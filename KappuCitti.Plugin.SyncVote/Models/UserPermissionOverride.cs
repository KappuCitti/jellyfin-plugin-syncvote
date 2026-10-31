using System;
using System.Xml.Serialization;

namespace KappuCitti.Plugin.SyncVote.Models;

/// <summary>
/// An exception to the default permissions for one user. A permission left out (<c>null</c>) follows the default.
/// </summary>
// Named UserPermissions in the XML, as it always was, so configuration files written by hand keep working.
[XmlType("UserPermissions")]
public class UserPermissionOverride
{
    /// <summary>
    /// Gets or sets the user ID.
    /// </summary>
    public Guid UserId { get; set; }

    /// <summary>
    /// Gets or sets whether the user can organize voting rooms, or null to follow the default.
    /// </summary>
    public bool? CanOrganize { get; set; }

    /// <summary>
    /// Gets or sets whether the user can vote, or null to follow the default.
    /// </summary>
    public bool? CanVote { get; set; }
}
