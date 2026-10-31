<#
.SYNOPSIS
    Tests the plugin options (admin page, permissions, limits, private rooms, web client injection switch).
    Restores the configuration it changes.
#>
param([string]$Base = "http://127.0.0.1:8096", [string]$AdminUser = "root", [string]$AdminPassword = "root", [switch]$ChangeServerLanguage, [string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) "syncvote-e2e"))

. "$PSScriptRoot\lib\jf.ps1" -Base $Base
. "$PSScriptRoot\lib\cdp.ps1"
New-Item -ItemType Directory -Force $OutDir | Out-Null

$script:fail = 0
function Check($name, $cond, $detail = "") {
    if ($cond) { Write-Host "PASS  $name" -ForegroundColor Green } else { Write-Host "FAIL  $name  $detail" -ForegroundColor Red; $script:fail++ }
}

$pluginId = "6bfde2dd-8211-4964-b86d-7812a9de160b"
$root = Login $AdminUser $AdminPassword "cfg-device"
$existing = Invoke-RestMethod "$Base/Users" -Headers $root.Headers | Where-Object Name -eq "svtest"
if ($existing) { Invoke-RestMethod "$Base/Users/$($existing.Id)" -Method Delete -Headers $root.Headers | Out-Null }
$created = Invoke-RestMethod "$Base/Users/New" -Method Post -Headers $root.Headers -ContentType "application/json" -Body (@{ Name = "svtest"; Password = "svtest-pw" } | ConvertTo-Json)
$sv = Login "svtest" "svtest-pw" "cfg-dev2"
$original = Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Headers $root.Headers
$serverConfig = Invoke-RestMethod "$Base/System/Configuration" -Headers $root.Headers
function Set-ServerLanguage($culture) {
    $cfg = Invoke-RestMethod "$Base/System/Configuration" -Headers $root.Headers
    $cfg.UICulture = $culture
    Invoke-RestMethod "$Base/System/Configuration" -Method Post -Headers $root.Headers -ContentType "application/json" -Body ($cfg | ConvertTo-Json -Depth 10) | Out-Null
}
function Get-Strings { Invoke-RestMethod "$Base/SyncVote/Client/i18n" }   # anonymous on purpose

function Set-Config($changes) {
    $cfg = Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Headers $root.Headers
    foreach ($k in $changes.Keys) { $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $changes[$k] -Force }
    Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Method Post -Headers $root.Headers -ContentType "application/json" -Body ($cfg | ConvertTo-Json -Depth 6) | Out-Null
}

try {
    Write-Host "== defaults"
    Check "defaults are as documented" ($original.DefaultTimeLimit -ge 1 -and $original.InjectWebClient -eq $true -and $original.DefaultCanOrganize -eq $true -and $original.DefaultCanVote -eq $true -and $original.WrongCodeAttempts -eq 7) ($original | ConvertTo-Json -Compress)

    # These steps switch the display language of the SERVER for a moment: only with -ChangeServerLanguage, on a server nobody is using.
    if ($ChangeServerLanguage) {
    Write-Host "== language"
    Set-Config @{ Language = "Auto" }
    Set-ServerLanguage "it-IT"
    $r = Get-Strings
    Check "server in Italian -> Italian strings" ($r.Language -eq "it" -and $r.Strings."btn.createRoom" -eq "Crea stanza") "$($r.Language) / $($r.Strings.'btn.createRoom')"
    Set-ServerLanguage "en-US"
    $r = Get-Strings
    Check "server in English -> English strings" ($r.Language -eq "en" -and $r.Strings."btn.createRoom" -eq "Create room")
    Set-ServerLanguage "fr-FR"
    $r = Get-Strings
    Check "a language without translation falls back to English" ($r.Language -eq "en" -and $r.Strings."btn.createRoom" -eq "Create room")
    Check "the list of languages is offered" (@($r.Available) -contains "en" -and @($r.Available) -contains "it")
    Set-Config @{ Language = "it" }
    Set-ServerLanguage "en-US"
    $r = Get-Strings
    Check "the plugin option wins over the server" ($r.Language -eq "it" -and $r.Strings."btn.createRoom" -eq "Crea stanza")
    Set-Config @{ Language = "klingon" }
    $r = Get-Strings
    Check "an unknown option value follows the server" ($r.Language -eq "en")
    Set-Config @{ Language = "Auto" }
    Set-ServerLanguage "it"
    $r = Get-Strings
    Check "a bare language code works too" ($r.Language -eq "it")
    Check "every key of English exists in Italian" (@($r.Strings.PSObject.Properties).Count -ge 60)
    }
    else {
        $r = Get-Strings
        Check "the plugin serves the language of the server" ($r.Language -in @($r.Available) -and $r.Strings."btn.createRoom") "language $($r.Language)"
    }

    Write-Host "== web client injection switch"
    Set-Config @{ InjectWebClient = $false }
    $html = (Invoke-WebRequest "$Base/web/index.html" -Headers @{ "Cache-Control" = "no-cache" }).Content
    Check "InjectWebClient=false leaves index.html untouched" ($html -notmatch "SyncVote")
    Set-Config @{ InjectWebClient = $true }
    $html = (Invoke-WebRequest "$Base/web/index.html" -Headers @{ "Cache-Control" = "no-cache" }).Content
    Check "InjectWebClient=true injects again, no restart needed" ($html -match "SyncVote/Client/syncvote\.js")

    Write-Host "== permissions"
    $col = @((Call $sv GET "/SyncVote/Library/Collections").Body)[0]
    $body = @{ Name = "perm"; SelectedCollections = @($col.Id) }
    Set-Config @{ DefaultCanOrganize = $false }
    $p = Call $sv GET "/SyncVote/Permissions"
    Check "permissions endpoint reflects the default" ($p.Body.CanOrganize -eq $false -and $p.Body.CanVote -eq $true)
    $r = Call $sv POST "/SyncVote/Room" $body
    Check "user without permission cannot organize" ($r.Status -eq 403) "status $($r.Status)"
    $r = Call $root POST "/SyncVote/Room" $body
    Check "administrator still can" ($r.Status -eq 200) "status $($r.Status)"
    if ($r.Status -eq 200) { Call $root DELETE "/SyncVote/Room/$($r.Body.Id)" | Out-Null }
    Set-Config @{ UserPermissionOverrides = @(@{ UserId = $sv.UserId; CanOrganize = $true; CanVote = $true }) }
    $r = Call $sv POST "/SyncVote/Room" $body
    Check "per-user override allows organizing" ($r.Status -eq 200) "status $($r.Status) $($r.Body | ConvertTo-Json -Compress)"
    if ($r.Status -eq 200) { Call $sv DELETE "/SyncVote/Room/$($r.Body.Id)" | Out-Null }
    Set-Config @{ DefaultCanOrganize = $true; DefaultCanVote = $false; UserPermissionOverrides = @() }
    $v = Call $sv POST "/SyncVote/Vote" @{ RoomId = [guid]::NewGuid(); ItemId = [guid]::NewGuid(); IsLike = $true }
    Check "user who cannot vote is refused before anything else" ($v.Status -eq 403) "status $($v.Status)"
    Set-Config @{ DefaultCanVote = $true }

    # An exception names only what it changes: the other permission keeps following the default.
    Set-Config @{ DefaultCanOrganize = $true; DefaultCanVote = $true; UserPermissionOverrides = @(@{ UserId = $sv.UserId; CanVote = $false }) }
    $p = Call $sv GET "/SyncVote/Permissions"
    Check "an exception on voting leaves organizing at the default (true)" ($p.Body.CanOrganize -eq $true -and $p.Body.CanVote -eq $false) ($p.Body | ConvertTo-Json -Compress)
    Set-Config @{ DefaultCanOrganize = $false }
    $p = Call $sv GET "/SyncVote/Permissions"
    Check "...and follows it when the default changes (false), the exception stays" ($p.Body.CanOrganize -eq $false -and $p.Body.CanVote -eq $false) ($p.Body | ConvertTo-Json -Compress)
    $v = Call $sv POST "/SyncVote/Vote" @{ RoomId = [guid]::NewGuid(); ItemId = [guid]::NewGuid(); IsLike = $true }
    Check "the exception on voting is enforced (403)" ($v.Status -eq 403) "status $($v.Status)"
    $r = Call $root GET "/SyncVote/Permissions?userId=$($sv.UserId)"
    Check "an administrator can read the permissions of another user" ($r.Status -eq 200 -and $r.Body.CanVote -eq $false) "status $($r.Status)"
    Set-Config @{ DefaultCanOrganize = $true; UserPermissionOverrides = @() }

    Write-Host "== max members"
    Set-Config @{ MaxRoomMembers = 1 }
    $r = Call $root POST "/SyncVote/Room" $body
    $j = Call $sv POST "/SyncVote/Room/$($r.Body.Id)/Join"
    Check "a full room refuses new members" ($j.Status -eq 409) "status $($j.Status)"
    Call $root DELETE "/SyncVote/Room/$($r.Body.Id)" | Out-Null
    Set-Config @{ MaxRoomMembers = 10 }

    Write-Host "== wrong room codes"
    Set-Config @{ WrongCodeAttempts = 2 }
    $coded = Call $root POST "/SyncVote/Room" @{ Name = "code"; SelectedCollections = @($col.Id); RequireCode = $true }
    $wrongCode = "{0:D6}" -f (([int]$coded.Body.Code + 1) % 1000000)
    $t1 = Call $sv POST "/SyncVote/Room/$($coded.Body.Id)/Join" @{ Code = $wrongCode }
    $t2 = Call $sv POST "/SyncVote/Room/$($coded.Body.Id)/Join" @{ Code = $wrongCode }
    $t3 = Call $sv POST "/SyncVote/Room/$($coded.Body.Id)/Join" @{ Code = $coded.Body.Code }
    Check "the number of wrong codes is the one of the settings (2: then even the right code waits)" ($t1.Status -eq 403 -and $t2.Status -eq 403 -and $t3.Status -eq 429) "statuses $($t1.Status), $($t2.Status), $($t3.Status)"
    Call $root DELETE "/SyncVote/Room/$($coded.Body.Id)" | Out-Null
    Set-Config @{ WrongCodeAttempts = 7 }
    $coded = Call $root POST "/SyncVote/Room" @{ Name = "code7"; SelectedCollections = @($col.Id); RequireCode = $true }
    $wrongCode = "{0:D6}" -f (([int]$coded.Body.Code + 1) % 1000000)
    $tries = 1..6 | ForEach-Object { (Call $sv POST "/SyncVote/Room/$($coded.Body.Id)/Join" @{ Code = $wrongCode }).Status }
    $ok = Call $sv POST "/SyncVote/Room/$($coded.Body.Id)/Join" @{ Code = $coded.Body.Code }
    Check "with the default (7) six mistakes are not enough to wait" (@($tries | Where-Object { $_ -ne 403 }).Count -eq 0 -and $ok.Status -eq 200) "statuses $($tries -join ','), then $($ok.Status)"
    Call $root DELETE "/SyncVote/Room/$($coded.Body.Id)" | Out-Null

    Write-Host "== private rooms"
    Set-Config @{ AllowPublicRooms = $false }
    $r = Call $root POST "/SyncVote/Room" $body
    $list = Call $sv GET "/SyncVote/Rooms"
    Check "AllowPublicRooms=false hides rooms of other groups" (@($list.Body).Count -eq 0) "count $(@($list.Body).Count)"
    $get = Call $sv GET "/SyncVote/Room/$($r.Body.Id)"
    Check "...and their details" ($get.Status -eq 404) "status $($get.Status)"
    $adm = Call $root GET "/SyncVote/Rooms"
    Check "the organizer still sees their own room" (@($adm.Body).Count -eq 1)
    Call $root DELETE "/SyncVote/Room/$($r.Body.Id)" | Out-Null
    Set-Config @{ AllowPublicRooms = $true }

    Write-Host "== admin page"
    Start-Chrome "$OutDir\e2e-chrome-profile"
    Send-Cdp "Page.navigate" @{ url = "$Base/web/index.html" } | Out-Null
    Wait-Js "!!document.querySelector('#txtManualName')" 25 | Out-Null
    Js "(function(){ const n=document.querySelector('#txtManualName'); const p=document.querySelector('#txtManualPassword'); n.value='$AdminUser'; p.value='$AdminPassword'; document.querySelector('.manualLoginForm').dispatchEvent(new Event('submit',{cancelable:true,bubbles:true})); return true })()" | Out-Null
    Wait-Js "!!window.ApiClient && !!ApiClient.accessToken()" 25 | Out-Null
    Start-Sleep 2
    if ($ChangeServerLanguage) { Set-ServerLanguage "it-IT"; Start-Sleep 2 }
    Js "location.hash = '#/configurationpage?name=SyncVote'; true" | Out-Null
    $form = Wait-Js "!!document.querySelector('#SyncVoteConfigForm') && document.querySelector('#MaxRoomMembers').value !== ''" 15
    Check "config page opens and shows the saved values" ([bool]$form)
    Check "config page lists the new options" ((Js "!!document.querySelector('#InjectWebClient') && !!document.querySelector('#DefaultCanOrganize') && !!document.querySelector('#DefaultCanVote')"))
    if ($ChangeServerLanguage) { Check "the settings page follows the server language (Italian)" ((Js "document.querySelector('#SyncVoteConfigForm').innerText.includes('Tempo limite predefinito')")) }
    Check "config page labels are translated (no raw keys)" (-not (Js "/config\.|btn\.save/.test(document.querySelector('#SyncVoteConfigForm').innerText)"))
    # The settings of the General tab are saved as they change, with no button.
    Check "General has no Save button, Save and Cancel are on the Permissions tab" ((Js "!document.querySelector('[data-panel=general] button[type=submit]') && !!document.querySelector('[data-panel=permissions] #SyncVoteSave') && !!document.querySelector('[data-panel=permissions] #SyncVoteCancel')"))
    Js "document.querySelector('#MaxRoomMembers').value = '7'; document.querySelector('#MaxRoomMembers').dispatchEvent(new Event('change', {bubbles:true})); true" | Out-Null
    Start-Sleep 1
    $saved = Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Headers $root.Headers
    Check "a number changed on General is saved right away" ($saved.MaxRoomMembers -eq 7) ($saved | ConvertTo-Json -Compress)
    Js "document.querySelector('#WrongCodeAttempts').value = '3'; document.querySelector('#WrongCodeAttempts').dispatchEvent(new Event('change', {bubbles:true})); true" | Out-Null
    Js "var c = document.querySelector('#InjectWebClient'); c.checked = false; c.dispatchEvent(new Event('change', {bubbles:true})); true" | Out-Null
    Js "document.querySelector('#MaxRoomMembers').value = '999'; document.querySelector('#MaxRoomMembers').dispatchEvent(new Event('change', {bubbles:true})); true" | Out-Null
    Start-Sleep 1.5
    $saved = Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Headers $root.Headers
    Check "a checkbox and another number too, and a number out of range is brought back to the limit (50)" ($saved.WrongCodeAttempts -eq 3 -and $saved.InjectWebClient -eq $false -and $saved.MaxRoomMembers -eq 50 -and (Js "document.querySelector('#MaxRoomMembers').value") -eq "50") ($saved | ConvertTo-Json -Compress)
    Js "document.querySelector('#MaxRoomMembers').value = '7'; document.querySelector('#MaxRoomMembers').dispatchEvent(new Event('change', {bubbles:true})); true" | Out-Null
    Start-Sleep 1
    Check "Save and Cancel are off while nothing about the permissions changed" ((Js "document.querySelector('#SyncVoteSave').disabled && document.querySelector('#SyncVoteCancel').disabled"))

    Write-Host "== admin page: tabs and permissions per user"
    function Get-Overrides { @((Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Headers $root.Headers).UserPermissionOverrides) }
    function Same-User($a, $b) { ([string]$a -replace '-', '') -eq ([string]$b -replace '-', '') }
    function Open-ConfigPage {
        Js "location.hash = '#/home'; true" | Out-Null
        Start-Sleep -Milliseconds 800
        Js "location.hash = '#/configurationpage?name=SyncVote'; true" | Out-Null
        # The page stays in the DOM between visits: wait for this visit's load, not for the rows of the last one.
        Wait-Js "!!document.querySelector('#SyncVoteConfigPage[data-loaded]')" 15 | Out-Null
    }    # The two boxes (organize, vote) of the row that shows $name, or $null.
    function Get-Row($name) {
        $json = Js "(function(){ var tr = Array.from(document.querySelectorAll('#UserRows tr')).find(function (r) { return r.textContent.indexOf('$name') !== -1 }); if (!tr) return null; var b = tr.querySelectorAll('input[type=checkbox]'); return JSON.stringify({ org: b[0].checked, vote: b[1].checked, disabled: b[0].disabled && b[1].disabled, text: tr.textContent.trim() }) })()"
        if ($json) { $json | ConvertFrom-Json } else { $null }
    }
    function Click-Box($name, $col) { Js "(function(){ var tr = Array.from(document.querySelectorAll('#UserRows tr')).find(function (r) { return r.textContent.indexOf('$name') !== -1 }); tr.querySelectorAll('input[type=checkbox]')[$col].click(); return true })()" | Out-Null }
    function Save-Page { Js "document.querySelector('#SyncVoteSave').click(); true" | Out-Null; Start-Sleep 2 }
    function Buttons { Js "JSON.stringify({ save: !document.querySelector('#SyncVoteSave').disabled, cancel: !document.querySelector('#SyncVoteCancel').disabled })" | ConvertFrom-Json }

    # A user that does not exist (any more) with an exception, and one real user with an exception on voting only.
    $ghost = [guid]::NewGuid()
    Set-Config @{ DefaultCanOrganize = $true; DefaultCanVote = $true; UserPermissionOverrides = @(@{ UserId = $sv.UserId; CanVote = $false }, @{ UserId = $ghost; CanOrganize = $false }) }
    Open-ConfigPage

    Check "the General tab is shown first" ((Js "!document.querySelector('[data-panel=general]').hidden && document.querySelector('[data-panel=permissions]').hidden"))
    Check "the settings moved to the Permissions tab are not on General" ((Js "!document.querySelector('[data-panel=general] #AllowPublicRooms') && !document.querySelector('[data-panel=general] #DefaultCanVote')"))
    Js "document.querySelector('[data-tab=permissions]').click(); true" | Out-Null
    Check "the Permissions tab shows its panel and hides General" ((Js "document.querySelector('[data-panel=general]').hidden && !document.querySelector('[data-panel=permissions]').hidden && document.querySelector('[data-tab=permissions]').classList.contains('active')"))
    Check "the three settings are on the Permissions tab" ((Js "['AllowPublicRooms','DefaultCanOrganize','DefaultCanVote'].every(function (id) { return !!document.querySelector('[data-panel=permissions] #' + id) })"))
    Check "the table is collapsed until opened" (-not (Js "document.querySelector('#UserPermissionsBox').open"))
    Js "document.querySelector('#UserPermissionsBox').open = true; true" | Out-Null
    Save-Shot "$OutDir\config-permissions.png"

    $row = Get-Row "svtest"
    Check "a user with an exception on voting: organize at the default (ticked), vote cleared" ($row -and $row.org -eq $true -and $row.vote -eq $false) ($row | ConvertTo-Json -Compress)
    $row = Get-Row "root"
    Check "an administrator is ticked, locked and marked" ($row -and $row.org -and $row.vote -and $row.disabled -and $row.text -match "Administrator|Amministratore") ($row | ConvertTo-Json -Compress)
    $row = Get-Row $ghost.ToString().Substring(0, 8)
    Check "a deleted user is listed with the start of the id, not the whole one" ($row -and $row.org -eq $false -and $row.vote -eq $true -and $row.text -notmatch $ghost.ToString()) ($row | ConvertTo-Json -Compress)
    Check "the count of users with exceptions is shown" ((Js "document.querySelector('#UserPermissionsCount').textContent.indexOf('2') !== -1")) (Js "document.querySelector('#UserPermissionsCount').textContent")
    $off = Js "(function(){ var th = document.querySelectorAll('.svUsers th.svCheck'); var mid = function (el) { var r = el.getBoundingClientRect(); return r.left + r.width / 2 }; var worst = 0; document.querySelectorAll('#UserRows tr').forEach(function (tr) { tr.querySelectorAll('td.svCheck').forEach(function (td, i) { var box = td.querySelector('.checkboxOutline') || td.querySelector('input'); worst = Math.max(worst, Math.abs(mid(box) - mid(th[i]))) }) }); return worst })()"
    Check "every box sits under the header of its column" ($off -le 2) "off by $off px"
    Check "no raw keys on the Permissions tab"(-not (Js "/config\.|btn\./.test(document.querySelector('[data-panel=permissions]').innerText)"))

    # Filter by name (also by the start of the id of a deleted user).
    Js "var f = document.querySelector('#UserFilter'); f.value = 'svt'; f.dispatchEvent(new Event('input', {bubbles:true})); true" | Out-Null
    Check "the filter keeps only the matching users" ((Js "document.querySelectorAll('#UserRows tr').length") -eq 1 -and (Get-Row "svtest"))
    Js "var f = document.querySelector('#UserFilter'); f.value = 'zzz-nobody'; f.dispatchEvent(new Event('input', {bubbles:true})); true" | Out-Null
    Check "a filter with no match says so" ((Js "document.querySelectorAll('#UserRows input').length") -eq 0 -and (Js "document.querySelector('#UserRows').innerText.trim().length") -gt 0)
    Js "var f = document.querySelector('#UserFilter'); f.value = '$($ghost.ToString().Substring(0, 8))'; f.dispatchEvent(new Event('input', {bubbles:true})); true" | Out-Null
    Check "the filter finds a deleted user by the start of the id" ((Js "document.querySelectorAll('#UserRows tr').length") -eq 1)
    Js "var f = document.querySelector('#UserFilter'); f.value = ''; f.dispatchEvent(new Event('input', {bubbles:true})); true" | Out-Null

    # Save and Cancel wake up with the first change and go back to sleep when it is undone by hand.
    $b = Buttons
    Check "Save and Cancel are off while nothing changed" (-not $b.save -and -not $b.cancel) ($b | ConvertTo-Json -Compress)
    $look = "(function(){ var s = getComputedStyle(document.querySelector('#SyncVoteSave')); return JSON.stringify({ opacity: parseFloat(s.opacity), filter: s.filter }) })()"
    $off = Js $look | ConvertFrom-Json
    Check "and they look off: faded and grey, not like a live button" ($off.opacity -lt 0.6 -and $off.filter -match "grayscale") ($off | ConvertTo-Json -Compress)
    Save-Shot "$OutDir\config-save-off.png"
    Click-Box "svtest" 0
    $b = Buttons
    Check "a change turns Save and Cancel on" ($b.save -and $b.cancel) ($b | ConvertTo-Json -Compress)
    $on = Js $look | ConvertFrom-Json
    Start-Sleep -Milliseconds 800   # Jellyfin fades buttons
    $on = Js $look | ConvertFrom-Json
    Check "and they look alive again" ($on.opacity -eq 1) ($on | ConvertTo-Json -Compress)
    Save-Shot "$OutDir\config-save-on.png"
    Click-Box "svtest" 0
    $b = Buttons
    Check "putting the box back by hand turns them off again" (-not $b.save -and -not $b.cancel) ($b | ConvertTo-Json -Compress)
    Js "document.querySelector('#DefaultCanVote').click(); true" | Out-Null
    Check "changing a default turns them on" ((Buttons).save)
    Js "document.querySelector('#DefaultCanVote').click(); true" | Out-Null
    Check "and putting it back turns them off" (-not (Buttons).save)
    Js "var f = document.querySelector('#UserFilter'); f.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true, cancelable:true})); true" | Out-Null

    # A box is an exception; nothing is written before Save.
    Click-Box "svtest" 0
    # ...while the General tab keeps saving by itself, without carrying the table that is still being edited.
    Js "document.querySelector('#MaxRoomMembers').value = '5'; document.querySelector('#MaxRoomMembers').dispatchEvent(new Event('change', {bubbles:true})); true" | Out-Null
    Start-Sleep 1.5
    $cfg = Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Headers $root.Headers
    $o = @($cfg.UserPermissionOverrides) | Where-Object { Same-User $_.UserId $sv.UserId }
    Check "a setting of General is saved while the permissions are being edited, and they stay unsaved" ($cfg.MaxRoomMembers -eq 5 -and $o.CanVote -eq $false -and $null -eq $o.CanOrganize -and (Buttons).save) ($cfg | ConvertTo-Json -Compress -Depth 5)
    Js "document.querySelector('#MaxRoomMembers').value = '7'; document.querySelector('#MaxRoomMembers').dispatchEvent(new Event('change', {bubbles:true})); true" | Out-Null
    $o = Get-Overrides | Where-Object { Same-User $_.UserId $sv.UserId }
    Check "a box changed in the table is not saved yet" ($o -and $o.CanVote -eq $false -and $null -eq $o.CanOrganize) ($o | ConvertTo-Json -Compress)
    Click-Box "svtest" 1
    Save-Page
    $o = Get-Overrides | Where-Object { Same-User $_.UserId $sv.UserId }
    Check "Save writes the exception for the organize box (vote is back at the default, so no longer an exception)" ($o -and $o.CanOrganize -eq $false -and $null -eq $o.CanVote) ($o | ConvertTo-Json -Compress)
    $g = Get-Overrides | Where-Object { Same-User $_.UserId $ghost }
    Check "the exception of the deleted user is kept" ($g -and $g.CanOrganize -eq $false -and $null -eq $g.CanVote) ($g | ConvertTo-Json -Compress)
    $p = Call $sv GET "/SyncVote/Permissions"
    Check "the saved exception takes effect for the user" ($p.Body.CanOrganize -eq $false -and $p.Body.CanVote -eq $true) ($p.Body | ConvertTo-Json -Compress)

    # Cancel throws the unsaved changes away.
    Open-ConfigPage
    Js "document.querySelector('#UserPermissionsBox').open = true; true" | Out-Null
    Click-Box "svtest" 1
    Js "document.querySelector('#MaxRoomMembers').value = '33'; true" | Out-Null
    Js "document.querySelector('#SyncVoteCancel').click(); true" | Out-Null
    Start-Sleep 1.5
    $row = Get-Row "svtest"
    Check "Cancel restores the table and the other settings" ($row -and $row.vote -eq $true -and (Js "document.querySelector('#MaxRoomMembers').value") -eq "7") ($row | ConvertTo-Json -Compress)

    # Two exceptions in the table (one saved, one not), then the default of a column off and on again: the column is as it was.
    Js "document.querySelector('#UserPermissionsBox').open = true; true" | Out-Null
    Click-Box "svtest" 1
    $before = @((Get-Row "svtest"), (Get-Row $ghost.ToString().Substring(0, 8))) | ForEach-Object { "$($_.org)/$($_.vote)" }
    Js "document.querySelector('#DefaultCanOrganize').click(); true" | Out-Null
    $mid = Get-Row "svtest"
    Check "the default off sets the column (nothing is an exception on organizing any more)" ($mid.org -eq $false) ($mid | ConvertTo-Json -Compress)
    Js "document.querySelector('#DefaultCanOrganize').click(); true" | Out-Null
    $after = @((Get-Row "svtest"), (Get-Row $ghost.ToString().Substring(0, 8))) | ForEach-Object { "$($_.org)/$($_.vote)" }
    Check "Save stays on, the column has an unsaved exception in the other box" ((Buttons).save)
    Check "the default back on gives the exceptions back, saved or not ($($before -join ' ; '))" (($before -join ';') -eq ($after -join ';') -and $after[0] -eq "False/False" -and $after[1] -eq "False/True") "before $($before -join ' ; ') after $($after -join ' ; ')"
    Check "the count of exceptions is the same as before" ((Js "document.querySelector('#UserPermissionsCount').textContent.indexOf('2') !== -1"))
    Js "document.querySelector('#DefaultCanVote').click(); document.querySelector('#DefaultCanVote').click(); true" | Out-Null
    $again = Get-Row "svtest"
    Check "the same for the other column" ($again.org -eq $false -and $again.vote -eq $false) ($again | ConvertTo-Json -Compress)
    Js "document.querySelector('#SyncVoteCancel').click(); true" | Out-Null
    Start-Sleep 1.5

    # The default of a column is for everybody: it sets the column and drops its exceptions.
    Js "document.querySelector('#UserPermissionsBox').open = true; document.querySelector('#DefaultCanOrganize').click(); true" | Out-Null
    $a = Get-Row "svtest"; $b = Get-Row $ghost.ToString().Substring(0, 8)
    Check "clearing the default clears the whole column, administrators stay locked on" ($a.org -eq $false -and $b.org -eq $false -and (Get-Row "root").org -eq $true)
    Save-Page
    $saved = Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Headers $root.Headers
    Check "...and no exception is left on organizing, nor any entry at all" ($saved.DefaultCanOrganize -eq $false -and @($saved.UserPermissionOverrides).Count -eq 0) ($saved | ConvertTo-Json -Compress -Depth 5)
    $p = Call $sv GET "/SyncVote/Permissions"
    Check "the user follows the new default" ($p.Body.CanOrganize -eq $false -and $p.Body.CanVote -eq $true)

    # An exception against a default that is off, then the default back on.
    Open-ConfigPage
    Js "document.querySelector('#UserPermissionsBox').open = true; true" | Out-Null
    Click-Box "svtest" 0
    Save-Page
    $o = Get-Overrides | Where-Object { Same-User $_.UserId $sv.UserId }
    $r = Call $sv POST "/SyncVote/Room" $body
    Check "a user allowed against a default that is off can organize" ($o -and $o.CanOrganize -eq $true -and $r.Status -eq 200) "status $($r.Status) $($o | ConvertTo-Json -Compress)"
    if ($r.Status -eq 200) { Call $sv DELETE "/SyncVote/Room/$($r.Body.Id)" | Out-Null }
    Open-ConfigPage
    Js "document.querySelector('#UserPermissionsBox').open = true; document.querySelector('#DefaultCanOrganize').click(); true" | Out-Null
    Save-Page
    Check "putting the default back on drops the exception again" (@(Get-Overrides).Count -eq 0 -and (Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Headers $root.Headers).DefaultCanOrganize -eq $true)
}
finally {
    Stop-Chrome
    # Leave the plugin configuration as it was found.
    Invoke-RestMethod "$Base/Plugins/$pluginId/Configuration" -Method Post -Headers $root.Headers -ContentType "application/json" -Body ($original | ConvertTo-Json -Depth 6) | Out-Null
    if ($ChangeServerLanguage) { Invoke-RestMethod "$Base/System/Configuration" -Method Post -Headers $root.Headers -ContentType "application/json" -Body ($serverConfig | ConvertTo-Json -Depth 10) | Out-Null }
    Invoke-RestMethod "$Base/Users/$($created.Id)" -Method Delete -Headers $root.Headers | Out-Null
    Write-Host "configuration restored, temporary user removed"
}

if ($script:fail -eq 0) { Write-Host "ALL CONFIG CHECKS PASSED" -ForegroundColor Green } else { Write-Host "$($script:fail) CONFIG CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
