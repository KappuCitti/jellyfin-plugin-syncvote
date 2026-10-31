<h1 align="center">SyncVote</h1>

<p align="center">
  <b>Choose what to watch, together.</b><br>
  Swipe-style voting for Jellyfin SyncPlay: everybody likes or dislikes the same titles, the winner starts playing for the whole group.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-blue.svg"></a>
  <img alt="Jellyfin 10.10, 10.11 and 12" src="https://img.shields.io/badge/Jellyfin-10.10%20%7C%2010.11%20%7C%2012-00a4dc.svg">
  <a href="https://github.com/KappuCitti/jellyfin-plugin-syncvote/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/KappuCitti/jellyfin-plugin-syncvote?include_prereleases"></a>
</p>

<p align="center">
  <img alt="The SyncVote entry in the SyncPlay menu" src="docs/images/menu.png" width="420">
</p>

Picking a movie for a watch party takes longer than watching it. SyncVote moves the argument into Jellyfin: whoever
organizes opens a voting room from the SyncPlay menu, everybody in the group swipes through the same list of titles for a
few minutes, and the most liked title is queued and played in the SyncPlay group.

<p align="center">
  <img alt="Swiping through the titles: the poster follows the finger and a green or red edge shows the vote" src="docs/images/swipe.gif" width="420">
</p>

It looks and feels like Jellyfin itself (same dialogs, same components) and speaks English, Italian, Spanish, German, French and Estonian (the last four were translated with AI and may be imperfect:
corrections are welcome, see [CONTRIBUTING](CONTRIBUTING.md)).

## What you get

- **A voting room for your SyncPlay group**, opened from the SyncPlay menu: no extra app, no extra page.
- **Fair voting**: everybody sees the same titles in the same order, and only titles that *every* member is allowed to see.
- **Filters** for the list: library folders, Jellyfin collections, genres, maximum age rating and "title contains". Order it
  randomly, by title, by rating or by premiere date.
- **A time limit** (1 to 120 minutes) enforced by the server. The round ends by itself, the organizer can end it earlier,
  start a new round, or close the room.
- **A runoff** when several titles got a like: one click and everybody votes again, only on those.
- **One click to play** the winner in the SyncPlay group.
- **Access check**: before creating the room the organizer is warned if somebody in the group cannot see the chosen
  libraries (without telling who).
- **Controls for admins**: who can organize or vote, room size, auto-start, room visibility.
- **Like, dislike, or just use the keyboard** (← →) or swipe on touch screens.
- **A room code**, if you want one: anybody in the SyncPlay group can join a room, but only the people who have the 6-digit code
  can vote. See [Room code](#room-code).
- **A purple dot** on the SyncPlay button while the group is voting (Jellyfin 12), so nobody misses it.

## Screenshots

<table>
  <tr>
    <td width="50%"><img alt="Creating a voting room" src="docs/images/create.png"><br><sub><b>1.</b> The organizer picks the libraries, genres and time limit.</sub></td>
    <td width="50%"><img alt="Voting on a title" src="docs/images/voting.png"><br><sub><b>2.</b> Everybody swipes through the same titles.</sub></td>
  </tr>
  <tr>
    <td colspan="2"><img alt="The results" src="docs/images/results.png"><br><sub><b>3.</b> The ranking, a button to play the winner in the group, and one to vote again only on the liked titles.</sub></td>
  </tr>
</table>

## Compatibility

Jellyfin plugins cannot be built once for every server version, so SyncVote ships **one package per Jellyfin generation**.
Pick the row of your server:

| Your Jellyfin server | SyncVote package | Status |
|:---|:---|:---|
| **12.x** | `0.2.0.2` | ✅ Supported, tested on 12.4 |
| **10.11.x** | `0.2.0.1` | ✅ Supported, tested on 10.11.11 |
| **10.10.x** | `0.2.0.0` | ✅ Supported, tested on 10.10.7 |
| 10.9.x | – | ⚠️ Not offered by the catalog, not tested |
| 10.8.x and older | – | ❌ Not supported (needs a Jellyfin feature that appeared in 10.9) |

The last digit of the version is the Jellyfin generation (`.0` → 10.10, `.1` → 10.11, `.2` → 12), and the first three are the
release (`0.2.0` above). So **`0.2.0.0` is the build for Jellyfin 10.10 only**, not for newer servers.

> [!NOTE]
> You do not have to choose: add the repository (see below) and Jellyfin offers the package made for your server.

> [!WARNING]
> Packages are not interchangeable. If you install by hand, take the one for your server: a 10.10 package on Jellyfin 10.11
> or 12 loads but most features fail with errors, and a package for a newer generation does not load at all on an older server.

SyncVote works in the **Jellyfin web client** (browsers and apps built on it), in the new interface of Jellyfin 12 as well as
in the classic one. The **official Jellyfin app for Android** is one of those apps: the SyncVote entry is in its SyncPlay menu and
swiping works with the finger (tried with app 2.7.3 on Android 12, against Jellyfin 12.2). Fully native apps (Android TV, iOS,
third-party apps…) do not run the web client, so they are not expected to show it; they have not been tried.

## Installation

1. In Jellyfin, open **Dashboard → Plugins → Repositories → Add** and paste:

   ```text
   https://raw.githubusercontent.com/KappuCitti/jellyfin-plugin-syncvote/master/manifest.json
   ```

2. Open **Catalog**, install **SyncVote**, and restart the server.

That is all: the plugin adds its own script to the web client, no other plugin is needed. Reload the web page once
(`Ctrl+F5`) after the first start.

## Using SyncVote

1. Everybody joins the same **SyncPlay group** (the SyncPlay button in the top bar).
2. Open the SyncPlay menu and pick **SyncVote**.
3. The organizer creates the room: a name, at least one library folder or collection, and optionally genres, an age rating,
   a title filter, the time limit, the order and a [code](#room-code).
4. The others open the same menu entry and join. When everybody is in, the organizer starts the voting.
5. Like or dislike each title. The time left is shown on top.
6. When the time is up (or the organizer stops it with the stop icon in the header) the results appear. The organizer can
   **play the winner**, start a **runoff**, start a **new round**, or **close** the room.

A **runoff** is a new round with only the titles that got at least one like, so the group can settle a close call. It is
offered when two or more titles were liked, and the ranking of the runoff starts from zero. A **new round** goes back to the
whole list.

> [!TIP]
> Turn on **Auto-start voting** in the plugin settings and the round starts as soon as every member of the SyncPlay group has
> joined the room.

### Room code

Anybody who can use SyncPlay can join a SyncPlay group, and a group has no password. If the server is shared with people you do
not know, tick **Ask for a code to vote** when you create the room:

- The server makes a **6-digit code**. You (the organizer) and the administrators see it all the time, in the header of the room
  and, in the lobby, in big digits; click it to copy it. Nobody else is ever shown it.
- Everybody else can open the room, but has to type the code to be let in. Without it there are no titles to vote on, no results
  and no votes. A code works at any time: somebody who types it while a round is running can vote in that round.
- By default the code lasts for **the whole SyncPlay session**: the next room of the group has the same one, and whoever typed it
  does not type it again. Choose **one round** instead and every new round has a new code (the people of the previous round have
  to type the new one).
- If the code gets to somebody who should not have it, the button next to it in the header makes a **new code**: it asks first,
  then everybody else is out of the room and has to type the new one (the votes already cast stay).
- Guessing is slowed down: after 7 wrong codes (you can change the number in the settings) the user has to wait 30 seconds, then
  longer with each mistake. The codes are never obvious ones like `111111` or `123456`.

> [!NOTE]
> The code keeps out people who happen to be in the group; it is not encryption. If your server is reached over plain `http`,
> somebody who can see the network traffic can see the code like they could see a password: use `https` (a reverse proxy) if that
> matters.

## Settings

Dashboard → Plugins → SyncVote. The page has two tabs, **General** and **Permissions**. Every setting is saved as soon as you
change it, except the defaults and the table of users in Permissions: those are saved together with **Save** (**Cancel** throws
the changes away). Both buttons stay off until something differs from what is saved, and go off again if you put it back by hand.

**General**

| Option | What it does |
|:---|:---|
| Default time limit / default sort order | Starting values of the create form |
| Max room members | How many people can join a room |
| Wrong room codes allowed | How many wrong codes a user can type for a room with a [code](#room-code) before they have to wait (7) |
| Language | `Same as the server` (default), Deutsch, Eesti, English, Español, Français or Italiano |
| Auto-start voting | Start when every SyncPlay member has joined the room |
| Add SyncVote to the web interface | Turn off only if another plugin loads the script for you |

**Permissions**

| Option | What it does |
|:---|:---|
| Show every room to everyone | Off by default: people only see the rooms they are in or the one of their SyncPlay group |
| Users can organize / can vote | The default for everybody, users created later included; administrators can always do both |
| Permissions per user | A collapsed table of all users with a box for each of the two permissions, and a filter by name |

In the table a tick means the user can. Changing a box makes an exception to the default of its column; changing the default
itself sets the whole column and clears its exceptions (put the default back and the column is as it was, unsaved exceptions
included). Only what differs from the default is saved, and a permission without an
exception keeps following the default. Administrators are shown ticked and cannot be changed. Exceptions of users that were
deleted are still listed (as *Deleted user*, with the start of their id): put their boxes back to the default to drop them.

The exceptions are stored in `plugins/configurations/KappuCitti.Plugin.SyncVote.xml` in the Jellyfin data folder; there is no
need to edit that file any more, but a hand-written one from earlier versions keeps working.

## Good to know

> [!NOTE]
> Rooms and votes live in the server's memory only, nothing is written to disk. A room lasts at most a day and goes away when
> the server restarts, which is fine for a movie night.

> [!NOTE]
> The language of the SyncVote screens is the display language of the **server** (Dashboard → General), so everybody in the
> group reads the same thing, even if their browsers differ. Change it in the plugin settings if you want another one.

> [!IMPORTANT]
> The voting list only contains titles that **every member** of the room can see (library access and parental controls
> included). If a title you expect is missing, somebody in the room is not allowed to see it.

## Troubleshooting

<details>
<summary>I do not see the SyncVote entry</summary>

- The entry is in the SyncPlay menu **of a group**: join or create a SyncPlay group first. In the new interface it is the first
  item of the menu, above *Settings*.
- Reload the page with `Ctrl+F5` after installing or updating.
- Make sure *Add SyncVote to the web interface* is on (Dashboard → Plugins → SyncVote).
- Open `https://your-server/SyncVote/Client/syncvote.js` in the browser: it should show JavaScript. If not, the plugin is not
  running: check Dashboard → Plugins and the server log.
- The official Android app shows it like the browser does. Fully native apps (Android TV, iOS, third-party ones) do not: use
  the web client or the Android app.
</details>

<details>
<summary>The plugin does not start after an update of Jellyfin</summary>

A new Jellyfin generation needs the SyncVote package made for it. Open the catalog and update the plugin; if the new package is
not out yet, SyncVote stays unavailable until it is.
</details>

<details>
<summary>SyncVote does not see my SyncPlay group, or shows another one</summary>

Jellyfin tells the plugin which people are in each SyncPlay group, by user name, but not which of their devices is in which group.
If **the same account** is in two different groups at once (for example the phone in one and the browser in another), SyncVote can
pick the wrong one. Keep one account in one group at a time, or leave the group on the device you do not use.
</details>
<details>
<summary>The screens are in the wrong language</summary>

They follow the display language of the server. Change it in Dashboard → General, or pick a language in the plugin settings.
</details>

<details>
<summary>There is no "Collections" list in the create form</summary>

It only appears when your server has Jellyfin collections (box sets). Create one in Jellyfin and it shows up.
</details>

## Documentation

- [API reference](docs/API.md): the endpoints of the plugin.
- [Development guide](docs/DEVELOPMENT.md): build, test, how the Jellyfin versions are supported.
- [Security policy](SECURITY.md): how to report a vulnerability.
- [Contributing](CONTRIBUTING.md) and the [open issues](https://github.com/KappuCitti/jellyfin-plugin-syncvote/issues) (what is planned).
- [End-to-end tests](tests/e2e/README.md).

## License

[GNU General Public License v3.0](LICENSE).
