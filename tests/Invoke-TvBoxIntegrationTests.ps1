# GsTestKind: integration
#Requires -Version 5.1
<#
.SYNOPSIS
    Integration test: runs client/Get-TvBoxCapabilities.ps1 against a real
    Android TV box and checks the result.

.DESCRIPTION
    The box address comes from -Device or, when that is omitted, from the
    GS_TVBOX_DEVICE environment variable (for example 192.0.2.10:5555). The
    repository does not store the real address. The adb executable comes
    from -AdbPath or, when that is omitted, from the first adb.exe on PATH;
    only a real adb.exe file counts, interpreter shims are ignored. With no
    device, unresolvable adb, or the box not in the 'device' state, every
    test prints a SKIP line with the reason and the suite exits 0.

    The probe runs in a child powershell.exe. It is read-only; this test
    only reads its JSON. Nothing here runs adb connect, pairs, changes
    settings or starts apps. Only the coordinator session operates the box,
    so run this only when no other session is driving it.

    By default only the structure is checked: schemaVersion 1, reachable,
    no collection errors, every derived flag has a value, and no MAC-looking
    token or long hex run in the JSON. Device-specific checks run only when
    their expected value is given:
        GS_TVBOX_EXPECT_MODEL   expected ro.product.model
        GS_TVBOX_EXPECT_MODE    expected /sys/class/display/mode
    and are SKIP otherwise.

    Exits 1 when a test fails; otherwise 0 (skips alone are fine).
#>
[CmdletBinding()]
param(
    [string]$AdbPath = '',
    [string]$Device = '',
    [ValidateRange(1, 600)]
    [int]$TimeoutSec = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$probePath = Join-Path $repoRoot 'client\Get-TvBoxCapabilities.ps1'

if (-not $PSBoundParameters.ContainsKey('Device')) { $Device = [string]$env:GS_TVBOX_DEVICE }
$Device = $Device.Trim()

# adb resolution mirrors the probe: an explicit -AdbPath wins, otherwise
# the first adb.exe on PATH. Only a real adb.exe file counts, so aliases,
# functions and .bat/.cmd shims are never considered. Each PATH entry is
# normalized to an absolute candidate; entries on a dead drive, with
# invalid characters or otherwise unreadable are skipped, so a broken PATH
# only turns every test into a SKIP. Nothing is run here.
if (-not $PSBoundParameters.ContainsKey('AdbPath') -and [string]::IsNullOrWhiteSpace($AdbPath)) {
    foreach ($dir in @(($env:PATH -split ';') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })) {
        try {
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $dir 'adb.exe'))
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) { $AdbPath = $candidate; break }
        } catch {
            continue
        }
    }
}
$expectModel = ([string]$env:GS_TVBOX_EXPECT_MODEL).Trim()
$expectMode = ([string]$env:GS_TVBOX_EXPECT_MODE).Trim()

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

# $SkipReason set by the caller skips this one test; $script:SkipReason
# (no device, box unreachable) skips every test.
function Invoke-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$SkipReason = ''
    )
    if ($null -ne $script:SkipReason) { $SkipReason = $script:SkipReason }
    if ($SkipReason -ne '') {
        $script:Skipped++
        Write-Host "SKIP $Name :: $SkipReason"
        return
    }
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name :: $($_.Exception.Message)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message (expected '$Expected', actual '$Actual')"
    }
}

$script:SkipReason = $null
$probe = $null
$probeExit = $null
$probeJson = ''

# The probe itself decides reachability (adb get-state == 'device'); its
# exit 2 means the box is unreachable, which is a SKIP here.
$outFile = Join-Path ([System.IO.Path]::GetTempPath()) ('GsTvBoxIntegration_' + [guid]::NewGuid().ToString('N') + '.json')
try {
    if ($Device -eq '') {
        $script:SkipReason = 'no TV box configured; set GS_TVBOX_DEVICE=<box-ip>:5555 (or pass -Device) to run against a real box'
    } elseif ([string]::IsNullOrEmpty($AdbPath) -or -not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
        $script:SkipReason = "adb not found ($AdbPath); pass -AdbPath or put adb.exe on PATH"
    } else {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $null = & $exe -NoProfile -ExecutionPolicy Bypass -File $probePath -AdbPath $AdbPath -Device $Device -TimeoutSec $TimeoutSec -OutFile $outFile
        $probeExit = $LASTEXITCODE
        if (Test-Path -LiteralPath $outFile) {
            $probeJson = [System.IO.File]::ReadAllText($outFile)
            $probe = $probeJson | ConvertFrom-Json
        }
        if ($probeExit -eq 2 -and $null -ne $probe) {
            $conn = @(@($probe.errors) | Where-Object { $null -ne $_ -and $_.field -eq 'connection' })
            $why = $(if ($conn.Count -gt 0) { '{0}: {1}' -f $conn[0].code, $conn[0].message } else { 'probe exit 2' })
            $script:SkipReason = "TV box $Device not reachable over ADB ($why); connect it with 'adb connect $Device' and rerun"
        }
    }
} finally {
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
}

Invoke-Test 'probe ran and wrote JSON' {
    Assert-True ($null -ne $probe) "no JSON (probe exit $probeExit)"
    Assert-True ($probeExit -eq 0 -or $probeExit -eq 1) "probe exit $probeExit"
}

Invoke-Test 'schemaVersion is 1 and the box is reachable' {
    Assert-Equal 1 $probe.schemaVersion 'schemaVersion'
    Assert-True ($probe.reachable -eq $true) 'reachable'
}

Invoke-Test 'probe reported no collection errors' {
    $errs = @(@($probe.errors) | Where-Object { $null -ne $_ })
    Assert-Equal 0 $errs.Count ('errors: ' + ($errs | ConvertTo-Json -Compress -Depth 4))
}

Invoke-Test 'derived flags are all collected (none null)' {
    foreach ($name in @('supports4k60', 'fourK60ColorFormat', 'supportsHdr', 'hasAv1Decoder', 'maxPcmChannels')) {
        Assert-True ($null -ne $probe.flags.$name) "flags.$name is null"
    }
}

Invoke-Test 'JSON contains no MAC-looking token or 12+ hex run' {
    Assert-True ($probeJson -notmatch '(?i)(?<![0-9a-z])[0-9a-f]{2}([:-])[0-9a-f]{2}(\1[0-9a-f]{2}){4}(?![0-9a-z])') 'MAC-looking token'
    Assert-True ($probeJson -notmatch '(?i)(?<![0-9a-z])(0x)?[0-9a-f]{12,}(?![0-9a-z])') '12+ hex run'
    Assert-True ($probeJson -notmatch '(?i)serial') 'the word serial'
}

Invoke-Test 'model matches GS_TVBOX_EXPECT_MODEL' -SkipReason $(if ($expectModel -eq '') { 'GS_TVBOX_EXPECT_MODEL not set' } else { '' }) {
    Assert-Equal $expectModel $probe.device.model 'ro.product.model'
}

Invoke-Test 'HDMI output mode matches GS_TVBOX_EXPECT_MODE' -SkipReason $(if ($expectMode -eq '') { 'GS_TVBOX_EXPECT_MODE not set' } else { '' }) {
    Assert-Equal $expectMode $probe.hdmi.currentMode '/sys/class/display/mode'
}

Write-Host ("Summary: {0} passed, {1} failed (skipped: {2})" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0) { exit 1 }
if ($script:Passed -eq 0 -and $script:Skipped -eq 0) { exit 1 }
exit 0
