#Requires -Version 5.1
<#
.SYNOPSIS
  Tests for the Sunshine backend of the local console server (worker A of
  SUNSHINE-BACKEND-CONTRACT.md): the -Backend/install-profile startup
  selection, the read-only probe library (product/gs-sunshine.ps1), the
  isolated Sunshine routing/static map, GET /api/sunshine/status, and the
  whitelisted gs-console.vbs argument.

.DESCRIPTION
  Safety envelope:
  - Everything runs against TEMP fixtures with GUID names. No real
    Sunshine installation is probed, downloaded or run; no real CLI, no
    runtime, no service, no scheduled task, no credential, no registry,
    no device, no system change.
  - Probe outcomes are exercised through the injectable seams
    (-InstallCandidates / -ExistenceProbe / -TcpProbe) and TEMP files; the
    TCP "open" case binds an EPHEMERAL loopback test listener owned by
    this suite. Real TCP 47990 is never contacted.
  - Child console servers are started on ephemeral 127.0.0.1 ports. In
    Sunshine DEMO mode the full status route is exercised; LIVE-mode
    Sunshine children are exercised for startup/static/session behavior
    only - their status route would probe the real machine, so it is
    never called with a valid token. Startup-failure children are
    asserted via stderr and exit code.
  - The legacy ConsoleApiTests suite keeps ownership of the legacy
    behavior; this suite only proves Sunshine isolation and that the
    legacy defaults stay untouched (missing profile = Legacy).
  Exits 0 only when every test passes; exits 1 otherwise.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$consolePath = Join-Path $repoRoot 'product\gs-console.ps1'
$sunshinePath = Join-Path $repoRoot 'product\gs-sunshine.ps1'
$vbsPath = Join-Path $repoRoot 'product\gs-console.vbs'
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

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$MessagePattern = ''
    )
    $thrown = $false
    try { & $Body } catch {
        $thrown = $true
        if (-not [string]::IsNullOrEmpty($MessagePattern)) {
            if ($_.Exception.Message.IndexOf($MessagePattern, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw "Assertion failed: expected an error containing '$MessagePattern' but got '$($_.Exception.Message)'"
            }
        }
    }
    if (-not $thrown) { throw "Assertion failed: expected an exception but none was thrown" }
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

# ---------------------------------------------------------------------------
# TEMP fixtures (GUID-named; nothing real is ever read or written)
# ---------------------------------------------------------------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('gs-sunshine-console-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$assetDir = Join-Path $fixtureRoot 'static'
New-Item -ItemType Directory -Path $assetDir -Force | Out-Null

$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $assetDir 'gs-sunshine.html'), '<html><body data-mode="__GS_MODE__"><p>sunshine fixture page</p></body></html>', $utf8)
[IO.File]::WriteAllText((Join-Path $assetDir 'gs-sunshine.js'), 'document.body.textContent = "sunshine fixture";', $utf8)
[IO.File]::WriteAllText((Join-Path $assetDir 'gs-console.css'), 'body { color: #142C48; }', $utf8)
[IO.File]::WriteAllText((Join-Path $assetDir 'gs-sunshine.css'), '.sunshine { color: #142C48; }', $utf8)

# Fake "installed" Sunshine executable at a TEMP candidate path.
$fakeExePath = Join-Path $fixtureRoot 'fake-sunshine\sunshine.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $fakeExePath) -Force | Out-Null
[IO.File]::WriteAllText($fakeExePath, 'fake executable bytes - never executed', $utf8)

# Marker fake CLI (demo servers receive it; if anything legacy was ever
# invoked, the marker file would appear).
$markerPath = Join-Path $fixtureRoot 'gs-product-invocation-marker.txt'
$fakeCliPath = Join-Path $fixtureRoot 'fake-marker-gs-product.ps1'
[IO.File]::WriteAllText($fakeCliPath, @'
param()
$ErrorActionPreference = 'Stop'
$log = $env:GS_SUNSHINE_MARKER
if (-not [string]::IsNullOrWhiteSpace($log)) { Add-Content -LiteralPath $log -Value 'invoked' }
'@, $utf8)

# Fake GsRuntime module whose import leaves a marker (proves the Sunshine
# startup never imports it, while the legacy contrast run does).
$fakeModuleRoot = Join-Path $fixtureRoot 'fake-modules'
$fakeModuleDir = Join-Path $fakeModuleRoot 'GsRuntime'
New-Item -ItemType Directory -Path $fakeModuleDir -Force | Out-Null
$gsRuntimeImportMarkerPath = Join-Path $fixtureRoot 'gsruntime-import-marker.txt'
$manifestContent = "@{`r`n  ModuleVersion = '1.0.0'`r`n  GUID = 'b7e7d3a0-1111-4c62-9f11-2f65c11e9b0a'`r`n  ScriptsToProcess = @('gs-import-marker.ps1')`r`n}`r`n"
[IO.File]::WriteAllText((Join-Path $fakeModuleDir 'GsRuntime.psd1'), $manifestContent, $utf8)
[IO.File]::WriteAllText((Join-Path $fakeModuleDir 'gs-import-marker.ps1'), ("param()`r`n" + 'Set-Content -LiteralPath "' + $gsRuntimeImportMarkerPath + '" -Value ''imported''' + "`r`n"), $utf8)

# Valid console prefs fixture (revision 7) for the legacy contrast: proves
# the fixture is readable, so the Sunshine run ignoring it is meaningful.
$validPrefsPath = Join-Path $fixtureRoot 'prefs\console-prefs.json'
$prefDirs = @('install-a', 'state-a', 'log-a')
foreach ($dir in $prefDirs) { New-Item -ItemType Directory -Path (Join-Path $fixtureRoot $dir) -Force | Out-Null }
$validPrefsJson = '{' + "`r`n" +
    '  "schemaVersion": 1,' + "`r`n" +
    '  "revision": 7,' + "`r`n" +
    '  "settings": {' + "`r`n" +
    ('    "displayName": "FixturePC",' + "`r`n") +
    ('    "installDir": "' + (Join-Path $fixtureRoot 'install-a').Replace('\', '\\') + '",' + "`r`n") +
    ('    "stateDir": "' + (Join-Path $fixtureRoot 'state-a').Replace('\', '\\') + '",' + "`r`n") +
    ('    "logDir": "' + (Join-Path $fixtureRoot 'log-a').Replace('\', '\\') + '",' + "`r`n") +
    '    "componentSourceDir": "",' + "`r`n" +
    '    "helperSourceDir": "",' + "`r`n" +
    '    "pollIntervalSec": 3' + "`r`n" +
    '  }' + "`r`n" +
    '}'
New-Item -ItemType Directory -Path (Split-Path -Parent $validPrefsPath) -Force | Out-Null
[IO.File]::WriteAllText($validPrefsPath, $validPrefsJson, $utf8)

# Install-profile fixtures.
function Write-InstallProfile {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Content)
    $path = Join-Path $fixtureRoot $Name
    [IO.File]::WriteAllText($path, $Content, $utf8)
    return $path
}
$profileMissingPath = Join-Path $fixtureRoot 'profile-does-not-exist.json'
$profileSunshinePath = Write-InstallProfile 'profile-sunshine.json' ('{' + "`r`n" + '  "schemaVersion": 1,' + "`r`n" + '  "backend": "sunshine"' + "`r`n" + '}')
$profileLegacyPath = Write-InstallProfile 'profile-legacy.json' ('{' + "`r`n" + '  "schemaVersion": 1,' + "`r`n" + '  "backend": "legacy"' + "`r`n" + '}')
$profileBadSchemaPath = Write-InstallProfile 'profile-bad-schema.json' '{"schemaVersion": 2, "backend": "sunshine"}'
$profileBadBackendCasePath = Write-InstallProfile 'profile-bad-backend-case.json' '{"schemaVersion": 1, "backend": "Sunshine"}'
$profileMissingBackendPath = Write-InstallProfile 'profile-missing-backend.json' '{"schemaVersion": 1}'
$profileNumericBackendPath = Write-InstallProfile 'profile-numeric-backend.json' '{"schemaVersion": 1, "backend": 5}'
$profileUnknownFieldPath = Write-InstallProfile 'profile-unknown-field.json' '{"schemaVersion": 1, "backend": "sunshine", "extra": true}'
$profileNotJsonPath = Write-InstallProfile 'profile-not-json.json' 'this is not json {{'
$profileArrayPath = Write-InstallProfile 'profile-array.json' '[1, 2, 3]'
$profileOversizedPath = Write-InstallProfile 'profile-oversized.json' ('x' * 5000)

# ---------------------------------------------------------------------------
# Child server helpers
# ---------------------------------------------------------------------------
$script:Servers = New-Object System.Collections.Generic.List[object]
$script:ServerSeq = 0

function Start-TestConsoleServer {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$ProductPath = '',
        [string]$SessionToken = '',
        [string]$Backend = '',
        [string]$ProfilePath = '',
        [switch]$Demo
    )
    $systemPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $systemPs)) { $systemPs = 'powershell.exe' }
    $argumentList = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "' + $consolePath + '"' +
        ' -Port ' + $Port +
        ' -ConfigPath "' + $ConfigPath + '"' +
        ' -StaticDir "' + $assetDir + '"'
    if ($Demo) { $argumentList += ' -Demo' }
    if ($Backend -ne '') { $argumentList += ' -Backend ' + $Backend }
    if ($ProfilePath -ne '') { $argumentList += ' -ProfilePath "' + $ProfilePath + '"' }
    if ($ProductPath -ne '') { $argumentList += ' -ProductPath "' + $ProductPath + '"' }
    if ($SessionToken -ne '') { $argumentList += ' -SessionToken "' + $SessionToken + '"' }
    $argumentList += ' -NoBrowser -NoTray -ExitAfterSec 240'
    $script:ServerSeq++
    $stderrFile = Join-Path $fixtureRoot ('server-' + $script:ServerSeq + '-' + $Port + '-stderr.txt')
    $proc = Start-Process -FilePath $systemPs -ArgumentList $argumentList -NoNewWindow -PassThru `
        -RedirectStandardError $stderrFile
    # Touch the handle while the child is alive: without this, ExitCode and
    # the redirected stderr bookkeeping are unreliable after the exit.
    $null = $proc.Handle
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

function Wait-ServerExit {
    param([Parameter(Mandatory)]$Record, [int]$TimeoutMs = 30000)
    if (-not $Record.Proc.WaitForExit($TimeoutMs)) {
        throw 'the child server did not exit within the timeout'
    }
    # WaitForExit(Int32) does not guarantee that the exit bookkeeping of a
    # process with redirected streams is complete; finish it explicitly.
    try { $Record.Proc.WaitForExit() } catch { }
    $code = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while ($true) {
        try { $code = $Record.Proc.ExitCode } catch { $code = $null }
        if ($null -ne $code) { break }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 100
    }
    return $code
}

function Read-ServerStderr {
    # Reads the redirected stderr file with a short retry: the writer may
    # still be flushing when the process has already exited.
    param([Parameter(Mandatory)]$Record)
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while ($true) {
        $text = ''
        try {
            if (Test-Path -LiteralPath $Record.StdErrFile) { $text = [IO.File]::ReadAllText($Record.StdErrFile, [Text.Encoding]::Default) }
        } catch { $text = '' }
        if (-not [string]::IsNullOrEmpty($text) -or [DateTime]::UtcNow -ge $deadline) { return ([string]$text) }
        Start-Sleep -Milliseconds 100
    }
}

function Invoke-ConsoleHttp {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$PathAndQuery,
        [string]$Session = '',
        [string]$Origin = '',
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
    if ($Session -ne '') { $req.Headers['X-Gs-Session'] = $Session }
    if ($Origin -ne '') { $req.Headers['Origin'] = $Origin }
    if ($Method -eq 'POST') {
        # A POST without a declared length is rejected with 411 by the HTTP
        # stack before any handler runs; declare an empty body explicitly.
        $req.ContentLength = 0
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

# ---------------------------------------------------------------------------
# In-process fake HTTP context (direct handler/router calls)
# ---------------------------------------------------------------------------
function New-FakeHttpContext {
    param([string]$Method = 'GET')
    $headers = New-Object System.Net.WebHeaderCollection
    $request = New-Object psobject
    $request | Add-Member NoteProperty HttpMethod $Method
    $request | Add-Member NoteProperty Headers $headers
    $response = New-Object psobject
    $response | Add-Member NoteProperty StatusCode 0
    $response | Add-Member NoteProperty ContentType ''
    $response | Add-Member NoteProperty Headers (New-Object System.Net.WebHeaderCollection)
    $response | Add-Member NoteProperty ContentLength64 ([long]0)
    $response | Add-Member NoteProperty OutputStream (New-Object System.IO.MemoryStream)
    $context = New-Object psobject
    $context | Add-Member NoteProperty Request $request
    $context | Add-Member NoteProperty Response $response
    return $context
}

function Get-FakeContextBody {
    param([Parameter(Mandatory)]$Context)
    return ([Text.Encoding]::UTF8.GetString($Context.Response.OutputStream.ToArray()))
}

function Assert-ResponseHeaders {
    param([Parameter(Mandatory)]$Context)
    Assert-Equal 'no-store' $Context.Response.Headers['Cache-Control'] 'Cache-Control no-store'
    Assert-Equal 'nosniff' $Context.Response.Headers['X-Content-Type-Options'] 'nosniff'
    Assert-Equal 'no-referrer' $Context.Response.Headers['Referrer-Policy'] 'no-referrer'
}

function Set-SunshineProbeOverride {
    # Replaces the composed snapshot function at script scope (the dot-sourced
    # console and this suite share one scope). Every override test defines its
    # own; no test relies on the real default implementation in-process.
    param([Parameter(Mandatory)][scriptblock]$Snapshot)
    Set-Item -Path 'function:script:Get-GsSunshineProbeSnapshot' -Value $Snapshot
}

# ---------------------------------------------------------------------------
# Console script-state save/restore (dot-sourced console shares this scope)
# ---------------------------------------------------------------------------
$script:SavedConsoleState = $null

function Save-ConsoleState {
    $script:SavedConsoleState = @{
        Backend            = $script:Backend
        ProfilePath        = $script:ProfilePath
        Mode               = $script:Mode
        StaticDirResolved  = $script:StaticDirResolved
        ProductPath        = $script:ProductPath
        ModuleRoot         = $script:ModuleRoot
        ConfigPath         = $script:ConfigPath
        StateDir           = $script:StateDir
        ProductPathResolved = $script:ProductPathResolved
        ModuleRootResolved = $script:ModuleRootResolved
        StateDirDefault    = $script:StateDirDefault
        ConfigFilePath     = $script:ConfigFilePath
        JobsRoot           = $script:JobsRoot
        GsRuntimeAvailable = $script:GsRuntimeAvailable
        InstallProfilePathResolved = $script:InstallProfilePathResolved
        Prefs              = $script:Prefs
        SessionToken       = $script:SessionToken
        LaunchUrl          = $script:LaunchUrl
    }
}

function Restore-ConsoleState {
    if ($null -eq $script:SavedConsoleState) { throw 'no saved console state' }
    foreach ($entry in $script:SavedConsoleState.GetEnumerator()) {
        Set-Variable -Scope Script -Name $entry.Key -Value $entry.Value -Force
    }
}

# ---------------------------------------------------------------------------
# In-process definitions (console dot-sources gs-sunshine.ps1 itself)
# ---------------------------------------------------------------------------
. $consolePath -DefineOnly -Port 47991

# ---------------------------------------------------------------------------
# Group A: source hygiene
# ---------------------------------------------------------------------------

Invoke-Test 'gs-sunshine.ps1 is ASCII-only' {
    Assert-True (Test-FileAscii $sunshinePath) 'gs-sunshine.ps1 must be pure ASCII'
}

Invoke-Test 'gs-sunshine.ps1 performs no writes, web access or process operations by construction' {
    $text = [IO.File]::ReadAllText($sunshinePath)
    foreach ($forbidden in @('Start-Process', 'Start-Service', 'New-Service', 'schtasks', 'netsh',
            'Invoke-WebRequest', 'Invoke-RestMethod', 'Invoke-Expression', 'WebClient', 'DownloadString',
            'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Remove-Item', 'reg add')) {
        Assert-NotContains $text $forbidden ("gs-sunshine.ps1 must not contain: " + $forbidden)
    }
}

Invoke-Test 'dot-sourcing gs-sunshine.ps1 alone defines functions and has no observable side effects' {
    $stdoutFile = Join-Path $fixtureRoot 'dot-source-stdout.txt'
    $stderrFile = Join-Path $fixtureRoot 'dot-source-stderr.txt'
    $systemPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = '. "' + $sunshinePath + '"; Write-Output "dot-sourced"'
    $proc = Start-Process -FilePath $systemPs -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $command) `
        -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    Assert-Equal 0 $proc.ExitCode 'the isolated dot-source process must exit 0'
    Assert-Equal 'dot-sourced' ((Get-Content -LiteralPath $stdoutFile -Raw).Trim()) 'stdout must be exactly the marker (no probe output)'
    $stderrText = ''
    if (Test-Path -LiteralPath $stderrFile) { $stderrText = (Get-Content -LiteralPath $stderrFile -Raw) }
    if ($null -eq $stderrText) { $stderrText = '' }
    Assert-Equal '' $stderrText.Trim() 'the isolated dot-source must write nothing to stderr'
}

Invoke-Test 'Legacy definitions load without optional Sunshine files and Sunshine startup refuses the omission' {
    $copyRoot = Join-Path $fixtureRoot 'legacy-only-copy'
    New-Item -ItemType Directory -Path $copyRoot | Out-Null
    Copy-Item -LiteralPath $consolePath -Destination $copyRoot
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $consolePath) 'gs-tray-model.ps1') -Destination $copyRoot
    $copyScript = Join-Path $copyRoot 'gs-console.ps1'
    $errorFile = Join-Path $copyRoot 'child-error.txt'
    $baseArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $copyScript + '"'
    $systemPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $child = Start-Process -FilePath $systemPs -ArgumentList ($baseArgs + ' -DefineOnly') -PassThru -Wait -NoNewWindow -RedirectStandardError $errorFile
    Assert-Equal 0 $child.ExitCode 'Legacy definitions do not require the optional Sunshine helper'
    $sunArgs = $baseArgs + ' -Backend Sunshine -Demo -NoBrowser -NoTray -ConfigPath "' + (Join-Path $copyRoot 'prefs.json') + '" -StateDir "' + (Join-Path $copyRoot 'state') + '" -ExitAfterSec 2'
    $child = Start-Process -FilePath $systemPs -ArgumentList $sunArgs -PassThru -Wait -NoNewWindow -RedirectStandardError $errorFile
    Assert-Equal 4 $child.ExitCode 'Sunshine fails startup when its helper is absent'
    Assert-False (Test-Path -LiteralPath (Join-Path $copyRoot 'prefs.json')) 'no legacy preferences are written'
    Assert-False (Test-Path -LiteralPath (Join-Path $copyRoot 'jobs')) 'no legacy jobs directory is created'
}

Invoke-Test 'gs-console.vbs is ASCII-only and forwards only whitelisted backend arguments' {
    Assert-True (Test-FileAscii $vbsPath) 'gs-console.vbs must be pure ASCII'
    $text = [IO.File]::ReadAllText($vbsPath)
    Assert-Contains $text 'LCase(WScript.Arguments(0))' 'the whitelist comparison is case-insensitive on argument 0 only'
    Assert-Contains $text '"sunshine"' 'the Sunshine whitelist entry exists'
    Assert-Contains $text '"legacy"' 'the Legacy whitelist entry exists'
    Assert-Contains $text ' -Backend Sunshine' 'Sunshine is forwarded as a fixed -Backend value'
    Assert-Contains $text ' -Backend Legacy' 'Legacy is forwarded as a fixed -Backend value'
    Assert-Contains $text 'Unsupported launch argument' 'unknown arguments are refused'
    Assert-Contains $text 'WScript.Quit 1' 'refused arguments exit nonzero without launching'
    Assert-Contains $text 'WScript.Arguments.Count > 1' 'extra arguments are refused before launch'
    Assert-NotContains $text 'WScript.Arguments(0) &' 'no argument text is ever concatenated into the command line'
    Assert-NotContains $text '& WScript.Arguments' 'no argument text is ever concatenated into the command line'
    Assert-NotContains $text 'WScript.Arguments(1' 'only argument 0 is ever read'
}

# ---------------------------------------------------------------------------
# Group B: gs-sunshine.ps1 probes (injectable, TEMP-bounded)
# ---------------------------------------------------------------------------

Invoke-Test 'probe timeout is clamped to the contractual [1,1000] ms window' {
    Assert-Equal 1000 (Resolve-GsSunshineTimeoutMs -TimeoutMs 1000) '1000 stays 1000'
    Assert-Equal 1000 (Resolve-GsSunshineTimeoutMs -TimeoutMs 5000) '5000 clamps to 1000'
    Assert-Equal 1 (Resolve-GsSunshineTimeoutMs -TimeoutMs 0) '0 clamps to 1'
    Assert-Equal 1 (Resolve-GsSunshineTimeoutMs -TimeoutMs -3) 'negative clamps to 1'
    Assert-Equal 999 (Resolve-GsSunshineTimeoutMs -TimeoutMs 999) '999 stays 999'
}

Invoke-Test 'default install candidates are exactly the official default location' {
    $candidates = Get-GsSunshineDefaultInstallCandidates
    Assert-NotNull $candidates 'the candidate list must exist'
    Assert-True ($candidates.Count -ge 1) 'at least one default candidate exists'
    Assert-Contains $candidates[0] 'Sunshine' 'the official Sunshine directory is used'
    Assert-True ((Split-Path -Leaf $candidates[0]) -eq 'sunshine.exe') 'the official executable name is used'
}

Invoke-Test 'installed probe: TEMP candidate exists as a file (real metadata branch)' {
    $result = Test-GsSunshineInstalled -InstallCandidates @($fakeExePath)
    Assert-True $result.Installed 'a TEMP fixture file is detected as installed'
    Assert-Equal $fakeExePath $result.InstalledPath 'the matching candidate path is returned'
}

Invoke-Test 'installed probe: no candidate exists is a definite false' {
    $missing = Join-Path $fixtureRoot 'definitely-missing\sunshine.exe'
    $result = Test-GsSunshineInstalled -InstallCandidates @($missing)
    Assert-False $result.Installed 'checked-and-absent is false, not unknown'
    Assert-Equal '' $result.InstalledPath 'no path is returned for a definite false'
}

Invoke-Test 'installed probe: existence probe errors and non-boolean results are unknown (null)' {
    $throwing = Test-GsSunshineInstalled -InstallCandidates @($fakeExePath) -ExistenceProbe { param($Path) throw 'probe exploded' }
    Assert-Null $throwing.Installed 'an erroring probe must be unknown, never a false negative'
    $nonBool = Test-GsSunshineInstalled -InstallCandidates @($fakeExePath) -ExistenceProbe { param($Path) 'yes' }
    Assert-Null $nonBool.Installed 'a non-boolean probe result must be unknown'
}

Invoke-Test 'installed probe: empty usable candidates are unknown (null)' {
    $empty = Test-GsSunshineInstalled -InstallCandidates @('', '   ')
    Assert-Null $empty.Installed 'only blank candidates cannot be a definite answer'
    $result = Test-GsSunshineInstalled -InstallCandidates @('') -ExistenceProbe { param($Path) $false }
    Assert-Null $result.Installed 'blank candidates are never reported as definite false'
}

Invoke-Test 'management port probe: an owned ephemeral loopback listener is open, a closed port is closed' {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $open = Test-GsSunshineManagementPort -Port $port -TimeoutMs 800
        Assert-True $open 'the suite-owned listener accepts the single TCP connect'
        $listener.Stop()
        Start-Sleep -Milliseconds 100
        $closed = Test-GsSunshineManagementPort -Port $port -TimeoutMs 800
        Assert-False $closed 'a refusal is a definite closed, not unknown'
    } finally {
        try { $listener.Stop() } catch { }
    }
}

Invoke-Test 'management port probe: probe errors and non-boolean results are unknown (null)' {
    $throwing = Test-GsSunshineManagementPort -Port 47990 -TcpProbe { param($Port, $TimeoutMs) throw 'boom' }
    Assert-Null $throwing 'an erroring TCP probe must be unknown'
    $nonBool = Test-GsSunshineManagementPort -Port 47990 -TcpProbe { param($Port, $TimeoutMs) 'definitely' }
    Assert-Null $nonBool 'a non-boolean TCP probe result must be unknown'
}

Invoke-Test 'management port task errors distinguish refusal from an unknown socket failure' {
    $fakeClient = [pscustomobject]@{ Closed = $false; ErrorCode = [System.Net.Sockets.SocketError]::AccessDenied }
    $fakeClient | Add-Member ScriptMethod ConnectAsync {
        param($Address, $Port)
        return [System.Threading.Tasks.Task]::FromException([System.Net.Sockets.SocketException]::new([int]$this.ErrorCode))
    }
    $fakeClient | Add-Member ScriptMethod Close { $this.Closed = $true }
    function New-Object {
        param([string]$TypeName)
        if ($TypeName -ne 'System.Net.Sockets.TcpClient') { throw 'Unexpected constructor in probe.' }
        return $fakeClient
    }
    try {
        Assert-Null (Test-GsSunshineManagementPort) 'access denied is unknown, not a closed port'
        Assert-True $fakeClient.Closed 'the client is closed after an unexpected task error'
        $fakeClient.Closed = $false
        $fakeClient.ErrorCode = [System.Net.Sockets.SocketError]::ConnectionRefused
        Assert-Equal $false (Test-GsSunshineManagementPort) 'an explicit refusal is a definite negative'
        Assert-True $fakeClient.Closed 'the client is closed after refusal'
    } finally {
        Remove-Item function:New-Object -ErrorAction SilentlyContinue
    }
}

Invoke-Test 'management port probe: injected probes receive the clamped timeout and the requested port' {
    $observed = @{}
    $result = Test-GsSunshineManagementPort -Port 12345 -TimeoutMs 60000 -TcpProbe {
        param($Port, $TimeoutMs)
        $script:sunshineProbeObserved = @{ Port = $Port; TimeoutMs = $TimeoutMs }
        return $true
    }
    Assert-True $result 'the injected probe result passes through'
    Assert-Equal 12345 $script:sunshineProbeObserved.Port 'the port is passed through'
    Assert-Equal 1000 $script:sunshineProbeObserved.TimeoutMs 'an oversized timeout is clamped before the probe'
}

Invoke-Test 'snapshot composes both probes with the installed path' {
    $snapshot = Get-GsSunshineProbeSnapshot -InstallCandidates @($fakeExePath) -TcpProbe { param($Port, $TimeoutMs) $false }
    Assert-True $snapshot.Installed 'the installed result passes through'
    Assert-Equal $fakeExePath $snapshot.InstalledPath 'the installed path passes through'
    Assert-False $snapshot.ManagementPortOpen 'the port result passes through'
}

# ---------------------------------------------------------------------------
# Group C: install profile parsing and backend resolution
# ---------------------------------------------------------------------------

Invoke-Test 'a missing profile file is not an error and resolves to Legacy' {
    $doc = Read-GsConsoleInstallProfile -Path $profileMissingPath
    Assert-False $doc.Found 'a missing file is reported as not found'
    Assert-Null $doc.Backend 'no backend is read from a missing file'
    Assert-Equal '' $doc.Error 'a missing file is not an error'
    Assert-Equal 'Legacy' (Resolve-GsConsoleBackend -RequestedBackend '' -ProfilePath $profileMissingPath) 'missing profile defaults to Legacy'
}

Invoke-Test 'a directory at the profile path never silently selects Legacy' {
    $directoryProfile = Join-Path $fixtureRoot 'profile-is-directory.json'
    New-Item -ItemType Directory -Path $directoryProfile | Out-Null
    $doc = Read-GsConsoleInstallProfile -Path $directoryProfile
    Assert-True $doc.Found 'the path exists'
    Assert-Equal 'ProfileNotFile' $doc.Error 'a directory is invalid, not absent'
    Assert-Throws { Resolve-GsConsoleBackend -RequestedBackend '' -ProfilePath $directoryProfile } 'install profile'
}

Invoke-Test 'profile schemaVersion requires a JSON integer rather than coercion' {
    $index = 0
    foreach ($value in @('"1"', '1.0', '[1]', 'true')) {
        $index++
        $path = Write-InstallProfile ('schema-type-' + $index + '.json') ('{"schemaVersion":' + $value + ',"backend":"sunshine"}')
        $doc = Read-GsConsoleInstallProfile -Path $path
        Assert-Equal 'ProfileSchemaVersionInvalid' $doc.Error ('invalid schema type: ' + $value)
    }
}

Invoke-Test 'valid sunshine and legacy profiles parse and resolve' {
    $doc = Read-GsConsoleInstallProfile -Path $profileSunshinePath
    Assert-True $doc.Found 'the profile is found'
    Assert-Equal 'sunshine' $doc.Backend 'the sunshine backend is read'
    Assert-Equal '' $doc.Error 'the valid profile has no error'
    Assert-Equal 'Sunshine' (Resolve-GsConsoleBackend -RequestedBackend '' -ProfilePath $profileSunshinePath) 'sunshine profile resolves to Sunshine'
    $legacy = Read-GsConsoleInstallProfile -Path $profileLegacyPath
    Assert-Equal 'legacy' $legacy.Backend 'the legacy backend is read'
    Assert-Equal 'Legacy' (Resolve-GsConsoleBackend -RequestedBackend '' -ProfilePath $profileLegacyPath) 'legacy profile resolves to Legacy'
}

Invoke-Test 'invalid profile content fails loudly with a specific error' {
    $badSchema = Read-GsConsoleInstallProfile -Path $profileBadSchemaPath
    Assert-Equal 'ProfileSchemaVersionInvalid' $badSchema.Error 'schemaVersion 2 is rejected'
    $badCase = Read-GsConsoleInstallProfile -Path $profileBadBackendCasePath
    Assert-Equal 'ProfileBackendInvalid' $badCase.Error 'backend values are case-sensitive lowercase'
    $missingBackend = Read-GsConsoleInstallProfile -Path $profileMissingBackendPath
    Assert-Equal 'ProfileBackendMissing' $missingBackend.Error 'a missing backend is rejected'
    $numericBackend = Read-GsConsoleInstallProfile -Path $profileNumericBackendPath
    Assert-Equal 'ProfileBackendInvalid' $numericBackend.Error 'a non-string backend is rejected'
    $unknownField = Read-GsConsoleInstallProfile -Path $profileUnknownFieldPath
    Assert-Equal 'ProfileUnknownField' $unknownField.Error 'unknown fields are rejected'
    $notJson = Read-GsConsoleInstallProfile -Path $profileNotJsonPath
    Assert-Equal 'ProfileUnreadable' $notJson.Error 'unparseable content is rejected'
    $arrayJson = Read-GsConsoleInstallProfile -Path $profileArrayPath
    Assert-Equal 'ProfileShapeInvalid' $arrayJson.Error 'a JSON array is rejected'
    $oversized = Read-GsConsoleInstallProfile -Path $profileOversizedPath
    Assert-Equal 'ProfileFileOversized' $oversized.Error 'an oversized profile is rejected'
}

Invoke-Test 'an invalid profile fails startup resolution (never a silent Legacy fallback)' {
    foreach ($badPath in @($profileBadSchemaPath, $profileBadBackendCasePath, $profileMissingBackendPath,
            $profileNumericBackendPath, $profileUnknownFieldPath, $profileNotJsonPath, $profileArrayPath,
            $profileOversizedPath)) {
        Assert-Throws { Resolve-GsConsoleBackend -RequestedBackend '' -ProfilePath $badPath } 'install profile'
    }
}

Invoke-Test 'an explicit backend wins over any profile, valid or invalid' {
    Assert-Equal 'Sunshine' (Resolve-GsConsoleBackend -RequestedBackend 'Sunshine' -ProfilePath $profileNotJsonPath) 'explicit Sunshine beats an invalid profile'
    Assert-Equal 'Legacy' (Resolve-GsConsoleBackend -RequestedBackend 'Legacy' -ProfilePath $profileNotJsonPath) 'explicit Legacy beats an invalid profile'
    Assert-Equal 'Sunshine' (Resolve-GsConsoleBackend -RequestedBackend 'SUNSHINE' -ProfilePath $profileSunshinePath) 'explicit backend matching is case-insensitive'
    Assert-Equal 'Legacy' (Resolve-GsConsoleBackend -RequestedBackend 'legacy' -ProfilePath $profileLegacyPath) 'explicit legacy matching is case-insensitive'
    Assert-Throws { Resolve-GsConsoleBackend -RequestedBackend 'Bogus' -ProfilePath $profileSunshinePath } 'Unknown backend'
}

# ---------------------------------------------------------------------------
# Group D: startup resolution (in-process, all state TEMP-bounded)
# ---------------------------------------------------------------------------

Invoke-Test 'Sunshine startup skips every legacy resolution and touches no legacy state' {
    Save-ConsoleState
    $dirSnapshotBefore = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -Force).Count
    try {
        # Profile-driven selection: empty explicit backend + a valid
        # sunshine profile (the production default flow, no -Backend).
        $script:Backend = ''
        $script:ProfilePath = $profileSunshinePath
        $script:Mode = 'live'
        $script:StaticDirResolved = $assetDir
        $script:ProductPathResolved = ''
        $script:ModuleRootResolved = ''
        $script:StateDirDefault = ''
        $script:ConfigFilePath = ''
        $script:JobsRoot = ''
        $script:GsRuntimeAvailable = $true
        $script:Prefs = $null
        $script:SessionToken = ''
        $script:LaunchUrl = ''
        # Even though a fake importable GsRuntime and a fake CLI are offered,
        # the Sunshine startup must not resolve, import or require them.
        Resolve-GsConsoleStartup
        Assert-Equal 'Sunshine' $script:Backend 'the Sunshine backend is selected'
        Assert-Equal '' $script:ProductPathResolved 'the legacy product CLI is never resolved'
        Assert-Equal '' $script:ModuleRootResolved 'the GsRuntime module root is never resolved'
        Assert-Equal '' $script:ConfigFilePath 'no legacy prefs path is resolved'
        Assert-Equal '' $script:JobsRoot 'no jobs root is resolved'
        Assert-False $script:GsRuntimeAvailable 'GsRuntime is never imported'
        Assert-Null $script:Prefs 'Sunshine has no legacy preferences, even in memory'
        Assert-True ($script:SessionToken -match '^[0-9a-f]{64}$') 'a cryptographic random session token is generated'
        Assert-Equal ('http://127.0.0.1:47991/#session=' + $script:SessionToken) $script:LaunchUrl 'the launch URL carries the fragment token'
        Assert-False (Test-Path -LiteralPath $gsRuntimeImportMarkerPath) 'the fake GsRuntime module was never imported'
        $dirSnapshotAfter = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -Force).Count
        Assert-Equal $dirSnapshotBefore $dirSnapshotAfter 'the startup created nothing on disk'
    } finally {
        Restore-ConsoleState
    }
}

Invoke-Test 'legacy contrast: the same fixtures ARE resolved, imported and read under Legacy' {
    Save-ConsoleState
    try {
        if (Test-Path -LiteralPath $gsRuntimeImportMarkerPath) { Remove-Item -LiteralPath $gsRuntimeImportMarkerPath -Force }
        $script:Backend = 'Legacy'
        $script:ProfilePath = $profileMissingPath
        $script:Mode = 'live'
        $script:StaticDirResolved = $assetDir
        $script:ProductPathResolved = ''
        $script:ModuleRootResolved = ''
        $script:StateDirDefault = ''
        $script:ConfigFilePath = ''
        $script:JobsRoot = ''
        $script:Prefs = $null
        $script:SessionToken = ''
        $script:LaunchUrl = ''
        $script:ProductPath = $fakeCliPath
        $script:ModuleRoot = $fakeModuleRoot
        $script:ConfigPath = $validPrefsPath
        $script:StateDir = (Join-Path $fixtureRoot 'state-a')
        Resolve-GsConsoleStartup
        Assert-Equal 'Legacy' $script:Backend 'the legacy backend stays selected'
        Assert-Equal $fakeCliPath $script:ProductPathResolved 'the fake CLI is resolved'
        Assert-Equal $fakeModuleRoot $script:ModuleRootResolved 'the fake module root is resolved'
        Assert-True $script:GsRuntimeAvailable 'GsRuntime is imported in legacy live mode'
        Assert-Equal 7 $script:Prefs.Revision 'the valid revision-7 prefs fixture is read (fixture proven readable)'
        Assert-True (Test-Path -LiteralPath $gsRuntimeImportMarkerPath) 'the fake GsRuntime module was imported (ScriptsToProcess marker)'
    } finally {
        try { Remove-Module GsRuntime -Force -ErrorAction SilentlyContinue } catch { }
        Restore-ConsoleState
    }
}

Invoke-Test 'Sunshine startup ignores a present ConfigPath prefs file and never imports GsRuntime' {
    Save-ConsoleState
    try {
        if (Test-Path -LiteralPath $gsRuntimeImportMarkerPath) { Remove-Item -LiteralPath $gsRuntimeImportMarkerPath -Force }
        $script:Backend = 'Legacy'
        $script:ProfilePath = $profileMissingPath
        $script:Mode = 'live'
        $script:StaticDirResolved = $assetDir
        $script:ProductPathResolved = ''
        $script:ModuleRootResolved = ''
        $script:StateDirDefault = ''
        $script:ConfigFilePath = ''
        $script:JobsRoot = ''
        $script:Prefs = $null
        $script:SessionToken = ''
        $script:LaunchUrl = ''
        $script:ProductPath = $fakeCliPath
        $script:ModuleRoot = $fakeModuleRoot
        $script:ConfigPath = $validPrefsPath
        # The same fixture was proven readable by the legacy contrast test;
        # Sunshine must ignore it completely.
        $script:Backend = 'Sunshine'
        Resolve-GsConsoleStartup
        Assert-Equal 'Sunshine' $script:Backend 'the Sunshine backend is selected despite the profile path argument'
        Assert-Equal '' $script:ConfigFilePath 'the legacy prefs path is never adopted'
        Assert-Null $script:Prefs 'the revision-7 prefs file is never adopted and no legacy prefs object exists'
        Assert-False (Test-Path -LiteralPath $gsRuntimeImportMarkerPath) 'GsRuntime was never imported'
    } finally {
        Restore-ConsoleState
    }
}

Invoke-Test 'Sunshine demo startup keeps the fixed demo token and creates no legacy state' {
    Save-ConsoleState
    try {
        $script:Backend = 'Sunshine'
        $script:ProfilePath = $profileMissingPath
        $script:Mode = 'demo'
        $script:StaticDirResolved = $assetDir
        $script:ProductPathResolved = ''
        $script:ModuleRootResolved = ''
        $script:StateDirDefault = ''
        $script:ConfigFilePath = ''
        $script:JobsRoot = ''
        $script:Prefs = $null
        $script:SessionToken = ''
        $script:LaunchUrl = ''
        Resolve-GsConsoleStartup
        Assert-Equal 'Sunshine' $script:Backend 'the Sunshine backend is selected'
        Assert-Equal $demoToken $script:SessionToken 'demo mode keeps the fixed demo token'
        Assert-Equal '' $script:ConfigFilePath 'no legacy config path exists in Sunshine demo'
        Assert-Equal '' $script:JobsRoot 'no jobs root exists in Sunshine demo'
    } finally {
        Restore-ConsoleState
    }
}

Invoke-Test 'an invalid profile fails the startup resolution (unknown explicit values are blocked by ValidateSet)' {
    Save-ConsoleState
    try {
        $script:Mode = 'live'
        $script:StaticDirResolved = $assetDir
        $script:Backend = ''
        $script:ProfilePath = $profileBadSchemaPath
        Assert-Throws { Resolve-GsConsoleStartup } 'install profile'
        # An unknown explicit -Backend value can never reach the resolution
        # here: the param ValidateSet refuses it at binding (and even at a
        # direct assignment), so the child-process Group F test covers that
        # failure path end to end.
    } finally {
        Restore-ConsoleState
    }
}

# ---------------------------------------------------------------------------
# Group E: status DTO, status handler and Sunshine routing (in-process)
# ---------------------------------------------------------------------------

Invoke-Test 'the status DTO keeps the exact contractual shape and passes null through' {
    $now = [datetime]::UtcNow
    $dto = New-GsConsoleSunshineStatusDto -Snapshot @{ Installed = $null; InstalledPath = ''; ManagementPortOpen = $null } -Mode 'live' -ObservedAtUtc $now
    $expectedKeys = @('backend', 'mode', 'observedAt', 'installed', 'managementPortOpen', 'pairingStatus', 'streamingStatus', 'managementUrl', 'downloadUrl', 'clientUrl')
    Assert-Equal ($expectedKeys -join ',') (@($dto.Keys) -join ',') 'the DTO keys and their order are exactly the contractual shape'
    Assert-Equal 'sunshine' $dto.backend 'backend is sunshine'
    Assert-Equal 'live' $dto.mode 'mode passes through'
    Assert-Null $dto.installed 'an unknown installed stays null'
    Assert-Null $dto.managementPortOpen 'an unknown port state stays null'
    Assert-Equal 'notChecked' $dto.pairingStatus 'pairing is never claimed'
    Assert-Equal 'notChecked' $dto.streamingStatus 'streaming is never claimed'
    Assert-Equal 'https://localhost:47990' $dto.managementUrl 'the fixed management URL'
    Assert-Equal 'https://github.com/LizardByte/Sunshine/releases/latest' $dto.downloadUrl 'the fixed download URL'
    Assert-Equal 'https://moonlight-stream.org' $dto.clientUrl 'the fixed client URL'
    Assert-True ($dto.observedAt.EndsWith('Z')) 'observedAt is UTC ISO-8601'
    $parsed = [datetime]::Parse($dto.observedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    Assert-True ([Math]::Abs(($parsed.ToUniversalTime() - $now.ToUniversalTime()).TotalSeconds) -lt 5) 'observedAt is a valid timestamp'
}

Invoke-Test 'live status handler passes true/false probe results through over a fake context' {
    Set-SunshineProbeOverride { param() return @{ Installed = $true; InstalledPath = ''; ManagementPortOpen = $false } }
    try {
        $oldMode = $script:Mode
        $script:Mode = 'live'
        $context = New-FakeHttpContext
        Invoke-GsConsoleApiSunshineStatus -Context $context
        Assert-Equal 200 $context.Response.StatusCode 'the status is 200'
        Assert-ResponseHeaders $context
        $doc = (Get-FakeContextBody $context) | ConvertFrom-Json
        Assert-True $doc.ok 'ok is true'
        Assert-Equal 'sunshine' $doc.data.backend 'backend is sunshine'
        Assert-Equal 'live' $doc.data.mode 'mode is live'
        Assert-True $doc.data.installed 'installed true passes through'
        Assert-False $doc.data.managementPortOpen 'port false passes through'
        Assert-Equal 'notChecked' $doc.data.pairingStatus 'pairing stays notChecked'
        Assert-True ($doc.data.observedAt.EndsWith('Z')) 'observedAt is UTC'
        $script:Mode = $oldMode
    } finally {
        $script:Mode = 'live'
    }
}

Invoke-Test 'demo status handler returns the synthetic snapshot and never calls a probe' {
    Set-SunshineProbeOverride { param() throw 'the demo handler must never probe' }
    try {
        $oldMode = $script:Mode
        $script:Mode = 'demo'
        $context = New-FakeHttpContext
        Invoke-GsConsoleApiSunshineStatus -Context $context
        Assert-Equal 200 $context.Response.StatusCode 'the demo status is 200'
        $doc = (Get-FakeContextBody $context) | ConvertFrom-Json
        Assert-True $doc.ok 'ok is true'
        Assert-Equal 'sunshine' $doc.data.backend 'backend is sunshine'
        Assert-Equal 'demo' $doc.data.mode 'mode is demo'
        Assert-True $doc.data.installed 'the synthetic installed value is a fixed true'
        Assert-True $doc.data.managementPortOpen 'the synthetic port value is a fixed true'
        $script:Mode = $oldMode
    } finally {
        $script:Mode = 'live'
    }
}

Invoke-Test 'null probe outcomes are never rewritten into definite answers' {
    Set-SunshineProbeOverride { param() return @{ Installed = $null; InstalledPath = ''; ManagementPortOpen = $null } }
    $context = New-FakeHttpContext
    Invoke-GsConsoleApiSunshineStatus -Context $context
    $doc = (Get-FakeContextBody $context) | ConvertFrom-Json
    Assert-Null $doc.data.installed 'null installed stays null in JSON'
    Assert-Null $doc.data.managementPortOpen 'null port state stays null in JSON'
}

Invoke-Test 'Sunshine routing: session is required on every API route' {
    Set-SunshineProbeOverride { param() return @{ Installed = $null; InstalledPath = ''; ManagementPortOpen = $null } }
    $oldToken = $script:SessionToken
    $oldBackend = $script:Backend
    try {
        $script:SessionToken = 'sunshine-test-session-token'
        $script:Backend = 'Sunshine'
        $noSession = New-FakeHttpContext
        Invoke-GsConsoleSunshineRequest -Context $noSession -RawPath '/api/sunshine/status' -Method 'GET'
        Assert-Equal 401 $noSession.Response.StatusCode 'a missing session is 401'
        $wrongSession = New-FakeHttpContext
        $wrongSession.Request.Headers.Add('X-Gs-Session', 'wrong-token')
        Invoke-GsConsoleSunshineRequest -Context $wrongSession -RawPath '/api/sunshine/status' -Method 'GET'
        Assert-Equal 401 $wrongSession.Response.StatusCode 'a wrong session is 401'
        $valid = New-FakeHttpContext
        $valid.Request.Headers.Add('X-Gs-Session', 'sunshine-test-session-token')
        Invoke-GsConsoleSunshineRequest -Context $valid -RawPath '/api/sunshine/status' -Method 'GET'
        Assert-Equal 200 $valid.Response.StatusCode 'the valid session reaches the status route'
    } finally {
        $script:SessionToken = $oldToken
        $script:Backend = $oldBackend
    }
}

Invoke-Test 'Sunshine routing: cross-origin and mutating requests are rejected' {
    $oldToken = $script:SessionToken
    $oldBackend = $script:Backend
    try {
        $script:SessionToken = 'sunshine-test-session-token'
        $script:Backend = 'Sunshine'
        $crossOrigin = New-FakeHttpContext
        $crossOrigin.Request.Headers.Add('X-Gs-Session', 'sunshine-test-session-token')
        $crossOrigin.Request.Headers.Add('Origin', 'http://evil.example:9999')
        Invoke-GsConsoleSunshineRequest -Context $crossOrigin -RawPath '/api/sunshine/status' -Method 'GET'
        Assert-Equal 403 $crossOrigin.Response.StatusCode 'a cross-origin request is 403 even with a valid session'
        $noOrigin = New-FakeHttpContext
        $noOrigin.Request.Headers.Add('X-Gs-Session', 'sunshine-test-session-token')
        Invoke-GsConsoleSunshineRequest -Context $noOrigin -RawPath '/api/sunshine/status' -Method 'POST'
        Assert-Equal 403 $noOrigin.Response.StatusCode 'a POST without Origin is 403'
        $postStatus = New-FakeHttpContext
        $postStatus.Request.Headers.Add('X-Gs-Session', 'sunshine-test-session-token')
        $postStatus.Request.Headers.Add('Origin', 'http://127.0.0.1:47991')
        Invoke-GsConsoleSunshineRequest -Context $postStatus -RawPath '/api/sunshine/status' -Method 'POST'
        Assert-Equal 404 $postStatus.Response.StatusCode 'POST on the read-only status route is 404'
    } finally {
        $script:SessionToken = $oldToken
        $script:Backend = $oldBackend
    }
}

Invoke-Test 'Sunshine routing: every legacy API path is a 404 behind a valid session' {
    $oldToken = $script:SessionToken
    $oldBackend = $script:Backend
    try {
        $script:SessionToken = 'sunshine-test-session-token'
        $script:Backend = 'Sunshine'
        $cases = @(
            @{ Path = '/api/state'; Method = 'GET' },
            @{ Path = '/api/settings'; Method = 'GET' },
            @{ Path = '/api/settings'; Method = 'POST' },
            @{ Path = '/api/actions'; Method = 'POST' },
            @{ Path = '/api/demo/scenario'; Method = 'POST' },
            @{ Path = '/api/jobs/0123456789abcdef0123456789abcdef'; Method = 'GET' },
            @{ Path = '/api/sunshine/other'; Method = 'GET' },
            @{ Path = '/api/sunshine/status/extra'; Method = 'GET' }
        )
        foreach ($case in $cases) {
            $context = New-FakeHttpContext -Method $case.Method
            $context.Request.Headers.Add('X-Gs-Session', 'sunshine-test-session-token')
            if ($case.Method -eq 'POST') { $context.Request.Headers.Add('Origin', 'http://127.0.0.1:47991') }
            Invoke-GsConsoleSunshineRequest -Context $context -RawPath $case.Path -Method $case.Method
            Assert-Equal 404 $context.Response.StatusCode ("legacy/mutating route must be 404: " + $case.Method + ' ' + $case.Path)
        }
    } finally {
        $script:SessionToken = $oldToken
        $script:Backend = $oldBackend
    }
}

Invoke-Test 'Sunshine routing: the static map is exactly the four fixed Sunshine resources' {
    $oldBackend = $script:Backend
    $oldStatic = $script:StaticDirResolved
    $oldMode = $script:Mode
    try {
        $script:Backend = 'Sunshine'
        $script:StaticDirResolved = $assetDir
        $script:Mode = 'live'
        $root = New-FakeHttpContext
        Invoke-GsConsoleSunshineRequest -Context $root -RawPath '/' -Method 'GET'
        Assert-Equal 200 $root.Response.StatusCode 'the fixed homepage is served'
        Assert-Equal 'text/html; charset=utf-8' $root.Response.ContentType 'the homepage content type'
        $rootBody = Get-FakeContextBody $root
        Assert-Contains $rootBody 'data-mode="live"' 'the mode placeholder is substituted'
        Assert-NotContains $rootBody '__GS_MODE__' 'no placeholder remains'
        Assert-ResponseHeaders $root
        Assert-Equal "default-src 'self'; frame-ancestors 'none'" $root.Response.Headers['Content-Security-Policy'] 'the static CSP'
        $js = New-FakeHttpContext
        Invoke-GsConsoleSunshineRequest -Context $js -RawPath '/gs-sunshine.js' -Method 'GET'
        Assert-Equal 200 $js.Response.StatusCode 'the sunshine script is served'
        $css = New-FakeHttpContext
        Invoke-GsConsoleSunshineRequest -Context $css -RawPath '/gs-console.css' -Method 'GET'
        Assert-Equal 200 $css.Response.StatusCode 'the reused base stylesheet is served'
        $sunshineCss = New-FakeHttpContext
        Invoke-GsConsoleSunshineRequest -Context $sunshineCss -RawPath '/gs-sunshine.css' -Method 'GET'
        Assert-Equal 200 $sunshineCss.Response.StatusCode 'the sunshine stylesheet is served'
        foreach ($forbidden in @('/gs-console.html', '/gs-console.js', '/gs-sunshine.html', '/anything-else', '/static/gs-sunshine.js')) {
            $context = New-FakeHttpContext
            Invoke-GsConsoleSunshineRequest -Context $context -RawPath $forbidden -Method 'GET'
            Assert-Equal 404 $context.Response.StatusCode ("no arbitrary static path is served: " + $forbidden)
        }
        $postRoot = New-FakeHttpContext -Method 'POST'
        Invoke-GsConsoleSunshineRequest -Context $postRoot -RawPath '/' -Method 'POST'
        Assert-Equal 404 $postRoot.Response.StatusCode 'mutating static requests are 404'
    } finally {
        $script:Backend = $oldBackend
        $script:StaticDirResolved = $oldStatic
        $script:Mode = $oldMode
    }
}

# ---------------------------------------------------------------------------
# Group F: child-process HTTP integration (TEMP assets, ephemeral ports)
# ---------------------------------------------------------------------------

Invoke-Test 'Sunshine demo server: full status route, fixed static map, token and legacy isolation over real HTTP' {
    $port = Get-FreeTcpPort
    $env:GS_SUNSHINE_MARKER = $markerPath
    try {
        $record = Start-TestConsoleServer -Port $port -ConfigPath (Join-Path $fixtureRoot 'sunshine-demo-prefs.json') `
            -ProductPath $fakeCliPath -Backend 'Sunshine' -Demo
        Assert-True (Wait-TcpReady -Port $port) 'the Sunshine demo server starts'
        # Static map.
        $root = Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/'
        Assert-Equal 200 $root.Status 'the homepage is served'
        Assert-Contains $root.Body 'data-mode="demo"' 'the demo mode is substituted'
        Assert-Equal 'text/html; charset=utf-8' $root.Headers['Content-Type'] 'the homepage content type'
        Assert-Equal "default-src 'self'; frame-ancestors 'none'" $root.Headers['Content-Security-Policy'] 'the static CSP'
        Assert-Equal 'no-store' $root.Headers['Cache-Control'] 'no-store on static'
        Assert-Equal 'nosniff' $root.Headers['X-Content-Type-Options'] 'nosniff on static'
        Assert-Equal 'no-referrer' $root.Headers['Referrer-Policy'] 'no-referrer on static'
        Assert-Equal 200 (Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/gs-sunshine.js').Status 'the sunshine script is served'
        Assert-Equal 200 (Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/gs-console.css').Status 'the reused stylesheet is served'
        Assert-Equal 200 (Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/gs-sunshine.css').Status 'the sunshine stylesheet is served'
        foreach ($forbidden in @('/gs-console.html', '/gs-console.js', '/gs-sunshine.html', '/nope')) {
            Assert-Equal 404 (Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery $forbidden).Status ("legacy/unknown static assets are 404: " + $forbidden)
        }
        Assert-Equal 404 (Invoke-ConsoleHttp -Port $port -Method 'POST' -PathAndQuery '/').Status 'POST / is 404'
        # Status route: auth + payload.
        $noSession = Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/api/sunshine/status'
        Assert-Equal 401 $noSession.Status 'a missing session is 401'
        $wrongSession = Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/api/sunshine/status' -Session 'wrong-token'
        Assert-Equal 401 $wrongSession.Status 'a wrong session is 401'
        $crossOrigin = Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/api/sunshine/status' -Session $demoToken -Origin 'http://evil.example:9999'
        Assert-Equal 403 $crossOrigin.Status 'a cross-origin request is 403'
        $status = Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/api/sunshine/status' -Session $demoToken
        Assert-Equal 200 $status.Status 'the valid session reads the status'
        Assert-Equal 'application/json; charset=utf-8' $status.Headers['Content-Type'] 'the status content type'
        Assert-Equal 'no-store' $status.Headers['Cache-Control'] 'no-store on the status'
        $doc = $status.Body | ConvertFrom-Json
        Assert-True $doc.ok 'ok is true'
        Assert-Equal 'sunshine' $doc.data.backend 'backend is sunshine'
        Assert-Equal 'demo' $doc.data.mode 'mode is demo'
        Assert-True $doc.data.installed 'the synthetic installed value'
        Assert-True $doc.data.managementPortOpen 'the synthetic port value'
        Assert-Equal 'notChecked' $doc.data.pairingStatus 'pairing is never claimed'
        Assert-Equal 'notChecked' $doc.data.streamingStatus 'streaming is never claimed'
        Assert-Equal 'https://localhost:47990' $doc.data.managementUrl 'the fixed management URL'
        Assert-Equal 'https://github.com/LizardByte/Sunshine/releases/latest' $doc.data.downloadUrl 'the fixed download URL'
        Assert-Equal 'https://moonlight-stream.org' $doc.data.clientUrl 'the fixed client URL'
        Assert-True ($doc.data.observedAt.EndsWith('Z')) 'observedAt is UTC ISO-8601'
        Assert-Equal 404 (Invoke-ConsoleHttp -Port $port -Method 'POST' -PathAndQuery '/api/sunshine/status' -Session $demoToken -Origin ('http://127.0.0.1:' + $port)).Status 'POST on the status route is 404'
        # Legacy API isolation behind a VALID session.
        foreach ($case in @(
                @('GET', '/api/state', $false),
                @('GET', '/api/settings', $false),
                @('POST', '/api/settings', $true),
                @('POST', '/api/actions', $true),
                @('POST', '/api/demo/scenario', $true),
                @('GET', '/api/jobs/0123456789abcdef0123456789abcdef', $false)
            )) {
            $origin = ''
            if ($case[2]) { $origin = 'http://127.0.0.1:' + $port }
            $response = Invoke-ConsoleHttp -Port $port -Method $case[0] -PathAndQuery $case[1] -Session $demoToken -Origin $origin
            Assert-Equal 404 $response.Status ("legacy routes stay 404 in Sunshine mode: " + $case[0] + ' ' + $case[1])
        }
        # Demo isolation: the fake CLI was never invoked and no prefs written.
        Assert-False (Test-Path -LiteralPath $markerPath) 'the demo Sunshine server never invoked the CLI'
        Assert-False (Test-Path -LiteralPath (Join-Path $fixtureRoot 'sunshine-demo-prefs.json')) 'no prefs file was written for the Sunshine session'
    } finally {
        Remove-Item env:GS_SUNSHINE_MARKER -ErrorAction SilentlyContinue
        Stop-AllTestServers
    }
}

Invoke-Test 'a live Sunshine server starts without any legacy product CLI and gates its API on the session' {
    $port = Get-FreeTcpPort
    try {
        $record = Start-TestConsoleServer -Port $port -ConfigPath (Join-Path $fixtureRoot 'sunshine-live-prefs.json') `
            -ProductPath (Join-Path $fixtureRoot 'this-product-cli-does-not-exist.ps1') -Backend 'Sunshine'
        Assert-True (Wait-TcpReady -Port $port) 'the live Sunshine server starts without a product CLI'
        $root = Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/'
        Assert-Equal 200 $root.Status 'the homepage is served in live mode'
        Assert-Contains $root.Body 'data-mode="live"' 'the live mode is substituted'
        Assert-Equal 401 (Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/api/sunshine/status' -Session 'not-the-real-token').Status 'the status route is session-gated (the real token is never requested)'
    } finally {
        Stop-AllTestServers
    }
}

Invoke-Test 'a profile-driven Sunshine server (no -Backend) serves the Sunshine page' {
    $port = Get-FreeTcpPort
    try {
        $record = Start-TestConsoleServer -Port $port -ConfigPath (Join-Path $fixtureRoot 'sunshine-profile-prefs.json') `
            -ProductPath (Join-Path $fixtureRoot 'this-product-cli-does-not-exist.ps1') -ProfilePath $profileSunshinePath
        Assert-True (Wait-TcpReady -Port $port) 'the profile-driven Sunshine server starts'
        $root = Invoke-ConsoleHttp -Port $port -Method 'GET' -PathAndQuery '/'
        Assert-Equal 200 $root.Status 'the Sunshine homepage is served'
        Assert-Contains $root.Body 'data-mode="live"' 'the page is the Sunshine page in live mode'
    } finally {
        Stop-AllTestServers
    }
}

Invoke-Test 'an invalid install profile fails the child startup with the documented stderr line and exit code' {
    $port = Get-FreeTcpPort
    try {
        $record = Start-TestConsoleServer -Port $port -ConfigPath (Join-Path $fixtureRoot 'bad-profile-prefs.json') `
            -ProductPath $fakeCliPath -ProfilePath $profileBadSchemaPath
        $exitCode = Wait-ServerExit -Record $record
        Assert-Equal 4 $exitCode 'an invalid profile exits with the startup-failure code'
        $stderrText = Read-ServerStderr -Record $record
        Assert-Contains $stderrText 'CONSOLE-STARTUP-FAILED' 'the documented stderr line is kept'
        Assert-Contains $stderrText 'install profile' 'the profile problem is named'
    } finally {
        Stop-AllTestServers
    }
}

Invoke-Test 'an unknown explicit backend fails the child startup with a clear error' {
    $port = Get-FreeTcpPort
    try {
        $record = Start-TestConsoleServer -Port $port -ConfigPath (Join-Path $fixtureRoot 'bogus-backend-prefs.json') `
            -ProductPath $fakeCliPath -Backend 'Bogus'
        $exitCode = Wait-ServerExit -Record $record
        Assert-True ($exitCode -ne 0) 'an unknown explicit backend never starts the server'
        $stderrText = Read-ServerStderr -Record $record
        # The host wraps stderr at the console column width, so the word
        # 'Backend' itself may be split across lines; the value and the
        # ValidateSet mention survive unwrapped in every width we saw.
        Assert-Contains $stderrText 'Bogus' 'the rejected backend value is named on stderr'
        Assert-Contains $stderrText 'ValidateSet' 'the ValidateSet rejection is named on stderr'
    } finally {
        Stop-AllTestServers
    }
}

Invoke-Test 'an explicit Legacy backend and a legacy profile keep the legacy CLI requirement' {
    foreach ($variant in @(
            @{ Backend = 'Legacy'; ProfilePath = '' },
            @{ Backend = ''; ProfilePath = $profileLegacyPath }
        )) {
        $port = Get-FreeTcpPort
        try {
            $record = Start-TestConsoleServer -Port $port -ConfigPath (Join-Path $fixtureRoot 'legacy-missing-cli-prefs.json') `
                -ProductPath (Join-Path $fixtureRoot 'this-product-cli-does-not-exist.ps1') `
                -Backend $variant.Backend -ProfilePath $variant.ProfilePath
            $exitCode = Wait-ServerExit -Record $record
            Assert-Equal 4 $exitCode 'legacy startup still requires the product CLI (exit 4)'
            $stderrText = Read-ServerStderr -Record $record
            Assert-Contains $stderrText 'CONSOLE-STARTUP-FAILED' 'the startup-failure stderr line'
        } finally {
            Stop-AllTestServers
        }
    }
}

# ---------------------------------------------------------------------------
# Cleanup and summary
# ---------------------------------------------------------------------------
Stop-AllTestServers
try {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

Write-Host ("Summary: {0} passed, {1} failed, {2} skipped" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0) { exit 1 }
exit 0
