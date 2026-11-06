#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for tools/gs-soak-monitor.ps1: the OutputDir repository guard, Cycle
    mode (plan-only and -Execute against a fake product script), the memory
    slope regression, the tolerant PID-file parser, and Monitor mode end-to-end
    runs against loopback serverinfo fakes and fake role processes.

.DESCRIPTION
    Runs the real tool in child powershell.exe processes with hard timeouts.
    Every fixture lives under %TEMP% (which is outside the repository), every
    serverinfo fake is a loopback TcpListener, and every fake role process is a
    sleeping child powershell.exe whose PID this suite owns and kills. Cycle
    tests never pass -Execute against the real product; they point -ProductPath
    at a fake script. Exits 0 only when every test passes and at least one ran.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$toolPath = Join-Path $repoRoot 'tools\gs-soak-monitor.ps1'

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
$workDir = Join-Path $tempRoot ('GsStabilityTool_' + [guid]::NewGuid().ToString('N'))
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

# Builds the tool invocation used by the child-process tests.
function New-ToolCommand {
    param([hashtable]$Arguments)
    $parts = @("& '$toolPath'")
    foreach ($key in $Arguments.Keys) {
        $value = $Arguments[$key]
        if ($value -is [string]) {
            $parts += ('-' + $key + " '" + ([string]$value).Replace("'", "''") + "'")
        } elseif ($value -is [System.Array]) {
            $parts += ('-' + $key + ' @(' + ((@($value | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })) -join ',') + ')')
        } elseif ($value -is [bool]) {
            $parts += ('-' + $key + ':$' + ([string]$value).ToLowerInvariant())
        } else {
            $parts += ('-' + $key + ' ' + ([string]$value).ToLowerInvariant())
        }
    }
    return ($parts -join ' ')
}

function Invoke-ToolChild {
    param([hashtable]$Arguments, [int]$TimeoutSec = 90)
    $command = (New-ToolCommand -Arguments $Arguments) + "`r`n" + 'exit $LASTEXITCODE'
    return (Invoke-ChildPowerShell -Command $command -TimeoutSec $TimeoutSec)
}

function New-SoakWorkArea {
    # StateDir + OutputDir pair under %TEMP% (outside the repository).
    $tag = [guid]::NewGuid().ToString('N')
    $area = [pscustomobject]@{
        StateDir  = (Join-Path $workDir ('state-' + $tag))
        OutputDir = (Join-Path $workDir ('out-' + $tag))
    }
    New-Item -ItemType Directory -Path $area.StateDir | Out-Null
    return $area
}

function Write-SoakStatus {
    param([Parameter(Mandatory = $true)][string]$StateDir, [string]$State = 'ready')
    $json = '{"state":"' + $State + '","source":"soak-test"}'
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'status.json'), $json, $utf8)
}

function New-ServerInfoXml {
    param([string]$CurrentGame = '0', [string]$ServerState = 'ready')
    return ('<root status_code="200"><state>' + $ServerState + '</state><currentgame>' + $CurrentGame + '</currentgame></root>')
}

# Loopback TcpListener fake serving one fixed canned response per connection.
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
            $deadline = [System.DateTime]::UtcNow.AddSeconds(180)
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
                } finally { try { $client.Close() } catch { } }
            }
        }).AddArgument($listener).AddArgument($response)
    $null = $powershell.BeginInvoke()
    $server = [pscustomobject]@{ Port = $port; Listener = $listener; PowerShell = $powershell; Runspace = $runspace }
    $script:Servers.Add($server)
    return $server
}

# Loopback fake that serves FirstBody for the first SwitchAfterRequests
# requests and SecondBody afterwards (the currentgame 1 -> 0 quit shape).
function New-TogglingServerInfoServer {
    param([string]$FirstBody, [string]$SecondBody, [int]$SwitchAfterRequests = 8)
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddScript({
            param($Listener, $Body1, $Body2, $SwitchAfter)
            $count = 0
            $deadline = [System.DateTime]::UtcNow.AddSeconds(180)
            while ([System.DateTime]::UtcNow -lt $deadline) {
                if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
                $client = $Listener.AcceptTcpClient()
                $count++
                try {
                    $stream = $client.GetStream()
                    # Read timeout: a silent client must not block cleanup (C-N3).
                    try { $stream.ReadTimeout = 5000 } catch { }
                    $buffer = New-Object byte[] 4096
                    try { $null = $stream.Read($buffer, 0, $buffer.Length) } catch { }
                    $body = $Body1
                    if ($count -gt $SwitchAfter) { $body = $Body2 }
                    $response = 'HTTP/1.1 200 OK' + "`r`n" +
                        'Content-Type: text/xml' + "`r`n" +
                        'Content-Length: ' + ([System.Text.Encoding]::ASCII.GetByteCount($body)) + "`r`n" +
                        'Connection: close' + "`r`n" + "`r`n" + $body
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($response)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                } finally { try { $client.Close() } catch { } }
            }
        }).AddArgument($listener).AddArgument($FirstBody).AddArgument($SecondBody).AddArgument($SwitchAfterRequests)
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

function Get-UnusedTcpPort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
    $listener.Stop()
    return $port
}

# Time-windowed serverinfo fake: -Windows is a list of @{ Xml; DurationSec }
# entries; the LAST window serves forever. Every request is answered with the
# body of the window that is active at the request's arrival time (measured
# from the server start), so quit choreography is deterministic against the
# wall clock instead of against request counts. -DelayMs delays every
# response (used to pin the probe cadence), and each request appends one
# '<utcIso>|<windowIndex>' line to -RequestLog for the cadence assertion.
function New-ScriptedServerInfoServer {
    param(
        [Parameter(Mandatory = $true)][object[]]$Windows,
        [int]$DelayMs = 0,
        [string]$RequestLog = ''
    )
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ($listener.LocalEndpoint -as [System.Net.IPEndPoint]).Port
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [powershell]::Create()
    $powershell.Runspace = $runspace
    $null = $powershell.AddScript({
            param($Listener, $Windows, $DelayMs, $RequestLog)
            $startedUtc = [System.DateTime]::UtcNow
            $deadline = $startedUtc.AddSeconds(240)
            while ([System.DateTime]::UtcNow -lt $deadline) {
                if (-not $Listener.Pending()) { Start-Sleep -Milliseconds 25; continue }
                $client = $Listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    try { $stream.ReadTimeout = 5000 } catch { }
                    $buffer = New-Object byte[] 4096
                    try { $null = $stream.Read($buffer, 0, $buffer.Length) } catch { }
                    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
                    $nowUtc = [System.DateTime]::UtcNow
                    $elapsedSec = ($nowUtc - $startedUtc).TotalSeconds
                    $index = 0
                    $cursor = 0.0
                    for ($i = 0; $i -lt @($Windows).Count; $i++) {
                        if ($elapsedSec -ge $cursor -and $elapsedSec -lt ($cursor + [double]$Windows[$i].DurationSec)) { $index = $i; break }
                        $cursor += [double]$Windows[$i].DurationSec
                        $index = $i
                    }
                    $body = [string]$Windows[$index].Xml
                    $response = 'HTTP/1.1 200 OK' + "`r`n" +
                        'Content-Type: text/xml' + "`r`n" +
                        'Content-Length: ' + ([System.Text.Encoding]::ASCII.GetByteCount($body)) + "`r`n" +
                        'Connection: close' + "`r`n" + "`r`n" + $body
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($response)
                    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } catch { }
                    if (-not [string]::IsNullOrEmpty($RequestLog)) {
                        try {
                            [System.IO.File]::AppendAllText($RequestLog, ($nowUtc.ToString('o') + '|' + $index + [System.Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
                        } catch { }
                    }
                } finally { try { $client.Close() } catch { } }
            }
        }).AddArgument($listener).AddArgument($Windows).AddArgument($DelayMs).AddArgument($RequestLog)
    $null = $powershell.BeginInvoke()
    $server = [pscustomobject]@{ Port = $port; Listener = $listener; PowerShell = $powershell; Runspace = $runspace }
    $script:Servers.Add($server)
    return $server
}

# Returns the source text of one helper FUNCTION OF THIS TEST FILE so a test
# can hand a copy of it to a grandchild powershell (used when the regression
# target is a helper that used to hang: the grandchild is killed at a hard
# deadline and the test FAILs instead of hanging the suite).
function Get-TestHelperFunctionText {
    param([Parameter(Mandatory = $true)][string]$Name)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast) { throw ("could not parse {0}" -f $PSCommandPath) }
    $found = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if ($null -eq $found) { throw ("helper function '{0}' not found in {1}" -f $Name, $PSCommandPath) }
    return $found.Extent.Text
}

# Returns the source text of one function from the tool so a test can define it
# with Invoke-Expression in its own scope (nothing is dot-sourced, so the
# tool's param block and main body never run).
function Get-GsSoakToolFunctionText {
    param([Parameter(Mandatory = $true)][string]$Name)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($toolPath, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast) { throw ("could not parse {0}" -f $toolPath) }
    $found = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if ($null -eq $found) { throw ("function '{0}' not found in {1}" -f $Name, $toolPath) }
    return $found.Extent.Text
}

function Read-SoakEvents {
    param([Parameter(Mandatory = $true)][string]$OutputDir)
    $events = @()
    foreach ($line in (Read-SoakFileLines -Path (Join-Path $OutputDir 'events.jsonl'))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $events += (ConvertFrom-Json -InputObject $line)
    }
    return @($events)
}

# Reads a text file with FileShare.ReadWrite so a concurrent writer (the
# monitor flushes samples.csv row by row) never blocks the read. Plain
# [IO.File]::ReadAllLines requests FileShare.Read, which CONFLICTS with a
# still-open writer and fails until the writer exits.
function Read-SoakFileLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        $lines = New-Object System.Collections.Generic.List[string]
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $lines.Add($line)
        }
        return @($lines.ToArray())
    } finally {
        try { $reader.Dispose() } catch { }
        $stream.Dispose()
    }
}

function Read-SoakSummary {
    param([Parameter(Mandatory = $true)][string]$OutputDir)
    return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $OutputDir 'summary.json'))))
}

function Get-CycleMarkerLines {
    param([Parameter(Mandatory = $true)][string]$StateDir)
    $path = Join-Path $StateDir 'cycle-marker.log'
    if (-not [System.IO.File]::Exists($path)) { return @() }
    return @([System.IO.File]::ReadAllLines($path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# Fake product script for Cycle mode: counts invocations per action in
# <StateDir>\count_<Action>.txt, appends "Action|n|pid" to cycle-marker.log,
# optionally returns a structured Busy failure (<Action>_fail_on.txt = n) or
# exits 3 (<Action>_exit3_on.txt = n). On Start it writes status.json ready
# unless <StateDir>\start_noready.txt exists.
$fakeProductScript = @'
param([string]$Action, [string]$StateDir)
$ErrorActionPreference = 'Stop'
$state = $StateDir
$utf8Local = New-Object System.Text.UTF8Encoding($false)
$marker = Join-Path $state 'cycle-marker.log'
$countFile = Join-Path $state ('count_' + $Action + '.txt')
$n = 1
if ([System.IO.File]::Exists($countFile)) { $n = [int]([System.IO.File]::ReadAllText($countFile).Trim()) + 1 }
[System.IO.File]::WriteAllText($countFile, [string]$n, $utf8Local)
[System.IO.File]::AppendAllText($marker, ($Action + '|' + $n + '|' + [string]$PID) + [System.Environment]::NewLine, $utf8Local)
$failOnFile = Join-Path $state ($Action + '_fail_on.txt')
if ([System.IO.File]::Exists($failOnFile)) {
    $failOn = [int]([System.IO.File]::ReadAllText($failOnFile).Trim())
    if ($n -eq $failOn) {
        [pscustomobject]@{ Success = $false; Data = $null; Errors = @([pscustomobject]@{ Code = 'Busy'; Message = 'synthetic busy' }) }
        exit 0
    }
}
$exit3File = Join-Path $state ($Action + '_exit3_on.txt')
if ([System.IO.File]::Exists($exit3File)) {
    $exitOn = [int]([System.IO.File]::ReadAllText($exit3File).Trim())
    if ($n -eq $exitOn) { exit 3 }
}
$noReadyFile = Join-Path $state 'start_noready.txt'
if ($Action -eq 'Start' -and -not [System.IO.File]::Exists($noReadyFile)) {
    [System.IO.File]::WriteAllText((Join-Path $state 'status.json'), '{"state":"ready","source":"fake-product"}', $utf8Local)
}
[pscustomobject]@{ Success = $true; Data = [pscustomobject]@{ ExitCode = 0 }; Errors = @() }
exit 0
'@

function New-FakeProductScript {
    $path = Join-Path $workDir ('fake-product-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [System.IO.File]::WriteAllText($path, $fakeProductScript, $utf8)
    return $path
}

# A product stand-in that hangs: the ActionTimeout deadline must kill its
# child, record ActionTimeout, stop cycling and still write summary.json.
$sleepingProductScript = @'
param([string]$Action, [string]$StateDir)
Start-Sleep -Seconds 60
'@

function New-SleepingProductScript {
    $path = Join-Path $workDir ('sleeping-product-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [System.IO.File]::WriteAllText($path, $sleepingProductScript, $utf8)
    return $path
}

try {
    # ---------------- OutputDir guard ----------------

    Invoke-Test 'OutputDir inside the repository is rejected (plan-only Cycle run creates nothing)' {
        $inside = Join-Path $repoRoot 'tools\soak-must-not-exist'
        $raw = Invoke-ToolChild -Arguments @{
            Mode      = 'Cycle'
            Count     = 1
            OutputDir = $inside
        } -TimeoutSec 60
        Assert-True ($raw.ExitCode -ne 0) 'the tool exits non-zero'
        $combined = $raw.StdOut + $raw.StdErr
        Assert-True ($combined -like '*outside the repository*') ('the error names the repository guard: ' + ($combined -split "`r?`n" | Select-Object -First 3) -join ' / ')
        Assert-True (-not (Test-Path -LiteralPath $inside)) 'nothing was created inside the repo'
    }

    # ---------------- Cycle mode ----------------

    Invoke-Test 'Cycle plan-only without -Execute prints the plan and runs nothing (fake product marker absent)' {
        $area = New-SoakWorkArea
        $fake = New-FakeProductScript
        $raw = Invoke-ToolChild -Arguments @{
            Mode       = 'Cycle'
            Count      = 4
            OutputDir  = $area.OutputDir
            StateDir   = $area.StateDir
            ProductPath = $fake
        } -TimeoutSec 60
        Assert-Equal 0 $raw.ExitCode 'plan-only exits 0'
        Assert-True ($raw.StdOut.Contains('CYCLE PLAN: 4 cycles')) 'the plan header is printed'
        Assert-True ($raw.StdOut.Contains('PLAN cycle 4/4')) 'the last planned cycle is printed'
        Assert-True ($raw.StdOut.Contains('PLAN-ONLY')) 'the plan-only notice is printed'
        Assert-Equal 0 @(Get-CycleMarkerLines -StateDir $area.StateDir).Count 'the fake product never ran'
        Assert-True (-not (Test-Path -LiteralPath $area.OutputDir)) 'plan-only creates no output directory'
    }

    Invoke-Test 'Cycle mode runs all cycles successfully against a fake product script' {
        $area = New-SoakWorkArea
        $fake = New-FakeProductScript
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '0' -ServerState 'ready')
        try {
            $raw = Invoke-ToolChild -Arguments @{
                Mode        = 'Cycle'
                Count       = 3
                Execute     = $true
                OutputDir   = $area.OutputDir
                StateDir    = $area.StateDir
                ProductPath = $fake
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                CycleReadyTimeoutSec = 15
            } -TimeoutSec 90
            Assert-Equal 0 $raw.ExitCode 'all-success cycles exit 0'
            $summary = Read-SoakSummary -OutputDir $area.OutputDir
            Assert-Equal 'pass' $summary.verdict 'verdict is pass'
            $cycles = @($summary.cycleResults)
            Assert-Equal 3 $cycles.Count 'three cycle results'
            foreach ($record in $cycles) {
                Assert-True $record.success ('cycle ' + $record.cycle + ' succeeded')
                Assert-Equal 'OK' $record.code ('cycle ' + $record.cycle + ' code is OK')
            }
            $markers = @(Get-CycleMarkerLines -StateDir $area.StateDir)
            Assert-Equal 3 @($markers | Where-Object { $_.StartsWith('Stop|') }).Count 'three stops'
            Assert-Equal 3 @($markers | Where-Object { $_.StartsWith('Start|') }).Count 'three starts'
            $events = Read-SoakEvents -OutputDir $area.OutputDir
            Assert-Equal 3 @($events | Where-Object { $_.type -eq 'Cycle' }).Count 'three cycle events'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Cycle mode records Busy on the configured cycle and fails the verdict' {
        $area = New-SoakWorkArea
        $fake = New-FakeProductScript
        [System.IO.File]::WriteAllText((Join-Path $area.StateDir 'Stop_fail_on.txt'), '3', $utf8)
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '0' -ServerState 'ready')
        try {
            $raw = Invoke-ToolChild -Arguments @{
                Mode        = 'Cycle'
                Count       = 4
                Execute     = $true
                OutputDir   = $area.OutputDir
                StateDir    = $area.StateDir
                ProductPath = $fake
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                CycleReadyTimeoutSec = 15
            } -TimeoutSec 90
            Assert-True ($raw.ExitCode -ne 0) 'a failed cycle exits non-zero'
            $summary = Read-SoakSummary -OutputDir $area.OutputDir
            Assert-Equal 'fail' $summary.verdict 'verdict is fail'
            $cycles = @($summary.cycleResults)
            Assert-Equal 4 $cycles.Count 'all four cycles were attempted'
            Assert-True (-not $cycles[2].success) 'cycle 3 failed'
            Assert-Equal 'Busy' $cycles[2].code 'cycle 3 code is Busy'
            Assert-Equal 'Stop' $cycles[2].phase 'cycle 3 failed in the Stop phase'
            Assert-True $cycles[3].success 'cycle 4 still ran after the failed cycle 3'
            Assert-True ($summary.verdictReasons.Count -ge 1) 'a verdict reason names the failed cycle'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Cycle mode records a non-zero product exit as a failed cycle' {
        $area = New-SoakWorkArea
        $fake = New-FakeProductScript
        [System.IO.File]::WriteAllText((Join-Path $area.StateDir 'Stop_exit3_on.txt'), '5', $utf8)
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '0' -ServerState 'ready')
        try {
            $raw = Invoke-ToolChild -Arguments @{
                Mode        = 'Cycle'
                Count       = 5
                Execute     = $true
                OutputDir   = $area.OutputDir
                StateDir    = $area.StateDir
                ProductPath = $fake
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                CycleReadyTimeoutSec = 15
            } -TimeoutSec 90
            Assert-True ($raw.ExitCode -ne 0) 'a failed cycle exits non-zero'
            $summary = Read-SoakSummary -OutputDir $area.OutputDir
            $cycles = @($summary.cycleResults)
            Assert-Equal 5 $cycles.Count 'five cycle results'
            Assert-Equal 'Exit3' $cycles[4].code 'cycle 5 code is Exit3'
            Assert-Equal 'Stop' $cycles[4].phase 'cycle 5 failed in the Stop phase'
            for ($i = 0; $i -lt 4; $i++) { Assert-True $cycles[$i].success ('cycle ' + ($i + 1) + ' succeeded') }
            $markers = @(Get-CycleMarkerLines -StateDir $area.StateDir)
            Assert-Equal 5 @($markers | Where-Object { $_.StartsWith('Stop|') }).Count 'five stop attempts'
            Assert-Equal 4 @($markers | Where-Object { $_.StartsWith('Start|') }).Count 'only four starts (cycle 5 never started)'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Cycle mode records ReadyTimeout when the host never becomes ready' {
        $area = New-SoakWorkArea
        $fake = New-FakeProductScript
        # start_noready.txt keeps the fake Start from writing a ready status.
        [System.IO.File]::WriteAllText((Join-Path $area.StateDir 'start_noready.txt'), '1', $utf8)
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '0' -ServerState 'ready')
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $raw = Invoke-ToolChild -Arguments @{
                Mode        = 'Cycle'
                Count       = 1
                Execute     = $true
                OutputDir   = $area.OutputDir
                StateDir    = $area.StateDir
                ProductPath = $fake
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                CycleReadyTimeoutSec = 2
            } -TimeoutSec 90
            $stopwatch.Stop()
            Assert-True ($raw.ExitCode -ne 0) 'a ReadyTimeout cycle exits non-zero'
            $summary = Read-SoakSummary -OutputDir $area.OutputDir
            Assert-Equal 'fail' $summary.verdict 'verdict is fail'
            $cycles = @($summary.cycleResults)
            Assert-Equal 1 $cycles.Count 'one cycle result'
            Assert-Equal 'ReadyTimeout' $cycles[0].code 'the cycle code is ReadyTimeout'
            Assert-Equal 'Wait' $cycles[0].phase 'the cycle failed in the Wait phase'
            Assert-True ($cycles[0].durationSec -ge 2) ('the cycle waited the full timeout, took ' + $cycles[0].durationSec + 's')
            Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 30) ('the run finished promptly, took {0:N1}s' -f $stopwatch.Elapsed.TotalSeconds)
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Cycle mode records ActionTimeout, stops cycling and still writes the summary' {
        $area = New-SoakWorkArea
        $sleepy = New-SleepingProductScript
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = Invoke-ToolChild -Arguments @{
            Mode             = 'Cycle'
            Count            = 3
            Execute          = $true
            OutputDir        = $area.OutputDir
            StateDir         = $area.StateDir
            ProductPath      = $sleepy
            ActionTimeoutSec = 2
        } -TimeoutSec 90
        $stopwatch.Stop()
        Assert-True ($raw.ExitCode -ne 0) 'an ActionTimeout run exits non-zero'
        Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 30) ('the run did not wait for the sleeping product, took {0:N1}s' -f $stopwatch.Elapsed.TotalSeconds)
        Assert-True (Test-Path -LiteralPath (Join-Path $area.OutputDir 'summary.json')) 'summary.json was still written'
        $summary = Read-SoakSummary -OutputDir $area.OutputDir
        Assert-Equal 'fail' $summary.verdict 'verdict is fail'
        $cycles = @($summary.cycleResults)
        Assert-Equal 1 $cycles.Count 'cycling stopped after the timeout'
        Assert-Equal 'ActionTimeout' $cycles[0].code 'the cycle code is ActionTimeout'
        Assert-Equal 'Stop' $cycles[0].phase 'the timeout hit in the Stop phase'
        Assert-True ($summary.verdictReasons.Count -ge 1) 'a verdict reason names the ActionTimeout'
    }

    # ---------------- Extracted pure functions ----------------

    Invoke-Test 'Memory slope regression on synthetic samples (extracted via AST)' {
        Invoke-Expression (Get-GsSoakToolFunctionText -Name 'Get-GsMemorySlopeMBPerHour')
        $slope = Get-GsMemorySlopeMBPerHour -Seconds ([double[]]@(0, 60, 120)) -PrivateMb ([double[]]@(100, 110, 120))
        Assert-Equal 600 $slope '10 MB per minute is 600 MB/h'
        $down = Get-GsMemorySlopeMBPerHour -Seconds ([double[]]@(0, 60, 120)) -PrivateMb ([double[]]@(120, 110, 100))
        Assert-Equal (-600) $down 'the slope can be negative'
        $flat = Get-GsMemorySlopeMBPerHour -Seconds ([double[]]@(0, 60, 120)) -PrivateMb ([double[]]@(100, 100, 100))
        Assert-Equal 0 $flat 'constant memory gives a zero slope'
        Assert-True ($null -eq (Get-GsMemorySlopeMBPerHour -Seconds ([double[]]@(0)) -PrivateMb ([double[]]@(100)))) 'one point is not enough'
        Assert-True ($null -eq (Get-GsMemorySlopeMBPerHour -Seconds ([double[]]@(5, 5, 5)) -PrivateMb ([double[]]@(100, 100, 100)))) 'zero x-variance returns null'
        Assert-True ($null -eq (Get-GsMemorySlopeMBPerHour -Seconds ([double[]]@(0, 60)) -PrivateMb ([double[]]@(100)))) 'length mismatch returns null'
    }

    Invoke-Test 'PID file parser tolerates plain, JSON-object, quoted and malformed formats (extracted via AST)' {
        Invoke-Expression (Get-GsSoakToolFunctionText -Name 'ConvertFrom-GsSoakPidFile')
        $dir = Join-Path $workDir ('pidparse-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $cases = @(
            @{ Name = 'plain'; Body = '1234'; Expected = [int64]1234 },
            @{ Name = 'plain-spaces'; Body = "  2345`r`n"; Expected = [int64]2345 },
            @{ Name = 'json-pid-string'; Body = '{"pid":"5678"}'; Expected = [int64]5678 },
            @{ Name = 'json-processId-number'; Body = '{"processId": 4321}'; Expected = [int64]4321 },
            @{ Name = 'quoted-number'; Body = '"8765"'; Expected = [int64]8765 },
            @{ Name = 'json-long-digits'; Body = '{"pid":"999999999999"}'; Expected = [int64]999999999999 },
            @{ Name = 'negative'; Body = '{"pid":-5}'; Expected = $null },
            @{ Name = 'garbage'; Body = 'not a pid at all'; Expected = $null },
            @{ Name = 'empty-object'; Body = '{}'; Expected = $null }
        )
        foreach ($case in $cases) {
            $path = Join-Path $dir ($case.Name + '_pid.json')
            [System.IO.File]::WriteAllText($path, $case.Body, $utf8)
            $parsed = ConvertFrom-GsSoakPidFile -Path $path
            Assert-True $parsed.Exists ('{0}: the file exists' -f $case.Name)
            Assert-Equal $case.Expected $parsed.Pid ('{0}: pid value' -f $case.Name)
            if ($null -eq $case.Expected) {
                Assert-True $parsed.Malformed ('{0}: reported malformed' -f $case.Name)
            } else {
                Assert-True (-not $parsed.Malformed) ('{0}: not malformed' -f $case.Name)
            }
        }
        $missing = ConvertFrom-GsSoakPidFile -Path (Join-Path $dir 'missing_pid.json')
        Assert-True (-not $missing.Exists) 'a missing file is reported as absent'
        Assert-True ($null -eq $missing.Pid) 'a missing file has no pid'
    }

    # ---------------- Monitor end-to-end ----------------

    Invoke-Test 'Monitor detects orphan and PID-change events from a killed fake role process' {
        $area = New-SoakWorkArea
        Write-SoakStatus -StateDir $area.StateDir -State 'stopped'
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '0' -ServerState 'ready')
        # Fake role process 1: a sleeping child powershell this suite owns.
        $child1 = Start-ChildPowerShell -Command 'Start-Sleep -Seconds 90'
        $pid1 = $child1.Process.Id
        [System.IO.File]::WriteAllText((Join-Path $area.StateDir 'broker_pid.json'), ([string]$pid1), $utf8)
        $child2 = $null
        try {
            $monitor = Start-ChildPowerShell -Command ((New-ToolCommand -Arguments @{
                Mode        = 'Monitor'
                DurationSec = 8
                IntervalSec = 1
                StateDir    = $area.StateDir
                OutputDir   = $area.OutputDir
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
            }) + "`r`n" + 'exit $LASTEXITCODE')
            # Wait for two samples with the live process, then swap it. The
            # monitor holds samples.csv open and flushes per row, so the poll
            # reads with FileShare.ReadWrite (see Read-SoakFileLines).
            Wait-Until -Condition {
                try {
                    $csvPath = Join-Path $area.OutputDir 'samples.csv'
                    [System.IO.File]::Exists($csvPath) -and @(Read-SoakFileLines -Path $csvPath).Count -ge 3
                } catch {
                    $false
                }
            } -TimeoutSec 25 -Message 'the monitor did not produce two samples'
            try { $child1.Process.Kill() } catch { }
            $child2 = Start-ChildPowerShell -Command 'Start-Sleep -Seconds 90'
            $pid2 = $child2.Process.Id
            [System.IO.File]::WriteAllText((Join-Path $area.StateDir 'broker_pid.json'), ([string]$pid2), $utf8)
            $raw = Complete-ChildPowerShell -Child $monitor -TimeoutSec 60
            # An orphan is a verdict failure by design, so this run exits 1.
            Assert-True ($raw.ExitCode -ne 0) 'the monitor fails its verdict when an orphan is detected'
            $summary = Read-SoakSummary -OutputDir $area.OutputDir
            Assert-Equal 'fail' $summary.verdict 'verdict is fail'
            Assert-True ($summary.verdictReasons.Count -ge 1) 'a verdict reason names the orphan'
            Assert-True ($summary.samples -ge 4) ('at least four samples, got ' + $summary.samples)
            Assert-True ($summary.orphans -ge 1) 'at least one orphan event was counted'
            Assert-True ($summary.pidChanges -ge 1) 'at least one pid change was counted'
            $events = @(Read-SoakEvents -OutputDir $area.OutputDir)
            $orphans = @($events | Where-Object { $_.type -eq 'Orphan' -and $_.role -eq 'broker' })
            Assert-True ($orphans.Count -ge 1) 'an Orphan event for broker exists'
            Assert-Equal ([int64]$pid1) $orphans[0].pid 'the orphan names the first fake PID'
            $pidChanges = @($events | Where-Object { $_.type -eq 'PidChange' -and $_.role -eq 'broker' })
            Assert-True ($pidChanges.Count -ge 1) 'a PidChange event for broker exists'
            Assert-Equal ([int64]$pid1) $pidChanges[0].from 'the PidChange records the old PID'
            Assert-Equal ([int64]$pid2) $pidChanges[0].to 'the PidChange records the new PID'
            # While process 1 was alive, the broker columns carried its metrics.
            $csvLines = @(Read-SoakFileLines -Path (Join-Path $area.OutputDir 'samples.csv'))
            Assert-True ($csvLines.Count -ge 5) 'the CSV has the header plus every sample row'
            Assert-True ($csvLines[1].Contains([string]$pid1)) 'the first sample row carries the first PID'
        } finally {
            try { if ($null -ne $child2 -and -not $child2.Process.HasExited) { $child2.Process.Kill() } } catch { }
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Monitor full run with -DurationSec 20 -IntervalSec 1 produces samples, events and a passing summary' {
        $area = New-SoakWorkArea
        # A real runtime reports 'starting'/'ready' in the status file while
        # serverinfo reports ..._SERVER_BUSY while streaming and ..._SERVER_FREE
        # once idle (the tray's Ready rule keys on the _SERVER_BUSY suffix).
        Write-SoakStatus -StateDir $area.StateDir -State 'starting'
        $server = New-TogglingServerInfoServer `
            -FirstBody (New-ServerInfoXml -CurrentGame '1' -ServerState 'READY_SERVER_BUSY') `
            -SecondBody (New-ServerInfoXml -CurrentGame '0' -ServerState 'READY_SERVER_FREE') `
            -SwitchAfterRequests 8
        # Fake role process for the nvs role (JSON pid-file format this time).
        $child = Start-ChildPowerShell -Command 'Start-Sleep -Seconds 90'
        [System.IO.File]::WriteAllText((Join-Path $area.StateDir 'nvs_pid.json'), ('{"pid":' + $child.Process.Id + '}'), $utf8)
        try {
            $monitor = Start-ChildPowerShell -Command ((New-ToolCommand -Arguments @{
                Mode        = 'Monitor'
                DurationSec = 20
                IntervalSec = 1
                StateDir    = $area.StateDir
                OutputDir   = $area.OutputDir
                ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                WatchProcessNames = @('gs-no-such-process-xyz')
            }) + "`r`n" + 'exit $LASTEXITCODE')
            # Flip the status file mid-run so a StateChange event must appear.
            Start-Sleep -Seconds 5
            Write-SoakStatus -StateDir $area.StateDir -State 'ready'
            $raw = Complete-ChildPowerShell -Child $monitor -TimeoutSec 60
            Assert-Equal 0 $raw.ExitCode ('the monitor passes its own verdict: ' + (($raw.StdOut -split "`r?`n" | Select-Object -Last 2) -join ' / '))
            $summary = Read-SoakSummary -OutputDir $area.OutputDir
            Assert-Equal 'pass' $summary.verdict 'verdict is pass'
            Assert-True ($summary.samples -ge 12) ('at least twelve samples, got ' + $summary.samples)
            Assert-True ($summary.streamTransitions -ge 1) 'the currentgame 1 -> 0 quit was counted'
            Assert-True ($null -ne $summary.secondsToAvailableAfterQuit) 'secondsToAvailableAfterQuit was observed'
            Assert-True ($summary.secondsToAvailableAfterQuit -ge 0 -and $summary.secondsToAvailableAfterQuit -lt 10) ('recovery time is plausible: ' + $summary.secondsToAvailableAfterQuit + 's')
            Assert-True ($null -ne $summary.memorySlopeMBPerHour) 'a memory slope was computed'
            Assert-Equal 0 $summary.orphans 'no orphans'
            $csvLines = @(Read-SoakFileLines -Path (Join-Path $area.OutputDir 'samples.csv'))
            Assert-True ($csvLines.Count -ge 13) ('header plus at least twelve sample rows, got ' + $csvLines.Count)
            $events = @(Read-SoakEvents -OutputDir $area.OutputDir)
            Assert-True (@($events | Where-Object { $_.type -eq 'StateChange' }).Count -ge 1) 'a StateChange event exists'
            Assert-True (@($events | Where-Object { $_.type -eq 'CurrentGameChange' }).Count -ge 1) 'a CurrentGameChange event exists'
            Assert-True (@($events | Where-Object { $_.type -eq 'AvailableAfterQuit' }).Count -ge 1) 'an AvailableAfterQuit event records the measurement'
        } finally {
            try { if (-not $child.Process.HasExited) { $child.Process.Kill() } } catch { }
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Monitor emits ServerInfoError events when serverinfo fails the validity rule' {
        $area = New-SoakWorkArea
        Write-SoakStatus -StateDir $area.StateDir -State 'ready'
        $closedPort = Get-UnusedTcpPort
        $raw = Invoke-ToolChild -Arguments @{
            Mode        = 'Monitor'
            DurationSec = 4
            IntervalSec = 1
            StateDir    = $area.StateDir
            OutputDir   = $area.OutputDir
            ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $closedPort)
        } -TimeoutSec 60
        Assert-Equal 0 $raw.ExitCode 'serverinfo errors alone do not fail the verdict'
        $summary = Read-SoakSummary -OutputDir $area.OutputDir
        Assert-Equal 'pass' $summary.verdict 'verdict is pass'
        Assert-True ($summary.serverInfoErrors -ge 1) 'serverinfo errors were counted'
        Assert-True ($summary.samples -ge 2) ('at least two samples ran, got ' + $summary.samples)
        $events = @(Read-SoakEvents -OutputDir $area.OutputDir)
        $errors = @($events | Where-Object { $_.type -eq 'ServerInfoError' })
        Assert-True ($errors.Count -ge 1) 'a ServerInfoError event exists'
        Assert-True ($errors[0].error -like '*Timeout*') 'the error names the timeout'
    }

    # ---------------- Round-4 review fixes (C-B3..C-B10, C-N2, C-N3) ----------------

    Invoke-Test 'OutputDir through a junction into the repository is rejected (reparse containment)' {
        $junction = Join-Path $workDir 'soak-junction-into-repo'
        $throughRepo = Join-Path $repoRoot 'tools\soak-junction-must-not-exist'
        try {
            New-Item -ItemType Junction -Path $junction -Value $repoRoot | Out-Null
            # Case 1: an OutputDir INSIDE the repository, reached through the
            # junction path (lexically outside the repo).
            $raw = Invoke-ToolChild -Arguments @{
                Mode      = 'Cycle'
                Count     = 1
                OutputDir = (Join-Path $junction 'tools\soak-junction-must-not-exist')
            } -TimeoutSec 60
            Assert-True ($raw.ExitCode -ne 0) 'the tool exits non-zero for the junction path'
            $combined = $raw.StdOut + $raw.StdErr
            Assert-True ($combined -like '*outside the repository*') ('the error names the repository guard: ' + (($combined -split "`r?`n" | Select-Object -First 3) -join ' / '))
            Assert-True (-not (Test-Path -LiteralPath $throughRepo)) 'nothing was created inside the repo through the junction'
            # Case 2: the OutputDir IS the junction itself.
            $raw2 = Invoke-ToolChild -Arguments @{
                Mode      = 'Cycle'
                Count     = 1
                OutputDir = $junction
            } -TimeoutSec 60
            Assert-True ($raw2.ExitCode -ne 0) 'the junction itself is rejected as OutputDir'
            Assert-True (-not (Test-Path -LiteralPath $throughRepo)) 'case 2 created nothing inside the repo'
        } finally {
            # Remove only the junction itself, never its target (the repo).
            if (Test-Path -LiteralPath $throughRepo) {
                try { Remove-Item -LiteralPath $throughRepo -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
            if (Test-Path -LiteralPath $junction) {
                try {
                    [System.IO.Directory]::Delete($junction, $false)
                } catch {
                    try { Remove-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue } catch { }
                }
            }
        }
    }

    Invoke-Test 'Complete-ChildPowerShell bounds stream draining after exit (extracted via AST, grandchild with deadline)' {
        # The regression target is this suite's own helper: a child whose
        # process exited but whose stdout task never completes (a descendant
        # that inherited the pipe) used to hang the unbounded GetResult
        # forever. The helper therefore runs in a grandchild with a hard
        # deadline: on the old helper the grandchild is killed and this test
        # FAILs instead of hanging the suite.
        $helperText = Get-TestHelperFunctionText -Name 'Complete-ChildPowerShell'
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

    Invoke-Test 'Stop-GsSoakOwnedProcess kills a still-running owned child and waits bounded (extracted via AST)' {
        Invoke-Expression (Get-GsSoakToolFunctionText -Name 'Stop-GsSoakOwnedProcess')
        # Null-safe: no process, no throw.
        Stop-GsSoakOwnedProcess -Process $null
        # A live sleeping child is killed; an unrelated child survives. The
        # assert uses Get-Process -Id because the helper DISPOSES the Process
        # object on the way out (property access on a disposed Process throws).
        $victim = Start-ChildPowerShell -Command 'Start-Sleep -Seconds 90'
        $survivor = Start-ChildPowerShell -Command 'Start-Sleep -Seconds 90'
        $victimId = $victim.Process.Id
        $survivorId = $survivor.Process.Id
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-GsSoakOwnedProcess -Process $victim.Process
        $stopwatch.Stop()
        Assert-True ($stopwatch.Elapsed.TotalSeconds -lt 15) ('the kill wait stayed bounded, took {0:N1}s' -f $stopwatch.Elapsed.TotalSeconds)
        Wait-Until -Condition { $null -eq (Get-Process -Id $victimId -ErrorAction SilentlyContinue) } -TimeoutSec 10 -Message 'the owned child was not killed'
        Assert-True ($null -ne (Get-Process -Id $survivorId -ErrorAction SilentlyContinue)) 'an unrelated child was NOT killed'
    }

    Invoke-Test 'Invoke-GsSoakProductAction kills its owned child on every exit path (AST source check)' {
        $fnText = Get-GsSoakToolFunctionText -Name 'Invoke-GsSoakProductAction'
        $tokens = $null
        $parseErrors = $null
        $fnAst = [System.Management.Automation.Language.Parser]::ParseInput($fnText, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'the extracted function parses'
        $tryStatements = @($fnAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] }, $true))
        Assert-True ($tryStatements.Count -ge 1) 'the function has a try block'
        $foundKillInFinally = $false
        foreach ($tryStatement in $tryStatements) {
            if ($null -ne $tryStatement.Finally -and $tryStatement.Finally.Extent.Text.Contains('Stop-GsSoakOwnedProcess')) {
                $foundKillInFinally = $true
            }
        }
        Assert-True $foundKillInFinally 'the finally block kills the owned child via Stop-GsSoakOwnedProcess'
    }

    Invoke-Test 'Get-GsSoakServerInfo rejects an HTTP 201 before reading the body (extracted via AST)' {
        Invoke-Expression (Get-GsSoakToolFunctionText -Name 'Read-GsSoakHttpBody')
        Invoke-Expression (Get-GsSoakToolFunctionText -Name 'Get-GsSoakServerInfo')
        $server = New-FakeHttpServer -StatusCode 201 -Body (New-ServerInfoXml -CurrentGame '0' -ServerState 'ready')
        try {
            $info = Get-GsSoakServerInfo -Uri ('http://127.0.0.1:{0}/serverinfo' -f $server.Port) -TimeoutSec 2
            Assert-Equal 201 $info.Http 'the HTTP status was recorded'
            Assert-True (-not [string]::IsNullOrEmpty($info.Error)) 'a 201 response is rejected'
            Assert-True ($info.Error -like '*200*') ('the error names the required status: ' + $info.Error)
            Assert-True ($null -eq $info.State) 'no state was parsed from a 201 body'
            Assert-True ($null -eq $info.CurrentGame) 'no currentgame was parsed from a 201 body'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Cycle readiness requires the shared Ready rule (extracted via AST)' {
        foreach ($fnName in @('Get-GsSoakStatusState', 'Read-GsSoakHttpBody', 'Get-GsSoakServerInfo', 'Test-GsSoakHostFree', 'Test-GsSoakCycleReady')) {
            Invoke-Expression (Get-GsSoakToolFunctionText -Name $fnName)
        }
        $area = New-SoakWorkArea
        Write-SoakStatus -StateDir $area.StateDir -State 'ready'
        $streamingServer = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '1' -ServerState 'READY_SERVER_BUSY')
        try {
            $streaming = Test-GsSoakCycleReady -StateDirectory $area.StateDir -ServerInfoUri ('http://127.0.0.1:{0}/serverinfo' -f $streamingServer.Port) -ServerInfoTimeoutSec 2
            Assert-True (-not $streaming) 'currentgame=1 with READY_SERVER_BUSY is NOT cycle-ready'
        } finally { Stop-FakeHttpServer -Server $streamingServer }
        $busyStateServer = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '0' -ServerState 'READY_SERVER_BUSY')
        try {
            $busyState = Test-GsSoakCycleReady -StateDirectory $area.StateDir -ServerInfoUri ('http://127.0.0.1:{0}/serverinfo' -f $busyStateServer.Port) -ServerInfoTimeoutSec 2
            Assert-True (-not $busyState) 'READY_SERVER_BUSY is NOT cycle-ready even with currentgame 0'
        } finally { Stop-FakeHttpServer -Server $busyStateServer }
        $freeServer = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '0' -ServerState 'READY_SERVER_FREE')
        try {
            $free = Test-GsSoakCycleReady -StateDirectory $area.StateDir -ServerInfoUri ('http://127.0.0.1:{0}/serverinfo' -f $freeServer.Port) -ServerInfoTimeoutSec 2
            Assert-True $free 'currentgame 0 with READY_SERVER_FREE IS cycle-ready'
        } finally { Stop-FakeHttpServer -Server $freeServer }
    }

    Invoke-Test 'Cycle child-script result selection takes the last result with a Success property, any type (extracted via AST)' {
        Invoke-Expression (Get-GsSoakToolFunctionText -Name 'Get-GsSoakProductChildScript')
        $fakeDir = Join-Path $workDir ('result-select-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fakeDir | Out-Null
        $productPath = Join-Path $fakeDir 'fake-class-result-product.ps1'
        $stateDir = Join-Path $fakeDir 'state'
        New-Item -ItemType Directory -Path $stateDir | Out-Null
        $resultFile = Join-Path $fakeDir 'result.json'
        $productBody = @'
class FakeClassResult {
    [bool]$Success
    [string]$Source
}
$ErrorActionPreference = 'Stop'
[pscustomobject]@{ Success = $false; Data = $null; Errors = @() }
$instance = [FakeClassResult]::new()
$instance.Success = $true
$instance.Source = 'class-instance'
$instance
exit 0
'@
        [System.IO.File]::WriteAllText($productPath, $productBody, $utf8)
        $childScript = Get-GsSoakProductChildScript -ProductScript $productPath -ProductAction 'Stop' -StateDirectory $stateDir -ResultFile $resultFile
        $childPath = Join-Path $fakeDir 'child.ps1'
        [System.IO.File]::WriteAllText($childPath, $childScript, $utf8)
        $raw = Invoke-ChildPowerShell -Command ("& '" + $childPath.Replace("'", "''") + "'") -TimeoutSec 60
        Assert-Equal 0 $raw.ExitCode 'the generated child script ran'
        Assert-True ([System.IO.File]::Exists($resultFile)) 'the result file was written'
        $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($resultFile))
        Assert-Equal 'True' ([string]$parsed.Success) 'the LAST result (the class instance) won'
        Assert-Equal 'class-instance' $parsed.Source 'the winning result is the class instance, not the earlier pscustomobject'
    }

    Invoke-Test 'samples.csv elapsedSec column is numeric (Monitor e2e)' {
        $area = New-SoakWorkArea
        Write-SoakStatus -StateDir $area.StateDir -State 'ready'
        $closedPort = Get-UnusedTcpPort
        $raw = Invoke-ToolChild -Arguments @{
            Mode          = 'Monitor'
            DurationSec   = 3
            IntervalSec   = 1
            StateDir      = $area.StateDir
            OutputDir     = $area.OutputDir
            ServerInfoUri = ('http://127.0.0.1:{0}/serverinfo' -f $closedPort)
        } -TimeoutSec 60
        Assert-Equal 0 $raw.ExitCode 'the monitor run completed'
        $lines = @(Read-SoakFileLines -Path (Join-Path $area.OutputDir 'samples.csv'))
        Assert-True ($lines.Count -ge 2) 'the CSV has a header plus sample rows'
        $rows = @($lines | Select-Object -Skip 1 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-True ($rows.Count -ge 1) 'at least one sample row'
        foreach ($row in $rows) {
            $fields = $row.Split(',')
            Assert-True ($fields.Count -ge 2) 'the row has the timestamp and elapsed columns'
            Assert-True ($fields[1] -match '^\d+(\.\d+)?$') ('elapsedSec is numeric, got: ' + $fields[1])
        }
    }

    Invoke-Test 'Quit outcomes: the worst successful delay wins the summary scalar (Monitor e2e)' {
        # Two quits: the first stays busy ~6s (over the provisional max of 2),
        # the second becomes free in ~2s. The scalar must keep the WORST
        # delay, not the latest one.
        $area = New-SoakWorkArea
        Write-SoakStatus -StateDir $area.StateDir -State 'starting'
        $windows = @(
            @{ Xml = (New-ServerInfoXml -CurrentGame '1' -ServerState 'READY_SERVER_BUSY'); DurationSec = 1.5 }
            @{ Xml = (New-ServerInfoXml -CurrentGame '0' -ServerState 'READY_SERVER_BUSY'); DurationSec = 6.0 }
            @{ Xml = (New-ServerInfoXml -CurrentGame '0' -ServerState 'READY_SERVER_FREE'); DurationSec = 1.5 }
            @{ Xml = (New-ServerInfoXml -CurrentGame '1' -ServerState 'READY_SERVER_BUSY'); DurationSec = 1.5 }
            @{ Xml = (New-ServerInfoXml -CurrentGame '0' -ServerState 'READY_SERVER_BUSY'); DurationSec = 2.0 }
            @{ Xml = (New-ServerInfoXml -CurrentGame '0' -ServerState 'READY_SERVER_FREE'); DurationSec = 60 }
        )
        $server = New-ScriptedServerInfoServer -Windows $windows
        try {
            $raw = Invoke-ToolChild -Arguments @{
                Mode                           = 'Monitor'
                DurationSec                    = 14
                IntervalSec                    = 1
                StateDir                       = $area.StateDir
                OutputDir                      = $area.OutputDir
                ServerInfoUri                  = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                MaxSecondsToAvailableAfterQuit = 2
            } -TimeoutSec 90
            Assert-True ($raw.ExitCode -ne 0) 'a quit delay over the threshold fails the verdict'
            $summary = Read-SoakSummary -OutputDir $area.OutputDir
            $events = @(Read-SoakEvents -OutputDir $area.OutputDir)
            $available = @($events | Where-Object { $_.type -eq 'AvailableAfterQuit' })
            Assert-Equal 2 $available.Count 'both quits recorded their delay'
            Assert-True ($available[0].seconds -ge 4.5) ('the first quit was the slow one: ' + $available[0].seconds + 's')
            Assert-True ($available[1].seconds -le 3.5) ('the second quit was fast: ' + $available[1].seconds + 's')
            Assert-True ($null -ne $summary.secondsToAvailableAfterQuit) 'the scalar was recorded'
            Assert-True ($summary.secondsToAvailableAfterQuit -ge 4.5) ('the scalar is the WORST delay, got ' + $summary.secondsToAvailableAfterQuit + 's')
            Assert-True ([math]::Abs($summary.secondsToAvailableAfterQuit - $available[0].seconds) -lt 0.01) 'the scalar equals the first (worst) measurement'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Quit outcomes: a timeout is recorded, fails the verdict and probes run at 1s start-to-start (Monitor e2e)' {
        # The quit never becomes free: the cap must produce a recorded
        # timeout outcome, a failing verdict reason and a null scalar, and
        # the probes must run at 1 s start-to-start (the delayed responses
        # make the old sleep-after-request cadence visible in the request
        # log: old gaps ~1.8s, new gaps ~1.0s).
        $area = New-SoakWorkArea
        Write-SoakStatus -StateDir $area.StateDir -State 'starting'
        $requestLog = Join-Path $workDir ('requestlog-' + [guid]::NewGuid().ToString('N') + '.txt')
        $windows = @(
            @{ Xml = (New-ServerInfoXml -CurrentGame '1' -ServerState 'READY_SERVER_BUSY'); DurationSec = 2.0 }
            @{ Xml = (New-ServerInfoXml -CurrentGame '0' -ServerState 'READY_SERVER_BUSY'); DurationSec = 120 }
        )
        $server = New-ScriptedServerInfoServer -Windows $windows -DelayMs 800 -RequestLog $requestLog
        try {
            $raw = Invoke-ToolChild -Arguments @{
                Mode                           = 'Monitor'
                DurationSec                    = 13
                IntervalSec                    = 1
                StateDir                       = $area.StateDir
                OutputDir                      = $area.OutputDir
                ServerInfoUri                  = ('http://127.0.0.1:{0}/serverinfo' -f $server.Port)
                MaxSecondsToAvailableAfterQuit = 2
            } -TimeoutSec 90
            Assert-True ($raw.ExitCode -ne 0) 'a quit that never becomes free fails the verdict'
            $summary = Read-SoakSummary -OutputDir $area.OutputDir
            $events = @(Read-SoakEvents -OutputDir $area.OutputDir)
            $timeouts = @($events | Where-Object { $_.type -eq 'AvailableAfterQuitTimeout' })
            Assert-True ($timeouts.Count -ge 1) 'the quit timeout was recorded as an event'
            Assert-True ($timeouts[0].waitedSec -ge 6.5) ('the timeout waited the full cap, waited ' + $timeouts[0].waitedSec + 's')
            Assert-True ($null -eq $summary.secondsToAvailableAfterQuit) 'no successful delay was fabricated'
            Assert-True ($summary.quitTimeouts -ge 1) ('the summary counts the quit timeout, got ' + $summary.quitTimeouts)
            $reasons = @($summary.verdictReasons | Where-Object { $_ -like '*did not become available*' })
            Assert-True ($reasons.Count -ge 1) 'a verdict reason names the quit timeout'
            # Cadence: consecutive busy-phase requests must be at most ~1.35s
            # apart (start-to-start 1s plus jitter), and at least 6 of them
            # must have happened before the cap.
            Assert-True ([System.IO.File]::Exists($requestLog)) 'the server logged its requests'
            $busyRequests = @()
            foreach ($line in [System.IO.File]::ReadAllLines($requestLog)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $parts = $line.Split('|')
                if ($parts[1] -eq '1') { $busyRequests += ([datetime]$parts[0]) }
            }
            Assert-True ($busyRequests.Count -ge 6) ('enough busy-phase probes ran, got ' + $busyRequests.Count)
            for ($i = 1; $i -lt $busyRequests.Count; $i++) {
                $gap = ($busyRequests[$i] - $busyRequests[$i - 1]).TotalSeconds
                Assert-True ($gap -le 1.35) ('probe start-to-start stayed near 1s, gap ' + [math]::Round($gap, 3) + 's')
            }
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'An interrupted Cycle run still reports its completed cycles and regression data (summary finalized in finally)' {
        # The tool runs in a child that HOSTS it via [powershell]::Create and
        # stops the pipeline once cycle 2 is in its ready-wait (the Ctrl+C
        # shape; the stop lands in the loop's interruptible Start-Sleep).
        # summary.json must still carry the completed cycle 1.
        $area = New-SoakWorkArea
        $fake = New-FakeProductScript
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml -CurrentGame '0' -ServerState 'ready')
        try {
            $hostBody = @'
$ErrorActionPreference = 'Stop'
$ps = [powershell]::Create()
# [powershell]::Create() already carries an OPENED default runspace.
$null = $ps.AddScript("& '__TOOL__' -Mode Cycle -Count 5 -Execute -StateDir '__STATE__' -OutputDir '__OUT__' -ProductPath '__PRODUCT__' -ServerInfoUri '__URI__' -CycleReadyTimeoutSec 15 -ActionTimeoutSec 40")
$async = $ps.BeginInvoke()
$markerPath = '__STATE__\cycle-marker.log'
$deadline = [System.DateTime]::UtcNow.AddSeconds(45)
$secondStarted = $false
while ([System.DateTime]::UtcNow -lt $deadline) {
    if ([System.IO.File]::Exists($markerPath)) {
        $starts = @([System.IO.File]::ReadAllLines($markerPath) | Where-Object { $_.StartsWith('Start|') })
        if ($starts.Count -ge 2) { $secondStarted = $true; break }
    }
    Start-Sleep -Milliseconds 100
}
if (-not $secondStarted) {
    try { $ps.Stop() } catch { }
    Write-Output 'HOST-ERROR second cycle never started'
    exit 3
}
try { $ps.Stop() } catch { }
try { $null = $ps.EndInvoke($async) } catch { }
Write-Output ('HOST-DONE summaryExists=' + [System.IO.File]::Exists('__OUT__\summary.json'))
exit 0
'@
            $hostBody = $hostBody.Replace('__TOOL__', $toolPath.Replace("'", "''")).Replace('__STATE__', $area.StateDir).Replace('__OUT__', $area.OutputDir).Replace('__PRODUCT__', $fake).Replace('__URI__', ('http://127.0.0.1:{0}/serverinfo' -f $server.Port))
            $raw = Invoke-ChildPowerShell -Command $hostBody -TimeoutSec 90
            Assert-True ($raw.StdOut.Contains('HOST-DONE summaryExists=True')) 'the interrupted run still wrote summary.json: ' + (($raw.StdOut -split "`r?`n" | Select-Object -Last 3) -join ' / ')
            $summary = Read-SoakSummary -OutputDir $area.OutputDir
            $cycles = @($summary.cycleResults)
            Assert-True ($cycles.Count -ge 1) 'the completed cycle 1 is present in the summary'
            Assert-Equal 1 $cycles[0].cycle 'the recorded cycle is cycle 1'
            Assert-Equal 'True' ([string]$cycles[0].success) 'cycle 1 succeeded before the interruption'
            Assert-True ($summary.verdict -eq 'fail') 'the interrupted run fails its verdict'
        } finally {
            Stop-FakeHttpServer -Server $server
        }
    }

    Invoke-Test 'Fake HTTP servers time out a silent client read instead of blocking forever' {
        $server = New-FakeHttpServer -StatusCode 200 -Body (New-ServerInfoXml)
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect('127.0.0.1', $server.Port)
            try {
                $stream = $client.GetStream()
                try { $stream.ReadTimeout = 12000 } catch { }
                $reader = New-Object System.IO.StreamReader($stream)
                $line = $null
                try { $line = $reader.ReadLine() } catch { }
                Assert-True ($null -ne $line) ('the server answered the silent connection within its read timeout, got: ' + $line)
                Assert-True ($line -like 'HTTP/1.1 200*') 'the canned response arrived despite the silent read'
            } finally {
                try { $client.Close() } catch { }
            }
        } finally {
            Stop-FakeHttpServer -Server $server
        }
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
