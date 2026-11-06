#Requires -Version 5.1
<#
.SYNOPSIS
    Lifecycle hardening tests for product/gs-product.ps1: the cross-process
    Start/Stop/Recover mutex (including its DACL), -Action Recover safety
    gates and cleanup, -Action Diagnose, the runtime status path lookup,
    bounded serverinfo reads, and the tests/Invoke-All.ps1 runner.

.DESCRIPTION
    Runs gs-product.ps1 in child powershell.exe processes against synthetic
    layouts under %TEMP% (fake runtime scripts, fake loopback HTTP servers,
    real loopback TCP connections). Touches no services, scheduled tasks,
    registry or real product processes; every gs-product call passes
    -SupervisorTaskName '' so no scheduled-task cmdlet can run. Each
    Invoke-All.ps1 runner test runs the real runner in a child powershell.exe
    with a hard outer timeout so a runner regression fails instead of
    hanging the suite. Exits 0 only when every test passes and at least one
    ran; SKIP lines count neither as passed nor failed.
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

# Waits (with a deadline, no fixed sleep) until $Condition returns $true.
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

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$elevated = Test-IsElevated

$tempRoot = [System.IO.Path]::GetTempPath()
$workDir = Join-Path $tempRoot ('GsLifecycleHardening_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null
$workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath
$utf8 = New-Object System.Text.UTF8Encoding($false)

# Every child process started by this suite, killed again in finally.
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
    # The deadline covers the process exit AND the drain of both pipes: a
    # child that exits after spawning a descendant that inherited its
    # stdout/stderr handles would otherwise block the unbounded GetResult
    # forever after a successful WaitForExit. Both stream tasks are bounded
    # by the REMAINING deadline (measured from the call start) and, when the
    # bound expires, the process and the streams are DISPOSED so no pipe
    # handle is left open, then the bounded failure is thrown.
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
            throw ("child powershell stdout did not drain within {0}s (an inherited-handle descendant may still hold the pipe)" -f $TimeoutSec)
        }
        $remainingMs = ($TimeoutSec * 1000) - $clock.ElapsedMilliseconds
        if ($remainingMs -le 0 -or -not $Child.ErrTask.Wait([int][Math]::Min($remainingMs, [int]::MaxValue))) {
            throw ("child powershell stderr did not drain within {0}s (an inherited-handle descendant may still hold the pipe)" -f $TimeoutSec)
        }
        $stdout = $Child.OutTask.GetAwaiter().GetResult()
        $stderr = $Child.ErrTask.GetAwaiter().GetResult()
        return ([pscustomobject]@{ ExitCode = $Child.Process.ExitCode; StdOut = $stdout; StdErr = $stderr })
    } finally {
        # No pipe handle survives this call: dispose the streams (closing our
        # ends even when a descendant still holds duplicated handles) and the
        # Process object.
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

# Builds the gs-product.ps1 invocation used by every test. -SupervisorTaskName ''
# guarantees no scheduled-task cmdlet ever runs; -StopSettleSec 0 keeps tests fast.
# Extra entries with the same key OVERRIDE the default (only the
# ElevationRequired test overrides SupervisorTaskName, with a unique name that
# cannot exist plus the -AssumeNotElevated seam that refuses before any cmdlet).
function New-GsProductCommand {
    param([string]$Action, $Layout, [hashtable]$Extra = @{})
    $command = ("& '{0}' -Action {1} -InstallDir '{2}' -StateDir '{3}' -LogDir '{4}' -ModuleRoot '{5}'" -f `
            $gsProductPath, $Action, $Layout.InstallDir, $Layout.StateDir, $Layout.LogDir, $moduleRoot)
    if (-not $Extra.ContainsKey('SupervisorTaskName')) { $command += " -SupervisorTaskName ''" }
    if (-not $Extra.ContainsKey('StopSettleSec')) { $command += ' -StopSettleSec 0' }
    # The outbound-traffic gate samples REAL adapters; deterministic tests
    # always disable it (0) unless a test asks for the gate explicitly.
    if (-not $Extra.ContainsKey('TrafficSampleSec')) { $command += ' -TrafficSampleSec 0' }
    foreach ($key in $Extra.Keys) {
        $value = $Extra[$key]
        if ($value -is [string]) {
            $command += (' -' + $key + " '" + ([string]$value).Replace("'", "''") + "'")
        } elseif ($value -is [System.Array]) {
            $command += (' -' + $key + ' @(' + ((@($value | ForEach-Object { [string]$_ })) -join ',') + ')')
        } elseif ($value -is [bool]) {
            # Switch parameters must render as -Name:$true / -Name:$false.
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

# Creates a synthetic install/state/log/component layout plus the
# runtime-config.json that gs-product.ps1 reads to resolve the layout.
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

# Fake deployed runtime scripts: append one line
# "action|pid|startTicks|endTicks|exitCode|threw" to lifecycle-marker.log,
# optionally sleep (read from <action>_sleep_ms), optionally write output
# lines (<action>_output, mimicking the black-box runtime scripts' 'RESULT
# OK'-style stream output), optionally exit <n> (<action>_exit), throw
# (<action>_throw) or end without exit (<action>_noexit).
# Each writes an <action>.begun marker file before doing anything.
$fakeRuntimeScript = @'
$ErrorActionPreference = 'Stop'
$state = '__STATE__'
$action = '__ACTION__'
$marker = Join-Path $state 'lifecycle-marker.log'
$startedAt = [System.DateTime]::UtcNow
[System.IO.File]::WriteAllText((Join-Path $state ($action + '.begun')), [string]$PID, (New-Object System.Text.UTF8Encoding($false)))
$sleepFile = Join-Path $state ($action + '_sleep_ms')
if ([System.IO.File]::Exists($sleepFile)) {
    $ms = [int]([System.IO.File]::ReadAllText($sleepFile).Trim())
    if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
}
$outputFile = Join-Path $state ($action + '_output')
if ([System.IO.File]::Exists($outputFile)) {
    foreach ($outLine in [System.IO.File]::ReadAllLines($outputFile)) {
        if ([string]::IsNullOrWhiteSpace($outLine)) { continue }
        Write-Output $outLine
    }
}
$exitCode = 0
$exitFile = Join-Path $state ($action + '_exit')
if ([System.IO.File]::Exists($exitFile)) { $exitCode = [int]([System.IO.File]::ReadAllText($exitFile).Trim()) }
$throwFile = Join-Path $state ($action + '_throw')
$threw = [System.IO.File]::Exists($throwFile)
$line = '{0}|{1}|{2}|{3}|{4}|{5}' -f $action, $PID, $startedAt.Ticks, [System.DateTime]::UtcNow.Ticks, $exitCode, $threw
[System.IO.File]::AppendAllText($marker, $line + [System.Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
if ($threw) { throw ('synthetic ' + $action + ' failure') }
$noExitFile = Join-Path $state ($action + '_noexit')
if ([System.IO.File]::Exists($noExitFile)) { return }
exit $exitCode
'@

function Write-FakeRuntimeScripts {
    param($Layout)
    $bin = Join-Path $Layout.StateDir 'runtime\bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $bin 'gs_start_with_hook.ps1'), $fakeRuntimeScript.Replace('__STATE__', $Layout.StateDir).Replace('__ACTION__', 'start'), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $bin 'gs_stop_private.ps1'), $fakeRuntimeScript.Replace('__STATE__', $Layout.StateDir).Replace('__ACTION__', 'stop'), $utf8)
}

function Set-RuntimeStatus {
    param($Layout, [string]$State = 'ready', [string]$Source = 'test')
    Write-StatusFile -Layout $Layout -Which 'RuntimeState' -Source $Source -State $State
}

function Write-StatusFile {
    param($Layout, [ValidateSet('RuntimeState', 'StateDir')][string]$Which, [string]$Source, [string]$State = 'ready')
    if ($Which -eq 'RuntimeState') {
        $dir = Join-Path $Layout.StateDir 'runtime\state'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'status.json'
    } else {
        $path = Join-Path $Layout.StateDir 'status.json'
    }
    $json = '{"state":"' + $State + '","source":"' + $Source + '"}'
    [System.IO.File]::WriteAllText($path, $json, $utf8)
}

# Parses lifecycle-marker.log entries produced by the fake runtime scripts.
function Get-MarkerEntries {
    param($Layout)
    $markerPath = Join-Path $Layout.StateDir 'lifecycle-marker.log'
    if (-not [System.IO.File]::Exists($markerPath)) { return @() }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadAllLines($markerPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        $entries.Add([pscustomobject]@{
            Action     = $parts[0]
            Pid        = [int]$parts[1]
            StartTicks = [long]$parts[2]
            EndTicks   = [long]$parts[3]
            ExitCode   = [int]$parts[4]
            Threw      = ($parts[5] -eq 'True')
        })
    }
    return $entries.ToArray()
}

# Independent copy of the product's lock name derivation (keep in sync with
# Get-GsLifecycleLockName in product/gs-product.ps1).
function Get-LockName {
    param([Parameter(Mandatory = $true)][string]$StateDirPath)
    $normalized = [System.IO.Path]::GetFullPath($StateDirPath).Replace('/', '\').TrimEnd('\').ToUpperInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))
    } finally {
        $sha.Dispose()
    }
    $hex = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    return ('Global\GsController.Lifecycle.' + $hex.Substring(0, 16))
}

# Returns the source text of one function from product/gs-product.ps1 so a
# test can define it with Invoke-Expression in its own scope (nothing is
# dot-sourced, so the product's param block and module imports never run).
function Get-GsProductFunctionText {
    param([Parameter(Mandatory = $true)][string]$Name)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($gsProductPath, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast) { throw ("could not parse {0}" -f $gsProductPath) }
    $found = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if ($null -eq $found) { throw ("function '{0}' not found in {1}" -f $Name, $gsProductPath) }
    return $found.Extent.Text
}

# A child process that acquires the same lifecycle mutex as gs-product would,
# signals readiness, then waits for a release or abandon signal.
$lockHolderScript = @'
$ErrorActionPreference = 'Stop'
$name = '__NAME__'
$readyFile = '__READY__'
$releaseFile = '__RELEASE__'
$abandonFile = '__ABANDON__'
$mutex = New-Object System.Threading.Mutex($false, $name)
[void]$mutex.WaitOne()
[System.IO.File]::WriteAllText($readyFile, 'ready', (New-Object System.Text.UTF8Encoding($false)))
$deadline = [System.DateTime]::UtcNow.AddSeconds(90)
while (-not [System.IO.File]::Exists($releaseFile) -and -not [System.IO.File]::Exists($abandonFile)) {
    if ([System.DateTime]::UtcNow -gt $deadline) { break }
    Start-Sleep -Milliseconds 50
}
if ([System.IO.File]::Exists($abandonFile)) {
    # Exit while still owning the mutex, after a delay so that a concurrent
    # gs-product call can open the named mutex first and block on it; that
    # blocked wait then fails with AbandonedMutexException. (If the last
    # handle closed with nobody holding the object open, the kernel object
    # would simply be destroyed and the next caller would get a fresh one.)
    Start-Sleep -Seconds 5
    exit 2
}
try { $mutex.ReleaseMutex() } catch { }
exit 0
'@

function New-LockHolder {
    param($Layout, [string]$Tag)
    $stamp = [guid]::NewGuid().ToString('N')
    $holder = [pscustomobject]@{
        Ready   = (Join-Path $workDir ('holder-' + $Tag + '-' + $stamp + '.ready'))
        Release = (Join-Path $workDir ('holder-' + $Tag + '-' + $stamp + '.release'))
        Abandon = (Join-Path $workDir ('holder-' + $Tag + '-' + $stamp + '.abandon'))
    }
    $command = $lockHolderScript.Replace('__NAME__', (Get-LockName -StateDirPath $Layout.StateDir)).Replace('__READY__', $holder.Ready).Replace('__RELEASE__', $holder.Release).Replace('__ABANDON__', $holder.Abandon)
    $holder | Add-Member -NotePropertyName Child -NotePropertyValue (Start-ChildPowerShell -Command $command)
    return $holder
}

function Wait-LockHolderReady {
    param($Holder)
    Wait-Until -Condition { [System.IO.File]::Exists($Holder.Ready) } -TimeoutSec 30 -Message 'lock holder did not signal readiness'
}

function Complete-LockHolder {
    param($Holder, [int]$TimeoutSec = 60)
    return (Complete-ChildPowerShell -Child $Holder.Child -TimeoutSec $TimeoutSec)
}

function Release-LockHolder {
    param($Holder)
    [System.IO.File]::WriteAllText($Holder.Release, 'go', $utf8)
    return (Complete-LockHolder -Holder $Holder)
}

# Fake serverinfo: a TcpListener on 127.0.0.1:0 serving one canned HTTP
# response per incoming connection (no HttpListener / http.sys involvement).
function New-FakeHttpServer {
    param([int]$StatusCode = 200, [string]$Body = '')
    $response = 'HTTP/1.1 ' + $StatusCode + ' Synthetic' + "`r`n" +
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
                    # A silent client (connected but never sending a request)
                    # must not block this synchronous Read forever: the read
                    # timeout makes the fake give up and answer/close, so
                    # cleanup can always finish (C-N3).
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

# Fake serverinfo server that sends the response headers immediately and then
# trickles the body one byte at a time forever (until stopped): the shape of
# server that used to hold Get-GsServerInfo's unbounded ReadToEnd open and,
# with it, the lifecycle lock.
function New-TrickleHttpServer {
    param([int]$StatusCode = 200, [int]$BodyLength = 1000000, [int]$IntervalMs = 200)
    $headers = 'HTTP/1.1 ' + $StatusCode + ' Synthetic' + "`r`n" +
        'Content-Type: text/xml' + "`r`n" +
        'Content-Length: ' + $BodyLength + "`r`n" +
        'Connection: close' + "`r`n" + "`r`n"
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddScript({
            param($Listener, $Resp, $Interval)
            $deadline = [System.DateTime]::UtcNow.AddSeconds(120)
            while ([System.DateTime]::UtcNow -lt $deadline) {
                if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
                $client = $Listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    # Read timeout: a silent client must not block cleanup (C-N3).
                    try { $stream.ReadTimeout = 5000 } catch { }
                    $buffer = New-Object byte[] 4096
                    try { $null = $stream.Read($buffer, 0, $buffer.Length) } catch { }
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Resp)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                    $one = New-Object byte[] 1
                    while ($true) {
                        Start-Sleep -Milliseconds $Interval
                        try {
                            $stream.Write($one, 0, 1)
                            $stream.Flush()
                        } catch { break }
                    }
                } finally { try { $client.Close() } catch { } }
            }
        }).AddArgument($listener).AddArgument($headers).AddArgument($IntervalMs)
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

# Builds one canned raw HTTP response as bytes (ASCII head + raw body bytes),
# so tests can serve redirects, multibyte bodies and other shapes the
# status/body-aware fake servers above cannot express.
function New-RawHttpResponseBytes {
    param([string]$StatusLine = 'HTTP/1.1 200 OK', [string[]]$Headers = @(), [byte[]]$BodyBytes = @())
    $head = $StatusLine + "`r`n"
    foreach ($header in $Headers) { $head += ($header + "`r`n") }
    $head += ('Content-Length: ' + $BodyBytes.Length + "`r`n" + 'Connection: close' + "`r`n" + "`r`n")
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $all = New-Object byte[] ($headBytes.Length + $BodyBytes.Length)
    [Array]::Copy($headBytes, 0, $all, 0, $headBytes.Length)
    if ($BodyBytes.Length -gt 0) { [Array]::Copy($BodyBytes, 0, $all, $headBytes.Length, $BodyBytes.Length) }
    return $all
}

# Fake HTTP server that writes one canned RAW response per connection and,
# when RequestLogPath is given, appends one line per accepted connection to
# that file: a test can then prove a server was never contacted by the
# absence of the log.
function New-RawHttpServer {
    param([Parameter(Mandatory = $true)][byte[]]$ResponseBytes, [string]$RequestLogPath = '')
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddScript({
            param($Listener, $Resp, $Log)
            $deadline = [System.DateTime]::UtcNow.AddSeconds(60)
            while ([System.DateTime]::UtcNow -lt $deadline) {
                if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
                $client = $Listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    # Read timeout: a silent client must not block cleanup (C-N3).
                    try { $stream.ReadTimeout = 5000 } catch { }
                    $buffer = New-Object byte[] 4096
                    try { $null = $stream.Read($buffer, 0, $buffer.Length) } catch { }
                    if ($Log -ne '') {
                        [System.IO.File]::AppendAllText($Log, ('hit ' + [System.DateTime]::UtcNow.Ticks + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
                    }
                    $stream.Write($Resp, 0, $Resp.Length)
                    $stream.Flush()
                } finally { try { $client.Close() } catch { } }
            }
        }).AddArgument($listener).AddArgument($ResponseBytes).AddArgument($RequestLogPath)
    $null = $powershell.BeginInvoke()
    $server = [pscustomobject]@{ Port = $port; Listener = $listener; PowerShell = $powershell; Runspace = $runspace }
    $script:Servers.Add($server)
    return $server
}

# Fake serverinfo server that completes the response headers immediately and
# then never finishes the chunked body: the headers declare
# 'Transfer-Encoding: chunked', the first chunk-size line is started with
# '5;' and one chunk-extension byte arrives every IntervalMs forever, so the
# size line never completes and no chunk data ever becomes readable.
function New-ChunkedTrickleServer {
    param([int]$IntervalMs = 200)
    $headers = 'HTTP/1.1 200 OK' + "`r`n" +
        'Transfer-Encoding: chunked' + "`r`n" +
        'Connection: close' + "`r`n" + "`r`n" + '5;'
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddScript({
            param($Listener, $Resp, $Interval)
            $deadline = [System.DateTime]::UtcNow.AddSeconds(120)
            while ([System.DateTime]::UtcNow -lt $deadline) {
                if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
                $client = $Listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    # Read timeout: a silent client must not block cleanup (C-N3).
                    try { $stream.ReadTimeout = 5000 } catch { }
                    $buffer = New-Object byte[] 4096
                    try { $null = $stream.Read($buffer, 0, $buffer.Length) } catch { }
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Resp)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                    $one = New-Object byte[] 1
                    $one[0] = [byte][char]0x65
                    while ($true) {
                        Start-Sleep -Milliseconds $Interval
                        try {
                            $stream.Write($one, 0, 1)
                            $stream.Flush()
                        } catch { break }
                    }
                } finally { try { $client.Close() } catch { } }
            }
        }).AddArgument($listener).AddArgument($headers).AddArgument($IntervalMs)
    $null = $powershell.BeginInvoke()
    $server = [pscustomobject]@{ Port = $port; Listener = $listener; PowerShell = $powershell; Runspace = $runspace }
    $script:Servers.Add($server)
    return $server
}

function New-ServerInfoXml {
    param([string]$CurrentGame = '1', [string]$ServerState = 'READY_SERVER_BUSY')
    return ('<root status_code="200"><state>' + $ServerState + '</state><currentgame>' + $CurrentGame + '</currentgame></root>')
}

function Get-UnusedTcpPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
    $listener.Stop()
    return $port
}

function Test-HasEstablishedLocalConnection {
    param([Parameter(Mandatory = $true)][int]$Port)
    foreach ($connection in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections()) {
        if ($connection.State -eq [System.Net.NetworkInformation.TcpState]::Established -and $connection.LocalEndPoint.Port -eq $Port) { return $true }
    }
    return $false
}

function Get-RecoverError {
    param($Result)
    $found = @($Result.Errors | Where-Object { $_.Code -eq 'RecoverRefused' })
    if ($found.Count -ne 1) {
        throw ("expected exactly one RecoverRefused error, got {0} error(s): {1}" -f @($Result.Errors).Count, ((@($Result.Errors | ForEach-Object { $_.Code })) -join ','))
    }
    return $found[0]
}

# Asserts the exact DACL the product must set on the lifecycle mutex:
# INTERACTIVE (S-1-5-4) and SYSTEM (S-1-5-18) with Synchronize|Modify,
# Administrators (S-1-5-32-544) with FullControl, nothing else.
function Assert-MutexRules {
    param([Parameter(Mandatory = $true)][object[]]$Rules)
    $syncModify = [int][System.Security.AccessControl.MutexRights]::Synchronize -bor [int][System.Security.AccessControl.MutexRights]::Modify
    Assert-Equal 3 @($Rules).Count 'exactly three allow rules'
    $bySid = @{ }
    foreach ($rule in $Rules) {
        Assert-Equal ([System.Security.AccessControl.AccessControlType]::Allow) $rule.AccessControlType 'rule is Allow'
        $bySid[$rule.IdentityReference.ToString()] = $rule
    }
    foreach ($sid in @('S-1-5-4', 'S-1-5-18')) {
        Assert-True $bySid.ContainsKey($sid) ("rule present for {0}" -f $sid)
        Assert-Equal $syncModify ([int]$bySid[$sid].MutexRights) ("Synchronize|Modify for {0}" -f $sid)
    }
    Assert-True $bySid.ContainsKey('S-1-5-32-544') 'rule present for S-1-5-32-544'
    Assert-Equal ([int][System.Security.AccessControl.MutexRights]::FullControl) ([int]$bySid['S-1-5-32-544'].MutexRights) 'FullControl for Administrators'
}

# Runs tests/Invoke-All.ps1 in a child powershell.exe with a hard outer
# timeout (on overrun the child is killed and this throws, so the test fails
# instead of hanging the suite). Output goes through cmd redirection to temp
# FILES instead of captured pipes: .NET hands every inheritable handle to
# children, so the grandchild fixture would otherwise hold this suite's own
# stdout pipe open and the pipe-EOF read would block for as long as the
# grandchild lives. Files are read after the process has exited, which is
# exit-based and immune to that.
function Invoke-AllRunner {
    # With -PassThru the runner is started without waiting and the cmd
    # wrapper Process is returned (the caller must dispose it), so a test
    # can sample the runner process while it runs.
    param([string]$ExtraArgs = '', [int]$TimeoutSec = 60, [switch]$DeferredOutput, [switch]$PassThru)
    $invokeAllPath = Join-Path $PSScriptRoot 'Invoke-All.ps1'
    $outFile = Join-Path $workDir ('invokeall-' + [guid]::NewGuid().ToString('N') + '.out.log')
    $errFile = Join-Path $workDir ('invokeall-' + [guid]::NewGuid().ToString('N') + '.err.log')
    $inner = ('& ''{0}'' {1}' -f $invokeAllPath, $ExtraArgs) + "`r`n" + 'exit $LASTEXITCODE'
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $env:windir 'System32\cmd.exe')
    $psi.Arguments = ('/c powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encoded + ' > "' + $outFile + '" 2> "' + $errFile + '"')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    $script:Children.Add($process)
    if ($PassThru) {
        return ([pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; OutFile = $outFile; ErrFile = $errFile; Process = $process })
    }
    $exitCode = $null
    try {
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill() } catch { }
            if (-not $process.WaitForExit(10000)) {
                throw ("the Invoke-All runner child did not finish within {0}s (and survived the kill)" -f $TimeoutSec)
            }
            throw ("the Invoke-All runner child did not finish within {0}s" -f $TimeoutSec)
        }
        $exitCode = $process.ExitCode
    } finally {
        try { $process.Dispose() } catch { }
    }
    $stdout = ''
    $stderr = ''
    # With -DeferredOutput the caller reads OutFile/ErrFile itself after any
    # fixture descendant has been killed AND fully exited: a descendant
    # inherits the redirect handles, and cmd's redirection denies read
    # sharing until every holder is gone.
    if (-not $DeferredOutput) {
        $stdout = Read-RunnerLogFile -Path $outFile
        $stderr = Read-RunnerLogFile -Path $errFile
    }
    return ([pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr; OutFile = $outFile; ErrFile = $errFile })
}

# Reads a runner log file, retrying briefly while a fixture descendant that
# inherited the redirect handle is still being torn down.
function Read-RunnerLogFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    $deadline = [System.DateTime]::UtcNow.AddSeconds(10)
    while ($true) {
        try { return [System.IO.File]::ReadAllText($Path) } catch [System.IO.IOException] {
            if ([System.DateTime]::UtcNow -gt $deadline) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

function New-RunnerFixtureDir {
    param([Parameter(Mandatory = $true)][string]$Tag)
    $dir = Join-Path $workDir ('allrunner-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

# Builds a temp "installed" copy of gs-product.ps1 whose Modules folder has
# a GsRuntime manifest that is invalid (InvalidManifest) or missing
# (MissingManifest), so the module import loop throws before any action can
# run. GsControl/GsLifecycle get minimal valid manifests so the loop dies
# exactly at GsRuntime.
function New-BrokenModuleInstall {
    param([ValidateSet('InvalidManifest', 'MissingManifest')][string]$Mode)
    $install = Join-Path $workDir ('diag-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $install | Out-Null
    foreach ($module in @('GsControl', 'GsLifecycle')) {
        $moduleDir = Join-Path $install ('Modules\' + $module)
        New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $moduleDir ($module + '.psd1')), "@{ RootModule = ''; ModuleVersion = '1.0.0' }", $utf8)
    }
    $runtimeDir = Join-Path $install 'Modules\GsRuntime'
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    if ($Mode -eq 'InvalidManifest') {
        [System.IO.File]::WriteAllText((Join-Path $runtimeDir 'GsRuntime.psd1'), 'this is not = a valid psd1 {{{', $utf8)
    }
    Copy-Item -LiteralPath $gsProductPath -Destination (Join-Path $install 'gs-product.ps1') -Force
    return $install
}

function New-FakeDiagnoseScript {
    $diagnoseScript = Join-Path $workDir ('fake-diagnose-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $body = "param([string]`$InstallDir, [string]`$StateDir, [string]`$LogDir, [string]`$ServerInfoUri)`r`n[pscustomobject]@{ schemaVersion = 1; ok = `$true; source = 'fake' }"
    [System.IO.File]::WriteAllText($diagnoseScript, $body, $utf8)
    return $diagnoseScript
}

function Write-TestFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Body)
    [System.IO.File]::WriteAllText($Path, $Body, $utf8)
}

# Fixture test files for the Invoke-All.ps1 runner tests.
$hangFixtureBody = @'
$ErrorActionPreference = 'Stop'
Write-Host 'hang fixture: sleeping for 600 seconds'
Start-Sleep -Seconds 600
'@

$passFixtureBody = @'
Write-Host 'PASS x'
Write-Host 'Summary: 1 passed, 0 failed'
exit 0
'@

$lyingFixtureBody = @'
Write-Host 'PASS x'
Write-Host 'Summary: 0 passed, 1 failed'
exit 0
'@

$grandchildMainFixtureBody = @'
$ErrorActionPreference = 'Stop'
Write-Host 'grandchild fixture: leaving a detached grandchild holding the output pipe'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '__INTERMEDIATE__'
# Wait until the grandchild has recorded its PID: by then the intermediate
# has exited and the grandchild is fully detached, so the runner's later
# taskkill /T of this fixture cannot reach it.
$deadline = [System.DateTime]::UtcNow.AddSeconds(30)
while (-not [System.IO.File]::Exists('__PIDFILE__') -and [System.DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
Start-Sleep -Seconds 600
'@

$grandchildIntermediateFixtureBody = @'
$ErrorActionPreference = 'Stop'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')
$psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -PidFile "{1}"' -f '__GRANDCHILD__', '__PIDFILE__')
$psi.UseShellExecute = $false
$null = [System.Diagnostics.Process]::Start($psi)
'@

$grandchildSleepFixtureBody = @'
param([string]$PidFile)
$ErrorActionPreference = 'Stop'
[System.IO.File]::WriteAllText($PidFile, ([string]$PID), (New-Object System.Text.UTF8Encoding($false)))
Start-Sleep -Seconds 120
'@

# Flood fixture: writes 1 MB lines in a tight loop for up to 30 s, so a
# runner that buffers child output in memory balloons until the timeout
# kill stops it.
$floodFixtureBody = @'
$ErrorActionPreference = 'Stop'
$deadline = [System.DateTime]::UtcNow.AddSeconds(30)
$line = 'x' * 1MB
while ([System.DateTime]::UtcNow -lt $deadline) {
    Write-Host $line
}
'@

# Fixture that exits non-zero while claiming success, to pin that the
# runner relays the child process's own exit code.
$exitFixtureBody = @'
Write-Host 'PASS x'
Write-Host 'Summary: 1 passed, 0 failed'
exit 3
'@

# Child that defines the product's serverinfo functions by parsing
# gs-product.ps1 (nothing is dot-sourced, so the param block and module
# imports never run) and calls Get-GsServerInfo once against a local port.
$serverInfoChildTemplate = @'
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile('__GSPRODUCT__', [ref]$tokens, [ref]$parseErrors)
foreach ($fnName in @('Get-GsUnwrappedException', 'Read-GsServerInfoBody', 'Get-GsServerInfo')) {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fnName }, $true)
    if ($null -eq $fn) { throw ('function not found: ' + $fnName) }
    Invoke-Expression $fn.Extent.Text
}
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$info = Get-GsServerInfo -Uri ('http://127.0.0.1:{0}/serverinfo' -f __PORT__) -TimeoutSec 2
$clock.Stop()
Write-Output ('RESULT http={0} currentgame={1} elapsedMs={2} error={3}' -f $info.Http, $info.CurrentGame, $clock.ElapsedMilliseconds, $info.Error)
'@

# Medium-integrity child for the cross-integrity DACL tests. It reports its
# PID and integrity label through a file, defines the product's own mutex
# functions by parsing gs-product.ps1, and then either holds the mutex
# (order 2) or tries the product's open path against an already-held mutex
# and reports BUSY / ACQUIRED / LOCKFAILED (order 1).
$xintChildTemplate = @'
$ErrorActionPreference = 'Stop'
$whoamiExe = Join-Path $env:windir 'System32\whoami.exe'
$resultFile = '__RESULT__'
$readyFile = '__READY__'
$releaseFile = '__RELEASE__'
$mutexName = '__NAME__'
$hold = '__HOLD__'
$label = ''
foreach ($line in @((& $whoamiExe '/groups'))) {
    if ($line -match 'Mandatory Label' -and $line -match 'S-1-16-\d+') { $label = $Matches[0] }
}
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile('__GSPRODUCT__', [ref]$tokens, [ref]$parseErrors)
foreach ($fnName in @('New-GsLifecycleMutexSecurity', 'Get-GsLifecycleLockName')) {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fnName }, $true)
    if ($null -eq $fn) { throw ('function not found: ' + $fnName) }
    Invoke-Expression $fn.Extent.Text
}
$ownPid = $PID
if ($hold -eq 'true') {
    $errorNote = ''
    try {
        $createdNew = $false
        $mutex = New-Object -TypeName 'System.Threading.Mutex' -ArgumentList $true, $mutexName, ([ref]$createdNew), (New-GsLifecycleMutexSecurity)
        if (-not $createdNew) { $errorNote = ';ERROR=mutex already existed' }
        [System.IO.File]::WriteAllText($readyFile, ('PID=' + $ownPid + ';LABEL=' + $label + $errorNote), (New-Object System.Text.UTF8Encoding($false)))
        $deadline = [System.DateTime]::UtcNow.AddSeconds(60)
        while (-not [System.IO.File]::Exists($releaseFile) -and [System.DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    } catch {
        [System.IO.File]::WriteAllText($readyFile, ('PID=' + $ownPid + ';LABEL=' + $label + ';ERROR=' + $_.Exception.Message), (New-Object System.Text.UTF8Encoding($false)))
    }
    exit 0
}
$outcome = 'UNKNOWN'
$detail = ''
try {
    $createdNew = $false
    $mutex = New-Object -TypeName 'System.Threading.Mutex' -ArgumentList $false, $mutexName, ([ref]$createdNew), (New-GsLifecycleMutexSecurity)
    if ($mutex.WaitOne(8000)) {
        $outcome = 'ACQUIRED'
        try { $mutex.ReleaseMutex() } catch { }
    } else {
        $outcome = 'BUSY'
    }
    $mutex.Dispose()
} catch {
    $outcome = 'LOCKFAILED'
    $detail = ('{0}: {1}' -f $_.Exception.GetType().FullName, $_.Exception.Message)
}
[System.IO.File]::WriteAllText($resultFile, ('OUTCOME=' + $outcome + ';DETAIL=' + $detail + ';PID=' + $ownPid), (New-Object System.Text.UTF8Encoding($false)))
exit 0
'@

function Start-MediumIntegrityChild {
    # Starts powershell -File <script> at Basic User trust level via runas.
    # runas returns immediately and the child is NOT our process; all
    # signaling happens through files. Returns runas's exit code.
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    $inner = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"')
    try {
        $null = & runas.exe /trustlevel:0x20000 $inner 2>$null
        return $LASTEXITCODE
    } catch {
        return $null
    }
}

# Runs one cross-integrity order with hard deadlines everywhere; only the
# recorded child PID is ever killed. Returns Outcome = Pass/Skip/Fail.
function Invoke-XintOrder {
    param([Parameter(Mandatory = $true)][ValidateSet('ChildHolds', 'ChildOpens')][string]$Mode)
    $tag = $Mode.ToLowerInvariant()
    $mutexName = Get-GsLifecycleLockName -StateDirPath (Join-Path $workDir ('xint-' + $tag + '-' + [guid]::NewGuid().ToString('N')))
    $readyFile = Join-Path $workDir ('xint-' + $tag + '-ready-' + [guid]::NewGuid().ToString('N') + '.txt')
    $releaseFile = Join-Path $workDir ('xint-' + $tag + '-release-' + [guid]::NewGuid().ToString('N') + '.txt')
    $resultFile = Join-Path $workDir ('xint-' + $tag + '-result-' + [guid]::NewGuid().ToString('N') + '.txt')
    $childScript = Join-Path $workDir ('xint-' + $tag + '-child-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $mutex = $null
    $childPid = $null
    try {
        if ($Mode -eq 'ChildOpens') {
            # Order 1: the elevated test process creates the mutex through the
            # product's code path and holds it.
            $createdNew = $false
            $mutex = New-Object -TypeName 'System.Threading.Mutex' -ArgumentList $true, $mutexName, ([ref]$createdNew), (New-GsLifecycleMutexSecurity)
            if (-not $createdNew) { throw 'Assertion failed: the elevated side did not create a fresh mutex' }
        }
        $holdFlag = 'false'
        if ($Mode -eq 'ChildHolds') { $holdFlag = 'true' }
        $body = $xintChildTemplate.Replace('__RESULT__', $resultFile).Replace('__READY__', $readyFile).Replace('__RELEASE__', $releaseFile).Replace('__NAME__', $mutexName).Replace('__HOLD__', $holdFlag).Replace('__GSPRODUCT__', $gsProductPath)
        [System.IO.File]::WriteAllText($childScript, $body, $utf8)
        $null = Start-MediumIntegrityChild -ScriptPath $childScript
        try {
            Wait-Until -Condition { Test-Path -LiteralPath $readyFile } -TimeoutSec 30 -Message 'medium-IL child did not signal readiness (runas /trustlevel did not start it)'
        } catch {
            return @{ Outcome = 'Skip'; Reason = 'runas /trustlevel did not produce a readiness signal; the medium-IL child may not be startable on this build' }
        }
        $ready = [System.IO.File]::ReadAllText($readyFile)
        if ($ready -match 'PID=(\d+)') { $childPid = [int]$Matches[1] }
        if ($ready -match 'ERROR=') {
            return @{ Outcome = 'Fail'; Reason = ('medium-IL child failed: {0}' -f $ready) }
        }
        if ($ready -notmatch 'LABEL=S-1-16-8192') {
            return @{ Outcome = 'Skip'; Reason = ('the child did not report medium integrity (expected S-1-16-8192), observed: {0}' -f $ready) }
        }
        if ($Mode -eq 'ChildHolds') {
            # Order 2: the medium-IL child created the mutex and holds it; the
            # elevated side must open it and see Busy, then lets the child go.
            $createdNew = $true
            $mutex = New-Object -TypeName 'System.Threading.Mutex' -ArgumentList $false, $mutexName, ([ref]$createdNew), (New-GsLifecycleMutexSecurity)
            if ($createdNew) { throw 'Assertion failed: the elevated side created a fresh mutex instead of opening the child''s' }
            if ($mutex.WaitOne(8000)) {
                try { $mutex.ReleaseMutex() } catch { }
                throw 'Assertion failed: the elevated side ACQUIRED the mutex although the medium-IL child holds it'
            }
            [System.IO.File]::WriteAllText($releaseFile, 'go', $utf8)
            return @{ Outcome = 'Pass'; Reason = 'the medium-IL child created and held the mutex; the elevated side observed Busy' }
        }
        # Order 1: wait for the child's own outcome report.
        try {
            Wait-Until -Condition { Test-Path -LiteralPath $resultFile } -TimeoutSec 30 -Message 'medium-IL child did not report the open outcome'
        } catch {
            return @{ Outcome = 'Fail'; Reason = 'the medium-IL child did not report an outcome within 30s' }
        }
        $outcome = [System.IO.File]::ReadAllText($resultFile)
        if (-not $outcome.Contains('OUTCOME=BUSY')) {
            return @{ Outcome = 'Fail'; Reason = ('the medium-IL child must see Busy, observed: {0}' -f $outcome) }
        }
        return @{ Outcome = 'Pass'; Reason = 'the medium-IL child opened the elevated-created mutex and observed Busy' }
    } catch {
        return @{ Outcome = 'Fail'; Reason = $_.Exception.Message }
    } finally {
        if ($null -ne $childPid -and $childPid -gt 0) {
            try {
                $proc = Get-Process -Id $childPid -ErrorAction Stop
                if ($proc.ProcessName -eq 'powershell') { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Publish-XintOutcome {
    param([Parameter(Mandatory = $true)][string]$Name, $Outcome)
    if ($Outcome.Outcome -eq 'Pass') {
        $script:Passed++
        Write-Host ("PASS {0}" -f $Name)
    } elseif ($Outcome.Outcome -eq 'Skip') {
        $script:Skipped++
        Write-Host ("SKIP {0} :: {1}" -f $Name, $Outcome.Reason)
    } else {
        $script:Failed++
        Write-Host ("FAIL {0} :: {1}" -f $Name, $Outcome.Reason)
    }
}

try {
    # ---------------- Cross-process lifecycle mutex ----------------

    Invoke-Test 'Start reports Busy while another process holds the lock and succeeds after release' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $holder = New-LockHolder -Layout $layout -Tag 'start-busy'
        try {
            Wait-LockHolderReady -Holder $holder
            $result = Invoke-GsProductJson -Action 'Start' -Layout $layout -Extra @{ LockTimeoutSec = 1 }
            Assert-True (-not $result.Success) 'Start refused'
            Assert-Equal 'Busy' $result.Errors[0].Code 'Busy code'
            Assert-True ($result.Errors[0].Message -like 'Another Start/Stop/Recover is in progress*') 'Busy message'
            Assert-Equal (Get-LockName -StateDirPath $layout.StateDir) $result.Errors[0].LockName 'lock name reported'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'start.begun'))) 'start script did not run while Busy'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no marker entries while Busy'

            $released = Release-LockHolder -Holder $holder
            Assert-Equal 0 $released.ExitCode 'holder released cleanly'
            $after = Invoke-GsProductJson -Action 'Start' -Layout $layout
            Assert-True $after.Success 'Start succeeds after the holder releases'
            Assert-Equal 0 $after.Data.ExitCode 'start exit code'
            Assert-Equal $false $after.Data.LockAbandoned 'lock was not abandoned'
            Assert-Equal 1 @(Get-MarkerEntries -Layout $layout).Count 'exactly one start after release'
        } finally {
            [System.IO.File]::WriteAllText($holder.Release, 'go', $utf8)
            try { $null = Complete-LockHolder -Holder $holder } catch { }
        }
    }

    Invoke-Test 'Stop reports Busy while another process holds the lock' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $holder = New-LockHolder -Layout $layout -Tag 'stop-busy'
        try {
            Wait-LockHolderReady -Holder $holder
            $result = Invoke-GsProductJson -Action 'Stop' -Layout $layout -Extra @{ LockTimeoutSec = 1 }
            Assert-True (-not $result.Success) 'Stop refused'
            Assert-Equal 'Busy' $result.Errors[0].Code 'Busy code'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'stop.begun'))) 'stop script did not run while Busy'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'supervisor_pause.flag'))) 'no pause flag at the legacy root while Busy'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'runtime\state\supervisor_pause.flag'))) 'no pause flag at the canonical location while Busy'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no marker entries while Busy'
        } finally {
            [System.IO.File]::WriteAllText($holder.Release, 'go', $utf8)
            try { $null = Complete-LockHolder -Holder $holder } catch { }
        }
    }

    Invoke-Test 'Two concurrent Starts with a short lock timeout produce exactly one start' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_sleep_ms'), '3000', $utf8)
        $first = Start-GsProductChild -Action 'Start' -Layout $layout -Extra @{ LockTimeoutSec = 60 }
        try {
            Wait-Until -Condition { Test-Path -LiteralPath (Join-Path $layout.StateDir 'start.begun') } -TimeoutSec 30 -Message 'first start script did not begin'
            $second = Invoke-GsProductJson -Action 'Start' -Layout $layout -Extra @{ LockTimeoutSec = 1 }
            Assert-True (-not $second.Success) 'second Start refused'
            Assert-Equal 'Busy' $second.Errors[0].Code 'second Start is Busy'
            $firstResult = Complete-GsProductJson -Child $first
            Assert-True $firstResult.Success 'first Start succeeds'
            Assert-Equal 1 @(Get-MarkerEntries -Layout $layout).Count 'exactly one start ran'
        } finally {
            try { if (-not $first.Process.HasExited) { $first.Process.Kill() } } catch { }
        }
    }

    Invoke-Test 'Two concurrent Starts with a long lock timeout both succeed without overlapping' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_sleep_ms'), '3000', $utf8)
        $first = Start-GsProductChild -Action 'Start' -Layout $layout -Extra @{ LockTimeoutSec = 60 }
        try {
            Wait-Until -Condition { Test-Path -LiteralPath (Join-Path $layout.StateDir 'start.begun') } -TimeoutSec 30 -Message 'first start script did not begin'
            $second = Invoke-GsProductJson -Action 'Start' -Layout $layout -Extra @{ LockTimeoutSec = 60 }
            Assert-True $second.Success 'second Start succeeds after waiting for the lock'
            $firstResult = Complete-GsProductJson -Child $first
            Assert-True $firstResult.Success 'first Start succeeds'
            $entries = @(Get-MarkerEntries -Layout $layout)
            Assert-Equal 2 $entries.Count 'two starts ran'
            $ordered = @($entries | Sort-Object -Property StartTicks)
            Assert-True ($ordered[0].EndTicks -le $ordered[1].StartTicks) 'start script intervals do not overlap'
        } finally {
            try { if (-not $first.Process.HasExited) { $first.Process.Kill() } } catch { }
        }
    }

    Invoke-Test 'Start succeeds when the mutex was abandoned by its previous owner' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $holder = New-LockHolder -Layout $layout -Tag 'abandon'
        try {
            Wait-LockHolderReady -Holder $holder
            # The holder delays its (non-releasing) exit, so the Start below
            # opens the named mutex and blocks on it; when the holder dies the
            # blocked wait raises AbandonedMutexException and Start proceeds.
            [System.IO.File]::WriteAllText($holder.Abandon, 'go', $utf8)
            $result = Invoke-GsProductJson -Action 'Start' -Layout $layout -Extra @{ LockTimeoutSec = 60 } -TimeoutSec 180
            Assert-True $result.Success 'Start succeeds after abandonment'
            Assert-Equal $true $result.Data.LockAbandoned 'LockAbandoned flag is set'
            Assert-Equal 0 $result.Data.ExitCode 'start exit code'
            Assert-Equal 1 @(Get-MarkerEntries -Layout $layout).Count 'start script ran once'
        } finally {
            [System.IO.File]::WriteAllText($holder.Release, 'go', $utf8)
            try { $null = Complete-LockHolder -Holder $holder } catch { }
        }
    }

    Invoke-Test 'Lock is released when the start script throws' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_throw'), '1', $utf8)
        $child = Start-GsProductChild -Action 'Start' -Layout $layout -Extra @{ LockTimeoutSec = 15 }
        # The failure is now a structured result (RuntimeStartFailed); the
        # CLI no longer dies with the unhandled throw.
        $raw = Complete-ChildPowerShell -Child $child
        $result = ConvertFrom-Json -InputObject $raw.StdOut
        Assert-True (-not $result.Success) 'Success is false when the start script throws'
        Assert-Equal 'RuntimeStartFailed' $result.Errors[0].Code 'error code is structured'
        Assert-True ($result.Errors[0].Message -like '*synthetic start failure*') 'message carries the synthetic failure'
        # The lock must have been released: a retry is not Busy.
        [System.IO.File]::Delete((Join-Path $layout.StateDir 'start_throw'))
        $retry = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True $retry.Success 'retry after the throw succeeds, so the lock was released'
    }

    Invoke-Test 'Different state directories do not block each other' {
        $layoutA = New-TempLayout
        $layoutB = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layoutA
        Write-FakeRuntimeScripts -Layout $layoutB
        [System.IO.File]::WriteAllText((Join-Path $layoutA.StateDir 'start_sleep_ms'), '4000', $utf8)
        $first = Start-GsProductChild -Action 'Start' -Layout $layoutA -Extra @{ LockTimeoutSec = 60 }
        try {
            Wait-Until -Condition { Test-Path -LiteralPath (Join-Path $layoutA.StateDir 'start.begun') } -TimeoutSec 30 -Message 'layout A start script did not begin'
            $second = Invoke-GsProductJson -Action 'Start' -Layout $layoutB -Extra @{ LockTimeoutSec = 2 }
            Assert-True $second.Success 'a different StateDir is not blocked by the held lock'
            $firstResult = Complete-GsProductJson -Child $first
            Assert-True $firstResult.Success 'layout A start succeeds'
        } finally {
            try { if (-not $first.Process.HasExited) { $first.Process.Kill() } } catch { }
        }
    }

    Invoke-Test 'Status and Diagnose do not block on the lifecycle lock' {
        $layout = New-TempLayout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $diagnoseScript = Join-Path $workDir ('fake-diagnose-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $diagnoseBody = "param([string]`$InstallDir, [string]`$StateDir, [string]`$LogDir, [string]`$ServerInfoUri)`r`n[pscustomobject]@{ schemaVersion = 1; ok = `$true; source = 'fake' }"
        [System.IO.File]::WriteAllText($diagnoseScript, $diagnoseBody, $utf8)
        $holder = New-LockHolder -Layout $layout -Tag 'status-diagnose'
        try {
            Wait-LockHolderReady -Holder $holder
            $status = Invoke-GsProductJson -Action 'Status' -Layout $layout -Extra @{ LockTimeoutSec = 1 }
            Assert-True $status.Success 'Status succeeds while the lock is held'
            Assert-Equal 'ready' $status.Data.state 'Status reads the runtime state'
            $diagnose = Invoke-GsProductJson -Action 'Diagnose' -Layout $layout -Extra @{ LockTimeoutSec = 1; DiagnoseScript = $diagnoseScript }
            Assert-True $diagnose.Success 'Diagnose succeeds while the lock is held'
            Assert-Equal 'fake' $diagnose.Data.source 'Diagnose returned the fake report'
        } finally {
            [System.IO.File]::WriteAllText($holder.Release, 'go', $utf8)
            try { $null = Complete-LockHolder -Holder $holder } catch { }
        }
    }

    # ---------------- Lifecycle mutex security (DACL) ----------------

    Invoke-Test 'Lifecycle mutex security rules (extracted via AST)' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'New-GsLifecycleMutexSecurity')
        $security = New-GsLifecycleMutexSecurity
        Assert-MutexRules -Rules @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    }

    $daclReadTestName = 'gs-product creates the lifecycle mutex with the INTERACTIVE/SYSTEM/Administrators DACL'
    if ($elevated) {
        Invoke-Test $daclReadTestName {
            $layout = New-TempLayout
            Write-FakeRuntimeScripts -Layout $layout
            # The fake start script sleeps long enough for this test to open
            # the mutex by name and read its DACL while gs-product holds it.
            [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_sleep_ms'), '8000', $utf8)
            $child = Start-GsProductChild -Action 'Start' -Layout $layout
            try {
                Wait-Until -Condition { Test-Path -LiteralPath (Join-Path $layout.StateDir 'start.begun') } -TimeoutSec 30 -Message 'start script did not begin (mutex was not created)'
                $lockName = Get-LockName -StateDirPath $layout.StateDir
                $opened = [System.Threading.Mutex]::OpenExisting($lockName, [System.Security.AccessControl.MutexRights]::ReadPermissions)
                try {
                    $dacl = $opened.GetAccessControl()
                    Assert-MutexRules -Rules @($dacl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
                } finally {
                    $opened.Dispose()
                }
            } finally {
                try { if (-not $child.Process.HasExited) { $child.Process.Kill() } } catch { }
            }
        }
    } else {
        $script:Skipped++
        Write-Host ('SKIP {0} :: reading the mutex DACL needs an elevated session (only Administrators FullControl grants READ_CONTROL on it)' -f $daclReadTestName)
    }

    # The cross-integrity tests start a medium-integrity child via
    # runas /trustlevel, which needs the Secondary Logon service. Read-only
    # status check here; the harness never starts services.
    $xintGateReason = $null
    if (-not $elevated) {
        $xintGateReason = 'the test process is not elevated'
    } else {
        $seclogon = Get-Service -Name 'seclogon' -ErrorAction SilentlyContinue
        if ($null -eq $seclogon) {
            $xintGateReason = 'the Secondary Logon (seclogon) service is not installed'
        } elseif ($seclogon.Status -ne 'Running') {
            $xintGateReason = ('runas /trustlevel needs the Secondary Logon (seclogon) service and its status is {0}; the harness never starts services' -f $seclogon.Status)
        }
    }
    if ($null -ne $xintGateReason) {
        $script:Skipped += 2
        Write-Host ('SKIP Mutex DACL across integrity levels (order 1: medium-IL child opens while elevated holds) :: {0}' -f $xintGateReason)
        Write-Host ('SKIP Mutex DACL across integrity levels (order 2: elevated opens while medium-IL child holds) :: {0}' -f $xintGateReason)
    } else {
        Invoke-Expression (Get-GsProductFunctionText -Name 'New-GsLifecycleMutexSecurity')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsLifecycleLockName')
        $order1Name = 'Mutex DACL across integrity levels (order 1: medium-IL child opens while elevated holds)'
        Publish-XintOutcome -Name $order1Name -Outcome (Invoke-XintOrder -Mode 'ChildOpens')
        $order2Name = 'Mutex DACL across integrity levels (order 2: elevated opens while medium-IL child holds)'
        Publish-XintOutcome -Name $order2Name -Outcome (Invoke-XintOrder -Mode 'ChildHolds')
    }

    # ---------------- Lock name normalization ----------------

    Invoke-Test 'Lock name normalization collapses equivalent path spellings' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsLifecycleLockName')
        $base = Get-GsLifecycleLockName -StateDirPath 'C:\Gs\State'
        Assert-True ($base.StartsWith('Global\GsController.Lifecycle.')) 'name prefix'
        Assert-Equal $base (Get-GsLifecycleLockName -StateDirPath 'C:\Gs\.\State') 'dot segment normalizes'
        Assert-Equal $base (Get-GsLifecycleLockName -StateDirPath 'c:/gs/state') 'forward slashes and casing normalize'
        Assert-Equal $base (Get-GsLifecycleLockName -StateDirPath 'C:\Gs\State\') 'trailing separator normalizes'
        Assert-Equal $base (Get-GsLifecycleLockName -StateDirPath 'C:\Gs\State\\') 'double trailing separators normalize'
        Assert-True ($base -ne (Get-GsLifecycleLockName -StateDirPath 'C:\Gs\Other')) 'different directories still differ'
    }

    Invoke-Test 'Product lock name function matches the test copy' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsLifecycleLockName')
        Assert-Equal (Get-LockName -StateDirPath $workDir) (Get-GsLifecycleLockName -StateDirPath $workDir) 'product and test derive the same lock name'
    }

    # ---------------- $LASTEXITCODE handling ----------------

    Invoke-Test 'Start reports success when the start script ends without exit' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_noexit'), '1', $utf8)
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True $result.Success 'Success is true for a script without exit'
        Assert-Equal 0 $result.Data.ExitCode 'exit code is 0'
    }

    Invoke-Test 'Start reports failure with ExitCode 3 when the start script exits 3' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_exit'), '3', $utf8)
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True (-not $result.Success) 'Success is false for exit 3'
        Assert-Equal 3 $result.Data.ExitCode 'exit code is 3'
        Assert-Equal 'RuntimeStartFailed' $result.Errors[0].Code 'non-zero exit carries a structured error code'
        Assert-Equal 3 $result.Errors[0].ExitCode 'error entry carries the exit code'
    }

    Invoke-Test 'Stop reports RuntimeStopFailed when the stop script exits 3' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop_exit'), '3', $utf8)
        $result = Invoke-GsProductJson -Action 'Stop' -Layout $layout
        Assert-True (-not $result.Success) 'Success is false for exit 3'
        Assert-Equal 3 $result.Data.ExitCode 'exit code is 3'
        Assert-Equal 'RuntimeStopFailed' $result.Errors[0].Code 'non-zero exit carries a structured error code'
        Assert-Equal 3 $result.Errors[0].ExitCode 'error entry carries the exit code'
    }

    Invoke-Test 'Stop reports RuntimeStopFailed when the state directory is unusable' {
        # The configured stateDir is an existing FILE: the runtime stop
        # script cannot exist under it and the pause flag's parent cannot be
        # a directory. The pre-checks fire BEFORE any side effect (no pause
        # flag, no directory, no runtime script run), and the failure is the
        # structured RuntimeStopFailed, not an unhandled throw.
        $root = Join-Path $workDir ('stopflag-' + [guid]::NewGuid().ToString('N'))
        $stateFile = Join-Path $root 'state-is-a-file'
        $configDir = Join-Path $root 'config'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        [System.IO.File]::WriteAllText($stateFile, 'not a directory', $utf8)
        $config = [ordered]@{
            schemaVersion      = 1
            installDir         = (Join-Path $root 'install')
            stateDir           = $stateFile
            logDir             = (Join-Path $root 'logs')
            componentSourceDir = (Join-Path $root 'components')
        }
        [System.IO.File]::WriteAllText((Join-Path $configDir 'runtime-config.json'), (ConvertTo-Json -InputObject $config -Depth 4), $utf8)
        $command = ("& '{0}' -Action Stop -InstallDir '{1}' -StateDir '{2}' -LogDir '{3}' -ModuleRoot '{4}' -SupervisorTaskName '' -StopSettleSec 0 | ConvertTo-Json -Depth 8" -f `
                $gsProductPath, (Join-Path $root 'install'), $configDir, (Join-Path $root 'logs'), $moduleRoot)
        $raw = Invoke-ChildPowerShell -Command $command
        Assert-Equal 0 $raw.ExitCode 'gs-product exits 0 with a structured result'
        $result = ConvertFrom-Json -InputObject $raw.StdOut
        Assert-True (-not $result.Success) 'Stop fails'
        Assert-Equal 'RuntimeStopFailed' $result.Errors[0].Code 'pause failure is a structured stop failure'
        Assert-True ($result.Errors[0].Message -like '*Stop failed*') 'message carries the failure'
        Assert-Equal $null $result.Data.ExitCode 'no exit code: the stop script never ran'
        Assert-Equal $false $result.Data.LockAbandoned 'lock was not abandoned'
        Assert-Equal $false ([System.IO.File]::Exists((Join-Path $configDir 'lifecycle-marker.log'))) 'no marker: the stop script did not run'
    }

    Invoke-Test 'Start reports RuntimeStartFailed when the runtime start script is missing' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Remove-Item -LiteralPath (Join-Path $layout.StateDir 'runtime\bin\gs_start_with_hook.ps1') -Force
        $result = Invoke-GsProductJson -Action 'Start' -Layout $layout
        Assert-True (-not $result.Success) 'Success is false for a missing script'
        Assert-Equal 'RuntimeStartFailed' $result.Errors[0].Code 'missing script is a structured failure'
        Assert-True ($result.Errors[0].Message -like '*missing*') 'message says the script is missing'
    }

    Invoke-Test 'Start with script output keeps the result object as the last output element' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_output'), "RESULT OK`r`nhook loaded", $utf8)
        $parsed = Invoke-GsProductJson -Action 'Start' -Layout $layout
        # Script output first, result object last (the tray parser takes the
        # last element), so the JSON is an array of three.
        $items = @($parsed)
        Assert-Equal 3 $items.Count 'two output lines plus the result object'
        Assert-Equal 'RESULT OK' $items[0] 'first output line'
        Assert-Equal 'hook loaded' $items[1] 'second output line'
        Assert-True ($items[2] -is [pscustomobject]) 'last element is the result object'
        Assert-True $items[2].Success 'result Success is true'
        Assert-Equal 0 $items[2].Data.ExitCode 'result exit code'
    }

    # ---------------- Recover refusals (fail closed) ----------------

    Invoke-Test 'Recover refuses with StatusUnavailable when no status file exists' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout
        $refusal = Get-RecoverError $result
        Assert-Equal 'StatusUnavailable' $refusal.Reason 'reason'
        Assert-Equal $null $refusal.Observed.StatusPath 'observed status path is null'
        Assert-Equal 'TcpOnly' $refusal.Observed.ConnectionCheckScope 'connection check scope is reported'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
    }

    Invoke-Test 'Recover refuses with NotReady when the status state is not ready' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'stopped'
        $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout
        $refusal = Get-RecoverError $result
        Assert-Equal 'NotReady' $refusal.Reason 'reason'
        Assert-Equal 'stopped' $refusal.Observed.StatusState 'observed status state'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
    }

    Invoke-Test 'Recover refuses with StatusUnavailable when the status file cannot be parsed' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'status.json'), 'this is not json at all', $utf8)
        $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout
        $refusal = Get-RecoverError $result
        Assert-Equal 'StatusUnavailable' $refusal.Reason 'reason'
        Assert-True ($refusal.Message -like '*could not be read or parsed*') 'message says the status file could not be parsed'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
    }

    Invoke-Test 'Status reports StatusReadFailed when the status file cannot be parsed' {
        $layout = New-TempLayout
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'status.json'), 'this is not json at all', $utf8)
        $result = Invoke-GsProductJson -Action 'Status' -Layout $layout
        Assert-True (-not $result.Success) 'Status fails'
        Assert-Equal 'StatusReadFailed' $result.Errors[0].Code 'read/parse failure is a structured error'
        Assert-True ($result.Errors[0].Message -like '*could not be read or parsed*') 'message names the failure'
    }

    Invoke-Test 'Recover refuses a status state field that is not a string' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        # [string] coercion would turn several of these into 'ready'-like
        # values; the gate must require an actual JSON string instead.
        $cases = @(
            @{ Name = 'array value'; Json = '{"state":["ready"]}' },
            @{ Name = 'number value'; Json = '{"state":5}' },
            @{ Name = 'object value'; Json = '{"state":{"x":1}}' },
            @{ Name = 'null value'; Json = '{"state":null}' }
        )
        foreach ($case in $cases) {
            [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'status.json'), $case.Json, $utf8)
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout
            $refusal = Get-RecoverError $result
            Assert-Equal 'NotReady' $refusal.Reason ('{0}: refusal reason' -f $case.Name)
            Assert-True ($refusal.Message -like '*state field is not a string*') ('{0}: message names the type failure' -f $case.Name)
            Assert-Equal $null $refusal.Observed.StatusState ('{0}: no coerced state value is reported' -f $case.Name)
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count ('{0}: no runtime script ran' -f $case.Name)
        }
    }

    Invoke-Test 'Recover refuses a status root that is not a JSON object' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        # A JSON array root parses but has no state field; documented choice:
        # NotReady (the file was found, read and parsed - the failure is the
        # state field's type), not StatusUnavailable.
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'status.json'), '["ready"]', $utf8)
        $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout
        $refusal = Get-RecoverError $result
        Assert-Equal 'NotReady' $refusal.Reason 'refusal reason'
        Assert-True ($refusal.Message -like '*state field is not a string*') 'message names the type failure'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
    }

    Invoke-Test 'Status reports StatusReadFailed when the status path lookup throws (extracted via AST)' {
        # No deterministic real-layout trigger exists for a throwing lookup:
        # Test-Path returns $false without throwing both for a candidate
        # whose parent is a file and for a >260-character candidate, and
        # illegal path characters are already rejected earlier, when the
        # runtime config is loaded. The layout object here therefore carries
        # an illegal path character directly, which makes Test-Path throw
        # inside Get-GsStatusFilePath.
        Invoke-Expression (Get-GsProductFunctionText -Name 'New-Result')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsStatusFilePath')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Invoke-GsStatusAction')
        $badState = Join-Path $workDir 'bad|state-dir'
        $layout = [pscustomobject]@{
            StateDir   = $badState
            StatusPath = (Join-Path $badState 'status.json')
        }
        $result = Invoke-GsStatusAction -Layout $layout
        Assert-True (-not $result.Success) 'Status fails'
        Assert-Equal 'StatusReadFailed' $result.Errors[0].Code 'lookup throw is a structured error'
        Assert-True ($result.Errors[0].Message -like '*could not be read or parsed*') 'message names the failure'
    }

    Invoke-Test 'Recover refuses with ServerInfoUnavailable when serverinfo is unreachable' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $closedPort = Get-UnusedTcpPort
        $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
            ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $closedPort)
        }
        $refusal = Get-RecoverError $result
        Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
        Assert-Equal $null $refusal.Observed.ServerInfoHttp 'observed http is null'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
    }

    Invoke-Test 'Recover refuses with ServerInfoUnavailable when serverinfo returns HTTP 500' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $server = New-FakeHttpServer -StatusCode 500 -Body ''
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal 500 $refusal.Observed.ServerInfoHttp 'observed http status'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses with NoStuckSession when currentgame is 0' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '0')
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'NoStuckSession' $refusal.Reason 'reason'
            Assert-Equal 200 $refusal.Observed.ServerInfoHttp 'observed http status'
            Assert-Equal '0' $refusal.Observed.CurrentGame 'observed currentgame'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses with NoStuckSession when currentgame is 2' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '2')
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'NoStuckSession' $refusal.Reason 'reason'
            Assert-Equal '2' $refusal.Observed.CurrentGame 'observed currentgame'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses with ServerInfoUnavailable when the serverinfo XML is malformed' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $server = New-FakeHttpServer -StatusCode 200 -Body 'this is not xml at all'
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal 200 $refusal.Observed.ServerInfoHttp 'observed http status'
            Assert-Equal $null $refusal.Observed.CurrentGame 'observed currentgame is null'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses serverinfo XML status_code that is not 200 inside an HTTP 200' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $body = '<root status_code="503"><state>READY_SERVER_BUSY</state><currentgame>1</currentgame></root>'
        $server = New-FakeHttpServer -StatusCode 200 -Body $body
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal 200 $refusal.Observed.ServerInfoHttp 'observed http status is the transport status'
            Assert-Equal $null $refusal.Observed.CurrentGame 'currentgame is not read from a bad status_code'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses a non-numeric currentgame' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $body = '<root status_code="200"><state>READY_SERVER_BUSY</state><currentgame>12abc</currentgame></root>'
        $server = New-FakeHttpServer -StatusCode 200 -Body $body
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal $null $refusal.Observed.CurrentGame 'non-numeric currentgame is rejected'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses an oversized serverinfo body' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $server = New-FakeHttpServer -StatusCode 200 -Body ([string][System.Text.Encoding]::ASCII.GetString((New-Object byte[] 70000)))
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ServerInfoTimeoutSec = 5
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal 200 $refusal.Observed.ServerInfoHttp 'observed http status'
            Assert-Equal $null $refusal.Observed.CurrentGame 'no currentgame from an oversized body'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses serverinfo XML without a state element' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $body = '<root status_code="200"><currentgame>1</currentgame></root>'
        $server = New-FakeHttpServer -StatusCode 200 -Body $body
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ClientPorts   = @(Get-UnusedTcpPort)
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal $null $refusal.Observed.CurrentGame 'no currentgame from a state-less body'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses serverinfo XML with a whitespace-only state element' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $body = '<root status_code="200"><state>   </state><currentgame>1</currentgame></root>'
        $server = New-FakeHttpServer -StatusCode 200 -Body $body
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ClientPorts   = @(Get-UnusedTcpPort)
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal $null $refusal.Observed.CurrentGame 'no currentgame from a whitespace state'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses an 11-digit currentgame' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        # All-digit, so the old 'anything numeric' rule accepted it (and
        # Recover reported NoStuckSession); the unified rule caps the field
        # at 10 digits and refuses with ServerInfoUnavailable instead.
        $body = '<root status_code="200"><state>READY_SERVER_BUSY</state><currentgame>12345678901</currentgame></root>'
        $server = New-FakeHttpServer -StatusCode 200 -Body $body
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
            }
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal $null $refusal.Observed.CurrentGame 'no currentgame from an over-long field'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses a serverinfo 302 redirect instead of following it' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $redirectLog = Join-Path $workDir ('redirect-target-' + [guid]::NewGuid().ToString('N') + '.log')
        $targetServer = New-RawHttpServer -ResponseBytes (New-RawHttpResponseBytes -StatusLine 'HTTP/1.1 200 OK' -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes((New-ServerInfoXml -CurrentGame '1')))) -RequestLogPath $redirectLog
        try {
            $redirectServer = New-RawHttpServer -ResponseBytes (New-RawHttpResponseBytes -StatusLine 'HTTP/1.1 302 Found' -Headers @('Location: http://127.0.0.1:' + $targetServer.Port + '/serverinfo'))
            try {
                $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                    ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $redirectServer.Port)
                    ClientPorts   = @(Get-UnusedTcpPort)
                }
                $refusal = Get-RecoverError $result
                Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
                Assert-Equal 302 $refusal.Observed.ServerInfoHttp 'observed http is the redirect status'
                Assert-Equal $false ([System.IO.File]::Exists($redirectLog)) 'the redirect target was never contacted'
                Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
            } finally {
                Stop-FakeHttpServer -Server $redirectServer
            }
        } finally {
            Stop-FakeHttpServer -Server $targetServer
        }
    }

    Invoke-Test 'Get-GsServerInfo counts body bytes before decoding (extracted via AST)' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsUnwrappedException')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Read-GsServerInfoBody')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsServerInfo')
        # 40000 two-byte UTF-8 characters = 80000 bytes: over the 65536-BYTE
        # cap while staying under 65536 characters, so only a byte-counted
        # cap can refuse it.
        $multibyteChar = [string][char]0xE9
        $body = $multibyteChar * 40000
        $server = New-RawHttpServer -ResponseBytes (New-RawHttpResponseBytes -StatusLine 'HTTP/1.1 200 OK' -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($body)))
        try {
            $info = Get-GsServerInfo -Uri ('http://127.0.0.1:{0}/serverinfo' -f $server.Port) -TimeoutSec 8
            Assert-Equal 200 $info.Http 'transport status is 200'
            Assert-True ($info.Error -like 'BodyTooLarge*') ('oversize is detected on bytes, not chars: {0}' -f $info.Error)
            Assert-Equal $null $info.CurrentGame 'no currentgame from an oversized body'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Get-GsServerInfo accepts a body of exactly 65536 bytes (extracted via AST)' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsUnwrappedException')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Read-GsServerInfoBody')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsServerInfo')
        # The byte cap is inclusive: exactly 65536 bytes is a valid body (all
        # ASCII here, so bytes and chars agree), padded with spaces inside
        # the root element.
        $prefix = '<root status_code="200"><state>READY_SERVER_BUSY</state><currentgame>1</currentgame>'
        $body = $prefix + (' ' * (65536 - $prefix.Length - '</root>'.Length)) + '</root>'
        Assert-Equal 65536 ([System.Text.Encoding]::UTF8.GetByteCount($body)) 'fixture body is exactly at the cap'
        $server = New-RawHttpServer -ResponseBytes (New-RawHttpResponseBytes -StatusLine 'HTTP/1.1 200 OK' -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($body)))
        try {
            $info = Get-GsServerInfo -Uri ('http://127.0.0.1:{0}/serverinfo' -f $server.Port) -TimeoutSec 8
            Assert-Equal $null $info.Error ('a body at the cap is valid: {0}' -f $info.Error)
            Assert-Equal '1' $info.CurrentGame 'currentgame is read from the at-cap body'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses a trickling serverinfo body within the deadline and releases the lock' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $server = New-TrickleHttpServer -StatusCode 200
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri         = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ServerInfoTimeoutSec  = 2
                LockTimeoutSec        = 15
            } -TimeoutSec 60
            $stopwatch.Stop()
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal 200 $refusal.Observed.ServerInfoHttp 'observed http status'
            Assert-Equal $null $refusal.Observed.CurrentGame 'no currentgame from a trickling body'
            # The total deadline (2s) plus child-process overhead must bound
            # the whole call; the old unbounded read would never return.
            Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 12) ('Recover returned within the deadline, took {0:N1}s' -f $stopwatch.Elapsed.TotalSeconds)
            # The lock was released: a following Start is not Busy.
            $followUp = Invoke-GsProductJson -Action 'Start' -Layout $layout -Extra @{ LockTimeoutSec = 1 }
            Assert-True $followUp.Success 'following Start is not Busy, so the lock was released'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses a chunked-forever serverinfo body within the deadline and releases the lock' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        # Headers complete immediately (Transfer-Encoding: chunked), then the
        # chunk-size line trickles one extension byte every 200 ms forever:
        # no chunk data ever becomes readable. The response wait and every
        # body read must be bounded by the caller's own deadline plus a
        # bounded child-process overhead, not by the framework's timers.
        $server = New-ChunkedTrickleServer -IntervalMs 200
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri        = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ServerInfoTimeoutSec = 2
                LockTimeoutSec       = 15
            } -TimeoutSec 60
            $stopwatch.Stop()
            $refusal = Get-RecoverError $result
            Assert-Equal 'ServerInfoUnavailable' $refusal.Reason 'reason'
            Assert-Equal 200 $refusal.Observed.ServerInfoHttp 'observed http status'
            Assert-Equal $null $refusal.Observed.CurrentGame 'no currentgame from an incomplete chunked body'
            # Wall time includes starting the child powershell; the deadline
            # itself is 2s (bounded precisely by the extracted-function test
            # below).
            Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 12) ('Recover returned within the deadline plus overhead, took {0:N1}s' -f $stopwatch.Elapsed.TotalSeconds)
            # The lock was released: a following Start is not Busy.
            $followUp = Invoke-GsProductJson -Action 'Start' -Layout $layout -Extra @{ LockTimeoutSec = 1 }
            Assert-True $followUp.Success 'following Start is not Busy, so the lock was released'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Get-GsServerInfo aborts a chunked trickle within the deadline (AST in a bounded child)' {
        $server = New-ChunkedTrickleServer -IntervalMs 200
        try {
            $command = $serverInfoChildTemplate.Replace('__GSPRODUCT__', $gsProductPath).Replace('__PORT__', [string]$server.Port)
            # A hard 20s outer bound: on the old synchronous read this call
            # never returns (the chunk-extension trickle resets every read
            # wait), and the test must fail instead of hanging the suite.
            $raw = Invoke-ChildPowerShell -Command $command -TimeoutSec 20
            Assert-Equal 0 $raw.ExitCode 'the serverinfo functions ran in the child'
            $line = @($raw.StdOut -split "`r?`n") | Where-Object { $_.StartsWith('RESULT ') } | Select-Object -First 1
            Assert-True ($null -ne $line) ('RESULT line printed: {0}' -f $raw.StdOut)
            Assert-True ($line -like '*error=Timeout*') ('the error is a Timeout: {0}' -f $line)
            $elapsedMs = 0
            if ($line -match 'elapsedMs=(\d+)') { $elapsedMs = [int]$Matches[1] }
            Assert-True ($elapsedMs -gt 0 -and $elapsedMs -lt 4000) ('aborted within TimeoutSec + 2s, took {0}ms' -f $elapsedMs)
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover refuses with ClientConnected when a client connection is active' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $client = $null
        $serverSide = $null
        try {
            $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect('127.0.0.1', $port)
            $serverSide = $listener.AcceptTcpClient()
            Wait-Until -Condition { Test-HasEstablishedLocalConnection -Port $port } -TimeoutSec 15 -Message 'established loopback connection was not observed'
            $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '1')
            try {
                $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                    ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                    ClientPorts   = @($port)
                }
                $refusal = Get-RecoverError $result
                Assert-Equal 'ClientConnected' $refusal.Reason 'reason'
                Assert-Equal 1 $refusal.Observed.ActiveConnections 'observed active connections'
                Assert-Equal 'TcpOnly' $refusal.Observed.ConnectionCheckScope 'connection check scope is reported'
                Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
            } finally {
                Stop-FakeHttpServer -Server $server
            }
        } finally {
            if ($null -ne $client) { $client.Close() }
            if ($null -ne $serverSide) { $serverSide.Close() }
            $listener.Stop()
        }
    }

    Invoke-Test 'Recover refuses client port sets that check nothing or are invalid' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '1')
        try {
            $uri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
            $empty = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{ ServerInfoUri = $uri; ClientPorts = @() }
            $refusal = Get-RecoverError $empty
            Assert-Equal 'ConnectionCheckFailed' $refusal.Reason 'empty set is refused'
            Assert-True ($refusal.Message -like '*no client ports to check*') 'empty set message'
            Assert-Equal $null $refusal.Observed.ActiveConnections 'no connection count was fabricated'
            $onlyPoll = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{ ServerInfoUri = $uri; ClientPorts = @(47989) }
            $refusal2 = Get-RecoverError $onlyPoll
            Assert-Equal 'ConnectionCheckFailed' $refusal2.Reason '47989-only set is refused'
            Assert-True ($refusal2.Message -like '*no client ports to check*') '47989-only message'
            $invalid = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{ ServerInfoUri = $uri; ClientPorts = @(70000) }
            $refusal3 = Get-RecoverError $invalid
            Assert-Equal 'ConnectionCheckFailed' $refusal3.Reason 'invalid port is refused'
            Assert-True ($refusal3.Message -like '*invalid client port: 70000*') 'invalid port message'
            Assert-Equal $null $refusal3.Observed.ActiveConnections 'no connection count was fabricated'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Client port validation rejects invalid and empty check sets (extracted via AST)' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsActiveClientConnectionCount')
        $invalidSets = @()
        $invalidSets += , @([int]0)
        $invalidSets += , @([int]70000)
        $invalidSets += , @([int]-1)
        $invalidSets += , @([int]47990, [int]70000)
        foreach ($badSet in $invalidSets) {
            $threw = $null
            try { $null = Get-GsActiveClientConnectionCount -Ports ([int[]]$badSet) } catch { $threw = $_ }
            Assert-True ($null -ne $threw) ('invalid port set rejected: {0}' -f (($badSet | ForEach-Object { [string]$_ }) -join ','))
            Assert-True ($threw.Exception.Message -like 'invalid client port:*') 'invalid port message'
        }
        $emptySets = @()
        $emptySets += , @()
        $emptySets += , @([int]47989)
        $emptySets += , @([int]47989, [int]47989)
        foreach ($emptySet in $emptySets) {
            $threw = $null
            try { $null = Get-GsActiveClientConnectionCount -Ports ([int[]]$emptySet) } catch { $threw = $_ }
            Assert-True ($null -ne $threw) 'empty check set rejected'
            Assert-Equal 'no client ports to check' $threw.Exception.Message 'empty check set message'
        }
    }

    # ---------------- Recover allowed paths ----------------

    Invoke-Test 'Recover stops then starts exactly once and removes the pause flag it created' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        # Both runtime scripts write two output lines (black-box stream
        # output); Recover must still pick the structured result objects.
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop_output'), "RESULT OK`r`nprivate stack stopped", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'start_output'), "RESULT OK`r`nprivate stack started", $utf8)
        $unusedPort = Get-UnusedTcpPort
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '1')
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ClientPorts   = @($unusedPort)
            }
            Assert-True $result.Success 'Recover succeeds'
            Assert-Equal 0 $result.Data.StopExitCode 'stop exit code'
            Assert-Equal 0 $result.Data.StartExitCode 'start exit code'
            Assert-Equal 'ready' $result.Data.Observed.StatusState 'observed status state'
            Assert-Equal 200 $result.Data.Observed.ServerInfoHttp 'observed serverinfo http'
            Assert-Equal '1' $result.Data.Observed.CurrentGame 'observed currentgame'
            Assert-Equal 0 $result.Data.Observed.ActiveConnections 'observed active connections'
            Assert-Equal 'TcpOnly' $result.Data.Observed.ConnectionCheckScope 'connection check scope is reported'
            $entries = @(Get-MarkerEntries -Layout $layout)
            Assert-Equal 2 $entries.Count 'exactly one stop and one start'
            Assert-Equal 'stop' $entries[0].Action 'stop runs first'
            Assert-Equal 'start' $entries[1].Action 'start runs second'
            Assert-True ($entries[0].EndTicks -le $entries[1].StartTicks) 'stop completes before start begins'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'supervisor_pause.flag'))) 'no pause flag left at the legacy root after Recover'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'runtime\state\supervisor_pause.flag'))) 'pause flag removed from the canonical location after Recover'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover keeps a pause flag that existed before the recovery' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $pausePath = Join-Path $layout.StateDir 'supervisor_pause.flag'
        [System.IO.File]::WriteAllText($pausePath, 'pre-existing', $utf8)
        $unusedPort = Get-UnusedTcpPort
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '1')
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ClientPorts   = @($unusedPort)
            }
            Assert-True $result.Success 'Recover succeeds'
            Assert-True (Test-Path -LiteralPath $pausePath) 'pre-existing pause flag is still present'
            Assert-Equal 'pre-existing' ([System.IO.File]::ReadAllText($pausePath)) 'pre-existing pause flag content untouched'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'runtime\state\supervisor_pause.flag'))) 'no canonical pause flag was created or left behind'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover reports RecoverCleanupFailed when the pause flag cannot be removed' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        # A stop script that waits until the product-created pause flag exists,
        # signals the test, and then waits for a release file: a deterministic
        # window in which the test can hold the flag open (FileShare.None) so
        # that Recover's cleanup Remove-Item fails.
        $waitingStop = @'
$ErrorActionPreference = 'Stop'
$state = '__STATE__'
$utf8Local = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $state 'stop.begun'), [string]$PID, $utf8Local)
$flag = Join-Path $state 'runtime\state\supervisor_pause.flag'
$deadline = [System.DateTime]::UtcNow.AddSeconds(30)
while (-not [System.IO.File]::Exists($flag) -and [System.DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
[System.IO.File]::WriteAllText((Join-Path $state 'stop.waiting'), 'flag exists', $utf8Local)
$deadline = [System.DateTime]::UtcNow.AddSeconds(60)
while (-not [System.IO.File]::Exists((Join-Path $state 'stop.release')) -and [System.DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
$line = 'stop|{0}|{1}|{2}|0|False' -f $PID, [System.DateTime]::UtcNow.Ticks, [System.DateTime]::UtcNow.Ticks
[System.IO.File]::AppendAllText((Join-Path $state 'lifecycle-marker.log'), $line + [System.Environment]::NewLine, $utf8Local)
exit 0
'@.Replace('__STATE__', $layout.StateDir)
        $bin = Join-Path $layout.StateDir 'runtime\bin'
        [System.IO.File]::WriteAllText((Join-Path $bin 'gs_stop_private.ps1'), $waitingStop, $utf8)
        $unusedPort = Get-UnusedTcpPort
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '1')
        $heldStream = $null
        try {
            $recoverChild = Start-GsProductChild -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ClientPorts   = @($unusedPort)
            }
            Wait-Until -Condition { Test-Path -LiteralPath (Join-Path $layout.StateDir 'stop.waiting') } -TimeoutSec 45 -Message 'stop script did not reach its waiting marker'
            $flagPath = Join-Path $layout.StateDir 'runtime\state\supervisor_pause.flag'
            Assert-True (Test-Path -LiteralPath $flagPath) 'pause flag exists at the canonical location while the stop script waits'
            $heldStream = [System.IO.File]::Open($flagPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop.release'), 'go', $utf8)
            $result = Complete-GsProductJson -Child $recoverChild -TimeoutSec 90
            Assert-True (-not $result.Success) 'Recover reports failure when the cleanup fails'
            $cleanupErrors = @($result.Errors | Where-Object { $_.Code -eq 'RecoverCleanupFailed' })
            Assert-Equal 1 $cleanupErrors.Count 'exactly one RecoverCleanupFailed error'
            Assert-Equal $flagPath $cleanupErrors[0].Path 'error names the pause-flag path'
            Assert-Equal 0 $result.Data.StartExitCode 'the start step itself still succeeded'
            Assert-Equal 0 $result.Data.StopExitCode 'the stop step itself still succeeded'
        } finally {
            if ($null -ne $heldStream) { try { $heldStream.Dispose() } catch { } }
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover does not start when the stop step fails' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop_throw'), '1', $utf8)
        $unusedPort = Get-UnusedTcpPort
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '1')
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ClientPorts   = @($unusedPort)
            }
            Assert-True (-not $result.Success) 'Recover fails'
            Assert-Equal 'RecoverStopFailed' $result.Errors[0].Code 'error code'
            $entries = @(Get-MarkerEntries -Layout $layout)
            Assert-Equal 0 @($entries | Where-Object { $_.Action -eq 'start' }).Count 'start never ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover reports RecoverStopFailed when the stop script writes output and exits 3' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        # Stream output before failing: Recover must pick the structured
        # result object, not the output lines, and must not start.
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop_output'), "RESULT OK`r`npartial stop output", $utf8)
        [System.IO.File]::WriteAllText((Join-Path $layout.StateDir 'stop_exit'), '3', $utf8)
        $unusedPort = Get-UnusedTcpPort
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '1')
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ClientPorts   = @($unusedPort)
            }
            Assert-True (-not $result.Success) 'Recover fails'
            Assert-Equal 'RecoverStopFailed' $result.Errors[0].Code 'error code'
            Assert-Equal 3 $result.Data.StopExitCode 'stop exit code from the picked result object'
            Assert-Equal $null $result.Data.StartExitCode 'start exit code is null'
            $entries = @(Get-MarkerEntries -Layout $layout)
            Assert-Equal 0 @($entries | Where-Object { $_.Action -eq 'start' }).Count 'start never ran'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Recover reports Busy while the lock is held' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $holder = New-LockHolder -Layout $layout -Tag 'recover-busy'
        try {
            Wait-LockHolderReady -Holder $holder
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{ LockTimeoutSec = 1 }
            Assert-True (-not $result.Success) 'Recover refused'
            Assert-Equal 'Busy' $result.Errors[0].Code 'Busy code'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran'
        } finally {
            [System.IO.File]::WriteAllText($holder.Release, 'go', $utf8)
            try { $null = Complete-LockHolder -Holder $holder } catch { }
        }
    }

    # ---------------- Diagnose ----------------

    Invoke-Test 'Diagnose reports DiagnoseUnavailable when the script is missing' {
        $layout = New-TempLayout
        $missing = Join-Path $workDir 'no-such-diagnose.ps1'
        $result = Invoke-GsProductJson -Action 'Diagnose' -Layout $layout -Extra @{ DiagnoseScript = $missing }
        Assert-True (-not $result.Success) 'Diagnose fails'
        Assert-Equal 'DiagnoseUnavailable' $result.Errors[0].Code 'error code'
        Assert-Equal ('gs-diagnose.ps1 not found at ' + $missing) $result.Errors[0].Message 'message names the missing path'
    }

    Invoke-Test 'Diagnose returns the report object from the script' {
        $layout = New-TempLayout
        $diagnoseScript = Join-Path $workDir ('fake-diagnose-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = "param([string]`$InstallDir, [string]`$StateDir, [string]`$LogDir, [string]`$ServerInfoUri)`r`n[pscustomobject]@{ schemaVersion = 1; ok = `$true; stateDirSeen = `$StateDir; serverInfoUriSeen = `$ServerInfoUri }"
        [System.IO.File]::WriteAllText($diagnoseScript, $body, $utf8)
        $result = Invoke-GsProductJson -Action 'Diagnose' -Layout $layout -Extra @{ DiagnoseScript = $diagnoseScript }
        Assert-True $result.Success 'Diagnose succeeds'
        Assert-Equal 'True' ([string]$result.Data.ok) 'report ok flag'
        Assert-Equal $layout.StateDir $result.Data.stateDirSeen 'report received the StateDir'
        Assert-Equal 'http://127.0.0.1:47989/serverinfo' $result.Data.serverInfoUriSeen 'report received the default ServerInfoUri'
    }

    Invoke-Test 'Diagnose reports DiagnoseFailed when the script throws' {
        $layout = New-TempLayout
        $diagnoseScript = Join-Path $workDir ('fake-diagnose-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = "param([string]`$InstallDir, [string]`$StateDir, [string]`$LogDir, [string]`$ServerInfoUri)`r`nthrow 'synthetic diagnose failure'"
        [System.IO.File]::WriteAllText($diagnoseScript, $body, $utf8)
        $result = Invoke-GsProductJson -Action 'Diagnose' -Layout $layout -Extra @{ DiagnoseScript = $diagnoseScript }
        Assert-True (-not $result.Success) 'Diagnose fails'
        Assert-Equal 'DiagnoseFailed' $result.Errors[0].Code 'error code'
        Assert-True ($result.Errors[0].Message -like '*synthetic diagnose failure*') 'message carries the failure'
    }

    Invoke-Test 'Diagnose reports DiagnoseFailed with ExitCode when the script exits 3' {
        $layout = New-TempLayout
        $diagnoseScript = Join-Path $workDir ('fake-diagnose-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = "param([string]`$InstallDir, [string]`$StateDir, [string]`$LogDir, [string]`$ServerInfoUri)`r`n[pscustomobject]@{ schemaVersion = 1; ok = `$true }`r`nexit 3"
        [System.IO.File]::WriteAllText($diagnoseScript, $body, $utf8)
        $result = Invoke-GsProductJson -Action 'Diagnose' -Layout $layout -Extra @{ DiagnoseScript = $diagnoseScript }
        Assert-True (-not $result.Success) 'Diagnose fails on a non-zero exit'
        Assert-Equal 'DiagnoseFailed' $result.Errors[0].Code 'error code'
        Assert-Equal 3 $result.Errors[0].ExitCode 'error entry carries the exit code'
    }

    Invoke-Test 'Diagnose rejects a script that returns a plain string' {
        $layout = New-TempLayout
        $diagnoseScript = Join-Path $workDir ('fake-diagnose-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = "param([string]`$InstallDir, [string]`$StateDir, [string]`$LogDir, [string]`$ServerInfoUri)`r`nWrite-Output 'just a string'"
        [System.IO.File]::WriteAllText($diagnoseScript, $body, $utf8)
        $result = Invoke-GsProductJson -Action 'Diagnose' -Layout $layout -Extra @{ DiagnoseScript = $diagnoseScript }
        Assert-True (-not $result.Success) 'Diagnose fails on a non-object report'
        Assert-Equal 'DiagnoseFailed' $result.Errors[0].Code 'error code'
        Assert-True ($result.Errors[0].Message -like '*Unexpected report*') 'message says the report is unexpected'
    }

    Invoke-Test 'Diagnose rejects a report without schemaVersion 1' {
        $layout = New-TempLayout
        $diagnoseScript = Join-Path $workDir ('fake-diagnose-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = "param([string]`$InstallDir, [string]`$StateDir, [string]`$LogDir, [string]`$ServerInfoUri)`r`n[pscustomobject]@{ ok = `$true }"
        [System.IO.File]::WriteAllText($diagnoseScript, $body, $utf8)
        $result = Invoke-GsProductJson -Action 'Diagnose' -Layout $layout -Extra @{ DiagnoseScript = $diagnoseScript }
        Assert-True (-not $result.Success) 'Diagnose fails without schemaVersion 1'
        Assert-Equal 'DiagnoseFailed' $result.Errors[0].Code 'error code'
        Assert-True ($result.Errors[0].Message -like '*schemaVersion 1*') 'message names the schema requirement'
    }

    Invoke-Test 'Diagnose works when a module manifest is invalid (no module dependency)' {
        # A temp install whose Modules\GsRuntime\GsRuntime.psd1 is invalid:
        # the import loop would throw before any action; Diagnose must still
        # return the fake report.
        $install = New-BrokenModuleInstall -Mode 'InvalidManifest'
        $diagnoseScript = New-FakeDiagnoseScript
        $layout = New-TempLayout
        $command = ("& '{0}' -Action Diagnose -InstallDir '{1}' -StateDir '{2}' -LogDir '{3}' -SupervisorTaskName '' -StopSettleSec 0 -DiagnoseScript '{4}' | ConvertTo-Json -Depth 8" -f `
                (Join-Path $install 'gs-product.ps1'), $install, $layout.StateDir, $layout.LogDir, $diagnoseScript)
        $raw = Invoke-ChildPowerShell -Command $command
        Assert-Equal 0 $raw.ExitCode 'gs-product exits 0 on the broken install'
        $result = ConvertFrom-Json -InputObject $raw.StdOut
        Assert-True $result.Success 'Diagnose succeeds without the modules'
        Assert-Equal 'fake' $result.Data.source 'Diagnose returned the fake report'
    }

    Invoke-Test 'Diagnose reports DiagnoseUnavailable when the manifest is missing and gs-diagnose.ps1 is absent' {
        # No -DiagnoseScript: the default gs-diagnose.ps1 next to the copied
        # gs-product.ps1 does not exist, so the refusal (not a throw) is the
        # contract.
        $install = New-BrokenModuleInstall -Mode 'MissingManifest'
        $layout = New-TempLayout
        $command = ("& '{0}' -Action Diagnose -InstallDir '{1}' -StateDir '{2}' -LogDir '{3}' -SupervisorTaskName '' -StopSettleSec 0 | ConvertTo-Json -Depth 8" -f `
                (Join-Path $install 'gs-product.ps1'), $install, $layout.StateDir, $layout.LogDir)
        $raw = Invoke-ChildPowerShell -Command $command
        Assert-Equal 0 $raw.ExitCode 'gs-product exits 0 with a structured result'
        $result = ConvertFrom-Json -InputObject $raw.StdOut
        Assert-True (-not $result.Success) 'Diagnose fails'
        Assert-Equal 'DiagnoseUnavailable' $result.Errors[0].Code 'error code'
        Assert-Equal ('gs-diagnose.ps1 not found at ' + (Join-Path $install 'gs-diagnose.ps1')) $result.Errors[0].Message 'message names the default path'
    }

    # ---------------- Runtime status path lookup ----------------

    Invoke-Test 'Status reads runtime\state\status.json when only it exists' {
        $layout = New-TempLayout
        Write-StatusFile -Layout $layout -Which 'RuntimeState' -Source 'runtimeState'
        $result = Invoke-GsProductJson -Action 'Status' -Layout $layout
        Assert-True $result.Success 'Status succeeds'
        Assert-Equal 'runtimeState' $result.Data.source 'runtime-state file was read'
    }

    Invoke-Test 'Status reads the state-dir status.json when only it exists' {
        $layout = New-TempLayout
        Write-StatusFile -Layout $layout -Which 'StateDir' -Source 'stateDir'
        $result = Invoke-GsProductJson -Action 'Status' -Layout $layout
        Assert-True $result.Success 'Status succeeds'
        Assert-Equal 'stateDir' $result.Data.source 'state-dir file was read'
    }

    Invoke-Test 'Status prefers the newer file when both status paths exist' {
        $layout = New-TempLayout
        Write-StatusFile -Layout $layout -Which 'RuntimeState' -Source 'runtimeState'
        Start-Sleep -Milliseconds 150
        Write-StatusFile -Layout $layout -Which 'StateDir' -Source 'stateDir'
        $result = Invoke-GsProductJson -Action 'Status' -Layout $layout
        Assert-True $result.Success 'Status succeeds'
        Assert-Equal 'stateDir' $result.Data.source 'newer state-dir file wins'
        Start-Sleep -Milliseconds 150
        Write-StatusFile -Layout $layout -Which 'RuntimeState' -Source 'runtimeState'
        $result2 = Invoke-GsProductJson -Action 'Status' -Layout $layout
        Assert-True $result2.Success 'Status succeeds again'
        Assert-Equal 'runtimeState' $result2.Data.source 'rewritten runtime-state file wins'
    }

    # ---------------- Test runner: tests/Invoke-All.ps1 ----------------
    # Each test runs the real runner against fixture folders under %TEMP% in
    # a child powershell.exe with a hard 60s outer timeout, so a runner
    # regression fails the test instead of hanging the suite.

    Invoke-Test 'Invoke-All fails a hanging test within its timeout' {
        $dir = New-RunnerFixtureDir -Tag 'hang'
        Write-TestFixture -Path (Join-Path $dir 'Invoke-HangTests.ps1') -Body $hangFixtureBody
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -TestTimeoutSec 3' -f $dir) -TimeoutSec 60
        $stopwatch.Stop()
        Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 20) ('Invoke-All finished within 20s, took {0:N1}s' -f $stopwatch.Elapsed.TotalSeconds)
        Assert-True ($raw.StdOut.Contains('FAIL Invoke-HangTests.ps1 :: timed out after 3s (child killed)')) 'timeout FAIL line printed'
        Assert-True ($raw.StdOut.Contains('Total: 0 passed, 0 skipped, 1 failed')) 'total line counts the timeout as failed'
        Assert-Equal 1 $raw.ExitCode 'Invoke-All exits 1 when a test times out'
    }

    Invoke-Test 'Invoke-All survives a test whose detached grandchild outlives the kill' {
        $dir = New-RunnerFixtureDir -Tag 'grandchild'
        $pidFile = Join-Path $workDir ('grandchild-' + [guid]::NewGuid().ToString('N') + '.pid')
        Write-TestFixture -Path (Join-Path $dir 'grandchild-sleep.ps1') -Body ($grandchildSleepFixtureBody.Replace('__PIDFILE__', $pidFile))
        Write-TestFixture -Path (Join-Path $dir 'grandchild-intermediate.ps1') -Body ($grandchildIntermediateFixtureBody.Replace('__GRANDCHILD__', (Join-Path $dir 'grandchild-sleep.ps1')).Replace('__PIDFILE__', $pidFile))
        Write-TestFixture -Path (Join-Path $dir 'Invoke-GrandchildTests.ps1') -Body ($grandchildMainFixtureBody.Replace('__INTERMEDIATE__', (Join-Path $dir 'grandchild-intermediate.ps1')).Replace('__PIDFILE__', $pidFile))
        $grandchildPid = $null
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            # Timeout 10s: the intermediate powershell must have exited (and
            # detached the grandchild from this fixture's process tree) well
            # before the runner's taskkill /T lands, even under load.
            $raw = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -TestTimeoutSec 10' -f $dir) -TimeoutSec 60 -DeferredOutput
            $stopwatch.Stop()
            Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 25) ('Invoke-All finished within 25s, took {0:N1}s' -f $stopwatch.Elapsed.TotalSeconds)
            Wait-Until -Condition { Test-Path -LiteralPath $pidFile } -TimeoutSec 15 -Message 'grandchild did not record its PID'
            $grandchildPid = [int]([System.IO.File]::ReadAllText($pidFile).Trim())
            # Kill the leftover grandchild by its recorded PID only, and only
            # after confirming the process name. It must die (and be fully
            # gone) before the output files are read: it inherited the
            # redirect handles, and Stop-Process returns before the kernel
            # has released them.
            try {
                $orphan = Get-Process -Id $grandchildPid -ErrorAction Stop
                if ($orphan.ProcessName -eq 'powershell') {
                    Stop-Process -Id $grandchildPid -Force -ErrorAction SilentlyContinue
                }
            } catch { }
            Wait-Until -Condition { $null -eq (Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue) } -TimeoutSec 10 -Message 'grandchild did not exit after the kill'
            $grandchildPid = $null
            $raw.StdOut = Read-RunnerLogFile -Path $raw.OutFile
            $raw.StdErr = Read-RunnerLogFile -Path $raw.ErrFile
            Assert-True ($raw.StdOut.Contains('FAIL Invoke-GrandchildTests.ps1 :: timed out after 10s (child killed)')) 'timeout FAIL line printed'
            Assert-True ($raw.StdOut.Contains('Total: 0 passed, 0 skipped, 1 failed')) 'total line counts the timeout as failed'
            Assert-Equal 1 $raw.ExitCode 'Invoke-All exits 1 when a test times out'
            # The runner relays child output only through the saved
            # full-output log (and the kept-file lines); read that log to
            # prove the tail was captured readably while the detached
            # grandchild still held the file, then clean it up.
            $fullLogMatch = [regex]::Match($raw.StdOut, 'full output: (.+)')
            Assert-True $fullLogMatch.Success 'the runner saved the full output log'
            $fullLogPath = $fullLogMatch.Groups[1].Value.Trim()
            Assert-True ([System.IO.File]::Exists($fullLogPath)) 'the saved full-output log exists'
            $fullLog = [System.IO.File]::ReadAllText($fullLogPath)
            Assert-True ($fullLog.Contains('grandchild fixture: leaving a detached grandchild holding the output pipe')) 'captured output tail is readable while the detached grandchild lives'
            try { if ([System.IO.File]::Exists($fullLogPath)) { [System.IO.File]::Delete($fullLogPath) } } catch { }
            # The runner could not delete its child output temp files while
            # the grandchild still held them open; it must have said so. The
            # grandchild is gone now, so they are safe to remove here.
            $keptChildOutputFiles = @([regex]::Matches($raw.StdOut, 'child output file kept: (.+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
            Assert-True ($keptChildOutputFiles.Count -gt 0) 'the runner reported the child output files it could not delete'
            foreach ($keptFile in $keptChildOutputFiles) {
                try { if ([System.IO.File]::Exists($keptFile)) { [System.IO.File]::Delete($keptFile) } } catch { }
            }
        } finally {
            # Kill the leftover grandchild by its recorded PID only, and only
            # after confirming the process name.
            if ($null -ne $grandchildPid -and $grandchildPid -gt 0) {
                try {
                    $orphan = Get-Process -Id $grandchildPid -ErrorAction Stop
                    if ($orphan.ProcessName -eq 'powershell') {
                        Stop-Process -Id $grandchildPid -Force -ErrorAction SilentlyContinue
                    }
                } catch { }
            }
        }
    }

    Invoke-Test 'Invoke-All reports a passing fixture with its Summary line' {
        $dir = New-RunnerFixtureDir -Tag 'pass'
        Write-TestFixture -Path (Join-Path $dir 'Invoke-PassTests.ps1') -Body $passFixtureBody
        Write-TestFixture -Path (Join-Path $dir 'Invoke-PassingTests.ps1') -Body $passFixtureBody
        Write-TestFixture -Path (Join-Path $dir 'Invoke-LyingTests.ps1') -Body $lyingFixtureBody
        $raw = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -Name Pass' -f $dir) -TimeoutSec 60
        Assert-Equal 0 $raw.ExitCode 'Invoke-All exits 0'
        Assert-True ($raw.StdOut.Contains('PASS Invoke-PassTests.ps1 (exit 0, ')) 'PASS line with exit code and duration'
        Assert-True ($raw.StdOut.Contains('Summary: 1 passed, 0 failed')) 'child Summary line relayed'
        Assert-True ($raw.StdOut.Contains('Total: 2 passed, 0 skipped, 0 failed')) 'both Pass* fixtures ran'
    }

    Invoke-Test 'Invoke-All marks a passing exit code with a failing Summary as failed' {
        $dir = New-RunnerFixtureDir -Tag 'lying'
        Write-TestFixture -Path (Join-Path $dir 'Invoke-LyingTests.ps1') -Body $lyingFixtureBody
        Write-TestFixture -Path (Join-Path $dir 'Invoke-ExitTests.ps1') -Body $exitFixtureBody
        $raw = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -Name Lying' -f $dir) -TimeoutSec 60
        Assert-Equal 1 $raw.ExitCode 'Invoke-All exits 1'
        Assert-True ($raw.StdOut.Contains('FAIL Invoke-LyingTests.ps1 (exit 0, ') -and $raw.StdOut.Contains(':: summary reports failures')) 'lying Summary marked FAIL'
        Assert-True ($raw.StdOut.Contains('Total: 0 passed, 0 skipped, 1 failed')) 'total line counts the lying Summary as failed'
        # The child's own exit code must survive the cmd.exe wrapper that
        # captures the output into temp files.
        $exitRun = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -Name Exit' -f $dir) -TimeoutSec 60
        Assert-Equal 1 $exitRun.ExitCode 'Invoke-All exits 1 for the non-zero exit'
        Assert-True ($exitRun.StdOut.Contains('FAIL Invoke-ExitTests.ps1 (exit 3, ')) 'child exit code 3 is relayed through the wrapper'
    }

    Invoke-Test 'Invoke-All keeps its working set bounded when a test floods output' {
        $dir = New-RunnerFixtureDir -Tag 'flood'
        Write-TestFixture -Path (Join-Path $dir 'Invoke-FloodTests.ps1') -Body $floodFixtureBody
        # Start the runner without blocking so the suite can sample the
        # runner powershell's working set while Invoke-All runs.
        $run = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -TestTimeoutSec 5' -f $dir) -PassThru
        $cmdProc = $run.Process
        $exitCode = $null
        $maxWorkingSetMb = 0
        try {
            # Discover the runner powershell (the cmd wrapper's child) and
            # sample its working set every 250 ms until Invoke-All exits.
            $runnerPid = $null
            $deadline = [System.DateTime]::UtcNow.AddSeconds(20)
            while ($null -eq $runnerPid) {
                if ($cmdProc.HasExited) { throw 'the Invoke-All cmd wrapper exited before the runner process was found' }
                if ([System.DateTime]::UtcNow -gt $deadline) { throw 'the Invoke-All runner process was not found within 20s' }
                $children = @(Get-CimInstance -ClassName Win32_Process -Filter ('ParentProcessId = {0}' -f $cmdProc.Id) -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'powershell.exe' })
                if ($children.Count -gt 0) { $runnerPid = [int]$children[0].ProcessId } else { Start-Sleep -Milliseconds 100 }
            }
            $deadline = [System.DateTime]::UtcNow.AddSeconds(60)
            while (-not $cmdProc.HasExited) {
                if ([System.DateTime]::UtcNow -gt $deadline) {
                    try { $cmdProc.Kill() } catch { }
                    throw 'the Invoke-All runner did not finish within 60s'
                }
                $runnerProc = Get-Process -Id $runnerPid -ErrorAction SilentlyContinue
                if ($null -ne $runnerProc) {
                    $workingSetMb = [int]($runnerProc.WorkingSet64 / 1MB)
                    if ($workingSetMb -gt $maxWorkingSetMb) { $maxWorkingSetMb = $workingSetMb }
                }
                Start-Sleep -Milliseconds 250
            }
            $exitCode = $cmdProc.ExitCode
        } finally {
            try { $cmdProc.Dispose() } catch { }
        }
        Assert-Equal 1 $exitCode 'Invoke-All exits 1 when a test times out'
        Assert-True ($maxWorkingSetMb -gt 0) 'the runner process was sampled'
        Assert-True ($maxWorkingSetMb -lt 300) ('runner working set stayed under 300 MB, max {0} MB' -f $maxWorkingSetMb)
        $stdout = Read-RunnerLogFile -Path $run.OutFile
        Assert-True ($stdout.Contains('FAIL Invoke-FloodTests.ps1 :: timed out after 5s (child killed)')) 'timeout FAIL line printed'
        Assert-True ($stdout.Contains('Total: 0 passed, 0 skipped, 1 failed')) 'total line counts the timeout as failed'
        foreach ($logFile in @($run.OutFile, $run.ErrFile)) {
            try { if ([System.IO.File]::Exists($logFile)) { [System.IO.File]::Delete($logFile) } } catch { }
        }
    }

    Invoke-Test 'Invoke-All -Name -Exact matches by exact file or base name' {
        $dir = New-RunnerFixtureDir -Tag 'exact'
        Write-TestFixture -Path (Join-Path $dir 'Invoke-PassTests.ps1') -Body $passFixtureBody
        Write-TestFixture -Path (Join-Path $dir 'Invoke-PassingTests.ps1') -Body $passFixtureBody
        # Substring 'Pass' selects both Pass* fixtures; -Exact 'Pass' selects
        # neither, so 'Stage1' no longer drags in 'Stage12' style matches.
        $substring = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -Name Pass' -f $dir) -TimeoutSec 60
        Assert-Equal 0 $substring.ExitCode 'substring -Name Pass runs the fixtures'
        Assert-True ($substring.StdOut.Contains('Total: 2 passed, 0 skipped, 0 failed')) 'substring matched both fixtures'
        $exactNone = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -Name Pass -Exact' -f $dir) -TimeoutSec 60
        Assert-Equal 1 $exactNone.ExitCode '-Name Pass -Exact finds no file named Pass'
        Assert-True ($exactNone.StdOut.Contains('No test files found')) 'no-match message printed'
        $exactFile = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -Name Invoke-PassTests.ps1 -Exact' -f $dir) -TimeoutSec 60
        Assert-Equal 0 $exactFile.ExitCode 'exact file name matches one'
        Assert-True ($exactFile.StdOut.Contains('Total: 1 passed, 0 skipped, 0 failed')) 'exactly one fixture ran (file name)'
        $exactBase = Invoke-AllRunner -ExtraArgs ('-TestsDir ''{0}'' -Name Invoke-PassTests -Exact' -f $dir) -TimeoutSec 60
        Assert-Equal 0 $exactBase.ExitCode 'exact base name matches one'
        Assert-True ($exactBase.StdOut.Contains('Total: 1 passed, 0 skipped, 0 failed')) 'exactly one fixture ran (base name)'
    }

    # ---------------- PrepareUninstall (K5) ----------------
    # The real scheduled-task path (Get-/Unregister-ScheduledTask) is NEVER
    # exercised here; the one test that passes a non-empty -SupervisorTaskName
    # uses a unique 'GsCoordTest-<guid>' name that cannot exist AND the
    # -AssumeNotElevated seam, which refuses before any cmdlet can run. The
    # real task-removal path stays for the operator's VM verification.

    Invoke-Test 'PrepareUninstall with an empty task name stops only and reports the task as absent' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $result = Invoke-GsProductJson -Action 'PrepareUninstall' -Layout $layout
        Assert-True $result.Success 'PrepareUninstall succeeds'
        Assert-True $result.Data.Stopped 'Stopped is true'
        Assert-Equal $false $result.Data.TaskRemoved 'TaskRemoved is false'
        Assert-Equal $false $result.Data.TaskExisted 'TaskExisted is false'
        Assert-Equal $true $result.Data.StateDirKept 'StateDirKept is true'
        Assert-Equal $true $result.Data.LogDirKept 'LogDirKept is true'
        $entries = @(Get-MarkerEntries -Layout $layout)
        Assert-Equal 1 @($entries | Where-Object { $_.Action -eq 'stop' }).Count 'exactly one stop ran'
        Assert-Equal 0 @($entries | Where-Object { $_.Action -eq 'start' }).Count 'no start ran'
        Assert-True (Test-Path -LiteralPath (Join-Path $layout.StateDir 'runtime\state\supervisor_pause.flag')) 'the canonical pause flag is kept'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'supervisor_pause.flag'))) 'no pause flag was created at the legacy root'
    }

    Invoke-Test 'PrepareUninstall refuses with ElevationRequired before anything runs when a task would be removed (-AssumeNotElevated seam)' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        # A unique name that cannot exist, never GsControllerSupervisor; the
        # seam forces the not-elevated outcome so the refusal happens before
        # any scheduled-task cmdlet could run.
        $fakeTaskName = 'GsCoordTest-' + [guid]::NewGuid().ToString('N')
        $result = Invoke-GsProductJson -Action 'PrepareUninstall' -Layout $layout -Extra @{
            SupervisorTaskName = $fakeTaskName
            AssumeNotElevated   = $true
        }
        Assert-True (-not $result.Success) 'PrepareUninstall fails'
        Assert-Equal 'ElevationRequired' $result.Errors[0].Code 'the error code is ElevationRequired'
        Assert-Equal $fakeTaskName $result.Errors[0].TaskName 'the error names the task'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'nothing ran: no stop script, no task query'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'stop.begun'))) 'the stop script never began'
    }

    Invoke-Test 'PrepareUninstall elevation decision cannot be forced to elevated (extracted via AST + seam)' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'Test-GsPrepareUninstallElevation')
        # The seam must force "not elevated" regardless of the real token
        # (this suite runs elevated, so the plain call is the contrast case).
        Assert-Equal $false (Test-GsPrepareUninstallElevation -AssumeNotElevated) 'the seam forces not-elevated'
        if (Test-IsElevated) {
            Assert-Equal $true (Test-GsPrepareUninstallElevation) 'the plain call follows the real token'
        }
        # Static check: the only boolean constant the function can return is
        # $false; the only source of $true is the real-token IsInRole call.
        $fnText = Get-GsProductFunctionText -Name 'Test-GsPrepareUninstallElevation'
        $tokens = $null
        $parseErrors = $null
        $fnAst = [System.Management.Automation.Language.Parser]::ParseInput($fnText, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'the extracted function parses'
        Assert-True ($fnText -like '*IsInRole*') 'the decision uses the real process token'
        $returns = $fnAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)
        Assert-True (@($returns).Count -ge 2) ('the function has its two return paths, found {0}' -f @($returns).Count)
        foreach ($returnStatement in @($returns)) {
            $isConstantTrue = ($returnStatement.Pipeline -is [System.Management.Automation.Language.ConstantExpressionAst] -and $returnStatement.Pipeline.Value -eq $true)
            Assert-True (-not $isConstantTrue) 'no return path returns the constant $true'
        }
    }

    Invoke-Test 'PrepareUninstall reports Busy while the lock is held' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        $holder = New-LockHolder -Layout $layout -Tag 'prepare-busy'
        try {
            Wait-LockHolderReady -Holder $holder
            $result = Invoke-GsProductJson -Action 'PrepareUninstall' -Layout $layout -Extra @{ LockTimeoutSec = 1 }
            Assert-True (-not $result.Success) 'PrepareUninstall refused'
            Assert-Equal 'Busy' $result.Errors[0].Code 'Busy code'
            Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no runtime script ran while Busy'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'supervisor_pause.flag'))) 'no pause flag was created at the legacy root while Busy'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.StateDir 'runtime\state\supervisor_pause.flag'))) 'no pause flag was created at the canonical location while Busy'
        } finally {
            [System.IO.File]::WriteAllText($holder.Release, 'go', $utf8)
            try { $null = Complete-LockHolder -Holder $holder } catch { }
        }
    }

    Invoke-Test 'PrepareUninstall skips the stop and says so when the runtime is not deployed' {
        $layout = New-TempLayout
        # No gs_stop_private.ps1: the deployed check (RuntimeBinDir) fails.
        $result = Invoke-GsProductJson -Action 'PrepareUninstall' -Layout $layout
        Assert-True $result.Success 'PrepareUninstall still succeeds (nothing to stop)'
        Assert-Equal $false $result.Data.Stopped 'Stopped is false'
        Assert-Equal 'RuntimeNotDeployed' $result.Data.StopSkippedReason 'the skip reason is recorded'
        Assert-Equal $false $result.Data.TaskRemoved 'TaskRemoved is false'
        Assert-Equal $false $result.Data.TaskExisted 'TaskExisted is false'
        Assert-Equal 0 @(Get-MarkerEntries -Layout $layout).Count 'no stop script ran'
    }

    Invoke-Test 'PrepareUninstall stop-then-remove decision on fake operations (extracted via AST)' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'New-Result')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsUnwrappedException')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsResultFromOutput')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Invoke-GsPrepareUninstallSteps')
        $log = New-Object System.Collections.Generic.List[string]
        $okStop = { $log.Add('stop'); New-Result $true ([pscustomobject]@{ ExitCode = 0; LockAbandoned = $false }) @() }
        $failedStop = { $log.Add('stop'); New-Result $false ([pscustomobject]@{ ExitCode = 3; LockAbandoned = $false }) @([pscustomobject]@{ Code = 'RuntimeStopFailed'; Message = 'synthetic stop failure' }) }
        $skipStop = { $log.Add('none'); New-Result $true ([pscustomobject]@{ ExitCode = $null; LockAbandoned = $false; Skipped = $true }) @() }
        $removingOp = { $log.Add('remove'); [pscustomobject]@{ TaskRemoved = $true; TaskExisted = $true } }
        $absentOp = { $log.Add('remove'); [pscustomobject]@{ TaskRemoved = $false; TaskExisted = $false } }
        $throwingOp = { $log.Add('remove'); throw 'synthetic removal failure' }
        # Path 1: stop ok, task present -> success, both recorded.
        $log.Clear()
        $r1 = Invoke-GsPrepareUninstallSteps -StopOp $okStop -RemoveOp $removingOp
        Assert-True $r1.Success 'path 1 succeeds'
        Assert-True $r1.Data.Stopped 'path 1 Stopped'
        Assert-True $r1.Data.TaskRemoved 'path 1 TaskRemoved'
        Assert-True $r1.Data.TaskExisted 'path 1 TaskExisted'
        Assert-Equal $null $r1.Data.StopSkippedReason 'path 1 has no skip reason'
        Assert-Equal $true $r1.Data.StateDirKept 'path 1 keeps StateDir'
        Assert-Equal $true $r1.Data.LogDirKept 'path 1 keeps LogDir'
        Assert-Equal 2 $log.Count 'path 1 ran stop then remove'

        # Path 2: stop FAILED and removal STILL ran -> failure, stop error
        # first, removal results recorded.
        $log.Clear()
        $r2 = Invoke-GsPrepareUninstallSteps -StopOp $failedStop -RemoveOp $removingOp
        Assert-True (-not $r2.Success) 'path 2 fails'
        Assert-Equal $false $r2.Data.Stopped 'path 2 Stopped is false'
        Assert-Equal 'RuntimeStopFailed' $r2.Errors[0].Code 'path 2 keeps the stop error first'
        Assert-True $r2.Data.TaskRemoved 'path 2 removed the task anyway'
        Assert-True $r2.Data.TaskExisted 'path 2 reports TaskExisted'
        Assert-Equal 2 $log.Count 'path 2 still called the remover after the failed stop'

        # Path 3: remover throws -> TaskRemovalFailed appended, failure.
        $log.Clear()
        $r3 = Invoke-GsPrepareUninstallSteps -StopOp $okStop -RemoveOp $throwingOp
        Assert-True (-not $r3.Success) 'path 3 fails'
        Assert-True $r3.Data.Stopped 'path 3 Stopped stays true'
        Assert-Equal $false $r3.Data.TaskRemoved 'path 3 TaskRemoved is false'
        $removalErrors = @($r3.Errors | Where-Object { $_.Code -eq 'TaskRemovalFailed' })
        Assert-Equal 1 $removalErrors.Count 'path 3 has exactly one TaskRemovalFailed error'
        Assert-True ($removalErrors[0].Message -like '*synthetic removal failure*') 'path 3 message carries the failure'

        # Path 5 (C-B1): a THROWING stop is caught and recorded as
        # RuntimeStopFailed with Stopped = $false, and the removal STILL runs.
        $throwingStop = { $log.Add('stop'); throw 'synthetic stop throw' }
        $log.Clear()
        $r5 = Invoke-GsPrepareUninstallSteps -StopOp $throwingStop -RemoveOp $removingOp
        Assert-True (-not $r5.Success) 'path 5 fails'
        Assert-Equal $false $r5.Data.Stopped 'path 5 Stopped is false'
        Assert-Equal 'RuntimeStopFailed' $r5.Errors[0].Code 'path 5 records RuntimeStopFailed first'
        Assert-True ($r5.Errors[0].Message -like '*synthetic stop throw*') 'path 5 message carries the throw'
        Assert-True $r5.Data.TaskRemoved 'path 5 still removed the task'
        Assert-True $r5.Data.TaskExisted 'path 5 reports TaskExisted'
        Assert-Equal 2 $log.Count 'path 5 still called the remover after the throwing stop'

        # Path 6 (C-B1): a throwing stop with an absent task -> the stop error
        # is recorded, the removal reports the absence, nothing throws.
        $log.Clear()
        $r6 = Invoke-GsPrepareUninstallSteps -StopOp $throwingStop -RemoveOp $absentOp
        Assert-True (-not $r6.Success) 'path 6 fails'
        Assert-Equal 'RuntimeStopFailed' $r6.Errors[0].Code 'path 6 stop error first'
        Assert-Equal $false $r6.Data.TaskRemoved 'path 6 task absent'
        Assert-Equal $false $r6.Data.TaskExisted 'path 6 TaskExisted false'
        Assert-Equal 2 $log.Count 'path 6 ran stop then remove'

        # Skip path: the stop was skipped (not deployed) -> no error, Stopped false.
        $log.Clear()
        $r4 = Invoke-GsPrepareUninstallSteps -StopOp $skipStop -RemoveOp $absentOp
        Assert-True $r4.Success 'the skip path succeeds'
        Assert-Equal $false $r4.Data.Stopped 'the skip path Stopped is false'
        Assert-Equal 'RuntimeNotDeployed' $r4.Data.StopSkippedReason 'the skip path records the reason'
        Assert-Equal $false $r4.Data.TaskRemoved 'the skip path reports the task absent'
    }

    Invoke-Test 'PrepareUninstall task lookup: only the provider not-found outcome counts as absent (extracted via AST)' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'Test-GsTaskNotFoundOutcome')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Invoke-GsTaskRemovalOutcome')
        $removerCalls = New-Object System.Collections.Generic.List[string]
        $removing = { param($Name) $removerCalls.Add('remove-' + $Name); [pscustomobject]@{ Removed = $true } }

        # Not-found classifier: the specific ERROR_FILE_NOT_FOUND outcome.
        $notFoundEx = New-Object System.IO.FileNotFoundException 'synthetic task not found (Exception from HRESULT: 0x80070002)'
        $notFoundEr = New-Object System.Management.Automation.ErrorRecord $notFoundEx, 'TaskNotFound', ([System.Management.Automation.ErrorCategory]::ObjectNotFound), $null
        Assert-True (Test-GsTaskNotFoundOutcome -ErrorRecord $notFoundEr) 'a 0x80070002 error is the not-found outcome'
        $missingEr = $null
        try { Get-ChildItem -LiteralPath (Join-Path $workDir 'definitely-missing-xyz') -ErrorAction Stop } catch { $missingEr = $_ }
        Assert-True (-not (Test-GsTaskNotFoundOutcome -ErrorRecord $missingEr)) 'an unrelated error is NOT the not-found outcome'

        # Path A: the lookup throws the provider's not-found outcome -> the
        # task is reported ABSENT and the remover never runs.
        $absentLookup = {
            param($Name)
            $er = New-Object System.Management.Automation.ErrorRecord (New-Object System.IO.FileNotFoundException 'synthetic task not found (Exception from HRESULT: 0x80070002)'), 'TaskNotFound', ([System.Management.Automation.ErrorCategory]::ObjectNotFound), $Name
            Write-Error -ErrorRecord $er -ErrorAction Stop
        }
        $removerCalls.Clear()
        $absent = Invoke-GsTaskRemovalOutcome -TaskName 'GsCoordTest-nope' -WillRemoveTask:$true -TaskLookup $absentLookup -TaskRemover $removing
        Assert-Equal $false $absent.TaskRemoved 'the absent path reports TaskRemoved = false'
        Assert-Equal $false $absent.TaskExisted 'the absent path reports TaskExisted = false'
        Assert-Equal 0 $removerCalls.Count 'the remover never ran for an absent task'

        # Path B: the lookup returns a task -> it is removed.
        $presentLookup = { param($Name) [pscustomobject]@{ TaskName = $Name; State = 'Ready' } }
        $removerCalls.Clear()
        $present = Invoke-GsTaskRemovalOutcome -TaskName 'GsCoordTest-fake' -WillRemoveTask:$true -TaskLookup $presentLookup -TaskRemover $removing
        Assert-Equal $true $present.TaskRemoved 'the present path removed the task'
        Assert-Equal $true $present.TaskExisted 'the present path reports TaskExisted'
        Assert-Equal 1 $removerCalls.Count 'the remover ran exactly once'
        Assert-Equal 'remove-GsCoordTest-fake' $removerCalls[0] 'the remover received the task name'

        # Path C: any OTHER lookup error -> the outcome function throws so the
        # caller records TaskRemovalFailed (never a confirmed absence).
        $errorLookup = { param($Name) throw 'scheduler communication synthetic failure' }
        $lookupThrew = $null
        try {
            $null = Invoke-GsTaskRemovalOutcome -TaskName 'GsCoordTest-fake' -WillRemoveTask:$true -TaskLookup $errorLookup -TaskRemover $removing
        } catch {
            $lookupThrew = $_
        }
        Assert-True ($null -ne $lookupThrew) 'a lookup error is rethrown, not swallowed'
        Assert-True ($lookupThrew.Exception.Message -like '*scheduled task lookup*failed*') ('the throw names the lookup failure: ' + $lookupThrew.Exception.Message)
        Assert-True ($lookupThrew.Exception.Message -like '*scheduler communication synthetic failure*') 'the throw carries the original failure'

        # Through the real decision function: a RemoveOp backed by a failing
        # lookup must surface as TaskRemovalFailed on the PrepareUninstall
        # result (never as TaskRemoved = $false / Success = $true).
        Invoke-Expression (Get-GsProductFunctionText -Name 'New-Result')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsUnwrappedException')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsResultFromOutput')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Invoke-GsPrepareUninstallSteps')
        $okStopLocal = { New-Result $true ([pscustomobject]@{ ExitCode = 0; LockAbandoned = $false }) @() }
        $wiredRemoveOp = {
            Invoke-GsTaskRemovalOutcome -TaskName 'GsCoordTest-fake' -WillRemoveTask:$true -TaskLookup $errorLookup -TaskRemover $removing
        }
        $wired = Invoke-GsPrepareUninstallSteps -StopOp $okStopLocal -RemoveOp $wiredRemoveOp
        Assert-True (-not $wired.Success) 'a lookup failure fails PrepareUninstall'
        $lookupFailures = @($wired.Errors | Where-Object { $_.Code -eq 'TaskRemovalFailed' })
        Assert-Equal 1 $lookupFailures.Count 'exactly one TaskRemovalFailed error'
        Assert-True ($lookupFailures[0].Message -like '*scheduler communication synthetic failure*') 'the TaskRemovalFailed message carries the lookup failure'

        # No task named => nothing to look up, nothing removed.
        $noop = Invoke-GsTaskRemovalOutcome -TaskName 'GsCoordTest-fake' -WillRemoveTask:$false -TaskLookup $errorLookup -TaskRemover $removing
        Assert-Equal $false $noop.TaskRemoved 'no task named: TaskRemoved = false'
        Assert-Equal $false $noop.TaskExisted 'no task named: TaskExisted = false'

        # Production wiring: the PrepareUninstall switch goes through
        # Invoke-GsTaskRemovalOutcome and no longer suppresses lookup errors
        # with -ErrorAction SilentlyContinue.
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($gsProductPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'gs-product.ps1 parses'
        $switches = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.SwitchStatementAst] }, $true))
        $prepareSwitch = $null
        foreach ($candidate in $switches) {
            if ($candidate.Extent.Text.Contains("'PrepareUninstall'")) { $prepareSwitch = $candidate; break }
        }
        Assert-True ($null -ne $prepareSwitch) 'the action switch containing PrepareUninstall was found'
        $switchText = $prepareSwitch.Extent.Text
        Assert-True ($switchText.Contains('Invoke-GsTaskRemovalOutcome')) 'the production removeOp goes through the lookup decision function'
        Assert-True ($switchText.Contains('SupervisorTaskName')) 'the production removeOp names the task'
        # The old suppressive lookup (specifically the PrepareUninstall one on
        # $SupervisorTaskName) must be gone. UnregisterAutostart keeps its own
        # -ErrorAction SilentlyContinue lookup on $taskName - unchanged, and
        # out of scope here - so the check is pinned to the old exact pattern.
        Assert-True ($switchText -notmatch 'Get-ScheduledTask\s+-TaskName\s+\$SupervisorTaskName\s+-ErrorAction\s+SilentlyContinue') 'the production removeOp no longer suppresses lookup errors'
        # The production defaults in the decision function are the real
        # scheduler cmdlets, called with errors SURFACING (not suppressed).
        $outcomeText = Get-GsProductFunctionText -Name 'Invoke-GsTaskRemovalOutcome'
        Assert-True ($outcomeText.Contains('Get-ScheduledTask')) 'the default lookup is the real Get-ScheduledTask'
        Assert-True ($outcomeText.Contains('-ErrorAction Stop')) 'the real lookup surfaces errors'
        Assert-True ($outcomeText.Contains('Unregister-ScheduledTask')) 'the default remover is the real Unregister-ScheduledTask'
        Assert-True ($outcomeText -notmatch 'SilentlyContinue') 'the decision function never suppresses errors'
    }

    Invoke-Test 'Complete-ChildPowerShell bounds stream draining after exit (extracted via AST, grandchild with deadline)' {
        # The regression target is this suite's own helper: a child whose
        # process exited but whose stdout task never completes (a descendant
        # that inherited the pipe) used to hang the unbounded GetResult
        # forever. The helper therefore runs in a grandchild with a hard
        # deadline: on the old helper the grandchild is killed and this test
        # FAILs instead of hanging the suite.
        $tokens = $null
        $parseErrors = $null
        $selfAst = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'the test file parses'
        $helperNode = $selfAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Complete-ChildPowerShell' }, $true)
        Assert-True ($null -ne $helperNode) 'the Complete-ChildPowerShell helper was found'
        $helperText = $helperNode.Extent.Text
        $grandchildBody = @'
$ErrorActionPreference = 'Stop'
function Start-LocalChild {
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
    return ([pscustomobject]@{
        Process = $process
        OutTask = $process.StandardOutput.ReadToEndAsync()
        ErrTask = $process.StandardError.ReadToEndAsync()
    })
}
# Sanity: a real, completing child still drains and returns normally.
$real = Start-LocalChild -Command 'Write-Output ok; exit 0'
$realResult = Complete-ChildPowerShell -Child $real -TimeoutSec 30
Write-Output ('REAL-OK exit=' + $realResult.ExitCode + ' out=' + $realResult.StdOut.Trim())
# The hang shape: the process exits but the stdout task never completes.
$source = New-Object System.Threading.Tasks.TaskCompletionSource[string]
$quick = Start-LocalChild -Command 'exit 0'
$null = $quick.Process.WaitForExit(15000)
$fake = [pscustomobject]@{ Process = $quick.Process; OutTask = $source.Task; ErrTask = $source.Task }
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $null = Complete-ChildPowerShell -Child $fake -TimeoutSec 2
    Write-Output ('NO-THROW elapsed=' + [int]$stopwatch.Elapsed.TotalSeconds)
} catch {
    Write-Output ('THREW elapsed=' + [int]$stopwatch.Elapsed.TotalSeconds + ' msg=' + $_.Exception.Message)
    try {
        $null = $quick.Process.HasExited
        Write-Output 'NOT-DISPOSED'
    } catch [System.ObjectDisposedException] {
        Write-Output 'DISPOSED'
    } catch {
        Write-Output ('HASEXITED-OTHER ' + $_.Exception.GetType().FullName)
    }
}
exit 0
'@
        $raw = Invoke-ChildPowerShell -Command ($helperText + "`r`n" + $grandchildBody) -TimeoutSec 30
        Assert-True ($raw.StdOut.Contains('REAL-OK exit=0 out=ok')) ('a completing child still works: ' + (($raw.StdOut -split "`r?`n" | Select-Object -First 4) -join ' / '))
        Assert-True ($raw.StdOut.Contains('THREW')) ('the never-completing stream threw instead of hanging: ' + (($raw.StdOut -split "`r?`n" | Select-Object -Last 4) -join ' / '))
        Assert-True ($raw.StdOut -notmatch 'NO-THROW') 'the fake stream did not silently complete'
        $elapsedMatch = [regex]::Match($raw.StdOut, 'THREW elapsed=(\d+)')
        Assert-True ($elapsedMatch.Success -and [int]$elapsedMatch.Groups[1].Value -le 14) ('the drain bound stayed near the deadline, took ' + $elapsedMatch.Groups[1].Value + 's')
        Assert-True ($raw.StdOut.Contains('DISPOSED')) 'the process was disposed on expiry'
    }

    Invoke-Test 'Get-GsServerInfo rejects an HTTP 201 before reading the body (extracted via AST)' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsUnwrappedException')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Read-GsServerInfoBody')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsServerInfo')
        $server = New-FakeHttpServer -StatusCode 201 -Body (New-ServerInfoXml -CurrentGame '1')
        try {
            $info = Get-GsServerInfo -Uri ('http://127.0.0.1:{0}/serverinfo' -f $server.Port) -TimeoutSec 2
            Assert-Equal 201 $info.Http 'the HTTP status was recorded'
            Assert-True (-not [string]::IsNullOrEmpty($info.Error)) 'a 201 response is rejected'
            Assert-True ($info.Error -like '*200*') ('the error names the required status: ' + $info.Error)
            Assert-True ($null -eq $info.CurrentGame) 'no currentgame was parsed from a 201 body'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    # ---------------- Recover outbound-traffic gate (C5) ----------------
    # The gate itself is never run against the real adapters in a test: the
    # suite's Recover calls pass -TrafficSampleSec 0, the rate math is tested
    # on injected counter sequences, and the wiring is pinned statically.

    Invoke-Test 'Recover skips the outbound-traffic gate when -TrafficSampleSec is 0' {
        $layout = New-TempLayout
        Write-FakeRuntimeScripts -Layout $layout
        Set-RuntimeStatus -Layout $layout -State 'ready'
        $unusedPort = Get-UnusedTcpPort
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '1')
        try {
            $result = Invoke-GsProductJson -Action 'Recover' -Layout $layout -Extra @{
                ServerInfoUri    = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                ClientPorts      = @($unusedPort)
                TrafficSampleSec = 0
            }
            Assert-True $result.Success 'Recover succeeds with the traffic gate disabled'
            Assert-Equal $null $result.Data.Observed.SendKbps 'no send rate was sampled'
            $entries = @(Get-MarkerEntries -Layout $layout)
            Assert-Equal 2 $entries.Count 'stop and start ran exactly once each'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Outbound traffic rate and gate logic on injected counter sequences (extracted via AST)' {
        Invoke-Expression (Get-GsProductFunctionText -Name 'Get-GsSendKbpsDelta')
        Invoke-Expression (Get-GsProductFunctionText -Name 'Test-GsClientTrafficGate')
        # Rate math: growth counts, a counter reset and a new adapter do not.
        $before = @{ 'a' = [int64]1000; 'b' = [int64]2000 }
        $after = @{ 'a' = [int64]3000; 'b' = [int64]260000; 'c' = [int64]999999 }
        $rate = Get-GsSendKbpsDelta -Before $before -After $after -Seconds 2
        Assert-Equal 1040 $rate '260000 bytes over 2 s is 1040 Kbps'
        $reset = Get-GsSendKbpsDelta -Before @{ 'a' = [int64]5000 } -After @{ 'a' = [int64]100 } -Seconds 1
        Assert-Equal 0 $reset 'a counter reset contributes zero'
        $gone = Get-GsSendKbpsDelta -Before @{ 'a' = [int64]1000 } -After @{ } -Seconds 1
        Assert-Equal 0 $gone 'a disappeared adapter contributes zero'
        $threw = $null
        try { $null = Get-GsSendKbpsDelta -Before @{ } -After @{ } -Seconds 0 } catch { $threw = $_ }
        Assert-True ($null -ne $threw) 'a non-positive sample length is rejected'
        # Gate over an injected sampler: a queue of two snapshots, no real
        # adapter is ever touched.
        $calls = New-Object System.Collections.Generic.List[string]
        $queue = New-Object System.Collections.Generic.Queue[object]
        $queue.Enqueue(@{ 'a' = [int64]1000 })
        $queue.Enqueue(@{ 'a' = [int64]201000 })
        $sampler = { $calls.Add('sample'); $queue.Dequeue() }
        $gate = Test-GsClientTrafficGate -SampleSec 1 -MaxIdleSendKbps 500 -Sampler $sampler
        Assert-Equal $true $gate.Detected '1600 Kbps exceeds the 500 Kbps idle threshold'
        Assert-Equal 1600 $gate.RateKbps 'the reported rate is 1600 Kbps'
        Assert-Equal 2 $calls.Count 'the sampler was called exactly twice'
        $queue.Enqueue(@{ 'a' = [int64]1000 })
        $queue.Enqueue(@{ 'a' = [int64]1000 })
        $quiet = Test-GsClientTrafficGate -SampleSec 1 -MaxIdleSendKbps 500 -Sampler $sampler
        Assert-Equal $false $quiet.Detected 'a zero rate stays under the threshold'
        Assert-Equal 0 $quiet.RateKbps 'the quiet rate is zero'
        # Disabled gate: no sleep, no sampler call.
        $calls.Clear()
        $off = Test-GsClientTrafficGate -SampleSec 0 -MaxIdleSendKbps 500 -Sampler $sampler
        Assert-Equal $false $off.Detected 'the disabled gate never detects'
        Assert-Equal $null $off.RateKbps 'the disabled gate reports no rate'
        Assert-Equal 0 $calls.Count 'the disabled gate never samples'
    }

    Invoke-Test 'Recover wires the ClientTrafficDetected refusal from the traffic gate (AST source check)' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($gsProductPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'gs-product.ps1 parses'
        $recoverFn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GsLifecycleRecover' }, $true)
        Assert-True ($null -ne $recoverFn) 'Invoke-GsLifecycleRecover exists'
        $text = $recoverFn.Extent.Text
        Assert-True ($text.Contains('$TrafficSampleSec -gt 0')) 'the gate runs only when sampling is enabled'
        Assert-True ($text.Contains('Test-GsClientTrafficGate')) 'the gate calls the traffic check'
        Assert-True ($text.Contains("'ClientTrafficDetected'")) 'the refusal reason is ClientTrafficDetected'
        Assert-True ($text.Contains('SendKbps')) 'the observed send rate is reported'
        # The gate must run AFTER the ClientConnected gate (fourth precondition).
        $clientConnectedPos = $text.IndexOf("'ClientConnected'")
        $trafficPos = $text.IndexOf('Test-GsClientTrafficGate')
        Assert-True ($clientConnectedPos -ge 0 -and $trafficPos -gt $clientConnectedPos) 'the traffic gate is the fourth precondition'
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

Write-Host ("Summary: {0} passed, {1} failed (skipped: {2})" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
