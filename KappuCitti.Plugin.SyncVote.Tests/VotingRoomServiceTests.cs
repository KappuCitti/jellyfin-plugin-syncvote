using System;
using System.Collections.Generic;
using System.Linq;
using KappuCitti.Plugin.SyncVote.Api;
using KappuCitti.Plugin.SyncVote.Configuration;
using KappuCitti.Plugin.SyncVote.Models;
using KappuCitti.Plugin.SyncVote.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace KappuCitti.Plugin.SyncVote.Tests;

public class VotingRoomServiceTests
{
    private static readonly Guid Organizer = Guid.NewGuid();
    private static readonly Guid Alice = Guid.NewGuid();
    private static readonly Guid Bob = Guid.NewGuid();
    private static readonly Guid Library = Guid.NewGuid();
    private static readonly Guid MovieA = Guid.NewGuid();
    private static readonly Guid MovieB = Guid.NewGuid();
    private static readonly Guid MovieC = Guid.NewGuid();

    private readonly FakeSettings _settings = new();
    private readonly FakeItems _items = new();
    private DateTime _now = new(2026, 1, 1, 20, 0, 0, DateTimeKind.Utc);
    private readonly VotingRoomService _service;

    public VotingRoomServiceTests()
    {
        _items.Add(MovieA, "Alien", 1979);
        _items.Add(MovieB, "Brazil", 1985);
        _items.Add(MovieC, "Casablanca", 1942);
        _service = new VotingRoomService(NullLogger<VotingRoomService>.Instance, _items, _settings) { Clock = () => _now };
    }

    private static CreateRoomRequest Request(string name = "Serata", int minutes = 5) => new()
    {
        Name = name,
        TimeLimit = minutes,
        SelectedCollections = new List<Guid> { Library }
    };

    private VotingRoom NewRoom(string group = "group-1", int minutes = 5)
        => _service.CreateRoom(Organizer, group, Request(minutes: minutes)).Value!;

    private VotingRoom RoomWithVotingOpen(params Guid[] members)
    {
        var room = NewRoom();
        foreach (var member in members)
        {
            Assert.True(_service.JoinRoom(room.Id, member).Succeeded);
        }

        Assert.True(_service.StartVoting(room.Id, Organizer).Succeeded);
        return room;
    }

    // ---- creating

    [Fact]
    public void CreateRoom_RequiresAName()
    {
        var result = _service.CreateRoom(Organizer, "g", Request("   "));
        Assert.Equal(RoomError.Invalid, result.Error);
    }

    [Fact]
    public void CreateRoom_RequiresALibrary()
    {
        var none = _service.CreateRoom(Organizer, "g", new CreateRoomRequest { Name = "x", SelectedCollections = new List<Guid>() });
        var missing = _service.CreateRoom(Organizer, "g", new CreateRoomRequest { Name = "x", SelectedCollections = null });
        var empty = _service.CreateRoom(Organizer, "g", new CreateRoomRequest { Name = "x", SelectedCollections = new List<Guid> { Guid.Empty } });

        Assert.Equal(RoomError.NoCollectionSelected, none.Error);
        Assert.Equal(RoomError.NoCollectionSelected, missing.Error);
        Assert.Equal(RoomError.NoCollectionSelected, empty.Error);
    }

    [Fact]
    public void CreateRoom_UsesTheOrganizerAsFirstMemberAndTheDefaultsOfTheConfiguration()
    {
        _settings.Configuration.DefaultTimeLimit = 7;
        _settings.Configuration.DefaultSortBy = "Title";

        var room = _service.CreateRoom(Organizer, "g", new CreateRoomRequest { Name = " Film ", SelectedCollections = new List<Guid> { Library } }).Value!;

        Assert.Equal("Film", room.Name);
        Assert.Equal(new[] { Organizer }, room.MemberIds);
        Assert.Equal(7, room.TimeLimit);
        Assert.Equal(SortBy.Title, room.SortBy);
        Assert.True(room.IsActive);
        Assert.False(room.IsVotingActive);
    }

    [Theory]
    [InlineData(0, 5)]
    [InlineData(-3, 5)]
    [InlineData(500, 120)]
    public void CreateRoom_KeepsTheTimeLimitInBounds(int requested, int expected)
    {
        _settings.Configuration.DefaultTimeLimit = 5;
        Assert.Equal(expected, NewRoom(minutes: requested).TimeLimit);
    }

    [Fact]
    public void CreateRoom_KeepsTheTitleFilterTrimmedOrNone()
    {
        var request = Request();
        request.TitleFilter = "  alien ";
        Assert.Equal("alien", _service.CreateRoom(Organizer, "g1", request).Value!.TitleFilter);

        request.TitleFilter = "   ";
        Assert.Null(_service.CreateRoom(Organizer, "g2", request).Value!.TitleFilter);

        request.TitleFilter = null;
        var room = _service.CreateRoom(Organizer, "g3", request).Value!;
        Assert.Null(room.TitleFilter);
        Assert.Null(_service.GetRoom(room.Id)!.TitleFilter);
    }

    [Fact]
    public void CreateRoom_IgnoresAnUnknownSortAndFallsBackToRandom()
    {
        var request = Request();
        request.SortBy = "Nonsense";
        Assert.Equal(SortBy.Random, _service.CreateRoom(Organizer, null, request).Value!.SortBy);
    }

    [Fact]
    public void CreateRoom_ReplacesThePreviousRoomOfTheSameOrganizerInTheGroup()
    {
        var first = NewRoom();
        var second = NewRoom();

        Assert.Null(_service.GetRoom(first.Id));
        Assert.NotNull(_service.GetRoom(second.Id));
        Assert.Single(_service.GetVisibleRooms(Organizer, "group-1", false));
    }

    [Fact]
    public void CreateRoom_RefusesASecondOrganizerWhileTheFirstRoundIsRunning()
    {
        NewRoom();
        var other = _service.CreateRoom(Alice, "group-1", Request());
        Assert.Equal(RoomError.GroupHasRoom, other.Error);
    }

    [Fact]
    public void CreateRoom_LetsAnotherOrganizerTakeOverOnceTheRoundIsFinished()
    {
        var room = NewRoom();
        _service.StartVoting(room.Id, Organizer);
        _service.EndVoting(room.Id, Organizer);

        Assert.True(_service.CreateRoom(Alice, "group-1", Request()).Succeeded);
    }

    [Fact]
    public void CreateRoom_AllowsRoomsInDifferentGroups()
    {
        NewRoom("group-1");
        Assert.True(_service.CreateRoom(Alice, "group-2", Request()).Succeeded);
    }

    // ---- joining

    [Fact]
    public void JoinRoom_IsIdempotent()
    {
        var room = NewRoom();
        Assert.True(_service.JoinRoom(room.Id, Alice).Succeeded);
        var again = _service.JoinRoom(room.Id, Alice);

        Assert.True(again.Succeeded);
        Assert.Equal(2, again.Value!.MemberIds.Count);
    }

    [Fact]
    public void JoinRoom_StopsAtTheMaximumNumberOfMembers()
    {
        _settings.Configuration.MaxRoomMembers = 2;
        var room = NewRoom();

        Assert.True(_service.JoinRoom(room.Id, Alice).Succeeded);
        Assert.Equal(RoomError.RoomFull, _service.JoinRoom(room.Id, Bob).Error);
        Assert.True(_service.JoinRoom(room.Id, Alice).Succeeded);
    }

    [Fact]
    public void JoinRoom_UnknownRoom()
    {
        Assert.Equal(RoomError.NotFound, _service.JoinRoom(Guid.NewGuid(), Alice).Error);
    }

    // ---- starting and ending

    [Fact]
    public void StartVoting_IsForTheOrganizerOnly()
    {
        var room = NewRoom();
        _service.JoinRoom(room.Id, Alice);

        Assert.Equal(RoomError.NotOrganizer, _service.StartVoting(room.Id, Alice).Error);
        Assert.True(_service.StartVoting(room.Id, Organizer).Succeeded);
    }

    [Fact]
    public void StartVoting_CannotStartTwice()
    {
        var room = NewRoom();
        _service.StartVoting(room.Id, Organizer);
        Assert.Equal(RoomError.VotingAlreadyActive, _service.StartVoting(room.Id, Organizer).Error);
    }

    [Fact]
    public void StartVoting_ReportsTheSecondsLeft()
    {
        var room = NewRoom(minutes: 3);
        var started = _service.StartVoting(room.Id, Organizer).Value!;
        Assert.Equal(180, started.SecondsRemaining);

        _now = _now.AddSeconds(45);
        Assert.Equal(135, _service.GetRoom(room.Id)!.SecondsRemaining);
    }

    [Fact]
    public void StartVoting_AfterARoundDiscardsTheOldVotes()
    {
        var room = RoomWithVotingOpen();
        _service.CastVote(room.Id, Organizer, MovieA, true);
        _service.EndVoting(room.Id, Organizer);

        _service.StartVoting(room.Id, Organizer);

        Assert.Empty(_service.GetResults(room.Id)!.LikedItems);
    }

    // ---- runoff

    // A: two likes, B: one like and one dislike, C: only disliked.
    private VotingRoom FinishedRoundWithTwoLikedTitles()
    {
        var room = RoomWithVotingOpen(Alice);
        _service.CastVote(room.Id, Organizer, MovieA, true);
        _service.CastVote(room.Id, Alice, MovieA, true);
        _service.CastVote(room.Id, Organizer, MovieB, true);
        _service.CastVote(room.Id, Alice, MovieB, false);
        _service.CastVote(room.Id, Organizer, MovieC, false);
        _service.CastVote(room.Id, Alice, MovieC, false);
        Assert.True(_service.EndVoting(room.Id, Organizer).Succeeded);
        return room;
    }

    [Fact]
    public void Runoff_VotesAgainOnlyOnTheTitlesWithALike()
    {
        var room = FinishedRoundWithTwoLikedTitles();

        var started = _service.StartVoting(room.Id, Organizer, onlyLiked: true);

        Assert.True(started.Succeeded);
        Assert.True(started.Value!.IsVotingActive);
        Assert.True(started.Value.IsRunoff);
        Assert.Equal(new[] { MovieA, MovieB }, started.Value.RunoffItemIds);
        Assert.Empty(_service.GetResults(room.Id)!.LikedItems);
        Assert.Empty(_service.GetVotedItemIds(room.Id, Organizer));
    }

    [Fact]
    public void Runoff_NeedsAtLeastTwoLikedTitlesAndLeavesTheResultsAlone()
    {
        var room = RoomWithVotingOpen(Alice);
        _service.CastVote(room.Id, Organizer, MovieA, true);
        _service.CastVote(room.Id, Alice, MovieA, true);
        _service.CastVote(room.Id, Organizer, MovieB, false);
        _service.EndVoting(room.Id, Organizer);

        var refused = _service.StartVoting(room.Id, Organizer, onlyLiked: true);

        Assert.Equal(RoomError.NotEnoughLikedTitles, refused.Error);
        var after = _service.GetRoom(room.Id)!;
        Assert.True(after.IsVotingFinished);
        Assert.False(after.IsRunoff);
        Assert.Equal(MovieA, _service.GetResults(room.Id)!.Winner!.ItemId);
    }

    [Fact]
    public void Runoff_NeedsARoundThatWasPlayed()
    {
        var room = NewRoom();
        Assert.Equal(RoomError.NotEnoughLikedTitles, _service.StartVoting(room.Id, Organizer, onlyLiked: true).Error);
        Assert.False(_service.GetRoom(room.Id)!.IsVotingActive);
    }

    [Fact]
    public void Runoff_IsForTheOrganizerOnlyAndNotWhileVotingRuns()
    {
        var room = FinishedRoundWithTwoLikedTitles();
        Assert.Equal(RoomError.NotOrganizer, _service.StartVoting(room.Id, Alice, onlyLiked: true).Error);

        Assert.True(_service.StartVoting(room.Id, Organizer, onlyLiked: true).Succeeded);
        Assert.Equal(RoomError.VotingAlreadyActive, _service.StartVoting(room.Id, Organizer, onlyLiked: true).Error);
    }

    [Fact]
    public void Runoff_OnlyTakesVotesForItsOwnTitles()
    {
        var room = FinishedRoundWithTwoLikedTitles();
        _service.StartVoting(room.Id, Organizer, onlyLiked: true);

        Assert.Equal(RoomError.UnknownItem, _service.CastVote(room.Id, Alice, MovieC, true).Error);
        Assert.True(_service.CastVote(room.Id, Alice, MovieB, true).Succeeded);
        Assert.Equal(new[] { MovieB }, _service.GetResults(room.Id)!.LikedItems.Select(i => i.ItemId));
    }

    [Fact]
    public void Runoff_CanNarrowDownAgain()
    {
        var room = RoomWithVotingOpen(Alice);
        _service.CastVote(room.Id, Organizer, MovieA, true);
        _service.CastVote(room.Id, Alice, MovieA, true);
        _service.CastVote(room.Id, Organizer, MovieB, true);
        _service.CastVote(room.Id, Alice, MovieC, true);
        _service.EndVoting(room.Id, Organizer);
        Assert.Equal(3, _service.StartVoting(room.Id, Organizer, onlyLiked: true).Value!.RunoffItemIds.Count);

        // In the runoff Casablanca loses its likes.
        _service.CastVote(room.Id, Organizer, MovieA, true);
        _service.CastVote(room.Id, Alice, MovieB, true);
        _service.CastVote(room.Id, Organizer, MovieC, false);
        _service.CastVote(room.Id, Alice, MovieC, false);
        _service.EndVoting(room.Id, Organizer);

        var second = _service.StartVoting(room.Id, Organizer, onlyLiked: true).Value!;

        Assert.Equal(new[] { MovieA, MovieB }, second.RunoffItemIds);
    }

    [Fact]
    public void ANewRoundAfterARunoffGoesBackToEveryTitle()
    {
        var room = FinishedRoundWithTwoLikedTitles();
        _service.StartVoting(room.Id, Organizer, onlyLiked: true);
        _service.EndVoting(room.Id, Organizer);

        var again = _service.StartVoting(room.Id, Organizer).Value!;

        Assert.False(again.IsRunoff);
        Assert.Empty(again.RunoffItemIds);
    }

    [Fact]
    public void TheRunoffTitlesOfAReturnedRoomAreACopy()
    {
        var room = FinishedRoundWithTwoLikedTitles();
        var started = _service.StartVoting(room.Id, Organizer, onlyLiked: true).Value!;

        started.SetRunoffItems(Array.Empty<Guid>());

        Assert.Equal(2, _service.GetRoom(room.Id)!.RunoffItemIds.Count);
    }

    [Fact]
    public void EndVoting_NeedsARunningRoundAndTheOrganizer()
    {
        var room = NewRoom();
        _service.JoinRoom(room.Id, Alice);
        Assert.Equal(RoomError.VotingNotActive, _service.EndVoting(room.Id, Organizer).Error);

        _service.StartVoting(room.Id, Organizer);
        Assert.Equal(RoomError.NotOrganizer, _service.EndVoting(room.Id, Alice).Error);

        var ended = _service.EndVoting(room.Id, Organizer).Value!;
        Assert.False(ended.IsVotingActive);
        Assert.True(ended.IsVotingFinished);
    }

    // ---- the clock

    [Fact]
    public void TheRoundEndsByItselfWhenTheTimeIsUp()
    {
        var room = RoomWithVotingOpen(Alice);

        _now = _now.AddMinutes(4).AddSeconds(59);
        Assert.True(_service.GetRoom(room.Id)!.IsVotingActive);

        _now = _now.AddSeconds(1);
        var after = _service.GetRoom(room.Id)!;
        Assert.False(after.IsVotingActive);
        Assert.True(after.IsVotingFinished);
        Assert.Equal(RoomError.VotingNotActive, _service.CastVote(room.Id, Alice, MovieA, true).Error);
    }

    [Fact]
    public void AFinishedRoomIsRemovedAfterAWhile()
    {
        var room = RoomWithVotingOpen();
        _service.EndVoting(room.Id, Organizer);

        _now = _now.AddHours(7);

        Assert.Empty(_service.GetVisibleRooms(Organizer, null, true));
        Assert.Null(_service.GetRoom(room.Id));
    }

    // ---- voting

    [Fact]
    public void CastVote_NeedsMembershipARunningRoundAndAKnownItem()
    {
        var room = NewRoom();
        _service.JoinRoom(room.Id, Alice);

        Assert.Equal(RoomError.VotingNotActive, _service.CastVote(room.Id, Alice, MovieA, true).Error);

        _service.StartVoting(room.Id, Organizer);
        Assert.Equal(RoomError.NotMember, _service.CastVote(room.Id, Bob, MovieA, true).Error);
        Assert.Equal(RoomError.UnknownItem, _service.CastVote(room.Id, Alice, Guid.NewGuid(), true).Error);
        Assert.Equal(RoomError.NotFound, _service.CastVote(Guid.NewGuid(), Alice, MovieA, true).Error);
        Assert.True(_service.CastVote(room.Id, Alice, MovieA, true).Succeeded);
    }

    [Fact]
    public void CastVote_ChangingYourMindReplacesTheVote()
    {
        var room = RoomWithVotingOpen(Alice);
        _service.CastVote(room.Id, Alice, MovieA, true);
        _service.CastVote(room.Id, Alice, MovieA, false);

        Assert.Empty(_service.GetResults(room.Id)!.LikedItems);
        Assert.Contains(MovieA, _service.GetVotedItemIds(room.Id, Alice));
    }

    [Fact]
    public void VotedItems_AreTrackedPerUser()
    {
        var room = RoomWithVotingOpen(Alice, Bob);
        _service.CastVote(room.Id, Alice, MovieA, true);
        _service.CastVote(room.Id, Bob, MovieB, false);

        Assert.Equal(new[] { MovieA }, _service.GetVotedItemIds(room.Id, Alice));
        Assert.Equal(new[] { MovieB }, _service.GetVotedItemIds(room.Id, Bob));
    }

    // ---- results

    [Fact]
    public void Results_RankByLikesThenFewerDislikesThenTheEarliestLike()
    {
        var room = RoomWithVotingOpen(Alice, Bob);

        // A: 2 likes. B: 1 like, 1 dislike. C: 1 like, liked later than B.
        _service.CastVote(room.Id, Organizer, MovieA, true);
        _service.CastVote(room.Id, Alice, MovieA, true);
        _service.CastVote(room.Id, Organizer, MovieB, true);
        _service.CastVote(room.Id, Alice, MovieB, false);
        _now = _now.AddSeconds(10);
        _service.CastVote(room.Id, Bob, MovieC, true);

        var results = _service.GetResults(room.Id)!;

        Assert.Equal(new[] { MovieA, MovieC, MovieB }.Length, results.LikedItems.Count);
        Assert.Equal(MovieA, results.Winner!.ItemId);
        Assert.Equal(2, results.Winner.VoteCount);
        Assert.Equal("Alien", results.Winner.Name);
        Assert.Equal(1979, results.Winner.Year);

        // B and C both have one like: C has no dislike so it wins the tie.
        Assert.Equal(new[] { MovieA, MovieC, MovieB }, results.LikedItems.Select(i => i.ItemId));
        Assert.Equal(1, results.LikedItems.Single(i => i.ItemId == MovieB).DislikeCount);
    }

    [Fact]
    public void Results_EarliestLikeBreaksARemainingTie()
    {
        var room = RoomWithVotingOpen(Alice);
        _service.CastVote(room.Id, Organizer, MovieB, true);
        _now = _now.AddSeconds(5);
        _service.CastVote(room.Id, Alice, MovieC, true);

        Assert.Equal(MovieB, _service.GetResults(room.Id)!.Winner!.ItemId);
    }

    [Fact]
    public void Results_HaveNoWinnerWithoutLikes()
    {
        var room = RoomWithVotingOpen();
        _service.CastVote(room.Id, Organizer, MovieA, false);

        var results = _service.GetResults(room.Id)!;
        Assert.Null(results.Winner);
        Assert.Empty(results.LikedItems);
    }

    [Fact]
    public void Results_UnknownRoom()
    {
        Assert.Null(_service.GetResults(Guid.NewGuid()));
    }

    // ---- closing

    [Fact]
    public void CloseRoom_OrganizerOrAdministratorOnly()
    {
        var room = NewRoom();
        _service.JoinRoom(room.Id, Alice);

        Assert.Equal(RoomError.NotOrganizer, _service.CloseRoom(room.Id, Alice, false).Error);
        Assert.True(_service.CloseRoom(room.Id, Alice, true).Succeeded);
        Assert.Null(_service.GetRoom(room.Id));
        Assert.Equal(RoomError.NotFound, _service.CloseRoom(room.Id, Organizer, false).Error);
    }

    [Fact]
    public void CloseRoom_DropsItsVotes()
    {
        var room = RoomWithVotingOpen();
        _service.CastVote(room.Id, Organizer, MovieA, true);
        _service.CloseRoom(room.Id, Organizer, false);

        Assert.Empty(_service.GetVotedItemIds(room.Id, Organizer));
    }

    // ---- visibility and permissions

    [Fact]
    public void PublicRooms_AreVisibleToEveryone()
    {
        NewRoom();
        Assert.Single(_service.GetVisibleRooms(Bob, null, false));
    }

    [Fact]
    public void PrivateRooms_AreVisibleToMembersTheGroupAndAdministrators()
    {
        _settings.Configuration.AllowPublicRooms = false;
        var room = NewRoom("group-1");
        _service.JoinRoom(room.Id, Alice);

        Assert.Single(_service.GetVisibleRooms(Organizer, null, false));
        Assert.Single(_service.GetVisibleRooms(Alice, null, false));
        Assert.Single(_service.GetVisibleRooms(Bob, "group-1", false));
        Assert.Single(_service.GetVisibleRooms(Bob, null, true));
        Assert.Empty(_service.GetVisibleRooms(Bob, "group-2", false));
        Assert.Empty(_service.GetVisibleRooms(Bob, null, false));

        var current = _service.GetRoom(room.Id)!;
        Assert.True(_service.IsVisibleTo(current, Alice, false, null));
        Assert.False(_service.IsVisibleTo(current, Bob, false, null));
    }

    [Fact]
    public void ReturnedRooms_AreCopies()
    {
        var room = NewRoom();
        _service.JoinRoom(room.Id, Alice);

        room.SetSelectedGenres(new[] { "Horror" });
        var again = _service.GetRoom(room.Id)!;

        Assert.Empty(again.SelectedGenres);
        Assert.Equal(2, again.MemberIds.Count);
        Assert.Single(room.MemberIds);
    }

    [Fact]
    public void Permissions_FollowTheDefaultsTheOverridesAndTheAdministratorRole()
    {
        _settings.Configuration.DefaultCanOrganize = false;
        _settings.Configuration.DefaultCanVote = true;
        _settings.Configuration.UserPermissionOverrides.Add(new UserPermissionOverride { UserId = Alice, CanOrganize = true, CanVote = false });

        var bob = _service.GetUserPermissions(Bob, false);
        Assert.False(bob.CanOrganize);
        Assert.True(bob.CanVote);

        var alice = _service.GetUserPermissions(Alice, false);
        Assert.True(alice.CanOrganize);
        Assert.False(alice.CanVote);

        var admin = _service.GetUserPermissions(Bob, true);
        Assert.True(admin.CanOrganize);
        Assert.True(admin.CanVote);
    }

    [Fact]
    public void AnExceptionOnlyChangesThePermissionItNames()
    {
        _settings.Configuration.DefaultCanOrganize = true;
        _settings.Configuration.DefaultCanVote = true;
        _settings.Configuration.UserPermissionOverrides.Add(new UserPermissionOverride { UserId = Alice, CanVote = false });

        Assert.True(_service.GetUserPermissions(Alice, false).CanOrganize);
        Assert.False(_service.GetUserPermissions(Alice, false).CanVote);

        _settings.Configuration.DefaultCanOrganize = false;
        Assert.False(_service.GetUserPermissions(Alice, false).CanOrganize);
    }

    [Fact]
    public void ExceptionsKeepTheirXmlShape()
    {
        // A file written by hand for the old model must still load, and a permission left out must stay out of the file.
        const string legacy = "<PluginConfiguration><UserPermissionOverrides><UserPermissions>"
            + "<UserId>3546ba77-ea1c-4d51-b4b1-c462ce9c1830</UserId><CanOrganize>false</CanOrganize><CanVote>true</CanVote>"
            + "</UserPermissions></UserPermissionOverrides></PluginConfiguration>";
        var serializer = new System.Xml.Serialization.XmlSerializer(typeof(PluginConfiguration));

        var loaded = (PluginConfiguration)serializer.Deserialize(new System.IO.StringReader(legacy))!;
        var entry = Assert.Single(loaded.UserPermissionOverrides);
        Assert.False(entry.CanOrganize);
        Assert.True(entry.CanVote);

        loaded.UserPermissionOverrides.Add(new UserPermissionOverride { UserId = Alice, CanVote = false });
        var written = new System.IO.StringWriter();
        serializer.Serialize(written, loaded);
        var xml = written.ToString();
        Assert.Contains("<UserPermissions>", xml, StringComparison.Ordinal);
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(xml, "<CanOrganize>"));
    }

    [Fact]
    public void ManyThreadsCanVoteAtTheSameTime()
    {
        var room = RoomWithVotingOpen();
        var users = Enumerable.Range(0, 8).Select(_ => Guid.NewGuid()).ToList();
        _settings.Configuration.MaxRoomMembers = 50;
        foreach (var user in users)
        {
            _service.JoinRoom(room.Id, user);
        }

        System.Threading.Tasks.Parallel.ForEach(users, user =>
        {
            for (var i = 0; i < 200; i++)
            {
                _service.CastVote(room.Id, user, MovieA, i % 2 == 0);
                _service.GetResults(room.Id);
                _service.GetRoom(room.Id);
            }
        });

        // Every user ended on a dislike (the last i is odd): nobody likes the movie any more.
        Assert.Empty(_service.GetResults(room.Id)!.LikedItems);
    }
}
