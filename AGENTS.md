# SyncVote – notes for coding agents

A Jellyfin plugin for group decisions on what to watch during SyncPlay, with swipe-style voting. The user-facing description
is the [README](README.md); this file is the short version of what an agent needs before touching the code.

## Where to look

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): layout, the one-source-many-Jellyfin-versions build, tests, how the pieces fit.
- [docs/API.md](docs/API.md): the HTTP API. [open issues](https://github.com/KappuCitti/jellyfin-plugin-syncvote/issues): what is left.
- [tests/e2e/README.md](tests/e2e/README.md): end-to-end scripts (real server, real web client in headless Chrome).

## Rules of the house

- **One source, one build per Jellyfin generation** (10.10 → net8, 10.11 → net9, 12 → net10; `-p:JellyfinVersion=…`). Differences
  between generations belong in `Compat/` or behind `#if JELLYFIN_10_10|10_11|12`. After any change build all three
  (`./build.ps1 -SkipTests` builds them; add `-Targets` to limit).
- **Verify before claiming**: unit tests (`dotnet test KappuCitti.Plugin.SyncVote.Tests`) and, for anything that touches
  Jellyfin, the e2e scripts on a test server of each generation.
- **Never run e2e scripts on a server somebody is using.** They create users, groups and rooms, and some can change the server
  language (`-ChangeServerLanguage`). Use isolated servers (`tests/e2e/new-server.ps1`).
- **Security**: every endpoint needs Jellyfin authentication except the client files; organizer-only actions are checked in
  `VotingRoomService`; the SyncPlay group of a room is what the server sees for the user, never what the client sends.
  The code of a room lives only in `VotingRoomService`, goes to the organizer and administrators only (`ForViewer` in the
  controller), travels in the body of the join request, and is never logged or put in a model that is sent to everybody.- **The client** only relies on `ApiClient`, the DOM of the SyncPlay menu (`.syncPlayGroupMenu`, `data-id="leave-group"` in the
  classic layout; `#app-sync-play-menu` and `#sync-play-active-subheader` in the Material UI one) and Jellyfin's own CSS classes.
  The web client has two layouts (12 made the Material UI one the default): run `tests/e2e/ui-test.ps1` for `-Layout legacy` and
  `-Layout modern` after touching the client. `Dashboard.alert` cannot be used for dialogs (it forces a single OK button). Jellyfin lays the dialog
  footer over the content, so `syncvote.css` makes it a normal flex item in our dialogs.
- **The settings page's `<script>` must stay inside the `data-role="page"` element**, otherwise Jellyfin drops it.
- **Texts** live in `Web/i18n/<language>.json` (`en`, `it`, `es`, `de`, `fr`, `et`; same keys, checked by a test, and each one needs an
  entry in the Language list of the settings page). The server picks the language.
- Keep the plugin GUID identical in `Plugin.cs`, `Configuration/configPage.html` and `manifest.json`.
- Code comments, commit messages and Markdown are written in English.

## State

Working on Jellyfin 10.10, 10.11 and 12: rooms, voting with a server-side time limit, filters (library folders, collections,
genres, age rating, title), results, runoff, playing the winner in SyncPlay, access checks, permissions, an optional room code
(made by the server, with a wait after wrong guesses and a button to make a new one), swipe animation, English, Italian, Spanish, German, French and Estonian.
Rooms live in memory by design. See the [open issues](https://github.com/KappuCitti/jellyfin-plugin-syncvote/issues) for what is next.
