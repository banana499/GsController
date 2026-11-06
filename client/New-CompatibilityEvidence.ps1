#requires -Version 5.1
<#
.SYNOPSIS
  Create the evidence directory and record.md skeleton for one compatibility case.

.DESCRIPTION
  Reads every matrix table in docs/compatibility-test-plan.md whose header
  starts with "| ID |" (the MacBook CMP- matrix and the Android TV ATV-
  matrix), checks that -CaseId is one of their case IDs, and that case IDs
  are unique across all tables, then creates
  <EvidenceRoot>\compat-<CaseId>-<yyyyMMdd_HHmmss>\ and writes record.md with
  the case's settings and the fields the operator fills in. It does not start
  Moonlight, touch the host or collect any data. Returns the created path.

  CMP- cases get the P-COMMON record used so far, byte for byte unchanged.
  ATV- cases get a P-ANDROID record: the Moonlight Android overlay fields
  (Video stream:, Decoder:, Incoming frame rate from network:, Rendering
  frame rate:, Frames dropped by your network connection:, Average network
  latency:, Average decoding time:), the pre-connect HDMI mode and
  frac_rate_policy checks, and no Moonlight command line (Moonlight for
  Android has no command-line interface).

  EvidenceRoot must already exist and must be outside this repository.

  Test-only seam: -Now fixes the timestamp used for the evidence directory
  name and the Created line in record.md (a DateTime, or a string [datetime]
  can parse), so two runs can be compared byte for byte. Production callers
  omit it and get Get-Date.

.EXAMPLE
  .\New-CompatibilityEvidence.ps1 -CaseId CMP-HDR-01 -EvidenceRoot 'C:\gs-evidence'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    # Default (..\docs\compatibility-test-plan.md relative to this script) is
    # resolved in the body: PS 5.1 leaves $PSScriptRoot empty in param
    # defaults when the script is started with powershell.exe -File.
    [string]$PlanPath = '',
    # Test-only seam, documented in the comment help above. Not used in
    # production; omitted means Get-Date.
    [object]$Now = $null
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $PSBoundParameters.ContainsKey('PlanPath')) {
    $PlanPath = Join-Path $scriptDir '..\docs\compatibility-test-plan.md'
}

function New-ArgError([string]$Message, [string]$ParamName) {
    return (New-Object System.ArgumentException($Message, $ParamName))
}

function Split-MarkdownRow([string]$Line) {
    $t = $Line.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|')) { $t = $t.Substring(0, $t.Length - 1) }
    return , @($t.Split('|') | ForEach-Object { $_.Trim() })
}

# Reads EVERY markdown table whose header line starts with "| ID |" (not just
# the first) and returns all rows of all tables in document order, as ordered
# hashtables keyed by header column name. Throws when the same case ID appears
# in more than one table.
function Read-PlanMatrix([string]$Path) {
    $lines = [System.IO.File]::ReadAllLines($Path, (New-Object System.Text.UTF8Encoding($false)))
    $rows = @()
    $i = 0
    while ($i -lt $lines.Count) {
        if ($lines[$i] -notmatch '^\s*\|\s*ID\s*\|') { $i++; continue }
        $header = Split-MarkdownRow $lines[$i]
        $i++
        while ($i -lt $lines.Count -and $lines[$i] -match '^\s*\|') {
            if ($lines[$i] -notmatch '^\s*\|[\s:\-\|]+\|\s*$') {
                $cells = Split-MarkdownRow $lines[$i]
                $row = [ordered]@{}
                for ($c = 0; $c -lt $header.Count; $c++) {
                    $row[$header[$c]] = $(if ($c -lt $cells.Count) { $cells[$c].Trim('`').Trim() } else { '' })
                }
                $rows += , $row
            }
            $i++
        }
    }
    if ($rows.Count -eq 0) { throw (New-ArgError "No matrix table (header '| ID |') in plan: $Path" 'PlanPath') }
    $ids = @($rows | ForEach-Object { [string]$_['ID'] } | Where-Object { $_ })
    $dupes = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($dupes.Count -gt 0) {
        throw (New-ArgError ("Duplicate case ID(s) across matrix tables: {0}" -f ($dupes -join ', ')) 'PlanPath')
    }
    return , $rows
}

function Get-Cell($Row, [string]$Name) {
    if ($Row.Contains($Name)) { return [string]$Row[$Name] }
    return ''
}

# Expected Moonlight 6.2.0 values for the case's codec/HDR flags (P-VIDEO table).
function Get-ExpectedVideo([string]$Settings) {
    $codec = ''
    if ($Settings -match '--video-codec\s+(\S+)') { $codec = $Matches[1] }
    $hdr = $Settings -match '(^|\s)--hdr(\s|$)'
    $table = @{
        'H.264|False' = @('0x1', 'H.264')
        'HEVC|False'  = @('0x100', 'HEVC')
        'HEVC|True'   = @('0x200', 'HEVC 10-bit HDR')
        'AV1|False'   = @('0x1000', 'AV1')
        'AV1|True'    = @('0x2000', 'AV1 10-bit HDR')
    }
    $key = "$codec|$hdr"
    if ($table.ContainsKey($key)) { return $table[$key] }
    return $null
}

# ---- Validate input ----
# Strict CaseId shape. A path-like CaseId (e.g. 'X\..\..\outside') must be
# rejected here, before any plan lookup or filesystem access: the evidence
# directory name is built with Join-Path, so a CaseId carrying separators or
# dot segments could otherwise escape EvidenceRoot.
if ($CaseId -cnotmatch '^[A-Z]{2,6}(-[A-Z0-9]{1,8}){1,3}$') {
    throw (New-ArgError "CaseId must match ^[A-Z]{2,6}(-[A-Z0-9]{1,8}){1,3}$ : $CaseId" 'CaseId')
}
if ([string]::IsNullOrWhiteSpace($PlanPath) -or -not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw (New-ArgError "Plan not found: $PlanPath" 'PlanPath')
}
$planFull = (Resolve-Path -LiteralPath $PlanPath).ProviderPath
$rows = Read-PlanMatrix $planFull
$ids = @($rows | ForEach-Object { Get-Cell $_ 'ID' } | Where-Object { $_ })
$row = $null
foreach ($r in $rows) { if ((Get-Cell $r 'ID') -ceq $CaseId) { $row = $r; break } }
if ($null -eq $row) {
    throw (New-ArgError ("Unknown CaseId '{0}'. Known IDs: {1}" -f $CaseId, ($ids -join ', ')) 'CaseId')
}

if ([string]::IsNullOrWhiteSpace($EvidenceRoot) -or -not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) {
    throw (New-ArgError "EvidenceRoot does not exist or is not a directory: $EvidenceRoot" 'EvidenceRoot')
}
$rootFull = (Resolve-Path -LiteralPath $EvidenceRoot).ProviderPath
$repoFull = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
$rootCmp = $rootFull.TrimEnd('\') + '\'
$repoCmp = $repoFull.TrimEnd('\') + '\'
if ($rootCmp.StartsWith($repoCmp, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw (New-ArgError "EvidenceRoot must be outside the repository ($repoFull): $rootFull" 'EvidenceRoot')
}

# ---- Create directory ----
# Note: the effective timestamp is $runTime, not $now - $now and $Now are the
# same variable in PowerShell (names are case-insensitive), so reading -Now
# through $now would clobber the parameter.
$runTime = Get-Date
if ($null -ne $Now) {
    try { $runTime = [datetime]$Now } catch { throw (New-ArgError "Now is not a DateTime or date string: '$Now'" 'Now') }
}
$dir = Join-Path $rootFull ('compat-{0}-{1}' -f $CaseId, $runTime.ToString('yyyyMMdd_HHmmss'))
# Normalized containment: the destination must resolve to a path inside
# EvidenceRoot (defense in depth on top of the CaseId shape rule above).
$dirFull = [System.IO.Path]::GetFullPath($dir)
$rootPrefix = $rootFull.TrimEnd('\') + '\'
if (-not $dirFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw (New-ArgError "Destination escapes EvidenceRoot ($rootFull): $dirFull" 'EvidenceRoot')
}
if (Test-Path -LiteralPath $dir) { throw "Evidence directory already exists: $dir" }
New-Item -ItemType Directory -Path $dir | Out-Null

# ---- Build record.md ----
$dimension = Get-Cell $row 'Dimension'
$settings = Get-Cell $row 'Settings'
$tokens = @($dimension -split '\+' | ForEach-Object { $_.Trim() })
$isAudio51 = $tokens -contains '5.1'
$isAudio71 = $tokens -contains '7.1'
$isGamepad = @($tokens | Where-Object { $_ -like 'Gamepad-*' }).Count -gt 0
$isHdr = $settings -match '(^|\s)--hdr(\s|$)'
$expected = Get-ExpectedVideo $settings
$isAtv = ((Get-Cell $row 'ID') -cmatch '^ATV-')

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Compatibility evidence: $CaseId")
$md.Add('')
$md.Add("Created: $($runTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
$md.Add("Plan: ``docs/compatibility-test-plan.md``")
$md.Add("Evidence directory: ``$dir``")
$md.Add('')
$md.Add('## Case (from the plan)')
$md.Add('')
$md.Add('| Field | Value |')
$md.Add('|---|---|')
foreach ($name in @('Dimension', 'Prerequisites', 'Procedure', 'Pass criteria', 'Evidence required')) {
    $md.Add("| $name | $(Get-Cell $row $name) |")
}
$md.Add('')
if ($isAtv) {
    $md.Add('Moonlight settings (entered in the Moonlight Android settings UI; there are no command-line flags):')
} else {
    $md.Add('Moonlight settings:')
}
$md.Add('')
$md.Add('```text')
$md.Add($settings)
$md.Add('```')
$md.Add('')
if ($isAtv) {
    # ATV- record: P-ANDROID checks and overlay fields; no Moonlight command
    # line anywhere (Moonlight for Android has none).
    $expectedCodec = ''
    if ($settings -match 'codec\s+([A-Za-z0-9.]+)') { $expectedCodec = $Matches[1] }
    $decoderCriterion = 'names the row''s codec; a pass requires this confirmation'
    if ($expectedCodec) { $decoderCriterion = "names ``$expectedCodec``; a pass requires this confirmation" }
    $md.Add('## Run details (fill in)')
    $md.Add('')
    $md.Add('| Field | Value |')
    $md.Add('|---|---|')
    $md.Add('| Operator |  |')
    $md.Add('| Run date and time |  |')
    $md.Add('| Client device |  |')
    $md.Add('| Client OS (Android version) |  |')
    $md.Add('| Moonlight version |  |')
    $md.Add('| Network (wired) |  |')
    $md.Add('| Host GPU / driver (as reported by the operator) |  |')
    $md.Add('| Result status (pass / fail / unsupported / not covered) | not covered |')
    $md.Add('| Reason (required for fail and unsupported) |  |')
    $md.Add('')
    $md.Add('## Pre-connect checks (P-ANDROID)')
    $md.Add('')
    $md.Add('| Check | Value |')
    $md.Add('|---|---|')
    $md.Add('| Moonlight settings pages screenshot taken (`settings-page.png`) |  |')
    $md.Add('| HDMI output mode read before connecting (expected 2160p60, YCbCr 4:2:0, 8-bit) |  |')
    $md.Add('| `frac_rate_policy` read before connecting (value recorded) |  |')
    $md.Add('')
    $md.Add('## Performance overlay (P-ANDROID)')
    $md.Add('')
    $md.Add("Read the overlay fields in Moonlight Android's original wording from ``overlay.png``. Capture it binary-safe from PowerShell with ``cmd /c ""adb exec-out screencap -p > overlay.png""``; PowerShell's own ``>`` redirection re-encodes the binary PNG and corrupts it (operator step only):")
    $md.Add('')
    $md.Add('| Overlay field | Value | Pass criterion |')
    $md.Add('|---|---|---|')
    $md.Add('| `Video stream:` |  | matches the row''s resolution and FPS |')
    $md.Add("| ``Decoder:`` |  | $decoderCriterion |")
    $md.Add('| `Incoming frame rate from network:` |  | at least 57 FPS |')
    $md.Add('| `Rendering frame rate:` |  | at least 55 FPS |')
    $md.Add('| `Frames dropped by your network connection:` |  | at most 1% |')
    $md.Add('| `Average network latency:` |  | recorded as an observation |')
    $md.Add('| `Average decoding time:` |  | recorded as an observation |')
    $md.Add('')
    $md.Add('Pass thresholds follow P-COMMON: incoming and decoding frame rate at least 57 FPS, rendering frame rate at least 55 FPS, frames dropped by the network at most 1%.')
    $md.Add('A silent fallback is never a pass: the Android "Prefer AV1" option can fall back to another codec without a warning, so a pass requires the codec confirmed on the `Decoder:` line.')
    $md.Add('')
    $md.Add('## Session and host steps (P-ANDROID; host steps are P-COMMON steps 2, 7, 8)')
    $md.Add('')
    $md.Add('| Check | Value |')
    $md.Add('|---|---|')
    $md.Add('| Host: product Start and `host-status-before.txt` saved (P-COMMON step 2) |  |')
    $md.Add('| Stream started from the Moonlight Android UI with the row settings |  |')
    $md.Add('| 60-second steady window held; overlay captured at 30 seconds or later |  |')
    $md.Add('| Only the `com.limelight` lines extracted from logcat to `logcat-limelight.txt` |  |')
    $md.Add('| Host: streamer Qos lines saved to `host-qos.txt` (P-COMMON step 7) |  |')
    $md.Add('| Stream quit normally from the Moonlight UI (no force-stop) |  |')
    $md.Add('| Host available again within 10 seconds; `host-status-after.txt` saved (P-COMMON step 8) |  |')
    $md.Add('')
    $md.Add('## Observations')
    $md.Add('')
    $md.Add('')
    $md.Add('## Files')
    $md.Add('')
    $md.Add('Do not add pairing data, certificates, keys or the Moonlight settings store. Never copy the full logcat.')
    $md.Add('')
    $md.Add('| File | Present | Notes |')
    $md.Add('|---|---|---|')
    $files = @('settings-page.png', 'overlay.png', 'logcat-limelight.txt',
        'host-status-before.txt', 'host-status-after.txt', 'host-qos.txt')
    foreach ($f in $files) { $md.Add("| $f |  |  |") }
} else {
    $md.Add('## Run details (fill in)')
    $md.Add('')
    $md.Add('| Field | Value |')
    $md.Add('|---|---|')
    $md.Add('| Operator |  |')
    $md.Add('| Run date and time |  |')
    $md.Add('| Client device |  |')
    $md.Add('| Client OS |  |')
    $md.Add('| Moonlight version |  |')
    $md.Add('| Network (Wi-Fi / wired) |  |')
    $md.Add('| Host GPU / driver (as reported by the operator) |  |')
    if ($isHdr) { $md.Add('| Host streamed display HDR on (Windows Settings) |  |') }
    $md.Add('| Result status (pass / fail / unsupported / not covered) | not covered |')
    $md.Add('| Reason (required for fail and unsupported) |  |')
    $md.Add('')
    $md.Add('## Common checks (P-COMMON)')
    $md.Add('')
    $md.Add('| Check | Value |')
    $md.Add('|---|---|')
    $md.Add('| `Launch response` status_code |  |')
    if ($null -ne $expected) {
        $md.Add("| ``Video stream is`` line (expect 3840x2160x60, format $($expected[0])) |  |")
        $md.Add("| Overlay codec (expect ``$($expected[1])``) |  |")
    } else {
        $md.Add('| `Video stream is` line |  |')
        $md.Add('| Overlay codec |  |')
    }
    $md.Add('| Incoming / decoding / rendering FPS |  |')
    $md.Add('| Frames dropped by network (%) |  |')
    $md.Add('| Host Qos Frame Number increasing / Avg Game FPS |  |')
    $md.Add('| Launch warnings (exact text) |  |')
    $md.Add('| Disconnects during steady window |  |')
    $md.Add('| Seconds until host available after quit |  |')
    $md.Add('| Product Status after quit |  |')
    if ($isHdr) {
        $md.Add('')
        $md.Add('## HDR visual check (P-VIDEO)')
        $md.Add('')
        $md.Add('| Check | Value |')
        $md.Add('|---|---|')
        $md.Add('| Test pattern or video used |  |')
        $md.Add('| Highlights brighter than SDR white |  |')
        $md.Add('| Colours not washed out |  |')
        $md.Add('| macOS display preset |  |')
    }
    if ($isAudio51 -or $isAudio71) {
        $channels = @(
            @('FL', 'Front left'), @('FR', 'Front right'), @('FC', 'Front centre'),
            @('LFE', 'Subwoofer'), @('BL', 'Back left'), @('BR', 'Back right'))
        if ($isAudio71) { $channels += , @('SL', 'Side left'); $channels += , @('SR', 'Side right') }
        $md.Add('')
        $md.Add('## Audio channel check (P-AUDIO)')
        $md.Add('')
        $md.Add('| Check | Value |')
        $md.Add('|---|---|')
        $md.Add('| Client output device and channel count (Audio MIDI Setup) |  |')
        $md.Add(('| `Audio channel count` / `Audio channel mask` (expect {0}) |  |' -f $(if ($isAudio71) { '8 / 63F' } else { '6 / 3F' })))
        $md.Add('| Channel test clip used |  |')
        $md.Add('')
        $md.Add('| Channel | Expected speaker | Heard at | OK |')
        $md.Add('|---|---|---|---|')
        foreach ($ch in $channels) { $md.Add("| $($ch[0]) | $($ch[1]) |  |  |") }
    }
    if ($isGamepad) {
        $md.Add('')
        $md.Add('## Gamepad check (P-GAMEPAD)')
        $md.Add('')
        $md.Add('| Check | Value |')
        $md.Add('|---|---|')
        $md.Add('| Controller model and connection (USB / Bluetooth) |  |')
        $md.Add('| Client log `Gamepad 0 (player 1) is:` line |  |')
        $md.Add('| Host joy.cpl lists a controller (type shown) |  |')
        $md.Add('| Face buttons, shoulders, Start, Back |  |')
        $md.Add('| Triggers (analog travel) |  |')
        $md.Add('| Both sticks (full range) and D-pad |  |')
        $md.Add('| Disconnect: `Gamepad 0 is gone`, joy.cpl clears within 5 s, stream continues |  |')
        $md.Add('| Reconnect: new `Gamepad ... is:` line, input in joy.cpl within 10 s, no relaunch |  |')
        $md.Add('| Rumble / touchpad / motion (observation only) |  |')
    }
    $md.Add('')
    $md.Add('## Observations')
    $md.Add('')
    $md.Add('')
    $md.Add('## Files')
    $md.Add('')
    $md.Add('Do not add pairing data, certificates, keys or the Moonlight settings store.')
    $md.Add('')
    $md.Add('| File | Present | Notes |')
    $md.Add('|---|---|---|')
    $files = @('moonlight-client.log', 'key-lines.txt', 'overlay.png', 'launch-warning.png',
        'host-status-before.txt', 'host-status-after.txt', 'host-qos.txt')
    if ($isAudio51 -or $isAudio71) { $files += 'client-audio-device.png' }
    if ($isGamepad) { $files += 'host-joycpl.png' }
    foreach ($f in $files) { $md.Add("| $f |  |  |") }
}

$recordPath = Join-Path $dir 'record.md'
[System.IO.File]::WriteAllText($recordPath, (($md -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

return $dir
