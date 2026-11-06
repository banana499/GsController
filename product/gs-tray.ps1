#requires -Version 5.1
<#
.SYNOPSIS
  Tray/status UI host for GsController.

.DESCRIPTION
  Shows a single notification-area icon that polls the runtime status file
  and (when the runtime reports ready/running) the streamer serverinfo
  endpoint through gs-tray-model.ps1 - the HTTP fetch runs on a background
  runspace so the UI thread never blocks on the network, and on exit an
  in-flight fetch is only signalled to stop, never waited on - and offers
  the menu actions Start, Stop, Status, Recover (a stuck session), Create
  support bundle, Open logs and Exit.

  Every user-visible text is translated from the external string table
  gs-tray-strings.zh-CN.json next to this script (K4, UTF-8 without BOM;
  a BOM-prefixed file is accepted by stripping the BOM). A missing or
  invalid table falls back to the built-in English table, which is logged;
  the tray log itself keeps the English state names and details.

  Start, Stop and Recover run gs-product.ps1 in a hidden child
  powershell.exe using an -EncodedCommand; when this process is not
  elevated the child is launched with -Verb RunAs (UAC) and a hidden window
  style. The support bundle runs gs-support.ps1 in a plain hidden child
  (never elevated via UAC). Recover asks for confirmation first - it
  interrupts a streaming client. This script never touches services,
  scheduled tasks, runtime processes, or pause flags itself - the CLI owns
  all lifecycle logic.

  Run with -STA (normally through gs-tray.vbs, which also hides the console
  window). Single instance enforced via the named mutex 'Local\GsController.Tray'.
  Every exception is appended to <TrayLogDir>\tray.log (rotated to tray.log.1
  at 1 MB); no raw exception dialog is ever shown.

  Parameters:
    -ProductPath   gs-product.ps1 (default: next to this script)
    -StateDir      product state dir (default: %ProgramData%\Local Development\GsController)
    -LogDir        product log dir (default: %ProgramData%\Local Development\GsControllerLogs)
    -ServerInfoUri serverinfo endpoint (default: http://127.0.0.1:47989/serverinfo)
    -PollMs        poll interval, default 2000
    -TrayLogDir    tray log + result dir (default: %LOCALAPPDATA%\GsController\tray)
    -ExitAfterSec  auto-exit for smoke runs only; 0 means run until Exit
#>
[CmdletBinding()]
param(
    [string]$ProductPath = '',
    [string]$StateDir = '',
    [string]$LogDir = '',
    [string]$ServerInfoUri = 'http://127.0.0.1:47989/serverinfo',
    [ValidateRange(200, 600000)]
    [int]$PollMs = 2000,
    [string]$TrayLogDir = '',
    [int]$ExitAfterSec = 0
)
$ErrorActionPreference = 'Stop'

# Path defaults are resolved in the body: $PSScriptRoot is empty inside the
# param block when powershell.exe runs a script with -File.
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ProductPath)) { $ProductPath = Join-Path $scriptRoot 'gs-product.ps1' }
if ([string]::IsNullOrWhiteSpace($StateDir)) { $StateDir = Join-Path $env:ProgramData 'Local Development\GsController' }
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $env:ProgramData 'Local Development\GsControllerLogs' }
if ([string]::IsNullOrWhiteSpace($TrayLogDir)) { $TrayLogDir = Join-Path $env:LOCALAPPDATA 'GsController\tray' }

$modelPath = Join-Path $scriptRoot 'gs-tray-model.ps1'
if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) { throw "Tray model not found: $modelPath" }
. $modelPath

$script:ResultsDir = Join-Path $TrayLogDir 'results'
foreach ($dir in @($TrayLogDir, $script:ResultsDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

function Write-TrayLog {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    try {
        $logPath = Join-Path $TrayLogDir 'tray.log'
        if ((Test-Path -LiteralPath $logPath) -and ((Get-Item -LiteralPath $logPath).Length -ge 1MB)) {
            Move-Item -LiteralPath $logPath -Destination (Join-Path $TrayLogDir 'tray.log.1') -Force
        }
        [IO.File]::AppendAllText($logPath, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
    } catch { } # Logging must never take the tray down.
}

# ---- Single instance -------------------------------------------------------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\GsController.Tray')
$owned = $false
try { $owned = $script:Mutex.WaitOne([TimeSpan]::Zero, $false) }
catch [System.Threading.AbandonedMutexException] {
    # The previous holder died without releasing; the handle is ours now.
    $owned = $true
}
if (-not $owned) {
    $script:Mutex.Dispose()
    exit 0
}

# ---- String table (K4) -----------------------------------------------------
# Load the external zh-CN table with built-in English fallback. Never throws:
# a loader failure falls back and is logged like any other fallback reason.
$script:TrayStrings = $null
try {
    $stringsResult = Get-GsTrayStrings -Path (Join-Path $scriptRoot 'gs-tray-strings.zh-CN.json')
} catch {
    $stringsResult = $null
}
if ($null -eq $stringsResult) {
    $stringsResult = [pscustomobject]@{ Source = 'builtin'; Path = ''; FallbackReason = 'string table loader threw'; Strings = (Get-GsTrayBuiltinStrings); KeyCount = 0 }
}
$script:TrayStrings = $stringsResult.Strings
if ($stringsResult.Source -eq 'file') {
    Write-TrayLog ('Strings: zh-CN table loaded (' + $stringsResult.KeyCount + ' keys).')
} else {
    Write-TrayLog ('Strings: falling back to built-in English table: ' + $stringsResult.FallbackReason)
}

# ---- WinForms --------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:NativeLoaded = $false
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GsTrayNative {
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@
    $script:NativeLoaded = $true
} catch {
    # Without DestroyIcon we simply keep the six handles until process exit.
}

$script:IconHandles = New-Object System.Collections.Generic.List[IntPtr]
function New-GsStateIcon {
    param([System.Drawing.Color]$Color)
    # One bitmap per state, disposed right after the HICON is taken.
    # Icon.FromHandle does not own the handle; handles are destroyed at exit.
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $brush = New-Object System.Drawing.SolidBrush($Color)
            try { $graphics.FillEllipse($brush, 2, 2, 11, 11) } finally { $brush.Dispose() }
        } finally { $graphics.Dispose() }
        $hIcon = $bmp.GetHicon()
        $script:IconHandles.Add($hIcon)
        return [System.Drawing.Icon]::FromHandle($hIcon)
    } finally { $bmp.Dispose() }
}

$script:IconStopped = New-GsStateIcon ([System.Drawing.Color]::Gray)
$script:IconStarting = New-GsStateIcon ([System.Drawing.Color]::Gold)
$script:IconStopping = New-GsStateIcon ([System.Drawing.Color]::Orange)
$script:IconReady = New-GsStateIcon ([System.Drawing.Color]::LimeGreen)
$script:IconStreaming = New-GsStateIcon ([System.Drawing.Color]::RoyalBlue)
$script:IconError = New-GsStateIcon ([System.Drawing.Color]::Red)
$script:StateIcons = @{
    'Stopped'   = $script:IconStopped
    'Starting'  = $script:IconStarting
    'Stopping'  = $script:IconStopping
    'Ready'     = $script:IconReady
    'Streaming' = $script:IconStreaming
    'Error'     = $script:IconError
}

$script:Pending = $null
$script:PendingStartedUtc = $null
$script:LastResult = $null
$script:LastStateName = ''
$script:LastDetail = ''
$script:LastDetailText = ''     # translated detail for the status dialog
$script:LastTooltip = ''        # last composed tooltip text (change detection)
$script:ConfirmedState = ''     # last state confirmed by two consecutive polls (B3)
$script:LastPollState = ''      # raw mapped state of the previous poll (B3)
$script:Stopped = $false
$script:PendingTimeoutSec = 300
$script:SupportScriptPath = Join-Path $scriptRoot 'gs-support.ps1'
# Injectable elevation probe (B-B3, K3): the support bundle must never run
# elevated, so the support menu item asks this probe and refuses to launch
# anything when the tray process itself is elevated. Reassign this slot to
# fake the elevation state in a host that needs to.
$script:IsTrayElevated = { Test-GsTrayElevated }
# Background serverinfo pipeline: at most one fetch in flight at a time, the
# UI thread only harvests the finished job and reads the cached result.
$script:ServerInfoJob = $null      # in-flight fetch: { Engine; Handle }
$script:LastServerInfo = $null     # last completed fetch: { Info; CompletedUtc }
$script:ServerInfoMaxAgeSec = 6    # older results count as missing serverinfo

function Format-TrayText {
    # Wrapper so the UI layer never touches the table directly: translates
    # one string-table key and never throws.
    param([string]$Key, [object[]]$Arguments = @())
    return (Format-GsTrayText -Strings $script:TrayStrings -Key $Key -Arguments $Arguments)
}

function Get-TrayBalloonTitle {
    return (Format-TrayText -Key 'balloon.title')
}

function Show-Balloon {
    param([string]$Title, [string]$Text, [string]$Kind = 'Info')
    try {
        $kind = [System.Windows.Forms.ToolTipIcon]::Info
        if ($Kind -eq 'Warning') { $kind = [System.Windows.Forms.ToolTipIcon]::Warning }
        if ($Kind -eq 'Error') { $kind = [System.Windows.Forms.ToolTipIcon]::Error }
        $script:Notify.ShowBalloonTip(5000, $Title, $Text, $kind)
    } catch {
        try { Write-TrayLog ('Balloon failed: ' + $_.Exception.Message) } catch { }
    }
}

function Set-TrayIcon {
    param([string]$State)
    $icon = $script:IconStopped
    if ($script:StateIcons.ContainsKey($State)) { $icon = $script:StateIcons[$State] }
    try { $script:Notify.Icon = $icon } catch { }
}

function Set-TrayTooltip {
    # The composed text (string-table prefix + translated detail + pause
    # suffix) arrives already capped at the 63 character NotifyIcon limit.
    param([string]$Text)
    try { if ($script:Notify.Text -ne $Text) { $script:Notify.Text = $Text } } catch { }
}

function Update-MenuFromState {
    param($State)
    $pendingAction = ''
    if ($null -ne $script:Pending) { $pendingAction = [string]$script:Pending.Action }
    $script:MenuStartItem.Enabled = Get-GsTrayMenuEnabled -StateRow $State -PendingAction $pendingAction -MenuItem 'Start'
    $script:MenuStopItem.Enabled = Get-GsTrayMenuEnabled -StateRow $State -PendingAction $pendingAction -MenuItem 'Stop'
    $script:MenuRecoverItem.Enabled = Get-GsTrayMenuEnabled -StateRow $State -PendingAction $pendingAction -MenuItem 'Recover'
    $script:MenuSupportItem.Enabled = Get-GsTrayMenuEnabled -StateRow $State -PendingAction $pendingAction -MenuItem 'SupportBundle'
}

function Get-TrayActionLabel {
    # Translates a pending-action code (Start/Stop/Recover/SupportBundle)
    # into its menu label for balloons; falls back to the raw code.
    param([string]$Action)
    try {
        $key = 'menu.' + $Action.Substring(0, 1).ToLowerInvariant() + $Action.Substring(1)
        $label = Format-TrayText -Key $key
        if (-not [string]::IsNullOrEmpty($label) -and $label -ne $key) { return $label }
    } catch { }
    return $Action
}

function Invoke-MenuItem {
    param([string]$Action)
    try {
        if ($null -ne $script:Pending) { return }
        $resultFile = Join-Path $script:ResultsDir ([guid]::NewGuid().ToString('N') + '.json')
        $command = New-GsTrayChildCommand -ProductPath $ProductPath -Action $Action -StateDir $StateDir -LogDir $LogDir -ResultFile $resultFile
        $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $proc = $null
        if ($isElevated) {
            $proc = Start-Process -FilePath $command.FilePath -ArgumentList $command.Arguments -WindowStyle Hidden -PassThru
        } else {
            # -WindowStyle Hidden keeps the elevated child's console from flashing.
            $proc = Start-Process -FilePath $command.FilePath -ArgumentList $command.Arguments -Verb RunAs -WindowStyle Hidden -PassThru
        }
        $script:Pending = [pscustomobject]@{ Action = $Action; Process = $proc; ResultFile = $resultFile }
        $script:PendingStartedUtc = [DateTime]::UtcNow
        Write-TrayLog ("CLI '{0}' launched (pid {1}, elevated={2})." -f $Action, $proc.Id, $isElevated)
    } catch [System.ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) {
            # The user cancelled the UAC prompt: log it, show a balloon, keep going.
            Write-TrayLog ("UAC prompt for '{0}' was cancelled by the user." -f $Action)
            Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'balloon.uacCancelled' -Arguments @((Get-TrayActionLabel $Action))) Warning
            return
        }
        Write-TrayLog ("Menu '{0}' failed: {1}" -f $Action, $_.Exception.ToString())
        Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'balloon.launchFailed' -Arguments @((Get-TrayActionLabel $Action))) Error
    } catch {
        Write-TrayLog ("Menu '{0}' failed: {1}" -f $Action, $_.Exception.ToString())
        Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'balloon.launchFailed' -Arguments @((Get-TrayActionLabel $Action))) Error
    }
}

function Update-PendingAction {
    # Decides whether the pending CLI child is finished and reports the
    # outcome. Finish detection (Test-GsTrayPendingDone): a usable result
    # file (anything other than NoResult) or a known-exited process; when
    # .HasExited throws (a non-elevated tray reading an elevated child) it
    # is treated as unknown, never as exited, and a Get-Process liveness
    # check plus the 300 s cap decide instead. Once the decision is made
    # (done or timed out) the child Process object is disposed - the last
    # HasExited/liveness read has happened by then - before the pending
    # action is cleared.
    if ($null -eq $script:Pending) { return }
    $proc = $script:Pending.Process
    $hasExited = $null
    try { $hasExited = [bool]$proc.HasExited } catch { $hasExited = $null }
    $processAlive = $null
    try {
        if ($proc.Id -gt 0) { $processAlive = ($null -ne (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) }
    } catch { $processAlive = $null }
    $parsed = $null
    try { $parsed = Read-GsTrayCommandResult -Path $script:Pending.ResultFile } catch {
        $parsed = [pscustomobject]@{ Success = $false; Code = 'NoResult'; Message = $_.Exception.Message }
    }
    $elapsedSec = ([DateTime]::UtcNow - $script:PendingStartedUtc).TotalSeconds
    $decision = Test-GsTrayPendingDone -ResultParsed $parsed -HasExited $hasExited -ProcessAlive $processAlive -ElapsedSec $elapsedSec -TimeoutSec $script:PendingTimeoutSec
    if ($decision -eq 'Waiting') { return }

    $action = $script:Pending.Action
    $resultFile = $script:Pending.ResultFile
    if ($decision -eq 'Done') {
        # The support bundle result (K1 shape) must be parsed before the
        # result file is deleted below.
        $supportResult = $null
        if ($action -eq 'SupportBundle') {
            try { $supportResult = Read-GsTraySupportResult -Path $resultFile } catch { $supportResult = $null }
        }
        try {
            if (Test-Path -LiteralPath $resultFile) { Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue }
        } catch { }
        $script:LastResult = $parsed
        $actionLabel = Get-TrayActionLabel $action
        if ($action -eq 'SupportBundle') {
            if ($null -ne $supportResult -and $supportResult.Success -and -not [string]::IsNullOrWhiteSpace($supportResult.ZipPath)) {
                try {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $supportResult.ZipPath + '"')
                } catch {
                    Write-TrayLog ('Support bundle: opening the zip in Explorer failed: ' + $_.Exception.Message)
                }
                Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'support.success' -Arguments @($supportResult.ZipPath)) Info
                Write-TrayLog ("Support bundle finished: Success={0} ZipPath='{1}'." -f $supportResult.Success, $supportResult.ZipPath)
            } else {
                # B-N1: a failure whose code came out empty (no usable
                # Errors[0].Code string) is a missing failure code and maps
                # to NoResult - never to the empty-code success balloon.
                $supportCode = 'NoResult'
                if ($null -ne $supportResult) {
                    $supportCode = $supportResult.Code
                    if ([string]::IsNullOrWhiteSpace($supportCode)) { $supportCode = 'NoResult' }
                }
                $balloon = Resolve-GsTraySupportBalloon -Strings $script:TrayStrings -Code $supportCode
                Show-Balloon (Get-TrayBalloonTitle) $balloon.Text $balloon.Kind
                Write-TrayLog ("Support bundle finished: Success={0} Code='{1}'." -f $parsed.Success, $parsed.Code)
            }
        } elseif ($parsed.Success) {
            $completedKey = 'balloon.actionCompleted'
            if ($action -eq 'Recover') { $completedKey = 'recover.success' }
            Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key $completedKey -Arguments @($actionLabel)) Info
            Write-TrayLog ("CLI '{0}' finished: Success={1} Code='{2}'." -f $action, $parsed.Success, $parsed.Code)
        } elseif ($parsed.Code -eq 'Busy') {
            Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'balloon.busy') Warning
            Write-TrayLog ("CLI '{0}' finished: Success={1} Code='{2}'." -f $action, $parsed.Success, $parsed.Code)
        } elseif ($parsed.Code -eq 'NoResult') {
            Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'balloon.noUsableResult' -Arguments @($actionLabel)) Error
            Write-TrayLog ("CLI '{0}' finished: Success={1} Code='{2}'." -f $action, $parsed.Success, $parsed.Code)
        } elseif ($action -eq 'Recover') {
            # Recover refusals arrive as Code='RecoverRefused' with Reason;
            # every documented reason and failure code maps to its own
            # balloon, and an unknown reason or code is shown raw (K3).
            $balloon = Resolve-GsTrayRecoverBalloon -Strings $script:TrayStrings -Code $parsed.Code -Reason $parsed.Reason -ActionLabel $actionLabel
            Show-Balloon (Get-TrayBalloonTitle) $balloon.Text $balloon.Kind
            Write-TrayLog ("CLI '{0}' finished: Success={1} Code='{2}' Reason='{3}'." -f $action, $parsed.Success, $parsed.Code, $parsed.Reason)
        } else {
            Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'balloon.actionFailed' -Arguments @($actionLabel, $parsed.Code)) Error
            Write-TrayLog ("CLI '{0}' finished: Success={1} Code='{2}'." -f $action, $parsed.Success, $parsed.Code)
        }
    } else {
        # The child is still running after the wait cap: stop waiting so the
        # menus unlock; the child keeps its lifecycle lock and later callers
        # get 'Busy' from the CLI itself. The orphaned result file is cleaned
        # up on the next tray start.
        $script:LastResult = [pscustomobject]@{ Success = $false; Code = 'Timeout'; Message = 'CLI did not finish within the wait cap.' }
        Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'balloon.actionStillRunning' -Arguments @((Get-TrayActionLabel $action))) Warning
        Write-TrayLog ("CLI '{0}' wait timed out after {1} s." -f $action, $script:PendingTimeoutSec)
    }
    # The decision is made (done or timed out), so the Process object is no
    # longer read: dispose it on every finish path.
    try { $proc.Dispose() } catch { }
    $script:Pending = $null
    $script:PendingStartedUtc = $null
}

function Get-GsTrayCachedServerInfo {
    # Returns the last completed background serverinfo result, or $null when
    # none has completed yet or the newest one is older than the staleness
    # cap (a stale result counts as missing serverinfo, i.e. 'unreachable').
    if ($null -eq $script:LastServerInfo) { return $null }
    $ageSec = ([DateTime]::UtcNow - $script:LastServerInfo.CompletedUtc).TotalSeconds
    if ($ageSec -gt $script:ServerInfoMaxAgeSec) { return $null }
    return $script:LastServerInfo.Info
}

function Update-GsServerInfoPipeline {
    # Harvests a finished background serverinfo fetch (disposing its
    # runspace), then starts a new one - also on a background runspace with
    # BeginInvoke - when the status file says ready/running and none is in
    # flight. The UI thread never blocks on HTTP; it only reads
    # Get-GsTrayCachedServerInfo.
    param([bool]$Want, [string]$Uri)
    if ($null -ne $script:ServerInfoJob) {
        $job = $script:ServerInfoJob
        if ($job.Handle.IsCompleted) {
            $info = $null
            try {
                $output = $job.Engine.EndInvoke($job.Handle)
                if ($null -ne $output -and @($output).Count -gt 0) { $info = @($output)[0] }
            } catch { }
            try { $job.Engine.Dispose() } catch { }
            $script:ServerInfoJob = $null
            if ($null -ne $info) {
                $script:LastServerInfo = [pscustomobject]@{ Info = $info; CompletedUtc = [DateTime]::UtcNow }
            }
        }
    }
    if ($Want -and $null -eq $script:ServerInfoJob) {
        # A fresh runspace per fetch; dot-sourcing the model is cheap (pure
        # functions only) and keeps the background runspace self-contained.
        $engine = [powershell]::Create()
        [void]$engine.AddScript({
                param($ModelPath, $TargetUri)
                . $ModelPath
                Get-GsTrayServerInfo -Uri $TargetUri
            }).AddArgument($script:modelPath).AddArgument($Uri)
        $script:ServerInfoJob = [pscustomobject]@{ Engine = $engine; Handle = $engine.BeginInvoke() }
    }
}

function Invoke-PollTick {
    try {
        Update-PendingAction
        $statusInfo = Get-GsTrayStatusInfo -StateDir $StateDir
        $wantServerInfo = $false
        if ($statusInfo.Exists -and $statusInfo.Readable -and [string]::IsNullOrEmpty($statusInfo.Error)) {
            $statusText = ''
            if ($null -ne $statusInfo.State) { $statusText = ([string]$statusInfo.State).Trim().ToLowerInvariant() }
            if ($statusText -eq 'ready' -or $statusText -eq 'running') { $wantServerInfo = $true }
        }
        Update-GsServerInfoPipeline -Want $wantServerInfo -Uri $ServerInfoUri
        $serverInfo = Get-GsTrayCachedServerInfo
        $pendingAction = ''
        if ($null -ne $script:Pending) { $pendingAction = $script:Pending.Action }
        $state = Get-GsTrayState -StatusInfo $statusInfo -ServerInfo $serverInfo -PendingAction $pendingAction

        # B3 notifications: compare the mapped state against the previous raw
        # poll and the last confirmed state BEFORE advancing them. A state is
        # only confirmed after two consecutive polls agree (debounce); the
        # pause suffix (either supervisor pause flag, Test-Path only) is
        # appended inside the notification and tooltip.
        $paused = $false
        try { $paused = Test-GsTrayPauseFlag -StateDir $StateDir } catch { $paused = $false }
        $notification = Get-GsTrayNotification -Strings $script:TrayStrings -Confirmed $script:ConfirmedState -Previous $script:LastPollState -Current $state.State -Paused $paused -PausedSuffix (Format-TrayText -Key 'notify.pausedSuffix')
        if ($state.State -eq $script:LastPollState) { $script:ConfirmedState = $state.State }
        $script:LastPollState = $state.State
        if ($null -ne $notification) {
            Show-Balloon (Get-TrayBalloonTitle) $notification Info
            Write-TrayLog ('Notification: ' + $notification)
        }

        # Translated tooltip (K4): translated detail (capped at the 63
        # character limit after translation) + table prefix + pause suffix.
        # The tray log keeps the English state name and detail.
        $detailText = Get-GsTrayDetailText -Strings $script:TrayStrings -StateRow $state
        $tooltip = Get-GsTrayTooltipText -Prefix (Format-TrayText -Key 'tooltip.prefix') -Detail $detailText -Paused $paused -PausedSuffix (Format-TrayText -Key 'notify.pausedSuffix')
        if ($state.State -ne $script:LastStateName -or $state.Detail -ne $script:LastDetail) {
            Set-TrayIcon -State $state.State
            $script:LastStateName = $state.State
            $script:LastDetail = $state.Detail
            $script:LastDetailText = $detailText
            Write-TrayLog ('State: ' + $state.State + ' (' + $state.Detail + ')')
        }
        if ($tooltip -ne $script:LastTooltip) {
            Set-TrayTooltip -Text $tooltip
            $script:LastTooltip = $tooltip
        }
        Update-MenuFromState -State $state
    } catch {
        Write-TrayLog ('Poll tick failed: ' + $_.Exception.ToString())
    }
}

function Invoke-MenuStatus {
    try {
        $statusInfo = Get-GsTrayStatusInfo -StateDir $StateDir
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add((Format-TrayText -Key 'status.trayState' -Arguments @((Get-GsTrayStateName -Strings $script:TrayStrings -State $script:LastStateName))))
        $lines.Add((Format-TrayText -Key 'status.detail' -Arguments @($script:LastDetailText)))
        if ($null -ne $script:Pending) { $lines.Add((Format-TrayText -Key 'status.pendingAction' -Arguments @((Get-TrayActionLabel ([string]$script:Pending.Action))))) }
        $lines.Add((Format-TrayText -Key 'status.statusFile' -Arguments @($statusInfo.Path)))
        if ($statusInfo.Exists) { $lines.Add((Format-TrayText -Key 'status.statusFilePresent')) } else { $lines.Add((Format-TrayText -Key 'status.statusFileMissing')) }
        if (-not [string]::IsNullOrEmpty($statusInfo.Error)) { $lines.Add((Format-TrayText -Key 'status.statusError' -Arguments @($statusInfo.Error))) }
        if ($null -ne $script:LastResult) {
            $lines.Add((Format-TrayText -Key 'status.lastResult' -Arguments @($script:LastResult.Success, $script:LastResult.Code)))
        } else {
            $lines.Add((Format-TrayText -Key 'status.lastResultNone'))
        }
        $lines.Add((Format-TrayText -Key 'status.trayLog' -Arguments @((Join-Path $TrayLogDir 'tray.log'))))
        [void][System.Windows.Forms.MessageBox]::Show(($lines -join "`r`n"), (Format-TrayText -Key 'status.title'))
    } catch {
        Write-TrayLog ('Status dialog failed: ' + $_.Exception.ToString())
    }
}

function Invoke-MenuOpenLogs {
    try {
        $target = $LogDir
        if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { $target = $TrayLogDir }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $target + '"')
        Write-TrayLog ('Opened log folder: ' + $target)
    } catch {
        Write-TrayLog ('Open logs failed: ' + $_.Exception.ToString())
    }
}

function Invoke-MenuRecover {
    # Recover clears a stuck GameStream session with one stop + one start
    # (K3): that interrupts a streaming client, so the action only runs
    # after an explicit confirmation dialog. Confirm -> the same hidden CLI
    # child flow as Start/Stop (-Action Recover).
    try {
        if ($null -ne $script:Pending) { return }
        $choice = [System.Windows.Forms.MessageBox]::Show((Format-TrayText -Key 'recover.confirmText'), (Format-TrayText -Key 'recover.confirmTitle'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-TrayLog 'Recover cancelled at the confirmation dialog.'
            return
        }
        Invoke-MenuItem 'Recover'
    } catch {
        Write-TrayLog ('Recover menu failed: ' + $_.Exception.ToString())
    }
}

function Invoke-MenuSupportBundle {
    # Runs the sibling gs-support.ps1 (K1) in a plain hidden child - never a
    # UAC elevation: the bundle is a read-only diagnostic, so a non-elevated
    # tray (the normal case) produces a non-elevated child. B-B3 (K3): when
    # the tray process itself is elevated the child would inherit that
    # elevation, so nothing is launched at all - no attempt is made to
    # obtain a non-elevated token - and the support-failed balloon with the
    # fixed elevated-tray reason is shown (English log line, Chinese UI
    # string). The elevation probe is injectable ($script:IsTrayElevated)
    # and the branch decision comes from the model
    # (Resolve-GsTraySupportLaunch). The result file carries the K1 result;
    # success opens Explorer at the zip, failures map to balloons (missing
    # tool: support.missing).
    try {
        if ($null -ne $script:Pending) { return }
        $probeElevated = $true
        try { $probeElevated = [bool](& $script:IsTrayElevated) } catch { $probeElevated = $true }
        $launchDecision = Resolve-GsTraySupportLaunch -Elevated $probeElevated
        if (-not $launchDecision.Launch) {
            Write-TrayLog ('Support bundle refused: ' + $launchDecision.RefusedReason + ' - the tray process itself is elevated and the support bundle never runs elevated (K3).')
            Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'support.elevatedRefused') Error
            return
        }
        if (-not (Test-Path -LiteralPath $script:SupportScriptPath -PathType Leaf)) {
            Write-TrayLog ('Support bundle: gs-support.ps1 not found at ' + $script:SupportScriptPath)
            Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'support.missing') Warning
            return
        }
        $resultFile = Join-Path $script:ResultsDir ([guid]::NewGuid().ToString('N') + '.json')
        $supportCommand = New-GsTraySupportCommand -SupportScriptPath $script:SupportScriptPath -ResultFile $resultFile -InstallDir $scriptRoot -StateDir $StateDir -LogDir $LogDir -TrayLogDir $TrayLogDir -ServerInfoUri $ServerInfoUri
        $proc = Start-Process -FilePath $supportCommand.FilePath -ArgumentList $supportCommand.Arguments -WindowStyle Hidden -PassThru
        $script:Pending = [pscustomobject]@{ Action = 'SupportBundle'; Process = $proc; ResultFile = $resultFile }
        $script:PendingStartedUtc = [DateTime]::UtcNow
        Write-TrayLog ('Support bundle launched (pid ' + $proc.Id + ').')
    } catch {
        Write-TrayLog ('Support bundle menu failed: ' + $_.Exception.ToString())
        Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'balloon.launchFailed' -Arguments @((Get-TrayActionLabel 'SupportBundle'))) Error
    }
}

function Stop-GsTray {
    if ($script:Stopped) { return }
    $script:Stopped = $true
    try {
        if ($null -ne $script:PollTimer) { $script:PollTimer.Stop(); $script:PollTimer.Dispose() }
    } catch { }
    try {
        if ($null -ne $script:ExitTimer) { $script:ExitTimer.Stop(); $script:ExitTimer.Dispose() }
    } catch { }
    try {
        if ($null -ne $script:ServerInfoJob) {
            $job = $script:ServerInfoJob
            $script:ServerInfoJob = $null
            # Never wait synchronously on the in-flight fetch here: its
            # engine may be inside a bounded network wait, and Dispose
            # joins the pipeline. BeginStop only signals it - the fetch
            # aborts itself at its own timeout and process exit reclaims
            # the runspace.
            try { [void]$job.Engine.BeginStop($null, $null) } catch { }
        }
    } catch { }
    try {
        if ($null -ne $script:Notify) {
            $script:Notify.Visible = $false
            $script:Notify.Icon = $null
            $script:Notify.Dispose()
            $script:Notify = $null
        }
    } catch { }
    if ($script:NativeLoaded) {
        foreach ($handle in $script:IconHandles) {
            try { [void][GsTrayNative]::DestroyIcon($handle) } catch { }
        }
    }
    try {
        if ($null -ne $script:Mutex) {
            try { $script:Mutex.ReleaseMutex() } catch { }
            $script:Mutex.Dispose()
            $script:Mutex = $null
        }
    } catch { }
    Write-TrayLog 'Tray stopped.'
}

function Invoke-MenuExit {
    try { Write-TrayLog 'Exit requested.' } catch { }
    Stop-GsTray
    try { $script:AppContext.ExitThread() } catch { }
}

# ---- Global exception handlers --------------------------------------------
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch { }
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $eventArgs)
    try { Write-TrayLog ('UI thread exception: ' + $eventArgs.Exception.ToString()) } catch { }
    try { Show-Balloon (Get-TrayBalloonTitle) (Format-TrayText -Key 'balloon.internalError') Error } catch { }
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $eventArgs)
    try { Write-TrayLog ('Unhandled exception: ' + $eventArgs.ExceptionObject.ToString()) } catch { }
})

# ---- Startup ---------------------------------------------------------------
foreach ($stale in @(Get-ChildItem -LiteralPath $script:ResultsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    try { Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue } catch { }
}
Write-TrayLog ('Tray starting (pid ' + $PID + '). ProductPath=' + $ProductPath + ' StateDir=' + $StateDir + ' LogDir=' + $LogDir + ' PollMs=' + $PollMs + ' ServerInfoUri=' + $ServerInfoUri)

$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$script:Notify.Icon = $script:IconStopped
# B-B1: the initial tooltip goes through the same capped composer as every
# later poll tooltip - a direct assignment of the raw table prefix would
# throw in the NotifyIcon.Text setter for a tooltip.prefix over 63 chars.
$script:Notify.Text = (Get-GsTrayTooltipText -Prefix (Format-TrayText -Key 'tooltip.prefix'))
$script:Notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:MenuStartItem = $menu.Items.Add((Format-TrayText -Key 'menu.start'))
$script:MenuStartItem.add_Click({ Invoke-MenuItem 'Start' })
$script:MenuStopItem = $menu.Items.Add((Format-TrayText -Key 'menu.stop'))
$script:MenuStopItem.add_Click({ Invoke-MenuItem 'Stop' })
$script:MenuStatusItem = $menu.Items.Add((Format-TrayText -Key 'menu.status'))
$script:MenuStatusItem.add_Click({ Invoke-MenuStatus })
$script:MenuRecoverItem = $menu.Items.Add((Format-TrayText -Key 'menu.recover'))
$script:MenuRecoverItem.add_Click({ Invoke-MenuRecover })
$script:MenuSupportItem = $menu.Items.Add((Format-TrayText -Key 'menu.supportBundle'))
$script:MenuSupportItem.add_Click({ Invoke-MenuSupportBundle })
$script:MenuLogsItem = $menu.Items.Add((Format-TrayText -Key 'menu.openLogs'))
$script:MenuLogsItem.add_Click({ Invoke-MenuOpenLogs })
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$exitItem = $menu.Items.Add((Format-TrayText -Key 'menu.exit'))
$exitItem.add_Click({ Invoke-MenuExit })
$script:Notify.ContextMenuStrip = $menu

$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = $PollMs
$script:PollTimer.Add_Tick({ Invoke-PollTick })
$script:PollTimer.Start()

if ($ExitAfterSec -gt 0) {
    $script:ExitTimer = New-Object System.Windows.Forms.Timer
    $script:ExitTimer.Interval = $ExitAfterSec * 1000
    $script:ExitTimer.Add_Tick({ Invoke-MenuExit })
    $script:ExitTimer.Start()
    Write-TrayLog ('Smoke mode: auto exit after ' + $ExitAfterSec + ' s.')
}

Invoke-PollTick

$script:AppContext = New-Object System.Windows.Forms.ApplicationContext
try {
    [System.Windows.Forms.Application]::Run($script:AppContext)
} finally {
    Stop-GsTray
}
exit 0
