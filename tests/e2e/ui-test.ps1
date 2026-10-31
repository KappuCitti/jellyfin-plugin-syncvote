<#
.SYNOPSIS
    Drives the real Jellyfin web client in headless Chrome: SyncPlay menu, room creation, voting, results, play.
    Screenshots go to -OutDir. Needs a SyncPlay-capable server with one movie library and the plugin installed.
.PARAMETER LogDir
    The log folder of the server under test (used to confirm SyncPlay received the play request).
.PARAMETER Layout
    Which web client layout to test. "default" is what the web client picks by itself (the new Material UI layout on 12, the
    classic one before). "legacy" forces the classic layout and "modern" the Material UI one (the "experimental" layout in 10.x).
    Run the test once for each of them: the SyncPlay menu is a different piece of the page in each.
#>
param([string]$Base = "http://127.0.0.1:8096", [string]$AdminUser = "root", [string]$AdminPassword = "root", [string]$Tag = "",
      [ValidateSet("default", "legacy", "modern")][string]$Layout = "default",
      [switch]$ChangeServerLanguage,
      [string]$LogDir = (Join-Path $env:LOCALAPPDATA "jellyfin\log"), [string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) "syncvote-e2e"))

. "$PSScriptRoot\lib\jf.ps1" -Base $Base
. "$PSScriptRoot\lib\cdp.ps1"

$shots = "$OutDir\shots$Tag"
New-Item -ItemType Directory -Force $shots | Out-Null
$script:fail = 0
function Check($name, $cond, $detail = "") {
    if ($cond) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name  $detail" -ForegroundColor Red; $script:fail++ }
}

# The web client stores the layout in localStorage. 12 renamed the classic one "desktop-legacy" and made the Material UI layout the
# default (no value); before 12 the classic one is the default and the Material UI one is called "experimental".
$serverMajor = [int]((Invoke-RestMethod "$Base/System/Info/Public").Version -split '\.')[0]
$layoutValue = switch ($Layout) {
    "legacy" { if ($serverMajor -ge 12) { "desktop-legacy" } else { "desktop" } }
    "modern" { if ($serverMajor -ge 12) { "" } else { "experimental" } }
    default { $null }
}

# True when the Material UI header is the one on screen (the classic header stays in the page, hidden, in that case).
function Test-ModernHeader { [bool](Js "(function(){ const s = document.querySelector('.MuiAppBar-root svg[data-testid=GroupsIcon]'); return !!s && s.getBoundingClientRect().width > 0 })()") }
function Open-SyncPlayMenu {
    Js "(function(){ const s = document.querySelector('.MuiAppBar-root svg[data-testid=GroupsIcon]'); const modern = !!s && s.getBoundingClientRect().width > 0; (modern ? s.closest('button') : document.querySelector('.headerSyncButton')).click(); return true })()" | Out-Null
    Wait-Js "!!document.querySelector('.syncPlayGroupMenu.opened') || !!document.querySelector('#app-sync-play-menu:not(.MuiModal-hidden) ul[role=menu]')" 8 | Out-Null
    Start-Sleep -Milliseconds 600
}
# The SyncPlay menu is closed when neither the classic action sheet nor the Material UI popover is open.
$menuClosed = "!document.querySelector('.syncPlayGroupMenu.opened') && !document.querySelector('#app-sync-play-menu:not(.MuiModal-hidden)')"
# Icon and text of every button in the footer of the dialog: are they on one line, centered with each other?
$footerButtons = "(function(){ return JSON.stringify(Array.from(document.querySelectorAll('.svDialog .formDialogFooter .formDialogFooterItem')).map(b => { const icon = b.querySelector('.material-icons'); const text = b.querySelector('span:not(.material-icons)'); const range = document.createRange(); range.selectNodeContents(text); const i = icon ? icon.getBoundingClientRect() : null, tr = range.getBoundingClientRect(), br = b.getBoundingClientRect(); return { label: text.textContent.trim(), lines: range.getClientRects().length, dy: i ? Math.round(Math.abs((i.top + i.height / 2) - (tr.top + tr.height / 2)) * 10) / 10 : 0, inside: br.left <= (i ? i.left : tr.left) + 0.5 && tr.right <= br.right + 0.5 } })) })()"

$root = Login $AdminUser $AdminPassword "ui-device"
$serverConfig = Invoke-RestMethod "$Base/System/Configuration" -Headers $root.Headers
function Set-ServerLanguage($culture) {
    $cfg = Invoke-RestMethod "$Base/System/Configuration" -Headers $root.Headers
    $cfg.UICulture = $culture
    Invoke-RestMethod "$Base/System/Configuration" -Method Post -Headers $root.Headers -ContentType "application/json" -Body ($cfg | ConvertTo-Json -Depth 10) | Out-Null
}
# The screens follow the language of the server. Forcing a language changes the server setting for the duration of the test:
# only do it on a test server nobody is using (-ChangeServerLanguage). Otherwise the texts are checked against the current language.
if ($ChangeServerLanguage) { Set-ServerLanguage "en-US" }
$hasBoxSets = [bool]@((Invoke-RestMethod "$Base/SyncVote/Library/Collections" -Headers $root.Headers) | Where-Object { $_.Type -eq "boxset" })
# The texts the checks look for, in the language the server will give the screens (English for a language the plugin does not have).
$texts = @{
    it = @{ Create = "Crea stanza"; Close = "Chiudi stanza"; Folders = "Cartelle libreria"; Collections = "Collezioni"; Genres = "Generi"; NoCollections = "Ancora nessuna collezione"; Runoff = "ballottaggio" }
    es = @{ Create = "Crear sala"; Close = "Cerrar sala"; Folders = "Carpetas de la biblioteca"; Collections = "Colecciones"; Genres = "Géneros"; NoCollections = "Todavía no hay colecciones"; Runoff = "segunda vuelta" }
    de = @{ Create = "Raum erstellen"; Close = "Raum schließen"; Folders = "Bibliotheksordner"; Collections = "Sammlungen"; Genres = "Genres"; NoCollections = "Noch keine Sammlungen"; Runoff = "Stichwahl" }
    fr = @{ Create = "Créer la salle"; Close = "Fermer la salle"; Folders = "Dossiers de la bibliothèque"; Collections = "Collections"; Genres = "Genres"; NoCollections = "Pas encore de collections"; Runoff = "second tour" }
    et = @{ Create = "Loo ruum"; Close = "Sulge ruum"; Folders = "Meediateegi kaustad"; Collections = "Kogud"; Genres = "Žanrid"; NoCollections = "Kogusid veel pole"; Runoff = "kordushääletus" }
    en = @{ Create = "Create room"; Close = "Close room"; Folders = "Library folders"; Collections = "Collections"; Genres = "Genres"; NoCollections = "No collections yet"; Runoff = "runoff" }
}
$serverLanguage = ((Invoke-RestMethod "$Base/System/Configuration" -Headers $root.Headers).UICulture -split '[-_]')[0].ToLowerInvariant()
$T = $(if ($texts.ContainsKey($serverLanguage)) { $texts[$serverLanguage] } else { $texts.en }).Clone()
$expectedSections = if ($hasBoxSets) { "$($T.Folders)|$($T.Collections)|$($T.Genres)" } else { "$($T.Folders)|$($T.Genres)" }
# Remove stale rooms left by an interrupted run.
foreach ($r in @((Call $root GET "/SyncVote/Rooms").Body)) { Call $root DELETE "/SyncVote/Room/$($r.Id)" | Out-Null }
$existing = Invoke-RestMethod "$Base/Users" -Headers $root.Headers | Where-Object Name -eq "svtest"
if ($existing) { Invoke-RestMethod "$Base/Users/$($existing.Id)" -Method Delete -Headers $root.Headers | Out-Null }
$created = Invoke-RestMethod "$Base/Users/New" -Method Post -Headers $root.Headers -ContentType "application/json" -Body (@{ Name = "svtest"; Password = "svtest-pw" } | ConvertTo-Json)
$sv = Login "svtest" "svtest-pw" "devB"
$logFile = "$LogDir\log_$(Get-Date -Format yyyyMMdd).log"

try {
    Start-Chrome "$OutDir\e2e-chrome-profile"
    Send-Cdp "Page.navigate" @{ url = "$Base/web/index.html" } | Out-Null
    Wait-Js "!!document.querySelector('#txtManualName')" 25 | Out-Null
    if ($null -ne $layoutValue) {
        # The layout is read when the page starts: set it, then load the page again.
        Js $(if ($layoutValue) { "localStorage.setItem('layout', '$layoutValue'); true" } else { "localStorage.removeItem('layout'); true" }) | Out-Null
        Send-Cdp "Page.navigate" @{ url = "$Base/web/index.html" } | Out-Null
        Wait-Js "!!document.querySelector('#txtManualName')" 25 | Out-Null
    }
    Js "(function(){ const n=document.querySelector('#txtManualName'); const p=document.querySelector('#txtManualPassword'); n.value='$AdminUser'; p.value='$AdminPassword'; document.querySelector('.manualLoginForm').dispatchEvent(new Event('submit',{cancelable:true,bubbles:true})); return true })()" | Out-Null
    $ready = Wait-Js "!!window.__syncVoteManager && !!window.ApiClient && !!ApiClient.accessToken()" 25
    Check "SyncVote client script loaded and user logged in" ([bool]$ready)
    Start-Sleep 3
    $modern = Test-ModernHeader
    Write-Host "      web client layout on screen: $(if ($modern) { 'modern (Material UI header)' } else { 'classic header' })"
    if ($Layout -ne "default") { Check "the web client shows the $Layout layout" ($modern -eq ($Layout -eq "modern")) "modern=$modern" }
    Save-Shot "$shots\01-home.png"
    Check "no literal template text in the page" (-not (Js "document.body.innerText.includes('`${title}') || document.body.innerText.includes('SyncVote Plugin Styles')"))
    Check "no purple floating button" (-not (Js "!!document.querySelector('.svFloatingButton')"))

    # The browser's own session creates the SyncPlay group; the second user joins through the API.
    Js "ApiClient.ajax({type:'POST', url: ApiClient.getUrl('SyncPlay/New'), data: JSON.stringify({GroupName:'ui-group'}), contentType:'application/json'}).then(()=>true)" | Out-Null
    $gid = $null
    for ($i = 0; $i -lt 20 -and -not $gid; $i++) { Start-Sleep -Milliseconds 500; $gid = (Call $root GET "/SyncPlay/List").Body | Where-Object GroupName -eq "ui-group" | Select-Object -First 1 -ExpandProperty GroupId }
    Check "SyncPlay group created from the browser" ([bool]$gid)
    $j = Call $sv POST "/SyncPlay/Join" @{ GroupId = $gid }
    Check "second user joined the group" ($j.Status -in 200,204) "status $($j.Status)"

    Write-Host "== SyncPlay menu"
    Open-SyncPlayMenu
    $menuItems = if ($modern) { "#app-sync-play-menu .svSyncVoteItem" } else { ".syncPlayGroupMenu.opened .svSyncVoteItem" }
    Check "SyncVote item is in the SyncPlay menu, once" ((Js "document.querySelectorAll('$menuItems').length") -eq 1) (Js "document.querySelectorAll('.svSyncVoteItem').length")
    Check "no SyncVote item is left anywhere else in the page" ((Js "document.querySelectorAll('.svSyncVoteItem').length") -eq 1)
    if ($modern) {
        # The entry is a copy of a native one: same height, same text, same padding, and an icon that is really drawn.
        $look = Js "(function(){ const sv = document.querySelector('.svSyncVoteItem'); const native = Array.from(sv.parentElement.querySelectorAll('li[role=menuitem]')).find(i => i !== sv); const cs = e => getComputedStyle(e), r = e => e.getBoundingClientRect(); const text = e => e.querySelector('.MuiListItemText-primary'); const icon = sv.querySelector('.svMenuIcon'); return JSON.stringify({ hasNative: !!native, height: native ? Math.abs(r(sv).height - r(native).height) : null, font: native ? cs(text(sv)).fontSize === cs(text(native)).fontSize : null, left: native ? cs(sv).paddingLeft === cs(native).paddingLeft : null, label: text(sv).innerText.trim(), iconWidth: Math.round(r(icon).width), iconX: native ? Math.abs(r(icon).left - r(native.querySelector('.MuiListItemIcon-root')).left) < 4 : null, listed: sv.parentElement.matches('ul[role=menu]') }) })()" | ConvertFrom-Json
        Check "the menu entry looks like the native ones (height, font, padding, icon position)" ($look.hasNative -and $look.height -le 1 -and $look.font -and $look.left -and $look.iconX -and $look.iconWidth -ge 16) ($look | ConvertTo-Json -Compress)
        Check "the menu entry is inside the list of the menu" ($look.listed -and $look.label -eq "SyncVote") ($look | ConvertTo-Json -Compress)
    }
    Save-Shot "$shots\02-menu.png"
    Js "document.querySelector('.svSyncVoteItem').click(); true" | Out-Null
    $form = Wait-Js "!!document.querySelector('#svRoomName')" 10
    Check "create dialog opens" ([bool]$form)
    Start-Sleep 1
    Check "SyncPlay menu is closed once SyncVote opens" ([bool](Js $menuClosed)) (Js "document.querySelectorAll('.syncPlayGroupMenu, #app-sync-play-menu').length")
    Check "dialog uses Jellyfin's own markup" ((Js "!!document.querySelector('.svDialog.formDialog .formDialogHeader') && !!document.querySelector('.svDialog .formDialogFooter') && !!document.querySelector('#svRoomName.emby-input')"))
    Save-Shot "$shots\03-create.png"
    Check "form lists collections and genres" ((Js "document.querySelectorAll('.svCollection').length") -ge 1 -and (Js "document.querySelectorAll('.svGenre').length") -ge 1)
    Check "the dialog speaks the language of the server" ((Js "document.querySelector('.svCreate').innerText.trim()") -eq $T.Create) (Js "document.querySelector('.svCreate').innerText")
    $fill = Js "(function(){ const c=document.querySelector('.svDialog .formDialogContent'), b=document.querySelector('.svCreateBody'); return JSON.stringify({w: b.getBoundingClientRect().width / c.clientWidth, h: b.getBoundingClientRect().height - c.clientHeight}) })()" | ConvertFrom-Json
    Check "the create form fills the whole dialog (width and height)" ($fill.w -ge 0.95 -and $fill.h -ge -2) ($fill | ConvertTo-Json -Compress)
    foreach ($height in 900, 640) {
        Send-Cdp "Emulation.setDeviceMetricsOverride" @{ width = 1100; height = $height; deviceScaleFactor = 1; mobile = $false } | Out-Null
        Start-Sleep -Milliseconds 600
        $g = Js "(function(){ const q=s=>document.querySelector(s).getBoundingClientRect(); const c=document.querySelector('.svDialog .formDialogContent'); const f=q('.svForm'), d=q('.svDialog'); return JSON.stringify({selectsAboveFooter: q('.svSelects').bottom <= q('.formDialogFooter').top + 1, scroll: c.scrollHeight - c.clientHeight, formWidthShare: f.width / d.width}) })()" | ConvertFrom-Json
        Check "create form at height ${height}: nothing hidden behind the footer, no scrolling, nearly full width" ($g.selectsAboveFooter -and $g.scroll -le 1 -and $g.formWidthShare -ge 0.9) ($g | ConvertTo-Json -Compress)
    }
    Send-Cdp "Emulation.setDeviceMetricsOverride" @{ width = 1100; height = 900; deviceScaleFactor = 1; mobile = $false } | Out-Null
    Start-Sleep -Milliseconds 600
    Check "sections match the server (library folders, collections only if there are any, genres)" ((Js "Array.from(document.querySelectorAll('.svCreateBody h2.sectionTitle')).map(h => h.innerText.trim()).join('|')") -eq $expectedSections) (Js "Array.from(document.querySelectorAll('.svCreateBody h2.sectionTitle')).map(h => h.innerText.trim()).join('|')")
    Check "the collections list shows up only when the server has collections" ((Js "document.querySelector('.svCreateBody').innerText.includes('$($T.Collections)')") -eq $hasBoxSets)
    Check "there is a title filter field" ((Js "!!document.querySelector('#svTitleFilter')"))
    Save-Shot "$shots\03b-create-fill.png"
    Check "no raw translation keys" (-not (Js "/field\.|dialog\.createRoom|btn\.createRoom/.test(document.querySelector('.svDialog').innerText)"))

    Js "document.querySelector('#svRoomName').value='Serata UI'; document.querySelector('#svTimeLimit').value='1'; document.querySelectorAll('.svCollection:checked').forEach(c => c.click()); document.querySelector('.svCreate').click(); true" | Out-Null
    Start-Sleep 1
    Check "creating without a library is refused with a message in the form" ((Js "!!document.querySelector('#svRoomName')") -and (Js "getComputedStyle(document.querySelector('#svFormError')).display !== 'none' && document.querySelector('#svFormError').innerText.length > 5") -and @((Call $root GET "/SyncVote/Rooms").Body).Count -eq 0)
    Js "document.querySelector('#svRoomName').value=''; document.querySelector('.svCreate').click(); true" | Out-Null
    Check "missing name shows a message in the form" ((Js "getComputedStyle(document.querySelector('#svFormError')).display !== 'none'") -and (Js "document.activeElement.id === 'svRoomName'"))
    Js "document.querySelector('#svRoomName').value='Serata UI'; true" | Out-Null
    Js "document.querySelector('.svCollection').click(); document.querySelector('.svCreate').click(); true" | Out-Null
    $lobby = Wait-Js "!!document.querySelector('#svLobbyMembers')" 10
    Check "lobby opens after creating the room" ([bool]$lobby)
    $room = (Call $root GET "/SyncVote/Rooms").Body | Where-Object Name -eq "Serata UI" | Select-Object -First 1
    Check "room exists for the SyncPlay group" ($room -and $room.SyncPlayGroupId -eq ([guid]$gid).ToString("N"))

    Call $sv POST "/SyncVote/Room/$($room.Id)/Join" | Out-Null
    $members = Wait-Js "document.querySelector('#svLobbyMembers') && document.querySelector('#svLobbyMembers').innerText.startsWith('2')" 8
    Check "lobby shows the second member" ([bool]$members) (Js "document.querySelector('#svLobbyMembers').innerText")
    Save-Shot "$shots\04-lobby.png"
    # The dot on the SyncPlay button (new layout only) is purple (the Jellyfin logo purple) while the group is voting, not before
    # (lobby) and not after (results, room closed).
    $purpleDot = "rgb(170, 92, 195)"
    $dotColor = "(function(){ const i = document.querySelector('.MuiAppBar-root svg[data-testid=GroupsIcon]'); const d = i && i.closest('button') && i.closest('button').querySelector('.MuiBadge-badge'); return d ? getComputedStyle(d).backgroundColor : '' })()"
    # Jellyfin 12 added the dot; the "experimental" layout of 10.x has none, so there is nothing to color there.
    $hasDot = [bool](Js "(function(){ const i = document.querySelector('.MuiAppBar-root svg[data-testid=GroupsIcon]'); return !!(i && i.closest('button') && i.closest('button').querySelector('.MuiBadge-badge')) })()")
    if ($modern -and $serverMajor -ge 12) { Check "the SyncPlay button has a dot while the group is joined" $hasDot }
    if ($modern -and $hasDot) {
        Start-Sleep 6   # more than one check of the web client (every 5 seconds)
        Check "the dot of the SyncPlay button is not purple while the room is only in the lobby" ((Js $dotColor) -ne $purpleDot) (Js $dotColor)
    }

    Write-Host "== voting"
    Js "document.querySelector('.svStart').click(); true" | Out-Null
    $card = Wait-Js "!!document.querySelector('#svCard h2')" 10
    Check "voting card shows a title" ([bool]$card)
    if ($modern -and $hasDot) {
        $purple = Wait-Js "($dotColor) === '$purpleDot'" 10
        Check "the dot of the SyncPlay button is purple once the voting has started" ([bool]$purple) (Js $dotColor)
    }
    $title1 = Js "document.querySelector('#svCard h2').innerText"
    Start-Sleep 1.5
    Save-Shot "$shots\05-voting.png"
    $t1 = Js "document.querySelector('#svTime').innerText"
    Start-Sleep 3
    $t2 = Js "document.querySelector('#svTime').innerText"
    $secs = { param($x) $p = $x -split ':'; [int]$p[0] * 60 + [int]$p[1] }
    Check "timer counts down" ((& $secs $t2) -lt (& $secs $t1) -and (& $secs $t1) -le 60) "t1=$t1 t2=$t2"
    Check "progress bar follows the timer" ([double](Js "parseFloat(document.querySelector('#svProgressBar').style.width)") -lt 100)
    foreach ($size in @(@(1100, 900, "tall"), @(1100, 560, "short"), @(420, 700, "phone"))) {
        Send-Cdp "Emulation.setDeviceMetricsOverride" @{ width = $size[0]; height = $size[1]; deviceScaleFactor = 1; mobile = $false } | Out-Null
        Start-Sleep -Milliseconds 700
        $r = Js "(function(){ const q=s=>document.querySelector(s).getBoundingClientRect(); const l=q('#svLike'), d=q('#svDislike'); return JSON.stringify({likeOk: l.top>=0 && l.bottom<=innerHeight, dislikeOk: d.top>=0 && d.bottom<=innerHeight, row: getComputedStyle(document.querySelector('#svCard')).display, vh: innerHeight}) })()" | ConvertFrom-Json
        Check "vote buttons visible without scrolling ($($size[2]) $($size[0])x$($size[1]))" ($r.likeOk -and $r.dislikeOk) ($r | ConvertTo-Json -Compress)
        $m = Js "(function(){ const c=document.querySelector('.svDialog .formDialogContent'); const l=document.querySelector('#svLike').getBoundingClientRect(), d=document.querySelector('#svDislike').getBoundingClientRect(); const f=document.querySelector('.svDialog .formDialogFooter').getBoundingClientRect(); const mid=(f.left+f.right)/2; return JSON.stringify({scroll: c.scrollHeight - c.clientHeight, dy: Math.abs((l.top+l.height/2)-(d.top+d.height/2)), dx: Math.abs((mid-(d.left+d.width/2)) - ((l.left+l.width/2)-mid)), endInFooter: !!document.querySelector('.svDialog .formDialogFooter .svEnd'), endInHeader: !!document.querySelector('.svDialog .formDialogHeader .svEnd')}) })()" | ConvertFrom-Json
        Check "the voting view needs no scrolling ($($size[2]))" ($m.scroll -le 1) ($m | ConvertTo-Json -Compress)
        Check "like and dislike are aligned and centered ($($size[2]))" ($m.dy -le 1 -and $m.dx -le 3) ($m | ConvertTo-Json -Compress)
        Check "end voting is a header icon, not next to the votes ($($size[2]))" ($m.endInHeader -and -not $m.endInFooter) ($m | ConvertTo-Json -Compress)
        if ($size[2] -eq "short") { Check "short screen: poster left, text right" ($r.row -eq "flex") ($r | ConvertTo-Json -Compress) }
        Save-Shot "$shots\05-voting-$($size[2]).png"
    }
    Send-Cdp "Emulation.setDeviceMetricsOverride" @{ width = 1100; height = 900; deviceScaleFactor = 1; mobile = $false } | Out-Null
    Start-Sleep -Milliseconds 700
    $h1 = Js "document.querySelector('#svCard').offsetHeight"
    $y1 = Js "Math.round(document.querySelector('#svLike').getBoundingClientRect().top)"
    Check "poster slot leaves the skeleton state (loaded, or no poster available)" ([bool](Wait-Js "!!document.querySelector('.svPosterBox.svLoaded')" 5))

    Js "document.querySelector('#svLike').click(); true" | Out-Null
    $moved = Wait-Js "document.querySelector('#svCard h2') && document.querySelector('#svCard h2').innerText !== $((ConvertTo-Json $title1))" 8
    Check "like moves to the next title" ([bool]$moved)
    Start-Sleep 1
    $h2 = Js "document.querySelector('#svCard').offsetHeight"
    $y2 = Js "Math.round(document.querySelector('#svLike').getBoundingClientRect().top)"
    Check "the layout does not move between titles" ($h1 -eq $h2 -and $y1 -eq $y2) "card $h1 -> $h2, buttons $y1 -> $y2"
    Check "next poster was preloaded" ((Js "Object.keys(__syncVoteManager.preloaded || {}).length") -ge 3)
    Js "document.querySelector('#svDislike').click(); true" | Out-Null
    Start-Sleep 1
    Js "document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight'})); true" | Out-Null
    Start-Sleep 1
    Check "three votes counted in the UI" ((Js "document.querySelector('#svVotesCount').innerText") -match '^3 ') (Js "document.querySelector('#svVotesCount').innerText")
    $res = Call $root GET "/SyncVote/Room/$($room.Id)/Results"
    Check "server recorded the two likes" (@($res.Body.LikedItems).Count -eq 2) "liked=$(@($res.Body.LikedItems).Count)"

    # Swipe with a real mouse drag. Only dislikes are cast here, so the likes the rest of the test relies on stay two.
    Write-Host "== swipe"
    $centre = Js "(function(){ const b=document.querySelector('#svCard .svPosterBox').getBoundingClientRect(); return JSON.stringify({x: Math.round(b.left+b.width/2), y: Math.round(b.top+b.height/2)}) })()" | ConvertFrom-Json
    $mouse = { param($type, $dx) Send-Cdp "Input.dispatchMouseEvent" @{ type = $type; x = $centre.x + $dx; y = $centre.y; button = "left"; buttons = $(if ($type -eq "mouseReleased") { 0 } else { 1 }); clickCount = 1 } | Out-Null }
    $cardState = "JSON.stringify({ textX: Math.round(document.querySelector('#svCard .svCardText').getBoundingClientRect().left), transform: document.querySelector('#svCard .svPosterBox').style.transform, opacity: document.querySelector('#svCard .svPosterBox').style.opacity, drag: document.querySelector('#svCard').dataset.drag || '', title: document.querySelector('#svCard h2') ? document.querySelector('#svCard h2').innerText : '', votes: document.querySelector('#svVotesCount').innerText })"
    $before = Js $cardState | ConvertFrom-Json
    & $mouse "mousePressed" 0
    foreach ($dx in 30, 60, 120) { & $mouse "mouseMoved" $dx }
    $drag = Js $cardState | ConvertFrom-Json
    Check "the poster follows the pointer and tilts, the text stays" ($drag.transform -match 'translateX\(120px\).*rotate\(' -and $drag.textX -eq $before.textX) ($drag | ConvertTo-Json -Compress)
    Check "past the threshold to the right the card shows it is a like" ($drag.drag -eq "like") ($drag | ConvertTo-Json -Compress)
    Save-Shot "$shots\05b-swipe-like.png"
    & $mouse "mouseMoved" 20
    Check "back under the threshold the mark is gone" ((Js "document.querySelector('#svCard').dataset.drag || ''") -eq "")
    & $mouse "mouseReleased" 20
    Start-Sleep -Milliseconds 500
    $back = Js $cardState | ConvertFrom-Json
    Check "a short swipe springs back and casts no vote" ($back.transform -eq "" -and $back.drag -eq "" -and $back.title -eq $before.title -and $back.votes -eq $before.votes) ($back | ConvertTo-Json -Compress)

    # A release that never arrives (an extension ate it): moving on with nothing pressed must not drag the poster or cast a vote.
    & $mouse "mousePressed" 0
    foreach ($dx in 30, 120) { & $mouse "mouseMoved" $dx }
    Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseMoved"; x = $centre.x + 200; y = $centre.y; buttons = 0 } | Out-Null
    Start-Sleep -Milliseconds 500
    $lost = Js $cardState | ConvertFrom-Json
    Check "moving with the button up (lost release) puts the poster back and casts no vote" ($lost.transform -eq "" -and $lost.drag -eq "" -and $lost.title -eq $before.title -and $lost.votes -eq $before.votes) ($lost | ConvertTo-Json -Compress)
    Send-Cdp "Input.dispatchMouseEvent" @{ type = "mouseReleased"; x = $centre.x + 200; y = $centre.y; button = "left"; buttons = 0; clickCount = 1 } | Out-Null

    & $mouse "mousePressed" 0
    foreach ($dx in -40, -90, -150) { & $mouse "mouseMoved" $dx }
    Check "past the threshold to the left the card shows it is a dislike" ((Js "document.querySelector('#svCard').dataset.drag") -eq "dislike")
    & $mouse "mouseReleased" -150
    Start-Sleep -Milliseconds 100
    $flying = Js $cardState | ConvertFrom-Json
    # Where the poster is heading, in px (the inline style is the end of the transition).
    $headingTo = { param($state) if ($state.transform -match 'translateX\((-?[\d.]+)px\)') { [double]$Matches[1] } else { [double]::NaN } }
    $x1 = & $headingTo $flying
    Check "after a long swipe the poster carries on to the left while it fades, the text stays" ($x1 -le -150 -and $x1 -ge -450 -and $flying.opacity -eq "0" -and $flying.textX -eq $before.textX) ($flying | ConvertTo-Json -Compress)
    $arrived = Wait-Js "document.querySelector('#svCard h2') && document.querySelector('#svCard h2').innerText !== $((ConvertTo-Json $before.title))" 8
    Check "the next title arrives after the vote" ([bool]$arrived)
    Start-Sleep -Milliseconds 400
    $next = Js $cardState | ConvertFrom-Json
    Check "the new card is clean (nothing left of the swipe) and the vote is counted" ($next.transform -eq "" -and $next.opacity -eq "" -and $next.drag -eq "" -and $next.votes -match '^4 ') ($next | ConvertTo-Json -Compress)
    Save-Shot "$shots\05c-after-swipe.png"

    # Thrown far: it must not come back to a fixed spot before it disappears.
    & $mouse "mousePressed" 0
    foreach ($dx in -100, -250, -400) { & $mouse "mouseMoved" $dx }
    & $mouse "mouseReleased" -400
    Start-Sleep -Milliseconds 100
    $thrown = Js $cardState | ConvertFrom-Json
    $x2 = & $headingTo $thrown
    Check "a poster thrown far away never comes back, it carries on while it fades" ($x2 -le -400 -and $thrown.opacity -eq "0") ($thrown | ConvertTo-Json -Compress)
    Check "the next title arrives after the throw" ([bool](Wait-Js "document.querySelector('#svVotesCount').innerText.startsWith('5 ')" 8)) (Js "document.querySelector('#svVotesCount').innerText")

    # Swiping again at once, while the new poster is still arriving: it must follow the pointer all the same (the entrance animation
    # must not hold on to the poster), and a short drag still springs back.
    & $mouse "mousePressed" 0
    foreach ($dx in 30, 60) { & $mouse "mouseMoved" $dx }
    $quick = Js "(function(){ const p = document.querySelector('#svCard .svPosterBox'); return JSON.stringify({ inline: p.style.transform, shown: getComputedStyle(p).transform }) })()" | ConvertFrom-Json
    $shownX = if ($quick.shown -match '^matrix\(([^)]*)\)') { [double](($Matches[1] -split ',')[4]) } else { [double]::NaN }
    Check "a swipe right after the new poster arrived moves the poster on screen" ($quick.inline -match 'translateX\(60px\)' -and $shownX -ge 55 -and $shownX -le 65) ($quick | ConvertTo-Json -Compress)
    & $mouse "mouseReleased" 60
    Start-Sleep -Milliseconds 500

    # A vote by button has no drag to continue from: the poster flies out to the side by itself.
    Js "document.querySelector('#svDislike').click(); true" | Out-Null
    Start-Sleep -Milliseconds 100
    $byButton = Js $cardState | ConvertFrom-Json
    Check "a vote by button makes the poster fly out to the left" ($byButton.transform -match 'translateX\(-120%\)' -and $byButton.opacity -eq "0" -and $byButton.drag -eq "dislike") ($byButton | ConvertTo-Json -Compress)
    Check "the next title arrives after the button" ([bool](Wait-Js "document.querySelector('#svVotesCount').innerText.startsWith('6 ')" 8)) (Js "document.querySelector('#svVotesCount').innerText")
    Start-Sleep -Milliseconds 400

    Send-Cdp "Emulation.setEmulatedMedia" @{ features = @(@{ name = "prefers-reduced-motion"; value = "reduce" }) } | Out-Null
    Js "document.querySelector('#svDislike').click(); true" | Out-Null
    Start-Sleep -Milliseconds 60
    Check "with reduced motion the poster does not fly" ((Js "document.querySelector('#svCard .svPosterBox').style.opacity") -eq "")
    Send-Cdp "Emulation.setEmulatedMedia" @{ features = @() } | Out-Null
    Check "the vote still counts with reduced motion" ([bool](Wait-Js "document.querySelector('#svVotesCount').innerText.startsWith('7 ')" 8)) (Js "document.querySelector('#svVotesCount').innerText")

    Call $sv POST "/SyncVote/Vote" @{ RoomId = $room.Id; ItemId = @($res.Body.LikedItems)[0].ItemId; IsLike = $true } | Out-Null
    Js "document.querySelector('.svEnd').click(); true" | Out-Null
    $results = Wait-Js "document.querySelectorAll('.svDialog .listItem').length >= 1" 10
    Check "ending the vote shows the results" ([bool]$results)
    if ($modern -and $hasDot) {
        $calm = Wait-Js "($dotColor) !== '$purpleDot' && ($dotColor) !== ''" 10
        Check "the dot is back to normal as soon as the voting is ended" ([bool]$calm) (Js $dotColor)
    }
    Start-Sleep 1
    Save-Shot "$shots\06-results.png"
    Check "winner is the title liked by both" ((Js "document.querySelector('.svDialog .listItemBodyText').innerText") -like "$(@($res.Body.LikedItems)[0].Name)*")

    Write-Host "== buttons of the results"
    Check "the results have a button for each thing the organizer can do (play, runoff, new round, close)" ((Js "document.querySelectorAll('.svDialog .formDialogFooterItem').length") -eq 4 -and (Js "!!document.querySelector('.svPlay') && !!document.querySelector('.svRunoff') && !!document.querySelector('.svAgain') && !!document.querySelector('.svCloseRoom')"))
    foreach ($size in @(@(1100, 900, "wide"), @(420, 700, "phone"))) {
        Send-Cdp "Emulation.setDeviceMetricsOverride" @{ width = $size[0]; height = $size[1]; deviceScaleFactor = 1; mobile = $false } | Out-Null
        Start-Sleep -Milliseconds 700
        $buttons = @(Js $footerButtons | ConvertFrom-Json)
        $crooked = @($buttons | Where-Object { $_.dy -gt 1.5 -or $_.lines -ne 1 -or -not $_.inside })
        Check "icon and text of every button are on one line, centered ($($size[2]) $($size[0])x$($size[1]))" ($buttons.Count -eq 4 -and $crooked.Count -eq 0) (($buttons | ConvertTo-Json -Compress))
        Save-Shot "$shots\06-results-$($size[2]).png"
    }
    Send-Cdp "Emulation.setDeviceMetricsOverride" @{ width = 1100; height = 900; deviceScaleFactor = 1; mobile = $false } | Out-Null
    Start-Sleep -Milliseconds 700

    Write-Host "== runoff: vote again on the liked titles"
    Check "the runoff button tells how many titles it is about" ((Js "document.querySelector('.svRunoff').title") -match '2')  (Js "document.querySelector('.svRunoff').title")
    Js "document.querySelector('.svRunoff').click(); true" | Out-Null
    Check "the runoff starts a new round" ([bool](Wait-Js "!!document.querySelector('#svCard h2')" 10))
    $roRoom = (Call $root GET "/SyncVote/Room/$($room.Id)").Body
    Check "the room is in a runoff between the two liked titles" ($roRoom.IsRunoff -and $roRoom.IsVotingActive -and @($roRoom.RunoffItemIds).Count -eq 2) ($roRoom | ConvertTo-Json -Compress)
    Check "the title of the dialog says it is a runoff" ((Js "document.querySelector('.svDialog .formDialogHeaderTitle').innerText") -like "*($($T.Runoff))")
    $roFirst = Js "document.querySelector('#svCard h2').innerText"
    Js "document.querySelector('#svLike').click(); true" | Out-Null
    Check "the second runoff title shows up" ([bool](Wait-Js "document.querySelector('#svCard h2') && document.querySelector('#svCard h2').innerText !== $((ConvertTo-Json $roFirst))" 8))
    $roSecond = Js "document.querySelector('#svCard h2').innerText"
    Js "document.querySelector('#svLike').click(); true" | Out-Null
    Check "after the two titles of the runoff there is nothing left to vote on" ([bool](Wait-Js "!document.querySelector('#svCard h2')" 8))
    # There is no title to vote on, so there is nothing to swipe either: the empty card must not move and get stuck out of place.
    $empty = Js "(function(){ const b=document.querySelector('#svCard .svPosterBox').getBoundingClientRect(); return JSON.stringify({x: Math.round(b.left+b.width/2), y: Math.round(b.top+b.height/2)}) })()" | ConvertFrom-Json
    foreach ($step in @(@("mousePressed", 0), @("mouseMoved", 60), @("mouseMoved", 150), @("mouseReleased", 150))) {
        Send-Cdp "Input.dispatchMouseEvent" @{ type = $step[0]; x = $empty.x + $step[1]; y = $empty.y; button = "left"; buttons = $(if ($step[0] -eq "mouseReleased") { 0 } else { 1 }); clickCount = 1 } | Out-Null
    }
    Start-Sleep -Milliseconds 400
    $emptyState = Js "JSON.stringify({ transform: document.querySelector('#svCard .svPosterBox').style.transform, drag: document.querySelector('#svCard').dataset.drag || '' })" | ConvertFrom-Json
    Check "with nothing left to vote on the card does not follow a swipe" ($emptyState.transform -eq "" -and $emptyState.drag -eq "") ($emptyState | ConvertTo-Json -Compress)
    Check "both titles of the runoff were liked on the server" (@((Call $root GET "/SyncVote/Room/$($room.Id)/Results").Body.LikedItems).Count -eq 2)
    Check "the two cards were the two liked titles" ((@($roFirst, $roSecond) | Sort-Object) -join "|" -eq ((@($res.Body.LikedItems).Name | Sort-Object) -join "|")) "cards: $roFirst | $roSecond"
    Js "document.querySelector('.svEnd').click(); true" | Out-Null
    Check "ending the runoff shows its results" ([bool](Wait-Js "!!document.querySelector('.svRunoff') || !!document.querySelector('.svPlay')" 10))
    Check "the results of the runoff say so in the title" ((Js "document.querySelector('.svDialog .formDialogHeaderTitle').innerText") -like "*($($T.Runoff))")
    Save-Shot "$shots\06b-results-runoff.png"

    Write-Host "== new round ends by itself when the time is up"
    Js "document.querySelector('.svAgain').click(); true" | Out-Null
    Check "new round starts" ([bool](Wait-Js "!!document.querySelector('#svCard h2')" 10))
    $fullRound = (Call $root GET "/SyncVote/Room/$($room.Id)").Body
    $fullCandidates = (Call $root GET "/SyncVote/Room/$($room.Id)/Candidates?limit=1").Body
    Check "a new round is about every title again, not the runoff" (-not $fullRound.IsRunoff -and $fullCandidates.TotalCount -gt 2) "runoff=$($fullRound.IsRunoff) titles=$($fullCandidates.TotalCount)"
    Check "the title of the dialog no longer says runoff" ((Js "document.querySelector('.svDialog .formDialogHeaderTitle').innerText") -notlike "*($($T.Runoff))")
    Js "document.querySelector('#svLike').click(); true" | Out-Null
    Start-Sleep 2
    $auto = Wait-Js "!!document.querySelector('.svPlay')" 70
    Check "results appear without anyone ending the vote" ([bool]$auto)
    if ($modern -and $hasDot) {
        $calmByTime = Wait-Js "($dotColor) !== '$purpleDot' && ($dotColor) !== ''" 10
        Check "the dot is back to normal when the time is up" ([bool]$calmByTime) (Js $dotColor)
    }
    $oneLike = (Call $root GET "/SyncVote/Room/$($room.Id)/Results").Body
    Check "with a single liked title there is no runoff to offer" (-not (Js "!!document.querySelector('.svRunoff')")) "liked on the server: $(@($oneLike.LikedItems).Name -join ', ')"
    Check "the other three buttons are still there" ((Js "document.querySelectorAll('.svDialog .formDialogFooterItem').length") -eq 3) "buttons: $(Js "Array.from(document.querySelectorAll('.svDialog .formDialogFooterItem')).map(b => b.innerText.trim()).join(' | ')")"

    Write-Host "== play the winner"
    Js "document.querySelector('.svPlay').click(); true" | Out-Null
    Start-Sleep 2
    Check "panel closes and a message is shown on top" ((Js "!document.querySelector('.svDialog')") -and (Js "!!document.querySelector('.svToast') && parseInt(getComputedStyle(document.querySelector('.svToast')).zIndex) > 999999"))
    Check "SyncPlay group received the play request" ((Get-Content $logFile | Select-String 'requested Play in group' | Select-Object -Last 1) -ne $null)

    Write-Host "== reopen and close the room"
    if ($ChangeServerLanguage) { Set-ServerLanguage "it-IT"; $T.Close = "Chiudi stanza" }
    Open-SyncPlayMenu
    # In the Material UI menu the entry is ours, not React's: check it answers to the keyboard too.
    if ($modern) { Js "document.querySelector('.svSyncVoteItem').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true})); true" | Out-Null }
    else { Js "document.querySelector('.svSyncVoteItem').click(); true" | Out-Null }
    $again = Wait-Js "!!document.querySelector('.svCloseRoom')" 8
    Check "reopening from the menu shows the room" ([bool]$again)
    Check "the buttons are in the language of the server (picked up without reloading the page)" ((Js "document.querySelector('.svCloseRoom').innerText.trim()") -eq $T.Close) (Js "document.querySelector('.svCloseRoom').innerText")
    Js "document.querySelector('.svCloseRoom').click(); true" | Out-Null
    Start-Sleep 1
    Check "closing the room removes it and the dialog" ((@((Call $root GET "/SyncVote/Rooms").Body).Count -eq 0) -and (Js "!document.querySelector('.svDialog')"))
    if ($modern -and $hasDot) {
        $normal = Wait-Js "($dotColor) !== '$purpleDot' && ($dotColor) !== ''" 10
        Check "with the room closed the dot is back to the color of the web client" ([bool]$normal) (Js $dotColor)
    }

    $errors = $script:console | Where-Object { $_ -match '^\[(error|exception)\]' -and $_ -match 'SyncVote|syncvote' }
    Check "no SyncVote console errors" (-not $errors) ($errors -join " | ")
    $script:console | Where-Object { $_ -match 'SyncVote' } | Select-Object -First 5 | ForEach-Object { Write-Host "      console: $_" }

    # The browser is logged in as an administrator; the room below belongs to somebody else. (After the console check: a refused
    # close is logged on purpose.)
    Write-Host "== an administrator closes a room somebody else organized"
    $svCollection = @((Call $sv GET "/SyncVote/Library/Collections").Body)[0]
    $svRoom = (Call $sv POST "/SyncVote/Room" @{ Name = "Stanza di svtest"; SelectedCollections = @($svCollection.Id); TimeLimit = 2 }).Body
    Check "the other user organized a room in the group" ($svRoom -and $svRoom.OrganizerId -ne $root.UserId) ($svRoom | ConvertTo-Json -Compress)
    Open-SyncPlayMenu
    Js "document.querySelector('.svSyncVoteItem').click(); true" | Out-Null
    $lobbyOfOther = Wait-Js "!!document.querySelector('.svCloseRoom')" 8
    Check "the administrator sees Close room" ([bool]$lobbyOfOther)
    Check "and no Start voting, which is the organizer's" ((Js "!document.querySelector('.svStart')"))
    Save-Shot "$shots\07-admin-lobby.png"
    # A refused close must not look like a success: the dialog stays and says so.
    Js "window.__realFetch = window.fetch; window.fetch = (u, o) => (o && o.method === 'DELETE') ? Promise.resolve(new Response('', { status: 403 })) : window.__realFetch(u, o); true" | Out-Null
    Js "document.querySelector('.svCloseRoom').click(); true" | Out-Null
    Start-Sleep -Milliseconds 800
    # The message is the "could not close" text of the language the server gives the screens now.
    $couldNotClose = (Invoke-RestMethod "$Base/SyncVote/Client/i18n").Strings."msg.errorClosing" | ConvertTo-Json -Compress
    Check "when the server refuses, the dialog stays open and a message says why" ((Js "!!document.querySelector('.svDialog')") -and (Js "Array.from(document.querySelectorAll('.svToast')).some(t => t.innerText.indexOf($couldNotClose) !== -1)") -and @((Call $root GET "/SyncVote/Rooms").Body).Count -eq 1)
    Js "window.fetch = window.__realFetch; document.querySelector('.svCloseRoom').click(); true" | Out-Null
    Start-Sleep 1
    Check "closing it for real removes the room and the dialog" ((@((Call $root GET "/SyncVote/Rooms").Body).Count -eq 0) -and (Js "!document.querySelector('.svDialog')"))

    # The organizer of a room with a code: the options in the create form, and the code in front of them all the time.
    Write-Host "== room code: the organizer"
    Open-SyncPlayMenu
    Js "document.querySelector('.svSyncVoteItem').click(); true" | Out-Null
    Check "the create form asks whether the room needs a code, and the validity is hidden until it does" ((Wait-Js "!!document.querySelector('#svRequireCode')" 10) -and (Js "getComputedStyle(document.querySelector('#svCodeScopeBox')).display === 'none'"))
    Js "document.querySelector('#svRequireCode').click(); true" | Out-Null
    Check "ticking it offers how long the code lasts (the whole SyncPlay session, or one round)" ((Js "getComputedStyle(document.querySelector('#svCodeScopeBox')).display !== 'none'") -and (Js "document.querySelectorAll('#svCodeScope option').length") -eq 2)
    Save-Shot "$shots\09-create-code.png"
    Js "document.querySelector('#svRoomName').value='Con codice'; document.querySelector('.svCreate').click(); true" | Out-Null
    Check "the lobby shows the code, big, to the organizer" ([bool](Wait-Js "!!document.querySelector('#svCodeBig')" 10))
    $chipText = Js "document.querySelector('.svCode .svCodeText').innerText"
    $apiCode = ((Call $root GET "/SyncVote/Rooms").Body | Where-Object Name -eq "Con codice").Code
    Check "the code in the header is the code of the server, in two groups of three" ($chipText -match '^\d{3} \d{3}$' -and ($chipText -replace ' ', '') -eq $apiCode) "header '$chipText', server '$apiCode'"
    Check "the big one is the same" ((Js "document.querySelector('#svCodeBig').innerText") -eq $chipText)
    # A new code, when the code got to somebody who should not have it: asked first, and only then done.
    Check "next to the code there is a button for a new one" ([bool](Js "!!document.querySelector('.svCodeRenew')"))
    Js "document.querySelector('.svCodeRenew').click(); true" | Out-Null
    Check "it asks before doing anything" ([bool](Js "!!document.querySelector('.svCodeAsk') && !!document.querySelector('.svCodeYes') && !!document.querySelector('.svCodeNo')"))
    Save-Shot "$shots\09-code-ask.png"
    Js "document.querySelector('.svCodeNo').click(); true" | Out-Null
    Check "saying no leaves the code as it was" ((Js "document.querySelector('.svCode .svCodeText').innerText") -eq $chipText -and ((Call $root GET "/SyncVote/Rooms").Body | Where-Object Name -eq "Con codice").Code -eq $apiCode)
    Js "document.querySelector('.svCodeRenew').click(); document.querySelector('.svCodeYes').click(); true" | Out-Null
    $newText = Wait-Js "document.querySelector('.svCode') && document.querySelector('.svCode .svCodeText').innerText !== '$chipText' && document.querySelector('.svCode .svCodeText').innerText" 8
    $apiNew = ((Call $root GET "/SyncVote/Rooms").Body | Where-Object Name -eq "Con codice").Code
    Check "saying yes makes a new code, in the header and in the lobby, the same as the server's" ($newText -match '^\d{3} \d{3}$' -and ($newText -replace ' ', '') -eq $apiNew -and $apiNew -ne $apiCode -and (Js "document.querySelector('#svCodeBig').innerText") -eq $newText) "was $chipText, now $newText, server $apiNew"
    $chipText = $newText; $apiCode = $apiNew
    Save-Shot "$shots\09-lobby-code.png"
    Js "document.querySelector('.svCode').click(); true" | Out-Null
    Check "clicking the code copies it and says so" ([bool](Wait-Js "!!document.querySelector('.svToast')" 3))
    Js "document.querySelector('.svStart').click(); true" | Out-Null
    Wait-Js "!!document.querySelector('#svCard h2')" 10 | Out-Null
    Check "while voting the code is still in the header, beside the end-voting icon and not on it" ([bool](Js "(function(){ const a = document.querySelector('.svCode'), b = document.querySelector('.svEnd'); if (!a || !b) return false; const x = a.getBoundingClientRect(), y = b.getBoundingClientRect(); return x.width > 0 && y.width > 0 && x.right <= y.left + 1 })()"))
    # A new code while voting: the code and the stop icon keep their places (the icon stays at the far edge, after the code).
    Js "document.querySelector('.svCodeRenew').click(); document.querySelector('.svCodeYes').click(); true" | Out-Null
    Wait-Js "document.querySelector('.svCode') && document.querySelector('.svCode .svCodeText').innerText !== '$chipText'" 8 | Out-Null
    $placed = Js "(function(){ const h = document.querySelector('.svDialog .formDialogHeader').getBoundingClientRect(), a = document.querySelector('.svCodeTools').getBoundingClientRect(), b = document.querySelector('.svEnd').getBoundingClientRect(); return JSON.stringify({ codeBeforeStop: a.right <= b.left + 1, stopAtTheEdge: b.right >= h.right - 40, codeAtTheEdge: a.right >= b.left - 20 }) })()" | ConvertFrom-Json
    Check "after a new code the stop icon is still at the far edge, with the code right before it" ($placed.codeBeforeStop -and $placed.stopAtTheEdge -and $placed.codeAtTheEdge) ($placed | ConvertTo-Json -Compress)
    Save-Shot "$shots\09-code-renewed-voting.png"
    Js "document.querySelector('.svEnd').click(); true" | Out-Null
    Wait-Js "!!document.querySelector('.svPlay') || !!document.querySelector('.svCloseRoom')" 10 | Out-Null
    Check "and with the results" ([bool](Js "!!document.querySelector('.svCode .svCodeText')"))
    Check "the results come up for the organizer" ([bool](Wait-Js "!!document.querySelector('.svCloseRoom')" 10))
    Js "document.querySelector('.svCloseRoom').click(); true" | Out-Null
    Start-Sleep 1
    if ($modern) {
        # The Material UI menu stays in the page (keepMounted) and React rebuilds its entries when the state of the group changes; the
        # SyncVote entry is not React's, so it has to be put back in place each time (and taken away when there is no group).
        Write-Host "== the menu entry follows the state of the group"
        Call $sv POST "/SyncPlay/Leave" | Out-Null
        $menuOrder = "(function(){ const l = document.querySelector('#app-sync-play-menu ul[role=menu]'); if (!l) return JSON.stringify({ none: true }); const k = Array.from(l.children); const i = k.findIndex(c => c.classList.contains('svSyncVoteItem')); const native = k.findIndex(c => c.matches('li[role=menuitem]') && !c.classList.contains('svSyncVoteItem')); return JSON.stringify({ count: k.filter(c => c.classList.contains('svSyncVoteItem')).length, after: i > 0 ? k[i - 1].tagName : null, beforeNative: native < 0 || i + 1 === native, total: document.querySelectorAll('.svSyncVoteItem').length }) })()"
        $closeMenu = "(function(){ const b = document.querySelector('#app-sync-play-menu .MuiBackdrop-root'); if (b) b.click(); return true })()"
        # Starting a new group leaves the current one: the header of the menu is rebuilt each time.
        foreach ($n in 1..3) {
            Js "ApiClient.ajax({type:'POST', url: ApiClient.getUrl('SyncPlay/New'), data: JSON.stringify({GroupName:'switch-$n'}), contentType:'application/json'}).then(()=>true)" | Out-Null
            Start-Sleep 2
            Open-SyncPlayMenu
            $order = Js $menuOrder | ConvertFrom-Json
            # Under the header of the group (a header and a divider in 12, a header in 10.x) and right in front of the native entries.
            Check "group change $n of 3: the entry is under the header of the group, in front of the native ones" ($order.count -eq 1 -and $order.after -in "HR", "DIV" -and $order.beforeNative) ($order | ConvertTo-Json -Compress)
            Js $closeMenu | Out-Null
            Start-Sleep -Milliseconds 700
        }
        Save-Shot "$shots\08-menu-other-group.png"
        Js "ApiClient.ajax({type:'POST', url: ApiClient.getUrl('SyncPlay/Leave')}).then(()=>true)" | Out-Null
        Start-Sleep 2
        Open-SyncPlayMenu
        Check "outside any group the menu has no SyncVote entry" ((Js "document.querySelectorAll('.svSyncVoteItem').length") -eq 0) (Js $menuOrder)
        Save-Shot "$shots\08-menu-no-group.png"
        Js $closeMenu | Out-Null
        Start-Sleep -Milliseconds 700
        Call $sv POST "/SyncPlay/Leave" | Out-Null
    }

    # Somebody who is not an administrator and is not given the code: the browser logs in as svtest.
    Write-Host "== room code: somebody who is asked for it"
    $codeCollection = @((Call $root GET "/SyncVote/Library/Collections").Body)[0]
    # The plugin finds the group of a user by their name among the people in it, so the browser of root has to be out of its
    # group too, or the room made below would land there.
    Js "ApiClient.ajax({type:'POST', url: ApiClient.getUrl('SyncPlay/Leave')}).then(()=>true)" | Out-Null
    Start-Sleep 1
    Call $root POST "/SyncPlay/Leave" | Out-Null
    Call $sv POST "/SyncPlay/Leave" | Out-Null
    Call $root POST "/SyncPlay/New" @{ GroupName = "code-group" } | Out-Null
    $codeGroup = (Call $root GET "/SyncPlay/List").Body | Where-Object GroupName -eq "code-group" | Select-Object -First 1 -ExpandProperty GroupId
    $roomA = (Call $root POST "/SyncVote/Room" @{ Name = "Stanza A"; TimeLimit = 3; SelectedCollections = @($codeCollection.Id); RequireCode = $true; CodeScope = "Round" }).Body
    Js "localStorage.clear(); sessionStorage.clear(); true" | Out-Null
    foreach ($round in 1, 2) {
        Send-Cdp "Page.navigate" @{ url = "$Base/web/index.html" } | Out-Null
        Wait-Js "!!document.querySelector('#txtManualName')" 25 | Out-Null
        if ($round -eq 1 -and $null -ne $layoutValue) { Js $(if ($layoutValue) { "localStorage.setItem('layout', '$layoutValue'); true" } else { "localStorage.removeItem('layout'); true" }) | Out-Null }
    }
    Js "(function(){ const n=document.querySelector('#txtManualName'); const p=document.querySelector('#txtManualPassword'); n.value='svtest'; p.value='svtest-pw'; document.querySelector('.manualLoginForm').dispatchEvent(new Event('submit',{cancelable:true,bubbles:true})); return true })()" | Out-Null
    Check "the browser is logged in as an ordinary user" ([bool](Wait-Js "!!window.__syncVoteManager && !!window.ApiClient && !!ApiClient.accessToken()" 25))
    Start-Sleep 3
    Js "ApiClient.ajax({type:'POST', url: ApiClient.getUrl('SyncPlay/Join'), data: JSON.stringify({GroupId:'$codeGroup'}), contentType:'application/json'}).then(()=>true)" | Out-Null
    # The server knows the browser is in the group once it says so.
    $inCodeGroup = "ApiClient.ajax({type:'GET', url: ApiClient.getUrl('SyncVote/SyncPlayInfo'), dataType:'json'}).then(r => (r.GroupId || '').toLowerCase() === '$(([guid]$codeGroup).ToString('N'))')"
    Check "the browser is in the SyncPlay group of the room" ([bool](Wait-Js $inCodeGroup 20))
    $wrongUi ="{0:D6}" -f (([int]$roomA.Code + 1) % 1000000)
    $tryCode = { param($digits) Js "(function(){ const i = document.querySelector('#svCodeInput'); i.value = '$digits'; document.querySelector('.svEnterCode').click(); return true })()" | Out-Null; Wait-Js "!document.querySelector('.svEnterCode') || !document.querySelector('.svEnterCode').disabled" 8 | Out-Null; Start-Sleep -Milliseconds 300 }

    Js "window.SyncVote.open(); true" | Out-Null
    $promptUp = [bool](Wait-Js "!!document.querySelector('#svCodeInput') && !!document.querySelector('.svEnterCode')" 10)
    $why = if ($promptUp) { "" } else { "page: " + (Js "(document.querySelector('.svDialog') || document.body).innerText.replace(/\s+/g, ' ').slice(0, 220)") + " | syncplay: " + (Js "ApiClient.ajax({type:'GET', url: ApiClient.getUrl('SyncVote/SyncPlayInfo'), dataType:'json'}).then(r => JSON.stringify(r))") + " | rooms: " + (Js "ApiClient.ajax({type:'GET', url: ApiClient.getUrl('SyncVote/Rooms'), dataType:'json'}).then(r => JSON.stringify(r.map(x => [x.Name, x.RequiresCode, x.SyncPlayGroupId])))") }
    Check "opening a room that asks for a code shows the code screen, not the room" $promptUp $why
    Check "it names the room and the code is nowhere on the page" ((Js "document.querySelector('.svDialog .formDialogHeaderTitle').innerText") -like "*Stanza A*" -and -not (Js "document.body.innerText.replace(/\s/g, '').includes('$($roomA.Code)')"))
    Save-Shot "$shots\10-code-prompt.png"
    & $tryCode ""
    $emptyMsg = Js "document.querySelector('#svCodeError').innerText"
    Check "an empty code is told to be typed" ($emptyMsg.Length -gt 3 -and (Js "getComputedStyle(document.querySelector('#svCodeError')).display !== 'none'"))
    & $tryCode $wrongUi
    $wrongMsg = Js "document.querySelector('#svCodeError').innerText"
    Check "a wrong code is refused with its own message, and the screen stays" ($wrongMsg.Length -gt 3 -and $wrongMsg -ne $emptyMsg -and [bool](Js "!!document.querySelector('#svCodeInput')"))
    Save-Shot "$shots\10-code-wrong.png"
    foreach ($i in 1..6) { & $tryCode $wrongUi }
    & $tryCode $roomA.Code
    $lockedMsg = Js "document.querySelector('#svCodeError').innerText"
    Check "after seven wrong codes the screen says to wait, with the seconds, even for the right code" ($lockedMsg -match '\d+' -and $lockedMsg -ne $wrongMsg -and [bool](Js "!!document.querySelector('#svCodeInput')")) $lockedMsg
    Save-Shot "$shots\10-code-locked.png"

    # A new room (another code, no wait): the right code, typed with a space, gets in.
    Call $root DELETE "/SyncVote/Room/$($roomA.Id)" | Out-Null
    Check "when the room is closed the screen goes away" ([bool](Wait-Js "!document.querySelector('.svDialog')" 10))
    $roomB = (Call $root POST "/SyncVote/Room" @{ Name = "Stanza B"; TimeLimit = 3; SelectedCollections = @($codeCollection.Id); RequireCode = $true; CodeScope = "Round" }).Body
    Js "window.SyncVote.open(); true" | Out-Null
    Wait-Js "!!document.querySelector('#svCodeInput')" 10 | Out-Null
    & $tryCode ($roomB.Code.Insert(3, " "))
    Check "the right code gets in: the lobby, without the code on it" ([bool](Wait-Js "!!document.querySelector('#svLobbyMembers')" 10) -and -not (Js "!!document.querySelector('.svCode') || !!document.querySelector('#svCodeBig')") -and -not (Js "document.body.innerText.replace(/\s/g, '').includes('$($roomB.Code)')"))
    Check "the server counts them as a member" (@((Call $root GET "/SyncVote/Room/$($roomB.Id)").Body.MemberIds) -contains $sv.UserId)

    # A code works at any time: while the round runs, the voting card is there and a vote counts.
    Call $root POST "/SyncVote/Room/$($roomB.Id)/StartVoting" | Out-Null
    Check "the voting starts for them" ([bool](Wait-Js "!!document.querySelector('#svCard h2')" 10))
    Js "document.querySelector('#svLike').click(); true" | Out-Null
    Check "and their vote counts" ([bool](Wait-Js "document.querySelector('#svVotesCount').innerText.startsWith('1 ')" 8))

    # The organizer makes a new code (it leaked): they are out of the room and have to type the new one.
    $renewedCode = (Call $root POST "/SyncVote/Room/$($roomB.Id)/NewCode").Body.Code
    Check "after a new code the screen asks for it again, by itself" ([bool](Wait-Js "!!document.querySelector('#svCodeInput')" 12))
    & $tryCode $roomB.Code
    Check "the code they used before is refused" ([bool](Js "!!document.querySelector('#svCodeInput')"))
    & $tryCode $renewedCode
    Check "the new one lets them back in" ([bool](Wait-Js "!!document.querySelector('#svCard h2')" 10))

    # A code for each round: the next round has a new code and they have to type it to vote again.
    Call $root POST "/SyncVote/Room/$($roomB.Id)/EndVoting" | Out-Null
    $next = (Call $root POST "/SyncVote/Room/$($roomB.Id)/StartVoting").Body
    Check "the next round has a new code" ($next.Code -ne $renewedCode -and $next.Code -match '^\d{6}$')
    Check "and the screen asks for it again, by itself" ([bool](Wait-Js "!!document.querySelector('#svCodeInput')" 12))
    & $tryCode $roomB.Code
    Check "the old code is not good any more" ([bool](Js "!!document.querySelector('#svCodeInput')"))
    & $tryCode $next.Code
    Check "the new one is, and they are voting again" ([bool](Wait-Js "!!document.querySelector('#svCard h2')" 10))
    Call $root DELETE "/SyncVote/Room/$($roomB.Id)" | Out-Null
    Call $root POST "/SyncPlay/Leave" | Out-Null
}
finally {
    Stop-Chrome
    if ($ChangeServerLanguage) { Invoke-RestMethod "$Base/System/Configuration" -Method Post -Headers $root.Headers -ContentType "application/json" -Body ($serverConfig | ConvertTo-Json -Depth 10) | Out-Null }
    Invoke-RestMethod "$Base/Users/$($created.Id)" -Method Delete -Headers $root.Headers | Out-Null
    Write-Host "temporary user removed"
}

if ($script:fail -eq 0) { Write-Host "ALL UI CHECKS PASSED" -ForegroundColor Green } else { Write-Host "$($script:fail) UI CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
