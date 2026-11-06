#requires -Version 5.1
<#
.SYNOPSIS
  Run a 4K60 Moonlight session from a second Windows client and save evidence.

.DESCRIPTION
  The host must already be paired and reachable. This script starts Moonlight
  in fullscreen/windowed mode, waits for the stream, captures a client-side
  screenshot when ffmpeg is available, and writes a JSON summary next to the
  logs. It does not modify the host.

.EXAMPLE
  .\Invoke-Moonlight4KTest.ps1 -HostUuid a9fa37b4-50a1-40b2-9344-1e44f4a603ca
#>
[CmdletBinding()]
param(
    [string]$MoonlightPath = 'C:\Program Files\Moonlight Game Streaming\Moonlight.exe',
    [Parameter(Mandatory = $true)][string]$HostUuid,
    [ValidateSet('4K', '1440', '1080', '720')][string]$Resolution = '4K',
    [int]$Fps = 60,
    [int]$BitrateKbps = 50000,
    [ValidateSet('fullscreen', 'windowed', 'borderless')][string]$DisplayMode = 'fullscreen',
    [int]$Seconds = 60,
    [string]$OutputDir = (Join-Path $PSScriptRoot ('evidence-' + (Get-Date -Format 'yyyyMMdd_HHmmss'))),
    [string]$FfmpegPath = ''
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $MoonlightPath)) { throw "Moonlight not found: $MoonlightPath" }
New-Item -ItemType Directory -Path $OutputDir, (Join-Path $OutputDir 'logs'), (Join-Path $OutputDir 'shots') -Force | Out-Null
$log = Join-Path $OutputDir 'logs\moonlight.log'
$err = Join-Path $OutputDir 'logs\moonlight.log.err'
$args = @('stream', $HostUuid, 'Desktop', ('--' + $Resolution), '--fps', [string]$Fps, '--bitrate', [string]$BitrateKbps, '--display-mode', $DisplayMode, '--performance-overlay')
$p = Start-Process -FilePath $MoonlightPath -ArgumentList $args -RedirectStandardOutput $log -RedirectStandardError $err -PassThru
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ((Test-Path -LiteralPath $err) -and (Select-String -LiteralPath $err -Pattern 'Launch response' -Quiet -ErrorAction SilentlyContinue)) { break }
}
Start-Sleep -Seconds $Seconds
if ($FfmpegPath -and (Test-Path -LiteralPath $FfmpegPath)) {
    & $FfmpegPath -hide_banner -loglevel error -f lavfi -i 'ddagrab=0:framerate=1' -vf 'hwdownload,format=bgra' -frames:v 1 -y (Join-Path $OutputDir 'shots\client.png') 2>>(Join-Path $OutputDir 'logs\capture.log')
}
$launch = ''
$video = ''
$l = Select-String -LiteralPath $err -Pattern 'Launch response' -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($l) { $launch = $l.Line }
$v = Select-String -LiteralPath $err -Pattern 'Video stream is' -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($v) { $video = $v.Line }
if ($p -and -not $p.HasExited) {
    # End the host-side session cleanly first.  A forced Stop-Process leaves
    # nvstreamer alive on the host and the server stuck in SERVER_BUSY, which
    # makes the next pairing/launch fail with isBusy/526.
    try {
        & $MoonlightPath quit $HostUuid 2>$null | Out-Null
        Start-Sleep -Seconds 5
    } catch { }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
$result = [pscustomobject]@{
    Client = $env:COMPUTERNAME
    HostUuid = $HostUuid
    Resolution = $Resolution
    Fps = $Fps
    BitrateKbps = $BitrateKbps
    DisplayMode = $DisplayMode
    Launch = $launch
    Video = $video
    Screenshot = $(if (Test-Path -LiteralPath (Join-Path $OutputDir 'shots\client.png')) { (Join-Path $OutputDir 'shots\client.png') } else { '' })
    Log = $err
    FinishedAt = (Get-Date).ToString('o')
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDir 'client-evidence.json') -Encoding UTF8
$result | Format-List
if ($launch -notmatch 'status_code="200"') { exit 2 }
if ($video -notmatch '3840x2160') { exit 3 }
exit 0
