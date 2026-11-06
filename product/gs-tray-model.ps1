#requires -Version 5.1
<#
.SYNOPSIS
  State model for the GsController tray UI (product/gs-tray.ps1).

.DESCRIPTION
  Pure PowerShell helpers with no Windows Forms types, so they can be unit
  tested without a UI. They resolve and read the runtime status file, parse
  the streamer serverinfo response, map both to a tray state, build the
  hidden child command line for gs-product.ps1, parse the child's result
  file, and decide when a pending CLI action is finished. This file contains
  no lifecycle logic of its own.

  Contracts (see docs/tray-ui.md):

  - Status file candidates, in order: <StateDir>\runtime\state\status.json,
    then <StateDir>\status.json. Use whichever exists; when both exist the
    newer LastWriteTimeUtc wins; when neither exists the first candidate is
    reported as the (missing) path. Only the `state` field is read; the
    file's contents are never logged. The read result also carries the
    file's LastWriteTimeUtc ($null when missing or unreadable); the state
    mapping uses it to expire a stuck stopping/starting transition: with a
    -NowUtc reference time, such a status whose file is strictly older than
    its grace period maps to an Error row ('Stopping did not finish' /
    'Starting did not finish') that enables both actions instead of the
    trusting Stopping/Starting rows. The grace period is 300 s for a
    'stopping' status - the same cap as the tray's own pending-action wait,
    because a real official-service Stop measured 138-142 s (see
    docs/troubleshooting.md) - and 120 s for the starting/launching/
    initializing family. Exactly at the grace period the transition is
    still fresh; a pending action still overrides as before.

  - serverinfo: plain HTTP GET (never HTTPS 47984, redirects never
    followed) against an XML document whose root element is named exactly
    'root' (case-sensitive), like `<root status_code="200"><state>...
    _SERVER_FREE</state><currentgame>0</currentgame></root>`. The response
    phase runs through BeginGetResponse plus AsyncWaitHandle.WaitOne(
    remaining) and the body read awaits every chunk through
    stream.ReadAsync(...).Wait(remaining); on any wait timeout the request
    is aborted with HttpWebRequest.Abort and reported as HttpStatus=0 /
    ParseOk=$false with a timeout ParseError, so the fetch is hard-bounded
    to about TimeoutMs per phase (connect/read) no matter how the server
    behaves. The body is read as raw bytes and capped at 65536 BYTES
    counted before decoding (exactly 65536 bytes is still valid), then
    decoded as UTF-8. Ready/Streaming require HttpStatus=200 exactly AND
    ParseOk AND ProtocolStatus=200.
    ConvertFrom-GsServerInfoXml returns
    { ProtocolStatus; ParseOk; State; CurrentGame; ParseError } where
    ParseOk is $true only if the XML loads, the root element is named
    exactly 'root' (case-sensitive), status_code matches ^[0-9]{1,10}$ and
    equals 200, the <state> element exists with non-empty trimmed content,
    and the <currentgame> element exists whose trimmed content matches
    ^[0-9]{1,10}$ (ProtocolStatus carries the parsed status_code; it is 0
    when status_code is missing or not parseable as an integer, and any
    status_code other than 200 fails the parse); ParseError is $null on
    success and a short reason otherwise. Get-GsTrayServerInfo returns
    { HttpStatus; ProtocolStatus; ParseOk; State; CurrentGame; ParseError }.

  - CLI result shape of gs-product.ps1:
    { Success; Data; Errors = @({ Code; Message }) }. When another
    Start/Stop/Recover holds the lifecycle lock the CLI returns
    Success=$false with Errors[0].Code='Busy'. Success must be a JSON
    boolean and Code/Message must be strings to be picked up.

  Read result Error codes: $null (fine, or file missing), 'ReadFailed'
  (exists but could not be read), 'InvalidJson' (readable but not valid
  JSON), 'MissingStateField' (valid JSON whose `state` field is absent or
  null), 'InvalidStateField' (valid JSON whose `state` field is present
  but not a string).

  Night batch B additions (see docs/tray-ui.md):
  - K4 string table: Get-GsTrayBuiltinStrings (built-in English table),
    Get-GsTrayStrings (external zh-CN table with validation and built-in
    fallback), Get-GsTrayString, Format-GsTrayText, Get-GsTrayStateName,
    Get-GsTrayDetailText (translated detail capped at the 63 character
    tray tooltip limit AFTER translation), Get-GsTrayTooltipText. State
    rows carry additive DetailKey/DetailArgs; the English Detail stays.
  - K3: New-GsTrayChildCommand also accepts -Action Recover;
    Read-GsTrayCommandResult returns an additive Reason field;
    Get-GsTrayMenuEnabled (pure menu enable rules);
    Resolve-GsTrayRecoverBalloon / Resolve-GsTraySupportBalloon (balloon
    mappings: unknown reasons and codes are shown raw, never a crash);
    New-GsTraySupportCommand + Read-GsTraySupportResult (K1 support
    bundle child flow).
  - B3: Test-GsTrayPauseFlag (Test-Path only, never deletes) and
    Get-GsTrayNotification (debounced Ready/Streaming transitions).

  Round-4 review additions (see docs/tray-ui.md):
  - B-B2: Get-GsTrayStrings is resource-bounded (files over 64 KB rejected
    before parsing, values capped at 512 characters, plain {N} placeholders
    only with indices inside the expected count - otherwise the English
    fallback).
  - B-B3 (K3): Test-GsTrayElevated + Resolve-GsTraySupportLaunch; an
    elevated tray never launches the support bundle.
  - B-B4: Get-GsTrayTooltipText reserves the prefix and pause suffix first
    and truncates the detail to the remaining budget (total <= 63).
  - B-N1: the balloon resolvers allow an empty Code; a missing failure
    code is normalized to NoResult.
#>

function Get-GsTrayBuiltinStrings {
    # The built-in English string table (K4 fallback). Keys must match the
    # external zh-CN table exactly; placeholder counts per key must match
    # too (both are validated by Get-GsTrayStrings and asserted by tests).
    # The table is memoized in script scope; callers may mutate their copy
    # of the returned hashtable only for tests. The slot is pre-initialized
    # below so StrictMode never sees an unset variable.
    if ($null -ne $script:GsTrayBuiltinStrings) { return $script:GsTrayBuiltinStrings }
    $script:GsTrayBuiltinStrings = @{
        'tooltip.prefix'                          = 'GsController: '
        'menu.start'                              = 'Start'
        'menu.stop'                               = 'Stop'
        'menu.status'                             = 'Status'
        'menu.recover'                            = 'Recover stuck session'
        'menu.supportBundle'                      = 'Create support bundle'
        'menu.openLogs'                           = 'Open logs'
        'menu.exit'                               = 'Exit'
        'state.stopped'                           = 'Stopped'
        'state.starting'                          = 'Starting'
        'state.stopping'                          = 'Stopping'
        'state.ready'                             = 'Ready'
        'state.streaming'                         = 'Streaming'
        'state.error'                             = 'Error'
        'detail.stoppedNoStatusFile'              = 'Stopped (no status file)'
        'detail.stopped'                          = 'Stopped'
        'detail.statusFileUnreadable'             = 'Status file unreadable'
        'detail.statusFileInvalid'                = 'Status file invalid'
        'detail.statusFileNoStateField'           = 'Status file has no state field'
        'detail.statusFileBadStateField'          = 'Status file has no valid state field'
        'detail.serverinfoUnreachable'            = 'runtime ready but serverinfo unreachable'
        'detail.serverinfoInvalid'                = 'runtime ready but serverinfo invalid'
        'detail.starting'                         = 'Starting...'
        'detail.stopping'                         = 'Stopping...'
        'detail.startingDidNotFinish'             = 'Starting did not finish'
        'detail.stoppingDidNotFinish'             = 'Stopping did not finish'
        'detail.ready'                            = 'Ready'
        'detail.streaming'                        = 'Streaming'
        'detail.runtimeFailed'                    = 'Runtime reports failed'
        'detail.runtimeError'                     = 'Runtime reports error'
        'detail.unknownState'                     = 'unknown state {0}'
        'status.title'                            = 'GsController status'
        'status.trayState'                        = 'Tray state: {0}'
        'status.detail'                           = 'Detail: {0}'
        'status.pendingAction'                    = 'Pending action: {0}'
        'status.statusFile'                       = 'Status file: {0}'
        'status.statusFilePresent'                = 'Status file: present'
        'status.statusFileMissing'                = 'Status file: missing'
        'status.statusError'                      = 'Status error: {0}'
        'status.lastResult'                       = 'Last CLI result: Success={0} Code={1}'
        'status.lastResultNone'                   = 'Last CLI result: (none)'
        'status.trayLog'                          = 'Tray log: {0}'
        'balloon.title'                           = 'GsController'
        'balloon.actionCompleted'                 = '{0} completed.'
        'balloon.busy'                            = 'Another lifecycle operation is running.'
        'balloon.noUsableResult'                  = '{0} finished without a usable result; see tray log.'
        'balloon.actionFailed'                    = '{0} failed ({1}).'
        'balloon.actionStillRunning'              = '{0} is still running; the tray stopped waiting.'
        'balloon.uacCancelled'                    = '{0} cancelled: elevation was declined.'
        'balloon.launchFailed'                    = '{0} could not be launched.'
        'balloon.internalError'                   = 'An internal error occurred; see the tray log.'
        'recover.confirmTitle'                    = 'Recover stuck session'
        'recover.confirmText'                     = 'This stops and restarts the GameStream runtime to clear a stuck session. If a client is currently streaming, it will be interrupted. Continue?'
        'recover.success'                         = 'The stuck session was recovered.'
        'recover.reason.StatusUnavailable'        = 'The status file is unavailable; recovery was refused'
        'recover.reason.NotReady'                 = 'The runtime is not ready; recovery was refused'
        'recover.reason.ServerInfoUnavailable'    = 'No valid serverinfo response; recovery was refused'
        'recover.reason.NoStuckSession'           = 'No stuck session was detected (currentgame is not 1); nothing to recover'
        'recover.reason.ClientConnected'          = 'A client connection was detected; recovery was cancelled to avoid interrupting the stream'
        'recover.reason.ConnectionCheckFailed'    = 'The client connection check failed; recovery was refused'
        'recover.reason.ClientTrafficDetected'    = 'Client traffic was detected; recovery was cancelled to avoid interrupting the stream'
        'recover.code.RecoverStopFailed'          = 'Recover failed: the stop step did not succeed'
        'recover.code.RecoverStartFailed'         = 'Recover failed: the start step did not succeed'
        'recover.code.RecoverCleanupFailed'       = 'Recover ran, but cleaning up the recovery pause flag failed'
        'recover.unknownReason'                   = 'Recover was refused (unknown reason): {0}'
        'support.missing'                         = 'The support bundle tool is not installed'
        'support.success'                         = 'Support bundle created: {0}'
        'support.noResult'                        = 'Support bundle finished without a usable result; see tray log.'
        'support.elevatedRefused'                 = 'Support bundle failed: the tray itself is running elevated, so the bundle was not created'
        'support.code.DiagnoseUnavailable'        = 'Support bundle failed: the diagnose script is unavailable'
        'support.code.DiagnoseFailed'             = 'Support bundle failed: the diagnose step failed'
        'support.code.RedactionCheckFailed'       = 'Support bundle failed: the redaction check failed'
        'support.code.OutputDirInvalid'           = 'Support bundle failed: the output directory is invalid'
        'support.code.ZipFailed'                  = 'Support bundle failed: creating the zip failed'
        'support.unknownCode'                     = 'Support bundle failed (unknown code): {0}'
        'notify.streamStarted'                    = 'Streaming has started'
        'notify.streamEnded'                      = 'Streaming has ended'
        'notify.pausedSuffix'                     = ' (supervisor paused)'
    }
    return $script:GsTrayBuiltinStrings
}

function Get-GsTrayStrings {
    # Loads the external zh-CN string table (K4) and validates it against the
    # built-in English table. Returns
    # { Source = 'file'|'builtin'; Path; FallbackReason; Strings; KeyCount }.
    # Never throws; on any problem (no path, missing/unreadable/empty file,
    # invalid JSON, not an object, non-string or empty value, missing key,
    # unknown key, placeholder-count mismatch) it falls back to the built-in
    # English table and reports the reason for logging. A leading UTF-8 BOM
    # (U+FEFF) is stripped and the file accepted (Get-Content/Notepad BOM
    # output stays usable); this must never crash the tray.
    # Resource bounds (B-B2): the file is rejected BEFORE reading/parsing
    # when it is over 65536 bytes (64 KB); every value is capped at 512
    # characters; every brace group in a value must be a plain {N}
    # placeholder (no alignment or format clauses, no stray braces) and
    # every placeholder index must stay inside the expected count for its
    # key - anything else falls back to English, so formatting can never
    # allocate unbounded output on the UI thread.
    [CmdletBinding()]
    param([string]$Path = '')

    $builtin = Get-GsTrayBuiltinStrings
    $fallback = {
        param($Reason)
        [pscustomobject]@{ Source = 'builtin'; Path = $Path; FallbackReason = $Reason; Strings = $builtin; KeyCount = $builtin.Count }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { return (& $fallback 'no string table path was given') }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return (& $fallback ('string table file not found: ' + $Path)) }
    $fileItem = $null
    try { $fileItem = Get-Item -LiteralPath $Path } catch {
        return (& $fallback ('string table could not be inspected: ' + $_.Exception.Message))
    }
    if ($fileItem.PSIsContainer) { return (& $fallback ('string table file not found: ' + $Path)) }
    # B-B2: bound the table bytes before reading or parsing anything.
    if ($fileItem.Length -gt 65536) { return (& $fallback 'string table file is over the 65536 byte (64 KB) size limit') }
    $text = $null
    try { $text = [IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch {
        return (& $fallback ('string table could not be read: ' + $_.Exception.Message))
    }
    # A BOM decodes to a leading U+FEFF on .NET Framework; strip and accept.
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($text)) { return (& $fallback 'string table file is empty') }
    $json = $null
    try { $json = $text | ConvertFrom-Json } catch {
        return (& $fallback ('string table is not valid JSON: ' + $_.Exception.Message))
    }
    if ($null -eq $json -or $json -is [System.Array] -or -not ($json -is [pscustomobject])) {
        return (& $fallback 'string table is not a JSON object')
    }
    $table = @{}
    foreach ($prop in $json.PSObject.Properties) {
        if ($null -eq $prop.Value -or -not ($prop.Value -is [string]) -or ([string]$prop.Value).Length -eq 0) {
            return (& $fallback ('string table has a non-string or empty value for key ' + $prop.Name))
        }
        # B-B2: bound every value so one huge entry cannot balloon UI text.
        if (([string]$prop.Value).Length -gt 512) {
            return (& $fallback ('string table value for key ' + $prop.Name + ' is longer than 512 characters'))
        }
        $table[[string]$prop.Name] = [string]$prop.Value
    }
    foreach ($key in $builtin.Keys) {
        if (-not $table.ContainsKey([string]$key)) { return (& $fallback ('string table is missing key ' + $key)) }
    }
    foreach ($key in $table.Keys) {
        if (-not $builtin.ContainsKey([string]$key)) { return (& $fallback ('string table has an unknown key ' + $key)) }
    }
    foreach ($key in $builtin.Keys) {
        $value = [string]$table[[string]$key]
        $expected = [regex]::Matches([string]$builtin[$key], '\{\d+\}').Count
        $found = [regex]::Matches($value, '\{(\d+)\}')
        if ($found.Count -ne $expected) { return (& $fallback ('string table placeholder count differs for key ' + $key)) }
        # B-B2: every brace group must be a plain {N} placeholder - alignment
        # clauses ({0,999999}), format clauses ({0:X}) and stray braces are
        # rejected - and every index must stay inside the expected count.
        $residual = [regex]::Replace($value, '\{(\d+)\}', '')
        if ($residual.Contains('{') -or $residual.Contains('}')) {
            return (& $fallback ('string table has an invalid placeholder in key ' + $key + ' (only plain {N} placeholders are allowed)'))
        }
        foreach ($m in $found) {
            $placeholderIndex = 0
            if (-not [int]::TryParse($m.Groups[1].Value, [ref]$placeholderIndex) -or $placeholderIndex -ge $expected) {
                return (& $fallback ('string table has an out-of-range placeholder index in key ' + $key))
            }
        }
    }
    return [pscustomobject]@{ Source = 'file'; Path = $Path; FallbackReason = $null; Strings = $table; KeyCount = $table.Count }
}

function Get-GsTrayString {
    # Looks up one string: the given table first, then the built-in English
    # table. Returns $null when the key exists in neither (callers decide
    # what to show, e.g. a raw reason code).
    [CmdletBinding()]
    param($Strings, [Parameter(Mandatory = $true)][string]$Key)
    if ($null -ne $Strings -and $Strings.ContainsKey($Key)) { return [string]$Strings[$Key] }
    $builtin = Get-GsTrayBuiltinStrings
    if ($builtin.ContainsKey($Key)) { return [string]$builtin[$Key] }
    return $null
}

function Format-GsTrayText {
    # Formats one string-table entry. Never throws: an unknown key falls back
    # to English, a format error (placeholder/argument mismatch) retries the
    # English template and, failing that, returns the raw template; a key
    # unknown to both tables returns the key itself.
    [CmdletBinding()]
    param(
        $Strings,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyCollection()][object[]]$Arguments = @()
    )
    $template = Get-GsTrayString -Strings $Strings -Key $Key
    if ($null -ne $template) {
        try { return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $template, $Arguments) } catch { }
    }
    $builtin = Get-GsTrayBuiltinStrings
    if ($builtin.ContainsKey($Key)) {
        $english = [string]$builtin[$Key]
        try { return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $english, $Arguments) } catch { return $english }
    }
    return $Key
}

function Get-GsTrayStateName {
    # Translates a canonical tray state name ('Stopped', 'Ready', ...) for
    # display; unknown states come back unchanged (never an empty label).
    [CmdletBinding()]
    param($Strings, [Parameter(Mandatory = $true)][string]$State)
    $key = 'state.' + $State.ToLowerInvariant()
    $text = Get-GsTrayString -Strings $Strings -Key $key
    if ($null -eq $text) { return $State }
    return $text
}

function Test-GsTrayPauseFlag {
    # B3: $true when either supervisor pause flag exists. Test-Path only -
    # the flag is never created, written or deleted here.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateDir)
    foreach ($relative in @('supervisor_pause.flag', 'runtime\state\supervisor_pause.flag')) {
        if (Test-Path -LiteralPath (Join-Path $StateDir $relative) -PathType Leaf) { return $true }
    }
    return $false
}

function Get-GsTrayNotification {
    # B3: debounced transition notification. A state change is only trusted
    # after two consecutive polls agree ($Current -eq $Previous); only then
    # is it compared against the caller's last CONFIRMED state ($Confirmed,
    # which the caller advances once a poll pair agrees). Ready->Streaming
    # announces the stream started, Streaming->Ready that it ended; every
    # other transition, the very first polls ($Confirmed empty) and any
    # one-poll blip stay silent. When $Paused, $PausedSuffix is appended and
    # the text is capped at the 63 character tray tooltip limit.
    [CmdletBinding()]
    param(
        $Strings = $null,
        [string]$Confirmed = '',
        [string]$Previous = '',
        [string]$Current = '',
        [bool]$Paused = $false,
        [string]$PausedSuffix = ''
    )
    if ([string]::IsNullOrWhiteSpace($Current)) { return $null }
    if ($Current -ne $Previous) { return $null }              # not yet stable for two consecutive polls
    if ([string]::IsNullOrEmpty($Confirmed)) { return $null }  # nothing confirmed to transition from
    if ($Current -eq $Confirmed) { return $null }              # already the confirmed state
    $key = $null
    if ($Confirmed -eq 'Ready' -and $Current -eq 'Streaming') { $key = 'notify.streamStarted' }
    elseif ($Confirmed -eq 'Streaming' -and $Current -eq 'Ready') { $key = 'notify.streamEnded' }
    if ($null -eq $key) { return $null }
    $text = Format-GsTrayText -Strings $Strings -Key $key
    if ($Paused -and -not [string]::IsNullOrEmpty($PausedSuffix)) { $text = $text + $PausedSuffix }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    return $text
}

function Get-GsTrayTooltipText {
    # Composes the tray tooltip (B-B4): the string-table prefix and, when
    # paused, the pause suffix are reserved FIRST; the detail is truncated to
    # whatever budget remains. The total never exceeds the 63 character
    # tray tooltip limit, and a paused tooltip always keeps its pause suffix
    # - truncating the composed text at the end (the old behavior) could
    # discard the entire suffix when a long state detail filled the budget.
    # Everything happens after translation; a prefix alone over the limit is
    # truncated to the limit itself.
    [CmdletBinding()]
    param(
        [string]$Prefix = '',
        [string]$Detail = '',
        [bool]$Paused = $false,
        [string]$PausedSuffix = ''
    )
    $limit = 63
    $prefixText = $Prefix
    if ($prefixText.Length -gt $limit) { $prefixText = $prefixText.Substring(0, $limit) }
    $suffixText = ''
    if ($Paused -and -not [string]::IsNullOrEmpty($PausedSuffix)) {
        $suffixText = $PausedSuffix
        $maxSuffix = $limit - $prefixText.Length
        if ($suffixText.Length -gt $maxSuffix) { $suffixText = $suffixText.Substring(0, [Math]::Max($maxSuffix, 0)) }
    }
    $detailBudget = $limit - $prefixText.Length - $suffixText.Length
    $detailText = $Detail
    if ($detailText.Length -gt $detailBudget) { $detailText = $detailText.Substring(0, [Math]::Max($detailBudget, 0)) }
    return ($prefixText + $detailText + $suffixText)
}

function Get-GsTrayDetailText {
    # Translates a state row for display (K4): DetailKey/DetailArgs through
    # the string table, falling back to the row's English Detail when there
    # is no key. The result is capped at the 63 character tray tooltip limit
    # AFTER translation (the limit counts characters, so a translated detail
    # built from a long argument is truncated here, never overflowed).
    [CmdletBinding()]
    param($Strings, [Parameter(Mandatory = $true)]$StateRow)
    $text = [string]$StateRow.Detail
    if (-not [string]::IsNullOrEmpty($StateRow.DetailKey)) {
        $text = Format-GsTrayText -Strings $Strings -Key $StateRow.DetailKey -Arguments $StateRow.DetailArgs
    }
    return (Limit-GsTrayDetail $text)
}

function Get-GsTrayMenuEnabled {
    # Pure menu enable rules shared by the tray. Any pending action disables
    # all four items. Otherwise: Start follows CanStart, Stop follows
    # CanStop, Recover is enabled only while Streaming with a usable stop
    # action (recovering interrupts a live client), and the support bundle
    # is independent of the runtime state.
    [CmdletBinding()]
    param(
        $StateRow,
        [string]$PendingAction = '',
        [Parameter(Mandatory = $true)][ValidateSet('Start', 'Stop', 'Recover', 'SupportBundle')][string]$MenuItem
    )
    if (-not [string]::IsNullOrWhiteSpace($PendingAction)) { return $false }
    switch ($MenuItem) {
        'Start' { if ($null -eq $StateRow) { return $false }; return [bool]$StateRow.CanStart }
        'Stop' { if ($null -eq $StateRow) { return $false }; return [bool]$StateRow.CanStop }
        'Recover' { if ($null -eq $StateRow) { return $false }; return (($StateRow.State -eq 'Streaming') -and [bool]$StateRow.CanStop) }
        default { return $true }
    }
}

function Resolve-GsTrayRecoverBalloon {
    # Maps a finished Recover CLI result to a balloon text and kind (K3).
    # Every documented refusal reason maps to its own Warning balloon; an
    # unknown or empty reason shows the raw reason (or the raw code) via the
    # recover.unknownReason template and never crashes. Failure codes map to
    # Error balloons; Busy keeps its own Warning; anything else falls back
    # to the generic '<action> failed (<code>).' balloon with the raw code.
    # An empty/whitespace Code is allowed (B-N1) and normalized to the
    # literal code 'NoResult' - a missing failure code is shown as NoResult,
    # never a crash or an empty-code balloon.
    [CmdletBinding()]
    param(
        $Strings,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Code,
        [string]$Reason = '',
        [string]$ActionLabel = 'Recover'
    )
    if ([string]::IsNullOrWhiteSpace($Code)) { $Code = 'NoResult' }
    if ($Code -eq 'RecoverRefused') {
        $shownReason = $Reason
        if ([string]::IsNullOrWhiteSpace($shownReason)) { $shownReason = $Code }
        $reasonKey = 'recover.reason.' + $Reason
        if ($null -ne (Get-GsTrayString -Strings $Strings -Key $reasonKey)) {
            return [pscustomobject]@{ Text = (Format-GsTrayText -Strings $Strings -Key $reasonKey); Kind = 'Warning' }
        }
        return [pscustomobject]@{ Text = (Format-GsTrayText -Strings $Strings -Key 'recover.unknownReason' -Arguments @($shownReason)); Kind = 'Warning' }
    }
    if ($Code -eq 'Busy') {
        return [pscustomobject]@{ Text = (Format-GsTrayText -Strings $Strings -Key 'balloon.busy'); Kind = 'Warning' }
    }
    $codeKey = 'recover.code.' + $Code
    if ($null -ne (Get-GsTrayString -Strings $Strings -Key $codeKey)) {
        return [pscustomobject]@{ Text = (Format-GsTrayText -Strings $Strings -Key $codeKey); Kind = 'Error' }
    }
    return [pscustomobject]@{ Text = (Format-GsTrayText -Strings $Strings -Key 'balloon.actionFailed' -Arguments @($ActionLabel, $Code)); Kind = 'Error' }
}

function Resolve-GsTraySupportBalloon {
    # Maps a finished support bundle result to a balloon text and kind.
    # Code '' means success (B-N1: the empty code is explicitly allowed so
    # that documented branch is callable); the five K1 error codes map to
    # their own Error balloons, NoResult (missing/invalid result file) to
    # support.noResult, and any unknown code is shown raw - never a crash.
    # A FAILURE result whose Code came out empty is normalized to NoResult
    # by the tray host before this resolver is called.
    [CmdletBinding()]
    param(
        $Strings,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Code,
        [string]$ZipPath = ''
    )
    if ([string]::IsNullOrEmpty($Code)) {
        return [pscustomobject]@{ Text = (Format-GsTrayText -Strings $Strings -Key 'support.success' -Arguments @($ZipPath)); Kind = 'Info' }
    }
    $codeKey = 'support.code.' + $Code
    if ($null -ne (Get-GsTrayString -Strings $Strings -Key $codeKey)) {
        return [pscustomobject]@{ Text = (Format-GsTrayText -Strings $Strings -Key $codeKey); Kind = 'Error' }
    }
    if ($Code -eq 'NoResult') {
        return [pscustomobject]@{ Text = (Format-GsTrayText -Strings $Strings -Key 'support.noResult'); Kind = 'Error' }
    }
    return [pscustomobject]@{ Text = (Format-GsTrayText -Strings $Strings -Key 'support.unknownCode' -Arguments @($Code)); Kind = 'Error' }
}

function Test-GsTrayElevated {
    # B-B3 (K3): $true when the CURRENT process runs with an elevated
    # (administrator) token. The tray host reaches this through its
    # injectable $script:IsTrayElevated slot to decide whether the support
    # bundle may launch at all: an elevated tray would hand its elevation to
    # the support child, so the menu item refuses instead. When the token
    # cannot be determined the probe fails closed ($true), i.e. no launch.
    [CmdletBinding()]
    param()
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $true
    }
}

function Resolve-GsTraySupportLaunch {
    # B-B3 (K3): pure decision for the support-bundle menu item. $Elevated
    # comes from the injected elevation probe (Test-GsTrayElevated in the
    # tray host). An elevated tray never launches the support child - it
    # would inherit the tray's elevation - and no attempt is made to obtain
    # a non-elevated token; the caller shows the fixed refusal reason
    # 'ElevatedTray' (English log, Chinese UI string) instead.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Elevated)
    if ($Elevated) {
        return [pscustomobject]@{ Launch = $false; RefusedReason = 'ElevatedTray' }
    }
    return [pscustomobject]@{ Launch = $true; RefusedReason = '' }
}

# Memoization slot for Get-GsTrayBuiltinStrings, initialized at dot-source
# time so a Set-StrictMode host never sees it unset.
$script:GsTrayBuiltinStrings = $null

function ConvertTo-GsTraySingleQuoted {
    # Wraps a value in single quotes so it is safe to embed in a generated
    # PowerShell command string. Uses the parser's own escaper (present in
    # Windows PowerShell 5.1); if it is unavailable, falls back to doubling
    # the ASCII quote and the Unicode quote look-alikes by hand.
    param([string]$Value)
    $escaped = $null
    try {
        $escaped = [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Value)
    } catch {
        $escaped = $null
    }
    if ($null -eq $escaped) {
        $escaped = $Value
        foreach ($quote in @("'", [string][char]0x2018, [string][char]0x2019, [string][char]0x201A, [string][char]0x201B)) {
            $escaped = $escaped.Replace($quote, $quote + $quote)
        }
    }
    return ("'" + $escaped + "'")
}

function Resolve-GsTrayStatusPath {
    # Returns the status file path to use for a state directory (see the
    # contract at the top of this file). Always returns a path; callers use
    # Read-GsTrayStatusFile to learn whether it exists.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateDir)

    $primary = Join-Path $StateDir 'runtime\state\status.json'
    $fallback = Join-Path $StateDir 'status.json'
    $primaryExists = Test-Path -LiteralPath $primary -PathType Leaf
    $fallbackExists = Test-Path -LiteralPath $fallback -PathType Leaf
    if ($primaryExists -and $fallbackExists) {
        $primaryTime = (Get-Item -LiteralPath $primary).LastWriteTimeUtc
        $fallbackTime = (Get-Item -LiteralPath $fallback).LastWriteTimeUtc
        if ($fallbackTime -gt $primaryTime) { return $fallback }
        return $primary
    }
    if ($fallbackExists) { return $fallback }
    return $primary
}

function Read-GsTrayStatusFile {
    # Reads one status file and returns { Path; Exists; Readable;
    # LastWriteTimeUtc; State; Error } where State is the raw string value
    # of the `state` field (or $null), Error is a short code (or $null), and
    # LastWriteTimeUtc is the file's write time in UTC ($null when the file
    # is missing or the time cannot be read). The state mapping uses it to
    # expire a stuck stopping/starting transition (see
    # Test-GsTrayTransitionStale). Missing files are normal (Error stays
    # $null, Exists=$false).
    # A `state` field that is absent or null is reported as
    # MissingStateField; a `state` field that is present but not a string
    # (number, bool, array, object) is reported as InvalidStateField: only
    # a string is a usable status value.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $info = [pscustomobject]@{ Path = $Path; Exists = $false; Readable = $false; LastWriteTimeUtc = $null; State = $null; Error = $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $info }
    $info.Exists = $true
    try { $info.LastWriteTimeUtc = (Get-Item -LiteralPath $Path).LastWriteTimeUtc } catch { }
    $text = $null
    try { $text = [IO.File]::ReadAllText($Path) } catch {
        $info.Error = 'ReadFailed'
        return $info
    }
    $info.Readable = $true
    if ([string]::IsNullOrWhiteSpace($text)) { $info.Error = 'InvalidJson'; return $info }
    $json = $null
    try { $json = $text | ConvertFrom-Json } catch { $info.Error = 'InvalidJson'; return $info }
    if ($null -eq $json) { $info.Error = 'InvalidJson'; return $info }
    $prop = $json.PSObject.Properties['state']
    if ($null -eq $prop -or $null -eq $prop.Value) { $info.Error = 'MissingStateField'; return $info }
    if (-not ($prop.Value -is [string])) { $info.Error = 'InvalidStateField'; return $info }
    $info.State = [string]$prop.Value
    return $info
}

function Get-GsTrayStatusInfo {
    # Resolves the status path for a state directory and reads it in one step.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateDir)
    return (Read-GsTrayStatusFile -Path (Resolve-GsTrayStatusPath -StateDir $StateDir))
}

function ConvertFrom-GsServerInfoXml {
    # Parses serverinfo XML text into { ProtocolStatus; ParseOk; State;
    # CurrentGame; ParseError }. Never throws: malformed or empty input
    # yields ProtocolStatus=0, ParseOk=$false, empty strings and a short
    # ParseError. ParseOk is $true only if the XML loads, the root element
    # is named exactly 'root' (case-sensitive), status_code matches
    # ^[0-9]{1,10}$ and equals 200, a <state> element exists with
    # non-empty trimmed content, and a <currentgame> element exists whose
    # trimmed content matches ^[0-9]{1,10}$. Only the root name,
    # status_code, state and currentgame are read; State and CurrentGame
    # are trimmed. ProtocolStatus carries the parsed status_code (0 when it
    # is missing or not parseable as an integer); any status_code other
    # than 200 fails the parse. ParseError is $null on success and a short
    # reason otherwise.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$XmlText)

    $result = [pscustomobject]@{ ProtocolStatus = 0; ParseOk = $false; State = ''; CurrentGame = ''; ParseError = $null }
    if ([string]::IsNullOrWhiteSpace($XmlText)) { $result.ParseError = 'response body is empty'; return $result }
    $doc = $null
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($XmlText)
    } catch {
        $result.ParseError = 'response body is not valid XML'
        return $result
    }
    $root = $doc.DocumentElement
    if ($null -eq $root) { $result.ParseError = 'response body has no XML root'; return $result }
    if (-not [string]::Equals($root.Name, 'root', [System.StringComparison]::Ordinal)) {
        $result.ParseError = 'XML root element is not exactly root'
        return $result
    }
    $code = $root.GetAttribute('status_code')
    $trimmedCode = ''
    if ($null -ne $code) { $trimmedCode = [string]$code }
    $asInt = 0
    if ([string]::IsNullOrWhiteSpace($trimmedCode) -or -not [regex]::IsMatch($trimmedCode.Trim(), '^[0-9]{1,10}$') -or -not [int]::TryParse($trimmedCode.Trim(), [ref]$asInt)) {
        $result.ParseError = 'status_code attribute is missing or not an integer'
        return $result
    }
    $result.ProtocolStatus = $asInt
    if ($asInt -ne 200) {
        $result.ParseError = 'status_code attribute is not 200'
        return $result
    }
    $stateNode = $root.SelectSingleNode('state')
    if ($null -eq $stateNode) { $result.ParseError = 'state element is missing'; return $result }
    $stateText = $stateNode.InnerText.Trim()
    if ($stateText -eq '') { $result.ParseError = 'state element is empty'; return $result }
    $gameNode = $root.SelectSingleNode('currentgame')
    if ($null -eq $gameNode) { $result.ParseError = 'currentgame element is missing'; return $result }
    $gameText = $gameNode.InnerText.Trim()
    if (-not [regex]::IsMatch($gameText, '^[0-9]{1,10}$')) { $result.ParseError = 'currentgame element is empty or not all digits'; return $result }
    $result.State = $stateText
    $result.CurrentGame = $gameText
    $result.ParseOk = $true
    return $result
}

function Read-GsTrayBoundedBody {
    # Reads a response stream as raw BYTES in chunks, with an abort that is
    # independent of the server: every chunk is awaited through
    # Stream.ReadAsync(...).Wait(remaining) against a Stopwatch deadline of
    # TimeoutMs instead of a blocking Read, and on any wait timeout
    # -Request.Abort() is called so a server that only trickles bytes can
    # never hold the caller. The body is capped at 65536 BYTES counted
    # before decoding and only then decoded as UTF-8 (~64 KB covers the
    # ASCII XML serverinfo answers; a multibyte body can be far over the
    # byte cap while staying under the character count). Returns
    # { Text; Complete; StopReason }; Complete is $false (and Text empty)
    # when the deadline, the byte cap, a wait timeout, or a read error
    # stopped the read early, and StopReason then says which: 'timeout' for
    # a wait timeout (the request has been aborted), 'cap' for the byte
    # cap, '' for the deadline or a read error.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Stream, [int]$TimeoutMs = 1000, $Request = $null)

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $memory = New-Object System.IO.MemoryStream
    try {
        $buffer = New-Object byte[] 4096
        $total = 0
        while ($true) {
            $remaining = $TimeoutMs - [int]$watch.ElapsedMilliseconds
            if ($remaining -le 0) {
                return [pscustomobject]@{ Text = ''; Complete = $false; StopReason = '' }
            }
            $task = $null
            try { $task = $Stream.ReadAsync($buffer, 0, $buffer.Length) } catch {
                return [pscustomobject]@{ Text = ''; Complete = $false; StopReason = '' }
            }
            # Wait rethrows a faulted task's exception; only $false here
            # means "still pending after the remaining budget".
            if (-not $task.Wait($remaining)) {
                try { if ($null -ne $Request) { $Request.Abort() } } catch { }
                return [pscustomobject]@{ Text = ''; Complete = $false; StopReason = 'timeout' }
            }
            $read = 0
            try { $read = $task.Result } catch {
                return [pscustomobject]@{ Text = ''; Complete = $false; StopReason = '' }
            }
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt 65536) {
                return [pscustomobject]@{ Text = ''; Complete = $false; StopReason = 'cap' }
            }
            $memory.Write($buffer, 0, $read)
        }
        $text = [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
        return [pscustomobject]@{ Text = $text; Complete = $true; StopReason = '' }
    } catch {
        return [pscustomobject]@{ Text = ''; Complete = $false; StopReason = '' }
    } finally {
        try { $memory.Dispose() } catch { }
    }
}

function Get-GsTrayServerInfo {
    # Fetches serverinfo over plain HTTP with a short timeout (default 1 s)
    # and returns { HttpStatus; ProtocolStatus; ParseOk; State; CurrentGame;
    # ParseError }. Redirects are never followed (AllowAutoRedirect stays
    # $false), and validity requires an HTTP status of exactly 200. The
    # response phase runs through BeginGetResponse plus
    # AsyncWaitHandle.WaitOne(remaining) and the body read awaits every
    # chunk, so on any wait timeout the request is aborted with
    # HttpWebRequest.Abort and reported as HttpStatus=0 / ParseOk=$false
    # with a timeout ParseError - the fetch is hard-bounded to about
    # TimeoutMs per phase (connect/read) no matter how the server behaves.
    # The WebException response and its stream are closed on every path; a
    # body over the 65536 byte cap or a read error yields ParseOk=$false
    # with a matching ParseError. ParseError is $null only when the body
    # parsed cleanly.
    [CmdletBinding()]
    param(
        [string]$Uri = 'http://127.0.0.1:47989/serverinfo',
        [ValidateRange(50, 30000)]
        [int]$TimeoutMs = 1000
    )

    $status = 0
    $bodyText = ''
    $bodyComplete = $false
    $bounded = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $false
        $request.Proxy = $null
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $asyncResult = $request.BeginGetResponse($null, $null)
        $remaining = $TimeoutMs - [int]$watch.ElapsedMilliseconds
        if ($remaining -le 0 -or -not $asyncResult.AsyncWaitHandle.WaitOne($remaining)) {
            try { $request.Abort() } catch { }
            return [pscustomobject]@{
                HttpStatus = 0
                ProtocolStatus = 0
                ParseOk = $false
                State = ''
                CurrentGame = ''
                ParseError = 'serverinfo request timed out'
            }
        }
        $response = $null
        try {
            $response = $request.EndGetResponse($asyncResult)
            $status = [int]$response.StatusCode
            $bounded = Read-GsTrayBoundedBody -Stream $response.GetResponseStream() -TimeoutMs $TimeoutMs -Request $request
            $bodyText = $bounded.Text
            $bodyComplete = [bool]$bounded.Complete
        } catch [System.Net.WebException] {
            $errorResponse = $_.Exception.Response
            if ($null -ne $errorResponse) {
                try {
                    $status = [int]$errorResponse.StatusCode
                    $errorStream = $null
                    try {
                        $errorStream = $errorResponse.GetResponseStream()
                        if ($null -ne $errorStream) {
                            $bounded = Read-GsTrayBoundedBody -Stream $errorStream -TimeoutMs $TimeoutMs -Request $request
                            $bodyText = $bounded.Text
                            $bodyComplete = [bool]$bounded.Complete
                        }
                    } finally {
                        if ($null -ne $errorStream) { try { $errorStream.Close() } catch { } }
                    }
                } finally {
                    try { $errorResponse.Close() } catch { }
                }
            }
        } finally {
            if ($null -ne $response) { try { $response.Close() } catch { } }
        }
    } catch {
        $status = 0
        $bodyText = ''
        $bodyComplete = $false
        $bounded = $null
    }
    $parsed = ConvertFrom-GsServerInfoXml -XmlText $bodyText
    if (-not $bodyComplete) {
        $stopReason = ''
        if ($null -ne $bounded) { $stopReason = [string]$bounded.StopReason }
        $parseError = 'response body was truncated or oversized'
        if ($stopReason -eq 'cap') { $parseError = 'response body exceeded the 65536 byte cap' }
        elseif ($stopReason -eq 'timeout') { $status = 0; $parseError = 'serverinfo read timed out' }
        $parsed = [pscustomobject]@{ ProtocolStatus = 0; ParseOk = $false; State = ''; CurrentGame = ''; ParseError = $parseError }
    }
    if ($status -ne 200) { $parsed.ParseOk = $false }
    return [pscustomobject]@{
        HttpStatus = $status
        ProtocolStatus = $parsed.ProtocolStatus
        ParseOk = [bool]$parsed.ParseOk
        State = $parsed.State
        CurrentGame = $parsed.CurrentGame
        ParseError = $parsed.ParseError
    }
}

function Limit-GsTrayDetail {
    # The tray tooltip text is limited to 63 characters; keep every detail
    # inside that limit.
    param([string]$Text)
    if ($Text.Length -le 63) { return $Text }
    return $Text.Substring(0, 63)
}

function New-GsTrayStateRow {
    # Builds the Get-GsTrayState result row:
    # { State; Detail; DetailKey; DetailArgs; CanStart; CanStop }. Detail is
    # the English text (tray.log); DetailKey/DetailArgs name the string
    # table entry the UI translates (K4) - DetailArgs carries the format
    # arguments, e.g. the raw state value for detail.unknownState.
    param([string]$State, [string]$Detail, [bool]$CanStart, [bool]$CanStop, [string]$DetailKey = '', [object[]]$DetailArgs = @())
    return [pscustomobject]@{
        State   = $State
        Detail  = (Limit-GsTrayDetail $Detail)
        DetailKey = $DetailKey
        DetailArgs = $DetailArgs
        CanStart = $CanStart
        CanStop = $CanStop
    }
}

function Get-GsTrayUpState {
    # Maps a ready/running status value plus optional serverinfo to a row.
    # Ready/Streaming require HTTP 200 AND a valid parse AND protocol
    # status 200; anything else maps to an Error row. Error rows enable both
    # actions: when a ready streamer is unreachable or invalid, Stop is the
    # meaningful recovery.
    param($ServerInfo)

    $reachable = ($null -ne $ServerInfo -and $ServerInfo.HttpStatus -eq 200)
    if (-not $reachable) {
        return (New-GsTrayStateRow 'Error' 'runtime ready but serverinfo unreachable' $true $true -DetailKey 'detail.serverinfoUnreachable')
    }
    $parseValid = ($ServerInfo.ParseOk -and $ServerInfo.ProtocolStatus -eq 200)
    if (-not $parseValid) {
        return (New-GsTrayStateRow 'Error' 'runtime ready but serverinfo invalid' $true $true -DetailKey 'detail.serverinfoInvalid')
    }
    $gameText = ''
    if ($null -ne $ServerInfo.CurrentGame) { $gameText = ([string]$ServerInfo.CurrentGame).Trim() }
    $serverState = ''
    if ($null -ne $ServerInfo.State) { $serverState = ([string]$ServerInfo.State).Trim().ToUpperInvariant() }
    $hasGame = ($gameText -ne '' -and $gameText -ne '0')
    if ($hasGame -or $serverState.EndsWith('_SERVER_BUSY')) {
        return (New-GsTrayStateRow 'Streaming' 'Streaming' $false $true -DetailKey 'detail.streaming')
    }
    return (New-GsTrayStateRow 'Ready' 'Ready' $false $true -DetailKey 'detail.ready')
}

function Test-GsTrayTransitionStale {
    # A stopping/starting-family status is only trusted while its status
    # file is fresh: if the file has not been written for strictly longer
    # than the transition's grace period, the transition is treated as dead
    # (an Error row that enables both actions) instead of locking both menu
    # items forever. The grace period is 300 s for a 'stopping' status - the
    # same cap as the tray's own pending-action wait, because a real
    # official-service Stop measured 138-142 s (see docs/troubleshooting.md)
    # - and 120 s for the starting/launching/initializing family. Exactly at
    # the grace period the transition is still fresh - only strictly older
    # files count as stale. Without a usable LastWriteTimeUtc or -NowUtc the
    # transition is trusted (the default -NowUtc is the current time).
    [CmdletBinding()]
    param($StatusInfo, $NowUtc)

    if ($null -eq $NowUtc) { return $false }
    $written = $null
    if ($null -ne $StatusInfo) { $written = $StatusInfo.LastWriteTimeUtc }
    if ($null -eq $written) { return $false }
    $graceSec = 120
    if ($null -ne $StatusInfo -and $null -ne $StatusInfo.State -and ($StatusInfo.State -is [string])) {
        if ($StatusInfo.State.Trim().ToLowerInvariant() -eq 'stopping') { $graceSec = 300 }
    }
    $ageSec = ($NowUtc - ([DateTime]$written)).TotalSeconds
    return ($ageSec -gt $graceSec)
}

function Get-GsTrayUnderlyingState {
    # Maps a status read result (plus optional serverinfo) to a tray row,
    # ignoring any pending menu action. Every Error row enables both actions:
    # the tray cannot know the real runtime state, Start covers the common
    # recovery and Stop covers a hung runtime (ready but unreachable or
    # invalid) - Stop works from any state, so it is always a safe recovery.
    # Status 'stopping' maps to its own Stopping tray state (orange icon);
    # paused/idle/stopped map to Stopped. A stopping/starting-family status
    # whose file is strictly older than its grace period (300 s for
    # stopping, 120 s for the starting family; -NowUtc decides) counts as a
    # transition that did not finish and maps to an Error row instead of
    # the trusting Stopping/Starting rows.
    [CmdletBinding()]
    param($StatusInfo, $ServerInfo, $NowUtc = [DateTime]::UtcNow)

    if ($null -eq $StatusInfo -or -not $StatusInfo.Exists) {
        return (New-GsTrayStateRow 'Stopped' 'Stopped (no status file)' $true $false -DetailKey 'detail.stoppedNoStatusFile')
    }
    if (-not $StatusInfo.Readable) {
        return (New-GsTrayStateRow 'Error' 'Status file unreadable' $true $true -DetailKey 'detail.statusFileUnreadable')
    }
    if (-not [string]::IsNullOrEmpty($StatusInfo.Error)) {
        $detail = 'Status file error'
        $detailKey = 'detail.statusFileInvalid'
        if ($StatusInfo.Error -eq 'InvalidJson') { $detail = 'Status file invalid' }
        elseif ($StatusInfo.Error -eq 'MissingStateField') { $detail = 'Status file has no state field'; $detailKey = 'detail.statusFileNoStateField' }
        elseif ($StatusInfo.Error -eq 'InvalidStateField') { $detail = 'Status file has no valid state field'; $detailKey = 'detail.statusFileBadStateField' }
        return (New-GsTrayStateRow 'Error' $detail $true $true -DetailKey $detailKey)
    }
    $raw = ''
    if ($null -ne $StatusInfo.State) { $raw = [string]$StatusInfo.State }
    $state = $raw.Trim().ToLowerInvariant()
    switch ($state) {
        'ready' { return (Get-GsTrayUpState -ServerInfo $ServerInfo) }
        'running' { return (Get-GsTrayUpState -ServerInfo $ServerInfo) }
        'starting' {
            if (Test-GsTrayTransitionStale -StatusInfo $StatusInfo -NowUtc $NowUtc) { return (New-GsTrayStateRow 'Error' 'Starting did not finish' $true $true -DetailKey 'detail.startingDidNotFinish') }
            return (New-GsTrayStateRow 'Starting' 'Starting...' $false $true -DetailKey 'detail.starting')
        }
        'launching' {
            if (Test-GsTrayTransitionStale -StatusInfo $StatusInfo -NowUtc $NowUtc) { return (New-GsTrayStateRow 'Error' 'Starting did not finish' $true $true -DetailKey 'detail.startingDidNotFinish') }
            return (New-GsTrayStateRow 'Starting' 'Starting...' $false $true -DetailKey 'detail.starting')
        }
        'initializing' {
            if (Test-GsTrayTransitionStale -StatusInfo $StatusInfo -NowUtc $NowUtc) { return (New-GsTrayStateRow 'Error' 'Starting did not finish' $true $true -DetailKey 'detail.startingDidNotFinish') }
            return (New-GsTrayStateRow 'Starting' 'Starting...' $false $true -DetailKey 'detail.starting')
        }
        'stopped' { return (New-GsTrayStateRow 'Stopped' 'Stopped' $true $false -DetailKey 'detail.stopped') }
        'stopping' {
            if (Test-GsTrayTransitionStale -StatusInfo $StatusInfo -NowUtc $NowUtc) { return (New-GsTrayStateRow 'Error' 'Stopping did not finish' $true $true -DetailKey 'detail.stoppingDidNotFinish') }
            return (New-GsTrayStateRow 'Stopping' 'Stopping...' $false $false -DetailKey 'detail.stopping')
        }
        'paused' { return (New-GsTrayStateRow 'Stopped' 'Stopped' $true $false -DetailKey 'detail.stopped') }
        'idle' { return (New-GsTrayStateRow 'Stopped' 'Stopped' $true $false -DetailKey 'detail.stopped') }
        'failed' { return (New-GsTrayStateRow 'Error' 'Runtime reports failed' $true $true -DetailKey 'detail.runtimeFailed') }
        'error' { return (New-GsTrayStateRow 'Error' 'Runtime reports error' $true $true -DetailKey 'detail.runtimeError') }
        default { return (New-GsTrayStateRow 'Error' ('unknown state ' + $raw) $true $true -DetailKey 'detail.unknownState' -DetailArgs @($raw)) }
    }
}

function Get-GsTrayState {
    # Maps the current status read result, optional serverinfo, and a pending
    # menu action to the tray row { State; Detail; CanStart; CanStop }.
    # -NowUtc is handed to the underlying mapping (default: the current
    # time) and decides whether a stopping/starting-family status is stale.
    #
    # Pending action overrides (both menu items stay disabled while the
    # action is in flight):
    #   Start => Starting ('Starting...'),   Stop => Stopping ('Stopping...').
    [CmdletBinding()]
    param(
        $StatusInfo,
        $ServerInfo,
        [string]$PendingAction = '',
        $NowUtc = [DateTime]::UtcNow
    )

    $underlying = Get-GsTrayUnderlyingState -StatusInfo $StatusInfo -ServerInfo $ServerInfo -NowUtc $NowUtc
    $pending = ''
    if (-not [string]::IsNullOrWhiteSpace($PendingAction)) { $pending = $PendingAction.Trim().ToUpperInvariant() }
    if ($pending -eq 'START') {
        return (New-GsTrayStateRow 'Starting' 'Starting...' $false $false -DetailKey 'detail.starting')
    }
    if ($pending -eq 'STOP') {
        return (New-GsTrayStateRow 'Stopping' 'Stopping...' $false $false -DetailKey 'detail.stopping')
    }
    return $underlying
}

function New-GsTrayChildCommand {
    # Builds the hidden child powershell.exe command that runs one gs-product
    # CLI action and writes its serialized result to $ResultFile.
    #
    # Returns { FilePath; Arguments; EncodedCommand; Script }. The inner
    # script converts the CLI result to JSON (UTF-8, depth 8); if the CLI
    # throws, it writes { Success=$false; Errors=@({Code='CliException'}) }
    # instead. The directory creation, serialization and file write are
    # best effort: if any of them fails, the result file stays missing or
    # invalid and Read-GsTrayCommandResult reports NoResult - the child
    # still exits 0, and the tray always gets a result or NoResult, never
    # a thrown error dialog.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProductPath,
        [Parameter(Mandatory = $true)][ValidateSet('Start', 'Stop', 'Status', 'Recover')][string]$Action,
        [string]$StateDir = '',
        [string]$LogDir = '',
        [Parameter(Mandatory = $true)][string]$ResultFile
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('$ErrorActionPreference = ''Stop''')
    $lines.Add('try {')
    $call = '    $result = & ' + (ConvertTo-GsTraySingleQuoted $ProductPath) + ' -Action ' + $Action
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $call += ' -StateDir ' + (ConvertTo-GsTraySingleQuoted $StateDir) }
    if (-not [string]::IsNullOrWhiteSpace($LogDir)) { $call += ' -LogDir ' + (ConvertTo-GsTraySingleQuoted $LogDir) }
    $lines.Add($call)
    $lines.Add('} catch {')
    $lines.Add('    $result = [pscustomobject]@{ Success = $false; Data = $null; Errors = @([pscustomobject]@{ Code = ''CliException''; Message = $_.Exception.Message }) }')
    $lines.Add('}')
    $lines.Add('# Best effort: if any of this fails, the result file stays missing')
    $lines.Add('# or invalid and the tray reports NoResult.')
    $lines.Add('try {')
    $lines.Add('    $resultDir = Split-Path -Parent ' + (ConvertTo-GsTraySingleQuoted $ResultFile))
    $lines.Add('    if (-not (Test-Path -LiteralPath $resultDir)) { New-Item -ItemType Directory -Path $resultDir -Force | Out-Null }')
    $lines.Add('    $json = $result | ConvertTo-Json -Depth 8')
    $lines.Add('    [IO.File]::WriteAllText(' + (ConvertTo-GsTraySingleQuoted $ResultFile) + ', $json, (New-Object Text.UTF8Encoding($false)))')
    $lines.Add('} catch { }')
    # The result file alone carries the outcome: a failed write leaves it
    # missing or invalid and the tray reports NoResult. The child always
    # exits 0 so a write failure never looks like a CLI error exit code.
    $lines.Add('exit 0')
    $script = ($lines -join "`r`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    return [pscustomobject]@{
        FilePath = 'powershell.exe'
        Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $encoded
        EncodedCommand = $encoded
        Script = $script
    }
}

function Read-GsTrayCommandResult {
    # Parses a child result file into { Success; Code; Message; Reason } where
    # Code is the first error code (for example 'Busy') and Reason is the
    # first error's Reason field when it is a string (K3: a Recover refusal
    # arrives as Code='RecoverRefused' with Reason=<documented reason>), else
    # ''. A missing, empty, invalid, or unreadable file yields Code='NoResult'
    # (and Reason=''); so does a Success field that is not a JSON boolean, or
    # non-string Code/Message/Reason values.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $noResult = { param($Message) [pscustomobject]@{ Success = $false; Code = 'NoResult'; Message = $Message; Reason = '' } }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return (& $noResult 'Result file was not written.')
    }
    $text = $null
    try { $text = [IO.File]::ReadAllText($Path) } catch {
        return (& $noResult ('Result file could not be read: ' + $_.Exception.Message))
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return (& $noResult 'Result file is empty.') }
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json } catch {
        return (& $noResult ('Result file is not valid JSON: ' + $_.Exception.Message))
    }
    if ($parsed -is [System.Array]) {
        if (@($parsed).Count -eq 0) { return (& $noResult 'Result file holds an empty JSON array.') }
        # The CLI's return value is the last object on the pipeline; earlier
        # entries would be stray module output.
        $parsed = @($parsed)[$parsed.Count - 1]
    }
    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['Success']) {
        return (& $noResult 'Result file does not look like a CLI result.')
    }
    if (-not ($parsed.Success -is [bool])) {
        return (& $noResult 'Success field must be a JSON boolean.')
    }
    $success = [bool]$parsed.Success
    $code = ''
    $message = ''
    $reason = ''
    if (-not $success -and $null -ne $parsed.PSObject.Properties['Errors'] -and $null -ne $parsed.Errors) {
        $first = @($parsed.Errors)[0]
        if ($null -ne $first) {
            if ($null -ne $first.PSObject.Properties['Code'] -and $first.Code -is [string]) { $code = [string]$first.Code }
            if ($null -ne $first.PSObject.Properties['Message'] -and $first.Message -is [string]) { $message = [string]$first.Message }
            if ($null -ne $first.PSObject.Properties['Reason'] -and $first.Reason -is [string]) { $reason = [string]$first.Reason }
        }
    }
    return [pscustomobject]@{ Success = $success; Code = $code; Message = $message; Reason = $reason }
}

function Test-GsTrayPendingDone {
    # Pure decision for the pending-action poll. An already available
    # outcome is reported FIRST and wins over the elapsed time: 'Done' when
    # a usable result file has been parsed (Code other than 'NoResult') or
    # the child process is known to have exited - a child that finishes at
    # the wait boundary is reported by its real outcome, never as a
    # timeout. Only when there is no result and no known exit does the wait
    # cap decide: 'TimedOut' once the elapsed time is strictly past the cap
    # (exactly at the cap still waits), 'Waiting' otherwise. $null means
    # "unknown because the query threw": reading .HasExited on an elevated
    # child from a non-elevated tray can throw access denied, so an unknown
    # liveness keeps waiting until the cap. A Get-Process liveness check of
    # $null (process gone) counts as exited.
    [CmdletBinding()]
    param(
        $ResultParsed,
        $HasExited,
        $ProcessAlive,
        [double]$ElapsedSec = 0,
        [int]$TimeoutSec = 300
    )
    if ($null -ne $ResultParsed -and $ResultParsed.Code -ne 'NoResult') { return 'Done' }
    if ($HasExited -eq $true) { return 'Done' }
    if ($ProcessAlive -eq $false) { return 'Done' }
    if ($ElapsedSec -gt $TimeoutSec) { return 'TimedOut' }
    return 'Waiting'
}

function New-GsTraySupportCommand {
    # Builds the hidden child powershell.exe command that runs gs-support.ps1
    # once (K1) and writes the support result to $ResultFile. The child is
    # ALWAYS a plain Start-Process (never -Verb RunAs): the support bundle is
    # a read-only diagnostic, so the tray never elevates for it - a
    # non-elevated tray (the normal case via gs-tray.vbs) produces a
    # non-elevated child.
    #
    # Returns { FilePath; Arguments; EncodedCommand; Script }. The inner
    # script captures every gs-support.ps1 output element and keeps the LAST
    # one whose schemaVersion equals 1; if none qualifies it synthesizes
    # { schemaVersion = 1; Success = $false; Errors = @({ Code =
    # 'NoSchemaResult' }) }, and a throw becomes Code='CliException'. The
    # result write is best effort: a failed write leaves the file missing or
    # invalid and Read-GsTraySupportResult reports NoResult; the child still
    # exits 0 so a write failure never looks like a CLI error exit code.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SupportScriptPath,
        [Parameter(Mandatory = $true)][string]$ResultFile,
        [string]$InstallDir = '',
        [string]$StateDir = '',
        [string]$LogDir = '',
        [string]$TrayLogDir = '',
        [string]$ServerInfoUri = ''
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('$ErrorActionPreference = ''Stop''')
    $lines.Add('$result = $null')
    $lines.Add('try {')
    $call = '    $output = @(& ' + (ConvertTo-GsTraySingleQuoted $SupportScriptPath)
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) { $call += ' -InstallDir ' + (ConvertTo-GsTraySingleQuoted $InstallDir) }
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $call += ' -StateDir ' + (ConvertTo-GsTraySingleQuoted $StateDir) }
    if (-not [string]::IsNullOrWhiteSpace($LogDir)) { $call += ' -LogDir ' + (ConvertTo-GsTraySingleQuoted $LogDir) }
    if (-not [string]::IsNullOrWhiteSpace($TrayLogDir)) { $call += ' -TrayLogDir ' + (ConvertTo-GsTraySingleQuoted $TrayLogDir) }
    if (-not [string]::IsNullOrWhiteSpace($ServerInfoUri)) { $call += ' -ServerInfoUri ' + (ConvertTo-GsTraySingleQuoted $ServerInfoUri) }
    $call += ')'
    $lines.Add($call)
    $lines.Add('    foreach ($item in $output) {')
    $lines.Add('        $schema = $null')
    $lines.Add('        if ($null -ne $item -and $item.PSObject.Properties[''schemaVersion'']) { $schema = $item.schemaVersion }')
    $lines.Add('        if ($schema -eq 1) { $result = $item }')
    $lines.Add('    }')
    $lines.Add('    if ($null -eq $result) {')
    $lines.Add('        $result = [pscustomobject]@{ schemaVersion = 1; Success = $false; ZipPath = $null; Entries = @(); Errors = @([pscustomobject]@{ Code = ''NoSchemaResult''; Message = ''gs-support.ps1 produced no schemaVersion 1 result.'' }) }')
    $lines.Add('    }')
    $lines.Add('} catch {')
    $lines.Add('    $result = [pscustomobject]@{ schemaVersion = 1; Success = $false; ZipPath = $null; Entries = @(); Errors = @([pscustomobject]@{ Code = ''CliException''; Message = $_.Exception.Message }) }')
    $lines.Add('}')
    $lines.Add('# Best effort: if any of this fails, the result file stays missing')
    $lines.Add('# or invalid and the tray reports NoResult.')
    $lines.Add('try {')
    $lines.Add('    $resultDir = Split-Path -Parent ' + (ConvertTo-GsTraySingleQuoted $ResultFile))
    $lines.Add('    if (-not (Test-Path -LiteralPath $resultDir)) { New-Item -ItemType Directory -Path $resultDir -Force | Out-Null }')
    $lines.Add('    $json = $result | ConvertTo-Json -Depth 8')
    $lines.Add('    [IO.File]::WriteAllText(' + (ConvertTo-GsTraySingleQuoted $ResultFile) + ', $json, (New-Object Text.UTF8Encoding($false)))')
    $lines.Add('} catch { }')
    $lines.Add('exit 0')
    $script = ($lines -join "`r`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    return [pscustomobject]@{
        FilePath = 'powershell.exe'
        Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $encoded
        EncodedCommand = $encoded
        Script = $script
    }
}

function Read-GsTraySupportResult {
    # Parses a support bundle result file (K1 shape) into
    # { Success; ZipPath; Code; Message; SchemaVersion }. The same NoResult
    # rules as Read-GsTrayCommandResult apply (missing, empty, invalid,
    # unreadable file; Success must be a JSON boolean; Code/Message/ZipPath
    # must be strings), plus: a result whose schemaVersion is not the
    # integer 1 counts as NoResult - only a schemaVersion 1 element is a
    # usable K1 result.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $noResult = { param($Message) [pscustomobject]@{ Success = $false; ZipPath = ''; Code = 'NoResult'; Message = $Message; SchemaVersion = 0 } }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return (& $noResult 'Result file was not written.')
    }
    $text = $null
    try { $text = [IO.File]::ReadAllText($Path) } catch {
        return (& $noResult ('Result file could not be read: ' + $_.Exception.Message))
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return (& $noResult 'Result file is empty.') }
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json } catch {
        return (& $noResult ('Result file is not valid JSON: ' + $_.Exception.Message))
    }
    if ($parsed -is [System.Array]) {
        if (@($parsed).Count -eq 0) { return (& $noResult 'Result file holds an empty JSON array.') }
        $parsed = @($parsed)[$parsed.Count - 1]
    }
    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['Success']) {
        return (& $noResult 'Result file does not look like a support result.')
    }
    if (-not ($parsed.Success -is [bool])) {
        return (& $noResult 'Success field must be a JSON boolean.')
    }
    $schemaVersion = 0
    if ($parsed.PSObject.Properties['schemaVersion']) {
        $schemaValue = $parsed.schemaVersion
        if ($schemaValue -is [int] -or $schemaValue -is [long]) { $schemaVersion = [int]$schemaValue }
    }
    if ($schemaVersion -ne 1) { return (& $noResult 'Result is not a schemaVersion 1 support result.') }
    $zipPath = ''
    if ($parsed.PSObject.Properties['ZipPath'] -and $parsed.ZipPath -is [string]) { $zipPath = [string]$parsed.ZipPath }
    $code = ''
    $message = ''
    if (-not $parsed.Success -and $null -ne $parsed.PSObject.Properties['Errors'] -and $null -ne $parsed.Errors) {
        $first = @($parsed.Errors)[0]
        if ($null -ne $first) {
            if ($null -ne $first.PSObject.Properties['Code'] -and $first.Code -is [string]) { $code = [string]$first.Code }
            if ($null -ne $first.PSObject.Properties['Message'] -and $first.Message -is [string]) { $message = [string]$first.Message }
        }
    }
    return [pscustomobject]@{ Success = [bool]$parsed.Success; ZipPath = $zipPath; Code = $code; Message = $message; SchemaVersion = $schemaVersion }
}
