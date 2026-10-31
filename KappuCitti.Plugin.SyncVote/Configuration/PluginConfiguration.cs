using System.Collections.Generic;
using KappuCitti.Plugin.SyncVote.Models;
using MediaBrowser.Model.Plugins;

namespace KappuCitti.Plugin.SyncVote.Configuration;

/// <summary>
/// Plugin configuration for SyncVote.
/// </summary>
public class PluginConfiguration : BasePluginConfiguration
{
    /// <summary>
    /// Gets or sets the default time limit for voting sessions in minutes.
    /// </summary>
    public int DefaultTimeLimit { get; set; } = 5;

    /// <summary>
    /// Gets or sets a value indicating whether every user can see every room.
    /// When false, a user only sees the rooms they belong to or the one of their SyncPlay group.
    /// </summary>
    public bool AllowPublicRooms { get; set; } = true;

    /// <summary>
    /// Gets or sets the maximum number of members per room.
    /// </summary>
    public int MaxRoomMembers { get; set; } = 10;

    /// <summary>
    /// Gets or sets how many wrong room codes a user can type before they have to wait (30 seconds, then longer with each
    /// further mistake). Between 1 and 20.
    /// </summary>
    public int WrongCodeAttempts { get; set; } = 7;

    /// <summary>
    /// Gets or sets a value indicating whether voting should auto-start when all SyncPlay members joined the room.
    /// </summary>
    public bool AutoStartVoting { get; set; } = false;

    /// <summary>
    /// Gets or sets the default sort order for candidates.
    /// </summary>
    public string DefaultSortBy { get; set; } = "Random";

    /// <summary>
    /// Gets or sets a value indicating whether the plugin injects its client script into the Jellyfin web UI by itself.
    /// Disable it when the script is loaded through another plugin (File Transformation, Custom JavaScript).
    /// </summary>
    public bool InjectWebClient { get; set; } = true;

    /// <summary>
    /// Gets or sets the language of the plugin screens: <c>Auto</c> follows the display language of the server, or a language code (<c>en</c>, <c>it</c>).
    /// </summary>
    public string Language { get; set; } = "Auto";

    /// <summary>
    /// Gets or sets a value indicating whether users can organize voting rooms unless overridden.
    /// </summary>
    public bool DefaultCanOrganize { get; set; } = true;

    /// <summary>
    /// Gets or sets a value indicating whether users can vote unless overridden.
    /// </summary>
    public bool DefaultCanVote { get; set; } = true;

    /// <summary>
    /// Gets or sets the per-user permission overrides, edited in the settings page.
    /// </summary>
    public List<UserPermissionOverride> UserPermissionOverrides { get; set; } = new();
}
