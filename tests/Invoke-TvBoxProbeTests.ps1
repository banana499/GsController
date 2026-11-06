#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for client/Get-TvBoxCapabilities.ps1, the Android TV box probe.

.DESCRIPTION
    Every test drives the probe through its -AdbRunner seam with canned adb
    output modeled on the A4091 box (Amlogic, Android 9) on a 4K60 4:2:0
    HDMI port, except the adb-resolution tests: those run the probe with
    its default runner against fake adb.exe files compiled with the .NET
    Framework csc.exe into %TEMP% (marker stand-ins that never touch a
    device), and one timeout test compiles a hanging fake adb.exe; those
    tests are skipped when csc.exe is absent. No real device is contacted
    and a real adb on PATH is never executed: tests with an injected
    runner bypass adb resolution entirely, so they run unchanged on a
    machine where PATH does contain a real adb. Addresses use the
    documentation range 192.0.2.0/24; identifiers in the fixtures (EDID
    serial, MAC addresses, hex IDs) are made up. GS_TVBOX_DEVICE and PATH
    are saved and restored around the tests that set them. Exits 0 only
    when every test passes and at least one ran; SKIP lines count neither
    as passed nor failed.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$probePath = Join-Path $repoRoot 'client\Get-TvBoxCapabilities.ps1'
$Hdmi = '/sys/class/amhdmitx/amhdmitx0'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

function Invoke-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
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

function Assert-Null {
    param($Actual, [string]$Message)
    if ($null -ne $Actual) { throw "Assertion failed: $Message (expected null, actual '$Actual')" }
}

# ---- Fixtures: canned adb output of the A4091 on TV HDMI 3 ----
# The EDID serial, product name and MAC addresses below are invented. They
# are planted so the identifier tests can check they never reach the JSON.
$FakeEdidSerial = '0x5E1A0C3F'
$FakeMac = '02:1a:2b:3c:4d:5e'
$FakeAndroidId = '9f8e7d6c5b4a3921'

$EdidHdmi3 = @'
Rx Manufacturer Name: TST
Rx Product Code: 1010
Rx Serial Number: 0x5E1A0C3F
Rx Product Name: FAKE-TV-NAME
Manufacture Week: 1
Manufacture Year: 2015
Physcial size(cm): 160 x 90
EDID Version: 1.3
EDID block number: 0x1
blk0 chksum: 0x6b
Source Physical Address[a.b.c.d]: 3.0.0.0
native Mode 70, VIC (native 31):
ColorDeepSupport b8
31 16 32 20 5 19 4 18 3 17 2 22 7 21 6 1 95 94 93 353 352 358 357
Audio {format, channel, freq, cce}
{1, 1, 7, 7}
Speaker Allocation: 1
Vendor: 0xc03 ( HDMI device)
MaxTMDSClock1 300 MHz
vLatency:  Invalid/Unknown
SCDC: 0
RR_Cap: 0
LTE_340M_Scramble: 0
  DeepColor
checkvalue: 0x6b000000
'@

$DispCapHdmi3 = @'
480i60hz
576i50hz
480p60hz
576p50hz
720p60hz
1080i60hz
1080p60hz
720p50hz
1080i50hz
1080p50hz*
1080p24hz
2160p30hz
2160p25hz
2160p24hz
smpte50hz
smpte60hz
2160p50hz
2160p60hz
'@

$HdrCapNone = @'
HDR10Plus Supported: 0
HDR Static Metadata:
    Supported EOTF:
        Traditional SDR: 0
        Traditional HDR: 0
        SMPTE ST 2084: 0
        Hybrif Log-Gamma: 0
    Supported SMD type1: 0
    Luminance Data
        Max: 0
        Avg: 0
        Min: 0

HDR Dynamic Metadata:

colorimetry_data: 0
'@

# Three files concatenated, as `cat /vendor/etc/media_codecs*.xml` prints
# them. The comment carries the AOSP example codec and an AV1 decoder that
# must not be counted; the performance file only updates existing codecs.
$MediaCodecsNoAv1 = @'
<?xml version="1.0" encoding="utf-8" ?>
<!-- A codec is declared like so:
    <MediaCodec name="OMX.foo.bar" type="something/interesting" />
    <MediaCodec name="OMX.vendor.av1.decoder" type="video/av01" />
-->
<MediaCodecs>
    <Decoders>
        <MediaCodec name="OMX.amlogic.hevc.decoder.awesome" type="video/hevc" >
        </MediaCodec>
        <MediaCodec name="OMX.amlogic.avc.decoder.awesome" type="video/avc" >
        </MediaCodec>
        <MediaCodec name="OMX.amlogic.vp9.decoder.awesome" type="video/x-vnd.on2.vp9" >
        </MediaCodec>
        <MediaCodec name="OMX.google.aac.decoder" type="audio/mp4a-latm" />
        <MediaCodec name="OMX.google.h264.decoder" type="video/avc">
        </MediaCodec>
        <MediaCodec name="OMX.google.hevc.decoder" type="video/hevc">
        </MediaCodec>
    </Decoders>
    <Encoders>
        <MediaCodec name="OMX.amlogic.video.encoder.avc" type="video/avc" />
    </Encoders>
</MediaCodecs>
<?xml version="1.0" encoding="utf-8" ?>
<MediaCodecs>
    <Decoders>
        <MediaCodec name="OMX.amlogic.vp8.decoder.sw" type="video/x-vnd.on2.vp8" />
    </Decoders>
</MediaCodecs>
<?xml version="1.0" encoding="utf-8" ?>
<MediaCodecs>
    <Decoders>
        <MediaCodec name="OMX.amlogic.avc.decoder.awesome" type="video/avc" update="true">
        </MediaCodec>
    </Decoders>
</MediaCodecs>
'@

# aud_cap really contains NUL bytes before some fields.
$AudCapStereo = "CodingType MaxChannels SamplingFreq SampleSize`nPCM, 2 ch, 32/44.1/48 kHz, `016/20/24 bit`n`0AC-3, 6 ch, 44.1/48 kHz, `0MaxBitRate 640kHz`nDobly_Digital+, 8 ch, 44.1/48 kHz, `0DepVaule 0x0`n"

$MoonlightPackage = @'
Activity Resolver Table:
  Non-Data Actions:
      android.intent.action.MAIN:
        7d1c0a2 com.limelight/.PcView filter 5f3e9b1
Packages:
  Package [com.limelight] (c3a1f0e):
    userId=10057
    pkg=Package{d4e5f6a com.limelight}
    versionCode=315 minSdk=21 targetSdk=36
    versionName=12.2
'@

# Returns a fresh map of shell command -> response for a healthy box.
# A response is a string (stdout, exit 0), a hashtable (a full runner
# result) or a scriptblock (called with the arguments and timeout).
function New-HealthyResponses {
    $r = @{}
    $r['get-state'] = "device`n"
    $r['getprop ro.product.model'] = "A4091`n"
    $r['getprop ro.product.brand'] = "skyworthbox`n"
    $r['getprop ro.board.platform'] = "testboard`n"
    $r['getprop ro.build.version.release'] = "9`n"
    $r['getprop ro.build.version.sdk'] = "28`n"
    $r['getprop ro.product.cpu.abilist'] = "armeabi-v7a,armeabi`n"
    $r['cat /proc/meminfo'] = "MemTotal:        3924524 kB`r`nMemFree:          928556 kB`r`nMemAvailable:    2331996 kB`r`n"
    $r['cat /sys/class/display/mode'] = "2160p60hz`n"
    $r["cat $Hdmi/attr"] = '420,8bit'
    $r["cat $Hdmi/config"] = "cur_VIC: 353`ncur_video_param->VIC=353`ncolordepth: 8bit`ncolorspace: 420`naudio channel num: 2 channels`n"
    $r["cat $Hdmi/frac_rate_policy"] = "0`n"
    $r['dumpsys SurfaceFlinger'] = "Display 0 color modes:`n  orientation=0, isDisplayOn=1`n  refresh-rate              : 60.000002 fps`n  x-dpi                     : 63.000000`n"
    $r["cat $Hdmi/disp_cap"] = $DispCapHdmi3
    $r["cat $Hdmi/dc_cap"] = "420,8bit`n444,12bit`n444,10bit`n444,8bit`n422,12bit`n422,10bit`n422,8bit`nrgb,12bit`nrgb,10bit`nrgb,8bit`n"
    $r["cat $Hdmi/edid"] = $EdidHdmi3
    $r["cat $Hdmi/hdr_cap"] = $HdrCapNone
    $r['cat /vendor/etc/media_codecs*.xml'] = $MediaCodecsNoAv1
    $r["cat $Hdmi/aud_cap"] = $AudCapStereo
    $r['cat /sys/class/net/eth0/operstate'] = "up`n"
    $r['cat /sys/class/net/eth0/speed'] = "1000`n"
    $r['cat /sys/class/net/eth0/duplex'] = "full`n"
    $r['ip -4 addr show eth0'] = "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000`n    link/ether $FakeMac brd ff:ff:ff:ff:ff:ff`n    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0`n       valid_lft forever preferred_lft forever`n"
    $r['dumpsys package com.limelight'] = $MoonlightPackage
    return $r
}

# A runner for the probe's -AdbRunner seam that answers from $Responses and
# records every command it was asked for in $Calls. Unknown commands fail
# with exit 255 so a probe that sends something new is noticed.
function New-FakeRunner {
    param([hashtable]$Responses, $Calls)
    return {
        param($AdbPath, $Arguments, $TimeoutSec)
        $argList = @($Arguments)
        $key = $(if ($argList.Count -ge 4 -and $argList[2] -eq 'shell') { $argList[3] } else { $argList[2] })
        $Calls.Add([string]$key)
        if (-not $Responses.ContainsKey($key)) {
            return @{ ExitCode = 255; StdOut = ''; StdErr = "fake adb: unexpected command '$key'"; TimedOut = $false }
        }
        $resp = $Responses[$key]
        if ($resp -is [scriptblock]) { return (& $resp $argList $TimeoutSec) }
        if ($resp -is [hashtable]) { return $resp }
        return @{ ExitCode = 0; StdOut = [string]$resp; StdErr = ''; TimedOut = $false }
    }.GetNewClosure()
}

# Runs the probe in this process with a fake runner. Returns the exit code,
# the JSON text, the parsed object and the commands the probe sent.
function Invoke-Probe {
    param([hashtable]$Responses, [int]$TimeoutSec = 15, [string]$OutFile = '')
    $calls = New-Object System.Collections.Generic.List[string]
    $params = @{ AdbRunner = (New-FakeRunner $Responses $calls); TimeoutSec = $TimeoutSec; Device = '192.0.2.10:5555' }
    if ($OutFile -ne '') { $params.OutFile = $OutFile }
    $global:LASTEXITCODE = 0
    $out = @(& $probePath @params)
    $code = $LASTEXITCODE
    $json = ($out -join "`n")
    return @{ ExitCode = $code; Json = $json; Obj = ($json | ConvertFrom-Json); Calls = $calls.ToArray() }
}

function Get-ProbeErrors {
    param($Result, [string]$Field)
    return , @(@($Result.Obj.errors) | Where-Object { $null -ne $_ -and $_.field -eq $Field })
}

$ExpectedCommands = @(
    'get-state',
    'getprop ro.product.model', 'getprop ro.product.brand', 'getprop ro.board.platform',
    'getprop ro.build.version.release', 'getprop ro.build.version.sdk', 'getprop ro.product.cpu.abilist',
    'cat /proc/meminfo', "cat $Hdmi/config", 'cat /sys/class/display/mode', "cat $Hdmi/attr",
    "cat $Hdmi/frac_rate_policy", 'dumpsys SurfaceFlinger', "cat $Hdmi/disp_cap", "cat $Hdmi/dc_cap",
    "cat $Hdmi/edid", "cat $Hdmi/hdr_cap", 'cat /vendor/etc/media_codecs*.xml', "cat $Hdmi/aud_cap",
    'cat /sys/class/net/eth0/operstate', 'cat /sys/class/net/eth0/speed', 'cat /sys/class/net/eth0/duplex',
    'ip -4 addr show eth0', 'dumpsys package com.limelight'
)

$tempRoot = [System.IO.Path]::GetTempPath()
$originalDeviceEnv = $env:GS_TVBOX_DEVICE
$originalPathEnv = $env:PATH
$workDir = Join-Path $tempRoot ('GsTvBoxProbe_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null

try {
    # ---- Healthy device (A4091-style fixtures, HDMI 3) ----
    $healthy = Invoke-Probe (New-HealthyResponses)

    Invoke-Test 'healthy box: exit 0, schemaVersion 1, no errors' {
        Assert-Equal 0 $healthy.ExitCode 'exit code'
        Assert-Equal 1 $healthy.Obj.schemaVersion 'schemaVersion'
        Assert-True ($healthy.Obj.reachable -eq $true) 'reachable'
        Assert-Equal 0 @($healthy.Obj.errors).Count ('errors: ' + (@($healthy.Obj.errors) | ConvertTo-Json -Compress))
        Assert-True ($healthy.Obj.collectedAtUtc -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') "collectedAtUtc '$($healthy.Obj.collectedAtUtc)'"
    }

    Invoke-Test 'healthy box: device section matches the A4091' {
        $d = $healthy.Obj.device
        Assert-Equal 'A4091' $d.model 'model'
        Assert-Equal 'skyworthbox' $d.brand 'brand'
        Assert-Equal 'testboard' $d.boardPlatform 'board'
        Assert-Equal '9' $d.androidRelease 'release'
        Assert-Equal 28 $d.sdk 'sdk'
        Assert-Equal 'armeabi-v7a,armeabi' (@($d.cpuAbiList) -join ',') 'abilist'
        Assert-Equal 3924524 $d.memTotalKb 'MemTotal'
        Assert-Equal 2331996 $d.memAvailableKb 'MemAvailable'
    }

    Invoke-Test 'healthy box: HDMI output is 2160p60hz 4:2:0 8bit at 60 Hz' {
        $h = $healthy.Obj.hdmi
        Assert-Equal '2160p60hz' $h.currentMode 'mode'
        Assert-Equal '420,8bit' $h.attr 'attr'
        Assert-Equal 353 $h.curVic 'cur_VIC'
        Assert-Equal '420' $h.colorspace 'colorspace'
        Assert-Equal 0 $h.fracRatePolicy 'frac_rate_policy'
        Assert-Equal 60.000002 $h.surfaceFlingerRefreshHz 'SurfaceFlinger refresh'
        Assert-Equal 300 $h.maxTmdsClockMHz 'MaxTMDSClock'
        Assert-Equal 0 $h.scdc 'SCDC'
    }

    Invoke-Test 'healthy box: derived flags match section 1' {
        $f = $healthy.Obj.flags
        Assert-True ($f.supports4k60 -eq $true) 'supports4k60'
        Assert-Equal 'yuv420-only' $f.fourK60ColorFormat 'fourK60ColorFormat'
        Assert-True ($f.supportsHdr -eq $false) 'supportsHdr'
        Assert-True ($f.hasAv1Decoder -eq $false) 'hasAv1Decoder'
        Assert-Equal 2 $f.maxPcmChannels 'maxPcmChannels'
    }

    Invoke-Test 'healthy box: each flag keeps its rule, source and raw lines' {
        $s4k = $healthy.Obj.hdmi.supports4k60
        Assert-Equal "$Hdmi/disp_cap" $s4k.source 'supports4k60 source'
        Assert-True (@($s4k.raw) -contains '2160p60hz') 'supports4k60 raw lists 2160p60hz'
        Assert-True (@($healthy.Obj.hdmi.fourK60ColorFormat.raw.edidLink) -contains 'SCDC: 0') 'color format raw keeps SCDC line'
        $hdr = $healthy.Obj.hdr.supportsHdr
        Assert-Equal "$Hdmi/hdr_cap" $hdr.source 'supportsHdr source'
        Assert-True (@($hdr.raw) -contains 'SMPTE ST 2084: 0') 'supportsHdr raw keeps ST 2084 line'
        Assert-True (@($hdr.raw) -contains 'Hybrif Log-Gamma: 0') 'supportsHdr raw keeps HLG line'
        $pcm = $healthy.Obj.audio.maxPcmChannels
        Assert-Equal "$Hdmi/aud_cap" $pcm.source 'maxPcmChannels source'
        Assert-Equal 'PCM, 2 ch, 32/44.1/48 kHz, 16/20/24 bit' (@($pcm.raw) -join '|') 'PCM raw line without NUL bytes'
        foreach ($flag in @($s4k, $hdr, $pcm, $healthy.Obj.decoders.hasAv1Decoder)) {
            Assert-True (-not [string]::IsNullOrWhiteSpace($flag.rule)) 'flag has a rule'
        }
    }

    Invoke-Test 'healthy box: decoders are the Amlogic H.264/HEVC/VP9 set without AV1' {
        $d = $healthy.Obj.decoders
        Assert-Equal '/vendor/etc/media_codecs*.xml' $d.source 'source'
        $hw = @($d.hardwareVideo)
        Assert-Equal 'OMX.amlogic.hevc.decoder.awesome,OMX.amlogic.avc.decoder.awesome,OMX.amlogic.vp9.decoder.awesome' ($hw -join ',') 'hardware video decoders'
        $names = @($d.list | ForEach-Object { $_.name })
        Assert-True ($names -notcontains 'OMX.foo.bar') 'example codec in the XML comment is ignored'
        Assert-True ($names -notcontains 'OMX.vendor.av1.decoder') 'AV1 codec in the XML comment is ignored'
        Assert-True ($names -notcontains 'OMX.amlogic.video.encoder.avc') 'encoders are not decoders'
        Assert-Equal 1 @($names | Where-Object { $_ -eq 'OMX.amlogic.avc.decoder.awesome' }).Count 'update="true" entry not duplicated'
        Assert-True ($names -contains 'OMX.amlogic.vp8.decoder.sw') 'software decoder listed'
        Assert-Equal 0 @($d.hasAv1Decoder.raw).Count 'AV1 raw is empty'
    }

    Invoke-Test 'healthy box: audio, network and Moonlight sections' {
        $a = @($healthy.Obj.audio.formats)
        Assert-Equal 'PCM:2,AC-3:6,Dobly_Digital+:8' (@($a | ForEach-Object { '{0}:{1}' -f $_.codingType, $_.maxChannels }) -join ',') 'audio formats'
        $n = $healthy.Obj.network
        Assert-Equal 'up' $n.operstate 'operstate'
        Assert-Equal 1000 $n.speedMbps 'speed'
        Assert-Equal 'full' $n.duplex 'duplex'
        Assert-Equal '192.0.2.10/24' $n.ipv4 'ipv4'
        $m = $healthy.Obj.moonlight
        Assert-True ($m.installed -eq $true) 'installed'
        Assert-Equal '12.2' $m.versionName 'versionName'
        Assert-Equal 315 $m.versionCode 'versionCode'
    }

    Invoke-Test 'healthy box: the probe sends only the whitelisted read-only commands' {
        $sent = @($healthy.Calls)
        Assert-Equal (($ExpectedCommands | Sort-Object) -join ' ; ') (($sent | Sort-Object) -join ' ; ') 'command set'
        Assert-True (@($sent | Where-Object { $_ -match 'serialno|android_id|deviceid|settings |input |am |pm |svc |setprop|reboot|connect|pair|echo|>' }).Count -eq 0) 'no identifier or write commands'
    }

    # ---- Identifiers ----
    Invoke-Test 'no serial, Android ID, MAC or EDID identity reaches the JSON' {
        $r = New-HealthyResponses
        # A misbehaving shell prints identifiers into otherwise parsed output.
        $r['getprop ro.product.model'] = "A4091`n"
        $r['dumpsys SurfaceFlinger'] = "android_id=$FakeAndroidId serial=0123456789ABCDEF`n  refresh-rate              : 60.000002 fps`nbt $($FakeMac.ToUpper()) wifi 02-aa-bb-cc-dd-ee`n"
        $res = Invoke-Probe $r
        Assert-Equal 0 $res.ExitCode 'exit code'
        $j = $res.Json
        foreach ($bad in @($FakeMac, $FakeMac.ToUpper(), '02-aa-bb-cc-dd-ee', $FakeAndroidId, '0123456789ABCDEF', $FakeEdidSerial, 'FAKE-TV-NAME', 'Serial Number', 'ro.serialno', '5E1A0C3F')) {
            Assert-True ($j.IndexOf($bad, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "JSON contains '$bad'"
        }
        Assert-True ($j -notmatch '(?i)\b[0-9a-f]{2}([:-])[0-9a-f]{2}(\1[0-9a-f]{2}){4}\b') 'no MAC-looking token'
        Assert-True ($j -notmatch '(?i)\b[0-9a-f]{12,}\b') 'no 12+ hex run'
        Assert-True (@($res.Calls | Where-Object { $_ -match 'getprop' -and $_ -notmatch '^getprop ro\.(product\.(model|brand|cpu\.abilist)|board\.platform|build\.version\.(release|sdk))$' }).Count -eq 0) 'only whitelisted getprop keys'
    }

    Invoke-Test 'identifiers in an error message are redacted too' {
        $r = New-HealthyResponses
        $r["cat $Hdmi/attr"] = @{ ExitCode = 1; StdOut = ''; StdErr = "cat: denied for device $FakeMac id $FakeAndroidId"; TimedOut = $false }
        $res = Invoke-Probe $r
        $e = (Get-ProbeErrors $res 'hdmi.attr')
        Assert-Equal 1 $e.Count 'one hdmi.attr error'
        Assert-True ($e[0].message -match 'REDACTED-MAC') "MAC redacted in '$($e[0].message)'"
        Assert-True ($res.Json -notmatch [regex]::Escape($FakeAndroidId)) 'Android ID redacted'
    }

    # ---- Unreachable ----
    Invoke-Test 'unreachable box: exit 2, every section null, one connection error' {
        $r = @{ 'get-state' = @{ ExitCode = 1; StdOut = ''; StdErr = "error: device '192.0.2.10:5555' not found"; TimedOut = $false } }
        $res = Invoke-Probe $r
        Assert-Equal 2 $res.ExitCode 'exit code'
        Assert-Equal 1 $res.Obj.schemaVersion 'schemaVersion still 1'
        Assert-True ($res.Obj.reachable -eq $false) 'reachable false'
        foreach ($sec in @('flags', 'device', 'hdmi', 'hdr', 'decoders', 'audio', 'network', 'moonlight')) {
            Assert-Null $res.Obj.$sec "section $sec"
        }
        $e = @($res.Obj.errors)
        Assert-Equal 1 $e.Count 'one error'
        Assert-Equal 'connection' $e[0].field 'field'
        Assert-Equal 'Unreachable' $e[0].code 'code'
        Assert-True ($e[0].message -match 'not found') 'adb message kept'
        Assert-Equal 'get-state' ($res.Calls -join ',') 'no shell command after a failed get-state'
    }

    Invoke-Test 'unauthorized box counts as unreachable and is not touched' {
        $r = @{ 'get-state' = "unauthorized`n" }
        $res = Invoke-Probe $r
        Assert-Equal 2 $res.ExitCode 'exit code'
        Assert-True ((@($res.Obj.errors)[0].message) -match "unauthorized") 'state reported'
        Assert-Equal 'get-state' ($res.Calls -join ',') 'nothing else sent'
    }

    Invoke-Test 'missing adb.exe is reported without running anything' {
        $global:LASTEXITCODE = 0
        $out = @(& $probePath -Device '192.0.2.10:5555' -AdbPath (Join-Path $workDir 'no-such-adb.exe'))
        $code = $LASTEXITCODE
        $obj = (($out -join "`n") | ConvertFrom-Json)
        Assert-Equal 2 $code 'exit code'
        Assert-Equal 'AdbNotFound' (@($obj.errors)[0].code) 'code'
        Assert-Null $obj.device 'device null'
    }

    # ---- adb resolution: explicit -AdbPath, PATH ----
    $savedPath = $env:PATH

    Invoke-Test 'an injected -AdbRunner bypasses adb resolution entirely' {
        try {
            # A poisoned PATH must not matter: with an injected runner no
            # PATH lookup happens, and the runner receives '' as AdbPath,
            # so the test never touches a real adb even when PATH holds one.
            $env:PATH = $workDir
            $pathsSeen = New-Object System.Collections.Generic.List[string]
            $calls = New-Object System.Collections.Generic.List[string]
            $inner = New-FakeRunner (New-HealthyResponses) $calls
            $runner = { param($p, $a, $t) $pathsSeen.Add([string]$p); & $inner $p $a $t }.GetNewClosure()
            $global:LASTEXITCODE = 0
            $out = @(& $probePath -Device '192.0.2.10:5555' -AdbRunner $runner)
            $obj = (($out -join "`n") | ConvertFrom-Json)
            Assert-Equal 0 $LASTEXITCODE 'exit code'
            Assert-True ($pathsSeen.Count -gt 0) 'the runner was called'
            Assert-Equal '' ((@($pathsSeen) | Select-Object -Unique) -join ',') 'runner received an empty AdbPath'
        } finally {
            $env:PATH = $savedPath
        }
    }

    Invoke-Test 'no adb anywhere in a clean environment: AdbNotFound, nothing started' {
        try {
            $env:PATH = $workDir  # the fresh %TEMP% work dir holds no adb.exe
            $global:LASTEXITCODE = 0
            $out = @(& $probePath -Device '192.0.2.10:5555')
            $code = $LASTEXITCODE
            $obj = (($out -join "`n") | ConvertFrom-Json)
            Assert-Equal 2 $code 'exit code'
            Assert-Equal 'AdbNotFound' (@($obj.errors)[0].code) 'code'
            Assert-True ((@($obj.errors)[0].message) -match 'PATH') ('message: ' + (@($obj.errors)[0].message))
            Assert-Null $obj.device 'device null'
            Assert-True ($obj.reachable -eq $false) 'not reachable'
        } finally {
            $env:PATH = $savedPath
        }
    }

    Invoke-Test 'a PATH with only invalid entries yields a structured AdbNotFound' {
        try {
            # A dead drive and an entry with invalid path characters must be
            # skipped without aborting the probe, however broken PATH is.
            $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 2) })
            $deadDrive = $null
            foreach ($letter in @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
                if ($used -notcontains ($letter + ':')) { $deadDrive = $letter + ':'; break }
            }
            Assert-True ($null -ne $deadDrive) 'a free drive letter exists for the fixture'
            $badChars = 'C:\bad' + [string][char]60 + [string][char]62 + 'dir'
            $env:PATH = "$deadDrive\dead;$badChars"
            $global:LASTEXITCODE = 0
            $out = @(& $probePath -Device '192.0.2.10:5555')
            $code = $LASTEXITCODE
            $obj = (($out -join "`n") | ConvertFrom-Json)
            Assert-Equal 2 $code 'exit code'
            Assert-Equal 'AdbNotFound' (@($obj.errors)[0].code) 'code'
            Assert-True ($obj.reachable -eq $false) 'not reachable'
            Assert-Null $obj.device 'device null'
        } finally {
            $env:PATH = $savedPath
        }
    }

    # ---- Device selection (no real address in the repository) ----
    $savedDeviceEnv = $env:GS_TVBOX_DEVICE

    Invoke-Test 'no -Device and no GS_TVBOX_DEVICE: NoDevice, exit 2, adb never called' {
        $env:GS_TVBOX_DEVICE = $null
        $calls = New-Object System.Collections.Generic.List[string]
        $global:LASTEXITCODE = 0
        $out = @(& $probePath -AdbRunner (New-FakeRunner (New-HealthyResponses) $calls))
        $code = $LASTEXITCODE
        $obj = (($out -join "`n") | ConvertFrom-Json)
        Assert-Equal 2 $code 'exit code'
        Assert-Equal 'NoDevice' (@($obj.errors)[0].code) 'code'
        Assert-Null $obj.adbTarget 'adbTarget null'
        Assert-Null $obj.device 'device null'
        Assert-Equal 0 $calls.Count 'no adb call'
    }

    Invoke-Test 'GS_TVBOX_DEVICE is used when -Device is omitted' {
        $env:GS_TVBOX_DEVICE = '192.0.2.10:5555'
        $calls = New-Object System.Collections.Generic.List[string]
        $seen = New-Object System.Collections.Generic.List[string]
        $inner = New-FakeRunner (New-HealthyResponses) $calls
        $runner = { param($p, $a, $t) $seen.Add([string]@($a)[1]); & $inner $p $a $t }.GetNewClosure()
        $global:LASTEXITCODE = 0
        $out = @(& $probePath -AdbRunner $runner)
        $obj = (($out -join "`n") | ConvertFrom-Json)
        Assert-Equal 0 $LASTEXITCODE 'exit code'
        Assert-Equal '192.0.2.10:5555' $obj.adbTarget 'adbTarget'
        Assert-Equal 0 @($seen | Where-Object { $_ -ne '192.0.2.10:5555' }).Count 'every call targets the env device'
    }

    Invoke-Test '-Device wins over GS_TVBOX_DEVICE' {
        $env:GS_TVBOX_DEVICE = '192.0.2.99:5555'
        $calls = New-Object System.Collections.Generic.List[string]
        $out = @(& $probePath -Device '192.0.2.10:5555' -AdbRunner (New-FakeRunner (New-HealthyResponses) $calls))
        $obj = (($out -join "`n") | ConvertFrom-Json)
        Assert-Equal '192.0.2.10:5555' $obj.adbTarget 'adbTarget'
    }

    $env:GS_TVBOX_DEVICE = $savedDeviceEnv

    Invoke-Test 'no real box address in the probe or the tests' {
        foreach ($path in @($probePath, $PSCommandPath, (Join-Path $repoRoot 'tests\Invoke-TvBoxIntegrationTests.ps1'))) {
            $text = [System.IO.File]::ReadAllText($path)
            $ips = @([regex]::Matches($text, '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b') | ForEach-Object { $_.Value } | Where-Object { $_ -notmatch '^192\.0\.2\.' -and $_ -notmatch '^255\.' -and $_ -notmatch '^\d\.0\.0\.0$' })
            Assert-Equal 0 $ips.Count ("non-documentation IPs in {0}: {1}" -f (Split-Path -Leaf $path), ($ips -join ', '))
        }
    }

    # ---- Failing call ----
    Invoke-Test 'one failing call: that field null, one error, the rest intact' {
        $r = New-HealthyResponses
        $r["cat $Hdmi/hdr_cap"] = @{ ExitCode = 1; StdOut = ''; StdErr = "cat: $Hdmi/hdr_cap: No such file or directory"; TimedOut = $false }
        $res = Invoke-Probe $r
        Assert-Equal 1 $res.ExitCode 'exit code'
        $e = @($res.Obj.errors)
        Assert-Equal 1 $e.Count ('errors: ' + ($e | ConvertTo-Json -Compress))
        Assert-Equal 'hdr.hdrCap' $e[0].field 'field'
        Assert-Equal 'CommandFailed' $e[0].code 'code'
        Assert-Equal "cat $Hdmi/hdr_cap" $e[0].command 'command'
        Assert-True ($e[0].message -match 'exit 1: .*No such file') "message '$($e[0].message)'"
        Assert-Null $res.Obj.hdr.eotf 'eotf null'
        Assert-Null $res.Obj.hdr.supportsHdr.value 'supportsHdr null, not false'
        Assert-Null $res.Obj.flags.supportsHdr 'flags.supportsHdr null'
        Assert-Equal 'A4091' $res.Obj.device.model 'device still collected'
        Assert-True ($res.Obj.flags.supports4k60 -eq $true) 'other flags still derived'
    }

    Invoke-Test 'empty output is an error, not an empty value' {
        $r = New-HealthyResponses
        $r['getprop ro.product.model'] = "`r`n"
        $res = Invoke-Probe $r
        $e = (Get-ProbeErrors $res 'device.model')
        Assert-Equal 1 $e.Count 'one device.model error'
        Assert-Equal 'EmptyOutput' $e[0].code 'code'
        Assert-Null $res.Obj.device.model 'model null'
    }

    Invoke-Test 'unparsable output is a ParseError with the field null' {
        $r = New-HealthyResponses
        $r['dumpsys SurfaceFlinger'] = "Display 0 color modes:`n  no rate here`n"
        $r['dumpsys package com.limelight'] = "Packages:`n  something unexpected`n"
        $res = Invoke-Probe $r
        Assert-Equal 'ParseError' (Get-ProbeErrors $res 'hdmi.surfaceFlingerRefreshHz')[0].code 'refresh code'
        Assert-Null $res.Obj.hdmi.surfaceFlingerRefreshHz 'refresh null'
        Assert-Equal 'ParseError' (Get-ProbeErrors $res 'moonlight.installed')[0].code 'moonlight code'
        Assert-Null $res.Obj.moonlight.installed 'installed null, not false'
    }

    Invoke-Test 'Moonlight not installed is reported as installed false' {
        $r = New-HealthyResponses
        $r['dumpsys package com.limelight'] = "Unable to find package: com.limelight`n"
        $res = Invoke-Probe $r
        Assert-True ($res.Obj.moonlight.installed -eq $false) 'installed false'
        Assert-Null $res.Obj.moonlight.versionName 'versionName null'
        Assert-Equal 0 @($res.Obj.errors).Count 'no error'
    }

    Invoke-Test 'a runner that throws becomes a RunnerError' {
        $r = New-HealthyResponses
        $r["cat $Hdmi/aud_cap"] = { param($a, $t) throw 'pipe broke' }
        $res = Invoke-Probe $r
        $e = (Get-ProbeErrors $res 'audio.audCap')
        Assert-Equal 'RunnerError' $e[0].code 'code'
        Assert-Null $res.Obj.flags.maxPcmChannels 'maxPcmChannels null'
    }

    # ---- Timeout ----
    Invoke-Test 'a call that sleeps past TimeoutSec is a Timeout even if it then succeeds' {
        $r = New-HealthyResponses
        $r["cat $Hdmi/disp_cap"] = { param($a, $t) Start-Sleep -Seconds ($t + 2); @{ ExitCode = 0; StdOut = "2160p60hz`n"; StdErr = ''; TimedOut = $false } }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-Probe $r -TimeoutSec 1
        $sw.Stop()
        $e = (Get-ProbeErrors $res 'hdmi.dispCap')
        Assert-Equal 1 $e.Count 'one dispCap error'
        Assert-Equal 'Timeout' $e[0].code 'code'
        Assert-Null $res.Obj.hdmi.dispCap 'dispCap null'
        Assert-Null $res.Obj.flags.supports4k60 'supports4k60 null'
        Assert-Null $res.Obj.flags.fourK60ColorFormat 'color format null'
        Assert-True ($sw.Elapsed.TotalSeconds -lt 30) 'probe finished'
    }

    Invoke-Test 'a runner reporting TimedOut is a Timeout' {
        $r = New-HealthyResponses
        $r['get-state'] = @{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $true }
        $res = Invoke-Probe $r
        Assert-Equal 2 $res.ExitCode 'exit code'
        Assert-Equal 'Timeout' (@($res.Obj.errors)[0].code) 'code'
    }

    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (Test-Path -LiteralPath $csc) {
        Invoke-Test 'default runner kills an adb that overruns TimeoutSec' {
            # A stand-in adb.exe: get-state answers at once, every other call hangs.
            $src = Join-Path $workDir 'fakeadb.cs'
            $exe = Join-Path $workDir 'fakeadb.exe'
            [System.IO.File]::WriteAllText($src, 'class P { static int Main(string[] a) { if (a.Length > 2 && a[2] == "get-state") { System.Console.WriteLine("device"); return 0; } System.Threading.Thread.Sleep(120000); return 0; } }')
            $null = & $csc /nologo /out:$exe $src
            Assert-True (Test-Path -LiteralPath $exe) 'fake adb compiled'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $global:LASTEXITCODE = 0
            $out = @(& $probePath -Device '192.0.2.10:5555' -AdbPath $exe -TimeoutSec 1)
            $sw.Stop()
            $obj = (($out -join "`n") | ConvertFrom-Json)
            Assert-Equal 1 $LASTEXITCODE 'exit code'
            Assert-True ($obj.reachable -eq $true) 'get-state ran through the default runner'
            $codes = @(@($obj.errors) | ForEach-Object { $_.code } | Select-Object -Unique)
            Assert-Equal 'Timeout' ($codes -join ',') 'every shell call timed out'
            Assert-Null $obj.device.model 'model null'
            Assert-True ($sw.Elapsed.TotalSeconds -lt 90) "24 calls x 1s finished in $([int]$sw.Elapsed.TotalSeconds)s"
            $left = @(Get-Process -Name 'fakeadb' -ErrorAction SilentlyContinue)
            Assert-Equal 0 $left.Count 'no fake adb left running'
        }
    } else {
        $script:Skipped++
        Write-Host 'SKIP default runner kills an adb that overruns TimeoutSec :: csc.exe (.NET Framework 4) not found'
    }

    if (Test-Path -LiteralPath $csc) {
        # Marker fake adb for the resolution tests: get-state answers
        # 'device', every shell call prints the marker on stdout and fails.
        # Wherever the marker shows up in the probe JSON, THAT fake ran
        # through the default runner. No real adb is ever started: the
        # fakes live in the %TEMP% work dir and are deleted with it.
        function New-MarkerFakeAdb {
            param([string]$Dir, [string]$ExeName, [string]$Marker)
            if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
            $src = Join-Path $Dir 'fakeadb.cs'
            $exe = Join-Path $Dir $ExeName
            $body = 'class P { static int Main(string[] a) { if (a.Length > 2 && a[2] == "get-state") { System.Console.WriteLine("device"); return 0; } System.Console.WriteLine("' + $Marker + '"); return 9; } }'
            [System.IO.File]::WriteAllText($src, $body, [System.Text.Encoding]::ASCII)
            $null = & $csc /nologo "/out:$exe" "$src"
            return $exe
        }

        Invoke-Test 'the explicit -AdbPath runs through the default runner even with a poisoned PATH' {
            try {
                $fake = New-MarkerFakeAdb -Dir (Join-Path $workDir 'explicit') -ExeName 'fake-adb.exe' -Marker 'FROM-EXPLICIT-FAKE'
                Assert-True (Test-Path -LiteralPath $fake -PathType Leaf) 'fake adb compiled'
                $env:PATH = $workDir  # no adb resolvable from PATH
                $global:LASTEXITCODE = 0
                $out = @(& $probePath -Device '192.0.2.10:5555' -AdbPath $fake)
                $json = ($out -join "`n")
                $obj = ($json | ConvertFrom-Json)
                Assert-Equal 1 $LASTEXITCODE 'exit code (get-state ok, shell calls fail)'
                Assert-True ($json.Contains('FROM-EXPLICIT-FAKE')) 'the explicit-path fake ran'
                Assert-Equal 0 @(@($obj.errors) | Where-Object { $_.code -eq 'AdbNotFound' }).Count 'no AdbNotFound'
            } finally {
                $env:PATH = $savedPath
            }
        }

        Invoke-Test 'PATH resolution takes the first adb.exe and ignores a .cmd shim' {
            try {
                $shimDir = Join-Path $workDir 'shimdir'
                New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $shimDir 'adb.cmd'), "@echo off`r`necho FROM-CMD-SHIM`r`nexit /b 3`r`n", [System.Text.Encoding]::ASCII)
                $null = New-MarkerFakeAdb -Dir (Join-Path $workDir 'exedir') -ExeName 'adb.exe' -Marker 'FROM-PATH-EXE-FAKE'
                $env:PATH = "$shimDir;$(Join-Path $workDir 'exedir');C:\Windows\System32"
                $global:LASTEXITCODE = 0
                $out = @(& $probePath -Device '192.0.2.10:5555')
                $json = ($out -join "`n")
                Assert-Equal 1 $LASTEXITCODE 'exit code'
                Assert-True ($json.Contains('FROM-PATH-EXE-FAKE')) 'the adb.exe on PATH ran'
                Assert-True (-not $json.Contains('FROM-CMD-SHIM')) 'the .cmd shim was ignored'
            } finally {
                $env:PATH = $savedPath
            }
        }

        Invoke-Test 'dead drive and invalid PATH entries are skipped; a later adb.exe still resolves' {
            try {
                $fake = New-MarkerFakeAdb -Dir (Join-Path $workDir 'late') -ExeName 'adb.exe' -Marker 'FROM-LATE-PATH-FAKE'
                Assert-True (Test-Path -LiteralPath $fake -PathType Leaf) 'fake adb compiled'
                $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 2) })
                $deadDrive = $null
                foreach ($letter in @('Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
                    if ($used -notcontains ($letter + ':')) { $deadDrive = $letter + ':'; break }
                }
                Assert-True ($null -ne $deadDrive) 'a free drive letter exists for the fixture'
                $badChars = 'C:\bad' + [string][char]60 + [string][char]62 + 'dir'
                # 'late' is a RELATIVE PATH entry: it must resolve to the
                # absolute candidate $workDir\late\adb.exe once the process
                # working directory is the work dir (GetFullPath resolves
                # against the process CWD, not the PowerShell location).
                $savedCwd = [System.Environment]::CurrentDirectory
                [System.Environment]::CurrentDirectory = $workDir
                try {
                    $env:PATH = "$deadDrive\dead;$badChars;late;C:\Windows\System32"
                    $global:LASTEXITCODE = 0
                    $out = @(& $probePath -Device '192.0.2.10:5555')
                    $json = ($out -join "`n")
                    $obj = ($json | ConvertFrom-Json)
                    Assert-Equal 1 $LASTEXITCODE 'exit code'
                    Assert-True ($json.Contains('FROM-LATE-PATH-FAKE')) 'the later adb.exe was resolved and ran'
                    Assert-Equal 0 @(@($obj.errors) | Where-Object { $_.code -eq 'AdbNotFound' }).Count 'no AdbNotFound'
                } finally {
                    [System.Environment]::CurrentDirectory = $savedCwd
                }
            } finally {
                $env:PATH = $savedPath
            }
        }

        Invoke-Test 'an explicit -AdbPath containing spaces runs' {
            try {
                $fake = New-MarkerFakeAdb -Dir (Join-Path $workDir 'space dir') -ExeName 'fake adb.exe' -Marker 'FROM-SPACED-FAKE'
                $global:LASTEXITCODE = 0
                $out = @(& $probePath -Device '192.0.2.10:5555' -AdbPath $fake)
                $json = ($out -join "`n")
                Assert-Equal 1 $LASTEXITCODE 'exit code'
                Assert-True ($json.Contains('FROM-SPACED-FAKE')) 'the spaced-path fake ran'
            } finally {
                $env:PATH = $savedPath
            }
        }
    } else {
        foreach ($name in @(
            'the explicit -AdbPath runs through the default runner even with a poisoned PATH',
            'PATH resolution takes the first adb.exe and ignores a .cmd shim',
            'dead drive and invalid PATH entries are skipped; a later adb.exe still resolves',
            'an explicit -AdbPath containing spaces runs'
        )) {
            $script:Skipped++
            Write-Host "SKIP $name :: csc.exe (.NET Framework 4) not found"
        }
    }

    # ---- EDID variants ----
    Invoke-Test '4K60 4:2:0-only EDID (mode listed as 2160p60hz420)' {
        $r = New-HealthyResponses
        $r["cat $Hdmi/disp_cap"] = "1080p60hz*`n2160p30hz`n2160p50hz420`n2160p60hz420`n"
        $res = Invoke-Probe $r
        Assert-True ($res.Obj.flags.supports4k60 -eq $true) 'supports4k60'
        Assert-Equal 'yuv420-only' $res.Obj.flags.fourK60ColorFormat 'color format'
        Assert-True (@($res.Obj.hdmi.supports4k60.raw) -contains '2160p60hz420') 'raw keeps the 420 mode'
    }

    Invoke-Test 'full HDMI 2.0 EDID (VIC 97, 600 MHz, SCDC 1) is rgb444-capable' {
        $r = New-HealthyResponses
        $edid = $EdidHdmi3.Replace('353 352', '97 96 353 352').Replace('MaxTMDSClock1 300 MHz', "MaxTMDSClock1 300 MHz`nMaxTMDSClock2 600 MHz").Replace('SCDC: 0', 'SCDC: 1')
        $r["cat $Hdmi/edid"] = $edid
        $res = Invoke-Probe $r
        Assert-Equal 600 $res.Obj.hdmi.maxTmdsClockMHz 'max TMDS'
        Assert-Equal 'rgb444-capable' $res.Obj.flags.fourK60ColorFormat 'color format'
    }

    Invoke-Test 'old-port EDID: 4K only up to 30 Hz' {
        $r = New-HealthyResponses
        $r['cat /sys/class/display/mode'] = "1080p60hz`n"
        $r["cat $Hdmi/disp_cap"] = "720p60hz`n1080p60hz*`n1080p50hz`n2160p30hz`n2160p25hz`n2160p24hz`n"
        $r["cat $Hdmi/edid"] = $EdidHdmi3.Replace('95 94 93 353 352 358 357', '95 94 93')
        $res = Invoke-Probe $r
        Assert-True ($res.Obj.flags.supports4k60 -eq $false) 'supports4k60 false'
        Assert-Equal 'not-offered' $res.Obj.flags.fourK60ColorFormat 'color format'
        Assert-Equal '1080p60hz' $res.Obj.hdmi.currentMode 'mode'
    }

    # ---- HDR EOTF present vs absent ----
    Invoke-Test 'HDR EOTF absent (all 0): supportsHdr false' {
        Assert-True ($healthy.Obj.flags.supportsHdr -eq $false) 'false'
        Assert-Equal 0 $healthy.Obj.hdr.eotf.smpteSt2084 'ST 2084'
        Assert-Equal 0 $healthy.Obj.hdr.eotf.hlg 'HLG'
    }

    Invoke-Test 'HDR EOTF ST 2084 present: supportsHdr true' {
        $r = New-HealthyResponses
        $r["cat $Hdmi/hdr_cap"] = $HdrCapNone.Replace('SMPTE ST 2084: 0', 'SMPTE ST 2084: 1').Replace('Traditional SDR: 0', 'Traditional SDR: 1')
        $res = Invoke-Probe $r
        Assert-True ($res.Obj.flags.supportsHdr -eq $true) 'true'
        Assert-True (@($res.Obj.hdr.supportsHdr.raw) -contains 'SMPTE ST 2084: 1') 'raw line'
    }

    Invoke-Test 'HLG only: reported, but supportsHdr stays false (Moonlight needs HDR10)' {
        $r = New-HealthyResponses
        $r["cat $Hdmi/hdr_cap"] = $HdrCapNone.Replace('Hybrif Log-Gamma: 0', 'Hybrif Log-Gamma: 1')
        $res = Invoke-Probe $r
        Assert-Equal 1 $res.Obj.hdr.eotf.hlg 'HLG'
        Assert-True ($res.Obj.flags.supportsHdr -eq $false) 'false'
    }

    Invoke-Test 'hdr_cap without EOTF lines is a ParseError, supportsHdr null' {
        $r = New-HealthyResponses
        $r["cat $Hdmi/hdr_cap"] = "HDR10Plus Supported: 0`n"
        $res = Invoke-Probe $r
        Assert-Null $res.Obj.flags.supportsHdr 'null'
        Assert-Equal 1 (Get-ProbeErrors $res 'hdr.eotf.smpteSt2084').Count 'ParseError recorded'
    }

    # ---- AV1 decoder present vs absent ----
    $aacLine = '<MediaCodec name="OMX.google.aac.decoder"'

    Invoke-Test 'AV1 decoder absent: hasAv1Decoder false' {
        Assert-True ($healthy.Obj.flags.hasAv1Decoder -eq $false) 'false'
    }

    Invoke-Test 'AV1 hardware decoder present: hasAv1Decoder true' {
        $r = New-HealthyResponses
        $r['cat /vendor/etc/media_codecs*.xml'] = $MediaCodecsNoAv1.Replace($aacLine, ('<MediaCodec name="OMX.amlogic.av1.decoder.awesome" type="video/av01" />' + "`n        " + $aacLine))
        $res = Invoke-Probe $r
        Assert-True ($res.Obj.flags.hasAv1Decoder -eq $true) 'true'
        Assert-True (@($res.Obj.decoders.hasAv1Decoder.raw) -contains 'OMX.amlogic.av1.decoder.awesome (video/av01, hardware)') 'raw entry'
    }

    Invoke-Test 'AV1 software decoder only: hasAv1Decoder false' {
        $r = New-HealthyResponses
        $r['cat /vendor/etc/media_codecs*.xml'] = $MediaCodecsNoAv1.Replace($aacLine, ('<MediaCodec name="c2.android.av1.decoder" type="video/av01" />' + "`n        " + $aacLine))
        $res = Invoke-Probe $r
        Assert-True ($res.Obj.flags.hasAv1Decoder -eq $false) 'false'
        Assert-True (@($res.Obj.decoders.hasAv1Decoder.raw) -contains 'c2.android.av1.decoder (video/av01, software)') 'raw lists the software decoder'
    }

    Invoke-Test 'codec XML unreadable: falls back to dumpsys media.player' {
        $r = New-HealthyResponses
        $r['cat /vendor/etc/media_codecs*.xml'] = @{ ExitCode = 1; StdOut = ''; StdErr = 'cat: /vendor/etc/media_codecs*.xml: No such file or directory'; TimedOut = $false }
        $r['dumpsys media.player'] = "  Codec: OMX.amlogic.hevc.decoder.awesome`n  Codec: OMX.amlogic.av1.decoder.awesome`n"
        $res = Invoke-Probe $r
        Assert-Equal 'dumpsys media.player' $res.Obj.decoders.source 'source'
        Assert-True ($res.Obj.flags.hasAv1Decoder -eq $true) 'AV1 found by name'
        Assert-Equal 1 (Get-ProbeErrors $res 'decoders.mediaCodecsXml').Count 'XML failure still recorded'
    }

    Invoke-Test 'no decoder source readable: hasAv1Decoder null' {
        $r = New-HealthyResponses
        $r['cat /vendor/etc/media_codecs*.xml'] = @{ ExitCode = 1; StdOut = ''; StdErr = 'no such file'; TimedOut = $false }
        $r['dumpsys media.player'] = " 2 registered handlers:`n  1: <stale>`n"
        $res = Invoke-Probe $r
        Assert-Null $res.Obj.flags.hasAv1Decoder 'null'
        Assert-Null $res.Obj.decoders.list 'list null'
    }

    # ---- Audio ----
    Invoke-Test 'multichannel PCM EDID: maxPcmChannels 8' {
        $r = New-HealthyResponses
        $r["cat $Hdmi/aud_cap"] = "CodingType MaxChannels SamplingFreq SampleSize`nPCM, 8 ch, 32/44.1/48 kHz, 16/20/24 bit`nAC-3, 6 ch, 44.1/48 kHz`n"
        $res = Invoke-Probe $r
        Assert-Equal 8 $res.Obj.flags.maxPcmChannels '8'
    }

    # ---- Output file ----
    Invoke-Test 'OutFile gets the same JSON, UTF-8 without BOM' {
        $path = Join-Path $workDir 'sub\probe.json'
        $res = Invoke-Probe (New-HealthyResponses) -OutFile $path
        Assert-True (Test-Path -LiteralPath $path) 'file written'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'no BOM'
        $fileObj = ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json)
        Assert-Equal 'A4091' $fileObj.device.model 'model in file'
    }

    Invoke-Test 'probe script is ASCII-only' {
        $bytes = [System.IO.File]::ReadAllBytes($probePath)
        $bad = @($bytes | Where-Object { $_ -gt 0x7E -or ($_ -lt 0x20 -and $_ -ne 9 -and $_ -ne 10 -and $_ -ne 13) })
        Assert-Equal 0 $bad.Count 'non-ASCII bytes'
    }

    Invoke-Test 'no user-specific adb default in the probe, the probe tests or the integration tests' {
        # The needle is assembled so this scan never matches its own source.
        $needleFolder = 'platform' + '-tools'
        foreach ($path in @($probePath, $PSCommandPath, (Join-Path $repoRoot 'tests\Invoke-TvBoxIntegrationTests.ps1'))) {
            $text = [System.IO.File]::ReadAllText($path)
            Assert-True ($text -notmatch 'C:\\+Users\\') ('user-profile path in ' + (Split-Path -Leaf $path))
            Assert-True (-not $text.Contains($needleFolder)) ('machine-specific adb folder in ' + (Split-Path -Leaf $path))
        }
    }
} finally {
    $env:GS_TVBOX_DEVICE = $originalDeviceEnv
    $env:PATH = $originalPathEnv
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Summary: {0} passed, {1} failed (skipped: {2})" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
