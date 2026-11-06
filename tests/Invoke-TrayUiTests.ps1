#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for the GsController tray UI model, host script, and launcher.
    No admin rights, no real tray icon, no real product, loopback network
    only; gs-tray.ps1 itself is never executed here.
    Exits 0 only when every test passes; exits 1 otherwise.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modelPath = Join-Path $repoRoot 'product\gs-tray-model.ps1'
$trayPath = Join-Path $repoRoot 'product\gs-tray.ps1'
$vbsPath = Join-Path $repoRoot 'product\gs-tray.vbs'
$zhStringsPath = Join-Path $repoRoot 'product\gs-tray-strings.zh-CN.json'

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

function Assert-StateRow {
    param($Actual, [string]$State, [string]$Detail, [bool]$CanStart, [bool]$CanStop, [string]$Message, $DetailKey = $null)
    Assert-Equal $State $Actual.State "$Message state"
    Assert-Equal $Detail $Actual.Detail "$Message detail"
    Assert-Equal $CanStart $Actual.CanStart "$Message CanStart"
    Assert-Equal $CanStop $Actual.CanStop "$Message CanStop"
    if ($null -ne $DetailKey) { Assert-Equal $DetailKey $Actual.DetailKey "$Message DetailKey" }
}

# ---- AST helpers for the K4 UI-text scan -----------------------------------
# $true when the node is a quoted string literal (single or double quotes),
# a parenthesized one, or a '+' concatenation of such literals. BareString
# constants (barewords like -Kind Warning) are not UI text and are exempt.
function Test-IsQuotedStringLiteralAst {
    param($Ast)
    if ($null -eq $Ast) { return $false }
    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return ($Ast.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::SingleQuoted -or
            $Ast.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::DoubleQuoted)
    }
    if ($Ast -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $pipeline = $Ast.Pipeline
        if ($null -ne $pipeline -and @($pipeline.PipelineElements).Count -eq 1) {
            $element = @($pipeline.PipelineElements)[0]
            if ($element -is [System.Management.Automation.Language.CommandExpressionAst]) {
                return (Test-IsQuotedStringLiteralAst $element.Expression)
            }
        }
        return $false
    }
    if ($Ast -is [System.Management.Automation.Language.BinaryExpressionAst] -and $Ast.Operator -eq [System.Management.Automation.Language.TokenKind]::Iplus) {
        return (Test-IsQuotedStringLiteralAst $Ast.Left) -and (Test-IsQuotedStringLiteralAst $Ast.Right)
    }
    return $false
}

# Collects quoted string literals passed as direct arguments to UI calls in
# one script file: every .Add(...) receiver, ShowBalloonTip(...),
# MessageBox::Show(...) and the tray's own Show-Balloon wrapper (K4: every
# user-visible text must come from the string table). Returns a list of
# '<call>: <literal>' descriptions; empty means clean. Hashtable index keys
# (e.g. $script:TrayStrings['menu.start']) are index expressions, not direct
# string arguments, and therefore pass.
function Get-GsTrayUiLiteralViolations {
    param([string]$Path)
    $violations = New-Object System.Collections.Generic.List[string]
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $nodes = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.MemberExpressionAst] -or $node -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($node in $nodes) {
        $callArgs = $null
        $label = ''
        if ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            $memberName = $node.Member.Extent.Text
            if ($memberName -eq 'ShowBalloonTip' -or $memberName -eq 'Add') {
                $callArgs = $node.Arguments
                $label = $memberName
            } elseif ($memberName -eq 'Show' -and $node.Expression.Extent.Text -like '*MessageBox') {
                $callArgs = $node.Arguments
                $label = 'MessageBox::Show'
            }
        } elseif ($node -is [System.Management.Automation.Language.CommandAst]) {
            if ($node.GetCommandName() -eq 'Show-Balloon') {
                $callArgs = @($node.CommandElements | Select-Object -Skip 1)
                $label = 'Show-Balloon'
            }
        }
        if ($null -ne $callArgs) {
            foreach ($arg in $callArgs) {
                if (Test-IsQuotedStringLiteralAst $arg) { $violations.Add(($label + ': ' + $arg.Extent.Text)) }
            }
        }
    }
    return $violations
}

# Hand-built inputs for mapping tests (the shapes the model itself produces).
function New-FakeStatusInfo {
    param([bool]$Exists = $true, [bool]$Readable = $true, $State = $null, [string]$Err = '', $LastWriteTimeUtc = $null)
    return [pscustomobject]@{ Path = 'synthetic'; Exists = $Exists; Readable = $Readable; LastWriteTimeUtc = $LastWriteTimeUtc; State = $State; Error = $Err }
}

function New-FakeServerInfo {
    param([int]$HttpStatus = 200, [int]$ProtocolStatus = 200, [bool]$ParseOk = $true, [string]$State = '', [string]$CurrentGame = '')
    return [pscustomobject]@{
        HttpStatus = $HttpStatus
        ProtocolStatus = $ProtocolStatus
        ParseOk = $ParseOk
        State = $State
        CurrentGame = $CurrentGame
    }
}

# Starts a fake loopback HTTP server on port 0 (TcpListener, background
# runspace) that writes one canned HTTP response (ASCII -ResponseText, or
# raw -ResponseBytes for bodies that are not ASCII-representable), or holds
# the connection open without answering when -HoldOpen is set.
function Start-FakeServerInfo {
    param([string]$ResponseText = '', [bool]$HoldOpen = $false, [byte[]]$ResponseBytes = $null)
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $engine = [powershell]::Create()
    $engine.AddScript({
        param($Listener, $Response, $Hold, $Bytes)
        try {
            $client = $Listener.AcceptTcpClient()
            if ($Hold) {
                Start-Sleep -Seconds 60
            } else {
                $stream = $client.GetStream()
                # Drain the request head before answering: a socket closed
                # with unread received data sends a TCP reset, which would
                # truncate a large canned body mid-read instead of ending it
                # cleanly.
                $drain = New-Object byte[] 8192
                $drainDeadline = [DateTime]::UtcNow.AddMilliseconds(300)
                $sawRequest = $false
                while ([DateTime]::UtcNow -lt $drainDeadline -and -not $sawRequest) {
                    while ($stream.DataAvailable) {
                        [void]$stream.Read($drain, 0, $drain.Length)
                        $sawRequest = $true
                    }
                    if (-not $sawRequest) { Start-Sleep -Milliseconds 5 }
                }
                if ($null -ne $Bytes) {
                    $stream.Write($Bytes, 0, $Bytes.Length)
                } else {
                    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Response)
                    $stream.Write($bytes, 0, $bytes.Length)
                }
                $stream.Flush()
            }
            try { $client.Close() } catch { }
        } catch { }
    }).AddArgument($listener).AddArgument($ResponseText).AddArgument($HoldOpen).AddArgument($ResponseBytes) | Out-Null
    $handle = $engine.BeginInvoke()
    return [pscustomobject]@{ Port = $port; Listener = $listener; Engine = $engine; Handle = $handle }
}

function Build-FakeHttpResponse {
    param([string]$StatusText = '200 OK', [string]$BodyText = '')
    $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes($BodyText)
    return "HTTP/1.1 $StatusText`r`nContent-Type: text/xml`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n$BodyText"
}

function Stop-FakeServerInfo {
    param($Fake)
    try { $Fake.Listener.Stop() } catch { }
    try { $Fake.Engine.Stop() } catch { }
    try { $Fake.Engine.Dispose() } catch { }
}

# Runs one built child command (plain powershell.exe, no RunAs) and waits.
function Invoke-TestChildCommand {
    param([string]$Arguments, [int]$TimeoutMs = 20000)
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    try {
        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) { throw "child powershell did not exit within $TimeoutMs ms" }
        return $proc.ExitCode
    } finally {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        try { $proc.Dispose() } catch { }
    }
}

# Builds a full string-table JSON for the round-4 table-validation tests:
# every built-in key with its English value as the stand-in translated
# value, plus optional per-key overrides. The result passes every load
# validation except the rule under test.
function New-FullTableJson {
    param($Overrides = @{})
    $en = Get-GsTrayBuiltinStrings
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('{')
    $first = $true
    foreach ($key in $en.Keys) {
        if (-not $first) { $parts.Add(',') }
        $first = $false
        $value = [string]$en[$key]
        if ($overrides.ContainsKey([string]$key)) { $value = [string]$overrides[[string]$key] }
        $value = $value.Replace('\', '\\').Replace('"', '\"')
        $parts.Add('"' + $key + '": "' + $value + '"')
    }
    $parts.Add('}')
    return ($parts -join "`n")
}

try {
    . $modelPath
} catch {
    Write-Host "FAIL model import :: $($_.Exception.Message)"
    exit 1
}

if (-not (Test-Path -LiteralPath $trayPath -PathType Leaf)) { Write-Host 'FAIL gs-tray.ps1 missing'; exit 1 }
if (-not (Test-Path -LiteralPath $vbsPath -PathType Leaf)) { Write-Host 'FAIL gs-tray.vbs missing'; exit 1 }

$tempRoot = [System.IO.Path]::GetTempPath()
$workDir = Join-Path $tempRoot ('GsTrayUi_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null
$workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath
$resultsDir = Join-Path $workDir 'results'
New-Item -ItemType Directory -Path $resultsDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

function New-TestFile {
    param([string]$Name, [string]$Content)
    $p = Join-Path $workDir $Name
    [System.IO.File]::WriteAllText($p, $Content, $utf8)
    return $p
}

# Directory whose name contains a space and a single quote, holding a fake
# gs-product.ps1 whose file name contains a space.
$weirdDir = Join-Path $workDir "dir with space and it's"
New-Item -ItemType Directory -Path $weirdDir | Out-Null
$weirdProduct = Join-Path $weirdDir 'fake gs-product.ps1'

$fakeBusyScript = @'
param([string]$Action, [string]$StateDir, [string]$LogDir)
[pscustomobject]@{ Success = $false; Data = $null; Errors = @([pscustomobject]@{ Code = 'Busy'; Message = 'Another lifecycle operation is running.' }) }
'@
$fakeThrowScript = @'
param([string]$Action, [string]$StateDir, [string]$LogDir)
throw 'boom from fake gs-product'
'@
$fakeOkScript = @'
param([string]$Action, [string]$StateDir, [string]$LogDir)
[pscustomobject]@{ Success = $true; Data = $null; Errors = @() }
'@

try {
    # ---- Get-GsTrayState: pending overrides ----
    Invoke-Test 'Pending Start beats every underlying state' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Exists $false) -ServerInfo $null -PendingAction 'Start'
        Assert-StateRow $row 'Starting' 'Starting...' $false $false 'pending start on missing file'
        $row2 = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_FREE' -CurrentGame '0') -PendingAction 'Start'
        Assert-StateRow $row2 'Starting' 'Starting...' $false $false 'pending start on ready'
    }

    Invoke-Test 'Pending Stop maps to Stopping with both actions disabled' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_FREE' -CurrentGame '0') -PendingAction 'Stop'
        Assert-StateRow $row 'Stopping' 'Stopping...' $false $false 'pending stop on ready'
        $row2 = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Exists $false) -ServerInfo $null -PendingAction 'Stop'
        Assert-StateRow $row2 'Stopping' 'Stopping...' $false $false 'pending stop on missing file'
        $row3 = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'failed') -ServerInfo $null -PendingAction 'Stop'
        Assert-StateRow $row3 'Stopping' 'Stopping...' $false $false 'pending stop on failed'
    }

    # ---- Get-GsTrayState: status file rows ----
    Invoke-Test 'Missing status file maps to Stopped' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Exists $false) -ServerInfo $null
        Assert-StateRow $row 'Stopped' 'Stopped (no status file)' $true $false 'missing file'
    }

    Invoke-Test 'Null status info maps to Stopped' {
        $row = Get-GsTrayState -StatusInfo $null -ServerInfo $null
        Assert-StateRow $row 'Stopped' 'Stopped (no status file)' $true $false 'null info'
    }

    Invoke-Test 'Unreadable status file maps to Error' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Readable $false -Err 'ReadFailed') -ServerInfo $null
        Assert-StateRow $row 'Error' 'Status file unreadable' $true $true 'unreadable'
    }

    Invoke-Test 'Invalid JSON maps to Error' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'InvalidJson') -ServerInfo $null
        Assert-StateRow $row 'Error' 'Status file invalid' $true $true 'invalid json'
    }

    Invoke-Test 'Missing state field maps to Error' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'MissingStateField') -ServerInfo $null
        Assert-StateRow $row 'Error' 'Status file has no state field' $true $true 'no state field'
    }

    Invoke-Test 'Non-string state field maps to Error' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'InvalidStateField') -ServerInfo $null
        Assert-StateRow $row 'Error' 'Status file has no valid state field' $true $true 'invalid state field'
    }

    Invoke-Test 'Boolean state value is reported as InvalidStateField' {
        $p = New-TestFile 'bool-status.json' '{"state":true}'
        $info = Read-GsTrayStatusFile -Path $p
        Assert-Equal 'InvalidStateField' $info.Error 'bool error code'
        Assert-True ($null -eq $info.State) 'bool no state'
        $row = Get-GsTrayState -StatusInfo $info -ServerInfo $null
        Assert-StateRow $row 'Error' 'Status file has no valid state field' $true $true 'bool row'
    }

    # ---- Get-GsTrayState: ready/running with serverinfo ----
    Invoke-Test 'Ready with free serverinfo maps to Ready' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_FREE' -CurrentGame '0')
        Assert-StateRow $row 'Ready' 'Ready' $false $true 'ready free'
    }

    Invoke-Test 'Ready with currentgame 0 and empty game maps to Ready' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_FREE' -CurrentGame '')
        Assert-StateRow $row 'Ready' 'Ready' $false $true 'empty game'
        $row2 = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_FREE' -CurrentGame ' 0 ')
        Assert-StateRow $row2 'Ready' 'Ready' $false $true 'game 0 padded'
    }

    Invoke-Test 'Ready with a current game maps to Streaming' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_BUSY' -CurrentGame '42')
        Assert-StateRow $row 'Streaming' 'Streaming' $false $true 'game 42'
    }

    Invoke-Test 'Ready with _SERVER_BUSY state maps to Streaming even with game 0' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_BUSY' -CurrentGame '0')
        Assert-StateRow $row 'Streaming' 'Streaming' $false $true 'busy suffix'
    }

    Invoke-Test 'Running with a current game maps to Streaming' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'running') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_BUSY' -CurrentGame '7')
        Assert-StateRow $row 'Streaming' 'Streaming' $false $true 'running busy'
    }

    Invoke-Test 'Ready without serverinfo maps to Error with documented detail' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $null
        Assert-StateRow $row 'Error' 'runtime ready but serverinfo unreachable' $true $true 'serverinfo null'
    }

    Invoke-Test 'Ready with non-200 serverinfo maps to Error with documented detail' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 404)
        Assert-StateRow $row 'Error' 'runtime ready but serverinfo unreachable' $true $true 'serverinfo 404'
    }

    Invoke-Test 'Ready with unparseable serverinfo maps to Error as invalid' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -ProtocolStatus 0 -ParseOk $false -State '' -CurrentGame '')
        Assert-StateRow $row 'Error' 'runtime ready but serverinfo invalid' $true $true 'parse failed'
    }

    Invoke-Test 'Ready with non-200 protocol status maps to Error as invalid' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -ProtocolStatus 503 -ParseOk $true -State 'X_SERVER_FREE' -CurrentGame '0')
        Assert-StateRow $row 'Error' 'runtime ready but serverinfo invalid' $true $true 'protocol 503'
    }

    Invoke-Test 'Status values are matched case-insensitively' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'READY') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'gs_server_free' -CurrentGame '0')
        Assert-StateRow $row 'Ready' 'Ready' $false $true 'READY'
        $row2 = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State ' Stopped ') -ServerInfo $null
        Assert-StateRow $row2 'Stopped' 'Stopped' $true $false 'padded stopped'
    }

    # ---- Get-GsTrayState: other documented status values ----
    Invoke-Test 'starting/launching/initializing map to Starting' {
        foreach ($value in @('starting', 'launching', 'initializing')) {
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State $value) -ServerInfo $null
            Assert-StateRow $row 'Starting' 'Starting...' $false $true "state $value"
        }
    }

    Invoke-Test 'stopped/paused/idle map to Stopped' {
        foreach ($value in @('stopped', 'paused', 'idle')) {
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State $value) -ServerInfo $null
            Assert-StateRow $row 'Stopped' 'Stopped' $true $false "state $value"
        }
    }

    Invoke-Test 'stopping maps to Stopping with both actions disabled' {
        # A status of 'stopping' gets its own Stopping tray state (orange
        # icon): showing Stopped would enable Start while the runtime is
        # still shutting down. Freshness is judged against -NowUtc; a fresh
        # file keeps the trusting Stopping row.
        $now = [DateTime]::UtcNow
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc $now) -ServerInfo $null -NowUtc $now
        Assert-StateRow $row 'Stopping' 'Stopping...' $false $false 'stopping'
    }

    Invoke-Test 'Stale stopping (older than 300 s) maps to Error enabling both actions' {
        # A stale 'stopping' must not lock both menu items forever. The
        # stopping grace period is 300 s (the tray's own pending wait cap);
        # only files strictly older than that count as stale.
        $now = [DateTime]::UtcNow
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc $now.AddSeconds(-301)) -ServerInfo $null -NowUtc $now
        Assert-StateRow $row 'Error' 'Stopping did not finish' $true $true 'stale stopping'
    }

    Invoke-Test 'Stale starting family (older than 120 s) maps to Error enabling both actions' {
        $now = [DateTime]::UtcNow
        foreach ($value in @('starting', 'launching', 'initializing')) {
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State $value -LastWriteTimeUtc $now.AddSeconds(-121)) -ServerInfo $null -NowUtc $now
            Assert-StateRow $row 'Error' 'Starting did not finish' $true $true "stale $value"
        }
    }

    Invoke-Test 'Exactly 120 s old transitions are still fresh' {
        # Boundary: only files strictly older than 120 s count as stale; at
        # exactly 120 s the transition is still trusted.
        $now = [DateTime]::UtcNow
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc $now.AddSeconds(-120)) -ServerInfo $null -NowUtc $now
        Assert-StateRow $row 'Stopping' 'Stopping...' $false $false 'stopping at the boundary'
        $row2 = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'starting' -LastWriteTimeUtc $now.AddSeconds(-120)) -ServerInfo $null -NowUtc $now
        Assert-StateRow $row2 'Starting' 'Starting...' $false $true 'starting at the boundary'
    }

    Invoke-Test 'Stopping stays fresh through 121, 140 and 300 s (real stops measure 138-142 s)' {
        # Regression (2026-10-31 field finding): a real official-service Stop
        # takes 138-142 s, which tripped the old flat 120 s transition
        # timeout and flashed 'Stopping did not finish' even though the stop
        # succeeded later. The stopping grace period is now 300 s (the same
        # cap as the tray's own pending-action wait): ages 121, 140 and 300 s
        # must all keep the trusting Stopping row.
        $now = [DateTime]::UtcNow
        foreach ($age in @(121, 140, 300)) {
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc $now.AddSeconds(-$age)) -ServerInfo $null -NowUtc $now
            Assert-StateRow $row 'Stopping' 'Stopping...' $false $false ('stopping at ' + $age + ' s')
        }
    }

    Invoke-Test 'External stop without a pending action: Stopping inside the grace, Stopped after completion' {
        # An external CLI stop (or a tray restarted mid-stop) has NO pending
        # Stop override: the row must come from the status file alone -
        # Stopping while the file is inside the stopping grace period, then
        # Stopped as soon as the file flips to 'stopped'.
        $now = [DateTime]::UtcNow
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc $now.AddSeconds(-140)) -ServerInfo $null -NowUtc $now
        Assert-StateRow $row 'Stopping' 'Stopping...' $false $false 'external stop at 140 s'
        $row2 = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopped') -ServerInfo $null -NowUtc $now
        Assert-StateRow $row2 'Stopped' 'Stopped' $true $false 'external stop completed'
    }

    Invoke-Test 'Own pending Stop: override shows Stopping at 140 s, completion maps to Stopped' {
        # The tray's own pending Stop overrides whatever the file says while
        # the CLI child runs; once the child finishes, the pending action is
        # cleared and the same file content maps on its own again.
        $now = [DateTime]::UtcNow
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc $now.AddSeconds(-140)) -ServerInfo $null -NowUtc $now -PendingAction 'Stop'
        Assert-StateRow $row 'Stopping' 'Stopping...' $false $false 'own pending stop at 140 s'
        $row2 = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopped') -ServerInfo $null -NowUtc $now
        Assert-StateRow $row2 'Stopped' 'Stopped' $true $false 'own stop completed (pending cleared)'
    }

    Invoke-Test 'Fresh transitions keep their restricted actions; expired ones enable both' {
        # A fresh stopping row locks both menu items; the expired Error row
        # is the recovery surface and enables both. The starting family keeps
        # its own 120 s boundary unchanged (120 fresh, 121 stale).
        $now = [DateTime]::UtcNow
        $freshStopping = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc $now.AddSeconds(-299)) -ServerInfo $null -NowUtc $now
        Assert-StateRow $freshStopping 'Stopping' 'Stopping...' $false $false 'fresh stopping at 299 s'
        $expiredStopping = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc $now.AddSeconds(-301)) -ServerInfo $null -NowUtc $now
        Assert-StateRow $expiredStopping 'Error' 'Stopping did not finish' $true $true 'expired stopping at 301 s'
        $freshStarting = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'starting' -LastWriteTimeUtc $now.AddSeconds(-119)) -ServerInfo $null -NowUtc $now
        Assert-StateRow $freshStarting 'Starting' 'Starting...' $false $true 'fresh starting at 119 s'
        $expiredStarting = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'starting' -LastWriteTimeUtc $now.AddSeconds(-121)) -ServerInfo $null -NowUtc $now
        Assert-StateRow $expiredStarting 'Error' 'Starting did not finish' $true $true 'expired starting at 121 s'
    }

    Invoke-Test 'Pending Stop wins over a stale stopping status' {
        $now = [DateTime]::UtcNow
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc $now.AddSeconds(-301)) -ServerInfo $null -NowUtc $now -PendingAction 'Stop'
        Assert-StateRow $row 'Stopping' 'Stopping...' $false $false 'pending stop on stale stopping'
    }

    Invoke-Test 'failed/error map to Error' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'failed') -ServerInfo $null
        Assert-StateRow $row 'Error' 'Runtime reports failed' $true $true 'failed'
        $row2 = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'error') -ServerInfo $null
        Assert-StateRow $row2 'Error' 'Runtime reports error' $true $true 'error'
    }

    Invoke-Test 'Unknown state maps to Error with unknown-state detail' {
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'warp') -ServerInfo $null
        Assert-StateRow $row 'Error' 'unknown state warp' $true $true 'warp'
    }

    Invoke-Test 'Every Error row enables both Start and Stop' {
        $errorRows = @(
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Readable $false -Err 'ReadFailed') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'InvalidJson') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'MissingStateField') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'InvalidStateField') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'failed') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'error') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'warp') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 503)),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -ParseOk $false)),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc ([DateTime]::UtcNow.AddSeconds(-301))) -ServerInfo $null -NowUtc ([DateTime]::UtcNow)),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'starting' -LastWriteTimeUtc ([DateTime]::UtcNow.AddSeconds(-121))) -ServerInfo $null -NowUtc ([DateTime]::UtcNow))
        )
        foreach ($row in $errorRows) {
            Assert-Equal 'Error' $row.State 'row is an Error row'
            Assert-Equal $true $row.CanStart 'Error row CanStart'
            Assert-Equal $true $row.CanStop 'Error row CanStop'
        }
    }

    Invoke-Test 'Detail never exceeds the 63 character NotifyIcon limit' {
        $long = 'x' * 200
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State $long) -ServerInfo $null
        Assert-Equal 'Error' $row.State 'state'
        Assert-True ($row.Detail.Length -le 63) ('detail length ' + $row.Detail.Length)
    }

    # ---- Status path selection ----
    Invoke-Test 'Only the primary candidate exists: primary wins' {
        $dir = Join-Path $workDir 'sel-only-a'
        New-Item -ItemType Directory -Path (Join-Path $dir 'runtime\state') -Force | Out-Null
        $aPath = Join-Path $dir 'runtime\state\status.json'
        [System.IO.File]::WriteAllText($aPath, '{"state":"ready"}', $utf8)
        Assert-Equal $aPath (Resolve-GsTrayStatusPath -StateDir $dir) 'chosen path'
    }

    Invoke-Test 'Only the fallback candidate exists: fallback wins' {
        $dir = Join-Path $workDir 'sel-only-b'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $bPath = Join-Path $dir 'status.json'
        [System.IO.File]::WriteAllText($bPath, '{"state":"ready"}', $utf8)
        Assert-Equal $bPath (Resolve-GsTrayStatusPath -StateDir $dir) 'chosen path'
    }

    Invoke-Test 'Both candidates exist: the newer file wins (fallback newer)' {
        $dir = Join-Path $workDir 'sel-both-b'
        New-Item -ItemType Directory -Path (Join-Path $dir 'runtime\state') -Force | Out-Null
        $aPath = Join-Path $dir 'runtime\state\status.json'
        $bPath = Join-Path $dir 'status.json'
        [System.IO.File]::WriteAllText($aPath, '{"state":"ready"}', $utf8)
        [System.IO.File]::WriteAllText($bPath, '{"state":"ready"}', $utf8)
        $base = (Get-Date).ToUniversalTime()
        (Get-Item -LiteralPath $aPath).LastWriteTimeUtc = $base.AddHours(-2)
        (Get-Item -LiteralPath $bPath).LastWriteTimeUtc = $base.AddHours(-1)
        Assert-Equal $bPath (Resolve-GsTrayStatusPath -StateDir $dir) 'newer fallback wins'
    }

    Invoke-Test 'Both candidates exist: the newer file wins (primary newer)' {
        $dir = Join-Path $workDir 'sel-both-a'
        New-Item -ItemType Directory -Path (Join-Path $dir 'runtime\state') -Force | Out-Null
        $aPath = Join-Path $dir 'runtime\state\status.json'
        $bPath = Join-Path $dir 'status.json'
        [System.IO.File]::WriteAllText($aPath, '{"state":"ready"}', $utf8)
        [System.IO.File]::WriteAllText($bPath, '{"state":"ready"}', $utf8)
        $base = (Get-Date).ToUniversalTime()
        (Get-Item -LiteralPath $aPath).LastWriteTimeUtc = $base.AddHours(-1)
        (Get-Item -LiteralPath $bPath).LastWriteTimeUtc = $base.AddHours(-2)
        Assert-Equal $aPath (Resolve-GsTrayStatusPath -StateDir $dir) 'newer primary wins'
    }

    Invoke-Test 'No candidate exists: primary path reported as missing' {
        $dir = Join-Path $workDir 'sel-none'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $aPath = Join-Path $dir 'runtime\state\status.json'
        Assert-Equal $aPath (Resolve-GsTrayStatusPath -StateDir $dir) 'chosen path'
        $info = Get-GsTrayStatusInfo -StateDir $dir
        Assert-Equal $aPath $info.Path 'info path'
        Assert-True (-not $info.Exists) 'not exists'
        Assert-True (-not $info.Readable) 'not readable'
        Assert-True ($null -eq $info.Error) 'no error'
    }

    # ---- Status file read errors ----
    Invoke-Test 'Locked status file is reported as ReadFailed' {
        $p = New-TestFile 'locked-status.json' '{"state":"ready"}'
        $lock = [System.IO.File]::Open($p, 'Open', 'Read', 'None')
        try { $info = Read-GsTrayStatusFile -Path $p } finally { $lock.Dispose() }
        Assert-True $info.Exists 'exists'
        Assert-True (-not $info.Readable) 'not readable'
        Assert-Equal 'ReadFailed' $info.Error 'error code'
        $row = Get-GsTrayState -StatusInfo $info -ServerInfo $null
        Assert-StateRow $row 'Error' 'Status file unreadable' $true $true 'unreadable row'
    }

    Invoke-Test 'Invalid JSON is reported and maps to Error' {
        $p = New-TestFile 'broken-status.json' '{ "state": '
        $info = Read-GsTrayStatusFile -Path $p
        Assert-True $info.Exists 'exists'
        Assert-True $info.Readable 'readable'
        Assert-Equal 'InvalidJson' $info.Error 'error code'
        Assert-True ($null -eq $info.State) 'no state'
        $row = Get-GsTrayState -StatusInfo $info -ServerInfo $null
        Assert-StateRow $row 'Error' 'Status file invalid' $true $true 'invalid row'
    }

    Invoke-Test 'JSON without a state field is reported' {
        $p = New-TestFile 'nostate-status.json' '{"other":1}'
        $info = Read-GsTrayStatusFile -Path $p
        Assert-Equal 'MissingStateField' $info.Error 'error code'
        $row = Get-GsTrayState -StatusInfo $info -ServerInfo $null
        Assert-StateRow $row 'Error' 'Status file has no state field' $true $true 'no-state row'
    }

    Invoke-Test 'Array, number and object state values are reported as InvalidStateField' {
        foreach ($case in @(@('array-status.json', '{"state":[1]}'), @('number-status.json', '{"state":5}'), @('object-status.json', '{"state":{}}'))) {
            $p = New-TestFile $case[0] $case[1]
            $info = Read-GsTrayStatusFile -Path $p
            Assert-Equal 'InvalidStateField' $info.Error ($case[0] + ' error code')
            Assert-True ($null -eq $info.State) ($case[0] + ' no state')
            $row = Get-GsTrayState -StatusInfo $info -ServerInfo $null
            Assert-StateRow $row 'Error' 'Status file has no valid state field' $true $true ($case[0] + ' row')
        }
    }

    Invoke-Test 'Null state value is reported as missing' {
        $p = New-TestFile 'nullstate-status.json' '{"state":null}'
        $info = Read-GsTrayStatusFile -Path $p
        Assert-Equal 'MissingStateField' $info.Error 'error code'
    }

    # ---- Freshness: every read sees the current file ----
    $freshDir = Join-Path $workDir 'fresh-state'
    $freshStatusDir = Join-Path $freshDir 'runtime\state'
    New-Item -ItemType Directory -Path $freshStatusDir -Force | Out-Null
    $freshStatusFile = Join-Path $freshStatusDir 'status.json'
    [System.IO.File]::WriteAllText($freshStatusFile, '{"state":"ready"}', $utf8)

    Invoke-Test 'Freshness: state ready reads as Ready' {
        $info = Get-GsTrayStatusInfo -StateDir $freshDir
        Assert-Equal $freshStatusFile $info.Path 'primary selected'
        Assert-Equal 'ready' $info.State 'raw state'
        $row = Get-GsTrayState -StatusInfo $info -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_FREE' -CurrentGame '0')
        Assert-StateRow $row 'Ready' 'Ready' $false $true 'fresh ready'
    }

    Invoke-Test 'Freshness: rewritten file is picked up on the next read' {
        [System.IO.File]::WriteAllText($freshStatusFile, '{"state":"stopped"}', $utf8)
        $info = Get-GsTrayStatusInfo -StateDir $freshDir
        Assert-Equal 'stopped' $info.State 'raw state after rewrite'
        $row = Get-GsTrayState -StatusInfo $info -ServerInfo $null
        Assert-StateRow $row 'Stopped' 'Stopped' $true $false 'fresh stopped'
    }

    # ---- serverinfo XML parsing ----
    Invoke-Test 'Serverinfo XML free parses all fields' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>GS_SERVER_FREE</state><currentgame>0</currentgame></root>'
        Assert-Equal 200 $parsed.ProtocolStatus 'protocol status'
        Assert-True $parsed.ParseOk 'parse ok'
        Assert-Equal 'GS_SERVER_FREE' $parsed.State 'state'
        Assert-Equal '0' $parsed.CurrentGame 'current game'
    }

    Invoke-Test 'Serverinfo XML busy parses all fields' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>GS_SERVER_BUSY</state><currentgame>12345</currentgame></root>'
        Assert-Equal 200 $parsed.ProtocolStatus 'protocol status'
        Assert-True $parsed.ParseOk 'parse ok'
        Assert-Equal 'GS_SERVER_BUSY' $parsed.State 'state'
        Assert-Equal '12345' $parsed.CurrentGame 'current game'
    }

    Invoke-Test 'Serverinfo state value is trimmed' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>X_SERVER_BUSY  </state><currentgame> 7 </currentgame></root>'
        Assert-True $parsed.ParseOk 'parse ok'
        Assert-Equal 'X_SERVER_BUSY' $parsed.State 'trimmed state'
        Assert-Equal '7' $parsed.CurrentGame 'trimmed game'
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -ProtocolStatus 200 -ParseOk $true -State 'X_SERVER_BUSY  ' -CurrentGame '0')
        Assert-StateRow $row 'Streaming' 'Streaming' $false $true 'padded busy maps to Streaming'
    }

    Invoke-Test 'Serverinfo with non-200 status_code keeps the value but does not parse' {
        # Unified validity rule: status_code must match ^\d{1,10}$ and equal
        # 200 for ParseOk; any other value keeps ProtocolStatus but fails.
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="503"><state>X_SERVER_FREE</state><currentgame>0</currentgame></root>'
        Assert-Equal 503 $parsed.ProtocolStatus 'protocol status kept'
        Assert-True (-not $parsed.ParseOk) 'parse ok false (status_code is not 200)'
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -ProtocolStatus 503 -ParseOk $true -State 'X_SERVER_FREE' -CurrentGame '0')
        Assert-StateRow $row 'Error' 'runtime ready but serverinfo invalid' $true $true 'protocol 503 row'
    }

    Invoke-Test 'Serverinfo malformed XML yields an unparseable record' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>GS_SERVER_FREE'
        Assert-Equal 0 $parsed.ProtocolStatus 'protocol status'
        Assert-True (-not $parsed.ParseOk) 'parse ok false'
        Assert-Equal '' $parsed.State 'state'
        Assert-Equal '' $parsed.CurrentGame 'current game'
    }

    Invoke-Test 'Serverinfo XML with missing fields does not parse' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"></root>'
        Assert-Equal 200 $parsed.ProtocolStatus 'protocol status kept'
        Assert-True (-not $parsed.ParseOk) 'parse ok false (no state)'
        Assert-Equal '' $parsed.State 'state'
        $parsed2 = ConvertFrom-GsServerInfoXml -XmlText '<root><state>GS_SERVER_FREE</state></root>'
        Assert-Equal 0 $parsed2.ProtocolStatus 'no status code'
        Assert-True (-not $parsed2.ParseOk) 'parse ok false (no status_code, no currentgame)'
        $parsed3 = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><currentgame>3</currentgame></root>'
        Assert-True (-not $parsed3.ParseOk) 'parse ok false (missing state)'
    }

    Invoke-Test 'Serverinfo with empty or non-digit currentgame does not parse' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>X_SERVER_FREE</state><currentgame></currentgame></root>'
        Assert-True (-not $parsed.ParseOk) 'empty game'
        $parsed2 = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>X_SERVER_FREE</state><currentgame>x42</currentgame></root>'
        Assert-True (-not $parsed2.ParseOk) 'non-digit game'
        $parsed3 = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>   </state><currentgame>0</currentgame></root>'
        Assert-True (-not $parsed3.ParseOk) 'whitespace-only state'
    }

    Invoke-Test 'Serverinfo empty input yields an unparseable record' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText ''
        Assert-Equal 0 $parsed.ProtocolStatus 'protocol status'
        Assert-True (-not $parsed.ParseOk) 'empty text parse ok'
        $parsed2 = ConvertFrom-GsServerInfoXml -XmlText '   '
        Assert-True (-not $parsed2.ParseOk) 'whitespace parse ok'
        $parsed3 = ConvertFrom-GsServerInfoXml -XmlText 'not xml'
        Assert-True (-not $parsed3.ParseOk) 'plain text parse ok'
    }

    Invoke-Test 'Serverinfo XML root must be exactly root (case-sensitive)' {
        # The streamer always answers with a <root> element; any other root
        # name - including a different case - is not treated as serverinfo.
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<foo status_code="200"><state>GS_SERVER_FREE</state><currentgame>0</currentgame></foo>'
        Assert-True (-not $parsed.ParseOk) 'foo root parse ok false'
        $parsed2 = ConvertFrom-GsServerInfoXml -XmlText '<ROOT status_code="200"><state>GS_SERVER_FREE</state><currentgame>0</currentgame></ROOT>'
        Assert-True (-not $parsed2.ParseOk) 'ROOT root parse ok false'
    }

    Invoke-Test 'Serverinfo status_code must be a 1-10 digit 200' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="12345678901"><state>X_SERVER_FREE</state><currentgame>0</currentgame></root>'
        Assert-Equal 0 $parsed.ProtocolStatus '11 digit status code not parsed'
        Assert-True (-not $parsed.ParseOk) '11 digit status code parse ok false'
    }

    Invoke-Test 'Serverinfo currentgame longer than 10 digits does not parse' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>GS_SERVER_FREE</state><currentgame>12345678901</currentgame></root>'
        Assert-True (-not $parsed.ParseOk) '11 digit game parse ok false'
        $parsed2 = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>GS_SERVER_FREE</state><currentgame>1234567890</currentgame></root>'
        Assert-True $parsed2.ParseOk '10 digit game parses'
        Assert-Equal '1234567890' $parsed2.CurrentGame '10 digit game kept'
    }

    Invoke-Test 'Serverinfo currentgame padded with spaces is valid and trimmed' {
        $parsed = ConvertFrom-GsServerInfoXml -XmlText '<root status_code="200"><state>GS_SERVER_FREE</state><currentgame> 1 </currentgame></root>'
        Assert-True $parsed.ParseOk 'padded game parse ok'
        Assert-Equal '1' $parsed.CurrentGame 'padded game trimmed'
    }

    # ---- serverinfo fetch over loopback ----
    Invoke-Test 'Serverinfo fetch reads a free fake server' {
        $fake = Start-FakeServerInfo -ResponseText (Build-FakeHttpResponse -StatusText '200 OK' -BodyText '<root status_code="200"><state>GS_SERVER_FREE</state><currentgame>0</currentgame></root>')
        try {
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            Assert-Equal 200 $result.HttpStatus 'http status'
            Assert-Equal 200 $result.ProtocolStatus 'protocol status'
            Assert-True $result.ParseOk 'parse ok'
            Assert-Equal 'GS_SERVER_FREE' $result.State 'state'
            Assert-Equal '0' $result.CurrentGame 'current game'
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $result
            Assert-StateRow $row 'Ready' 'Ready' $false $true 'ready free row'
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch reads a busy fake server' {
        $fake = Start-FakeServerInfo -ResponseText (Build-FakeHttpResponse -StatusText '200 OK' -BodyText '<root status_code="200"><state>GS_SERVER_BUSY</state><currentgame>99</currentgame></root>')
        try {
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            Assert-Equal 200 $result.HttpStatus 'http status'
            Assert-Equal 200 $result.ProtocolStatus 'protocol status'
            Assert-True $result.ParseOk 'parse ok'
            Assert-Equal 'GS_SERVER_BUSY' $result.State 'state'
            Assert-Equal '99' $result.CurrentGame 'current game'
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $result
            Assert-StateRow $row 'Streaming' 'Streaming' $false $true 'busy row'
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch with an HTTP 200 empty body reports invalid' {
        $fake = Start-FakeServerInfo -ResponseText (Build-FakeHttpResponse -StatusText '200 OK' -BodyText '')
        try {
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            Assert-Equal 200 $result.HttpStatus 'http status'
            Assert-True (-not $result.ParseOk) 'parse ok false'
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $result
            Assert-StateRow $row 'Error' 'runtime ready but serverinfo invalid' $true $true 'empty body row'
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch with HTTP 200 plain text body reports invalid' {
        $fake = Start-FakeServerInfo -ResponseText (Build-FakeHttpResponse -StatusText '200 OK' -BodyText 'not xml')
        try {
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            Assert-Equal 200 $result.HttpStatus 'http status'
            Assert-True (-not $result.ParseOk) 'parse ok false'
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $result
            Assert-StateRow $row 'Error' 'runtime ready but serverinfo invalid' $true $true 'not xml row'
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch with an empty currentgame reports invalid' {
        $fake = Start-FakeServerInfo -ResponseText (Build-FakeHttpResponse -StatusText '200 OK' -BodyText '<root status_code="200"><state>GS_SERVER_FREE</state><currentgame></currentgame></root>')
        try {
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            Assert-Equal 200 $result.HttpStatus 'http status'
            Assert-True (-not $result.ParseOk) 'parse ok false'
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $result
            Assert-StateRow $row 'Error' 'runtime ready but serverinfo invalid' $true $true 'empty currentgame row'
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch with HTTP 503 reports unreachable' {
        $fake = Start-FakeServerInfo -ResponseText (Build-FakeHttpResponse -StatusText '503 Service Unavailable' -BodyText '<root status_code="503"><state>X_SERVER_FREE</state><currentgame>0</currentgame></root>')
        try {
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            Assert-Equal 503 $result.HttpStatus 'http status'
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $result
            Assert-StateRow $row 'Error' 'runtime ready but serverinfo unreachable' $true $true 'http 503 row'
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch with a truncated body stops at the deadline and reports invalid' {
        # Large announced Content-Length with a small body, then hold: the
        # chunked read must give up within about the timeout instead of
        # blocking forever.
        $partial = 'HTTP/1.1 200 OK' + "`r`n" + 'Content-Type: text/xml' + "`r`n" + 'Content-Length: 100000' + "`r`n" + "`r`n" + '<root status_code="200"><state>GS_SE'
        $fake = Start-FakeServerInfo -ResponseText $partial
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            $watch.Stop()
            Assert-Equal 200 $result.HttpStatus 'http status'
            Assert-True (-not $result.ParseOk) 'parse ok false (truncated)'
            Assert-True ($watch.Elapsed.TotalMilliseconds -lt 3500) ('truncated body latency ms: ' + [int]$watch.Elapsed.TotalMilliseconds)
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch on a closed port returns quickly with status 0' {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Get-GsTrayServerInfo -Uri "http://127.0.0.1:$port/serverinfo"
        $watch.Stop()
        Assert-Equal 0 $result.HttpStatus 'closed port status'
        Assert-True (-not $result.ParseOk) 'closed port parse ok false'
        Assert-True ($watch.Elapsed.TotalMilliseconds -lt 3000) ('closed port latency ms: ' + [int]$watch.Elapsed.TotalMilliseconds)
    }

    Invoke-Test 'Serverinfo fetch honors the 1 second timeout' {
        $fake = Start-FakeServerInfo -HoldOpen $true
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            $watch.Stop()
            Assert-Equal 0 $result.HttpStatus 'timeout status'
            Assert-True (-not $result.ParseOk) 'timeout parse ok false'
            Assert-True ($watch.Elapsed.TotalMilliseconds -lt 3000) ('timeout latency ms: ' + [int]$watch.Elapsed.TotalMilliseconds)
            Assert-True ($watch.Elapsed.TotalMilliseconds -ge 900) ('returned too early ms: ' + [int]$watch.Elapsed.TotalMilliseconds)
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch caps the body at 65536 bytes before decoding' {
        # 22000 three-byte UTF-8 characters: the body is over the 65536 byte
        # cap while staying far below 65536 characters, so only a byte cap
        # applied before decoding can reject it.
        $filler = [string][char]0x3042 * 22000
        $body = '<root status_code="200"><note>' + $filler + '</note><state>GS_SERVER_FREE</state><currentgame>0</currentgame></root>'
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        Assert-True ($bodyBytes.Length -gt 65536) ('body bytes over the cap: ' + $bodyBytes.Length)
        Assert-True ($body.Length -lt 65536) ('body chars under the cap: ' + $body.Length)
        $head = "HTTP/1.1 200 OK`r`nContent-Type: text/xml`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
        $allBytes = New-Object System.Collections.Generic.List[byte]
        foreach ($headByte in [System.Text.Encoding]::ASCII.GetBytes($head)) { [void]$allBytes.Add($headByte) }
        foreach ($bodyByte in $bodyBytes) { [void]$allBytes.Add($bodyByte) }
        $fake = Start-FakeServerInfo -ResponseBytes $allBytes.ToArray()
        try {
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            Assert-Equal 200 $result.HttpStatus 'http status'
            Assert-True (-not $result.ParseOk) 'parse ok false over the byte cap'
            Assert-True ($result.ParseError -like '*65536*') ('parse error mentions the cap: ' + $result.ParseError)
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $result
            Assert-StateRow $row 'Error' 'runtime ready but serverinfo invalid' $true $true 'byte cap row'
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch accepts a body of exactly 65536 bytes' {
        # The byte cap is inclusive: 65536 bytes is valid (when otherwise
        # well-formed); only 65537 and more are over the cap.
        $prefix = '<root status_code="200"><note>'
        $suffix = '</note><state>GS_SERVER_FREE</state><currentgame>0</currentgame></root>'
        $body = $prefix + ([string][char]120 * (65536 - $prefix.Length - $suffix.Length)) + $suffix
        Assert-Equal 65536 ([System.Text.Encoding]::ASCII.GetByteCount($body)) 'body is exactly the cap'
        $head = "HTTP/1.1 200 OK`r`nContent-Type: text/xml`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
        $fake = Start-FakeServerInfo -ResponseText ($head + $body)
        try {
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            Assert-Equal 200 $result.HttpStatus 'http status'
            Assert-True $result.ParseOk 'parse ok at exactly the cap'
            Assert-True ($null -eq $result.ParseError) ('no parse error: ' + $result.ParseError)
            Assert-Equal 'GS_SERVER_FREE' $result.State 'state kept at exactly the cap'
        } finally { Stop-FakeServerInfo $fake }
    }

    Invoke-Test 'Serverinfo fetch does not follow a 302 redirect' {
        # AllowAutoRedirect stays $false: a redirect answer is reported as-is
        # (never Ready) and the redirect target is never contacted.
        $flags = [hashtable]::Synchronized(@{ Hit = $false })
        $targetListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $targetListener.Start()
        $targetPort = $targetListener.LocalEndpoint.Port
        $targetEngine = [powershell]::Create()
        [void]$targetEngine.AddScript({
                param($Listener, $Flags)
                try {
                    $client = $Listener.AcceptTcpClient()
                    $Flags.Hit = $true
                    try { $client.Close() } catch { }
                } catch { }
            }).AddArgument($targetListener).AddArgument($flags)
        $targetHandle = $targetEngine.BeginInvoke()
        $redirect = "HTTP/1.1 302 Found`r`nLocation: http://127.0.0.1:$targetPort/serverinfo`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
        $fake = Start-FakeServerInfo -ResponseText $redirect
        try {
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$($fake.Port)/serverinfo")
            Assert-Equal 302 $result.HttpStatus 'redirect status reported as-is'
            Assert-True (-not $result.ParseOk) 'redirect parse ok false'
            Start-Sleep -Milliseconds 400
            Assert-True (-not $flags.Hit) 'redirect target was not contacted'
            $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $result
            Assert-StateRow $row 'Error' 'runtime ready but serverinfo unreachable' $true $true 'redirect row'
        } finally {
            Stop-FakeServerInfo $fake
            try { $targetListener.Stop() } catch { }
            try { $targetEngine.Stop() } catch { }
            try { $targetEngine.Dispose() } catch { }
        }
    }

    Invoke-Test 'Serverinfo fetch aborts a slow chunked trickle within the timeout' {
        # The fake answers 200 with a chunked body and then sends one
        # chunk-extension byte every 200 ms forever: a blocking read would
        # trickle along indefinitely. The fetch must abort the request and
        # come back with status 0 and a timeout ParseError inside
        # TimeoutMs + 1 s.
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $engine = [powershell]::Create()
        [void]$engine.AddScript({
                param($Listener)
                try {
                    $client = $Listener.AcceptTcpClient()
                    $stream = $client.GetStream()
                    $head = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nTransfer-Encoding: chunked`r`nConnection: close`r`n`r`n5;")
                    $stream.Write($head, 0, $head.Length)
                    $stream.Flush()
                    for ($i = 0; $i -lt 1000; $i++) {
                        Start-Sleep -Milliseconds 200
                        $oneByte = [System.Text.Encoding]::ASCII.GetBytes([string][char](65 + ($i % 26)))
                        try {
                            $stream.Write($oneByte, 0, 1)
                            $stream.Flush()
                        } catch { break }
                    }
                    try { $client.Close() } catch { }
                } catch { }
            }).AddArgument($listener)
        [void]$engine.BeginInvoke()
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Get-GsTrayServerInfo -Uri ("http://127.0.0.1:$port/serverinfo") -TimeoutMs 1000
            $watch.Stop()
            Assert-Equal 0 $result.HttpStatus 'aborted fetch reports status 0'
            Assert-True (-not $result.ParseOk) 'aborted fetch parse ok false'
            Assert-True ($result.ParseError -like '*timed out*') ('parse error mentions the timeout: ' + $result.ParseError)
            Assert-True ($watch.Elapsed.TotalMilliseconds -lt 2000) ('trickle latency ms: ' + [int]$watch.Elapsed.TotalMilliseconds)
        } finally {
            try { $listener.Stop() } catch { }
            try { $engine.Stop() } catch { }
            try { $engine.Dispose() } catch { }
        }
    }

    # ---- Child command builder ----
    Invoke-Test 'Command builder produces the documented arguments and script' {
        $resultFile = Join-Path $resultsDir 'builder.json'
        $cmd = New-GsTrayChildCommand -ProductPath 'C:\prod\gs-product.ps1' -Action Start -StateDir 'C:\st' -LogDir 'C:\lg' -ResultFile $resultFile
        Assert-Equal 'powershell.exe' $cmd.FilePath 'file path'
        $prefix = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '
        Assert-True $cmd.Arguments.StartsWith($prefix) 'arguments prefix'
        Assert-Equal ($prefix + $cmd.EncodedCommand) $cmd.Arguments 'arguments are prefix plus encoded command'
        $decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($cmd.EncodedCommand))
        $expectedCall = '$result = & ' + "'C:\prod\gs-product.ps1'" + ' -Action Start'
        Assert-True $decoded.Contains($expectedCall) 'product call with action'
        Assert-True $decoded.Contains("-StateDir 'C:\st'") 'state dir'
        Assert-True $decoded.Contains("-LogDir 'C:\lg'") 'log dir'
        Assert-True $decoded.Contains($resultFile) 'result file literal'
        Assert-True $decoded.Contains('ConvertTo-Json -Depth 8') 'json depth 8'
        Assert-True $decoded.Contains("Code = 'CliException'") 'exception fallback object'
        Assert-True $decoded.Contains('UTF8Encoding($false)') 'utf-8 without BOM'
        Assert-Equal 2 ([regex]::Matches($decoded, 'try \{')).Count 'CLI call and file write each wrapped in try/catch'
    }

    Invoke-Test 'Command builder escapes single quotes and omits empty dirs' {
        $resultFile = Join-Path $resultsDir 'builder2.json'
        $cmd = New-GsTrayChildCommand -ProductPath $weirdProduct -Action Stop -StateDir '' -LogDir '' -ResultFile $resultFile
        $decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($cmd.EncodedCommand))
        $escaped = "'" + $weirdProduct.Replace("'", "''") + "'"
        Assert-True $decoded.Contains("& $escaped -Action Stop") 'escaped product path'
        Assert-True (-not $decoded.Contains('-StateDir')) 'no state dir when empty'
        Assert-True (-not $decoded.Contains('-LogDir')) 'no log dir when empty'
    }

    Invoke-Test 'B2: ValidateSet accepts Recover and still rejects unknown actions' {
        # Contract-required change (K3): Recover joined the CLI child
        # ValidateSet, so building with -Action Recover must now succeed
        # (it used to throw here) while a genuinely unknown action still
        # throws.
        $cmd = New-GsTrayChildCommand -ProductPath 'C:\prod\gs-product.ps1' -Action Recover -ResultFile (Join-Path $resultsDir 'recover.json')
        $decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($cmd.EncodedCommand))
        Assert-True $decoded.Contains('-Action Recover') 'Recover action in the generated script'
        $threw = $false
        try { New-GsTrayChildCommand -ProductPath 'C:\p.ps1' -Action Explode -ResultFile (Join-Path $resultsDir 'x.json') } catch { $threw = $true }
        Assert-True $threw 'genuinely unknown action still rejected'
    }

    # ---- Built commands run against fake gs-product scripts ----
    Invoke-Test 'Built command returns Busy from a fake CLI' {
        [System.IO.File]::WriteAllText($weirdProduct, $fakeBusyScript, $utf8)
        $resultFile = Join-Path $resultsDir ([guid]::NewGuid().ToString('N') + '.json')
        $cmd = New-GsTrayChildCommand -ProductPath $weirdProduct -Action Start -StateDir $workDir -LogDir $workDir -ResultFile $resultFile
        $exitCode = Invoke-TestChildCommand -Arguments $cmd.Arguments
        Assert-Equal 0 $exitCode 'child exit code'
        $parsed = Read-GsTrayCommandResult -Path $resultFile
        Assert-True (-not $parsed.Success) 'success is false'
        Assert-Equal 'Busy' $parsed.Code 'error code'
        Assert-True ($parsed.Message -like '*lifecycle operation*') ('message: ' + $parsed.Message)
    }

    Invoke-Test 'Built command returns CliException when the fake CLI throws' {
        [System.IO.File]::WriteAllText($weirdProduct, $fakeThrowScript, $utf8)
        $resultFile = Join-Path $resultsDir ([guid]::NewGuid().ToString('N') + '.json')
        $cmd = New-GsTrayChildCommand -ProductPath $weirdProduct -Action Stop -StateDir $workDir -LogDir $workDir -ResultFile $resultFile
        $exitCode = Invoke-TestChildCommand -Arguments $cmd.Arguments
        Assert-Equal 0 $exitCode 'child exit code (exception is caught in the child)'
        $parsed = Read-GsTrayCommandResult -Path $resultFile
        Assert-True (-not $parsed.Success) 'success is false'
        Assert-Equal 'CliException' $parsed.Code 'error code'
        Assert-True ($parsed.Message -like '*boom from fake gs-product*') ('message: ' + $parsed.Message)
    }

    Invoke-Test 'Built command returns success from a fake CLI' {
        [System.IO.File]::WriteAllText($weirdProduct, $fakeOkScript, $utf8)
        $resultFile = Join-Path $resultsDir ([guid]::NewGuid().ToString('N') + '.json')
        $cmd = New-GsTrayChildCommand -ProductPath $weirdProduct -Action Start -StateDir $workDir -LogDir $workDir -ResultFile $resultFile
        $exitCode = Invoke-TestChildCommand -Arguments $cmd.Arguments
        Assert-Equal 0 $exitCode 'child exit code'
        $parsed = Read-GsTrayCommandResult -Path $resultFile
        Assert-True $parsed.Success 'success is true'
        Assert-Equal '' $parsed.Code 'no error code'
    }

    Invoke-Test 'Built command works from a folder with space, ASCII quote and smart quote' {
        # U+2019 (right single quotation mark) is built in code to keep this
        # file ASCII; the path exercises the single-quote escaping end to end.
        $quoteDir = Join-Path $workDir ("quote ' dir " + [string][char]0x2019)
        New-Item -ItemType Directory -Path $quoteDir -Force | Out-Null
        $quoteProduct = Join-Path $quoteDir 'fake gs-product.ps1'
        [System.IO.File]::WriteAllText($quoteProduct, $fakeOkScript, $utf8)
        $resultFile = Join-Path $resultsDir ([guid]::NewGuid().ToString('N') + '.json')
        $cmd = New-GsTrayChildCommand -ProductPath $quoteProduct -Action Start -StateDir $quoteDir -LogDir $quoteDir -ResultFile $resultFile
        $decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($cmd.EncodedCommand))
        $asciiQuote = [string][char]39
        Assert-True $decoded.Contains($asciiQuote + $asciiQuote) 'ASCII quote is doubled in the generated script'
        Assert-True $decoded.Contains([string][char]0x2019) 'smart quote is preserved in the generated script'
        $exitCode = Invoke-TestChildCommand -Arguments $cmd.Arguments
        Assert-Equal 0 $exitCode 'child exit code'
        $parsed = Read-GsTrayCommandResult -Path $resultFile
        Assert-True $parsed.Success 'escaped path ran and returned success'
        Assert-Equal '' $parsed.Code 'no error code'
    }

    Invoke-Test 'Child that exits without writing a result file yields NoResult' {
        [System.IO.File]::WriteAllText($weirdProduct, $fakeOkScript, $utf8)
        # The parent of the result file is a regular file, so the child's
        # best-effort write fails silently and no result file appears.
        $blocker = New-TestFile 'write-blocker.txt' 'not a directory'
        $resultFile = Join-Path $blocker 'child-result.json'
        $cmd = New-GsTrayChildCommand -ProductPath $weirdProduct -Action Start -StateDir $workDir -LogDir $workDir -ResultFile $resultFile
        $exitCode = Invoke-TestChildCommand -Arguments $cmd.Arguments
        Assert-Equal 0 $exitCode 'child exit code despite write failure'
        Assert-True (-not (Test-Path -LiteralPath $resultFile)) 'no result file written'
        $parsed = Read-GsTrayCommandResult -Path $resultFile
        Assert-True (-not $parsed.Success) 'success is false'
        Assert-Equal 'NoResult' $parsed.Code 'error code'
    }

    Invoke-Test 'Pending-done decision truth table' {
        $done = [pscustomobject]@{ Success = $true; Code = ''; Message = '' }
        $noResult = [pscustomobject]@{ Success = $false; Code = 'NoResult'; Message = '' }
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $done -HasExited $null -ProcessAlive $null -ElapsedSec 0 -TimeoutSec 300) 'usable result file decides Done'
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $true -ProcessAlive $null -ElapsedSec 0 -TimeoutSec 300) 'known-exited process decides Done'
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $null -ProcessAlive $false -ElapsedSec 0 -TimeoutSec 300) 'process gone decides Done'
        Assert-Equal 'Waiting' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $false -ProcessAlive $true -ElapsedSec 0 -TimeoutSec 300) 'running child keeps Waiting'
        Assert-Equal 'Waiting' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $null -ProcessAlive $null -ElapsedSec 0 -TimeoutSec 300) 'unknown liveness and no file keep Waiting'
        Assert-Equal 'Waiting' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $null -ProcessAlive $null -ElapsedSec 300 -TimeoutSec 300) 'exactly at the cap keeps Waiting'
        Assert-Equal 'TimedOut' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $false -ProcessAlive $true -ElapsedSec 301 -TimeoutSec 300) 'past the cap times out'
        Assert-Equal 'TimedOut' (Test-GsTrayPendingDone -ResultParsed $null -HasExited $null -ProcessAlive $null -ElapsedSec 301 -TimeoutSec 300) 'no data at all still times out at the cap'
    }

    Invoke-Test 'Pending-done: an available result or known exit wins over the wait cap' {
        # Regression: the old decision compared the elapsed time FIRST, so a
        # child that finished right at the 300 s boundary was reported as
        # TimedOut even though the result file (or the known exit) already
        # held the real outcome. The outcome must win over the cap.
        $success = [pscustomobject]@{ Success = $true; Code = ''; Message = '' }
        $failure = [pscustomobject]@{ Success = $false; Code = 'CliException'; Message = '' }
        $noResult = [pscustomobject]@{ Success = $false; Code = 'NoResult'; Message = '' }
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $success -HasExited $null -ProcessAlive $null -ElapsedSec 301 -TimeoutSec 300) 'success result past the cap is Done'
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $failure -HasExited $null -ProcessAlive $null -ElapsedSec 301 -TimeoutSec 300) 'failure result past the cap is Done'
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $success -HasExited $false -ProcessAlive $true -ElapsedSec 300.5 -TimeoutSec 300) 'a result beats a still-running liveness past the cap'
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $true -ProcessAlive $null -ElapsedSec 301 -TimeoutSec 300) 'known exit past the cap is Done'
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $null -ProcessAlive $false -ElapsedSec 301 -TimeoutSec 300) 'process gone past the cap is Done'
    }

    Invoke-Test 'Pending-done: without a result or a known exit the 300/301 s boundary decides' {
        # No result file and no known exit (child running, or liveness
        # unknown because .HasExited threw): exactly at the cap the tray
        # keeps waiting; strictly past it the wait ends as TimedOut.
        $noResult = [pscustomobject]@{ Success = $false; Code = 'NoResult'; Message = '' }
        Assert-Equal 'Waiting' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $false -ProcessAlive $true -ElapsedSec 300 -TimeoutSec 300) 'running at exactly the cap keeps Waiting'
        Assert-Equal 'Waiting' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $null -ProcessAlive $null -ElapsedSec 300 -TimeoutSec 300) 'unknown liveness at exactly the cap keeps Waiting'
        Assert-Equal 'TimedOut' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $false -ProcessAlive $true -ElapsedSec 301 -TimeoutSec 300) 'running past the cap times out'
        Assert-Equal 'TimedOut' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $null -ProcessAlive $null -ElapsedSec 301 -TimeoutSec 300) 'unknown liveness past the cap times out'
        Assert-Equal 'TimedOut' (Test-GsTrayPendingDone -ResultParsed $null -HasExited $null -ProcessAlive $null -ElapsedSec 301 -TimeoutSec 300) 'no data at all times out past the cap'
    }

    Invoke-Test 'Pending-done: a deferred poll sequence delivers the real outcome' {
        # Simulated poll timeline (no real waiting): early polls see nothing
        # and keep Waiting; a later poll past the cap that finally finds the
        # outcome - a success result, a failure result, or a result-less
        # known exit - reports that outcome, never TimedOut.
        $noResult = [pscustomobject]@{ Success = $false; Code = 'NoResult'; Message = '' }
        $success = [pscustomobject]@{ Success = $true; Code = ''; Message = '' }
        $failure = [pscustomobject]@{ Success = $false; Code = 'Busy'; Message = '' }
        Assert-Equal 'Waiting' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $false -ProcessAlive $true -ElapsedSec 0 -TimeoutSec 300) 't=0 waiting'
        Assert-Equal 'Waiting' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $false -ProcessAlive $true -ElapsedSec 100 -TimeoutSec 300) 't=100 still waiting'
        Assert-Equal 'Waiting' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $false -ProcessAlive $true -ElapsedSec 299 -TimeoutSec 300) 't=299 still waiting'
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $success -HasExited $false -ProcessAlive $true -ElapsedSec 301 -TimeoutSec 300) 't=301 deferred success is Done'
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $failure -HasExited $null -ProcessAlive $null -ElapsedSec 301 -TimeoutSec 300) 't=301 deferred failure is Done'
        Assert-Equal 'Done' (Test-GsTrayPendingDone -ResultParsed $noResult -HasExited $true -ProcessAlive $null -ElapsedSec 301 -TimeoutSec 300) 't=301 known exit is Done'
    }

    # ---- Result parser edge cases ----
    Invoke-Test 'Result parser: missing file yields NoResult' {
        $parsed = Read-GsTrayCommandResult -Path (Join-Path $resultsDir 'does-not-exist.json')
        Assert-True (-not $parsed.Success) 'success is false'
        Assert-Equal 'NoResult' $parsed.Code 'error code'
    }

    Invoke-Test 'Result parser: empty file yields NoResult' {
        $p = New-TestFile 'empty-result.json' ''
        $parsed = Read-GsTrayCommandResult -Path $p
        Assert-Equal 'NoResult' $parsed.Code 'empty file code'
        $p2 = New-TestFile 'blank-result.json' "   `r`n"
        $parsed2 = Read-GsTrayCommandResult -Path $p2
        Assert-Equal 'NoResult' $parsed2.Code 'whitespace file code'
    }

    Invoke-Test 'Result parser: invalid JSON yields NoResult' {
        $p = New-TestFile 'garbage-result.json' 'not json at all {'
        $parsed = Read-GsTrayCommandResult -Path $p
        Assert-Equal 'NoResult' $parsed.Code 'garbage code'
    }

    Invoke-Test 'Result parser: locked result file yields NoResult' {
        $p = New-TestFile 'locked-result.json' '{"Success":false,"Data":null,"Errors":[{"Code":"Busy","Message":"x"}]}'
        $lock = [System.IO.File]::Open($p, 'Open', 'Read', 'None')
        try { $parsed = Read-GsTrayCommandResult -Path $p } finally { $lock.Dispose() }
        Assert-True (-not $parsed.Success) 'success is false'
        Assert-Equal 'NoResult' $parsed.Code 'locked file code'
        Assert-True ($parsed.Message -like '*could not be read*') ('message: ' + $parsed.Message)
    }

    Invoke-Test 'Result parser: string Success field yields NoResult' {
        $p = New-TestFile 'string-success-result.json' '{"Success":"false","Data":null,"Errors":[]}'
        $parsed = Read-GsTrayCommandResult -Path $p
        Assert-True (-not $parsed.Success) 'success is false'
        Assert-Equal 'NoResult' $parsed.Code 'string success code'
        Assert-Equal 'Success field must be a JSON boolean.' $parsed.Message 'string success message'
    }

    Invoke-Test 'Result parser: non-string Code and Message are ignored' {
        $p = New-TestFile 'typed-errors-result.json' '{"Success":false,"Data":null,"Errors":[{"Code":5,"Message":true}]}'
        $parsed = Read-GsTrayCommandResult -Path $p
        Assert-True (-not $parsed.Success) 'success is false'
        Assert-Equal '' $parsed.Code 'non-string code dropped'
        Assert-Equal '' $parsed.Message 'non-string message dropped'
    }

    Invoke-Test 'Result parser: success result has empty code and message' {
        $p = New-TestFile 'ok-result.json' '{"Success":true,"Data":null,"Errors":[]}'
        $parsed = Read-GsTrayCommandResult -Path $p
        Assert-True $parsed.Success 'success'
        Assert-Equal '' $parsed.Code 'code'
        Assert-Equal '' $parsed.Message 'message'
    }

    # ---- Static checks ----
    Invoke-Test 'gs-tray-model.ps1 parses without errors' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($modelPath, [ref]$tokens, [ref]$errors)
        Assert-Equal 0 @($errors).Count 'parse errors'
    }

    Invoke-Test 'gs-tray.ps1 parses without errors' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($trayPath, [ref]$tokens, [ref]$errors)
        Assert-Equal 0 @($errors).Count 'parse errors'
    }

    Invoke-Test 'gs-tray.ps1 contains no lifecycle or system-operation commands' {
        $trayText = [System.IO.File]::ReadAllText($trayPath)
        foreach ($pattern in @('Start-ScheduledTask', 'Stop-ScheduledTask', 'Register-ScheduledTask', 'Unregister-ScheduledTask',
                'Start-Service', 'Stop-Service', 'Set-Service', 'Stop-Process', 'gs_start_with_hook', 'gs_stop_private',
                'supervisor_pause', 'netsh', 'sc\.exe', 'SchTasks')) {
            Assert-True ($trayText -notmatch $pattern) "tray must not contain '$pattern'"
        }
    }

    Invoke-Test 'Both CLI child launches in gs-tray.ps1 are started hidden' {
        $trayText = [System.IO.File]::ReadAllText($trayPath)
        $launches = [regex]::Matches($trayText, 'Start-Process -FilePath \$command\.FilePath[^\r\n]*')
        Assert-Equal 2 $launches.Count 'two CLI child launches (elevated and RunAs)'
        foreach ($launch in $launches) {
            Assert-True ($launch.Value -match '-WindowStyle Hidden') ('launch is hidden: ' + $launch.Value)
        }
    }

    Invoke-Test 'gs-tray.ps1 disposes the pending CLI child process object' {
        # Resource hygiene: once the pending decision is made (done or timed
        # out) the child Process object must be disposed - after the Waiting
        # early return and before the pending action is cleared.
        $trayText = [System.IO.File]::ReadAllText($trayPath)
        $funcMatch = [regex]::Match($trayText, '(?s)function Update-PendingAction \{.*?\r?\n\}')
        Assert-True $funcMatch.Success 'Update-PendingAction function found'
        $body = $funcMatch.Value
        $waitingIndex = $body.IndexOf("if (`$decision -eq 'Waiting') { return }")
        $disposeIndex = $body.IndexOf('$proc.Dispose()')
        $pendingClearedIndex = $body.IndexOf('$script:Pending = $null')
        Assert-True ($waitingIndex -ge 0) 'Waiting early return found'
        Assert-True ($disposeIndex -gt $waitingIndex) 'process disposed after the Waiting early return (both finish branches)'
        Assert-True ($pendingClearedIndex -gt $disposeIndex) 'dispose happens before the pending action is cleared'
    }

    Invoke-Test 'gs-tray.ps1 defines the Stopping icon and maps all six states' {
        $trayText = [System.IO.File]::ReadAllText($trayPath)
        Assert-True ($trayText -match '\$script:IconStopping\s*=\s*New-GsStateIcon\s*\(\[System\.Drawing\.Color\]::Orange\)') 'Stopping icon is built orange'
        foreach ($stateName in @('Stopped', 'Starting', 'Stopping', 'Ready', 'Streaming', 'Error')) {
            $pattern = '''{0}''\s*=\s*\$script:Icon' -f $stateName
            Assert-True ($trayText -match $pattern) ('state-to-icon map has ' + $stateName)
        }
        Assert-Equal 6 ([regex]::Matches($trayText, 'New-GsStateIcon \(')).Count 'six state icons are built'
    }

    Invoke-Test 'gs-tray-model.ps1 contains no Windows Forms types' {
        $modelText = [System.IO.File]::ReadAllText($modelPath)
        Assert-True ($modelText -notmatch 'Windows\.Forms') 'no Windows.Forms'
        Assert-True ($modelText -notmatch 'NotifyIcon') 'no NotifyIcon'
    }

    Invoke-Test 'gs-tray.vbs launches hidden without waiting' {
        $vbsText = [System.IO.File]::ReadAllText($vbsPath)
        Assert-True ($vbsText -match '\.Run\s+\w+,\s*0,\s*False') 'window style 0 and bWaitOnReturn False'
        Assert-True ($vbsText -match '-WindowStyle Hidden') 'powershell window hidden'
        Assert-True ($vbsText -match '-STA') 'STA apartment'
        Assert-True ($vbsText -match 'powershell\.exe') 'powershell.exe'
        Assert-True ($vbsText -match 'gs-tray\.ps1') 'tray script target'
        Assert-True ($vbsText -match '-NoProfile') 'no profile'
        Assert-True ($vbsText -match '-ExecutionPolicy Bypass') 'execution policy bypass'
    }

    # ---- B1 (K4): external zh-CN string table ---------------------------------
    # No Chinese literals in this file (it stays ASCII): translated-value
    # assertions compare against the zh table itself and assert the value
    # differs from the built-in English one.

    Invoke-Test 'B1: Get-GsTrayStrings loads the shipped zh-CN table' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-Equal 'file' $zh.Source 'table source'
        Assert-True ($null -eq $zh.FallbackReason) ('no fallback reason: ' + $zh.FallbackReason)
        Assert-True ($zh.KeyCount -gt 0) ('key count ' + $zh.KeyCount)
        Assert-Equal $zh.KeyCount $zh.Strings.Count 'key count matches table'
    }

    Invoke-Test 'B1: zh-CN and built-in English tables have identical key sets' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-Equal 'file' $zh.Source 'zh table must load from the file'
        $en = Get-GsTrayBuiltinStrings
        foreach ($key in $en.Keys) {
            Assert-True ($zh.Strings.ContainsKey([string]$key)) ('zh table missing key ' + $key)
        }
        foreach ($key in $zh.Strings.Keys) {
            Assert-True ($en.ContainsKey([string]$key)) ('zh table has an unknown key ' + $key)
        }
        Assert-Equal $en.Count $zh.Strings.Count 'same key count'
    }

    Invoke-Test 'B1: zh-CN and English tables have identical placeholder counts per key' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $en = Get-GsTrayBuiltinStrings
        foreach ($key in $en.Keys) {
            $expected = [regex]::Matches([string]$en[$key], '\{\d+\}').Count
            $actual = [regex]::Matches([string]$zh.Strings[[string]$key], '\{\d+\}').Count
            Assert-Equal $expected $actual ('placeholder count for ' + $key)
        }
    }

    Invoke-Test 'B1: built-in English table covers the documented key set exactly' {
        $en = Get-GsTrayBuiltinStrings
        $required = @(
            'menu.start', 'menu.stop', 'menu.status', 'menu.recover', 'menu.supportBundle', 'menu.openLogs', 'menu.exit',
            'state.stopped', 'state.starting', 'state.stopping', 'state.ready', 'state.streaming', 'state.error',
            'detail.stoppedNoStatusFile', 'detail.stopped', 'detail.statusFileUnreadable', 'detail.statusFileInvalid',
            'detail.statusFileNoStateField', 'detail.statusFileBadStateField', 'detail.serverinfoUnreachable',
            'detail.serverinfoInvalid', 'detail.starting', 'detail.stopping', 'detail.startingDidNotFinish',
            'detail.stoppingDidNotFinish', 'detail.ready', 'detail.streaming', 'detail.runtimeFailed',
            'detail.runtimeError', 'detail.unknownState',
            'status.title', 'status.trayState', 'status.detail', 'status.pendingAction', 'status.statusFile',
            'status.statusFilePresent', 'status.statusFileMissing', 'status.statusError', 'status.lastResult',
            'status.lastResultNone', 'status.trayLog',
            'balloon.title', 'balloon.actionCompleted', 'balloon.busy', 'balloon.noUsableResult', 'balloon.actionFailed',
            'balloon.actionStillRunning', 'balloon.uacCancelled', 'balloon.launchFailed', 'balloon.internalError',
            'recover.confirmTitle', 'recover.confirmText', 'recover.success',
            'recover.reason.StatusUnavailable', 'recover.reason.NotReady', 'recover.reason.ServerInfoUnavailable',
            'recover.reason.NoStuckSession', 'recover.reason.ClientConnected', 'recover.reason.ConnectionCheckFailed',
            'recover.reason.ClientTrafficDetected',
            'recover.code.RecoverStopFailed', 'recover.code.RecoverStartFailed', 'recover.code.RecoverCleanupFailed',
            'recover.unknownReason',
            'support.missing', 'support.success', 'support.noResult', 'support.elevatedRefused',
            'support.code.DiagnoseUnavailable',
            'support.code.DiagnoseFailed', 'support.code.RedactionCheckFailed', 'support.code.OutputDirInvalid',
            'support.code.ZipFailed', 'support.unknownCode',
            'notify.streamStarted', 'notify.streamEnded', 'notify.pausedSuffix',
            'tooltip.prefix'
        )
        foreach ($key in $required) {
            Assert-True ($en.ContainsKey($key)) ('built-in table missing key ' + $key)
        }
        Assert-Equal $required.Count $en.Count 'no extra built-in keys'
    }

    Invoke-Test 'B1: string table fallback when the file is missing' {
        $result = Get-GsTrayStrings -Path (Join-Path $workDir 'no-such-strings.json')
        Assert-Equal 'builtin' $result.Source 'source'
        Assert-True (-not [string]::IsNullOrEmpty($result.FallbackReason)) 'fallback reason recorded'
        Assert-True ($result.Strings.Count -gt 0) 'built-in strings present'
    }

    Invoke-Test 'B1: string table fallback on corrupt JSON' {
        $p = New-TestFile 'corrupt-strings.json' '{ not json at all'
        $result = Get-GsTrayStrings -Path $p
        Assert-Equal 'builtin' $result.Source 'source'
        Assert-True ($result.FallbackReason -like '*JSON*') ('reason mentions JSON: ' + $result.FallbackReason)
    }

    Invoke-Test 'B1: string table fallback on a non-string value' {
        $p = New-TestFile 'nonstring-strings.json' '{"menu.start": 5}'
        $result = Get-GsTrayStrings -Path $p
        Assert-Equal 'builtin' $result.Source 'source'
        Assert-True ($result.FallbackReason -like '*non-string*') ('reason: ' + $result.FallbackReason)
    }

    Invoke-Test 'B1: string table fallback when a key is missing' {
        # Every built-in key except menu.exit, with a placeholder-free dummy
        # value: the first complaint must be the missing key.
        $en = Get-GsTrayBuiltinStrings
        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add('{')
        $first = $true
        foreach ($key in $en.Keys) {
            if ($key -eq 'menu.exit') { continue }
            if (-not $first) { $parts.Add(',') }
            $first = $false
            $parts.Add('"' + $key + '": "x"')
        }
        $parts.Add('}')
        $p = New-TestFile 'partial-strings.json' ($parts -join "`n")
        $result = Get-GsTrayStrings -Path $p
        Assert-Equal 'builtin' $result.Source 'source'
        Assert-True ($result.FallbackReason -like '*missing key menu.exit*') ('reason: ' + $result.FallbackReason)
    }

    Invoke-Test 'B1: string table fallback on a placeholder count mismatch' {
        # Full key set (values copied from the built-in table) except one
        # key that lost its placeholder.
        $en = Get-GsTrayBuiltinStrings
        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add('{')
        $first = $true
        foreach ($key in $en.Keys) {
            if (-not $first) { $parts.Add(',') }
            $first = $false
            $value = [string]$en[$key]
            if ($key -eq 'detail.unknownState') { $value = 'plain text without a placeholder' }
            $value = $value.Replace('\', '\\').Replace('"', '\"')
            $parts.Add('"' + $key + '": "' + $value + '"')
        }
        $parts.Add('}')
        $p = New-TestFile 'placeholder-strings.json' ($parts -join "`n")
        $result = Get-GsTrayStrings -Path $p
        Assert-Equal 'builtin' $result.Source 'source'
        Assert-True ($result.FallbackReason -like '*placeholder*') ('reason: ' + $result.FallbackReason)
    }

    Invoke-Test 'B1: BOM-prefixed string table is accepted (BOM stripped, never a crash)' {
        # Decision: a leading UTF-8 BOM is stripped and the file accepted.
        # A single-key table cannot be accepted as a whole, so the assertion
        # is that the failure reason is 'missing key' (the JSON after the
        # BOM parsed) and never a JSON parse error.
        $raw = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes('{"menu.exit": "Exit"}')
        $p = Join-Path $workDir 'bom-strings.json'
        [System.IO.File]::WriteAllBytes($p, $raw)
        $result = Get-GsTrayStrings -Path $p
        Assert-Equal 'builtin' $result.Source 'single-key table falls back on missing keys'
        Assert-True ($result.FallbackReason -like '*missing key*') ('JSON after the BOM parsed: ' + $result.FallbackReason)
        Assert-True ($result.FallbackReason -notlike '*JSON*') 'the BOM itself is not a parse error'
    }

    Invoke-Test 'B1: empty string table file falls back without throwing' {
        $p = New-TestFile 'empty-strings.json' ''
        $result = Get-GsTrayStrings -Path $p
        Assert-Equal 'builtin' $result.Source 'source'
        Assert-True ($result.Strings.Count -gt 0) 'built-in strings present'
        $p2 = New-TestFile 'whitespace-strings.json' '   '
        $result2 = Get-GsTrayStrings -Path $p2
        Assert-Equal 'builtin' $result2.Source 'source'
    }

    Invoke-Test 'B1: Format-GsTrayText substitutes placeholders and never throws' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $text = Format-GsTrayText -Strings $zh.Strings -Key 'detail.unknownState' -Arguments @('warp')
        Assert-True ($text -like '*warp') ('argument substituted: ' + $text)
        Assert-True ($text -ne [string](Get-GsTrayBuiltinStrings)['detail.unknownState']) 'text is translated'
        $text2 = Format-GsTrayText -Strings @{} -Key 'detail.unknownState' -Arguments @('x')
        Assert-True ($text2 -like '*x') ('empty table falls back to English: ' + $text2)
        $text3 = Format-GsTrayText -Strings $zh.Strings -Key 'detail.unknownState'
        Assert-True ($text3.Length -gt 0) 'missing arguments yield the raw template, not a throw'
        $text4 = Format-GsTrayText -Strings $zh.Strings -Key 'state.ready' -Arguments @()
        Assert-True ($text4.Length -gt 0) 'placeholder-free key formats with empty arguments'
    }

    Invoke-Test 'B1: Format-GsTrayText falls back to English for an unknown key' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-Equal 'totally-unknown-key' (Format-GsTrayText -Strings $zh.Strings -Key 'totally-unknown-key') 'unknown key returned as-is'
        Assert-Equal ([string](Get-GsTrayBuiltinStrings)['menu.start']) (Format-GsTrayText -Strings $null -Key 'menu.start') 'null table uses the built-in English table'
    }

    Invoke-Test 'B1: state rows carry DetailKey and DetailArgs alongside the English Detail' {
        $rows = @(
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Exists $false) -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Readable $false -Err 'ReadFailed') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'InvalidJson') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'MissingStateField') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'InvalidStateField') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_FREE' -CurrentGame '0')),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_BUSY' -CurrentGame '42')),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -ProtocolStatus 0 -ParseOk $false -State '' -CurrentGame '')),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'starting') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc ([DateTime]::UtcNow)) -ServerInfo $null -NowUtc ([DateTime]::UtcNow)),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc ([DateTime]::UtcNow.AddSeconds(-301))) -ServerInfo $null -NowUtc ([DateTime]::UtcNow)),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'starting' -LastWriteTimeUtc ([DateTime]::UtcNow.AddSeconds(-121))) -ServerInfo $null -NowUtc ([DateTime]::UtcNow)),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopped') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'failed') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'error') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'warp') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $null -PendingAction 'Start'),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $null -PendingAction 'Stop')
        )
        foreach ($row in $rows) {
            Assert-True (-not [string]::IsNullOrEmpty($row.DetailKey)) ('row has a DetailKey (state ' + $row.State + ', detail ' + $row.Detail + ')')
            Assert-True ($null -ne $row.DetailArgs) 'row has DetailArgs'
        }
        Assert-Equal 'detail.stoppedNoStatusFile' $rows[0].DetailKey 'missing file key'
        Assert-Equal 'detail.statusFileUnreadable' $rows[1].DetailKey 'unreadable key'
        Assert-Equal 'detail.statusFileInvalid' $rows[2].DetailKey 'invalid json key'
        Assert-Equal 'detail.statusFileNoStateField' $rows[3].DetailKey 'no state field key'
        Assert-Equal 'detail.statusFileBadStateField' $rows[4].DetailKey 'bad state field key'
        Assert-Equal 'detail.ready' $rows[5].DetailKey 'ready key'
        Assert-Equal 'detail.streaming' $rows[6].DetailKey 'streaming key'
        Assert-Equal 'detail.serverinfoUnreachable' $rows[7].DetailKey 'unreachable key'
        Assert-Equal 'detail.serverinfoInvalid' $rows[8].DetailKey 'invalid key'
        Assert-Equal 'detail.starting' $rows[9].DetailKey 'starting key'
        Assert-Equal 'detail.stopping' $rows[10].DetailKey 'stopping key'
        Assert-Equal 'detail.stoppingDidNotFinish' $rows[11].DetailKey 'stale stopping key'
        Assert-Equal 'detail.startingDidNotFinish' $rows[12].DetailKey 'stale starting key'
        Assert-Equal 'detail.stopped' $rows[13].DetailKey 'stopped key'
        Assert-Equal 'detail.runtimeFailed' $rows[14].DetailKey 'failed key'
        Assert-Equal 'detail.runtimeError' $rows[15].DetailKey 'error key'
        Assert-Equal 'detail.unknownState' $rows[16].DetailKey 'unknown key'
        Assert-Equal 'warp' ([string]$rows[16].DetailArgs[0]) 'unknown-state argument carries the raw value'
        Assert-Equal 'detail.starting' $rows[17].DetailKey 'pending start key'
        Assert-Equal 'detail.stopping' $rows[18].DetailKey 'pending stop key'
    }

    Invoke-Test 'B1: every translated state row and its longest detail stay within 63 characters' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $prefix = Format-GsTrayText -Strings $zh.Strings -Key 'tooltip.prefix'
        $suffix = Format-GsTrayText -Strings $zh.Strings -Key 'notify.pausedSuffix'
        $longRaw = 'x' * 200
        $rows = @(
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Exists $false) -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Readable $false -Err 'ReadFailed') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'InvalidJson') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'MissingStateField') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -Err 'InvalidStateField') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_FREE' -CurrentGame '0')),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_BUSY' -CurrentGame '42')),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -ProtocolStatus 0 -ParseOk $false -State '' -CurrentGame '')),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'starting') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc ([DateTime]::UtcNow)) -ServerInfo $null -NowUtc ([DateTime]::UtcNow)),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopping' -LastWriteTimeUtc ([DateTime]::UtcNow.AddSeconds(-301))) -ServerInfo $null -NowUtc ([DateTime]::UtcNow)),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'starting' -LastWriteTimeUtc ([DateTime]::UtcNow.AddSeconds(-121))) -ServerInfo $null -NowUtc ([DateTime]::UtcNow)),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopped') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'failed') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'error') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'warp') -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State $longRaw) -ServerInfo $null),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $null -PendingAction 'Start'),
            (Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo $null -PendingAction 'Stop')
        )
        foreach ($row in $rows) {
            # The UI translates through Get-GsTrayDetailText, which caps at
            # the 63 character limit AFTER translation (counting characters).
            $translated = Get-GsTrayDetailText -Strings $zh.Strings -StateRow $row
            Assert-True ($translated.Length -le 63) ('translated detail too long (' + $translated.Length + ') for ' + $row.DetailKey)
            $tooltip = Get-GsTrayTooltipText -Prefix $prefix -Detail $translated -Paused $true -PausedSuffix $suffix
            Assert-True ($tooltip.Length -le 63) ('composed tooltip too long: ' + $tooltip.Length)
        }
    }

    Invoke-Test 'B1: state name keys exist for all six states and are translated' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        foreach ($stateName in @('Stopped', 'Starting', 'Stopping', 'Ready', 'Streaming', 'Error')) {
            $name = Get-GsTrayStateName -Strings $zh.Strings -State $stateName
            Assert-True (-not [string]::IsNullOrEmpty($name)) ('translated state name for ' + $stateName)
            Assert-True ($name -ne $stateName) ('state name differs from the English name for ' + $stateName)
            Assert-True ($name.Length -le 63) 'state name within the limit'
        }
        Assert-Equal 'Weird' (Get-GsTrayStateName -Strings $zh.Strings -State 'Weird') 'unknown states come back unchanged'
    }

    Invoke-Test 'B1: AST scan of gs-tray.ps1 finds no English literals in UI calls' {
        $violations = Get-GsTrayUiLiteralViolations -Path $trayPath
        Assert-Equal 0 @($violations).Count ('quoted literals in UI calls: ' + ($violations -join '; '))
    }

    Invoke-Test 'B1: product .ps1 files are ASCII-only' {
        foreach ($p in @($modelPath, $trayPath)) {
            $bytes = [System.IO.File]::ReadAllBytes($p)
            foreach ($byteValue in $bytes) {
                if ($byteValue -gt 127) { throw ('non-ASCII byte found in ' + $p) }
            }
        }
    }

    # ---- B2 (K3/K1): Recover and support bundle --------------------------------

    Invoke-Test 'B2: Recover child command quoting survives spaces, ASCII quotes and U+2019' {
        [System.IO.File]::WriteAllText($weirdProduct, $fakeOkScript, $utf8)
        $resultFile = Join-Path $resultsDir ([guid]::NewGuid().ToString('N') + '.json')
        $cmd = New-GsTrayChildCommand -ProductPath $weirdProduct -Action Recover -StateDir $weirdDir -LogDir $weirdDir -ResultFile $resultFile
        $decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($cmd.EncodedCommand))
        $escaped = "'" + $weirdProduct.Replace("'", "''") + "'"
        Assert-True $decoded.Contains("& $escaped -Action Recover") 'escaped product path with the Recover action'
        $exitCode = Invoke-TestChildCommand -Arguments $cmd.Arguments
        Assert-Equal 0 $exitCode 'child exit code'
        $parsed = Read-GsTrayCommandResult -Path $resultFile
        Assert-True $parsed.Success 'escaped path ran a Recover against the fake CLI and returned success'
        Assert-Equal '' $parsed.Code 'no error code'
    }

    Invoke-Test 'B2: result parser surfaces Errors[0].Reason (present, absent, non-string)' {
        $p = New-TestFile 'reason-present.json' '{"Success":false,"Data":null,"Errors":[{"Code":"RecoverRefused","Reason":"NoStuckSession","Message":"x"}]}'
        $parsed = Read-GsTrayCommandResult -Path $p
        Assert-Equal 'RecoverRefused' $parsed.Code 'code'
        Assert-Equal 'NoStuckSession' $parsed.Reason 'reason surfaced'
        $p2 = New-TestFile 'reason-absent.json' '{"Success":false,"Data":null,"Errors":[{"Code":"Busy","Message":"x"}]}'
        $parsed2 = Read-GsTrayCommandResult -Path $p2
        Assert-Equal '' $parsed2.Reason 'absent reason is empty'
        $p3 = New-TestFile 'reason-nonstring.json' '{"Success":false,"Data":null,"Errors":[{"Code":"X","Reason":5}]}'
        $parsed3 = Read-GsTrayCommandResult -Path $p3
        Assert-Equal '' $parsed3.Reason 'non-string reason is empty'
        $p4 = New-TestFile 'reason-success.json' '{"Success":true,"Data":null,"Errors":[]}'
        $parsed4 = Read-GsTrayCommandResult -Path $p4
        Assert-Equal '' $parsed4.Reason 'success result has an empty reason'
    }

    Invoke-Test 'B2: menu enable rules follow state and pending action' {
        $streamingRow = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_BUSY' -CurrentGame '42')
        $readyRow = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'ready') -ServerInfo (New-FakeServerInfo -HttpStatus 200 -State 'GS_SERVER_FREE' -CurrentGame '0')
        $stoppedRow = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'stopped') -ServerInfo $null
        $errorRow = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State 'failed') -ServerInfo $null
        # Recover: only while Streaming (it interrupts a live client).
        Assert-True (Get-GsTrayMenuEnabled -StateRow $streamingRow -MenuItem 'Recover') 'recover enabled while Streaming'
        Assert-True (-not (Get-GsTrayMenuEnabled -StateRow $readyRow -MenuItem 'Recover')) 'recover disabled while Ready'
        Assert-True (-not (Get-GsTrayMenuEnabled -StateRow $stoppedRow -MenuItem 'Recover')) 'recover disabled while Stopped'
        Assert-True (-not (Get-GsTrayMenuEnabled -StateRow $errorRow -MenuItem 'Recover')) 'recover disabled while Error'
        Assert-True (-not (Get-GsTrayMenuEnabled -StateRow $null -MenuItem 'Recover')) 'recover disabled without a state row'
        # Start/Stop keep the state row flags.
        Assert-True (-not (Get-GsTrayMenuEnabled -StateRow $streamingRow -MenuItem 'Start')) 'start disabled while Streaming'
        Assert-True (Get-GsTrayMenuEnabled -StateRow $streamingRow -MenuItem 'Stop') 'stop enabled while Streaming'
        Assert-True (Get-GsTrayMenuEnabled -StateRow $stoppedRow -MenuItem 'Start') 'start enabled while Stopped'
        Assert-True (-not (Get-GsTrayMenuEnabled -StateRow $stoppedRow -MenuItem 'Stop')) 'stop disabled while Stopped'
        Assert-True (Get-GsTrayMenuEnabled -StateRow $errorRow -MenuItem 'Start') 'start enabled while Error'
        # Support bundle is independent of the runtime state.
        Assert-True (Get-GsTrayMenuEnabled -StateRow $streamingRow -MenuItem 'SupportBundle') 'support enabled while Streaming'
        Assert-True (Get-GsTrayMenuEnabled -StateRow $stoppedRow -MenuItem 'SupportBundle') 'support enabled while Stopped'
        Assert-True (Get-GsTrayMenuEnabled -StateRow $null -MenuItem 'SupportBundle') 'support enabled without a state row'
        # Any pending action disables all four items.
        foreach ($pending in @('Start', 'Stop', 'Recover', 'SupportBundle')) {
            foreach ($item in @('Start', 'Stop', 'Recover', 'SupportBundle')) {
                Assert-True (-not (Get-GsTrayMenuEnabled -StateRow $streamingRow -PendingAction $pending -MenuItem $item)) ($pending + ' pending disables ' + $item)
            }
        }
    }

    Invoke-Test 'B2: every documented Recover refusal reason maps to a translated Warning balloon' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $en = Get-GsTrayBuiltinStrings
        foreach ($reason in @('StatusUnavailable', 'NotReady', 'ServerInfoUnavailable', 'NoStuckSession', 'ClientConnected', 'ConnectionCheckFailed', 'ClientTrafficDetected')) {
            $balloon = Resolve-GsTrayRecoverBalloon -Strings $zh.Strings -Code 'RecoverRefused' -Reason $reason
            Assert-Equal ([string]$zh.Strings['recover.reason.' + $reason]) $balloon.Text ('zh balloon for ' + $reason)
            Assert-Equal 'Warning' $balloon.Kind ('kind for ' + $reason)
            Assert-True ($balloon.Text -ne [string]$en['recover.reason.' + $reason]) ('balloon is translated for ' + $reason)
        }
    }

    Invoke-Test 'B2: unknown Recover refusal reason is shown raw and never crashes' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $balloon = Resolve-GsTrayRecoverBalloon -Strings $zh.Strings -Code 'RecoverRefused' -Reason 'SomeFutureReason'
        Assert-True ($balloon.Text -like '*SomeFutureReason') ('raw reason shown: ' + $balloon.Text)
        Assert-Equal 'Warning' $balloon.Kind 'kind for an unknown reason'
        $empty = Resolve-GsTrayRecoverBalloon -Strings $zh.Strings -Code 'RecoverRefused' -Reason ''
        Assert-True ($empty.Text -like '*RecoverRefused') ('empty reason shows the raw code: ' + $empty.Text)
    }

    Invoke-Test 'B2: Recover failure codes map to Error balloons and Busy to its own Warning' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        foreach ($code in @('RecoverStopFailed', 'RecoverStartFailed', 'RecoverCleanupFailed')) {
            $balloon = Resolve-GsTrayRecoverBalloon -Strings $zh.Strings -Code $code
            Assert-Equal ([string]$zh.Strings['recover.code.' + $code]) $balloon.Text ('zh balloon for ' + $code)
            Assert-Equal 'Error' $balloon.Kind ('kind for ' + $code)
        }
        $busy = Resolve-GsTrayRecoverBalloon -Strings $zh.Strings -Code 'Busy'
        Assert-Equal ([string]$zh.Strings['balloon.busy']) $busy.Text 'busy balloon'
        Assert-Equal 'Warning' $busy.Kind 'busy kind'
    }

    Invoke-Test 'B2: unknown Recover failure code is shown raw' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $balloon = Resolve-GsTrayRecoverBalloon -Strings $zh.Strings -Code 'WeirdRecoverCode' -ActionLabel 'label'
        Assert-True ($balloon.Text -like '*WeirdRecoverCode*') ('raw code shown: ' + $balloon.Text)
        Assert-Equal 'Error' $balloon.Kind 'kind for an unknown code'
    }

    Invoke-Test 'B2: support command builder quotes paths like the CLI builder' {
        # Directory name with a space, an ASCII apostrophe and U+2019.
        $supportDir = Join-Path $workDir ("support ' dir " + [string][char]0x2019)
        New-Item -ItemType Directory -Path $supportDir -Force | Out-Null
        $supportScript = Join-Path $supportDir 'fake gs-support.ps1'
        [System.IO.File]::WriteAllText($supportScript, 'param()', $utf8)
        $resultFile = Join-Path $resultsDir 'support-builder.json'
        $cmd = New-GsTraySupportCommand -SupportScriptPath $supportScript -ResultFile $resultFile -InstallDir $supportDir -StateDir $supportDir -LogDir $supportDir -TrayLogDir $supportDir -ServerInfoUri 'http://127.0.0.1:9/serverinfo'
        Assert-Equal 'powershell.exe' $cmd.FilePath 'file path'
        $prefix = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '
        Assert-True $cmd.Arguments.StartsWith($prefix) 'arguments prefix'
        $decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($cmd.EncodedCommand))
        # The parser escaper doubles the ASCII apostrophe AND the U+2019
        # look-alike (verified against CodeGeneration.EscapeSingleQuotedStringContent).
        $smart = [string][char]0x2019
        $escaped = "'" + ($supportScript.Replace("'", "''").Replace($smart, ($smart + $smart))) + "'"
        Assert-True $decoded.Contains('& ' + $escaped) 'escaped support script path'
        Assert-True $decoded.Contains([string][char]0x2019) 'smart quote preserved'
        Assert-True $decoded.Contains('-InstallDir') 'install dir passed'
        Assert-True $decoded.Contains('-StateDir') 'state dir passed'
        Assert-True $decoded.Contains('-LogDir') 'log dir passed'
        Assert-True $decoded.Contains('-TrayLogDir') 'tray log dir passed'
        Assert-True $decoded.Contains('-ServerInfoUri') 'serverinfo uri passed'
        Assert-True $decoded.Contains("Code = 'NoSchemaResult'") 'no-schema fallback present'
        Assert-True $decoded.Contains("Code = 'CliException'") 'exception fallback present'
        Assert-True $decoded.Contains('ConvertTo-Json -Depth 8') 'json depth 8'
        Assert-True $decoded.Contains('UTF8Encoding($false)') 'utf-8 without BOM'
        Assert-True $decoded.Contains('exit 0') 'child always exits 0'
    }

    Invoke-Test 'B2: support command picks the last schemaVersion 1 element (fake gs-support run)' {
        # R4-N2: the fake output now also carries an EARLIER matching
        # schemaVersion 1 decoy and trailing non-matching output, so the
        # selection order (the LAST schemaVersion 1 element wins) is
        # actually verified, not just the schema filter.
        $supportDir = Join-Path $workDir ("support ' run " + [string][char]0x2019)
        New-Item -ItemType Directory -Path $supportDir -Force | Out-Null
        $supportScript = Join-Path $supportDir 'fake gs-support.ps1'
        $fakeSupportOk = @'
param([string]$InstallDir, [string]$StateDir, [string]$LogDir, [string]$TrayLogDir, [string]$ServerInfoUri)
'progress output'
[pscustomobject]@{ schemaVersion = 1; Success = $true; ZipPath = 'decoy-first.zip'; Entries = @(); Errors = @() }
[pscustomobject]@{ schemaVersion = 2; Success = $true; ZipPath = 'wrong-version.zip'; Entries = @(); Errors = @() }
[pscustomobject]@{ schemaVersion = 1; Success = $true; ZipPath = (Join-Path $StateDir 'bundle.zip'); Entries = @('a.txt'); Errors = @() }
'trailing noise line'
[pscustomobject]@{ schemaVersion = 2; Success = $true; ZipPath = 'trailing-wrong.zip'; Entries = @(); Errors = @() }
'@
        [System.IO.File]::WriteAllText($supportScript, $fakeSupportOk, $utf8)
        $resultFile = Join-Path $resultsDir ([guid]::NewGuid().ToString('N') + '.json')
        $cmd = New-GsTraySupportCommand -SupportScriptPath $supportScript -ResultFile $resultFile -InstallDir $supportDir -StateDir $supportDir
        $exitCode = Invoke-TestChildCommand -Arguments $cmd.Arguments
        Assert-Equal 0 $exitCode 'child exit code'
        $parsed = Read-GsTraySupportResult -Path $resultFile
        Assert-True $parsed.Success 'success surfaced'
        Assert-True ($parsed.ZipPath -like '*bundle.zip') ('last schemaVersion 1 element picked, zip: ' + $parsed.ZipPath)
        Assert-True ($parsed.ZipPath -notlike '*decoy*') 'the earlier schemaVersion 1 decoy is skipped'
        Assert-True ($parsed.ZipPath -notlike '*trailing*') 'trailing non-matching output is ignored'
        Assert-Equal 1 $parsed.SchemaVersion 'schema version'
        Assert-Equal '' $parsed.Code 'no error code'
    }

    Invoke-Test 'B2: fake gs-support failure maps to its code balloon' {
        $supportScript = Join-Path $workDir 'fake-support-fail.ps1'
        $fakeSupportFail = @'
param()
[pscustomobject]@{ schemaVersion = 1; Success = $false; ZipPath = $null; Entries = @(); Errors = @([pscustomobject]@{ Code = 'ZipFailed'; Message = 'boom' }) }
'@
        [System.IO.File]::WriteAllText($supportScript, $fakeSupportFail, $utf8)
        $resultFile = Join-Path $resultsDir ([guid]::NewGuid().ToString('N') + '.json')
        $cmd = New-GsTraySupportCommand -SupportScriptPath $supportScript -ResultFile $resultFile
        $exitCode = Invoke-TestChildCommand -Arguments $cmd.Arguments
        Assert-Equal 0 $exitCode 'child exit code'
        $parsed = Read-GsTraySupportResult -Path $resultFile
        Assert-True (-not $parsed.Success) 'failure surfaced'
        Assert-Equal 'ZipFailed' $parsed.Code 'code surfaced'
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $balloon = Resolve-GsTraySupportBalloon -Strings $zh.Strings -Code $parsed.Code
        Assert-Equal ([string]$zh.Strings['support.code.ZipFailed']) $balloon.Text 'zh balloon for ZipFailed'
        Assert-Equal 'Error' $balloon.Kind 'kind for ZipFailed'
    }

    Invoke-Test 'B2: support result parser reads ZipPath, Code and SchemaVersion' {
        $p = New-TestFile 'support-ok.json' '{"schemaVersion":1,"Success":true,"ZipPath":"C:\\out\\bundle.zip","Entries":["a"],"Errors":[]}'
        $ok = Read-GsTraySupportResult -Path $p
        Assert-True $ok.Success 'success'
        Assert-Equal 'C:\out\bundle.zip' $ok.ZipPath 'zip path'
        Assert-Equal '' $ok.Code 'no error code'
        Assert-Equal 1 $ok.SchemaVersion 'schema version'
        $p2 = New-TestFile 'support-fail.json' '{"schemaVersion":1,"Success":false,"ZipPath":null,"Errors":[{"Code":"DiagnoseFailed"}]}'
        $fail = Read-GsTraySupportResult -Path $p2
        Assert-True (-not $fail.Success) 'failure'
        Assert-Equal 'DiagnoseFailed' $fail.Code 'code'
        Assert-Equal '' $fail.ZipPath 'no zip on failure'
        Assert-Equal 1 $fail.SchemaVersion 'schema version kept'
    }

    Invoke-Test 'B2: support result parser reports NoResult for missing, invalid, non-boolean or wrong-schema results' {
        $r = Read-GsTraySupportResult -Path (Join-Path $resultsDir 'no-such-support.json')
        Assert-Equal 'NoResult' $r.Code 'missing file'
        $p = New-TestFile 'support-garbage.json' 'not json {'
        Assert-Equal 'NoResult' (Read-GsTraySupportResult -Path $p).Code 'invalid json'
        $p2 = New-TestFile 'support-empty.json' ''
        Assert-Equal 'NoResult' (Read-GsTraySupportResult -Path $p2).Code 'empty file'
        $p3 = New-TestFile 'support-string-success.json' '{"schemaVersion":1,"Success":"yes"}'
        Assert-Equal 'NoResult' (Read-GsTraySupportResult -Path $p3).Code 'non-boolean success'
        $p4 = New-TestFile 'support-wrong-schema.json' '{"schemaVersion":2,"Success":true,"ZipPath":"x.zip"}'
        $r4 = Read-GsTraySupportResult -Path $p4
        Assert-Equal 'NoResult' $r4.Code 'wrong schemaVersion is not a usable K1 result'
        Assert-Equal 0 $r4.SchemaVersion 'wrong schema version reported as 0'
    }

    Invoke-Test 'B2: missing gs-support.ps1 maps to the not-installed balloon and unknown codes stay raw' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $en = Get-GsTrayBuiltinStrings
        $missingPath = Join-Path $workDir 'no-such-support-dir\gs-support.ps1'
        Assert-True (-not (Test-Path -LiteralPath $missingPath -PathType Leaf)) 'fixture: support script absent'
        $text = Format-GsTrayText -Strings $zh.Strings -Key 'support.missing'
        Assert-Equal ([string]$zh.Strings['support.missing']) $text 'zh not-installed text'
        Assert-True ($text -ne [string]$en['support.missing']) 'not-installed text is translated'
        $unknown = Resolve-GsTraySupportBalloon -Strings $zh.Strings -Code 'MysteryCode'
        Assert-True ($unknown.Text -like '*MysteryCode') 'unknown support code shown raw'
        Assert-Equal 'Error' $unknown.Kind 'unknown code kind'
        $noResult = Resolve-GsTraySupportBalloon -Strings $zh.Strings -Code 'NoResult'
        Assert-Equal ([string]$zh.Strings['support.noResult']) $noResult.Text 'no-result balloon'
        Assert-Equal 'Error' $noResult.Kind 'no-result kind'
    }

    # ---- B3 (optional): notifications and pause flag ---------------------------

    Invoke-Test 'B3: notification fires on confirmed Ready->Streaming and Streaming->Ready' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $started = Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Ready' -Previous 'Streaming' -Current 'Streaming'
        Assert-Equal ([string]$zh.Strings['notify.streamStarted']) $started 'start notification'
        $ended = Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Streaming' -Previous 'Ready' -Current 'Ready'
        Assert-Equal ([string]$zh.Strings['notify.streamEnded']) $ended 'end notification'
        Assert-True ($started -ne [string](Get-GsTrayBuiltinStrings)['notify.streamStarted']) 'start text is translated'
    }

    Invoke-Test 'B3: a single poll in the new state does not notify (debounce)' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-True ($null -eq (Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Ready' -Previous 'Ready' -Current 'Streaming')) 'first poll in the new state stays silent'
        Assert-True ($null -eq (Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Streaming' -Previous 'Streaming' -Current 'Ready')) 'first poll back stays silent'
    }

    Invoke-Test 'B3: a one-poll blip produces no notification and no false end notification' {
        # Ready confirmed, then one Streaming poll, then Ready again: the
        # blip must be fully silent (in particular, no stream-ended text
        # when Ready resumes).
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $blip1 = Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Ready' -Previous 'Ready' -Current 'Streaming'
        $blip2 = Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Ready' -Previous 'Streaming' -Current 'Ready'
        $blip3 = Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Ready' -Previous 'Ready' -Current 'Ready'
        Assert-True ($null -eq $blip1 -and $null -eq $blip2 -and $null -eq $blip3) 'the blip is fully silent'
    }

    Invoke-Test 'B3: notification stays silent while the state is unchanged or unconfirmed' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-True ($null -eq (Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Ready' -Previous 'Ready' -Current 'Ready')) 'stable state stays silent'
        Assert-True ($null -eq (Get-GsTrayNotification -Strings $zh.Strings -Confirmed '' -Previous 'Ready' -Current 'Ready')) 'no notification before the first confirmed state'
        Assert-True ($null -eq (Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Ready' -Previous 'Ready' -Current '')) 'empty current state stays silent'
    }

    Invoke-Test 'B3: notification ignores non Ready/Streaming transitions' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-True ($null -eq (Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Stopped' -Previous 'Error' -Current 'Error')) 'Stopped -> Error stays silent'
        Assert-True ($null -eq (Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Starting' -Previous 'Ready' -Current 'Ready')) 'Starting -> Ready stays silent'
    }

    Invoke-Test 'B3: notification appends the pause suffix and stays within 63 characters' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $suffix = Format-GsTrayText -Strings $zh.Strings -Key 'notify.pausedSuffix'
        $plain = Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Ready' -Previous 'Streaming' -Current 'Streaming'
        $paused = Get-GsTrayNotification -Strings $zh.Strings -Confirmed 'Ready' -Previous 'Streaming' -Current 'Streaming' -Paused $true -PausedSuffix $suffix
        Assert-True ($paused.StartsWith([string]$plain)) 'suffix appended after the plain text'
        Assert-True ($paused.Length -gt $plain.Length) 'suffix adds length'
        Assert-True ($paused.Length -le 63) ('within 63 characters: ' + $paused.Length)
    }

    Invoke-Test 'B3: pause flag detected via the StateDir path' {
        $dir = Join-Path $workDir 'pause-statedir'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Assert-True (-not (Test-GsTrayPauseFlag -StateDir $dir)) 'no flag yet'
        [System.IO.File]::WriteAllText((Join-Path $dir 'supervisor_pause.flag'), 'paused', $utf8)
        Assert-True (Test-GsTrayPauseFlag -StateDir $dir) 'flag found at the StateDir root'
    }

    Invoke-Test 'B3: pause flag detected via the runtime path' {
        $dir = Join-Path $workDir 'pause-runtime'
        New-Item -ItemType Directory -Path (Join-Path $dir 'runtime\state') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'runtime\state\supervisor_pause.flag'), 'paused', $utf8)
        Assert-True (Test-GsTrayPauseFlag -StateDir $dir) 'flag found under runtime\state'
    }

    Invoke-Test 'B3: pause flag check never deletes the flag and stays false without one' {
        $dir = Join-Path $workDir 'pause-keep'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Assert-True (-not (Test-GsTrayPauseFlag -StateDir $dir)) 'false without a flag'
        $flagPath = Join-Path $dir 'supervisor_pause.flag'
        [System.IO.File]::WriteAllText($flagPath, 'paused', $utf8)
        [void](Test-GsTrayPauseFlag -StateDir $dir)
        [void](Test-GsTrayPauseFlag -StateDir $dir)
        Assert-True (Test-Path -LiteralPath $flagPath -PathType Leaf) 'flag still exists after two checks'
        Assert-Equal 'paused' ([System.IO.File]::ReadAllText($flagPath)) 'flag content untouched'
    }

    Invoke-Test 'B3: tooltip gets the pause suffix only when paused and stays within 63 characters' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        $prefix = Format-GsTrayText -Strings $zh.Strings -Key 'tooltip.prefix'
        $detail = Format-GsTrayText -Strings $zh.Strings -Key 'detail.streaming'
        $suffix = Format-GsTrayText -Strings $zh.Strings -Key 'notify.pausedSuffix'
        $plain = Get-GsTrayTooltipText -Prefix $prefix -Detail $detail
        $paused = Get-GsTrayTooltipText -Prefix $prefix -Detail $detail -Paused $true -PausedSuffix $suffix
        Assert-True ($paused.EndsWith($suffix)) 'suffix at the end'
        Assert-True ($plain.StartsWith($prefix) -and -not $plain.EndsWith($suffix)) 'plain tooltip has no suffix'
        Assert-True ($plain.Length -le 63 -and $paused.Length -le 63) 'both within 63 characters'
        $capped = Get-GsTrayTooltipText -Prefix $prefix -Detail ('y' * 200) -Paused $true -PausedSuffix $suffix
        Assert-Equal 63 $capped.Length 'long tooltip capped at exactly 63'
    }

    # ---- Round 4 review fixes (B-B1..B-B4, B-N1, B-N2) -------------------------

    Invoke-Test 'R4-B1: the startup tooltip assignment goes through the capped tooltip composer' {
        # The initial NotifyIcon.Text must be composed (and therefore capped)
        # exactly like every later poll tooltip; a direct assignment of the
        # raw table prefix would throw on a 64 character tooltip.prefix.
        $trayText = [System.IO.File]::ReadAllText($trayPath)
        $startup = [regex]::Match($trayText, '(?m)^\$script:Notify\.Text\s*=\s*(.+?)\s*$')
        Assert-True $startup.Success 'startup NotifyIcon.Text assignment found'
        $rhs = $startup.Groups[1].Value
        Assert-True ($rhs -like '*Get-GsTrayTooltipText*') ('startup tooltip goes through Get-GsTrayTooltipText: ' + $rhs)
        Assert-True ($rhs -like '*tooltip.prefix*') 'startup tooltip uses the tooltip.prefix key'
        $capped = Get-GsTrayTooltipText -Prefix ('P' * 64)
        Assert-True ($capped.Length -le 63) ('a 64 character prefix is capped to ' + $capped.Length)
    }

    Invoke-Test 'R4-B1: a 64 character tooltip.prefix is a valid table value the composer must cap' {
        $json = New-FullTableJson -Overrides @{ 'tooltip.prefix' = ('P' * 64) }
        $p = New-TestFile 'r4-long-prefix-strings.json' $json
        $loaded = Get-GsTrayStrings -Path $p
        Assert-Equal 'file' $loaded.Source ('a 64 character prefix is a valid table value (reason: ' + $loaded.FallbackReason + ')')
        $prefix = [string]$loaded.Strings['tooltip.prefix']
        Assert-Equal 64 $prefix.Length 'prefix kept at 64 characters'
        $capped = Get-GsTrayTooltipText -Prefix $prefix
        Assert-True ($capped.Length -le 63) ('composer caps the 64 character prefix to ' + $capped.Length)
        Assert-True ($capped.StartsWith('P')) 'capped tooltip keeps the prefix text'
    }

    Invoke-Test 'R4-B2: a placeholder alignment attack table falls back and formatting stays bounded' {
        # {0} + 2048 x {0,999999}: the old count-only check saw exactly one
        # placeholder and accepted the table; formatting it would allocate
        # gigabytes of padding on the UI thread.
        $hostile = '{0}' + ('{0,999999}' * 2048)
        $result = Get-GsTrayStrings -Path (New-TestFile 'r4-align-2048.json' (New-FullTableJson -Overrides @{ 'balloon.actionCompleted' = $hostile }))
        Assert-Equal 'builtin' $result.Source ('2048 alignment clauses fall back (reason: ' + $result.FallbackReason + ')')
        Assert-True (($result.FallbackReason -like '*512*') -or ($result.FallbackReason -like '*placeholder*')) ('reason: ' + $result.FallbackReason)
        $text = Format-GsTrayText -Strings $result.Strings -Key 'balloon.actionCompleted' -Arguments @('Start')
        Assert-True ($text.Length -lt 100) ('formatting after the fallback stays bounded: ' + $text.Length)
        # A short alignment clause is rejected by the placeholder syntax rule
        # alone (the value is well inside the 512 character cap).
        $short = '{0}' + ('{0,999999}' * 10)
        $result2 = Get-GsTrayStrings -Path (New-TestFile 'r4-align-short.json' (New-FullTableJson -Overrides @{ 'balloon.actionCompleted' = $short }))
        Assert-Equal 'builtin' $result2.Source 'short alignment clause falls back'
        Assert-True ($result2.FallbackReason -like '*placeholder*') ('reason names the placeholder: ' + $result2.FallbackReason)
        # A format clause ({0:X}) is rejected as well.
        $result3 = Get-GsTrayStrings -Path (New-TestFile 'r4-format-clause.json' (New-FullTableJson -Overrides @{ 'balloon.actionCompleted' = '{0:X} done.' }))
        Assert-Equal 'builtin' $result3.Source 'format clause falls back'
    }

    Invoke-Test 'R4-B2: a string table file over 64 KB falls back before parsing' {
        $json = New-FullTableJson
        $padded = $json.Substring(0, $json.Length - 1) + ((' ' * 70000) + '}')
        $p = New-TestFile 'r4-oversize-strings.json' $padded
        $fileBytes = (Get-Item -LiteralPath $p).Length
        Assert-True ($fileBytes -gt 65536) ('fixture is over 64 KB: ' + $fileBytes)
        $result = Get-GsTrayStrings -Path $p
        Assert-Equal 'builtin' $result.Source ('over-64KB table falls back (reason: ' + $result.FallbackReason + ')')
        Assert-True ($result.FallbackReason -like '*65536*') ('reason names the size limit: ' + $result.FallbackReason)
    }

    Invoke-Test 'R4-B2: a value over 512 characters falls back (512 exactly is accepted)' {
        $long = New-FullTableJson -Overrides @{ 'detail.stopped' = ('x' * 513) }
        $result = Get-GsTrayStrings -Path (New-TestFile 'r4-long-value.json' $long)
        Assert-Equal 'builtin' $result.Source 'a 513 character value falls back'
        Assert-True ($result.FallbackReason -like '*512*') ('reason names the value cap: ' + $result.FallbackReason)
        $boundary = New-FullTableJson -Overrides @{ 'detail.stopped' = ('x' * 512) }
        $result2 = Get-GsTrayStrings -Path (New-TestFile 'r4-boundary-value.json' $boundary)
        Assert-Equal 'file' $result2.Source ('exactly 512 characters is accepted (reason: ' + $result2.FallbackReason + ')')
    }

    Invoke-Test 'R4-B2: out-of-range placeholder indices fall back (in-range reorder stays valid)' {
        # status.lastResult has two placeholders: {2}/{3} keep the count but
        # are out of range, which the old count-only check accepted.
        $oob = New-FullTableJson -Overrides @{ 'status.lastResult' = 'X{2}Y{3}Z' }
        $result = Get-GsTrayStrings -Path (New-TestFile 'r4-oob-index.json' $oob)
        Assert-Equal 'builtin' $result.Source 'out-of-range placeholder indices fall back'
        Assert-True ($result.FallbackReason -like '*placeholder*') ('reason: ' + $result.FallbackReason)
        $reordered = New-FullTableJson -Overrides @{ 'status.lastResult' = 'Code={1} Success={0}' }
        $result2 = Get-GsTrayStrings -Path (New-TestFile 'r4-reordered-index.json' $reordered)
        Assert-Equal 'file' $result2.Source ('in-range reordered placeholders stay valid (reason: ' + $result2.FallbackReason + ')')
    }

    Invoke-Test 'R4-B3: the support launch decision refuses an elevated tray and allows a non-elevated one' {
        $refused = Resolve-GsTraySupportLaunch -Elevated $true
        Assert-True (-not $refused.Launch) 'an elevated tray must not launch the support child'
        Assert-Equal 'ElevatedTray' $refused.RefusedReason 'fixed refusal reason'
        $allowed = Resolve-GsTraySupportLaunch -Elevated $false
        Assert-True $allowed.Launch 'a non-elevated tray launches the support child'
        Assert-Equal '' $allowed.RefusedReason 'no refusal reason when allowed'
        $probe = Test-GsTrayElevated
        Assert-True ($null -ne $probe) 'the elevation probe returns'
        Assert-True ($probe -is [bool]) 'the elevation probe returns a boolean'
    }

    Invoke-Test 'R4-B3: gs-tray.ps1 checks the injectable elevation probe before any support launch' {
        $trayText = [System.IO.File]::ReadAllText($trayPath)
        Assert-True ($trayText -match '\$script:IsTrayElevated\s*=\s*') 'injectable elevation probe slot defined'
        $funcMatch = [regex]::Match($trayText, '(?s)function Invoke-MenuSupportBundle \{.*?\r?\n\}')
        Assert-True $funcMatch.Success 'Invoke-MenuSupportBundle found'
        $body = $funcMatch.Value
        $probeIndex = $body.IndexOf('$script:IsTrayElevated')
        $decisionIndex = $body.IndexOf('Resolve-GsTraySupportLaunch')
        $logIndex = $body.IndexOf('Support bundle refused')
        $balloonIndex = $body.IndexOf('support.elevatedRefused')
        $launchIndex = $body.IndexOf('Start-Process')
        Assert-True ($probeIndex -ge 0) 'menu item calls the injectable elevation probe'
        Assert-True ($decisionIndex -ge 0) 'menu item asks the pure launch decision'
        Assert-True ($logIndex -ge 0) 'English refusal log line present'
        Assert-True ($balloonIndex -ge 0) 'fixed refusal balloon key present'
        Assert-True ($launchIndex -ge 0) 'support launch still present for the non-elevated branch'
        Assert-True ($balloonIndex -lt $launchIndex) 'the refusal branch comes before any Start-Process'
    }

    Invoke-Test 'R4-B3: the elevated-refusal string exists in both tables and is translated' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-Equal 'file' $zh.Source 'shipped zh table loads'
        $en = Get-GsTrayBuiltinStrings
        Assert-True ($en.ContainsKey('support.elevatedRefused')) 'built-in English table has the refusal key'
        Assert-True ($zh.Strings.ContainsKey('support.elevatedRefused')) 'zh table has the refusal key'
        $enText = [string]$en['support.elevatedRefused']
        $zhText = [string]$zh.Strings['support.elevatedRefused']
        Assert-True (($enText.Length -gt 0) -and ($enText.Length -le 512)) 'English value bounded'
        Assert-True (($zhText.Length -gt 0) -and ($zhText.Length -le 512)) 'Chinese value bounded'
        Assert-True ($enText -notlike '*{*') 'English value has no placeholders'
        Assert-True ($zhText -notlike '*{*') 'Chinese value has no placeholders'
        Assert-True ($zhText -ne $enText) 'refusal text is translated'
    }

    Invoke-Test 'R4-B4: a long detail keeps the pause suffix inside the 63 character tooltip budget' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-Equal 'file' $zh.Source 'zh table loads'
        $prefix = Format-GsTrayText -Strings $zh.Strings -Key 'tooltip.prefix'
        $suffix = Format-GsTrayText -Strings $zh.Strings -Key 'notify.pausedSuffix'
        $row = Get-GsTrayState -StatusInfo (New-FakeStatusInfo -State ('x' * 200)) -ServerInfo $null
        $detail = Get-GsTrayDetailText -Strings $zh.Strings -StateRow $row
        $tooltip = Get-GsTrayTooltipText -Prefix $prefix -Detail $detail -Paused $true -PausedSuffix $suffix
        Assert-True ($tooltip.Length -le 63) ('tooltip within 63: ' + $tooltip.Length)
        Assert-True ($tooltip.EndsWith($suffix)) 'the pause suffix survives a long detail'
        Assert-True ($tooltip.StartsWith($prefix)) 'the prefix survives a long detail'
        $detailPart = $tooltip.Substring($prefix.Length, $tooltip.Length - $prefix.Length - $suffix.Length)
        Assert-True ($detail.StartsWith($detailPart)) 'the detail is truncated, not mangled'
        Assert-True ($detailPart.Length -lt $detail.Length) 'the detail was actually truncated to make room'
        $plain = Get-GsTrayTooltipText -Prefix $prefix -Detail ('y' * 200)
        Assert-True ($plain.Length -le 63) 'a long detail without pause stays within 63'
    }

    Invoke-Test 'R4-N1: balloon resolvers accept an empty Code and normalize a missing failure code' {
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-Equal 'file' $zh.Source 'zh table loads'
        $ok = Resolve-GsTraySupportBalloon -Strings $zh.Strings -Code '' -ZipPath 'C:\x\bundle.zip'
        Assert-True ($ok.Text -like '*bundle.zip') ('empty Code is the documented success branch: ' + $ok.Text)
        Assert-Equal 'Info' $ok.Kind 'empty-code success kind'
        $emptyRecover = Resolve-GsTrayRecoverBalloon -Strings $zh.Strings -Code ''
        Assert-True ($emptyRecover.Text -like '*NoResult*') ('a missing recover failure code shows NoResult: ' + $emptyRecover.Text)
        Assert-Equal 'Error' $emptyRecover.Kind 'missing recover code kind'
        $blankRecover = Resolve-GsTrayRecoverBalloon -Strings $zh.Strings -Code '   '
        Assert-True ($blankRecover.Text -like '*NoResult*') 'a whitespace recover code is normalized too'
        $noResultSupport = Resolve-GsTraySupportBalloon -Strings $zh.Strings -Code 'NoResult'
        Assert-Equal ([string]$zh.Strings['support.noResult']) $noResultSupport.Text 'NoResult keeps its own balloon'
    }

    Invoke-Test 'R4-N1: the tray normalizes a missing support failure code to NoResult' {
        # Functional: a support result whose failure carries no code parses
        # with an empty Code; normalizing it to NoResult maps to the
        # no-result balloon and can never show the empty-code success text.
        $zh = Get-GsTrayStrings -Path $zhStringsPath
        Assert-Equal 'file' $zh.Source 'zh table loads'
        $p = New-TestFile 'r4-support-nocode.json' '{"schemaVersion":1,"Success":false,"ZipPath":null,"Entries":[],"Errors":[{"Message":"no code"}]}'
        $parsed = Read-GsTraySupportResult -Path $p
        Assert-True (-not $parsed.Success) 'failure surfaced'
        Assert-Equal '' $parsed.Code 'parser keeps the missing failure code empty'
        $normalized = $parsed.Code
        if ([string]::IsNullOrWhiteSpace($normalized)) { $normalized = 'NoResult' }
        $balloon = Resolve-GsTraySupportBalloon -Strings $zh.Strings -Code $normalized
        Assert-Equal ([string]$zh.Strings['support.noResult']) $balloon.Text 'missing failure code maps to the no-result balloon'
        Assert-Equal 'Error' $balloon.Kind 'no-result kind'
        # Static: the tray host performs that normalization itself before it
        # asks for a balloon.
        $trayText = [System.IO.File]::ReadAllText($trayPath)
        $funcMatch = [regex]::Match($trayText, '(?s)function Update-PendingAction \{.*?\r?\n\}')
        Assert-True $funcMatch.Success 'Update-PendingAction found'
        $needle = 'if ([string]::IsNullOrWhiteSpace($supportCode)) { $supportCode = ''NoResult'' }'
        Assert-True ($funcMatch.Value.Contains($needle)) 'support failure branch normalizes an empty code to NoResult'
    }
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
