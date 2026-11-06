#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only capability probe for the Android TV box client, over ADB.

.DESCRIPTION
    Runs read-only commands on the box through `adb -s <Device> shell`:
    getprop of whitelisted keys, cat of /sys, /proc and
    /vendor/etc/media_codecs*.xml files, dumpsys and ip. Prints one JSON object
    (schemaVersion 1) with the sections device, hdmi, hdr, decoders, audio,
    network and moonlight, plus collectedAtUtc and errors[].

    Derived flags keep their raw source next to them: hdmi.supports4k60,
    hdr.supportsHdr, decoders.hasAv1Decoder and audio.maxPcmChannels. Each is
    { value, source, raw }; value is null when its input could not be read
    or parsed.

    A failing, timed-out or unparsable call leaves its field null and adds an
    errors entry { field, code, command, message }. When the box is
    unreachable (adb get-state is not 'device') every section is null.
    Nothing is guessed or filled in from defaults.

    Identifiers are never kept. Only the whitelisted getprop keys are read
    (never ro.serialno). Of the EDID text only the TMDS clock and SCDC lines
    are kept (not the serial number or product name). Every output is
    scrubbed of MAC-looking tokens and of hex runs of 12 or more digits
    before it is parsed, and the final JSON is scrubbed again.

    The probe never runs adb connect, never changes a setting and never
    touches ADB authorization. Connect the box first (adb connect).

    The adb executable is resolved as follows: an explicit -AdbPath wins;
    otherwise the first adb.exe on PATH is used. PATH resolution accepts
    only a real adb.exe file: aliases, functions and .bat/.cmd interpreter
    shims are ignored, and the resolved path is handed to CreateProcess
    directly, so nothing is ever started through a shell or a command
    string. PATH entries on a dead drive or with invalid characters are
    skipped, and candidates are normalized to absolute paths. When nothing
    resolves, the result is a structured AdbNotFound
    error (exit 2) and no process is started. With an injected -AdbRunner
    nothing is resolved at all and the runner receives the -AdbPath value
    as given (empty when omitted), so unit tests never depend on what is
    installed on the machine.

    Exit codes: 0 every field collected; 1 collected with errors; 2 no
    device given, adb not found or box unreachable (every section null).

.PARAMETER Device
    adb target, for example 192.0.2.10:5555. When omitted, the value of the
    GS_TVBOX_DEVICE environment variable is used. With neither, nothing is
    run and the result is a NoDevice error (exit 2). The repository never
    stores the real address.

.PARAMETER AdbPath
    Full path to adb.exe, including spaces when present. Default: empty,
    which resolves to the first adb.exe on PATH (see above). With an
    injected -AdbRunner the value is passed through without any existence
    check.

.PARAMETER AdbRunner
    Test seam. Called as: & $AdbRunner <AdbPath> <string[] Arguments> <TimeoutSec>
    It returns an object or hashtable with ExitCode (int), StdOut and StdErr
    (strings) and TimedOut (bool). The default runs adb as a child process
    and kills it when it overruns TimeoutSec. A call that takes longer than
    TimeoutSec plus 1 second is a Timeout whatever it returned.

.EXAMPLE
    .\Get-TvBoxCapabilities.ps1 -Device 192.0.2.10:5555 -OutFile C:\gs-evidence\tvbox-probe-20261031_120000\probe.json
#>
[CmdletBinding()]
param(
    [string]$AdbPath = '',
    [string]$Device = '',
    [string]$OutFile = '',
    [scriptblock]$AdbRunner = $null,
    [ValidateRange(1, 600)]
    [int]$TimeoutSec = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('Device') -and -not [string]::IsNullOrWhiteSpace($env:GS_TVBOX_DEVICE)) {
    $Device = $env:GS_TVBOX_DEVICE
}
$Device = $Device.Trim()

# Resolves the adb executable: an explicit -AdbPath wins, otherwise the
# first adb.exe on PATH. Only a real adb.exe file counts: aliases and
# functions are not consulted, .bat/.cmd interpreter shims are ignored, and
# the resolved path is handed to CreateProcess directly (never through a
# shell or a command string). Each PATH entry is normalized to an absolute
# candidate; entries on a dead drive, with invalid characters or otherwise
# unreadable are skipped, so a broken PATH can never abort the probe - the
# worst case is a structured AdbNotFound. With an injected -AdbRunner
# nothing is resolved, so unit tests never depend on what is installed on
# this machine.
function Find-AdbOnPath {
    foreach ($dir in @(($env:PATH -split ';') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })) {
        try {
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $dir 'adb.exe'))
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) { return $candidate }
        } catch {
            continue
        }
    }
    return ''
}

$explicitAdb = ''
if ($PSBoundParameters.ContainsKey('AdbPath')) { $explicitAdb = $AdbPath.Trim() }
if ($explicitAdb -ne '') {
    $AdbPath = $explicitAdb
} elseif ($null -ne $AdbRunner) {
    $AdbPath = ''
} else {
    $AdbPath = Find-AdbOnPath
}

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$HdmiDir = '/sys/class/amhdmitx/amhdmitx0'
$NetDir = '/sys/class/net/eth0'

# The only getprop keys the probe reads. ro.serialno and the like are never asked for.
$PropKeys = [ordered]@{
    model          = 'ro.product.model'
    brand          = 'ro.product.brand'
    boardPlatform  = 'ro.board.platform'
    androidRelease = 'ro.build.version.release'
    sdk            = 'ro.build.version.sdk'
    cpuAbiList     = 'ro.product.cpu.abilist'
}

# Every shell command must match one of these read-only shapes before it is sent.
$ReadOnlyCommandPatterns = @(
    ('^getprop (' + ((@($PropKeys.Values) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'),
    '^cat /sys/[A-Za-z0-9_./-]+$',
    '^cat /proc/meminfo$',
    '^cat /vendor/etc/media_codecs\*\.xml$',
    '^dumpsys (SurfaceFlinger|media\.player|package com\.limelight)$',
    '^ip -4 addr show [a-z0-9]+$'
)

# Replaces MAC-looking tokens and hex runs of 12+ digits (serials, Android IDs).
function Remove-Identifiers {
    param($Text)
    if ($null -eq $Text) { return $null }
    $t = [regex]::Replace([string]$Text, '(?i)(?<![0-9a-z])[0-9a-f]{2}([:-])[0-9a-f]{2}(?:\1[0-9a-f]{2}){4}(?![0-9a-z])', '[REDACTED-MAC]')
    $t = [regex]::Replace($t, '(?i)(?<![0-9a-z])(?:0x)?[0-9a-f]{12,}(?![0-9a-z])', '[REDACTED-HEX]')
    return $t
}

# Quotes one argument for CreateProcess the way the MSVC runtime splits it.
function ConvertTo-WindowsArgument {
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') { $backslashes++; continue }
        if ($ch -eq [char]'"') {
            [void]$sb.Append([char]'\', 2 * $backslashes + 1)
        } elseif ($backslashes -gt 0) {
            [void]$sb.Append([char]'\', $backslashes)
        }
        [void]$sb.Append($ch)
        $backslashes = 0
    }
    if ($backslashes -gt 0) { [void]$sb.Append([char]'\', 2 * $backslashes) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Default runner: one adb child process, stdin closed, stdout/stderr read
# asynchronously, killed when it overruns TimeoutSec. Output that is still
# open after the kill (a grandchild holding the pipe) is not waited for.
function Invoke-AdbProcess {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutSec)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Path
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $timedOut = $false
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            try { $p.Kill() } catch { }
            [void]$p.WaitForExit(5000)
        }
        $drained = [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 2000)
        if (-not $drained) { $timedOut = $true }
        $exitCode = -1
        if ($p.HasExited -and -not $timedOut) { $exitCode = $p.ExitCode }
        $stdout = ''
        $stderr = ''
        if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $stdout = $outTask.Result }
        if ($errTask.IsCompleted -and -not $errTask.IsFaulted) { $stderr = $errTask.Result }
        return @{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr; TimedOut = $timedOut }
    } finally {
        $p.Dispose()
    }
}

$script:Errors = New-Object System.Collections.Generic.List[object]

function Add-ProbeError {
    param([string]$Field, [string]$Code, [string]$Command, [string]$Message)
    $m = Remove-Identifiers ([string]$Message)
    $m = ($m -replace '\s+', ' ').Trim()
    if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
    $script:Errors.Add([ordered]@{ field = $Field; code = $Code; command = $Command; message = $m })
}

# Runs adb with the given arguments through the runner and normalizes the
# result. Returns @{ Ok; Code; StdOut; Message }; StdOut is already scrubbed
# of identifiers. Never throws.
function Invoke-Adb {
    param([string[]]$Arguments)
    $runner = $AdbRunner
    if ($null -eq $runner) { $runner = ${function:Invoke-AdbProcess} }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = @(& $runner $AdbPath $Arguments $TimeoutSec) | Select-Object -Last 1
    } catch {
        return @{ Ok = $false; Code = 'RunnerError'; StdOut = ''; Message = $_.Exception.Message }
    }
    $sw.Stop()
    $exitCode = $null; $stdout = ''; $stderr = ''; $timedOut = $false
    try {
        $exitCode = $r.ExitCode
        if ($null -ne $r.StdOut) { $stdout = [string]$r.StdOut }
        if ($null -ne $r.StdErr) { $stderr = [string]$r.StdErr }
        $timedOut = [bool]$r.TimedOut
    } catch {
        return @{ Ok = $false; Code = 'RunnerError'; StdOut = ''; Message = ('runner returned an unexpected result: ' + $_.Exception.Message) }
    }
    # Some Amlogic sysfs files (aud_cap) embed NUL bytes; drop control
    # characters other than tab and newlines before anything is parsed.
    $stdout = Remove-Identifiers ([regex]::Replace($stdout, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''))
    $stderr = Remove-Identifiers ([regex]::Replace($stderr, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''))
    if ($timedOut -or $sw.Elapsed.TotalSeconds -gt ($TimeoutSec + 1)) {
        return @{ Ok = $false; Code = 'Timeout'; StdOut = ''; Message = ('no result within {0}s' -f $TimeoutSec) }
    }
    if ($null -eq $exitCode -or [int]$exitCode -ne 0) {
        $msg = $stderr.Trim()
        if ($msg -eq '') { $msg = $stdout.Trim() }
        return @{ Ok = $false; Code = 'CommandFailed'; StdOut = $stdout; Message = ('exit {0}: {1}' -f $exitCode, $msg) }
    }
    return @{ Ok = $true; Code = ''; StdOut = $stdout; Message = '' }
}

# Runs one read-only shell command on the box. On failure records an error
# for $Field and returns $null; on success returns the scrubbed stdout with
# CRLF normalized to LF.
function Invoke-BoxShell {
    param([string]$Command, [string]$Field, [switch]$AllowEmpty)
    $allowed = $false
    foreach ($pattern in $ReadOnlyCommandPatterns) { if ($Command -cmatch $pattern) { $allowed = $true; break } }
    if (-not $allowed) { throw "refusing a command outside the read-only whitelist: $Command" }
    $r = Invoke-Adb @('-s', $Device, 'shell', $Command)
    if (-not $r.Ok) {
        Add-ProbeError $Field $r.Code $Command $r.Message
        return $null
    }
    $text = ($r.StdOut -replace "`r", '')
    if (-not $AllowEmpty -and $text.Trim() -eq '') {
        Add-ProbeError $Field 'EmptyOutput' $Command 'command printed nothing'
        return $null
    }
    return $text
}

# Nullable text parameters below stay untyped: PowerShell turns $null into
# '' for a [string] parameter, which would hide a failed call.

# Emits the trimmed non-empty lines of $Text (nothing for $null).
function Get-Lines {
    param($Text)
    if ($null -eq $Text) { return }
    foreach ($line in ([string]$Text -split "`n")) {
        $t = $line.Trim()
        if ($t -ne '') { $t }
    }
}

function ConvertTo-IntOrNull {
    param($Text)
    $n = 0
    if ($null -ne $Text -and [int]::TryParse(([string]$Text).Trim(), [System.Globalization.NumberStyles]::Integer, $Invariant, [ref]$n)) { return $n }
    return $null
}

function New-Flag {
    param($Value, [string]$Rule, [string]$Source, $Raw)
    return [ordered]@{ value = $Value; rule = $Rule; source = $Source; raw = $Raw }
}


# Returns capture group 1 of $Pattern in $Text, or $null with a ParseError
# for $Field. $Text $null means the call already failed and was recorded.
function Get-Match {
    param($Text, [string]$Pattern, [string]$Field, [string]$Command)
    if ($null -eq $Text) { return $null }
    $m = [regex]::Match([string]$Text, $Pattern)
    if (-not $m.Success) {
        Add-ProbeError $Field 'ParseError' $Command ('no line matches /{0}/' -f $Pattern)
        return $null
    }
    return $m.Groups[1].Value.Trim()
}

function Get-TrimmedOrNull {
    param($Text)
    if ($null -eq $Text) { return $null }
    return ([string]$Text).Trim()
}

function Get-DeviceSection {
    $s = [ordered]@{}
    foreach ($name in @($PropKeys.Keys)) {
        $s[$name] = Get-TrimmedOrNull (Invoke-BoxShell ('getprop ' + $PropKeys[$name]) ('device.' + $name))
    }
    if ($null -ne $s.sdk) {
        $sdk = ConvertTo-IntOrNull $s.sdk
        if ($null -eq $sdk) { Add-ProbeError 'device.sdk' 'ParseError' ('getprop ' + $PropKeys.sdk) ("not an integer: '{0}'" -f $s.sdk) }
        $s.sdk = $sdk
    }
    if ($null -ne $s.cpuAbiList) { $s.cpuAbiList = @($s.cpuAbiList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
    $cmd = 'cat /proc/meminfo'
    $mem = Invoke-BoxShell $cmd 'device.meminfo'
    $s.memTotalKb = ConvertTo-IntOrNull (Get-Match $mem '(?m)^MemTotal:\s+(\d+)\s*kB' 'device.memTotalKb' $cmd)
    $s.memAvailableKb = ConvertTo-IntOrNull (Get-Match $mem '(?m)^MemAvailable:\s+(\d+)\s*kB' 'device.memAvailableKb' $cmd)
    return $s
}

# 4K60 color format from the EDID. Amlogic numbers 4:2:0-only modes from the
# EDID's Y420 data block as VIC + 256, so 2160p60 is VIC 97 in RGB/4:4:4 and
# 353 in 4:2:0 (cur_VIC 353 = 2160p60 4:2:0). RGB/4:4:4 at 4K60 also needs a
# 594 MHz TMDS link, i.e. MaxTMDSClock >= 594 and SCDC scrambling.
function Get-FourK60ColorFormat {
    param($DispCap4k60, $Vics, $MaxTmds, $Scdc)
    if ($null -eq $DispCap4k60) { return $null }
    if (@($DispCap4k60).Count -eq 0) { return 'not-offered' }
    $plain = @($DispCap4k60 | Where-Object { ($_ -replace '\*$', '') -eq '2160p60hz' })
    if ($plain.Count -eq 0) { return 'yuv420-only' }
    if ($null -ne $Vics -and @($Vics) -notcontains 97 -and @($Vics) -contains 353) { return 'yuv420-only' }
    if ($null -ne $MaxTmds -and $MaxTmds -lt 594) { return 'yuv420-only' }
    if ($null -ne $Scdc -and $Scdc -eq 0) { return 'yuv420-only' }
    if ($null -ne $MaxTmds -and $null -ne $Scdc) { return 'rgb444-capable' }
    return $null
}

function Get-HdmiSection {
    $configCmd = "cat $HdmiDir/config"
    $ConfigText = Invoke-BoxShell $configCmd 'hdmi.config'
    $s = [ordered]@{}
    $s.currentMode = Get-TrimmedOrNull (Invoke-BoxShell 'cat /sys/class/display/mode' 'hdmi.currentMode')
    $s.attr = Get-TrimmedOrNull (Invoke-BoxShell "cat $HdmiDir/attr" 'hdmi.attr')
    $s.curVic = ConvertTo-IntOrNull (Get-Match $ConfigText '(?m)^cur_VIC:\s*(\d+)' 'hdmi.curVic' $configCmd)
    $s.colorspace = Get-Match $ConfigText '(?m)^colorspace:\s*(\S+)' 'hdmi.colorspace' $configCmd
    $s.colordepth = Get-Match $ConfigText '(?m)^colordepth:\s*(\S+)' 'hdmi.colordepth' $configCmd
    $s.fracRatePolicy = ConvertTo-IntOrNull (Get-TrimmedOrNull (Invoke-BoxShell "cat $HdmiDir/frac_rate_policy" 'hdmi.fracRatePolicy'))

    $sfCmd = 'dumpsys SurfaceFlinger'
    $rate = Get-Match (Invoke-BoxShell $sfCmd 'hdmi.surfaceFlingerRefreshHz') 'refresh-rate\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*fps' 'hdmi.surfaceFlingerRefreshHz' $sfCmd
    $s.surfaceFlingerRefreshHz = $(if ($null -eq $rate) { $null } else { [double]::Parse($rate, $Invariant) })

    $disp = Invoke-BoxShell "cat $HdmiDir/disp_cap" 'hdmi.dispCap'
    $s.dispCap = $(if ($null -eq $disp) { $null } else { , @(Get-Lines $disp) })
    $dc = Invoke-BoxShell "cat $HdmiDir/dc_cap" 'hdmi.dcCap'
    $s.dcCap = $(if ($null -eq $dc) { $null } else { , @(Get-Lines $dc) })

    # Only the link-capability lines and the VIC list of the EDID text are
    # parsed; the rest of it names the TV and carries its serial number.
    $edidCmd = "cat $HdmiDir/edid"
    $edid = Invoke-BoxShell $edidCmd 'hdmi.edid'
    $s.edidLink = $null
    $s.edidVics = $null
    $s.maxTmdsClockMHz = $null
    $s.scdc = $null
    if ($null -ne $edid) {
        $lines = @(Get-Lines $edid)
        $s.edidLink = @($lines | Where-Object { $_ -match '^(MaxTMDSClock\d*|SCDC|LTE_340M_Scramble)\b' })
        $vicLine = @($lines | Where-Object { $_ -match '^\d+( +\d+){2,}$' }) | Select-Object -First 1
        if ($null -eq $vicLine) { Add-ProbeError 'hdmi.edidVics' 'ParseError' $edidCmd 'no VIC list line' }
        else { $s.edidVics = @($vicLine -split ' +' | ForEach-Object { [int]$_ }) }
        $clocks = @([regex]::Matches($edid, 'MaxTMDSClock\d*\s*:?\s*(\d+)\s*MHz') | ForEach-Object { [int]$_.Groups[1].Value })
        if ($clocks.Count -gt 0) { $s.maxTmdsClockMHz = ($clocks | Measure-Object -Maximum).Maximum }
        else { Add-ProbeError 'hdmi.maxTmdsClockMHz' 'ParseError' $edidCmd 'no MaxTMDSClock line' }
        $s.scdc = ConvertTo-IntOrNull (Get-Match $edid '(?m)^\s*SCDC\s*:\s*(\d+)' 'hdmi.scdc' $edidCmd)
    }

    # Amlogic marks the preferred mode with '*'; some kernels list
    # 4:2:0-only modes with a '420' suffix.
    $cap4k = $null
    $cap4k60 = $null
    if ($null -ne $s.dispCap) {
        $cap4k = @($s.dispCap | Where-Object { $_ -match '^2160p' })
        $cap4k60 = @($cap4k | Where-Object { ($_ -replace '\*$', '') -match '^2160p60hz(420)?$' })
    }
    $s.supports4k60 = New-Flag $(if ($null -eq $cap4k60) { $null } else { $cap4k60.Count -gt 0 }) `
        'disp_cap (the EDID mode list) offers 2160p60hz or 2160p60hz420' "$HdmiDir/disp_cap" $cap4k
    $dc420 = $null
    if ($null -ne $s.dcCap) { $dc420 = @($s.dcCap | Where-Object { $_ -match '^420,' }) }
    $s.fourK60ColorFormat = New-Flag (Get-FourK60ColorFormat $cap4k60 $s.edidVics $s.maxTmdsClockMHz $s.scdc) `
        'not-offered: no 2160p60 in disp_cap; yuv420-only: EDID has VIC 353 (2160p60 Y420) but not VIC 97, or MaxTMDSClock < 594 MHz, or SCDC 0; rgb444-capable: VIC 97, MaxTMDSClock >= 594 and SCDC 1' `
        "$HdmiDir/disp_cap, $HdmiDir/edid, $HdmiDir/dc_cap" `
        ([ordered]@{ dispCap4k60 = $cap4k60; edidVics = $s.edidVics; edidLink = $s.edidLink; dcCap420 = $dc420 })
    return $s
}

# hdr_cap lists the EDID's HDR static metadata EOTFs. Moonlight's HDR
# toggle needs an HDR10 (SMPTE ST 2084) display; HLG alone is reported but
# does not make the flag true. The kernel spells HLG "Hybrif Log-Gamma".
function Get-HdrSection {
    $cmd = "cat $HdmiDir/hdr_cap"
    $text = Invoke-BoxShell $cmd 'hdr.hdrCap'
    $s = [ordered]@{ eotf = $null; hdr10PlusSupported = $null }
    $eotfLines = $null
    if ($null -ne $text) {
        $eotfLines = @(Get-Lines $text | Where-Object { $_ -match '^(Traditional SDR|Traditional HDR|SMPTE ST 2084|Hybri[df] Log-Gamma)\s*:' })
        $names = [ordered]@{ traditionalSdr = 'Traditional SDR'; traditionalHdr = 'Traditional HDR'; smpteSt2084 = 'SMPTE ST 2084'; hlg = 'Hybri[df] Log-Gamma' }
        $eotf = [ordered]@{}
        foreach ($key in @($names.Keys)) {
            $eotf[$key] = ConvertTo-IntOrNull (Get-Match $text ('(?m)^\s*' + $names[$key] + '\s*:\s*(\d+)') ('hdr.eotf.' + $key) $cmd)
        }
        $s.eotf = $eotf
        $s.hdr10PlusSupported = ConvertTo-IntOrNull (Get-Match $text '(?m)^\s*HDR10Plus Supported\s*:\s*(\d+)' 'hdr.hdr10PlusSupported' $cmd)
    }
    $value = $null
    if ($null -ne $s.eotf -and $null -ne $s.eotf.smpteSt2084) { $value = ($s.eotf.smpteSt2084 -eq 1) }
    $s.supportsHdr = New-Flag $value 'hdr_cap "SMPTE ST 2084: 1" (HDR10 EOTF in the EDID)' "$HdmiDir/hdr_cap" $eotfLines
    return $s
}

# Decoders come from /vendor/etc/media_codecs*.xml; dumpsys media.player is
# the fallback. Software decoders (OMX.google.*, c2.android.*, *.sw) are
# listed but do not count as hardware decoders.
function Get-DecoderSection {
    $xmlCmd = 'cat /vendor/etc/media_codecs*.xml'
    $source = '/vendor/etc/media_codecs*.xml'
    $text = Invoke-BoxShell $xmlCmd 'decoders.mediaCodecsXml'
    $list = $null
    if ($null -ne $text) {
        $clean = [regex]::Replace($text, '(?s)<!--.*?-->', '')
        $list = New-Object System.Collections.Generic.List[object]
        $seen = @{}
        foreach ($block in [regex]::Matches($clean, '(?s)<Decoders>(.*?)</Decoders>')) {
            foreach ($m in [regex]::Matches($block.Groups[1].Value, '<MediaCodec\b([^>]*)>')) {
                $attrs = $m.Groups[1].Value
                $name = [regex]::Match($attrs, '\bname="([^"]+)"').Groups[1].Value
                $type = [regex]::Match($attrs, '\btype="([^"]+)"').Groups[1].Value
                if ($name -eq '' -or $attrs -match '\bupdate="true"') { continue }
                $key = "$name|$type"
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $list.Add([ordered]@{ name = $name; type = $type })
            }
        }
        if ($list.Count -eq 0) { Add-ProbeError 'decoders.list' 'ParseError' $xmlCmd 'no <MediaCodec> entries inside <Decoders>'; $list = $null }
    }
    if ($null -eq $list) {
        $mpCmd = 'dumpsys media.player'
        $mp = Invoke-BoxShell $mpCmd 'decoders.mediaPlayer'
        if ($null -ne $mp) {
            $names = @([regex]::Matches($mp, '\b((?:OMX|c2)\.[A-Za-z0-9_.-]*decoder[A-Za-z0-9_.-]*)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            if ($names.Count -gt 0) {
                $list = New-Object System.Collections.Generic.List[object]
                foreach ($n in $names) { $list.Add([ordered]@{ name = $n; type = $null }) }
                $source = $mpCmd
            } else {
                Add-ProbeError 'decoders.list' 'ParseError' $mpCmd 'no decoder names in output'
            }
        }
    }
    $s = [ordered]@{ source = $null; list = $null; hardwareVideo = $null }
    $av1 = $null
    $av1Raw = $null
    if ($null -ne $list) {
        foreach ($d in $list) { $d.hardware = ($d.name -notmatch '^(OMX\.google\.|c2\.android\.)' -and $d.name -notmatch '\.sw$') }
        $s.source = $source
        $s.list = $list.ToArray()
        $s.hardwareVideo = @($list | Where-Object { $_.hardware -and ($null -eq $_.type -or [string]$_.type -like 'video/*') } | ForEach-Object { $_.name })
        $av1All = @($list | Where-Object { [string]$_.type -eq 'video/av01' -or $_.name -match '(?i)\bav1|av01' })
        $av1Raw = @($av1All | ForEach-Object { '{0} ({1}, {2})' -f $_.name, $_.type, $(if ($_.hardware) { 'hardware' } else { 'software' }) })
        $av1 = (@($av1All | Where-Object { $_.hardware }).Count -gt 0)
    }
    $s.hasAv1Decoder = New-Flag $av1 'a hardware decoder (not OMX.google.*, c2.android.* or *.sw) of type video/av01' $source $av1Raw
    return $s
}

# aud_cap is the EDID's short audio descriptor list, one format per line:
# "PCM, 2 ch, ...", " AC-3, 6 ch, ...", "Dobly_Digital+, 8 ch, ..." (sic).
function Get-AudioSection {
    $cmd = "cat $HdmiDir/aud_cap"
    $text = Invoke-BoxShell $cmd 'audio.audCap'
    $s = [ordered]@{ formats = $null }
    $pcmLines = $null
    $max = $null
    if ($null -ne $text) {
        $formats = New-Object System.Collections.Generic.List[object]
        foreach ($line in @(Get-Lines $text)) {
            $m = [regex]::Match($line, '^([^,]+),\s*(\d+)\s*ch\b')
            if ($m.Success) { $formats.Add([ordered]@{ codingType = $m.Groups[1].Value.Trim(); maxChannels = [int]$m.Groups[2].Value; line = $line }) }
        }
        if ($formats.Count -eq 0) {
            Add-ProbeError 'audio.formats' 'ParseError' $cmd 'no "<format>, <n> ch" lines'
        } else {
            $s.formats = $formats.ToArray()
            $pcm = @($formats | Where-Object { $_.codingType -match '^(L-)?PCM$' })
            $pcmLines = @($pcm | ForEach-Object { $_.line })
            if ($pcm.Count -eq 0) {
                Add-ProbeError 'audio.maxPcmChannels' 'ParseError' $cmd 'no PCM line'
            } else {
                $max = ($pcm | ForEach-Object { $_.maxChannels } | Measure-Object -Maximum).Maximum
            }
        }
    }
    $s.maxPcmChannels = New-Flag $max 'largest channel count on a PCM line of aud_cap (Moonlight outputs PCM, not AC-3/DD+ passthrough)' "$HdmiDir/aud_cap" $pcmLines
    return $s
}

function Get-NetworkSection {
    $s = [ordered]@{ interface = 'eth0' }
    $s.operstate = Get-TrimmedOrNull (Invoke-BoxShell "cat $NetDir/operstate" 'network.operstate')
    $s.speedMbps = ConvertTo-IntOrNull (Get-TrimmedOrNull (Invoke-BoxShell "cat $NetDir/speed" 'network.speedMbps'))
    $s.duplex = Get-TrimmedOrNull (Invoke-BoxShell "cat $NetDir/duplex" 'network.duplex')
    $cmd = 'ip -4 addr show eth0'
    $s.ipv4 = Get-Match (Invoke-BoxShell $cmd 'network.ipv4') '(?m)^\s*inet\s+(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\b' 'network.ipv4' $cmd
    return $s
}

function Get-MoonlightSection {
    $cmd = 'dumpsys package com.limelight'
    $text = Invoke-BoxShell $cmd 'moonlight'
    $s = [ordered]@{ package = 'com.limelight'; installed = $null; versionName = $null; versionCode = $null }
    if ($null -ne $text) {
        if ($text -match 'Package \[com\.limelight\]') {
            $s.installed = $true
            $s.versionName = Get-Match $text '(?m)^\s*versionName=(\S+)' 'moonlight.versionName' $cmd
            $s.versionCode = ConvertTo-IntOrNull (Get-Match $text '(?m)^\s*versionCode=(\d+)' 'moonlight.versionCode' $cmd)
        } elseif ($text -match 'Unable to find package: com\.limelight') {
            $s.installed = $false
        } else {
            Add-ProbeError 'moonlight.installed' 'ParseError' $cmd 'neither a Package [com.limelight] block nor "Unable to find package"'
        }
    }
    return $s
}

# Runs one section collector; an unexpected exception (a probe bug) leaves
# the section null with a ProbeError instead of aborting the whole probe.
function Invoke-Section {
    param([string]$Name, [scriptblock]$Collector)
    try {
        return (& $Collector)
    } catch {
        Add-ProbeError $Name 'ProbeError' '' $_.Exception.Message
        return $null
    }
}

function Get-FlagValue {
    param($Section, [string]$Flag)
    if ($null -eq $Section -or -not $Section.Contains($Flag)) { return $null }
    return $Section[$Flag].value
}

# ---- Main ----
$result = [ordered]@{
    schemaVersion  = 1
    adbTarget      = $(if ($Device -eq '') { $null } else { $Device })
    reachable      = $false
    collectedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)
    flags          = $null
    device         = $null
    hdmi           = $null
    hdr            = $null
    decoders       = $null
    audio          = $null
    network        = $null
    moonlight      = $null
    errors         = $null
}

$unreachable = $false
if ($Device -eq '') {
    Add-ProbeError 'connection' 'NoDevice' '' 'no adb target: pass -Device or set GS_TVBOX_DEVICE'
    $unreachable = $true
} else {
    # Default runner: the adb executable must exist on disk before anything
    # is started. An injected runner is never checked against disk, so
    # unit tests run no matter what is installed on this machine.
    if ($null -eq $AdbRunner -and ([string]::IsNullOrEmpty($AdbPath) -or -not (Test-Path -LiteralPath $AdbPath -PathType Leaf))) {
        $detail = $(if ($AdbPath -ne '') { $AdbPath } else { 'no -AdbPath given and no adb.exe on PATH' })
        Add-ProbeError 'connection' 'AdbNotFound' '' ('adb not found: ' + $detail)
        $unreachable = $true
    } else {
        # 'device' is the only state in which shell commands run. The probe
        # never runs adb connect or touches authorization; offline,
        # unauthorized or unknown targets are reported as unreachable.
        $state = Invoke-Adb @('-s', $Device, 'get-state')
        if (-not $state.Ok) {
            $code = $(if ($state.Code -eq 'Timeout') { 'Timeout' } else { 'Unreachable' })
            Add-ProbeError 'connection' $code 'adb get-state' $state.Message
            $unreachable = $true
        } elseif ($state.StdOut.Trim() -ne 'device') {
            Add-ProbeError 'connection' 'Unreachable' 'adb get-state' ("state '{0}'" -f $state.StdOut.Trim())
            $unreachable = $true
        }
    }
}

if (-not $unreachable) {
    $result.reachable = $true
    $result.device = Invoke-Section 'device' { Get-DeviceSection }
    $result.hdmi = Invoke-Section 'hdmi' { Get-HdmiSection }
    $result.hdr = Invoke-Section 'hdr' { Get-HdrSection }
    $result.decoders = Invoke-Section 'decoders' { Get-DecoderSection }
    $result.audio = Invoke-Section 'audio' { Get-AudioSection }
    $result.network = Invoke-Section 'network' { Get-NetworkSection }
    $result.moonlight = Invoke-Section 'moonlight' { Get-MoonlightSection }
    $result.flags = [ordered]@{
        supports4k60       = Get-FlagValue $result.hdmi 'supports4k60'
        fourK60ColorFormat = Get-FlagValue $result.hdmi 'fourK60ColorFormat'
        supportsHdr        = Get-FlagValue $result.hdr 'supportsHdr'
        hasAv1Decoder      = Get-FlagValue $result.decoders 'hasAv1Decoder'
        maxPcmChannels     = Get-FlagValue $result.audio 'maxPcmChannels'
    }
}
$result.errors = $script:Errors.ToArray()

# Every string was scrubbed when it came off the box; scrub the document
# once more so nothing identifier-shaped can reach the evidence.
$json = Remove-Identifiers ($result | ConvertTo-Json -Depth 12)

if ($OutFile -ne '') {
    $outFull = [System.IO.Path]::GetFullPath($OutFile)
    $outDir = Split-Path -Parent $outFull
    if (-not (Test-Path -LiteralPath $outDir -PathType Container)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($outFull, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}
Write-Output $json

if ($unreachable) { exit 2 }
if ($script:Errors.Count -gt 0) { exit 1 }
exit 0
