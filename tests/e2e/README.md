# End-to-end tests

PowerShell (7+) scripts that test the plugin against a real Jellyfin server. **Use them on a test server only**: they create a
temporary user (`svtest`, removed at the end), SyncPlay groups and rooms, and change (then restore) the plugin configuration.

| Script | What it checks |
|---|---|
| `api-test.ps1` | The HTTP API: authentication, permissions, library, real SyncPlay, room life cycle, votes, ranking, the winner started in SyncPlay, filters and ordering, and the room code (who sees it, joining, guessing, wrong bodies, how long it lasts) |
| `ui-test.ps1` | The real web client in headless Chrome: the SyncPlay menu entry (once, looking like the native ones, and that the menu closes), creating a room, lobby, voting (buttons, keyboard, and swipes with a real mouse drag: the poster follows the pointer, short swipes spring back, long or thrown ones vote, a lost release is ignored, `prefers-reduced-motion`), timer, layout without scrolling at several heights, results (icons and text of the buttons on one line), the runoff, "play the winner", an administrator closing a room somebody else organized, the SyncVote entry staying in place in the new SyncPlay menu while the group changes, the purple dot of the SyncPlay button (Jellyfin 12), and the room code: the option when creating a room, the code in front of the organizer, and the screen where an ordinary user types it (empty, wrong, locked after 7 mistakes, right, asked again in the next round). Saves screenshots. `-Layout legacy\|modern` picks the web client layout, see below |
| `config-test.ps1` | The settings page (tabs, the permissions table with its exceptions, Save and Cancel), the injection switch, permissions, member limit, wrong room codes, private rooms, language selection |
| `new-server.ps1` | Creates an isolated Jellyfin server from the official portable zip (admin `root`/`root`, a library of 30 fake movies with genres, or your own folder of movies with `-MediaPath`). It only ever stops the server that uses its own data folder |
| `catalog-test.ps1` | Installs SyncVote from the **published** plugin catalog on an isolated server and checks that the server gets the package made for its Jellyfin generation. Then run `api-test.ps1` on it |
| `install-plugin.ps1` | Builds the plugin for a Jellyfin version, copies it into the test server and restarts it |

> [!WARNING]
> `ui-test.ps1` and `config-test.ps1` can switch the display language of the **server** for a moment, to check that the screens
> follow it. They only do it with `-ChangeServerLanguage` (and put it back): use that switch on a test server nobody is using.
> `api-test.ps1` creates a temporary collection and removes it (and the "Collections" library Jellyfin creates for it) at the end.

The tests expect an administrator (`root`/`root` by default, see `-AdminUser` and `-AdminPassword`) and at least one movie library.

## Examples

```powershell
# A test server that is already running (installed in the default Windows location)
./tests/e2e/install-plugin.ps1 -JellyfinVersion 10.10.7
./tests/e2e/api-test.ps1
./tests/e2e/ui-test.ps1
./tests/e2e/config-test.ps1

# Another Jellyfin version, isolated: download the zip from https://repo.jellyfin.org/files/server/windows/,
# unzip it to <folder>\server, then
dotnet publish KappuCitti.Plugin.SyncVote -c Release -p:JellyfinVersion=12.0.0 -o out12
./tests/e2e/new-server.ps1 -Root <folder> -Port 8098 -PluginDll out12/KappuCitti.Plugin.SyncVote.dll
./tests/e2e/api-test.ps1    -Base http://127.0.0.1:8098
./tests/e2e/ui-test.ps1     -Base http://127.0.0.1:8098 -LogDir <folder>\data\log
./tests/e2e/config-test.ps1 -Base http://127.0.0.1:8098
```

The UI test needs Chrome or Edge (set `CHROME_PATH` to choose one). The unit tests (no server) are in
`KappuCitti.Plugin.SyncVote.Tests`; run them with `dotnet test`.

## Both web client layouts

Jellyfin's web client has two layouts and the SyncPlay menu is a different piece of the page in each (an action sheet in the
classic one, a Material UI popover in the new one), so run `ui-test.ps1` once for each:

```powershell
./tests/e2e/ui-test.ps1 -Base http://127.0.0.1:8098 -Layout legacy -Tag -legacy
./tests/e2e/ui-test.ps1 -Base http://127.0.0.1:8098 -Layout modern -Tag -modern
```

`legacy` is the classic header (`desktop-legacy` in 12, the default before) and `modern` the Material UI one (the default in 12,
"experimental" in 10.x). The default, `-Layout default`, leaves whatever the web client picks, which on Jellyfin 12 is the new
one. `-Tag` keeps the screenshots of the runs apart.
