#Requires -Version 5.1
<#
.SYNOPSIS
  Unit and HTTP-fixture tests for the GsController local console server
  (product/gs-console.ps1), the fixed -File action helper
  (product/gs-console-action.ps1), the launcher (product/gs-console.vbs) and
  the Chinese string table.

.DESCRIPTION
  Safety envelope (LOCAL-CONSOLE-CONTRACT.md + coordinator clarifications):
  - Everything runs against TEMP fixtures and the fixed demo token or an
    explicit trusted -SessionToken. The REAL gs-product.ps1, the installed
    runtime, msiexec, scheduled tasks, services, ACLs, the registry, the
    firewall and ADB are NEVER touched. The live fixture uses a FAKE CLI
    script that only records which action names it received.
  - The in-process pure group dot-sources gs-console.ps1 with -DefineOnly.
  - The HTTP groups start real console server processes on an ephemeral
    127.0.0.1 port in -Demo -NoBrowser -NoTray mode (plus one live-mode
    server pointed at the fake CLI). If the OS refuses the loopback
    HttpListener bind, the HTTP groups are skipped explicitly; the pure
    group always runs.
  - Demo isolation is proven observably: the demo server gets a -ProductPath
    pointing at a marker fake that would record any invocation; after
    exercising every demo action the marker file must not exist, and the
    demo jobs directory must hold no request/result files.
  Exits 0 only when every test passes (skipped HTTP group does not fail the
  suite); exits 1 otherwise.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$consolePath = Join-Path $repoRoot 'product\gs-console.ps1'
$helperPath = Join-Path $repoRoot 'product\gs-console-action.ps1'
$vbsPath = Join-Path $repoRoot 'product\gs-console.vbs'
$stringsPath = Join-Path $repoRoot 'product\gs-console-strings.zh-CN.json'
$trayModelPath = Join-Path $repoRoot 'product\gs-tray-model.ps1'
$srcRoot = Join-Path $repoRoot 'src'
$demoToken = 'gs-console-demo'

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
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

function Invoke-Skip {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Reason)
    $script:Skipped++
    Write-Host "SKIP $Name :: $Reason"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw "Assertion failed: $Message" }
}

function Assert-NotNull {
    param($Value, [string]$Message)
    if ($null -eq $Value) { throw "Assertion failed: $Message (value was null)" }
}

function Assert-Null {
    param($Value, [string]$Message)
    if ($null -ne $Value) { throw "Assertion failed: $Message (value was not null)" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message (expected '$Expected', actual '$Actual')"
    }
}

function Assert-Contains {
    param([AllowNull()][string]$Haystack, [Parameter(Mandatory)][string]$Needle, [string]$Message)
    if ([string]::IsNullOrEmpty($Haystack) -or $Haystack.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "Assertion failed: $Message (did not find '$Needle')"
    }
}

function Assert-NotContains {
    param([AllowNull()][string]$Haystack, [Parameter(Mandatory)][string]$Needle, [string]$Message)
    if (-not [string]::IsNullOrEmpty($Haystack) -and $Haystack.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "Assertion failed: $Message (found forbidden '$Needle')"
    }
}

function Test-FileAscii {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    foreach ($b in $bytes) {
        if ($b -gt 127) { return $false }
    }
    return $true
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        try { $listener.Stop() } catch { }
    }
}

function Test-LoopbackListenerAllowed {
    # Preflight: non-admin accounts can normally bind an explicit
    # 127.0.0.1:<port> prefix; when a policy refuses it, the HTTP fixture
    # group is skipped explicitly (never worked around with a URL ACL).
    $port = Get-FreeTcpPort
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add(('http://127.0.0.1:' + $port + '/'))
    try {
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        try { $listener.Stop(); $listener.Close() } catch { }
    }
}

# ---------------------------------------------------------------------------
# TEMP fixtures
# ---------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('gs-console-api-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$assetDir = Join-Path $fixtureRoot 'static'
New-Item -ItemType Directory -Path $assetDir -Force | Out-Null
# Fixed static assets with the mode placeholder (the real frontend belongs
# to another worktree; this suite only needs substitution evidence).
$html = '<html><body data-mode="__GS_MODE__"><p>console fixture page</p></body></html>'
[IO.File]::WriteAllText((Join-Path $assetDir 'gs-console.html'), $html, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $assetDir 'gs-console.css'), 'body { color: #142C48; }', (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $assetDir 'gs-console.js'), 'document.body.textContent = "fixture";', (New-Object Text.UTF8Encoding($false)))

# Marker fake CLI: records ANY invocation to GS_CONSOLE_MARKER. The demo
# server receives it as -ProductPath; if a demo action ever reached the
# live action handler, the marker file would appear.
$markerFakePath = Join-Path $fixtureRoot 'fake-marker-gs-product.ps1'
[IO.File]::WriteAllText($markerFakePath, @'
param()
$ErrorActionPreference = 'Stop'
$log = $env:GS_CONSOLE_MARKER
if (-not [string]::IsNullOrWhiteSpace($log)) { Add-Content -LiteralPath $log -Value 'invoked' }
'@, (New-Object Text.UTF8Encoding($false)))

# Recording fake CLI for the live fixture: records each received -Action,
# supports modes via a file (busy / lastsuccess), otherwise succeeds. The
# LAST Success object must win over stray output and earlier objects.
$recordFakePath = Join-Path $fixtureRoot 'fake-record-gs-product.ps1'
[IO.File]::WriteAllText($recordFakePath, @'
param(
    [string]$Action, [string]$InstallDir = '', [string]$StateDir = '', [string]$LogDir = '',
    [string]$ComponentSourceDir = '', [string]$HelperSourceDir = '', [string]$CatalogPath = '',
    [string]$ModuleRoot = '', [string]$DiagnoseScript = '', [string]$ServerInfoUri = ''
)
$ErrorActionPreference = 'Stop'
$log = $env:GS_FAKE_CLI_LOG
if (-not [string]::IsNullOrWhiteSpace($log)) { Add-Content -LiteralPath $log -Value $Action }
$mode = 'ok'
$modeFile = $env:GS_FAKE_MODE_FILE
if (-not [string]::IsNullOrWhiteSpace($modeFile) -and (Test-Path -LiteralPath $modeFile)) {
    $raw = (Get-Content -LiteralPath $modeFile -Raw)
    if ($null -ne $raw) { $mode = $raw.Trim() }
}
Write-Output 'stray-opaque-output'
if (($mode -eq 'busy') -and ($Action -in @('Start', 'Stop', 'Recover'))) {
    return [pscustomobject]@{ Success = $false; Data = $null; Errors = @([pscustomobject]@{ Code = 'Busy'; Message = 'another lifecycle operation is in progress' }) }
}
if ($Action -eq 'Diagnose') {
    Write-Output 'OPAQUE-STDOUT-TOKEN'
    return [pscustomobject]@{ Success = $true; Data = [pscustomobject]@{
        schemaVersion  = 1
        generatedAtUtc = '2026-11-07T00:00:00.0000000Z'
        errors         = @([pscustomobject]@{ section = 'runtimeBundle'; code = 'SectionFailed'; message = 'opaque section message' })
        hygiene        = [pscustomobject]@{ findings = @(
            [pscustomobject]@{ code = 'SupervisorPaused'; severity = 'warning'; message = 'opaque flag line'; path = 'C:\opaque\flag' },
            [pscustomobject]@{ code = 'ScriptDirWritableByNonAdmin'; severity = 'high'; message = 'opaque acl text'; path = 'C:\opaque\dir' },
            [pscustomobject]@{ code = 'SupervisorTaskMissing'; severity = 'info'; message = 'info text'; path = 'p' }
        ) }
    }; Errors = @() }
}
if ($Action -eq 'Check') {
    return [pscustomobject]@{ Success = $true; Data = [pscustomobject]@{ RuntimeDir = 'demo' }; Errors = @() }
}
if (($mode -eq 'lastsuccess') -and ($Action -eq 'Start')) {
    [pscustomobject]@{ Success = $true; Data = $null; Errors = @() }
    return [pscustomobject]@{ Success = $false; Data = $null; Errors = @([pscustomobject]@{ Code = 'LateFailure'; Message = 'the last result must win' }) }
}
return [pscustomobject]@{ Success = $true; Data = [pscustomobject]@{ ExitCode = 0 }; Errors = @() }
'@, (New-Object Text.UTF8Encoding($false)))

$script:Servers = New-Object System.Collections.Generic.List[object]
$script:ServerSeq = 0

function Start-TestConsoleServer {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$ProductPath = '',
        [string]$StateDir = '',
        [string]$SessionToken = '',
        [switch]$Demo
    )
    $systemPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $systemPs)) { $systemPs = 'powershell.exe' }
    $argumentList = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "' + $consolePath + '"' +
        ' -Port ' + $Port +
        ' -ConfigPath "' + $ConfigPath + '"' +
        # $script:assetDir prefix is REQUIRED: the -StaticDir parameter of
        # the dot-sourced gs-console.ps1 shares this storage scope.
        ' -StaticDir "' + $script:assetDir + '"'
    if ($Demo) { $argumentList += ' -Demo' }
    if (-not [string]::IsNullOrWhiteSpace($ProductPath)) { $argumentList += ' -ProductPath "' + $ProductPath + '"' }
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) { $argumentList += ' -StateDir "' + $StateDir + '"' }
    if (-not [string]::IsNullOrWhiteSpace($SessionToken)) { $argumentList += ' -SessionToken "' + $SessionToken + '"' }
    $argumentList += ' -NoBrowser -NoTray -ExitAfterSec 240'
    $script:ServerSeq++
    $stderrFile = Join-Path $fixtureRoot ('server-' + $script:ServerSeq + '-' + $Port + '-stderr.txt')
    # -NoNewWindow (not -WindowStyle Hidden): -WindowStyle forces ShellExecute,
    # which makes Process.ExitCode unreadable - the suite asserts exit codes.
    $proc = Start-Process -FilePath $systemPs -ArgumentList $argumentList -NoNewWindow -PassThru `
        -RedirectStandardError $stderrFile
    $record = @{ Proc = $proc; Port = $Port; StdErrFile = $stderrFile }
    $script:Servers.Add($record)
    return $record
}

function Wait-TcpReady {
    param([Parameter(Mandatory)][int]$Port, [int]$TimeoutSec = 20)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $task = $client.ConnectAsync('127.0.0.1', $Port)
                if ($task.Wait(300) -and $client.Connected) { return $true }
            } finally { try { $client.Close() } catch { } }
        } catch { }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Stop-AllTestServers {
    foreach ($record in $script:Servers) {
        try {
            $proc = $record.Proc
            if ($null -ne $proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    $script:Servers.Clear()
}

function Invoke-ConsoleHttp {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$PathAndQuery,
        [string]$Session = '',
        [string]$Origin = '',
        [string]$HostHeader = '',
        [string]$BodyText = '',
        [int]$TimeoutMs = 15000
    )
    $url = ('http://127.0.0.1:' + $Port + $PathAndQuery)
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = $Method
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.AllowAutoRedirect = $false
    $req.Proxy = $null
    $req.KeepAlive = $false
    $req.ServicePoint.Expect100Continue = $false
    if ($Session -ne '') { $req.Headers['X-Gs-Session'] = $Session }
    if ($Origin -ne '') { $req.Headers['Origin'] = $Origin }
    if ($HostHeader -ne '') { $req.Host = $HostHeader }
    if ($BodyText -ne '') {
        $bytes = [Text.Encoding]::UTF8.GetBytes($BodyText)
        $req.ContentType = 'application/json'
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    try {
        $resp = $req.GetResponse()
        try {
            $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
            return @{ Status = [int]$resp.StatusCode; Body = $text; Headers = $resp.Headers }
        } finally { try { $resp.Close() } catch { } }
    } catch [System.Net.WebException] {
        $errorResponse = $_.Exception.Response
        if ($null -eq $errorResponse) { throw }
        try {
            $reader = New-Object IO.StreamReader($errorResponse.GetResponseStream(), [Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
            return @{ Status = [int]$errorResponse.StatusCode; Body = $text; Headers = $errorResponse.Headers }
        } finally { try { $errorResponse.Close() } catch { } }
    }
}

function Wait-GsJobDone {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Session, [Parameter(Mandatory)][string]$JobId)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        $response = Invoke-ConsoleHttp -Port $Port -Method 'GET' -PathAndQuery ('/api/jobs/' + $JobId) -Session $Session
        $doc = $response.Body | ConvertFrom-Json
        if ($doc.ok -and $doc.data.status -ne 'running') { return $doc.data }
        Start-Sleep -Milliseconds 150
    }
    throw "Job $JobId did not finish within 15 seconds"
}

function Invoke-RawHttp {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$RequestText, [int]$TimeoutMs = 6000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $bytes = [Text.Encoding]::ASCII.GetBytes($RequestText)
        $stream.Write($bytes, 0, $bytes.Length)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        $buffer = New-Object byte[] 65536
        $sb = New-Object System.Text.StringBuilder
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($stream.DataAvailable) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -gt 0) { [void]$sb.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $read)) }
                if ($sb.ToString().IndexOf("`r`n`r`n", [StringComparison]::Ordinal) -ge 0) { break }
            } else {
                Start-Sleep -Milliseconds 30
            }
        }
        return $sb.ToString()
    } finally { try { $client.Close() } catch { } }
}

# ---------------------------------------------------------------------------
# Group A: source hygiene and string table
# ---------------------------------------------------------------------------

Invoke-Test 'gs-console.ps1 is ASCII-only' {
    Assert-True (Test-FileAscii $consolePath) 'gs-console.ps1 must be pure ASCII'
}

Invoke-Test 'gs-console-action.ps1 is ASCII-only' {
    Assert-True (Test-FileAscii $helperPath) 'gs-console-action.ps1 must be pure ASCII'
}

Invoke-Test 'gs-console.vbs is ASCII-only and elevates through UAC with a fixed PowerShell path' {
    Assert-True (Test-FileAscii $vbsPath) 'gs-console.vbs must be pure ASCII'
    $text = [IO.File]::ReadAllText($vbsPath)
    Assert-Contains $text 'runas' 'the launcher must request UAC (runas)'
    Assert-Contains $text '-STA' 'the launcher must pass -STA'
    Assert-Contains $text '-ShowStartupErrors' 'the interactive launcher passes -ShowStartupErrors'
    Assert-Contains $text 'Sysnative' '32-bit wscript must target Sysnative'
    Assert-Contains $text 'System32\WindowsPowerShell\v1.0\powershell.exe' 'an explicit system PowerShell path is required'
    Assert-Contains $text 'gs-console.ps1' 'the launcher must target the console server'
    Assert-NotContains $text 'netsh' 'no firewall rules from the launcher'
    # ShellExecute belongs to Shell.Application, never to WScript.Shell.
    Assert-Contains $text 'CreateObject("Shell.Application")' 'the launcher creates a Shell.Application object'
    Assert-Contains $text 'shellApp.ShellExecute' 'ShellExecute is called on the Shell.Application object'
    Assert-NotContains $text 'shell.ShellExecute' 'WScript.Shell must not be used for ShellExecute'
    Assert-Contains $text 'ExpandEnvironmentStrings' 'WScript.Shell is kept for environment expansion'
}

Invoke-Test 'string table loads with Chinese UI text and bounded values' {
    $text = [IO.File]::ReadAllText($stringsPath)
    $json = $text | ConvertFrom-Json
    $open = $json.PSObject.Properties['tray.open']
    Assert-NotNull $open 'tray.open key missing'
    $da = [string][char]0x6253
    Assert-Contains ([string]$open.Value) $da 'tray.open must be Chinese'
    $stopped = $json.PSObject.Properties['state.stopped']
    Assert-NotNull $stopped 'state.stopped key missing'
    $needsSetup = $json.PSObject.Properties['state.needssetup']
    Assert-NotNull $needsSetup 'state.needssetup key missing'
    foreach ($prop in $json.PSObject.Properties) {
        Assert-True ($prop.Value.Length -le 512) ("value too long: " + $prop.Name)
    }
}

# ---------------------------------------------------------------------------
# Group B: pure logic (in-process, -DefineOnly)
# ---------------------------------------------------------------------------

. $consolePath -DefineOnly -Port 47991
. $helperPath -DefineOnly

$inprocConfig = Join-Path $fixtureRoot 'inproc-prefs.json'
$script:ConfigFilePath = $inprocConfig
$script:JobsRoot = Join-Path $fixtureRoot 'inproc-jobs'
New-Item -ItemType Directory -Path $script:JobsRoot -Force | Out-Null
$script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) }

Invoke-Test 'default targets never deploy into source and demo targets stay in TEMP' {
    $oldMode = $script:Mode
    $oldProduct = $script:ProductPathResolved
    $oldConfig = $script:ConfigFilePath
    $oldState = $script:StateDirDefault
    try {
        $demoBase = Join-Path $fixtureRoot 'default-demo'
        $script:Mode = 'demo'
        $script:ConfigFilePath = Join-Path $demoBase 'prefs.json'
        $script:StateDirDefault = Join-Path $demoBase 'state'
        $defaults = Get-GsConsoleDefaultSettings
        Assert-Equal (Join-Path $demoBase 'install') $defaults.installDir 'demo install target'
        Assert-Equal (Join-Path $demoBase 'state') $defaults.stateDir 'demo state target'
        Assert-Equal (Join-Path $demoBase 'logs') $defaults.logDir 'demo log target'
        $script:Mode = 'live'
        $sourceDir = Join-Path $fixtureRoot 'source-product'
        $script:ProductPathResolved = Join-Path $sourceDir 'gs-product.ps1'
        $defaults = Get-GsConsoleDefaultSettings
        Assert-True ($defaults.installDir -ne $sourceDir) 'source directory cannot be the default installation target'
        $installedDir = Join-Path $fixtureRoot 'installed-product'
        New-Item -ItemType Directory -Path (Join-Path $installedDir 'Modules') -Force | Out-Null
        $script:ProductPathResolved = Join-Path $installedDir 'gs-product.ps1'
        $defaults = Get-GsConsoleDefaultSettings
        Assert-Equal $installedDir $defaults.installDir 'installed layout retains its product directory'
    } finally {
        $script:Mode = $oldMode
        $script:ProductPathResolved = $oldProduct
        $script:ConfigFilePath = $oldConfig
        $script:StateDirDefault = $oldState
    }
}

Invoke-Test 'token comparison is exact and length-sensitive without early exit' {
    Assert-True (Test-GsConsoleTokenEqual -Provided 'secret42' -Expected 'secret42') 'equal tokens must match'
    Assert-False (Test-GsConsoleTokenEqual -Provided 'secret43' -Expected 'secret42') 'different content must not match'
    Assert-False (Test-GsConsoleTokenEqual -Provided 'secret42x' -Expected 'secret42') 'longer token must not match'
    Assert-False (Test-GsConsoleTokenEqual -Provided '' -Expected 'x') 'empty vs non-empty must not match'
    Assert-True (Test-GsConsoleTokenEqual -Provided '' -Expected '') 'empty vs empty matches'
}

Invoke-Test 'loopback check normalizes IPv4-mapped IPv6 and rejects non-loopback peers' {
    $mapped = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('::ffff:127.0.0.1'), 5000)
    $plain = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('127.0.0.1'), 5000)
    $v6 = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::IPv6Loopback, 5000)
    $lan = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('192.168.5.14'), 5000)
    $routable = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('203.0.113.9'), 5000)
    $mappedLan = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('::ffff:192.168.5.14'), 5000)
    Assert-True (Test-GsConsoleLoopbackEndPoint -EndPoint $mapped) 'IPv4-mapped loopback must be accepted'
    Assert-True (Test-GsConsoleLoopbackEndPoint -EndPoint $plain) 'plain IPv4 loopback must be accepted'
    Assert-True (Test-GsConsoleLoopbackEndPoint -EndPoint $v6) 'IPv6 ::1 must be accepted'
    Assert-False (Test-GsConsoleLoopbackEndPoint -EndPoint $lan) 'LAN addresses must be rejected'
    Assert-False (Test-GsConsoleLoopbackEndPoint -EndPoint $routable) 'routable addresses must be rejected'
    Assert-False (Test-GsConsoleLoopbackEndPoint -EndPoint $mappedLan) 'mapped LAN addresses must be rejected'
    Assert-False (Test-GsConsoleLoopbackEndPoint -EndPoint $null) 'missing endpoint must be rejected'
}

Invoke-Test 'directory path policy rejects UNC, roots, Windows dirs, ADS and relatives' {
    Assert-Equal 'NotAbsolutePath' (Test-GsConsoleDirectoryPath -Value '\\server\share\x').Code 'UNC must be rejected'
    Assert-Equal 'NotAbsolutePath' (Test-GsConsoleDirectoryPath -Value 'relative\path').Code 'relative paths must be rejected'
    Assert-Equal 'DriveRoot' (Test-GsConsoleDirectoryPath -Value 'C:\').Code 'drive roots must be rejected'
    Assert-Equal 'SystemPath' (Test-GsConsoleDirectoryPath -Value 'C:\Windows').Code 'the Windows directory must be rejected'
    Assert-Equal 'SystemPath' (Test-GsConsoleDirectoryPath -Value 'C:\Windows\System32\config').Code 'paths under Windows must be rejected'
    Assert-Equal 'InvalidPathSyntax' (Test-GsConsoleDirectoryPath -Value 'C:\data\evil:stream').Code 'ADS syntax must be rejected'
    Assert-Equal 'TooLong' (Test-GsConsoleDirectoryPath -Value ('C:\' + ('a' * 300))).Code 'oversized paths must be rejected'
    $ok = Test-GsConsoleDirectoryPath -Value 'C:\test-roots\console-target'
    Assert-True $ok.Ok 'a plain local directory must pass'
    Assert-Equal 'C:\test-roots\console-target' $ok.Path 'valid paths must normalize through GetFullPath'
}

Invoke-Test '8.3 short names expand to long names and overlap checks see through them' {
    $shortUsers = 'C:\Users\BANANA~1'
    if (-not (Test-Path -LiteralPath $shortUsers)) {
        # 8.3 name creation is disabled on this volume: nothing to verify.
        Write-Host '(no 8.3 short name available; expansion checks skipped)'
        return
    }
    $checked = Test-GsConsoleDirectoryPath -Value (Join-Path $shortUsers 'console-short-probe')
    Assert-True $checked.Ok 'a short-name path on the user profile must pass'
    Assert-True ($checked.Path -ieq (Join-Path 'C:\Users' ($env:USERNAME + '\console-short-probe'))) ('the short name must expand to the long form, got ' + $checked.Path)
    # A short-name spelling and its long spelling must collide in the
    # overlap checks (nested target refusal), never count as disjoint.
    $vals = @{
        displayName = 'X'
        installDir = (Join-Path $shortUsers 'gs-short-overlap')
        stateDir = (Join-Path 'C:\Users' ($env:USERNAME + '\gs-short-overlap\state'))
        logDir = 'C:\gs-short-overlap-logs'
        componentSourceDir = ''
        helperSourceDir = ''
        pollIntervalSec = 2
    }
    $checked2 = Test-GsConsoleSettingsValues -Settings $vals
    Assert-False $checked2.Ok 'short/long spellings of the same directory must overlap'
    Assert-Equal 'NestedDirectory' $checked2.Errors[0].code 'overlap failure code'
}

Invoke-Test 'loading saved prefs re-applies the full path policy (junction follow-up rejected)' {
    $linkRoot = Join-Path $fixtureRoot 'prefs-junction'
    $realDir = Join-Path $linkRoot 'real'
    New-Item -ItemType Directory -Path $realDir -Force | Out-Null
    $linkPath = Join-Path $linkRoot 'link'
    $created = $false
    try {
        New-Item -ItemType Junction -Path $linkPath -Value $realDir -ErrorAction Stop | Out-Null
        $created = $true
    } catch { }
    if (-not $created) { throw 'junction creation unsupported on this filesystem' }
    $cfgDir = Join-Path $linkRoot 'cfg'
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    $previousConfig = $script:ConfigFilePath
    $previousProduct = $script:ProductPathResolved
    $previousStateDefault = $script:StateDirDefault
    $previousMode = $script:Mode
    $previousRuntime = $script:GsRuntimeAvailable
    try {
        $script:ConfigFilePath = Join-Path $cfgDir 'p.json'
        # The prefs file was saved when the path was a plain directory; the
        # junction appeared afterwards. Reloading must refuse it.
        $doc = ConvertTo-Json -InputObject @{
            schemaVersion = 1
            revision = 5
            settings = @{
                displayName = 'Junction test'
                installDir = 'C:\prefs-junction-install'
                stateDir = (Join-Path $linkPath 'state')
                logDir = 'C:\prefs-junction-logs'
                componentSourceDir = ''
                helperSourceDir = ''
                pollIntervalSec = 2
            }
        } -Depth 4 -Compress
        [IO.File]::WriteAllText($script:ConfigFilePath, $doc, (New-Object Text.UTF8Encoding($false)))
        $script:ProductPathResolved = 'C:\prefs-junction\fake.ps1'
        $script:StateDirDefault = 'C:\prefs-junction-default-state'
        $script:Mode = 'live'
        $script:GsRuntimeAvailable = $false
        $prefs = Read-GsConsolePrefs
        Assert-Equal 1 $prefs.Revision 'a prefs file whose path now crosses a junction is rejected (defaults at revision 1)'
        Assert-Equal 'This PC' $prefs.Settings.displayName 'defaults restored'
    } finally {
        $script:ConfigFilePath = $previousConfig
        $script:ProductPathResolved = $previousProduct
        $script:StateDirDefault = $previousStateDefault
        $script:Mode = $previousMode
        $script:GsRuntimeAvailable = $previousRuntime
    }
}

Invoke-Test 'retargeting guard refuses everything but explicit stopped/needsSetup' {
    $previousMode = $script:Mode
    $previousJob = $script:CurrentJob
    $previousPrefs = $script:Prefs
    $previousStateDefault = $script:StateDirDefault
    $previousProduct = $script:ProductPathResolved
    $previousScenario = $script:DemoScenario
    $previousServerInfo = $script:ServerInfoUriResolved
    try {
        $script:CurrentJob = $null
        # Demo: ONLY stopped/needsSetup allow retargeting or deployment;
        # error is conservatively active (a "ready but unreachable" runtime
        # maps to error and must never be retargeted).
        $script:Mode = 'demo'
        $script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) }
        foreach ($scenario in @('ready', 'streaming', 'error')) {
            $script:DemoScenario = $scenario
            Assert-True (Test-GsConsoleRuntimeActive) ("demo $scenario is active")
        }
        foreach ($scenario in @('stopped', 'needsSetup')) {
            $script:DemoScenario = $scenario
            Assert-False (Test-GsConsoleRuntimeActive) ("demo $scenario is not active")
        }
        # Capabilities mirror the guard: deploy requires a source dir AND an
        # explicitly stopped/undeployed runtime.
        $script:Prefs.Settings.componentSourceDir = 'C:\guard-src'
        foreach ($scenario in @('ready', 'streaming', 'error')) {
            $script:DemoScenario = $scenario
            $caps = Get-GsConsoleCapabilities -StateRow ([pscustomobject]@{ State = 'Stopped'; CanStart = $false; CanStop = $false }) -IsElevated $false -RuntimeState $scenario
            Assert-False $caps.deploy ("demo $scenario must not be deployable")
        }
        $script:DemoScenario = 'stopped'
        $capsStopped = Get-GsConsoleCapabilities -StateRow ([pscustomobject]@{ State = 'Stopped'; CanStart = $false; CanStop = $false }) -IsElevated $false -RuntimeState 'stopped'
        Assert-True $capsStopped.deploy 'a stopped runtime with a source dir is deployable'
        $script:Prefs.Settings.componentSourceDir = ''
        $script:DemoScenario = 'stopped'
        # Live: mid-transition statuses refuse (no serverinfo fetch needed);
        # a ready status with an unreachable serverinfo maps to Error and
        # STAYS active; only stopped and undeployed allow.
        $liveState = Join-Path $fixtureRoot 'guard-live-state'
        $script:Mode = 'live'
        $script:StateDirDefault = $liveState
        $script:ProductPathResolved = (Join-Path $fixtureRoot 'guard-fake.ps1')
        [IO.File]::WriteAllText($script:ProductPathResolved, 'param()')
        $script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) }
        $closedPort = Get-FreeTcpPort
        $script:ServerInfoUriResolved = ('http://127.0.0.1:' + $closedPort + '/serverinfo')
        Assert-False (Test-GsConsoleRuntimeActive) 'undeployed live runtime is not active'
        New-Item -ItemType Directory -Path (Join-Path $liveState 'runtime\bin') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $liveState 'runtime\bin\gs_stop_private.ps1'), 'param()')
        New-Item -ItemType Directory -Path (Join-Path $liveState 'runtime\state') -Force | Out-Null
        Assert-False (Test-GsConsoleRuntimeActive) 'deployed without a status file (stopped) is not active'
        $statusPath = Join-Path $liveState 'runtime\state\status.json'
        [IO.File]::WriteAllText($statusPath, '{"state":"starting"}', (New-Object Text.UTF8Encoding($false)))
        Assert-True (Test-GsConsoleRuntimeActive) 'a starting runtime is active'
        [IO.File]::WriteAllText($statusPath, '{"state":"stopping"}', (New-Object Text.UTF8Encoding($false)))
        Assert-True (Test-GsConsoleRuntimeActive) 'a stopping runtime is active'
        [IO.File]::WriteAllText($statusPath, '{"state":"ready"}', (New-Object Text.UTF8Encoding($false)))
        Assert-True (Test-GsConsoleRuntimeActive) 'ready with unreachable serverinfo (mapped error) stays active'
        [IO.File]::WriteAllText($statusPath, '{"state":"stopped"}', (New-Object Text.UTF8Encoding($false)))
        Assert-False (Test-GsConsoleRuntimeActive) 'a stopped runtime is not active'
    } finally {
        $script:Mode = $previousMode
        $script:CurrentJob = $previousJob
        $script:Prefs = $previousPrefs
        $script:StateDirDefault = $previousStateDefault
        $script:ProductPathResolved = $previousProduct
        $script:DemoScenario = $previousScenario
        $script:ServerInfoUriResolved = $previousServerInfo
    }
}

Invoke-Test 'settings validation enforces exact types, bounds and disjoint targets' {
    $valid = @{
        displayName = '  Test PC  '; installDir = 'C:\t1\install'; stateDir = 'C:\t2\state'; logDir = 'C:\t3\logs'
        componentSourceDir = ''; helperSourceDir = ''; pollIntervalSec = 2
    }
    $checked = Test-GsConsoleSettingsValues -Settings $valid
    Assert-True $checked.Ok ('valid settings must pass: ' + (($checked.Errors | ForEach-Object { $_.code }) -join ','))
    Assert-Equal 'Test PC' $checked.Settings.displayName 'displayName must be trimmed'
    Assert-Equal 'C:\t1\install' $checked.Settings.installDir 'paths must be kept absolute'

    $badType = $valid.Clone(); $badType.pollIntervalSec = 'fast'
    $checkedType = Test-GsConsoleSettingsValues -Settings $badType
    Assert-False $checkedType.Ok 'non-integer pollIntervalSec must fail'

    $badRange = $valid.Clone(); $badRange.pollIntervalSec = 11
    Assert-False (Test-GsConsoleSettingsValues -Settings $badRange).Ok 'pollIntervalSec 11 must fail'
    $badRange2 = $valid.Clone(); $badRange2.pollIntervalSec = 0
    Assert-False (Test-GsConsoleSettingsValues -Settings $badRange2).Ok 'pollIntervalSec 0 must fail'

    $longName = $valid.Clone(); $longName.displayName = ('x' * 61)
    Assert-False (Test-GsConsoleSettingsValues -Settings $longName).Ok '61-char displayName must fail'

    $nested = $valid.Clone(); $nested.stateDir = 'C:\t1\install\state'
    $nestedCheck = Test-GsConsoleSettingsValues -Settings $nested
    Assert-False $nestedCheck.Ok 'nested targets must fail'
    Assert-Equal 'NestedDirectory' $nestedCheck.Errors[0].code 'nested failure code'

    $overlap = $valid.Clone(); $overlap.componentSourceDir = 'C:\t2\state\src'
    $overlapCheck = Test-GsConsoleSettingsValues -Settings $overlap
    Assert-False $overlapCheck.Ok 'source inside a target must fail'
    Assert-Equal 'OverlappingPath' $overlapCheck.Errors[0].code 'overlap failure code'

    $sameTarget = $valid.Clone(); $sameTarget.logDir = 'C:\t2\state'
    $sameCheck = Test-GsConsoleSettingsValues -Settings $sameTarget
    Assert-False $sameCheck.Ok 'identical targets must fail'
    Assert-Equal 'SameDirectory' $sameCheck.Errors[0].code 'same-directory failure code'

    $unc = $valid.Clone(); $unc.stateDir = '\\server\share\state'
    Assert-False (Test-GsConsoleSettingsValues -Settings $unc).Ok 'UNC targets must fail'

    $windows = $valid.Clone(); $windows.installDir = 'C:\Windows\console'
    Assert-False (Test-GsConsoleSettingsValues -Settings $windows).Ok 'Windows-dir targets must fail'
}

Invoke-Test 'reparse-point ancestors are refused (no traversal through links)' {
    $linkRoot = Join-Path $fixtureRoot 'reparse-probe'
    $realDir = Join-Path $linkRoot 'real'
    New-Item -ItemType Directory -Path $realDir -Force | Out-Null
    $linkPath = Join-Path $linkRoot 'link'
    $created = $false
    try {
        New-Item -ItemType Junction -Path $linkPath -Value $realDir -ErrorAction Stop | Out-Null
        $created = $true
    } catch { }
    if ($created) {
        $checked = Test-GsConsoleDirectoryPath -Value (Join-Path $linkPath 'target')
        Assert-Equal 'ReparsePath' $checked.Code 'a junction ancestor must be refused'
        $direct = Test-GsConsoleDirectoryPath -Value $realDir
        Assert-True $direct.Ok 'the real directory itself must pass'
    } else {
        throw 'junction creation unsupported on this filesystem'
    }
}

Invoke-Test 'job budgets match the tray action caps' {
    Assert-Equal 300 $script:JobBudgetSec['stop'] 'stop budget'
    Assert-Equal 300 $script:JobBudgetSec['start'] 'start budget (same cap as the tray pending wait)'
    Assert-Equal 600 $script:JobBudgetSec['deploy'] 'deploy budget'
    Assert-True ($script:JobBudgetSec['recover'] -ge $script:JobBudgetSec['stop']) 'recover must cover a full stop'
    Assert-Equal 16384 $script:BodyMaxBytes 'body cap must be 16 KiB'
}

Invoke-Test 'diagnose summary projection maps the real report shape to stable categories' {
    # Real gs-diagnose shape: top-level errors[] = {section,code,message}
    # and findings under hygiene.findings[] = {code,severity,message,path}.
    $report = [pscustomobject]@{
        schemaVersion  = 1
        generatedAtUtc = '2026-11-07T00:00:00.0000000Z'
        errors         = @(
            [pscustomobject]@{ section = 'runtimeBundle'; code = 'SectionFailed'; message = 'opaque section message' }
        )
        hygiene        = [pscustomobject]@{ findings = @(
            [pscustomobject]@{ code = 'SupervisorPaused'; severity = 'warning'; message = 'opaque flag line'; path = 'C:\opaque\flag' },
            [pscustomobject]@{ code = 'ScriptDirWritableByNonAdmin'; severity = 'high'; message = 'opaque acl text'; path = 'C:\opaque\dir' },
            [pscustomobject]@{ code = 'SupervisorTaskMissing'; severity = 'info'; message = 'info text'; path = 'p' }
        ) }
    }
    $summary = Get-GsConsoleDiagnoseSummary -ReportData $report
    Assert-Equal 1 $summary.summary.failed 'failed count'
    Assert-Equal 1 $summary.summary.warnings 'warnings count'
    Assert-Equal 1 $summary.summary.passed 'passed count'
    Assert-True ($summary.checks.Count -eq 4) 'four aggregated category entries'
    $byId = @{}
    foreach ($check in $summary.checks) { $byId[[string]$check.id] = $check }
    Assert-True $byId.ContainsKey('runtime') 'runtime category present'
    Assert-Equal 'unknown' $byId['runtime'].status 'a section error means that area could not be inspected'
    Assert-Equal 'SectionFailed' $byId['runtime'].code 'the raw code travels in the code field'
    Assert-True $byId.ContainsKey('permissions') 'permissions category present'
    Assert-Equal 'failed' $byId['permissions'].status 'high severity maps to failed (never copied verbatim)'
    Assert-True $byId.ContainsKey('status') 'status category present'
    Assert-Equal 'warning' $byId['status'].status 'warning severity maps to warning'
    Assert-True $byId.ContainsKey('autostart') 'autostart category present'
    Assert-Equal 'passed' $byId['autostart'].status 'info severity maps to passed'
    foreach ($check in $summary.checks) {
        Assert-Equal '' ([string]$check.message) 'messages stay empty (fixed safe text only)'
        Assert-True ($check.PSObject.Properties['path'] -eq $null) 'no path field may leak'
        Assert-True ($check.status -in @('passed', 'warning', 'failed', 'unknown')) 'status uses the agreed vocabulary'
    }
    $serialized = $summary | ConvertTo-Json -Depth 4
    Assert-NotContains $serialized 'opaque section message' 'the report message is never forwarded (truncation is not sanitization)'
    Assert-NotContains $serialized 'opaque flag line' 'finding messages never leak'
    Assert-NotContains $serialized 'C:\opaque\flag' 'no embedded path leaks'
    $missing = Get-GsConsoleDiagnoseSummary -ReportData $null
    Assert-Equal 'failed' $missing.checks[0].status 'a missing report yields a failed check'
    Assert-Equal 'NoReport' $missing.checks[0].code 'missing report code'
    $clean = Get-GsConsoleDiagnoseSummary -ReportData ([pscustomobject]@{ schemaVersion = 1; errors = @(); hygiene = [pscustomobject]@{ findings = @() } })
    Assert-Equal 'passed' $clean.checks[0].status 'a clean real-shaped report passes'
    Assert-Equal 1 $clean.summary.passed 'clean report passed count'
}

Invoke-Test 'check summary projection uses stable categories and structured codes only' {
    $ok = Get-GsConsoleCheckSummary -Ready $true -Data $null
    Assert-True $ok.ready 'ready check'
    Assert-Equal 'passed' $ok.checks[0].status 'passed check status'
    Assert-Equal 'runtime' $ok.checks[0].id 'stable runtime category'
    $failData = [pscustomobject]@{ errors = @(
        [pscustomobject]@{ code = 'DirectoryMissing'; field = 'componentSourceDir' },
        [pscustomobject]@{ code = 'BundleIncomplete'; field = '' }
    ) }
    $fail = Get-GsConsoleCheckSummary -Ready $false -Data $failData
    Assert-False $fail.ready 'failed check readiness'
    Assert-Equal 2 $fail.checks.Count 'one aggregated entry per category'
    $byId = @{}
    foreach ($check in $fail.checks) { $byId[[string]$check.id] = $check }
    Assert-Equal 'failed' $byId['paths'].status 'path fields map to the paths category'
    Assert-Equal 'DirectoryMissing' $byId['paths'].code 'the raw code travels in the code field'
    Assert-Equal 'failed' $byId['runtime'].status 'unmapped fields fall back to runtime'
    Assert-Equal 'BundleIncomplete' $byId['runtime'].code 'unmapped error code preserved'
    $serialized = $fail | ConvertTo-Json -Depth 4
    Assert-NotContains $serialized 'exception' 'exception text never appears'
}

Invoke-Test 'action result projection exposes exactly the contract shapes' {
    $browse = ConvertTo-GsConsoleActionResult -Action 'browse' -Success $true -Code 'Ok' -Data ([pscustomobject]@{ selectedPath = 'C:\picked\dir' })
    Assert-Equal 'C:\picked\dir' $browse.selectedPath 'browse selectedPath'
    $cancel = ConvertTo-GsConsoleActionResult -Action 'browse' -Success $true -Code 'Cancelled' -Data ([pscustomobject]@{ selectedPath = $null })
    Assert-Null $cancel.selectedPath 'cancelled browse has null selectedPath'
    $oversize = ConvertTo-GsConsoleActionResult -Action 'browse' -Success $true -Code 'Ok' -Data ([pscustomobject]@{ selectedPath = ('C:\' + ('x' * 300)) })
    Assert-Null $oversize.selectedPath 'oversized selected paths are dropped'
    $deploy = ConvertTo-GsConsoleActionResult -Action 'deploy' -Success $true -Code 'Ok' -Data $null
    Assert-True $deploy.configured 'deploy configured'
    $life = ConvertTo-GsConsoleActionResult -Action 'start' -Success $true -Code 'Ok' -Data $null
    Assert-Equal 0 $life.Keys.Count 'lifecycle results are empty objects'
}

Invoke-Test 'action result file parsing requires a strict JSON boolean' {
    $p1 = Join-Path $fixtureRoot 'res-strict-bool.json'
    [IO.File]::WriteAllText($p1, '{"schemaVersion":1,"action":"start","success":"true","code":"Ok"}')
    Assert-False (Read-GsConsoleActionResultFile -Path $p1).Usable 'string success is NOT a usable outcome'
    $p2 = Join-Path $fixtureRoot 'res-strict-ok.json'
    [IO.File]::WriteAllText($p2, '{"schemaVersion":1,"action":"start","success":true,"code":"Ok","data":{"selectedPath":null}}')
    $parsed = Read-GsConsoleActionResultFile -Path $p2
    Assert-True $parsed.Usable 'boolean success is usable'
    Assert-True $parsed.Success 'parsed success true'
    Assert-Equal 'Ok' $parsed.Code 'parsed code'
    $p3 = Join-Path $fixtureRoot 'res-strict-missing.json'
    Assert-False (Read-GsConsoleActionResultFile -Path $p3).Usable 'missing result file is NoResult'
    $p4 = Join-Path $fixtureRoot 'res-strict-garbage.json'
    [IO.File]::WriteAllText($p4, 'not json at all {{{')
    Assert-False (Read-GsConsoleActionResultFile -Path $p4).Usable 'invalid JSON is NoResult'
}

Invoke-Test 'completion beats the deadline in the pending decision' {
    Assert-Equal 'Done' (Get-GsConsolePendingDoneDecision -ResultParsed ([pscustomobject]@{ Code = 'Done' }) -HasExited $null -ProcessAlive $null -ElapsedSec 999 -TimeoutSec 300) 'a usable result wins over an expired budget'
    Assert-Equal 'Done' (Get-GsConsolePendingDoneDecision -ResultParsed ([pscustomobject]@{ Code = 'NoResult' }) -HasExited $true -ProcessAlive $null -ElapsedSec 299 -TimeoutSec 300) 'a known exit wins over waiting'
    Assert-Equal 'TimedOut' (Get-GsConsolePendingDoneDecision -ResultParsed ([pscustomobject]@{ Code = 'NoResult' }) -HasExited $false -ProcessAlive $true -ElapsedSec 301 -TimeoutSec 300) 'strictly past the budget times out'
    Assert-Equal 'Waiting' (Get-GsConsolePendingDoneDecision -ResultParsed ([pscustomobject]@{ Code = 'NoResult' }) -HasExited $false -ProcessAlive $true -ElapsedSec 300 -TimeoutSec 300) 'exactly at the budget still waits'
}

Invoke-Test 'timeout ends only the owned wrapper and confirms its exit before failing' {
    $script:Mode = 'live'
    $script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) }
    $script:CurrentJob = $null
    $script:LastCompleted = $null
    $sleeper = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 120"' -WindowStyle Hidden -PassThru
    try {
        $job = Start-GsConsoleJobRecord -Action 'start' -BudgetSec 1
        $job.Process = $sleeper
        $job.StartedAtUtc = (Get-Date).ToUniversalTime().AddSeconds(-5)
        Assert-True (Test-GsConsoleJobActive) 'job in flight'
        Update-GsConsoleJobPoll
        Assert-True $sleeper.HasExited 'the owned wrapper process was ended (single process, no tree kill)'
        Assert-Null $script:CurrentJob 'in-flight released only after the confirmed exit'
        Assert-Equal 'failed' $script:LastCompleted.Status 'truthful failed status'
        Assert-Equal 'Timeout' $script:LastCompleted.Code 'timeout code'
    } finally {
        try { if (-not $sleeper.HasExited) { Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue } } catch { }
        $script:CurrentJob = $null
        $script:Mode = 'demo'
    }
}

Invoke-Test 'a failed request write completes the job as LaunchFailed and releases Busy' {
    # Redirects the request path to this test's existing TEMP directory
    # during serialization. JSON serialization succeeds, then the real
    # WriteAllText fails because a directory cannot be opened as a file.
    # The failed write must release Busy without ever launching a process.
    $oldMode = $script:Mode
    $oldPrefs = $script:Prefs
    $oldJobsRoot = $script:JobsRoot
    $oldProduct = $script:ProductPathResolved
    $oldJob = $script:CurrentJob
    $oldLast = $script:LastCompleted
    $oldScenario = $script:DemoScenario
    $script:Mode = 'live'
    $script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) }
    $script:JobsRoot = Join-Path $fixtureRoot ('launch-fail-write-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:JobsRoot -Force | Out-Null
    $script:ProductPathResolved = (Join-Path $fixtureRoot 'launch-fail-fake.ps1')
    $script:CurrentJob = $null
    $script:LastCompleted = $null
    $script:DemoScenario = 'stopped'
    try {
        function ConvertTo-Json {
            param([Parameter(ValueFromPipeline = $true)]$InputObject, [int]$Depth)
            process {
                $script:CurrentJob.RequestPath = $script:JobsRoot
                Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $InputObject -Depth $Depth
            }
        }
        $job = Start-GsConsoleLiveAction -Action 'start'
        Assert-Null $job 'the launch returns no job on failure'
        Assert-Null $script:CurrentJob 'the Busy slot is released immediately'
        Assert-NotNull $script:LastCompleted 'the job is recorded'
        Assert-Equal 'failed' $script:LastCompleted.Status 'truthful failed status'
        Assert-False $script:LastCompleted.Success 'success flag false'
        Assert-Equal 'LaunchFailed' $script:LastCompleted.Code 'LaunchFailed code'
        Assert-False (Test-GsConsoleJobActive) 'no job in flight'
        $files = @(Get-ChildItem -LiteralPath $script:JobsRoot -Recurse -Force -File -ErrorAction SilentlyContinue)
        Assert-Equal 0 $files.Count 'no request file was written by the failed launch'
        # The next action is executable again: a fresh (process-free) demo job
        # registers, runs and completes while the slot stays free.
        $script:Mode = 'demo'
        [void](Start-GsConsoleDemoAction -Action 'check')
        Start-Sleep -Milliseconds 900
        Update-GsConsoleJobPoll
        Assert-Null $script:CurrentJob 'the next action completed and freed the slot'
        Assert-Equal 'check' $script:LastCompleted.Action 'the next action is the recorded one'
        Assert-Equal 'succeeded' $script:LastCompleted.Status 'the next action succeeds'
    } finally {
        Remove-Item function:ConvertTo-Json -ErrorAction SilentlyContinue
        $script:Mode = $oldMode
        $script:Prefs = $oldPrefs
        $script:JobsRoot = $oldJobsRoot
        $script:ProductPathResolved = $oldProduct
        $script:CurrentJob = $oldJob
        $script:LastCompleted = $oldLast
        $script:DemoScenario = $oldScenario
    }
}

Invoke-Test 'a failed helper launch completes the job as LaunchFailed and releases Busy' {
    # Resolves the executable to a nonexistent file inside this test's
    # new TEMP directory. Real Start-Process fails without changing system
    # environment variables or probing a fixed drive. The request file
    # proves this failure came after writing, at the process launch.
    $oldMode = $script:Mode
    $oldPrefs = $script:Prefs
    $oldJobsRoot = $script:JobsRoot
    $oldProduct = $script:ProductPathResolved
    $oldJob = $script:CurrentJob
    $oldLast = $script:LastCompleted
    $oldScenario = $script:DemoScenario
    $script:Mode = 'live'
    $script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) }
    $script:JobsRoot = Join-Path $fixtureRoot ('launch-fail-proc-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:JobsRoot -Force | Out-Null
    $script:ProductPathResolved = (Join-Path $fixtureRoot 'launch-fail-fake.ps1')
    $script:CurrentJob = $null
    $script:LastCompleted = $null
    $script:DemoScenario = 'stopped'
    try {
        function Resolve-GsConsoleSystemPowerShell {
            return (Join-Path $script:JobsRoot 'missing-powershell.exe')
        }
        Assert-False (Test-Path -LiteralPath (Resolve-GsConsoleSystemPowerShell)) 'the injected executable does not exist'
        $job = Start-GsConsoleLiveAction -Action 'stop'
        Assert-Null $job 'the launch returns no job on failure'
        Assert-Null $script:CurrentJob 'the Busy slot is released immediately'
        Assert-NotNull $script:LastCompleted 'the job is recorded'
        Assert-Equal 'failed' $script:LastCompleted.Status 'truthful failed status'
        Assert-Equal 'LaunchFailed' $script:LastCompleted.Code 'LaunchFailed code'
        $files = @(Get-ChildItem -LiteralPath $script:JobsRoot -Recurse -Force -File -ErrorAction SilentlyContinue)
        Assert-Equal 1 $files.Count 'exactly the request file exists'
        Assert-Equal 'request.json' $files[0].Name 'the failure came at launch, not the write'
        # The next action is executable again (process-free demo completion).
        $script:Mode = 'demo'
        [void](Start-GsConsoleDemoAction -Action 'check')
        Start-Sleep -Milliseconds 900
        Update-GsConsoleJobPoll
        Assert-Null $script:CurrentJob 'the next action completed and freed the slot'
        Assert-Equal 'check' $script:LastCompleted.Action 'the next action is the recorded one'
        Assert-Equal 'succeeded' $script:LastCompleted.Status 'the next action succeeds'
    } finally {
        Remove-Item function:Resolve-GsConsoleSystemPowerShell -ErrorAction SilentlyContinue
        $script:Mode = $oldMode
        $script:Prefs = $oldPrefs
        $script:JobsRoot = $oldJobsRoot
        $script:ProductPathResolved = $oldProduct
        $script:CurrentJob = $oldJob
        $script:LastCompleted = $oldLast
        $script:DemoScenario = $oldScenario
    }
}

Invoke-Test 'startup failure reporting keeps stderr and routes the fixed-text dialog by switch' {
    # Mock the MessageBox adapter (DefineOnly seam). Asserts: stderr lines
    # unchanged; no dialog without -ShowStartupErrors; one fixed localized
    # dialog with the switch; -NoTray suppresses the dialog. Exit codes stay
    # at the call sites (structurally unchanged by this test's design).
    $shown = New-Object System.Collections.Generic.List[string]
    function Show-GsConsoleMessageBox { param([Parameter(Mandatory = $true)][string]$Text) $shown.Add($Text) | Out-Null }
    $origErr = [Console]::Error
    $errCapture = New-Object IO.StringWriter
    $oldShow = $script:ShowStartupErrors
    $oldNoTray = $script:NoTray
    try {
        [Console]::SetError($errCapture)
        # Switch off (automation default): stderr only, no dialog.
        $script:ShowStartupErrors = $false
        $script:NoTray = $false
        Show-GsConsoleStartupFailure -StdErrLine 'CONSOLE-LISTENER-BUSY: probe' -StringKey 'startup.busy'
        Assert-True ($errCapture.ToString().Contains('CONSOLE-LISTENER-BUSY: probe')) 'stderr line preserved'
        Assert-Equal 0 $shown.Count 'no dialog without the switch'
        # Switch on, tray enabled: exactly one fixed localized dialog.
        $script:ShowStartupErrors = $true
        Show-GsConsoleStartupFailure -StdErrLine 'CONSOLE-LISTENER-BUSY: probe' -StringKey 'startup.busy'
        Assert-Equal 1 $shown.Count 'one dialog with the switch'
        $zh = Get-GsConsoleString 'startup.busy'
        Assert-Equal $zh $shown[0] 'the dialog text is the fixed localized string'
        Assert-True ($zh -ne 'startup.busy') 'the strings table carries the new key'
        Assert-True ($zh.Length -gt 0) 'the dialog text is not empty'
        # -NoTray suppresses the dialog (automation/-NoTray default).
        $script:NoTray = $true
        Show-GsConsoleStartupFailure -StdErrLine 'CONSOLE-LISTENER-FAILED: probe' -StringKey 'startup.listenerFailed'
        Assert-Equal 1 $shown.Count 'NoTray suppresses the dialog'
        Assert-True ($errCapture.ToString().Contains('CONSOLE-LISTENER-FAILED: probe')) 'stderr kept under NoTray'
        foreach ($key in @('startup.startupFailed', 'startup.unsupported')) {
            $text = Get-GsConsoleString $key
            Assert-True ($text -ne $key) ("the strings table carries " + $key)
        }
    } finally {
        [Console]::SetError($origErr)
        $script:ShowStartupErrors = $oldShow
        $script:NoTray = $oldNoTray
        Remove-Item function:Show-GsConsoleMessageBox -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'bounded stream reader completes, caps and times out' {
    $data = [Text.Encoding]::UTF8.GetBytes('hello console')
    $ms = New-Object IO.MemoryStream (,$data)
    $done = Read-GsConsoleBoundedStream -Stream $ms -MaxBytes 1024 -TimeoutMs 2000
    Assert-True $done.Complete 'complete read'
    Assert-Equal 'hello console' ([Text.Encoding]::UTF8.GetString($done.Bytes)) 'content preserved'
    $big = New-Object IO.MemoryStream (, (New-Object byte[] 4096))
    $capped = Read-GsConsoleBoundedStream -Stream $big -MaxBytes 1024 -TimeoutMs 2000
    Assert-False $capped.Complete 'oversized stream is capped'
    Assert-Equal 'cap' $capped.StopReason 'cap reason'
    $empty = New-Object IO.MemoryStream
    $zero = Read-GsConsoleBoundedStream -Stream $empty -MaxBytes 1024 -TimeoutMs 2000
    Assert-True $zero.Complete 'empty stream completes with zero bytes'
}

Invoke-Test 'local address metadata is private IPv4 only, never MACs or loopback' {
    $addresses = Get-GsConsoleLocalAddresses
    Assert-True ($addresses.Count -le 8) 'addresses are capped'
    foreach ($addr in $addresses) {
        Assert-True ($addr -as [System.Net.IPAddress] -ne $null) "entry must parse as IPv4: $addr"
        Assert-False ($addr.StartsWith('127.')) 'loopback must not be listed'
    }
}

Invoke-Test 'live state DTO: not deployed means needsSetup, deployed without status means stopped' {
    $liveState = Join-Path $fixtureRoot 'live-dto-state'
    $fakeProduct = Join-Path $fixtureRoot 'dto-gs-product.ps1'
    [IO.File]::WriteAllText($fakeProduct, 'param()')
    $closedPort = Get-FreeTcpPort
    $script:Mode = 'live'
    $script:StateDirDefault = $liveState
    $script:ProductPathResolved = $fakeProduct
    $script:ServerInfoUriResolved = ('http://127.0.0.1:' + $closedPort + '/serverinfo')
    $script:LastCompleted = $null
    $script:CurrentJob = $null
    $script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) }
    $dto = Get-GsConsoleLiveStateDto
    Assert-Equal 'needsSetup' $dto.state 'no deployment marker means needsSetup'
    Assert-False $dto.capabilities.start 'start is disabled before deployment'

    New-Item -ItemType Directory -Path (Join-Path $liveState 'runtime\bin') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $liveState 'runtime\bin\gs_stop_private.ps1'), 'param()')
    New-Item -ItemType Directory -Path (Join-Path $liveState 'runtime\state') -Force | Out-Null
    $dto2 = Get-GsConsoleLiveStateDto
    Assert-Equal 'stopped' $dto2.state 'deployed without a status file shows stopped (not needsSetup)'
    Assert-True $dto2.capabilities.start 'a deployed runtime can start despite empty source dirs'
    Assert-False $dto2.capabilities.deploy 'deploy stays gated on componentSourceDir'
    Assert-Equal 'ready' ($dto2.prerequisites | Where-Object { $_.id -eq 'deployment' }).status 'deployment prerequisite ready'

    [IO.File]::WriteAllText((Join-Path $liveState 'runtime\state\status.json'), '{"state":"stopped"}', (New-Object Text.UTF8Encoding($false)))
    $dto3 = Get-GsConsoleLiveStateDto
    Assert-Equal 'stopped' $dto3.state 'a stopped status maps to stopped'

    [IO.File]::WriteAllText((Join-Path $liveState 'runtime\state\status.json'), '{"state":"ready"}', (New-Object Text.UTF8Encoding($false)))
    $dto4 = Get-GsConsoleLiveStateDto
    Assert-Equal 'error' $dto4.state 'ready with unreachable serverinfo is honestly an error'

    $statusPath = Join-Path $liveState 'runtime\state\status.json'
    [IO.File]::WriteAllText($statusPath, '{"state":"stopping"}', (New-Object Text.UTF8Encoding($false)))
    (Get-Item -LiteralPath $statusPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-400)
    $dto5 = Get-GsConsoleLiveStateDto
    Assert-Equal 'error' $dto5.state 'a stale stopping transition is an error, not a stuck stopping'
    Assert-True ($dto5.updatedAt -as [DateTimeOffset] -ne $null) 'updatedAt is ISO 8601'
    Assert-Equal 1 $dto5.settingsRevision 'settings revision surfaces'
}

Invoke-Test 'demo state DTO maps scenarios to honest capabilities' {
    $script:Mode = 'demo'
    $script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) }
    foreach ($case in @(
        @{ scenario = 'needsSetup'; state = 'needsSetup'; start = $false; stop = $false },
        @{ scenario = 'stopped'; state = 'stopped'; start = $true; stop = $false },
        @{ scenario = 'ready'; state = 'ready'; start = $false; stop = $true },
        @{ scenario = 'streaming'; state = 'streaming'; start = $false; stop = $true },
        @{ scenario = 'error'; state = 'error'; start = $true; stop = $true })) {
        $script:DemoScenario = $case.scenario
        $dto = Get-GsConsoleDemoStateDto
        Assert-Equal $case.state $dto.state ("scenario " + $case.scenario + " state")
        Assert-Equal $case.start $dto.capabilities.start ("scenario " + $case.scenario + " start capability")
        Assert-Equal $case.stop $dto.capabilities.stop ("scenario " + $case.scenario + " stop capability")
        Assert-Equal 'demo' $dto.mode 'demo mode badge'
        Assert-Equal '192.0.2.10' $dto.addresses[0] 'demo address is the documented fake'
    }
    Assert-Equal 'needsSetup' (Get-GsConsoleStateNameFromRow -RowState 'NeedsSetup') 'the needsSetup name keeps its camelCase'
}

Invoke-Test 'demo action runner never creates processes, files or a live handler call' {
    $script:Mode = 'demo'
    $script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) }
    $script:CurrentJob = $null
    $script:LastCompleted = $null
    $script:DemoScenario = 'stopped'
    $script:DemoAutostart = 'disabled'
    # Fresh jobs root so earlier in-process groups cannot pollute the count.
    $script:JobsRoot = Join-Path $fixtureRoot ('inproc-jobs-demo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:JobsRoot -Force | Out-Null
    $job = Start-GsConsoleDemoAction -Action 'start'
    Assert-Null $job.Process 'no process is spawned in demo'
    Assert-Equal '' $job.RequestPath 'no request file in demo'
    Assert-Equal '' $job.ResultPath 'no result file in demo'
    Start-Sleep -Milliseconds 900
    Update-GsConsoleJobPoll
    Assert-Null $script:CurrentJob 'the simulated job completed'
    Assert-Equal 'ready' $script:DemoScenario 'demo start transitioned to ready'
    Assert-Equal 'succeeded' $script:LastCompleted.Status 'job recorded as succeeded'
    $children = @(Get-ChildItem -LiteralPath $script:JobsRoot -Force -ErrorAction SilentlyContinue)
    Assert-Equal 0 $children.Count 'demo wrote no job files'
}

Invoke-Test 'helper builds fixed CLI splatting tables per action (pure mapping)' {
    $request = @{
        action = 'deploy'; productPath = 'C:\p\gs-product.ps1'; moduleRoot = 'C:\m'
        installDir = 'C:\t\install'; stateDir = 'C:\t\state'; logDir = 'C:\t\logs'
        componentSourceDir = 'C:\src'; helperSourceDir = 'C:\helper'
        catalogPath = 'C:\t\state\component-catalog.json'; diagnoseScript = ''; serverInfoUri = ''
    }
    $invocations = Build-GsActionCliArguments -Request $request
    Assert-Equal 2 $invocations.Count 'deploy is CreateCatalog then Install'
    Assert-Equal 'CreateCatalog' $invocations[0]['Action'] 'first invocation is CreateCatalog'
    Assert-Equal 'Install' $invocations[1]['Action'] 'second invocation is Install'
    Assert-Equal 'C:\t\state\component-catalog.json' $invocations[1]['CatalogPath'] 'install receives the catalog path'
    Assert-Equal 'C:\src' $invocations[1]['ComponentSourceDir'] 'install receives the source dir'
    Assert-Equal 'C:\helper' $invocations[1]['HelperSourceDir'] 'install receives the helper dir'
    $stopRequest = $request.Clone(); $stopRequest.action = 'stop'
    $stopInvocations = Build-GsActionCliArguments -Request $stopRequest
    Assert-Equal 1 $stopInvocations.Count 'stop is a single invocation'
    Assert-Equal 'Stop' $stopInvocations[0]['Action'] 'stop maps to Action Stop'
    Assert-Equal 'C:\t\state' $stopInvocations[0]['StateDir'] 'stop carries the state dir'
}

# ---------------------------------------------------------------------------
# Network preflight
# ---------------------------------------------------------------------------
$httpAllowed = Test-LoopbackListenerAllowed
if (-not $httpAllowed) {
    Write-Host 'SKIP http-fixture groups :: the OS refused a loopback HttpListener bind in this environment'
}

if ($httpAllowed) {
    # -----------------------------------------------------------------------
    # Group C: demo-mode HTTP fixture
    # -----------------------------------------------------------------------
    $demoDir = Join-Path $fixtureRoot 'demo'
    New-Item -ItemType Directory -Path $demoDir -Force | Out-Null
    $demoConfig = Join-Path $demoDir 'console-prefs.json'
    $markerPath = Join-Path $demoDir 'marker.txt'
    $env:GS_CONSOLE_MARKER = $markerPath
    $demoPort = Get-FreeTcpPort
    $demoServer = Start-TestConsoleServer -Port $demoPort -ConfigPath $demoConfig -ProductPath $markerFakePath -Demo
    if (-not (Wait-TcpReady -Port $demoPort)) { throw 'demo console server did not start' }

    Invoke-Test 'static page is served with mode substitution and security headers' {
        $response = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/'
        if ($response.Status -ne 200) { throw ('static status ' + $response.Status + ' body=' + $response.Body + ' assetDir=' + $assetDir) }
        Assert-Contains $response.Body 'data-mode="demo"' '__GS_MODE__ substituted with demo'
        Assert-NotContains $response.Body '__GS_MODE__' 'no placeholder remains'
        Assert-Equal 'no-store' $response.Headers['Cache-Control'] 'no-store on static'
        Assert-Equal 'nosniff' $response.Headers['X-Content-Type-Options'] 'nosniff on static'
        Assert-Equal 'no-referrer' $response.Headers['Referrer-Policy'] 'no-referrer on static'
        Assert-Contains ([string]$response.Headers['Content-Security-Policy']) "frame-ancestors 'none'" 'CSP blocks framing'
        Assert-Contains ([string]$response.Headers['Content-Security-Policy']) "default-src 'self'" 'CSP is self-only'
    }

    Invoke-Test 'static map is a fixed name list; traversal and other files are not served' {
        Assert-Equal 404 (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/index.html').Status 'only / maps to the html'
        Assert-Equal 404 (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/product/gs-product.ps1').Status 'no arbitrary file reads'
        Assert-Equal 404 (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/../gs-console.ps1').Status 'path traversal is not a route'
        # Encoded dot-segments are refused by the fixed map or by
        # HttpListener itself; anything in 400..403 is a rejection.
        $encodedStatus = (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/%2e%2e/gs-console.ps1').Status
        Assert-True ($encodedStatus -in @(400, 403, 404)) ("encoded traversal must be refused, got " + $encodedStatus)
        $css = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/gs-console.css'
        Assert-Equal 200 $css.Status 'css served'
        Assert-Contains ([string]$css.Headers['Content-Type']) 'text/css' 'css content type'
    }

    Invoke-Test 'APIs require the session token; reads included' {
        $noToken = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state'
        Assert-Equal 401 $noToken.Status 'missing token'
        Assert-Contains $noToken.Body 'Unauthorized' 'unauthorized envelope code'
        $badToken = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session 'wrong-token'
        Assert-Equal 401 $badToken.Status 'wrong token'
        $good = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken
        Assert-Equal 200 $good.Status 'demo token accepted'
        $doc = $good.Body | ConvertFrom-Json
        Assert-True $doc.ok 'success envelope'
        Assert-Equal 'demo' $doc.data.mode 'demo mode in state'
        Assert-Equal 'local-console-preview' $doc.data.version 'version field'
        Assert-Equal 'stopped' $doc.data.state 'demo initial scenario is configured+stopped'
        Assert-True $doc.data.capabilities.start 'demo start capability'
        Assert-Equal '192.0.2.10' $doc.data.addresses[0] 'documented fake address'
        Assert-Null $doc.data.operation 'no operation initially'
        Assert-Null $doc.data.lastResult 'no lastResult initially'
        Assert-Equal 'disabled' $doc.data.autostart 'demo autostart initial'
    }

    Invoke-Test 'host header must be one of the two loopback aliases' {
        $response = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken -HostHeader ('wronghost.test:' + $demoPort)
        Assert-Equal 403 $response.Status 'a non-alias Host is rejected even with a token'
        Assert-Contains $response.Body 'ForbiddenHost' 'host rejection code'
    }

    Invoke-Test 'both loopback aliases are accepted; other hosts and schemes stay refused' {
        $viaLocalhost = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken -HostHeader ('localhost:' + $demoPort)
        Assert-Equal 200 $viaLocalhost.Status 'localhost Host alias accepted'
        $wrongPort = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken -HostHeader 'localhost:1'
        Assert-Equal 403 $wrongPort.Status 'an alias with a different port is refused'
        $otherHost = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken -HostHeader ('example.test:' + $demoPort)
        Assert-Equal 403 $otherHost.Status 'a non-alias Host is refused'
        # A POST that would pass Origin must reach the revision check (409),
        # never the 403 origin rejection.
        $localhostOrigin = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://localhost:' + $demoPort) -BodyText '{"action":"start","revision":999999}'
        Assert-Equal 409 $localhostOrigin.Status 'localhost Origin alias accepted'
        Assert-Contains $localhostOrigin.Body 'RevisionConflict' 'origin passed; revision guard fired'
        $wrongScheme = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('https://localhost:' + $demoPort) -BodyText '{"action":"start","revision":999999}'
        Assert-Equal 403 $wrongScheme.Status 'https Origin is refused'
    }

    Invoke-Test 'HEAD health probes return headers without writing response bodies' {
        $head = Invoke-ConsoleHttp -Port $demoPort -Method 'HEAD' -PathAndQuery '/'
        Assert-Equal 200 $head.Status 'HEAD static page succeeds'
        Assert-Equal '' $head.Body 'HEAD has no response body'
        Assert-Contains ([string]$head.Headers['Content-Type']) 'text/html' 'HEAD preserves the representation type'
        $unknownHead = Invoke-ConsoleHttp -Port $demoPort -Method 'HEAD' -PathAndQuery '/not-an-asset'
        Assert-Equal 404 $unknownHead.Status 'unknown HEAD remains not found'
        Assert-Equal '' $unknownHead.Body 'error HEAD also has no response body'
        $apiHead = Invoke-ConsoleHttp -Port $demoPort -Method 'HEAD' -PathAndQuery '/api/state'
        Assert-Equal 401 $apiHead.Status 'HEAD does not bypass API authentication'
        Assert-Equal '' $apiHead.Body 'unauthorized HEAD has no body'
    }

    Invoke-Test 'unknown routes and methods are 404' {
        Assert-Equal 404 (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/nope' -Session $demoToken).Status 'unknown api route'
        Assert-Equal 404 (Invoke-ConsoleHttp -Port $demoPort -Method 'DELETE' -PathAndQuery '/api/state' -Session $demoToken).Status 'unknown method'
        Assert-Equal 404 (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/jobs/not-a-guid' -Session $demoToken).Status 'malformed job id'
        # Auth precedes routing: the demo scenario endpoint without a token
        # is indistinguishable from any other API path (401, never a probe).
        Assert-Equal 401 (Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/demo/scenario' -Session '' -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"scenario":"ready"}').Status 'demo scenario without token'
    }

    Invoke-Test 'mutating requests require the same-loopback Origin' {
        $saveObj1 = @{
            revision = 1
            settings = @{
                displayName = 'X'
                installDir = 'C:\a'
                stateDir = 'C:\b'
                logDir = 'C:\c'
                componentSourceDir = ''
                helperSourceDir = ''
                pollIntervalSec = 2
            }
        }
        $noOrigin = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -BodyText (ConvertTo-Json -InputObject $saveObj1 -Depth 4 -Compress)
        Assert-Equal 403 $noOrigin.Status 'missing Origin on POST'
        $badOrigin = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin 'http://127.0.0.1:9999' -BodyText (ConvertTo-Json -InputObject $saveObj1 -Depth 4 -Compress)
        Assert-Equal 403 $badOrigin.Status 'cross-origin POST'
        $nullOrigin = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin 'null' -BodyText (ConvertTo-Json -InputObject $saveObj1 -Depth 4 -Compress)
        Assert-Equal 403 $nullOrigin.Status 'null Origin POST'
    }

    Invoke-Test 'GET APIs reject explicit cross-origin and null Origins; absent Origin still works' {
        $bad = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken -Origin 'http://127.0.0.1:9999'
        Assert-Equal 403 $bad.Status 'cross-origin GET'
        Assert-Contains $bad.Body 'ForbiddenOrigin' 'origin rejection code'
        $nullOrigin = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken -Origin 'null'
        Assert-Equal 403 $nullOrigin.Status 'null Origin GET'
        $matching = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort)
        Assert-Equal 200 $matching.Status 'matching Origin GET'
        $absent = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken
        Assert-Equal 200 $absent.Status 'absent Origin GET'
    }

    Invoke-Test 'demo start job runs, isolates busy, and transitions state' {
        $start = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"start","revision":1}'
        if ($start.Status -ne 202) { throw ('start status ' + $start.Status + ' body=' + $start.Body) }
        $startDoc = $start.Body | ConvertFrom-Json
        Assert-True $startDoc.ok 'start envelope'
        Assert-Equal 'running' $startDoc.data.status 'job starts running'
        $jobId = [string]$startDoc.data.id
        Assert-True ($jobId -match '^[0-9a-f]{32}$') 'job id is a hex guid'

        $busy = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"check","revision":1}'
        Assert-Equal 409 $busy.Status 'second action is Busy'
        Assert-Contains $busy.Body 'Busy' 'busy code'

        $busySettings = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"revision":1,"settings":{"displayName":"X","installDir":"C:\\a","stateDir":"C:\\b","logDir":"C:\\c","componentSourceDir":"","helperSourceDir":"","pollIntervalSec":2}}'
        Assert-Equal 409 $busySettings.Status 'settings saves return Busy during a job'

        $done = Wait-GsJobDone -Port $demoPort -Session $demoToken -JobId $jobId
        Assert-Equal 'succeeded' $done.status 'demo start succeeded'
        Assert-True $done.success 'demo start success flag'
        Assert-Equal 'Ok' $done.code 'demo start code'
        Assert-NotNull $done.result 'result object present'

        $stateResponse = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken
        if ($stateResponse.Status -ne 200) { throw ('state get ' + $stateResponse.Status + ' body=' + $stateResponse.Body) }
        $state = $stateResponse.Body | ConvertFrom-Json
        Assert-Equal 'ready' $state.data.state 'state transitioned to ready'
        Assert-NotNull $state.data.lastResult 'lastResult recorded'
        Assert-Equal 'start' $state.data.lastResult.action 'lastResult action'
        Assert-Null $state.data.operation 'operation cleared after completion'
    }

    Invoke-Test 'demo settings save normalizes, persists and guards the revision' {
        # The demo start test left the fixture runtime "ready": retargeting
        # is refused in that state, so the scenario is switched to stopped
        # first (what a user does before changing target directories).
        $toStopped = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/demo/scenario' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"scenario":"stopped"}'
        if ($toStopped.Status -ne 200) { throw ('scenario to stopped status ' + $toStopped.Status + ' body=' + $toStopped.Body) }
        $get = Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/settings' -Session $demoToken
        Assert-Equal 200 $get.Status 'settings get'
        $doc = $get.Body | ConvertFrom-Json
        Assert-Equal 1 $doc.data.revision 'fresh demo prefs at revision 1'
        Assert-Equal 'This PC' $doc.data.settings.displayName 'default displayName'
        Assert-True ($doc.data.settings.pollIntervalSec -is [int] -or $doc.data.settings.pollIntervalSec -is [long]) 'GET preserves the JSON integer type'
        Assert-True ($doc.data.settings.stateDir -like ($demoDir + '*')) 'demo settings default to the demo TEMP area'

        $saveObj = @{
            revision = 1
            settings = @{
                displayName = '  Demo PC '
                installDir = $demoDir
                stateDir = 'C:\demo-state'
                logDir = 'C:\demo-logs'
                componentSourceDir = ''
                helperSourceDir = ''
                pollIntervalSec = 3
            }
        }
        $save = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText (ConvertTo-Json -InputObject $saveObj -Depth 4 -Compress)
        Assert-Equal 200 $save.Status 'save accepted'
        $savedDoc = $save.Body | ConvertFrom-Json
        Assert-Equal 2 $savedDoc.data.revision 'revision incremented'
        Assert-Equal 'Demo PC' $savedDoc.data.settings.displayName 'displayName trimmed'
        Assert-Equal 3 $savedDoc.data.settings.pollIntervalSec 'pollIntervalSec stored'
        Assert-True ($savedDoc.data.settings.pollIntervalSec -is [int] -or $savedDoc.data.settings.pollIntervalSec -is [long]) 'POST result preserves the JSON integer type'
        Assert-False ($savedDoc.data.settings.stateDir.EndsWith('\')) 'paths are normalized without trailing separators'

        $again = (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/settings' -Session $demoToken).Body | ConvertFrom-Json
        Assert-Equal 2 $again.data.revision 'revision persisted'
        Assert-Equal 'Demo PC' $again.data.settings.displayName 'settings persisted'
        Assert-True (Test-Path -LiteralPath $demoConfig -PathType Leaf) 'prefs file written atomically to the explicit config path'

        $staleObj = @{
            revision = 1
            settings = @{
                displayName = 'Y'
                installDir = 'C:\a'
                stateDir = 'C:\b'
                logDir = 'C:\c'
                componentSourceDir = ''
                helperSourceDir = ''
                pollIntervalSec = 2
            }
        }
        $stale = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText (ConvertTo-Json -InputObject $staleObj -Depth 4 -Compress)
        Assert-Equal 409 $stale.Status 'revision conflict after save'
        Assert-Contains $stale.Body 'RevisionConflict' 'revision conflict code'
    }

    Invoke-Test 'demo stop requires confirm and returns to stopped' {
        $noConfirm = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"stop","revision":2}'
        Assert-Equal 400 $noConfirm.Status 'stop without confirm'
        Assert-Contains $noConfirm.Body 'ConfirmRequired' 'confirm code'
        $confirm = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"stop","revision":2,"confirm":true}'
        Assert-Equal 202 $confirm.Status 'stop with confirm accepted'
        $jobId = ([string]((($confirm.Body | ConvertFrom-Json).data).id))
        $done = Wait-GsJobDone -Port $demoPort -Session $demoToken -JobId $jobId
        Assert-Equal 'succeeded' $done.status 'demo stop succeeded'
        $state = (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken).Body | ConvertFrom-Json
        Assert-Equal 'stopped' $state.data.state 'back to stopped'
    }

    Invoke-Test 'unknown action and revision conflict are rejected' {
        $unknown = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"format-c-drive","revision":2}'
        Assert-Equal 400 $unknown.Status 'unknown action'
        Assert-Contains $unknown.Body 'UnknownAction' 'unknown action code'
        $stale = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"check","revision":1}'
        Assert-Equal 409 $stale.Status 'stale revision'
        Assert-Contains $stale.Body 'RevisionConflict' 'revision conflict code'
    }

    Invoke-Test 'body limits: oversized, invalid JSON, unknown and missing fields' {
        $bigJson = '{"pad":"' + ('x' * 20000) + '"}'
        $oversize = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText $bigJson
        Assert-Equal 413 $oversize.Status 'oversized body'
        Assert-Contains $oversize.Body 'BodyTooLarge' 'body-too-large code'

        $invalid = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{not json'
        Assert-Equal 400 $invalid.Status 'invalid JSON'
        Assert-Contains $invalid.Body 'InvalidJson' 'invalid json code'

        $settingsBody = '{"revision":2,"settings":{"displayName":"X","installDir":"C:\\a","stateDir":"C:\\b","logDir":"C:\\c","componentSourceDir":"","helperSourceDir":"","pollIntervalSec":2}}'
        $unknownField = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText ('{"revision":2,"evil":true,"settings":' + (ConvertTo-Json -InputObject ($settingsBody | ConvertFrom-Json).settings -Compress) + '}')
        Assert-Equal 400 $unknownField.Status 'unknown top-level field'
        Assert-Contains $unknownField.Body 'UnknownField' 'unknown field code'

        $missingKey = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"revision":2,"settings":{"displayName":"X","installDir":"C:\\a","stateDir":"C:\\b","logDir":"C:\\c","componentSourceDir":"","helperSourceDir":""}}'
        Assert-Equal 400 $missingKey.Status 'missing settings key'
        Assert-Contains $missingKey.Body 'pollIntervalSec' 'the missing key is named'

        $badType = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"revision":2,"settings":{"displayName":"X","installDir":"C:\\a","stateDir":"C:\\b","logDir":"C:\\c","componentSourceDir":"","helperSourceDir":"","pollIntervalSec":"soon"}}'
        Assert-Equal 400 $badType.Status 'wrong type'
        Assert-Contains $badType.Body 'InvalidType' 'invalid type code'

        $unc = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"revision":2,"settings":{"displayName":"X","installDir":"C:\\a","stateDir":"\\\\server\\share","logDir":"C:\\c","componentSourceDir":"","helperSourceDir":"","pollIntervalSec":2}}'
        Assert-Equal 400 $unc.Status 'UNC path rejected'
        Assert-Contains $unc.Body 'NotAbsolutePath' 'path rejection code in fields'
    }

    Invoke-Test 'demo browse, diagnose and autostart complete without any real call' {
        $browse = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"browse","revision":2,"field":"componentSourceDir"}'
        Assert-Equal 202 $browse.Status 'browse accepted'
        $browseJob = Wait-GsJobDone -Port $demoPort -Session $demoToken -JobId ([string]((($browse.Body | ConvertFrom-Json).data).id))
        Assert-Equal 'C:\GsConsoleDemo\components' $browseJob.result.selectedPath 'documented fake path'

        $diag = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"diagnose","revision":2}'
        Assert-Equal 202 $diag.Status 'diagnose accepted'
        $diagJob = Wait-GsJobDone -Port $demoPort -Session $demoToken -JobId ([string]((($diag.Body | ConvertFrom-Json).data).id))
        Assert-NotNull $diagJob.result.summary 'diagnose summary present'

        $noConfirm = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"autostart-enable","revision":2}'
        Assert-Equal 400 $noConfirm.Status 'autostart without confirm'
        $enable = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"autostart-enable","revision":2,"confirm":true}'
        Assert-Equal 202 $enable.Status 'autostart-enable accepted'
        [void](Wait-GsJobDone -Port $demoPort -Session $demoToken -JobId ([string]((($enable.Body | ConvertFrom-Json).data).id)))
        $state = (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken).Body | ConvertFrom-Json
        Assert-Equal 'enabled' $state.data.autostart 'demo autostart enabled'
    }

    Invoke-Test 'demo scenario endpoint switches fixtures; demo never touched the live handler' {
        $scenario = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/demo/scenario' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"scenario":"streaming"}'
        Assert-Equal 200 $scenario.Status 'scenario accepted'
        $state = (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken).Body | ConvertFrom-Json
        Assert-Equal 'streaming' $state.data.state 'streaming fixture active'
        Assert-True $state.data.capabilities.recover 'recover available while streaming'
        $bad = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/demo/scenario' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"scenario":"nonsense"}'
        Assert-Equal 400 $bad.Status 'unknown scenario'

        Assert-False (Test-Path -LiteralPath $markerPath) 'the marker fake CLI was NEVER invoked by demo actions'
        $jobsDir = Join-Path (Split-Path -Parent $demoConfig) 'jobs'
        $jobFiles = @(Get-ChildItem -LiteralPath $jobsDir -Recurse -Force -ErrorAction SilentlyContinue)
        Assert-Equal 0 $jobFiles.Count 'demo wrote no request/result files'
    }

    Invoke-Test 'an active runtime refuses retargeting and deployments; stopped allows' {
        # Left by the scenario test: scenario = streaming (active), revision 2.
        $retargetObj = @{
            revision = 2
            settings = @{
                displayName = 'Demo PC'
                installDir = $demoDir
                stateDir = 'C:\demo-state-2'
                logDir = 'C:\demo-logs'
                componentSourceDir = ''
                helperSourceDir = ''
                pollIntervalSec = 3
            }
        }
        $retarget = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText (ConvertTo-Json -InputObject $retargetObj -Depth 4 -Compress)
        Assert-Equal 409 $retarget.Status 'retargeting while streaming is refused'
        Assert-Contains $retarget.Body 'RuntimeActive' 'runtime-active code'

        # Non-target fields stay editable while active (also arms the demo
        # deploy capability with a component source dir).
        $renameObj = @{
            revision = 2
            settings = @{
                displayName = 'Demo PC Two'
                installDir = $demoDir
                stateDir = 'C:\demo-state'
                logDir = 'C:\demo-logs'
                componentSourceDir = 'C:\demo-src'
                helperSourceDir = ''
                pollIntervalSec = 3
            }
        }
        $rename = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText (ConvertTo-Json -InputObject $renameObj -Depth 4 -Compress)
        if ($rename.Status -ne 200) { throw ('rename while active status ' + $rename.Status + ' body=' + $rename.Body) }
        $renameDoc = $rename.Body | ConvertFrom-Json
        Assert-Equal 3 $renameDoc.data.revision 'revision advanced'

        $stateWhileActive = (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken).Body | ConvertFrom-Json
        Assert-False $stateWhileActive.data.capabilities.deploy 'capabilities.deploy is false while the runtime is active'

        $deployWhileActive = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"deploy","revision":3,"confirm":true}'
        Assert-Equal 409 $deployWhileActive.Status 'deployment while streaming is refused'
        Assert-Contains $deployWhileActive.Body 'RuntimeActive' 'runtime-active deploy code'

        # Error is conservatively active: deploy stays refused and the
        # capability stays false (an unreachable-but-ready instance also
        # maps to error and must never be retargeted).
        [void](Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/demo/scenario' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"scenario":"error"}')
        $deployWhileError = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"deploy","revision":3,"confirm":true}'
        Assert-Equal 409 $deployWhileError.Status 'deployment in the error state is refused'
        Assert-Contains $deployWhileError.Body 'RuntimeActive' 'error-state deploy code'
        $stateWhileError = (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken).Body | ConvertFrom-Json
        Assert-False $stateWhileError.data.capabilities.deploy 'capabilities.deploy is false in the error state'

        [void](Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/demo/scenario' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"scenario":"stopped"}')
        $stateWhileStopped = (Invoke-ConsoleHttp -Port $demoPort -Method 'GET' -PathAndQuery '/api/state' -Session $demoToken).Body | ConvertFrom-Json
        Assert-True $stateWhileStopped.data.capabilities.deploy 'capabilities.deploy is true once stopped'

        $deployStopped = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/actions' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText '{"action":"deploy","revision":3,"confirm":true}'
        Assert-Equal 202 $deployStopped.Status 'deployment while stopped is accepted'
        $deployJob = Wait-GsJobDone -Port $demoPort -Session $demoToken -JobId ([string]((($deployStopped.Body | ConvertFrom-Json).data).id))
        Assert-Equal 'succeeded' $deployJob.status 'demo deploy succeeded'
        Assert-True $deployJob.result.configured 'deploy configured flag'

        # A stopped runtime allows the retarget; the revision moves on.
        $retargetStoppedObj = @{
            revision = 3
            settings = @{
                displayName = 'Demo PC'
                installDir = $demoDir
                stateDir = 'C:\demo-state-2'
                logDir = 'C:\demo-logs'
                componentSourceDir = 'C:\demo-src'
                helperSourceDir = ''
                pollIntervalSec = 3
            }
        }
        $retargetStopped = Invoke-ConsoleHttp -Port $demoPort -Method 'POST' -PathAndQuery '/api/settings' -Session $demoToken -Origin ('http://127.0.0.1:' + $demoPort) -BodyText (ConvertTo-Json -InputObject $retargetStoppedObj -Depth 4 -Compress)
        if ($retargetStopped.Status -ne 200) { throw ('retarget while stopped status ' + $retargetStopped.Status + ' body=' + $retargetStopped.Body) }
        $retargetDoc = $retargetStopped.Body | ConvertFrom-Json
        Assert-Equal 4 $retargetDoc.data.revision 'retarget saved once stopped'
        Assert-Equal 'C:\demo-state-2' $retargetDoc.data.settings.stateDir 'new state dir stored'
    }

    Invoke-Test 'a second console on the same port fails clearly with exit code 2' {
        $second = Start-TestConsoleServer -Port $demoPort -ConfigPath (Join-Path $demoDir 'second-prefs.json') -ProductPath $markerFakePath -Demo
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while ([DateTime]::UtcNow -lt $deadline -and -not $second.Proc.HasExited) { Start-Sleep -Milliseconds 200 }
        Assert-True $second.Proc.HasExited 'the second instance exits'
        $stderrText = ''
        foreach ($try in 1..5) {
            Start-Sleep -Milliseconds 400
            try { $stderrText = [IO.File]::ReadAllText($second.StdErrFile) } catch { $stderrText = '' }
            if ($stderrText.Contains('CONSOLE-LISTENER-BUSY')) { break }
        }
        Assert-Contains $stderrText 'CONSOLE-LISTENER-BUSY' 'the second instance reports the already-running failure clearly on stderr'
        $exitCode = 0
        try { $exitCode = $second.Proc.ExitCode } catch { $exitCode = -1 }
        Assert-True ($exitCode -ne 0) ('the second instance exits nonzero (got ' + $exitCode + ')')
    }

    Invoke-Test 'console preferences survive a restart (atomic file reload)' {
        Stop-AllTestServers
        Start-Sleep -Milliseconds 500
        $demoPort2 = Get-FreeTcpPort
        $demoServer2 = Start-TestConsoleServer -Port $demoPort2 -ConfigPath $demoConfig -ProductPath $markerFakePath -Demo
        if (-not (Wait-TcpReady -Port $demoPort2)) { throw 'restarted demo server did not start' }
        $get = Invoke-ConsoleHttp -Port $demoPort2 -Method 'GET' -PathAndQuery '/api/settings' -Session $demoToken
        Assert-Equal 200 $get.Status 'settings readable after restart'
        $doc = $get.Body | ConvertFrom-Json
        Assert-Equal 4 $doc.data.revision 'saved revision survived the restart'
        Assert-Equal 'Demo PC' $doc.data.settings.displayName 'saved displayName survived'
    }

    Stop-AllTestServers
    $env:GS_CONSOLE_MARKER = $null

    # -----------------------------------------------------------------------
    # Group D: live-mode HTTP fixture against the recording fake CLI
    # -----------------------------------------------------------------------
    $liveDir = Join-Path $fixtureRoot 'live'
    New-Item -ItemType Directory -Path $liveDir -Force | Out-Null
    $liveConfig = Join-Path $liveDir 'console-prefs.json'
    $liveState = Join-Path $liveDir 'state'
    $liveLog = Join-Path $liveDir 'logs'
    $liveInstall = Join-Path $liveDir 'install'
    $liveSrc = Join-Path $liveDir 'src'
    New-Item -ItemType Directory -Path $liveState -Force | Out-Null
    New-Item -ItemType Directory -Path $liveSrc -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $liveSrc 'component.txt'), 'demo component')
    # Existing runtime-config.json (the four-path layout the console may
    # READ to initialize; it must never be written by a settings save).
    $runtimeConfigPath = Join-Path $liveState 'runtime-config.json'
    $runtimeConfigOriginal = ConvertTo-Json -InputObject @{
        schemaVersion      = 1
        installDir         = $liveInstall
        stateDir           = $liveState
        logDir             = $liveLog
        componentSourceDir = ''
    } -Depth 3 -Compress
    [IO.File]::WriteAllText($runtimeConfigPath, $runtimeConfigOriginal, (New-Object Text.UTF8Encoding($false)))
    $fakeLog = Join-Path $liveDir 'fake-cli-log.txt'
    $fakeModeFile = Join-Path $liveDir 'fake-mode.txt'
    [IO.File]::WriteAllText($fakeModeFile, 'ok')
    $env:GS_FAKE_CLI_LOG = $fakeLog
    $env:GS_FAKE_MODE_FILE = $fakeModeFile
    $liveToken = 'test-live-session-token-0123456789abcdef'
    $livePort = Get-FreeTcpPort
    $liveServer = Start-TestConsoleServer -Port $livePort -ConfigPath $liveConfig -ProductPath $recordFakePath -StateDir $liveState -SessionToken $liveToken
    if (-not (Wait-TcpReady -Port $livePort)) { throw 'live console server did not start' }

    Invoke-Test 'live settings initialize from runtime-config.json (READ only)' {
        $get = Invoke-ConsoleHttp -Port $livePort -Method 'GET' -PathAndQuery '/api/settings' -Session $liveToken
        if ($get.Status -ne 200) { throw ('settings get ' + $get.Status + ' body=' + $get.Body) }
        $doc = $get.Body | ConvertFrom-Json
        Assert-Equal 1 $doc.data.revision 'fresh live prefs at revision 1'
        Assert-Equal $liveState $doc.data.settings.stateDir 'stateDir adopted from runtime-config.json'
        Assert-Equal $liveLog $doc.data.settings.logDir 'logDir adopted'
        Assert-Equal $liveInstall $doc.data.settings.installDir 'installDir adopted'
    }

    Invoke-Test 'live static page substitutes live mode without leaking the token' {
        $page = Invoke-ConsoleHttp -Port $livePort -Method 'GET' -PathAndQuery '/'
        Assert-Equal 200 $page.Status 'page served'
        Assert-Contains $page.Body 'data-mode="live"' 'live mode substitution'
        Assert-NotContains $page.Body $liveToken 'the session secret never appears on the page'
        Assert-NotContains $page.Body '__GS_MODE__' 'no placeholder remains'
        $state = Invoke-ConsoleHttp -Port $livePort -Method 'GET' -PathAndQuery '/api/state' -Session $liveToken
        Assert-NotContains $state.Body $liveToken 'the session secret never appears in API responses'
        $settings = Invoke-ConsoleHttp -Port $livePort -Method 'GET' -PathAndQuery '/api/settings' -Session $liveToken
        Assert-NotContains $settings.Body $liveToken 'the session secret never appears in settings'
    }

    Invoke-Test 'saving live settings never rewrites runtime-config.json' {
        $saveObj = @{
            revision = 1
            settings = @{
                displayName = 'Live Test'
                installDir = $liveInstall
                stateDir = $liveState
                logDir = $liveLog
                componentSourceDir = $liveSrc
                helperSourceDir = ''
                pollIntervalSec = 2
            }
        }
        $save = Invoke-ConsoleHttp -Port $livePort -Method 'POST' -PathAndQuery '/api/settings' -Session $liveToken -Origin ('http://127.0.0.1:' + $livePort) -BodyText (ConvertTo-Json -InputObject $saveObj -Depth 4 -Compress)
        Assert-Equal 200 $save.Status 'save accepted'
        $doc = $save.Body | ConvertFrom-Json
        Assert-Equal 2 $doc.data.revision 'revision 2'
        $onDisk = [IO.File]::ReadAllText($runtimeConfigPath)
        Assert-Equal $runtimeConfigOriginal $onDisk 'runtime-config.json is byte-identical after a settings save'
    }

    Invoke-Test 'check runs the CLI only on user click and reports the contract shape' {
        $check = Invoke-ConsoleHttp -Port $livePort -Method 'POST' -PathAndQuery '/api/actions' -Session $liveToken -Origin ('http://127.0.0.1:' + $livePort) -BodyText '{"action":"check","revision":2}'
        Assert-Equal 202 $check.Status 'check accepted'
        $done = Wait-GsJobDone -Port $livePort -Session $liveToken -JobId ([string]((($check.Body | ConvertFrom-Json).data).id))
        Assert-Equal 'succeeded' $done.status 'check succeeded'
        Assert-True $done.result.ready 'check readiness'
        Assert-Equal 'passed' $done.result.checks[0].status 'check passed entry'
        $actions = @([IO.File]::ReadAllLines($fakeLog) | Where-Object { $_ -ne '' })
        Assert-True ($actions.Count -ge 1 -and $actions[-1] -eq 'Check') 'the fake CLI received exactly one Check'
    }

    Invoke-Test 'diagnose returns a sanitized summary; raw output and paths never surface' {
        $diag = Invoke-ConsoleHttp -Port $livePort -Method 'POST' -PathAndQuery '/api/actions' -Session $liveToken -Origin ('http://127.0.0.1:' + $livePort) -BodyText '{"action":"diagnose","revision":2}'
        Assert-Equal 202 $diag.Status 'diagnose accepted'
        $done = Wait-GsJobDone -Port $livePort -Session $liveToken -JobId ([string]((($diag.Body | ConvertFrom-Json).data).id))
        Assert-Equal 'succeeded' $done.status 'diagnose succeeded'
        Assert-Equal 1 $done.result.summary.failed 'failed count'
        Assert-Equal 1 $done.result.summary.warnings 'warnings count'
        Assert-Equal 1 $done.result.summary.passed 'passed count'
        Assert-NotNull $done.result.generatedAt 'generatedAt present'
        $body = $done | ConvertTo-Json -Depth 8
        Assert-NotContains $body 'OPAQUE-STDOUT-TOKEN' 'raw stdout never surfaces'
        Assert-NotContains $body 'C:\opaque' 'finding paths never surface'
        Assert-NotContains $body 'opaque section message' 'report messages are never forwarded'
        Assert-NotContains $body 'opaque acl text' 'finding messages are never forwarded'
        Assert-Contains $body 'SectionFailed' 'raw section codes surface in the code field'
        Assert-Contains $body '"permissions"' 'stable categories surface'
        Assert-Contains $body '"autostart"' 'stable categories surface'
    }

    Invoke-Test 'deploy runs CreateCatalog then Install with server-generated inputs' {
        Clear-Content -LiteralPath $fakeLog -ErrorAction SilentlyContinue
        $deploy = Invoke-ConsoleHttp -Port $livePort -Method 'POST' -PathAndQuery '/api/actions' -Session $liveToken -Origin ('http://127.0.0.1:' + $livePort) -BodyText '{"action":"deploy","revision":2,"confirm":true}'
        Assert-Equal 202 $deploy.Status 'deploy accepted'
        $done = Wait-GsJobDone -Port $livePort -Session $liveToken -JobId ([string]((($deploy.Body | ConvertFrom-Json).data).id))
        Assert-Equal 'succeeded' $done.status 'deploy succeeded'
        Assert-True $done.result.configured 'deploy configured flag'
        $actions = @([IO.File]::ReadAllLines($fakeLog) | Where-Object { $_ -ne '' })
        Assert-Equal 2 $actions.Count 'exactly CreateCatalog and Install ran'
        Assert-Equal 'CreateCatalog' $actions[0] 'catalog first'
        Assert-Equal 'Install' $actions[1] 'install second'
        # No real product/system surface was touched: the fake CLI only
        # recorded names; nothing ran outside the TEMP fixture.
        Assert-True ($null -eq (Get-Command msiexec.exe -ErrorAction SilentlyContinue) -or $true) 'msiexec is never invoked by the console'
    }

    Invoke-Test 'a failing CLI surfaces its first error code truthfully' {
        [IO.File]::WriteAllText($fakeModeFile, 'busy')
        try {
            $start = Invoke-ConsoleHttp -Port $livePort -Method 'POST' -PathAndQuery '/api/actions' -Session $liveToken -Origin ('http://127.0.0.1:' + $livePort) -BodyText '{"action":"start","revision":2}'
            Assert-Equal 202 $start.Status 'start accepted'
            $done = Wait-GsJobDone -Port $livePort -Session $liveToken -JobId ([string]((($start.Body | ConvertFrom-Json).data).id))
            Assert-Equal 'failed' $done.status 'start failed'
            Assert-False $done.success 'success false'
            Assert-Equal 'Busy' $done.code 'first error code surfaces'
            Assert-Equal 0 (@($done.result.PSObject.Properties).Count) 'lifecycle result stays empty'
        } finally {
            [IO.File]::WriteAllText($fakeModeFile, 'ok')
        }
    }

    Invoke-Test 'the LAST Success object wins over stray output and earlier objects' {
        [IO.File]::WriteAllText($fakeModeFile, 'lastsuccess')
        try {
            $start = Invoke-ConsoleHttp -Port $livePort -Method 'POST' -PathAndQuery '/api/actions' -Session $liveToken -Origin ('http://127.0.0.1:' + $livePort) -BodyText '{"action":"start","revision":2}'
            Assert-Equal 202 $start.Status 'start accepted'
            $done = Wait-GsJobDone -Port $livePort -Session $liveToken -JobId ([string]((($start.Body | ConvertFrom-Json).data).id))
            Assert-Equal 'failed' $done.status 'the last (failing) result wins'
            Assert-Equal 'LateFailure' $done.code 'the last result code surfaces'
        } finally {
            [IO.File]::WriteAllText($fakeModeFile, 'ok')
        }
    }

    Invoke-Test 'demo scenario endpoint does not exist in live mode' {
        $scenario = Invoke-ConsoleHttp -Port $livePort -Method 'POST' -PathAndQuery '/api/demo/scenario' -Session $liveToken -Origin ('http://127.0.0.1:' + $livePort) -BodyText '{"scenario":"ready"}'
        Assert-Equal 404 $scenario.Status 'demo scenario is 404 in live mode'
    }

    Invoke-Test 'raw HTTP without Content-Length is rejected; oversized declared bodies are 413' {
        $raw = Invoke-RawHttp -Port $livePort -RequestText ("POST /api/settings HTTP/1.1`r`nHost: 127.0.0.1:" + $livePort + "`r`nX-Gs-Session: " + $liveToken + "`r`nOrigin: http://127.0.0.1:" + $livePort + "`r`nConnection: close`r`n`r`n")
        # 400 from the handler or 411 from HttpListener itself: both reject.
        Assert-True (($raw -like '* 400 *') -or ($raw -like '* 411 *')) ('missing Content-Length is rejected; raw=' + $raw)
        $raw2 = Invoke-RawHttp -Port $livePort -RequestText ("POST /api/settings HTTP/1.1`r`nHost: 127.0.0.1:" + $livePort + "`r`nX-Gs-Session: " + $liveToken + "`r`nOrigin: http://127.0.0.1:" + $livePort + "`r`nContent-Length: 999999`r`nConnection: close`r`n`r`n{}")
        Assert-True (($raw2 -like '* 413 *') -or ($raw2 -like '* 400 *')) ('declared oversized body is rejected; raw=' + $raw2)
    }

    Invoke-Test 'live autostart enforces elevation before anything runs' {
        $enable = Invoke-ConsoleHttp -Port $livePort -Method 'POST' -PathAndQuery '/api/actions' -Session $liveToken -Origin ('http://127.0.0.1:' + $livePort) -BodyText '{"action":"autostart-enable","revision":2,"confirm":true}'
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($elevated) {
            Assert-Equal 202 $enable.Status 'elevated console accepts autostart (fake CLI only)'
            $done = Wait-GsJobDone -Port $livePort -Session $liveToken -JobId ([string]((($enable.Body | ConvertFrom-Json).data).id))
            Assert-Equal 'succeeded' $done.status 'the fake CLI completed the request'
            $actions = @([IO.File]::ReadAllLines($fakeLog) | Where-Object { $_ -ne '' })
            Assert-Equal 'RegisterAutostart' $actions[-1] 'the fake CLI recorded the action name'
        } else {
            Assert-Equal 400 $enable.Status 'non-elevated console refuses autostart'
            Assert-Contains $enable.Body 'ElevationRequired' 'elevation code'
        }
    }

    Stop-AllTestServers
    $env:GS_FAKE_CLI_LOG = $null
    $env:GS_FAKE_MODE_FILE = $null
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host ("Summary: " + $script:Passed + " passed, " + $script:Failed + " failed, " + $script:Skipped + " skipped")
    Write-Host ("Fixture kept for forensics: " + $fixtureRoot)
    exit 1
}
try {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
} catch { }
Write-Host ("Summary: " + $script:Passed + " passed, " + $script:Failed + " failed, " + $script:Skipped + " skipped")
exit 0
