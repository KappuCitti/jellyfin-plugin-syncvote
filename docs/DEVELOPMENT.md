# Development guide

How to build, test and change SyncVote. Read the [README](../README.md) first for what the plugin does.

## Requirements

- PowerShell 7 (the scripts) and Git.
- .NET SDKs for the Jellyfin generations you build: **8** for Jellyfin 10.10, **9** for 10.11, **10** for 12. The newest SDK
  builds all of them, so installing .NET 10 is enough.
- Chrome or Edge, only for the UI tests.

## Layout

| Path | What |
|:---|:---|
| `KappuCitti.Plugin.SyncVote/` | The plugin |
| `…/Api/` | Controllers (`SyncVoteController`, `ClientAssetsController`) and the request/response classes |
| `…/Services/` | `VotingRoomService` (rooms and votes, no Jellyfin types), `LibraryService`, `SyncPlayService` |
| `…/Infrastructure/` | Adds the script to the web client's `index.html`, picks the language, title matching |
| `…/Compat/` | The few Jellyfin types that moved between versions |
| `…/Web/` | `syncvote.js`, `syncvote.css`, `i18n/<language>.json` (embedded in the dll) |
| `…/Configuration/` | The settings class and the settings page |
| `KappuCitti.Plugin.SyncVote.Tests/` | Unit tests |
| `tests/e2e/` | End-to-end scripts against a real server: [README](../tests/e2e/README.md) |
| `build.ps1`, `release.ps1` | Packaging (see below) |

## One source, one build per Jellyfin generation

A plugin is compiled against one Jellyfin version and cannot be loaded by another generation (the target framework and some
types change). The project therefore builds the same source several times, selected by `JellyfinVersion`:

| `JellyfinVersion` | Target framework | Symbol | Target ABI | Version digit |
|:---|:---|:---|:---|:---|
| `10.10.x` | net8.0 | `JELLYFIN_10_10` | 10.10.0.0 | `.0` |
| `10.11.x` | net9.0 | `JELLYFIN_10_11` | 10.11.0.0 | `.1` |
| `12.x` | net10.0 | `JELLYFIN_12` | 12.0.0.0 | `.2` |

```powershell
dotnet build KappuCitti.Plugin.SyncVote -p:JellyfinVersion=10.10.7     # one generation (default: 12.0.0)
./build.ps1 -ReleaseVersion 0.2.0                                       # unit tests + all packages in ./artifacts
./build.ps1 -ReleaseVersion 0.2.0 -Targets 10.10,12 -SkipTests          # only some generations
```

- Output goes to `bin/jf<version>` and `obj/jf<version>`, so builds of different versions never overwrite each other.
- Each package is a zip with **only** `KappuCitti.Plugin.SyncVote.dll`: Jellyfin provides every other assembly
  (the Jellyfin packages are referenced with `ExcludeAssets=runtime`).
- We compile against the *oldest* version we test of each generation (10.10.7, 10.11.0, 12.0.0) and check it on a newer one
  (10.10.7, 10.11.11, 12.4.0).
- **Version numbers** are `X.Y.Z.<digit>`. The catalog of a server offers the highest version whose ABI it satisfies, so the
  digit must grow with the generation: that is how every server ends up with its own build.

> [!IMPORTANT]
> Jellyfin 10.8 and older cannot be supported: the plugin needs `IPluginServiceRegistrator`, which appeared in 10.9.

### When Jellyfin changes something

Put the difference in `Compat/` (type aliases in `GlobalUsings.cs`, helpers like `UserCompat`) or behind `#if JELLYFIN_…`,
and keep the rest of the code free of version checks. Build all three generations: that is where a break shows up.

### Supporting a new Jellyfin generation

Add a block to `KappuCitti.Plugin.SyncVote.csproj` (target framework, symbol, `TargetAbi`, next `AbiIndex`), a row to the matrix
in `build.ps1`, and the SDK to the workflows. Then run the tests below on a server of that generation.

## Tests

```powershell
dotnet test KappuCitti.Plugin.SyncVote.Tests
```

The unit tests link the version-independent plugin sources (rooms and votes, ranking, the clock, permissions, title matching,
language choice, web client injection) and check that the translation files stay in step. They need no Jellyfin server.

For the rest use [`tests/e2e`](../tests/e2e/README.md): API, the real web client in headless Chrome (once for each of its two
layouts), and the settings.

> [!WARNING]
> Run the end-to-end scripts on a test server only. They create users, groups and rooms, and some change the server's display
> language for a moment (only with `-ChangeServerLanguage`).

## How the pieces fit

- `PluginServiceRegistrator` registers the services as singletons and adds `WebClientInjectionMiddleware` to the pipeline
  (an `IStartupFilter`). The middleware puts `<script src=".../SyncVote/Client/syncvote.js">` before `</body>` of `/web/` and
  `/web/index.html`.
- The web client uses `ApiClient` (for the address and the token) and the DOM of the SyncPlay menu. It adds one entry to the
  menu and opens a dialog built with the same markup and classes as Jellyfin's dialogs (`formDialog`, `emby-button`,
  `emby-input`…). The menu is a different piece of the page in each web client layout, and the script handles both:
  - **Classic layout** (10.10, 10.11 and 12's "obsolete" one): an action sheet (`.actionSheet.syncPlayGroupMenu`) that is closed
    through the browser history, exactly like Jellyfin's own entries do. Only the menu of a group has `data-id="leave-group"`.
  - **Material UI layout** (the default in 12, "experimental" in 10.x): a `ul[role=menu]` in `#app-sync-play-menu`. The menu of a
    group has a header with the id `sync-play-active-subheader` (in 12 "leave group" is only an icon button, so its words cannot
    be looked for). The entry is a copy of one of the native ones, so it gets their (generated) styles, and the menu is closed by
    clicking its backdrop.
  Both headers can be in the page at the same time, only one of them visible: look at what is on screen, not at what exists.
- A **runoff** is a normal round limited to the titles that got a like (`VotingRoom.RunoffItemIds`). `VotingRoomService` decides
  who is in it and refuses votes for anyone else; `LibraryService.GetCandidateIds` narrows its (cached) list.
- A room belongs to the SyncPlay group the **server** sees for the caller (`ISyncPlayManager.ListGroups`). The client cannot
  choose it.
- `LibraryService` builds the candidate list once per room (cached for a minute): the titles every member can see, filtered, in
  an order that is the same for everybody (a seeded shuffle for `Random`).
- The time limit lives in `VotingRoomService`; the client only shows the seconds the server reports.

## Code style

`.editorconfig` is the one from Jellyfin's plugin template (analyzers and rules), plus one rule: unused `using`s are reported.
Code comments and documentation are written in English.
