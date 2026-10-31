using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using KappuCitti.Plugin.SyncVote.Api;
using KappuCitti.Plugin.SyncVote.Infrastructure;
using KappuCitti.Plugin.SyncVote.Models;
using Microsoft.Extensions.Logging;

namespace KappuCitti.Plugin.SyncVote.Services;

/// <summary>
/// Manages voting rooms and votes. Rooms are ephemeral: they live in memory for the lifetime of the server.
/// Every public method is thread-safe and hands out copies, never the live room.
/// </summary>
public class VotingRoomService
{
    private static readonly TimeSpan FinishedRoomLifetime = TimeSpan.FromHours(6);
    private static readonly TimeSpan MaxRoomLifetime = TimeSpan.FromHours(24);

    // Wrong codes: a few are free (7 by default, set in the plugin settings), then the user is locked out for 30 s, doubling with
    // each further mistake up to 30 min. A code has 1,000,000 values: that is about 12 tries in the first 15 minutes and about 55
    // in a day for one account.
    private const int FirstLockSeconds = 30;
    private const int MaxLockSeconds = 1800;
    private const int MaxTypedCodeLength = 32;
    private static readonly TimeSpan AttemptMemory = TimeSpan.FromHours(1);

    private readonly object _lock = new();
    private readonly ILogger<VotingRoomService> _logger;
    private readonly IItemInfoProvider _items;
    private readonly IPluginSettings _settings;
    private readonly List<VotingRoom> _rooms = new();
    private readonly List<Vote> _votes = new();

    // Room codes live only here, in memory, and are never logged or put on a room: see GetCode.
    private readonly Dictionary<Guid, CodeState> _roomCodes = new();
    private readonly Dictionary<string, CodeState> _groupCodes = new();
    private readonly Dictionary<(Guid Room, Guid User), AttemptState> _attempts = new();

    /// <summary>
    /// Initializes a new instance of the <see cref="VotingRoomService"/> class.
    /// </summary>
    /// <param name="logger">The logger.</param>
    /// <param name="items">The library item lookup.</param>
    /// <param name="settings">The plugin settings.</param>
    public VotingRoomService(ILogger<VotingRoomService> logger, IItemInfoProvider items, IPluginSettings settings)
    {
        _logger = logger;
        _items = items;
        _settings = settings;
    }

    /// <summary>
    /// Gets or sets the clock (UTC); replaceable for tests.
    /// </summary>
    public Func<DateTime> Clock { get; set; } = () => DateTime.UtcNow;

    /// <summary>
    /// Gets or sets the generator of room codes (6 digits, from a cryptographic random source); replaceable for tests.
    /// </summary>
    public Func<string> CodeGenerator { get; set; } = () => RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6", CultureInfo.InvariantCulture);

    /// <summary>
    /// Creates a new voting room. A user's previous room for the same SyncPlay group is closed;
    /// the group cannot have two rooms organized by different users at the same time.
    /// </summary>
    /// <param name="organizerId">The organizer.</param>
    /// <param name="syncPlayGroupId">The SyncPlay group of the room, if any.</param>
    /// <param name="request">The request.</param>
    /// <returns>The created room.</returns>
    public OperationResult<VotingRoom> CreateRoom(Guid organizerId, string? syncPlayGroupId, CreateRoomRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Name))
        {
            return OperationResult<VotingRoom>.Fail(RoomError.Invalid);
        }

        if (!(request.SelectedCollections ?? new List<Guid>()).Any(id => id != Guid.Empty))
        {
            return OperationResult<VotingRoom>.Fail(RoomError.NoCollectionSelected);
        }

        var config = _settings.Configuration;
        var sortByName = string.IsNullOrWhiteSpace(request.SortBy) ? config.DefaultSortBy : request.SortBy;
        var sortBy = Enum.TryParse<SortBy>(sortByName, true, out var parsed) ? parsed : SortBy.Random;

        lock (_lock)
        {
            Cleanup();

            if (!string.IsNullOrEmpty(syncPlayGroupId))
            {
                foreach (var existing in _rooms.Where(r => r.IsActive && r.SyncPlayGroupId == syncPlayGroupId).ToList())
                {
                    if (existing.OrganizerId != organizerId && !existing.IsVotingFinished)
                    {
                        return OperationResult<VotingRoom>.Fail(RoomError.GroupHasRoom);
                    }

                    CloseRoomInternal(existing);
                }
            }

            var room = new VotingRoom
            {
                Id = Guid.NewGuid(),
                Name = request.Name.Trim(),
                SyncPlayGroupId = string.IsNullOrEmpty(syncPlayGroupId) ? null : syncPlayGroupId,
                OrganizerId = organizerId,
                IsActive = true,
                TimeLimit = request.TimeLimit > 0 ? request.TimeLimit : config.DefaultTimeLimit,
                SortBy = sortBy,
                MaxParentalRating = request.MaxParentalRating,
                TitleFilter = TitleMatcher.Normalize(request.TitleFilter),
                CreatedAt = Clock()
            };

            room.AddMember(organizerId);
            room.SetSelectedCollections(request.SelectedCollections ?? new List<Guid>());
            room.SetSelectedGenres(request.SelectedGenres ?? new List<string>());
            room.SetItemTypes(request.ItemTypes ?? new List<string>());

            if (request.RequireCode)
            {
                room.RequiresCode = true;
                room.CodeScope = Enum.TryParse<RoomCodeScope>(request.CodeScope, true, out var scope) && Enum.IsDefined(scope) ? scope : RoomCodeScope.Session;

                // A code for the whole SyncPlay session is the code of the group: every room of the group has it, and whoever
                // has entered it stays in. Otherwise the room has a code of its own.
                var state = room.CodeScope == RoomCodeScope.Session && room.SyncPlayGroupId != null
                    ? GroupCode(room.SyncPlayGroupId)
                    : new CodeState(NewCode(), Clock());
                state.Verified.Add(organizerId);
                _roomCodes[room.Id] = state;
            }

            _rooms.Add(room);
            _logger.LogInformation("Created voting room {RoomId} by user {UserId}", room.Id, organizerId);

            return OperationResult<VotingRoom>.Ok(room.Snapshot(Clock()));
        }
    }

    /// <summary>
    /// Gets the active rooms a user is allowed to see.
    /// </summary>
    /// <param name="userId">The user.</param>
    /// <param name="syncPlayGroupId">The SyncPlay group of the user, if any.</param>
    /// <param name="isAdministrator">Whether the user is a server administrator.</param>
    /// <returns>The visible rooms.</returns>
    public IReadOnlyList<VotingRoom> GetVisibleRooms(Guid userId, string? syncPlayGroupId, bool isAdministrator)
    {
        lock (_lock)
        {
            Cleanup();
            var publicRooms = _settings.Configuration.AllowPublicRooms;
            return _rooms
                .Where(r => r.IsActive)
                .Where(r => publicRooms || isAdministrator || CanSee(r, userId, syncPlayGroupId))
                .Select(r => r.Snapshot(Clock()))
                .ToList();
        }
    }

    /// <summary>
    /// Gets a room.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <returns>A copy of the room, or null.</returns>
    public VotingRoom? GetRoom(Guid roomId)
    {
        lock (_lock)
        {
            var room = FindActive(roomId);
            return room?.Snapshot(Clock());
        }
    }

    /// <summary>
    /// Gets the code of a room. It is meant for the organizer and the administrators only: callers decide who may see it.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <returns>The code (6 digits), or null when the room does not exist or has no code.</returns>
    public string? GetCode(Guid roomId)
    {
        lock (_lock)
        {
            return FindActive(roomId) != null && _roomCodes.TryGetValue(roomId, out var state) ? state.Code : null;
        }
    }

    /// <summary>
    /// Makes a new code for a room that asks for one, for example because the code got to somebody who should not have it.
    /// Everybody but the organizer is out of the room and has to type the new code; the votes already cast stay.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <param name="userId">The user asking.</param>
    /// <param name="isAdministrator">Whether the user is a server administrator.</param>
    /// <returns>The updated room.</returns>
    public OperationResult<VotingRoom> RenewCode(Guid roomId, Guid userId, bool isAdministrator)
    {
        lock (_lock)
        {
            var room = FindActive(roomId);
            if (room == null)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.NotFound);
            }

            if (room.OrganizerId != userId && !isAdministrator)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.NotOrganizer);
            }

            if (!room.RequiresCode)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.Invalid);
            }

            RotateCode(room, "asked by the organizer");
            return OperationResult<VotingRoom>.Ok(room.Snapshot(Clock()));
        }
    }

    /// <summary>
    /// Gets how many seconds a user still has to wait before trying a code again (0 when they can try).
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <param name="userId">The user.</param>
    /// <returns>The seconds to wait.</returns>
    public int GetRetryAfterSeconds(Guid roomId, Guid userId)
    {
        lock (_lock)
        {
            return _attempts.TryGetValue((roomId, userId), out var attempt) && attempt.LockedUntil > Clock()
                ? (int)Math.Ceiling((attempt.LockedUntil - Clock()).TotalSeconds)
                : 0;
        }
    }

    /// <summary>
    /// Gets whether a user may look at a room.
    /// </summary>
    /// <param name="room">The room.</param>
    /// <param name="userId">The user.</param>
    /// <param name="syncPlayGroupId">The SyncPlay group of the user, if any.</param>
    /// <param name="isAdministrator">Whether the user is a server administrator.</param>
    /// <returns>True when the room is visible to the user.</returns>
    public bool IsVisibleTo(VotingRoom room, Guid userId, bool isAdministrator, string? syncPlayGroupId)
        => isAdministrator || _settings.Configuration.AllowPublicRooms || CanSee(room, userId, syncPlayGroupId);

    /// <summary>
    /// Joins a user to a room. Joining a room twice is not an error. A room with a code lets in only the people who give it
    /// (and the administrators, who can see it anyway); after a few wrong codes the user has to wait.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <param name="userId">The user ID.</param>
    /// <param name="code">The code of the room, if the room has one.</param>
    /// <param name="isAdministrator">Whether the user is a server administrator.</param>
    /// <returns>The updated room.</returns>
    public OperationResult<VotingRoom> JoinRoom(Guid roomId, Guid userId, string? code = null, bool isAdministrator = false)
    {
        lock (_lock)
        {
            var room = FindActive(roomId);
            if (room == null)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.NotFound);
            }

            if (!room.MemberIds.Contains(userId))
            {
                if (room.RequiresCode && !isAdministrator && !CheckCode(room, userId, code, out var codeError))
                {
                    return OperationResult<VotingRoom>.Fail(codeError);
                }

                if (room.MemberIds.Count >= Math.Max(1, _settings.Configuration.MaxRoomMembers))
                {
                    return OperationResult<VotingRoom>.Fail(RoomError.RoomFull);
                }

                room.AddMember(userId);
                _logger.LogInformation("User {UserId} joined room {RoomId}", userId, roomId);
            }

            return OperationResult<VotingRoom>.Ok(room.Snapshot(Clock()));
        }
    }

    /// <summary>
    /// Starts a voting round. Only the organizer can do it; the votes of a previous round are discarded.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <param name="userId">The user asking.</param>
    /// <param name="onlyLiked">
    /// Runoff: vote again only on the titles that got at least one like in the round that just ended (there must be at least two).
    /// Otherwise the round is about every candidate again.
    /// </param>
    /// <returns>The updated room.</returns>
    public OperationResult<VotingRoom> StartVoting(Guid roomId, Guid userId, bool onlyLiked = false)
    {
        lock (_lock)
        {
            var room = FindActive(roomId);
            if (room == null)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.NotFound);
            }

            if (room.OrganizerId != userId)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.NotOrganizer);
            }

            if (room.IsVotingActive)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.VotingAlreadyActive);
            }

            // The ranking of the finished round is read before its votes are discarded.
            var runoff = onlyLiked ? Rank(roomId).Select(x => x.ItemId).ToList() : new List<Guid>();
            if (onlyLiked && runoff.Count < 2)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.NotEnoughLikedTitles);
            }

            // A code "for each round" changes when a new round follows a finished one: the people who voted before have to enter
            // the new code to vote again. The first round keeps the people who entered the code in the lobby.
            if (room.RequiresCode && room.CodeScope == RoomCodeScope.Round && room.IsVotingFinished)
            {
                RotateCode(room, "next round");
            }

            _votes.RemoveAll(v => v.RoomId == roomId);
            room.SetRunoffItems(runoff);
            room.IsVotingActive = true;
            room.IsVotingFinished = false;
            room.VotingStartedAt = Clock();
            _logger.LogInformation("Voting started in room {RoomId} by user {UserId}{Runoff}", roomId, userId, onlyLiked ? $" (runoff between {runoff.Count} titles)" : string.Empty);

            return OperationResult<VotingRoom>.Ok(room.Snapshot(Clock()));
        }
    }

    /// <summary>
    /// Ends the running voting round before its time limit. Only the organizer can do it.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <param name="userId">The user asking.</param>
    /// <returns>The updated room.</returns>
    public OperationResult<VotingRoom> EndVoting(Guid roomId, Guid userId)
    {
        lock (_lock)
        {
            var room = FindActive(roomId);
            if (room == null)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.NotFound);
            }

            if (room.OrganizerId != userId)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.NotOrganizer);
            }

            if (!room.IsVotingActive)
            {
                return OperationResult<VotingRoom>.Fail(RoomError.VotingNotActive);
            }

            FinishVoting(room);
            return OperationResult<VotingRoom>.Ok(room.Snapshot(Clock()));
        }
    }

    /// <summary>
    /// Closes a room. Only the organizer can do it.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <param name="userId">The user asking.</param>
    /// <param name="isAdministrator">Whether the user is a server administrator.</param>
    /// <returns>The outcome.</returns>
    public OperationResult<bool> CloseRoom(Guid roomId, Guid userId, bool isAdministrator)
    {
        lock (_lock)
        {
            var room = FindActive(roomId);
            if (room == null)
            {
                return OperationResult<bool>.Fail(RoomError.NotFound);
            }

            if (room.OrganizerId != userId && !isAdministrator)
            {
                return OperationResult<bool>.Fail(RoomError.NotOrganizer);
            }

            CloseRoomInternal(room);
            return OperationResult<bool>.Ok(true);
        }
    }

    /// <summary>
    /// Casts (or changes) a vote.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <param name="userId">The voter.</param>
    /// <param name="itemId">The item ID.</param>
    /// <param name="isLike">Whether it is a like.</param>
    /// <returns>The outcome.</returns>
    public OperationResult<bool> CastVote(Guid roomId, Guid userId, Guid itemId, bool isLike)
    {
        lock (_lock)
        {
            var room = FindActive(roomId);
            if (room == null)
            {
                return OperationResult<bool>.Fail(RoomError.NotFound);
            }

            if (!room.MemberIds.Contains(userId))
            {
                return OperationResult<bool>.Fail(RoomError.NotMember);
            }

            if (!room.IsVotingActive)
            {
                return OperationResult<bool>.Fail(RoomError.VotingNotActive);
            }

            if (_items.GetItem(itemId) == null)
            {
                return OperationResult<bool>.Fail(RoomError.UnknownItem);
            }

            // The winner of a runoff is one of its titles, whatever a client sends.
            if (room.IsRunoff && !room.RunoffItemIds.Contains(itemId))
            {
                return OperationResult<bool>.Fail(RoomError.UnknownItem);
            }

            _votes.RemoveAll(v => v.RoomId == roomId && v.UserId == userId && v.ItemId == itemId);
            _votes.Add(new Vote
            {
                Id = Guid.NewGuid(),
                RoomId = roomId,
                UserId = userId,
                ItemId = itemId,
                IsLike = isLike,
                VotedAt = Clock()
            });

            _logger.LogDebug("User {UserId} voted {Vote} for item {ItemId} in room {RoomId}", userId, isLike ? "like" : "dislike", itemId, roomId);
            return OperationResult<bool>.Ok(true);
        }
    }

    /// <summary>
    /// Gets the items a user already voted on in a room.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <param name="userId">The user.</param>
    /// <returns>The item IDs.</returns>
    public IReadOnlySet<Guid> GetVotedItemIds(Guid roomId, Guid userId)
    {
        lock (_lock)
        {
            return _votes.Where(v => v.RoomId == roomId && v.UserId == userId).Select(v => v.ItemId).ToHashSet();
        }
    }

    /// <summary>
    /// Gets the ranking of a room: most liked first, then fewest dislikes, then earliest like.
    /// </summary>
    /// <param name="roomId">The room ID.</param>
    /// <returns>The results, or null if the room does not exist.</returns>
    public VotingResults? GetResults(Guid roomId)
    {
        lock (_lock)
        {
            var room = FindActive(roomId);
            if (room == null)
            {
                return null;
            }

            var liked = Rank(roomId).Select(x =>
            {
                var info = _items.GetItem(x.ItemId);
                return new VotedItem
                {
                    ItemId = x.ItemId,
                    VoteCount = x.Likes,
                    DislikeCount = x.Dislikes,
                    Name = info?.Name ?? "Unknown",
                    Year = info?.Year,
                    Type = info?.Type ?? "Unknown"
                };
            }).ToList();

            return new VotingResults
            {
                RoomId = roomId,
                IsVotingFinished = room.IsVotingFinished,
                LikedItems = liked,
                Winner = liked.FirstOrDefault()
            };
        }
    }

    /// <summary>
    /// Gets the permissions of a user: server administrators can always do everything, the others follow their exception
    /// for that permission if they have one and the default otherwise.
    /// </summary>
    /// <param name="userId">The user.</param>
    /// <param name="isAdministrator">Whether the user is a server administrator.</param>
    /// <returns>The permissions.</returns>
    public UserPermissions GetUserPermissions(Guid userId, bool isAdministrator)
    {
        var config = _settings.Configuration;
        var overridden = config.UserPermissionOverrides.FirstOrDefault(p => p.UserId == userId);

        return new UserPermissions
        {
            UserId = userId,
            CanOrganize = isAdministrator || (overridden?.CanOrganize ?? config.DefaultCanOrganize),
            CanVote = isAdministrator || (overridden?.CanVote ?? config.DefaultCanVote)
        };
    }

    // The titles with at least one like, best first. Callers hold _lock.
    private List<RankedItem> Rank(Guid roomId)
    {
        return _votes
            .Where(v => v.RoomId == roomId)
            .GroupBy(v => v.ItemId)
            .Select(g => new
            {
                ItemId = g.Key,
                Likes = g.Count(v => v.IsLike),
                Dislikes = g.Count(v => !v.IsLike),
                FirstLike = g.Where(v => v.IsLike).Select(v => v.VotedAt).DefaultIfEmpty(DateTime.MaxValue).Min()
            })
            .Where(x => x.Likes > 0)
            .OrderByDescending(x => x.Likes)
            .ThenBy(x => x.Dislikes)
            .ThenBy(x => x.FirstLike)
            .Select(x => new RankedItem(x.ItemId, x.Likes, x.Dislikes))
            .ToList();
    }

    // True when the user may get into a room that has a code: they already proved they know it, or they give it now.
    // Callers hold _lock.
    private bool CheckCode(VotingRoom room, Guid userId, string? code, out RoomError error)
    {
        error = RoomError.None;
        if (!_roomCodes.TryGetValue(room.Id, out var state))
        {
            // A room that asks for a code always has one; if it does not, nobody gets in.
            error = RoomError.Forbidden;
            return false;
        }

        var now = Clock();
        if (state.Verified.Contains(userId))
        {
            return true;
        }

        var key = (room.Id, userId);
        _attempts.TryGetValue(key, out var attempt);
        if (attempt != null && now - attempt.Last > AttemptMemory)
        {
            _attempts.Remove(key);
            attempt = null;
        }

        if (attempt != null && attempt.LockedUntil > now)
        {
            error = RoomError.TooManyAttempts;
            return false;
        }

        // Somebody typing a code does not type more than a few characters: anything longer is a wrong code, and is not even read.
        var typed = code ?? string.Empty;
        var digits = typed.Length > MaxTypedCodeLength ? "too long" : new string(typed.Where(char.IsDigit).ToArray());
        if (digits.Length == 0)
        {
            error = RoomError.CodeRequired;
            return false;
        }

        // Compared in constant time, so the time it takes says nothing about how much of the code is right.
        if (!CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(digits), Encoding.UTF8.GetBytes(state.Code)))
        {
            attempt ??= _attempts[key] = new AttemptState();
            attempt.Failures++;
            attempt.Last = now;
            var free = Math.Clamp(_settings.Configuration.WrongCodeAttempts, 1, 20);
            if (attempt.Failures >= free)
            {
                var seconds = Math.Min(MaxLockSeconds, FirstLockSeconds * Math.Pow(2, Math.Min(attempt.Failures - free, 10)));
                attempt.LockedUntil = now.AddSeconds(seconds);
            }

            _logger.LogInformation("Wrong code for room {RoomId} from user {UserId} ({Failures} in a row)", room.Id, userId, attempt.Failures);
            error = RoomError.WrongCode;
            return false;
        }

        _attempts.Remove(key);
        state.Verified.Add(userId);
        state.Touched = now;
        return true;
    }

    // A code nobody else uses right now, and not one that is the first thing anybody would try (111111, 123456, 121212...).
    // Callers hold _lock.
    private string NewCode()
    {
        var inUse = _roomCodes.Values.Concat(_groupCodes.Values).Select(s => s.Code).ToHashSet(StringComparer.Ordinal);
        var code = CodeGenerator();
        for (var tries = 0; tries < 100 && (IsEasyToGuess(code) || inUse.Contains(code)); tries++)
        {
            code = CodeGenerator();
        }

        return code;
    }

    /// <summary>
    /// Gets whether a code is the kind people try first: one digit repeated, a straight run up or down, a block of one to three
    /// digits repeated, or a palindrome. A bit more than 2,000 of the million codes.
    /// </summary>
    /// <param name="code">The code (digits).</param>
    /// <returns>True when the code is easy to guess.</returns>
    public static bool IsEasyToGuess(string code)
    {
        if (code.Length < 2 || !code.All(char.IsDigit))
        {
            return true;
        }

        var run = (int step) => Enumerable.Range(1, code.Length - 1).All(i => code[i] - code[i - 1] == step);
        var repeats = (int block) => Enumerable.Range(0, code.Length).All(i => code[i] == code[i % block]);
        return run(1) || run(-1) || repeats(1) || repeats(2) || repeats(3) || code.SequenceEqual(code.Reverse());
    }

    // The code of a SyncPlay group, made the first time a room of the group asks for one. Callers hold _lock.
    private CodeState GroupCode(string groupId)
    {
        if (!_groupCodes.TryGetValue(groupId, out var state))
        {
            state = new CodeState(NewCode(), Clock());
            _groupCodes[groupId] = state;
        }

        state.Touched = Clock();
        return state;
    }

    // A new code for a room (the next round, or because the organizer asked): only the organizer keeps the right to vote, everybody
    // else types the new code to get back in. The votes already cast stay. A code for the whole session is the code of the group, so
    // the next room of the group gets the new one too. Callers hold _lock.
    private void RotateCode(VotingRoom room, string reason)
    {
        var state = new CodeState(NewCode(), Clock());
        state.Verified.Add(room.OrganizerId);
        _roomCodes[room.Id] = state;
        if (room.CodeScope == RoomCodeScope.Session && room.SyncPlayGroupId != null)
        {
            _groupCodes[room.SyncPlayGroupId] = state;
        }

        foreach (var member in room.MemberIds.Where(id => id != room.OrganizerId).ToList())
        {
            room.RemoveMember(member);
        }

        foreach (var key in _attempts.Keys.Where(k => k.Room == room.Id).ToList())
        {
            _attempts.Remove(key);
        }

        _logger.LogInformation("New code for room {RoomId} ({Reason})", room.Id, reason);
    }

    private static bool CanSee(VotingRoom room, Guid userId, string? syncPlayGroupId)
        => room.OrganizerId == userId
           || room.MemberIds.Contains(userId)
           || (!string.IsNullOrEmpty(syncPlayGroupId) && room.SyncPlayGroupId == syncPlayGroupId);

    // Callers hold _lock.
    private VotingRoom? FindActive(Guid roomId)
    {
        var room = _rooms.FirstOrDefault(r => r.Id == roomId && r.IsActive);
        if (room != null)
        {
            ExpireVoting(room);
        }

        return room;
    }

    private void ExpireVoting(VotingRoom room)
    {
        if (room.IsVotingActive && room.VotingEndsAt is { } end && Clock() >= end)
        {
            FinishVoting(room);
        }
    }

    private void FinishVoting(VotingRoom room)
    {
        room.IsVotingActive = false;
        room.IsVotingFinished = true;
        _logger.LogInformation("Voting finished in room {RoomId}", room.Id);
    }

    private void CloseRoomInternal(VotingRoom room)
    {
        room.IsActive = false;
        room.IsVotingActive = false;
        _votes.RemoveAll(v => v.RoomId == room.Id);
        _roomCodes.Remove(room.Id);
        foreach (var key in _attempts.Keys.Where(k => k.Room == room.Id).ToList())
        {
            _attempts.Remove(key);
        }

        _logger.LogInformation("Closed voting room {RoomId}", room.Id);
    }

    private void Cleanup()
    {
        var now = Clock();
        foreach (var room in _rooms.ToList())
        {
            ExpireVoting(room);
            var finishedLongAgo = room.IsVotingFinished && room.VotingEndsAt is { } end && now - end > FinishedRoomLifetime;
            var tooOld = now - room.CreatedAt > MaxRoomLifetime;
            if (!room.IsActive || finishedLongAgo || tooOld)
            {
                if (room.IsActive)
                {
                    CloseRoomInternal(room);
                }

                _rooms.Remove(room);
            }
        }

        // The code of a group is forgotten a day after it was last used, when no room needs it.
        foreach (var group in _groupCodes.Where(g => now - g.Value.Touched > MaxRoomLifetime && !_roomCodes.ContainsValue(g.Value)).Select(g => g.Key).ToList())
        {
            _groupCodes.Remove(group);
        }

        foreach (var stale in _attempts.Where(a => now - a.Value.Last > AttemptMemory).Select(a => a.Key).ToList())
        {
            _attempts.Remove(stale);
        }
    }

    private sealed record RankedItem(Guid ItemId, int Likes, int Dislikes);

    private sealed class CodeState
    {
        public CodeState(string code, DateTime now)
        {
            Code = code;
            Touched = now;
        }

        public string Code { get; }

        // The users who gave the right code: they do not have to give it again for as long as it is valid.
        public HashSet<Guid> Verified { get; } = new();

        public DateTime Touched { get; set; }
    }

    private sealed class AttemptState
    {
        public int Failures { get; set; }

        public DateTime Last { get; set; }

        public DateTime LockedUntil { get; set; }
    }
}
