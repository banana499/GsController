#Requires -Version 5.1
<#
.SYNOPSIS
    Pause-flag contract tests for product/gs-product.ps1: the supervisor
    pause flag has a canonical location (<StateDir>\runtime\state\
    supervisor_pause.flag, the location the black-box supervisor reads per
    docs/remote-client-test.md) and a legacy location (<StateDir>\
    supervisor_pause.flag, written by older builds).

.DESCRIPTION
    Contract covered:
    - Stop/PrepareUninstall write the pause flag at the CANONICAL location
      only; a pre-existing legacy flag is preserved with its exact bytes
      (never overwritten, never deleted); an existing canonical flag is
      never overwritten; a directory-shaped pause path fails the stop with
      the structured RuntimeStopFailed BEFORE the black-box stop script
      runs; paths are never deleted recursively.
    - An explicit manual Start that succeeds clears BOTH locations (the
      operator's explicit resume of the auto-guard); the flags must still
      exist while the start script runs (no early pause-free window). A
      failed start preserves pre-existing pause flags: flags the start
      script deleted or modified are restored from a byte snapshot taken
      BEFORE the start; a flag the failing start script created itself is
      left alone (it may be the runtime deliberately staying paused). A
      flag that cannot be removed after a successful start fails the
      result (PauseCleanupFailed) instead of reporting success. A pause
      flag that cannot be read (directory shape, locked file) refuses the
      start BEFORE the runtime script runs (PauseSnapshotFailed).
    - Recover snapshots both locations before any side effect and, after
      the stop/start, restores every PRE-EXISTING flag to its original
      bytes (even when the runtime deleted or modified it) and removes
      ONLY the canonical flag its own stop step created; a flag that
      appeared without the product creating it (for example one the
      runtime wrote itself) is left alone. Restore/removal failures
      append Code 'RecoverCleanupFailed' (existing errors stay first, a
      successful result becomes a failure). A snapshot failure refuses
      the recovery before any runtime script runs.

    Everything runs under %TEMP% against fake runtime scripts; every
    gs-product call passes -SupervisorTaskName '' so no scheduled-task
    cmdlet can ever run, -TrafficSampleSec 0 and -StopSettleSec 0. No
    services, scheduled tasks, registry, ACLs, devices or certificates
    are touched; tests/Invoke-All.ps1 is never invoked. Exits 0 only when
    every test passes and at least one ran.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$gsProductPath = Join-Path $repoRoot 'product\gs-product.ps1'
$moduleRoot = Join-Path $repoRoot 'src'

$script:Passed = 0
$script:Failed = 0

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

function Assert-BytesEqual {
    param([byte[]]$Expected, [byte[]]$Actual, [string]$Message)
    $same = ($Expected.Length -eq $Actual.Length)
    if ($same) {
        for ($i = 0; $i -lt $Expected.Length; $i++) {
            if ($Expected[$i] -ne $Actual[$i]) { $same = $false; break }
        }
    }
    if (-not $same) {
        throw ("Assertion failed: {0} (expected {1} bytes '{2}', actual {3} bytes '{4}')" -f `
                $Message, $Expected.Length, [System.Text.Encoding]::UTF8.GetString($Expected), $Actual.Length, [System.Text.Encoding]::UTF8.GetString($Actual))
    }
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$TimeoutSec = 30,
        [string]$Message = 'condition was not met'
    )
    $deadline = [System.DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([System.DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw ("Assertion failed: {0} (waited {1}s)" -f $Message, $TimeoutSec)
}

$tempRoot = [System.IO.Path]::GetTempPath()
$workDir = Join-Path $tempRoot ('GsPauseContract_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null
$workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath
$utf8 = New-Object System.Text.UTF8Encoding($false)

$script:Children = New-Object System.Collections.Generic.List[object]
$script:Servers = New-Object System.Collections.Generic.List[object]

function Start-ChildPowerShell {
    param([Parameter(Mandatory = $true)][string]$Command)
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encoded)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    $script:Children.Add($process)
    return ([pscustomobject]@{
        Process = $process
        OutTask = $process.StandardOutput.ReadToEndAsync()
        ErrTask = $process.StandardError.ReadToEndAsync()
    })
}

function Complete-ChildPowerShell {
    param($Child, [int]$TimeoutSec = 120)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $Child.Process.WaitForExit($TimeoutSec * 1000)) {
            try { $Child.Process.Kill() } catch { }
            if (-not $Child.Process.WaitForExit(10000)) {
                throw ("child powershell did not finish within {0}s (and survived the kill)" -f $TimeoutSec)
            }
            throw ("child powershell did not finish within {0}s" -f $TimeoutSec)
        }
        $remainingMs = ($TimeoutSec * 1000) - $clock.ElapsedMilliseconds
        if ($remainingMs -le 0 -or -not $Child.OutTask.Wait([int][Math]::Min($remainingMs, [int]::MaxValue))) {
            throw ("child powershell stdout did not drain within {0}s" -f $TimeoutSec)
        }
        $remainingMs = ($TimeoutSec * 1000) - $clock.ElapsedMilliseconds
        if ($remainingMs -le 0 -or -not $Child.ErrTask.Wait([int][Math]::Min($remainingMs, [int]::MaxValue))) {
            throw ("child powershell stderr did not drain within {0}s" -f $TimeoutSec)
        }
        $stdout = $Child.OutTask.GetAwaiter().GetResult()
        $stderr = $Child.ErrTask.GetAwaiter().GetResult()
        return ([pscustomobject]@{ ExitCode = $Child.Process.ExitCode; StdOut = $stdout; StdErr = $stderr })
    } finally {
        try { $Child.OutTask.Dispose() } catch { }
        try { $Child.ErrTask.Dispose() } catch { }
        try { $Child.Process.Dispose() } catch { }
    }
}

function Invoke-ChildPowerShell {
    param([Parameter(Mandatory = $true)][string]$Command, [int]$TimeoutSec = 120)
    $child = Start-ChildPowerShell -Command $Command
    return (Complete-ChildPowerShell -Child $child -TimeoutSec $TimeoutSec)
}

# Every gs-product call passes -SupervisorTaskName '' (no scheduled-task
# cmdlet can ever run), -StopSettleSec 0 and -TrafficSampleSec 0 unless a
# test overrides StopSettleSec explicitly (no test does).
function New-GsProductCommand {
    param([string]$Action, $Layout, [hashtable]$Extra = @{})
    $command = ("& '{0}' -Action {1} -InstallDir '{2}' -StateDir '{3}' -LogDir '{4}' -ModuleRoot '{5}'" -f `
            $gsProductPath, $Action, $Layout.InstallDir, $Layout.StateDir, $Layout.LogDir, $moduleRoot)
    if (-not $Extra.ContainsKey('SupervisorTaskName')) { $command += " -SupervisorTaskName ''" }
    if (-not $Extra.ContainsKey('StopSettleSec')) { $command += ' -StopSettleSec 0' }
    if (-not $Extra.ContainsKey('TrafficSampleSec')) { $command += ' -TrafficSampleSec 0' }
    foreach ($key in $Extra.Keys) {
        $value = $Extra[$key]
        if ($value -is [string]) {
            $command += (' -' + $key + " '" + ([string]$value).Replace("'", "''") + "'")
        } elseif ($value -is [bool]) {
            $command += (' -' + $key + ':$' + ([string]$value).ToLowerInvariant())
        } else {
            $command += (' -' + $key + ' ' + [string]$value)
        }
    }
    return $command
}

function Start-GsProductChild {
    param([string]$Action, $Layout, [hashtable]$Extra = @{})
    $command = (New-GsProductCommand -Action $Action -Layout $Layout -Extra $Extra) + ' | ConvertTo-Json -Depth 8'
    return (Start-ChildPowerShell -Command $command)
}

function Complete-GsProductJson {
    param($Child, [int]$TimeoutSec = 120)
    $raw = Complete-ChildPowerShell -Child $Child -TimeoutSec $TimeoutSec
    if ([string]::IsNullOrWhiteSpace($raw.StdOut)) {
        throw ("gs-product produced no output (exit {0}); stderr: {1}" -f $raw.ExitCode, (($raw.StdErr -split "`r?`n" | Select-Object -First 3) -join ' / '))
    }
    return (ConvertFrom-Json -InputObject $raw.StdOut)
}

function Invoke-GsProductJson {
    param([string]$Action, $Layout, [hashtable]$Extra = @{}, [int]$TimeoutSec = 120)
    $child = Start-GsProductChild -Action $Action -Layout $Layout -Extra $Extra
    return (Complete-GsProductJson -Child $child -TimeoutSec $TimeoutSec)
}

function New-TempLayout {
    $root = Join-Path $workDir ([guid]::NewGuid().ToString('N'))
    $layout = [pscustomobject]@{
        Root          = $root
        InstallDir    = (Join-Path $root 'install')
        StateDir      = (Join-Path $root 'state')
        LogDir        = (Join-Path $root 'logs')
        ComponentsDir = (Join-Path $root 'components')
    }
    foreach ($dir in @($layout.InstallDir, $layout.StateDir, $layout.LogDir, $layout.ComponentsDir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $config = [ordered]@{
        schemaVersion      = 1
        installDir         = $layout.InstallDir
        stateDir           = $layout.StateDir
        logDir             = $layout.LogDir
        componentSourceDir = $layout.ComponentsDir
    }
    [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'runtime-config.json'), (ConvertTo-Json -InputObject $config -Depth 4), $utf8)
    return $layout
}

# The two pause-flag locations, spelled out HERE and not read from the code
# under test: the canonical location the black-box supervisor reads
# (runtime\state) and the legacy root location older product builds wrote.
function Get-PausePaths {
    param($Layout)
    [pscustomobject]@{
        Canonical = (Join-Path $Layout.StateDir 'runtime\state\supervisor_pause.flag')
        Legacy    = (Join-Path $Layout.StateDir 'supervisor_pause.flag')
    }
}

function Write-PauseFlag {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

# Returns the source text of one function from product/gs-product.ps1 so a
# test can define it with Invoke-Expression in its own scope (nothing is
# dot-sourced, so the product's param block and module imports never run).
function Get-GsProductFunctionText {
    param([Parameter(Mandatory = $true)][string]$Name)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($gsProductPath, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $ast) {
        $found = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
        if ($null -ne $found) { return $found.Extent.Text }
    }
    throw ("function '{0}' not found in {1}" -f $Name, $gsProductPath)
}

# Fake deployed runtime scripts. Hooks (per action, marker files under the
# state dir):
#   <action>_del_pause  - delete BOTH pause flags first (the black-box start
#                         is known to remove an existing pause flag)
#   <action>_mod_pause  - append 'X2' to BOTH existing pause flags
#   <action>_new_pause  - create the LEGACY pause flag ('blackbox legacy')
#                         if absent (the runtime writing its own pause)
#   <action>_wait_flag  - wait (<=30s) for the CANONICAL flag to exist, write
#                         <action>.waiting, wait (<=60s) for <action>.release
#   <action>_see_pause  - write <action>.saw_pause = whether ANY pause flag
#                         existed when the script began
#   <action>_sleep_ms / <action>_exit / <action>_throw / <action>_noexit
# Every run appends 'action|pid|start|end|exit|threw' to lifecycle-marker.log.
$fakeRuntimeScript = @'
$ErrorActionPreference = 'Stop'
$state = '__STATE__'
$action = '__ACTION__'
$utf8Local = New-Object System.Text.UTF8Encoding($false)
$canonicalFlag = Join-Path $state 'runtime\state\supervisor_pause.flag'
$legacyFlag = Join-Path $state 'supervisor_pause.flag'
[System.IO.File]::WriteAllText((Join-Path $state ($action + '.begun')), [string]$PID, $utf8Local)
if ([System.IO.File]::Exists((Join-Path $state ($action + '_del_pause')))) {
    foreach ($f in @($canonicalFlag, $legacyFlag)) {
        if ([System.IO.File]::Exists($f)) { [System.IO.File]::Delete($f) }
    }
}
if ([System.IO.File]::Exists((Join-Path $state ($action + '_mod_pause')))) {
    foreach ($f in @($canonicalFlag, $legacyFlag)) {
        if ([System.IO.File]::Exists($f)) { [System.IO.File]::AppendAllText($f, 'X2', $utf8Local) }
    }
}
if ([System.IO.File]::Exists((Join-Path $state ($action + '_new_pause')))) {
    if (-not [System.IO.File]::Exists($legacyFlag)) { [System.IO.File]::WriteAllText($legacyFlag, 'blackbox legacy', $utf8Local) }
}
$seeFile = Join-Path $state ($action + '_see_pause')
if ([System.IO.File]::Exists($seeFile)) {
    $saw = ([System.IO.File]::Exists($canonicalFlag) -or [System.IO.File]::Exists($legacyFlag))
    [System.IO.File]::WriteAllText((Join-Path $state ($action + '.saw_pause')), ([string]$saw), $utf8Local)
}
$waitFile = Join-Path $state ($action + '_wait_flag')
if ([System.IO.File]::Exists($waitFile)) {
    $deadline = [System.DateTime]::UtcNow.AddSeconds(30)
    while (-not [System.IO.File]::Exists($canonicalFlag) -and [System.DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    [System.IO.File]::WriteAllText((Join-Path $state ($action + '.waiting')), 'flag checked', $utf8Local)
    $deadline = [System.DateTime]::UtcNow.AddSeconds(60)
    while (-not [System.IO.File]::Exists((Join-Path $state ($action + '.release'))) -and [System.DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
}
$sleepFile = Join-Path $state ($action + '_sleep_ms')
if ([System.IO.File]::Exists($sleepFile)) {
    $ms = [int]([System.IO.File]::ReadAllText($sleepFile).Trim())
    if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
}
$exitCode = 0
$exitFile = Join-Path $state ($action + '_exit')
if ([System.IO.File]::Exists($exitFile)) { $exitCode = [int]([System.IO.File]::ReadAllText($exitFile).Trim()) }
$threw = [System.IO.File]::Exists((Join-Path $state ($action + '_throw')))
$line = '{0}|{1}|{2}|{3}|{4}|{5}' -f $action, $PID, [System.DateTime]::UtcNow.Ticks, [System.DateTime]::UtcNow.Ticks, $exitCode, $threw
[System.IO.File]::AppendAllText((Join-Path $state 'lifecycle-marker.log'), $line + [System.Environment]::NewLine, $utf8Local)
if ($threw) { throw ('synthetic ' + $action + ' failure') }
exit $exitCode
'@

function Write-FakeRuntimeScripts {
    param($Layout)
    $bin = Join-Path $Layout.StateDir 'runtime\bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $bin 'gs_start_with_hook.ps1'), $fakeRuntimeScript.Replace('__STATE__', $Layout.StateDir).Replace('__ACTION__', 'start'), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $bin 'gs_stop_private.ps1'), $fakeRuntimeScript.Replace('__STATE__', $Layout.StateDir).Replace('__ACTION__', 'stop'), $utf8)
}

function Get-MarkerEntries {
    param($Layout)
    $markerPath = Join-Path $Layout.StateDir 'lifecycle-marker.log'
    if (-not [System.IO.File]::Exists($markerPath)) { return @() }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadAllLines($markerPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        $entries.Add([pscustomobject]@{
            Action   = $parts[0]
            ExitCode = [int]$parts[4]
            Threw    = ($parts[5] -eq 'True')
        })
    }
    return $entries.ToArray()
}

# Recover needs the status gate to pass: a ready runtime status file.
function Set-RuntimeStatus {
    param($Layout)
    $dir = Join-Path $Layout.StateDir 'runtime\state'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'status.json'), '{"state":"ready","source":"test"}', $utf8)
}

function New-FakeHttpServer {
    param([string]$Body)
    $response = 'HTTP/1.1 200 Synthetic' + "`r`n" +
        'Content-Type: text/xml' + "`r`n" +
        'Content-Length: ' + ([System.Text.Encoding]::ASCII.GetByteCount($Body)) + "`r`n" +
        'Connection: close' + "`r`n" + "`r`n" + $Body
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddScript({
            param($Listener, $Resp)
            $deadline = [System.DateTime]::UtcNow.AddSeconds(60)
            while ([System.DateTime]::UtcNow -lt $deadline) {
                if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
                $client = $Listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    try { $stream.ReadTimeout = 5000 } catch { }
                    $buffer = New-Object byte[] 4096
                    try { $null = $stream.Read($buffer, 0, $buffer.Length) } catch { }
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Resp)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                } finally { $client.Close() }
            }
        }).AddArgument($listener).AddArgument($response)
    $null = $powershell.BeginInvoke()
    $server = [pscustomobject]@{ Port = $port; Listener = $listener; PowerShell = $powershell; Runspace = $runspace }
    $script:Servers.Add($server)
    return $server
}

function Stop-FakeHttpServer {
    param($Server)
    try { $Server.Listener.Stop() } catch { }
    try { $Server.PowerShell.Stop() } catch { }
    try { $Server.PowerShell.Dispose() } catch { }
    try { $Server.Runspace.Close() } catch { }
    try { $Server.Runspace.Dispose() } catch { }
}

function New-ServerInfoXml {
    param([string]$CurrentGame = '1')
    return ('<root status_code="200"><state>READY_SERVER_BUSY</state><currentgame>' + $CurrentGame + '</currentgame></root>')
}

function Get-UnusedTcpPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
    $listener.Stop()
    return $port
}

# Runs one successful Recover against the given layout (fake scripts must be
# deployed; gates pass via the fake serverinfo server and -TrafficSampleSec 0).
function Invoke-RecoverSuccess {
    param($Layout, [hashtable]$Extra = @{})
    $unusedPort = Get-UnusedTcpPort
    $server = New-FakeHttpServer -Body (New-ServerInfoXml -CurrentGame '1')
    try {
        $merged = @{ ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port); ClientPorts = @($unusedPort) }
        foreach ($key in $Extra.Keys) { $merged[$key] = $Extra[$key] }
        return (Invoke-GsProductJson -Action 'Recover' -Layout $Layout -Extra $merged)
    } finally {
        Stop-FakeHttpServer -Server $server
    }
}

try {
    # ---------------- Stop writes the canonical pause flag ----------------

    Invoke-Test 'Stop writes the canonical pause flag and no legacy root flag' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        $result = Invoke-GsProductJson -Action 'Stop' -Layout $layout
        Assert-True $result.Success 'Stop succeeds'
        Assert-True (Test-Path -LiteralPath $paths.Canonical -PathType Leaf) 'canonical pause flag exists under runtime\state'
        Assert-True (-not (Test-Path -LiteralPath $paths.Legacy)) 'no legacy pause flag at the state root'
        $content = [System.IO.File]::ReadAllText($paths.Canonical)
        Assert-True ($content -like '*reason=manual_stop*') 'canonical flag carries the manual_stop reason'
    }

    Invoke-Test 'Stop preserves a pre-existing legacy pause flag with its exact bytes' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Legacy -Content 'legacy pause bytes'
        $result = Invoke-GsProductJson -Action 'Stop' -Layout $layout
        Assert-True $result.Success 'Stop succeeds'
        Assert-Equal 'legacy pause bytes' ([System.IO.File]::ReadAllText($paths.Legacy)) 'legacy flag content untouched'
        Assert-True (Test-Path -LiteralPath $paths.Canonical -PathType Leaf) 'canonical pause flag also written'
    }

    Invoke-Test 'Stop never overwrites an existing canonical pause flag and writes no legacy flag' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Canonical -Content 'canonical bytes'
        $before = [System.IO.File]::ReadAllBytes($paths.Canonical)
        $result = Invoke-GsProductJson -Action 'Stop' -Layout $layout
        Assert-True $result.Success 'Stop succeeds'
        Assert-BytesEqual $before ([System.IO.File]::ReadAllBytes($paths.Canonical)) 'existing canonical flag bytes untouched'
        Assert-True (-not (Test-Path -LiteralPath $paths.Legacy)) 'no legacy flag was created'
    }

    Invoke-Test 'Stop reports RuntimeStopFailed without running the stop script when the canonical pause parent cannot be created' {
        # runtime\state exists as a FILE: the canonical pause flag's parent
        # cannot be created. The failure must be the structured
        # RuntimeStopFailed, the black-box stop script must never run, and
        # nothing may be deleted.
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $runtimeStateDir = Join-Path $layout.StateDir 'runtime\state'
        if (Test-Path -LiteralPath $runtimeStateDir) { Remove-Item -LiteralPath $runtimeStateDir -Recurse -Force }
        [System.IO.File]::WriteAllText($runtimeStateDir, 'not a directory', $utf8)
        $paths = Get-PausePaths -Layout $layout
        $result = Invoke-GsProductJson -Action 'Stop' -Layout $layout
        Assert-True (-not $result.Success) 'Stop fails'
        Assert-Equal 'RuntimeStopFailed' $result.Errors[0].Code 'pause preparation failure is a structured stop failure'
        Assert-True ($result.Errors[0].Message -like '*Stop failed*') 'message carries the failure'
        Assert-Equal $null $result.Data.ExitCode 'no exit code: the stop script never ran'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        Assert-True (Test-Path -LiteralPath $runtimeStateDir -PathType Leaf) 'the file standing in for the pause parent was not deleted'
        Assert-True (-not (Test-Path -LiteralPath $paths.Canonical)) 'no canonical pause flag was created'
        Assert-True (-not (Test-Path -LiteralPath $paths.Legacy)) 'no legacy pause flag was created'
    }

    Invoke-Test 'Stop reports RuntimeStopFailed without deleting anything when the canonical pause path is a directory' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        New-Item -ItemType Directory -Path $paths.Canonical -Force | Out-Null
        $result = Invoke-GsProductJson -Action 'Stop' -Layout $layout
        Assert-True (-not $result.Success) 'Stop fails'
        Assert-Equal 'RuntimeStopFailed' $result.Errors[0].Code 'directory-shaped pause path is a structured stop failure'
        Assert-True ($result.Errors[0].Message -like '*Stop failed*') 'message carries the failure'
        Assert-Equal $null $result.Data.ExitCode 'no exit code: the stop script never ran'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        Assert-True (Test-Path -LiteralPath $paths.Canonical -PathType Container) 'the directory was not deleted'
    }

    Invoke-Test 'Stop reports RuntimeStopFailed without deleting anything when the legacy pause path is a directory' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        New-Item -ItemType Directory -Path $paths.Legacy -Force | Out-Null
        $result = Invoke-GsProductJson -Action 'Stop' -Layout $layout
        Assert-True (-not $result.Success) 'Stop fails'
        Assert-Equal 'RuntimeStopFailed' $result.Errors[0].Code 'directory-shaped legacy pause path is a structured stop failure'
        Assert-Equal $null $result.Data.ExitCode 'no exit code: the stop script never ran'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        Assert-True (Test-Path -LiteralPath $paths.Legacy -PathType Container) 'the legacy directory was not deleted'
        Assert-True (-not (Test-Path -LiteralPath $paths.Canonical)) 'no canonical pause flag was created'
    }

    # ---------------- Explicit manual Start resumes the auto-guard ----------------

    Invoke-Test 'Start clears canonical and legacy pause flags only after the runtime start succeeded' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_see_pause'), '1', $utf8)
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Canonical -Content 'c'
        Write-PauseFlag -Path $paths.Legacy -Content 'l'
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True $result.Success 'Start succeeds'
        Assert-Equal 'True' ([System.IO.File]::ReadAllText((Join-Path $layout.StateDir 'start.saw_pause'))) 'the pause flags still existed while the start script ran (no early pause-free window)'
        Assert-True (-not (Test-Path -LiteralPath $paths.Canonical)) 'canonical pause flag cleared after the successful start'
        Assert-True (-not (Test-Path -LiteralPath $paths.Legacy)) 'legacy pause flag cleared after the successful start'
    }

    Invoke-Test 'Start preserves runtime output objects emitted before the product result' {
        # The contract fixes only the LAST Success object in the stream as
        # the product result. A runtime that emits its own Success-carrying
        # object mid-stream (before the product result) must have that
        # object preserved, in order, together with the surrounding text
        # output.
        $layout = New-TempLayout
        $paths = Get-PausePaths -Layout $layout
        $bin = Join-Path $layout.StateDir 'runtime\bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $verboseStart = @'
$ErrorActionPreference = 'Stop'
$state = '__STATE__'
$utf8Local = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $state 'start.begun'), [string]$PID, $utf8Local)
Write-Output 'before-hook'
Write-Output ([pscustomobject]@{ Success = $true; Stage = 'hook' })
Write-Output 'after-hook'
exit 0
'@.Replace('__STATE__', $layout.StateDir)
        [System.IO.File]::WriteAllText((Join-Path $bin 'gs_start_with_hook.ps1'), $verboseStart, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $bin 'gs_stop_private.ps1'), "exit 0`r`n", $utf8)
        Write-PauseFlag -Path $paths.Canonical -Content 'c'
        Write-PauseFlag -Path $paths.Legacy -Content 'l'
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        $items = @($result)
        Assert-Equal 4 $items.Count 'text, runtime Success object, text, product result - nothing dropped'
        Assert-Equal 'before-hook' $items[0] 'first text line'
        Assert-True ($items[1] -is [pscustomobject]) 'the runtime Success object survived'
        Assert-Equal 'hook' $items[1].Stage 'the runtime Success object content is intact'
        Assert-Equal 'after-hook' $items[2] 'second text line'
        Assert-True ($items[3].PSObject.Properties['Data'] -ne $null) 'the LAST element is the product result (has Data)'
        Assert-True ($items[3].Success) 'the product result reports success'
        Assert-Equal 0 $items[3].Data.ExitCode 'the product result carries the exit code'
        Assert-True ($items[3].PSObject.Properties['Errors'] -ne $null) 'the product result carries Errors'
        Assert-True (-not (Test-Path -LiteralPath $paths.Canonical)) 'canonical pause flag cleared after the successful start'
        Assert-True (-not (Test-Path -LiteralPath $paths.Legacy)) 'legacy pause flag cleared after the successful start'
    }

    Invoke-Test 'Start keeps pre-existing pause flags with original bytes when the start fails' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_exit'), '3', $utf8)
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Canonical -Content 'c-bytes'
        Write-PauseFlag -Path $paths.Legacy -Content 'l-bytes'
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True (-not $result.Success) 'Start fails'
        Assert-Equal 'RuntimeStartFailed' $result.Errors[0].Code 'start failure is structured'
        Assert-Equal 'c-bytes' ([System.IO.File]::ReadAllText($paths.Canonical)) 'canonical flag kept with original bytes'
        Assert-Equal 'l-bytes' ([System.IO.File]::ReadAllText($paths.Legacy)) 'legacy flag kept with original bytes'
    }

    Invoke-Test 'Start restores a pre-existing pause flag that the start script deleted' {
        # The black-box start is known to delete an existing pause flag. When
        # the start then FAILS, the pre-existing pause state must be restored
        # from the snapshot taken before the start, byte for byte.
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_del_pause'), '1', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_exit'), '3', $utf8)
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Canonical -Content 'original canonical bytes'
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True (-not $result.Success) 'Start fails'
        Assert-Equal 'RuntimeStartFailed' $result.Errors[0].Code 'the start failure stays the first error'
        Assert-Equal 'original canonical bytes' ([System.IO.File]::ReadAllText($paths.Canonical)) 'the deleted pause flag was restored with its original bytes'
    }

    Invoke-Test 'Start restores pause flag bytes that the failing start script modified' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_mod_pause'), '1', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_exit'), '3', $utf8)
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Canonical -Content 'AAA'
        Write-PauseFlag -Path $paths.Legacy -Content 'LLL'
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True (-not $result.Success) 'Start fails'
        Assert-Equal 'AAA' ([System.IO.File]::ReadAllText($paths.Canonical)) 'modified canonical flag restored to original bytes'
        Assert-Equal 'LLL' ([System.IO.File]::ReadAllText($paths.Legacy)) 'modified legacy flag restored to original bytes'
    }

    Invoke-Test 'Start does not delete a pause flag the failing start script created' {
        # A pause flag that appeared at a position that was empty before the
        # start may be the runtime deliberately staying paused: a failed
        # explicit start must NOT remove it.
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_new_pause'), '1', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_exit'), '3', $utf8)
        $paths = Get-PausePaths -Layout $layout
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True (-not $result.Success) 'Start fails'
        Assert-True (Test-Path -LiteralPath $paths.Legacy -PathType Leaf) 'the pause flag created by the failing start script still exists'
        Assert-Equal 'blackbox legacy' ([System.IO.File]::ReadAllText($paths.Legacy)) 'its content is untouched'
    }

    Invoke-Test 'Start reports PauseCleanupFailed when a pause flag cannot be removed after a successful start' {
        # The start script waits until the canonical pause flag exists (it
        # must still exist while the runtime starts), signals the test, and
        # waits for a release file: a deterministic window in which the test
        # holds the flag open (FileShare.None) so the post-start cleanup
        # Remove-Item fails. Deleting a flag that survives must NOT be
        # reported as success.
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_wait_flag'), '1', $utf8)
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Canonical -Content 'held'
        $heldStream = $null
        try {
            $child = Start-GsProductChild -Action 'Start' -Layout $layout
            Wait-Until -Condition { Test-Path -LiteralPath (Join-Path $layout.StateDir 'start.waiting') } -TimeoutSec 30 -Message 'the start script did not reach its waiting marker'
            $heldStream = [System.IO.File]::Open($paths.Canonical, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start.release'), 'go', $utf8)
            $result = Complete-GsProductJson -Child $child -TimeoutSec 90
            Assert-True (-not $result.Success) 'a pause flag that could not be removed fails the result'
            $cleanupErrors = @($result.Errors | Where-Object { $_.Code -eq 'PauseCleanupFailed' })
            Assert-Equal 1 $cleanupErrors.Count 'exactly one PauseCleanupFailed error'
            Assert-Equal $paths.Canonical $cleanupErrors[0].Path 'the error names the canonical pause path'
            Assert-Equal 0 $result.Data.ExitCode 'the runtime start itself still succeeded'
            Assert-True (Test-Path -LiteralPath $paths.Canonical -PathType Leaf) 'the flag still exists (removal failed)'
        } finally {
            if ($null -ne $heldStream) { try { $heldStream.Dispose() } catch { } }
        }
    }

    Invoke-Test 'Start refuses with PauseSnapshotFailed without running the runtime when an existing pause flag path is a directory' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        New-Item -ItemType Directory -Path $paths.Canonical -Force | Out-Null
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True (-not $result.Success) 'Start fails'
        Assert-Equal 'PauseSnapshotFailed' $result.Errors[0].Code 'the unreadable pause flag refuses the start before the runtime runs'
        Assert-Equal $null $result.Data.ExitCode 'no exit code: the start script never ran'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        Assert-True (Test-Path -LiteralPath $paths.Canonical -PathType Container) 'the directory-shaped pause path was not deleted'
    }

    Invoke-Test 'Start refuses with PauseSnapshotFailed without running the runtime when a pause flag is locked' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Legacy -Content 'locked'
        $heldStream = $null
        try {
            $heldStream = [System.IO.File]::Open($paths.Legacy, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
            Assert-True (-not $result.Success) 'Start fails'
            Assert-Equal 'PauseSnapshotFailed' $result.Errors[0].Code 'the locked pause flag refuses the start before the runtime runs'
            Assert-Equal $null $result.Data.ExitCode 'no exit code: the start script never ran'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            if ($null -ne $heldStream) { try { $heldStream.Dispose() } catch { } }
        }
    }

    # ---------------- Recover pause-flag snapshot and restore ----------------

    Invoke-Test 'Recover keeps a pre-existing canonical pause flag and creates no legacy flag' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Canonical -Content 'pre-canonical'
        $result = Invoke-RecoverSuccess -Layout $layout
        Assert-True $result.Success 'Recover succeeds'
        Assert-Equal 'pre-canonical' ([System.IO.File]::ReadAllText($paths.Canonical)) 'pre-existing canonical flag untouched'
        Assert-True (-not (Test-Path -LiteralPath $paths.Legacy)) 'no legacy flag was created or left behind'
    }

    Invoke-Test 'Recover restores pre-existing pause flags that the runtime start deleted' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_del_pause'), '1', $utf8)
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Canonical -Content 'C1'
        Write-PauseFlag -Path $paths.Legacy -Content 'L1'
        $result = Invoke-RecoverSuccess -Layout $layout
        Assert-True $result.Success 'Recover succeeds'
        Assert-Equal 'C1' ([System.IO.File]::ReadAllText($paths.Canonical)) 'deleted pre-existing canonical flag restored with original bytes'
        Assert-Equal 'L1' ([System.IO.File]::ReadAllText($paths.Legacy)) 'deleted pre-existing legacy flag restored with original bytes'
    }

    Invoke-Test 'Recover restores pause flag bytes that the runtime start modified' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_mod_pause'), '1', $utf8)
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Canonical -Content 'C1'
        Write-PauseFlag -Path $paths.Legacy -Content 'L1'
        $result = Invoke-RecoverSuccess -Layout $layout
        Assert-True $result.Success 'Recover succeeds'
        Assert-Equal 'C1' ([System.IO.File]::ReadAllText($paths.Canonical)) 'modified canonical flag restored to original bytes'
        Assert-Equal 'L1' ([System.IO.File]::ReadAllText($paths.Legacy)) 'modified legacy flag restored to original bytes'
    }

    Invoke-Test 'Recover keeps a pause flag the runtime start created and removes only its own canonical flag' {
        # Neither pause flag existed before Recover; the runtime start wrote
        # its own pause at the LEGACY position. Recover must remove only the
        # canonical flag its own stop step created and must treat the
        # runtime-written legacy flag as not its own (left in place).
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_new_pause'), '1', $utf8)
        $paths = Get-PausePaths -Layout $layout
        $result = Invoke-RecoverSuccess -Layout $layout
        Assert-True $result.Success 'Recover succeeds'
        Assert-True (-not (Test-Path -LiteralPath $paths.Canonical)) 'the canonical flag created by the recover stop step was removed'
        Assert-True (Test-Path -LiteralPath $paths.Legacy -PathType Leaf) 'the runtime-written legacy flag was left alone'
        Assert-Equal 'blackbox legacy' ([System.IO.File]::ReadAllText($paths.Legacy)) 'the runtime-written legacy flag content is untouched'
    }

    Invoke-Test 'Recover reports RecoverCleanupFailed when the pause flag it created cannot be removed' {
        # A stop script that waits until the CANONICAL pause flag (created by
        # the recover stop step) exists, signals the test, and then waits for
        # a release file: a deterministic window in which the test can hold
        # the flag open (FileShare.None) so the cleanup removal fails.
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop_wait_flag'), '1', $utf8)
        $paths = Get-PausePaths -Layout $layout
        $heldStream = $null
        try {
            $unusedPort = Get-UnusedTcpPort
            $server = New-FakeHttpServer -Body (New-ServerInfoXml -CurrentGame '1')
            try {
                $recoverChild = Start-GsProductChild -Action 'Recover' -Layout $layout -Extra @{
                    ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                    ClientPorts   = @($unusedPort)
                }
                Wait-Until -Condition { Test-Path -LiteralPath (Join-Path $layout.StateDir 'stop.waiting') } -TimeoutSec 45 -Message 'the stop script did not reach its waiting marker'
                Assert-True (Test-Path -LiteralPath $paths.Canonical -PathType Leaf) 'the canonical pause flag exists while the stop script waits'
                $heldStream = [System.IO.File]::Open($paths.Canonical, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop.release'), 'go', $utf8)
                $result = Complete-GsProductJson -Child $recoverChild -TimeoutSec 90
                Assert-True (-not $result.Success) 'Recover reports failure when its own flag cannot be removed'
                $cleanupErrors = @($result.Errors | Where-Object { $_.Code -eq 'RecoverCleanupFailed' })
                Assert-Equal 1 $cleanupErrors.Count 'exactly one RecoverCleanupFailed error'
                Assert-Equal $paths.Canonical $cleanupErrors[0].Path 'the error names the canonical pause path'
                Assert-Equal 0 $result.Data.StopExitCode 'the stop step itself still succeeded'
                Assert-Equal 0 $result.Data.StartExitCode 'the start step itself still succeeded'
            } finally {
                Stop-FakeHttpServer -Server $server
            }
        } finally {
            if ($null -ne $heldStream) { try { $heldStream.Dispose() } catch { } }
        }
    }

    Invoke-Test 'Recover refuses with PauseSnapshotFailed without running any runtime script when a pause flag path is a directory' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        New-Item -ItemType Directory -Path $paths.Canonical -Force | Out-Null
        $result = Invoke-RecoverSuccess -Layout $layout
        Assert-True (-not $result.Success) 'Recover fails'
        $refusals = @($result.Errors | Where-Object { $_.Code -eq 'RecoverRefused' })
        Assert-Equal 1 $refusals.Count 'exactly one RecoverRefused error'
        Assert-Equal 'PauseSnapshotFailed' $refusals[0].Reason 'the refusal reason is PauseSnapshotFailed'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        Assert-True (Test-Path -LiteralPath $paths.Canonical -PathType Container) 'the directory-shaped pause path was not deleted'
    }

    Invoke-Test 'Recover refuses with PauseSnapshotFailed without running any runtime script when a pause flag is locked' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Legacy -Content 'locked'
        $heldStream = $null
        $contentIntact = $false
        try {
            $heldStream = [System.IO.File]::Open($paths.Legacy, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $result = Invoke-RecoverSuccess -Layout $layout
            Assert-True (-not $result.Success) 'Recover fails'
            $refusals = @($result.Errors | Where-Object { $_.Code -eq 'RecoverRefused' })
            Assert-Equal 1 $refusals.Count 'exactly one RecoverRefused error'
            Assert-Equal 'PauseSnapshotFailed' $refusals[0].Reason 'the refusal reason is PauseSnapshotFailed'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
            $contentIntact = $true
        } finally {
            if ($null -ne $heldStream) { try { $heldStream.Dispose() } catch { } }
        }
        # After the test's own exclusive handle is released the flag content
        # must still be the original bytes.
        Assert-True $contentIntact 'the pre-content assertions ran'
        Assert-Equal 'locked' ([System.IO.File]::ReadAllText($paths.Legacy)) 'the locked flag content is untouched'
    }

    Invoke-Test 'Recover keeps a legacy pause flag that the stop script created (successful recover)' {
        # The stop core NEVER creates a legacy pause flag, so a legacy flag
        # that appears during the stop was written by the black box (or by
        # the supervisor, which does not take the product mutex): Recover
        # must not claim it, and it must survive the cleanup.
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop_new_pause'), '1', $utf8)
        $paths = Get-PausePaths -Layout $layout
        $result = Invoke-RecoverSuccess -Layout $layout
        Assert-True $result.Success 'Recover succeeds'
        Assert-True (-not (Test-Path -LiteralPath $paths.Canonical)) 'the canonical flag created by the stop core was removed'
        Assert-True (Test-Path -LiteralPath $paths.Legacy -PathType Leaf) 'the legacy flag the stop script wrote is not claimed and stays'
        Assert-Equal 'blackbox legacy' ([System.IO.File]::ReadAllText($paths.Legacy)) 'the stop-script-written legacy flag content is untouched'
    }

    Invoke-Test 'Recover keeps a legacy pause flag that the stop script created (failed start)' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop_new_pause'), '1', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_exit'), '3', $utf8)
        $paths = Get-PausePaths -Layout $layout
        $result = Invoke-RecoverSuccess -Layout $layout
        Assert-True (-not $result.Success) 'Recover fails at the start step'
        Assert-Equal 1 @($result.Errors | Where-Object { $_.Code -eq 'RecoverStartFailed' }).Count 'exactly one RecoverStartFailed error'
        Assert-True (Test-Path -LiteralPath $paths.Legacy -PathType Leaf) 'the stop-script-written legacy flag survives the failed recover'
        Assert-Equal 'blackbox legacy' ([System.IO.File]::ReadAllText($paths.Legacy)) 'the stop-script-written legacy flag content is untouched'
        Assert-True (-not (Test-Path -LiteralPath $paths.Canonical)) 'the canonical flag the stop core created is still cleaned up'
        Assert-Equal 0 @($result.Errors | Where-Object { $_.Code -eq 'RecoverCleanupFailed' }).Count 'no cleanup failure was reported'
    }

    Invoke-Test 'Recover claims nothing when the stop script is missing (no pause flag was created)' {
        # The stop core checks the script BEFORE writing any pause flag, so a
        # missing stop script means the stop core created nothing - and the
        # cleanup must have nothing to claim (no flags, no cleanup error).
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout
        Remove-Item -LiteralPath (Join-Path $layout.StateDir 'runtime\bin\gs_stop_private.ps1') -Force
        $paths = Get-PausePaths -Layout $layout
        $result = Invoke-RecoverSuccess -Layout $layout
        Assert-True (-not $result.Success) 'Recover fails'
        Assert-Equal 'RecoverStopFailed' $result.Errors[0].Code 'the stop step failure is the first error'
        Assert-Equal $null $result.Data.StopExitCode 'the stop script never produced an exit code'
        Assert-True (-not (Test-Path -LiteralPath $paths.Canonical)) 'no canonical pause flag exists (the stop core never wrote one)'
        Assert-True (-not (Test-Path -LiteralPath $paths.Legacy)) 'no legacy pause flag exists'
        Assert-Equal 0 @($result.Errors | Where-Object { $_.Code -eq 'RecoverCleanupFailed' }).Count 'nothing was claimed, so no cleanup failure'
    }

    Invoke-Test 'Stop creates the canonical pause flag atomically and records ownership only on actual creation (AST source check)' {
        # The supervisor does NOT take the product mutex, so the canonical
        # flag can appear between the pre-check and the write: the creation
        # must be the atomic FileMode.CreateNew (an existing flag is
        # preserved, never overwritten), and the ownership record must sit
        # AFTER a successful create only - inside the guarded try, before
        # the preserve-race catch.
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($gsProductPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'gs-product.ps1 parses'
        $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GsRuntimeStopCore' }, $true)
        Assert-True ($null -ne $fn) 'Invoke-GsRuntimeStopCore exists'
        $text = $fn.Extent.Text
        Assert-True ($text.Contains('[IO.FileMode]::CreateNew')) 'the canonical pause flag is created with the atomic CreateNew mode'
        Assert-True ($text -notmatch 'WriteAllText\(\$pause') 'no overwrite-style write to the canonical pause path'
        Assert-True ($text -notmatch 'WriteAllBytes\(\$pause') 'no overwrite-style byte write to the canonical pause path'
        $recordMatches = @([regex]::Matches($text, '(?m)^\s*\$PauseOperationContext\.CanonicalCreatedByThisStopCore = \$true'))
        Assert-Equal 1 $recordMatches.Count 'the ownership record appears exactly once'
        $createPos = $text.IndexOf('[IO.FileMode]::CreateNew')
        $recordPos = $recordMatches[0].Index
        Assert-True ($recordPos -gt $createPos) 'the ownership record sits after the atomic create'
        Assert-True ($recordPos -lt $text.IndexOf('$pauseStream.Write')) 'the ownership record is written BEFORE the stream write (a write/flush failure must not lose it)'
        # The open failure catch classifies ONLY the "already exists" Win32
        # errors (80/183) plus a regular-file re-check as the lost race, and
        # contains NO ownership record (the record lives after the catch, at
        # the open-success point).
        $betweenCreateAndRecord = $text.Substring($createPos, $recordPos - $createPos)
        Assert-True ($betweenCreateAndRecord.Contains('catch')) 'the open is guarded by its own catch'
        Assert-True ($betweenCreateAndRecord.Contains('-2147024816')) 'the catch classifies Win32 80 (ERROR_FILE_EXISTS)'
        Assert-True ($betweenCreateAndRecord.Contains('-2147024713')) 'the catch classifies Win32 183 (ERROR_ALREADY_EXISTS)'
        Assert-True ($betweenCreateAndRecord.Contains('PathType Leaf')) 'the lost-race branch re-checks the flag is a regular file before preserving it'
        Assert-True ($betweenCreateAndRecord -notmatch 'CanonicalCreatedByThisStopCore') 'the open-failure catch records no ownership'
        Assert-True ($betweenCreateAndRecord -notmatch 'WriteAllText|WriteAllBytes') 'no overwrite-style write to the canonical pause path'
    }

    Invoke-Test 'Pause-flag helpers never throw past their structured result (injected provider failure)' {
        # With $ErrorActionPreference = 'Stop' even a metadata probe
        # (Test-Path) can produce a terminating error; the helpers must turn
        # ANY failure - including one from their own metadata checks - into
        # the structured outcome, never an exception past their boundary.
        Invoke-Expression (Get-GsProductFunctionText -Name 'Test-GsPauseBytesEqual')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Restore-GsPauseFlagEntry')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Remove-GsPauseFlagFile')
        function Test-Path { throw 'synthetic provider failure' }
        $thrown = $null
        $removed = $null
        try { $removed = Remove-GsPauseFlagFile -Path (Join-Path $workDir 'whatever.flag') } catch { $thrown = $_ }
        Assert-True ($null -eq $thrown) 'Remove-GsPauseFlagFile does not throw past its result'
        Assert-Equal 'Failed' $removed.Outcome 'a metadata failure becomes a structured Failed outcome'
        $entry = [pscustomobject]@{ Path = (Join-Path $workDir 'whatever.flag'); Exists = $true; Bytes = [System.Text.Encoding]::UTF8.GetBytes('x'); CreatedByThisOperation = $false }
        $thrown = $null
        $restored = $null
        try { $restored = Restore-GsPauseFlagEntry -Entry $entry } catch { $thrown = $_ }
        Assert-True ($null -eq $thrown) 'Restore-GsPauseFlagEntry does not throw past its result'
        Assert-Equal 'Failed' $restored.Outcome 'a metadata failure becomes a structured Failed outcome'
    }

    # ---------------- Injected-open behavior of the stop core ----------------
    # Harness: extracts the stop core via AST, swaps [IO.File]::Open for an
    # injectable probe (everything defined at script scope), and deploys the
    # fake runtime scripts so a marker proves whether the black box ran. No
    # production switch is added; nothing touches real permissions.

    function New-TestStopCoreHarness {
        Invoke-Expression ('function script:' + (Get-GsProductFunctionText -Name 'New-Result').Substring(9))
        Invoke-Expression ('function script:' + (Get-GsProductFunctionText -Name 'Get-GsUnwrappedException').Substring(9))
        $core = (Get-GsProductFunctionText -Name 'Invoke-GsRuntimeStopCore').Replace('[IO.File]::Open($pause, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)', 'Invoke-TestPauseFileOpen -Path $pause -Mode ([IO.FileMode]::CreateNew) -Access ([IO.FileAccess]::Write) -Share ([IO.FileShare]::Read)')
        Invoke-Expression ('function script:' + $core.Substring(9))
        Invoke-Expression (@'
function script:New-FakePauseStream {
    param([string]$FailOn)
    $stream = New-Object pscustomobject
    $stream | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param([byte[]]$Buffer, [int]$Offset, [int]$Count)
        if ($script:TestPauseStreamFailOn -eq 'Write') { throw (New-Object System.IO.IOException('synthetic stream write failure')) }
    }
    $stream | Add-Member -MemberType ScriptMethod -Name Flush -Value {
        if ($script:TestPauseStreamFailOn -eq 'Flush') { throw (New-Object System.IO.IOException('synthetic stream flush failure')) }
    }
    $stream | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    return $stream
}
'@)
        Invoke-Expression (@'
function script:Invoke-TestPauseFileOpen {
    param($Path, $Mode, $Access, $Share)
    switch ($script:TestPauseOpenBehavior) {
        'WriteFails' {
            # A successful real open CREATES the empty file; only the
            # in-memory stream write then fails.
            $null = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read).Dispose()
            return (New-FakePauseStream -FailOn 'Write')
        }
        'FlushFails' {
            $null = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read).Dispose()
            return (New-FakePauseStream -FailOn 'Flush')
        }
        'PlainIOError' { throw (New-Object System.IO.IOException('synthetic plain open failure')) }
        'RaceCreateThenExistsError' {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
            [System.IO.File]::WriteAllText($Path, 'race-winner', (New-Object System.Text.UTF8Encoding($false)))
            throw (New-Object System.IO.IOException('synthetic already exists', -2147024816))
        }
        'SwapDirThenExistsError' {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            throw (New-Object System.IO.IOException('synthetic already exists', -2147024816))
        }
        default { throw ('unknown TestPauseOpenBehavior: ' + $script:TestPauseOpenBehavior) }
    }
}
'@)
    }

    function New-TestStopCoreLayout {
        # A synthetic layout shaped for the EXTRACTED stop core (it reads
        # StateDir, RuntimeBinDir, PauseFlagPath, LegacyPauseFlagPath) with
        # the standard fake runtime scripts deployed.
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        $testLayout = [pscustomobject]@{
            StateDir            = $layout.StateDir
            RuntimeBinDir       = (Join-Path $layout.StateDir 'runtime\bin')
            PauseFlagPath       = $paths.Canonical
            LegacyPauseFlagPath = $paths.Legacy
        }
        return [pscustomobject]@{ Layout = $layout; TestLayout = $testLayout; Paths = $paths }
    }

    Invoke-Test 'Injected stream WRITE failure: structured stop failure, black box not run, flag owned by this operation' {
        New-TestStopCoreHarness
        $script:TestPauseOpenBehavior = 'WriteFails'
        $script:TestPauseStreamFailOn = 'Write'
        $harness = New-TestStopCoreLayout
        $ctx = @{}
        $result = Invoke-GsRuntimeStopCore -Layout $harness.TestLayout -StopSettleSec 0 -SupervisorTaskName '' -LockAbandoned $false -PauseOperationContext $ctx
        Assert-True (-not $result.Success) 'the write failure is a structured stop failure'
        Assert-Equal 'RuntimeStopFailed' $result.Errors[0].Code 'error code'
        Assert-Equal $null $result.Data.ExitCode 'the stop script never ran'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $harness.Layout).Count 'no runtime script ran'
        Assert-True $ctx.ContainsKey('CanonicalCreatedByThisStopCore') 'the flag created by the successful open is recorded as owned BEFORE the write'
        Assert-True (Test-Path -LiteralPath $harness.Paths.Canonical -PathType Leaf) 'the owned flag still exists for a later cleanup'
    }

    Invoke-Test 'Injected stream FLUSH failure: structured stop failure, black box not run, flag owned by this operation' {
        New-TestStopCoreHarness
        $script:TestPauseOpenBehavior = 'FlushFails'
        $script:TestPauseStreamFailOn = 'Flush'
        $harness = New-TestStopCoreLayout
        $ctx = @{}
        $result = Invoke-GsRuntimeStopCore -Layout $harness.TestLayout -StopSettleSec 0 -SupervisorTaskName '' -LockAbandoned $false -PauseOperationContext $ctx
        Assert-True (-not $result.Success) 'the flush failure is a structured stop failure'
        Assert-Equal 'RuntimeStopFailed' $result.Errors[0].Code 'error code'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $harness.Layout).Count 'no runtime script ran'
        Assert-True $ctx.ContainsKey('CanonicalCreatedByThisStopCore') 'the flag created by the successful open is recorded as owned before the flush'
    }

    Invoke-Test 'Injected plain open IOException (not already-exists): structured failure, black box not run, nothing owned' {
        New-TestStopCoreHarness
        $script:TestPauseOpenBehavior = 'PlainIOError'
        $harness = New-TestStopCoreLayout
        $ctx = @{}
        $result = Invoke-GsRuntimeStopCore -Layout $harness.TestLayout -StopSettleSec 0 -SupervisorTaskName '' -LockAbandoned $false -PauseOperationContext $ctx
        Assert-True (-not $result.Success) 'a non-already-exists open failure is a structured stop failure'
        Assert-Equal 'RuntimeStopFailed' $result.Errors[0].Code 'error code'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $harness.Layout).Count 'no runtime script ran'
        Assert-True (-not $ctx.ContainsKey('CanonicalCreatedByThisStopCore')) 'nothing was created, so nothing is owned'
        Assert-True (-not (Test-Path -LiteralPath $harness.Paths.Canonical)) 'no canonical pause flag was created'
    }

    Invoke-Test 'Lost creation race (open says already-exists, file present): flag preserved, not owned, black box runs' {
        New-TestStopCoreHarness
        $script:TestPauseOpenBehavior = 'RaceCreateThenExistsError'
        $harness = New-TestStopCoreLayout
        $ctx = @{}
        $result = Invoke-GsRuntimeStopCore -Layout $harness.TestLayout -StopSettleSec 0 -SupervisorTaskName '' -LockAbandoned $false -PauseOperationContext $ctx
        Assert-True $result.Success 'the lost race preserves the existing flag and the stop proceeds'
        Assert-Equal 1 @(Get-MarkerEntries -Layout $harness.Layout).Count 'the stop script ran exactly once'
        Assert-True (-not $ctx.ContainsKey('CanonicalCreatedByThisStopCore')) 'the racing flag is NOT owned by this operation'
        Assert-Equal 'race-winner' ([System.IO.File]::ReadAllText($harness.Paths.Canonical)) 'the racing flag bytes are preserved'
    }

    Invoke-Test 'Race path swapped to a directory: NOT treated as a preserved pause, structured failure, black box not run' {
        New-TestStopCoreHarness
        $script:TestPauseOpenBehavior = 'SwapDirThenExistsError'
        $harness = New-TestStopCoreLayout
        $ctx = @{}
        $result = Invoke-GsRuntimeStopCore -Layout $harness.TestLayout -StopSettleSec 0 -SupervisorTaskName '' -LockAbandoned $false -PauseOperationContext $ctx
        Assert-True (-not $result.Success) 'the already-exists error with a directory-shaped path is a structured stop failure'
        Assert-Equal 'RuntimeStopFailed' $result.Errors[0].Code 'error code'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $harness.Layout).Count 'no runtime script ran'
        Assert-True (-not $ctx.ContainsKey('CanonicalCreatedByThisStopCore')) 'nothing is owned'
        Assert-True (Test-Path -LiteralPath $harness.Paths.Canonical -PathType Container) 'the directory was not deleted'
    }

    # ---------------- PrepareUninstall uses the same stop core ----------------

    Invoke-Test 'PrepareUninstall writes the canonical pause flag and keeps a pre-existing legacy one' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        Write-PauseFlag -Path $paths.Legacy -Content 'legacy kept'
        $result = Invoke-GsProductJson -Action 'PrepareUninstall' -Layout $layout
        Assert-True $result.Success 'PrepareUninstall succeeds'
        Assert-True $result.Data.Stopped 'Stopped is true'
        Assert-True (Test-Path -LiteralPath $paths.Canonical -PathType Leaf) 'the canonical pause flag was written'
        Assert-Equal 'legacy kept' ([System.IO.File]::ReadAllText($paths.Legacy)) 'the pre-existing legacy flag is kept with its bytes'
        $entries = @(Get-MarkerEntries -Layout $layout)
        Assert-Equal 1 @($entries | Where-Object { $_.Action -eq 'stop' }).Count 'exactly one stop ran'
        Assert-Equal 0 @($entries | Where-Object { $_.Action -eq 'start' }).Count 'no start ran'
    }

    Invoke-Test 'Start after Stop removes the pause flag Stop wrote (stop-start round trip)' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $paths = Get-PausePaths -Layout $layout
        $stop = Invoke-GsProductJson -Action 'Stop' -Layout $layout
        Assert-True $stop.Success 'Stop succeeds'
        Assert-True (Test-Path -LiteralPath $paths.Canonical -PathType Leaf) 'Stop wrote the canonical pause flag'
        $start = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True $start.Success 'Start succeeds'
        Assert-True (-not (Test-Path -LiteralPath $paths.Canonical)) 'Start cleared the canonical pause flag'
        Assert-True (-not (Test-Path -LiteralPath $paths.Legacy)) 'no legacy pause flag exists after the round trip'
    }
} finally {
    foreach ($server in $script:Servers) {
        try { Stop-FakeHttpServer -Server $server } catch { }
    }
    foreach ($process in $script:Children) {
        try {
            if (-not $process.HasExited) { $process.Kill() }
        } catch { }
    }
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
