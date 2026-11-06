#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for product/gs-diagnose.ps1. Uses only temporary synthetic
    directories, the test process's own PID, and a loopback TcpListener fake
    serverinfo server. No real product state, no runtime bundle, no admin,
    no non-loopback network. Exits 0 only when every test passes and at
    least one ran; exits 1 otherwise.

    Every test that could hang (network fakes, file streaming, background
    runspaces, child processes) carries an independent hard deadline: the
    child process is killed or the runspace is stopped on overrun, so a
    regression fails the suite instead of hanging it.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$diagPath = Join-Path $repoRoot 'product\gs-diagnose.ps1'
$realProductEntry = Join-Path $repoRoot 'product\gs-product.ps1'

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
        $atLine = ''
        if ($null -ne $_.InvocationInfo) { $atLine = (' (line ' + $_.InvocationInfo.ScriptLineNumber + ')') }
        Write-Host "FAIL $Name :: $($_.Exception.Message)$atLine"
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

# Asserts that $Body throws exactly System.ArgumentException with the given ParamName.
function Assert-ArgumentException {
    param([scriptblock]$Body, [string]$ParamName, [string]$Message)
    $caught = $null
    try { & $Body } catch { $caught = $_.Exception }
    if ($null -eq $caught) { throw "Assertion failed: expected ArgumentException: $Message" }
    $typeName = $caught.GetType().FullName
    if ($typeName -ne 'System.ArgumentException') {
        throw "Assertion failed: $Message (expected System.ArgumentException, actual $typeName : $($caught.Message))"
    }
    if ($caught.ParamName -ne $ParamName) {
        throw "Assertion failed: $Message (expected ParamName '$ParamName', actual '$($caught.ParamName)')"
    }
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
$utf8 = New-Object System.Text.UTF8Encoding($false)
$tempRoot = [System.IO.Path]::GetTempPath()
$workDir = Join-Path $tempRoot ('GsDiagnose_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null
$workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath

# Secret material used to poison the fixture. Must never appear in any output.
$secretToken = 'abc123'
$secretRikey = 'deadbeefcafebabe'
$secretHex40 = 'a1b2c3d4' * 5
$secretJwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
$pemBodyRsa = 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7Zm9vYmFyYmF6'
$pemBodyDsa = 'MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAKR7Zm9vYmFyYmF6'
$secretJunkField = 'topsecret42'
$allSecrets = @($secretToken, $secretRikey, $secretHex40, $secretJwt, $pemBodyRsa, $pemBodyDsa, $secretJunkField)

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Get-KnownSha256 {
    # Independent SHA-256 of a string; UTF-8 without BOM, same as the fixture
    # files on disk.
    param([string]$Content)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-FakeProductEntryText { return '# synthetic product entry for diagnose tests' }
function Get-FakePsd1Text {
    param([string]$Version)
    return "@{`r`n    ModuleVersion = '$Version'`r`n}"
}
function Get-FakePsm1Text {
    param([string]$ModuleName)
    return "# synthetic module body $ModuleName"
}

function Get-GhostPid {
    # A PID that no process is currently using.
    $candidate = 4194300
    while ($null -ne (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { $candidate-- }
    return $candidate
}

function Get-SupervisorLogText {
    # 60 lines. The diagnose tail of 50 covers raw lines 11..60. A PEM block
    # opens on raw line 9 (before the window) and closes on raw line 12, so
    # the first tail line sits inside a block started outside the window.
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le 60; $i++) { $lines.Add("ORD $i ordinary line $i") }
    $lines[2] = '-----BEGIN PRIVATE KEY-----'                        # raw 3 (outside window)
    $lines[3] = $pemBodyRsa                                          # raw 4 (outside window)
    $lines[4] = '-----END PRIVATE KEY-----'                          # raw 5 (outside window)
    $lines[8] = '-----BEGIN RSA PRIVATE KEY-----'                    # raw 9 (before window)
    $lines[9] = $pemBodyDsa                                          # raw 10 (before window)
    $lines[10] = 'body line inside the tail window'                  # raw 11 (first tail line)
    $lines[11] = '-----END RSA PRIVATE KEY-----'                     # raw 12
    $lines[14] = ('token=' + $secretToken)                           # raw 15
    $lines[29] = '"password": "x"'                                   # raw 30
    $lines[39] = ('rikey=' + $secretRikey)                           # raw 40
    $lines[44] = ('checksum ' + $secretHex40 + ' end')               # raw 45
    $lines[49] = ('authorization: Bearer ' + $secretJwt)             # raw 50
    $lines[51] = 'RESULT OK'                                         # raw 52
    $lines[52] = 'state=ready'                                       # raw 53
    $lines[53] = 'Video stream is 3840x2160x60'                      # raw 54
    return (($lines -join "`r`n") + "`r`n")
}

function Get-RedactionMatrixLogText {
    # One line per round-2 redaction defect. Indexes are asserted one by one.
    $lines = @(
        '-----BEGIN PRIVATE KEY-----',                                                    # 0
        'AAAAB3NzaC1yc2EAAAADAQABAAABgQDFAKEPEMBODY0000',                                 # 1
        '-----END PRIVATE KEY----- -----BEGIN CERTIFICATE-----',                          # 2
        'QUJDRA==',                                                                       # 3
        '-----END CERTIFICATE-----',                                                      # 4
        'access_token=S3cr3t',                                                            # 5
        'client_secret=S3cr3t',                                                           # 6
        'refresh_token=S3cr3t',                                                           # 7
        'x-api-key=S3cr3t',                                                               # 8
        'sessionid=S3cr3t',                                                               # 9
        'Authorization: Bearer eyJS3cr3t',                                                # 10
        'Proxy-Authorization: Basic S3cr3t',                                              # 11
        'Set-Cookie: sid=S3cr3t; path=/',                                                 # 12
        'Cookie: lang=en; sid=S3cr3t',                                                    # 13
        'X-Api-Key: S3cr3t',                                                              # 14
        '{\"token\":\"S3cr3t\"}',                                                         # 15
        "'token': 'S3cr3t'",                                                              # 16
        'token: ["first", "S3cr3t"]',                                                     # 17
        'pinball=1234 spinning=1234 opinion certainly',                                   # 18
        'PIN 1234',                                                                       # 19
        'pin: 1234',                                                                      # 20
        'GET http://127.0.0.1:47989/x?a=1&sig=S3cr3t HTTP/1.1',                           # 21
        'callback http://host/cb#access_token=S3cr3t done',                               # 22
        ('accessing C:\hex\' + $secretHex40 + '\path free text'),                         # 23
        'token=S3cr3t',                                                                   # 24
        'certificate=S3cr3t credential=S3cr3t api-key=S3cr3t private-key=S3cr3t rikeyid=S3cr3t', # 25
        'ORD ordinary line untouched'                                                     # 26
    )
    return (($lines -join "`r`n") + "`r`n")
}

function New-Fixture {
    param([string]$Name)

    $base = Join-Path $workDir $Name
    $install = Join-Path $base 'install'
    $state = Join-Path $base 'state'
    $logs = Join-Path $base 'logs'
    $compSrc = Join-Path $base 'components'
    foreach ($d in @($install, $state, $logs, $compSrc)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    Write-Utf8File (Join-Path $install 'gs-product.ps1') (Get-FakeProductEntryText)
    $counter = 0
    foreach ($moduleName in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
        $counter++
        $version = ('9.9.' + $counter)
        $modDir = Join-Path $install (Join-Path 'Modules' $moduleName)
        Write-Utf8File (Join-Path $modDir ($moduleName + '.psd1')) (Get-FakePsd1Text $version)
        Write-Utf8File (Join-Path $modDir ($moduleName + '.psm1')) (Get-FakePsm1Text $moduleName)
    }

    # Install bin with known content, plus a .log file that must be skipped.
    Write-Utf8File (Join-Path $install 'bin\bundle-alpha.dat') 'bundle-alpha-payload'
    Write-Utf8File (Join-Path $install 'bin\bundle-beta.dat') 'bundle-beta-payload'
    Write-Utf8File (Join-Path $install 'bin\stale.log') 'should be skipped'

    $config = [ordered]@{
        schemaVersion      = 1
        installDir         = $install
        stateDir           = $state
        logDir             = $logs
        componentSourceDir = $compSrc
    }
    Write-Utf8File (Join-Path $state 'runtime-config.json') ($config | ConvertTo-Json)

    $status = [ordered]@{
        state        = 'ready'
        runId        = 'run-1234'
        lastError    = ('password=hunter2 token=' + $secretToken)
        sessionToken = $secretJunkField   # not whitelisted; must never be reported
    }
    Write-Utf8File (Join-Path $state 'runtime\state\status.json') ($status | ConvertTo-Json)

    Write-Utf8File (Join-Path $state 'runtime\bin\gs_supervisor.ps1') '# synthetic supervisor'
    Write-Utf8File (Join-Path $state 'runtime\hook.dat') 'synthetic hook'
    Write-Utf8File (Join-Path $state 'runtime\bin\_supervisor.log') (Get-SupervisorLogText)

    # PID files: alive plain integer (this test process), JSON with a dead
    # processId, malformed text, and a missing file (ssau).
    $ghost = Get-GhostPid
    Write-Utf8File (Join-Path $state 'broker_pid.json') ([string]$PID)
    Write-Utf8File (Join-Path $state 'nvs_pid.json') ('{ "processId": ' + $ghost + ' }')
    Write-Utf8File (Join-Path $state 'nss_pid.json') 'garbage{ not json'

    return @{ Base = $base; Install = $install; State = $state; Logs = $logs; ComponentSource = $compSrc; GhostPid = $ghost }
}

# A loopback port that refuses connections (listener created, then stopped).
$closedListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$closedListener.Start()
$closedPort = $closedListener.LocalEndpoint.Port
$closedListener.Stop()

function New-CommonParams {
    # Parameters that keep every test off the real machine: synthetic dirs,
    # MSI lookup skipped, serverinfo pointed at the closed loopback port,
    # supervisor task query skipped and the live ACL probe disabled (the
    # task store and ACLs are only ever exercised through the injected
    # test seams, never against real system state).
    param([hashtable]$Fixture)
    return @{
        InstallDir                 = $Fixture.Install
        StateDir                   = $Fixture.State
        LogDir                     = $Fixture.Logs
        ModuleRoot                 = (Join-Path $Fixture.Install 'Modules')
        SkipInstalledProductLookup = $true
        ServerInfoUri              = ('http://127.0.0.1:' + $closedPort + '/serverinfo')
        TimeoutSec                 = 2
        SupervisorTaskName         = ''
        SkipAclCheck               = $true
        SkipHostCheck              = $true
    }
}

function Invoke-Diagnose {
    param([hashtable]$Params)
    return @(& $diagPath @Params)
}

function Invoke-DiagnoseChild {
    # Runs diagnose in a child powershell.exe with a hard deadline so a
    # regression fails the test instead of hanging the suite. The child is
    # killed on overrun. Returns exit code plus decoded stdout/stderr.
    param([hashtable]$Params, [int]$TimeoutSeconds = 90)
    $exe = Join-Path $PSHOME 'powershell.exe'
    $argText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $diagPath + '" -AsJson'
    foreach ($key in @('InstallDir', 'StateDir', 'LogDir', 'ModuleRoot', 'ServerInfoUri', 'SupervisorTaskName')) {
        if ($Params.ContainsKey($key) -and ($null -ne $Params[$key])) {
            $argText = $argText + (' -' + $key + ' "' + $Params[$key] + '"')
        }
    }
    foreach ($key in @('TimeoutSec', 'LogTailLines', 'LogScanMaxBytes')) {
        if ($Params.ContainsKey($key)) { $argText = $argText + (' -' + $key + ' ' + $Params[$key]) }
    }
    foreach ($key in @('SkipInstalledProductLookup', 'SkipAclCheck', 'SkipHostCheck')) {
        if ($Params.ContainsKey($key) -and $Params[$key]) {
            $argText = $argText + (' -' + $key)
        }
    }
    $proc = New-Object System.Diagnostics.Process
    try {
        $proc.StartInfo.FileName = $exe
        $proc.StartInfo.Arguments = $argText
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $null = $proc.Start()
        # Drain both pipes asynchronously from the start: waiting for exit
        # before reading would deadlock once the child fills a pipe buffer.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            throw ('diagnose child exceeded its ' + $TimeoutSeconds + 's hard deadline')
        }
        $stdout = $outTask.Result
        $stderrText = $errTask.Result
        return @{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderrText }
    } finally {
        $proc.Dispose()
    }
}

function Invoke-DiagnoseWithFakeServer {
    # Runs diagnose with -AsJson in a background runspace and serves exactly
    # one canned HTTP response on a fresh loopback TcpListener (no
    # HttpListener). Returns the runspace output and error streams. The
    # runspace is stopped on a hard completion deadline so a hung diagnose
    # fails the test instead of hanging the suite.
    param(
        [hashtable]$Params,
        [int]$StatusCode = 200,
        [string]$Body = '',
        [switch]$HoldOpen,
        # Full status line override, e.g. 'HTTP/1.1 302 Found'.
        [string]$StatusLine = '',
        # Extra response headers, each a full 'Name: value' string.
        [string[]]$ExtraHeaders = @(),
        # Custom body writer: scriptblock param($stream, $client), used for
        # trickling and oversized bodies.
        [scriptblock]$RawWriter = $null,
        # Optional userinfo for the request URI (display-uri leak test).
        [string]$UserInfo = '',
        [int]$CompletionTimeoutSeconds = 30
    )
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    if ([string]::IsNullOrEmpty($UserInfo)) {
        $Params.ServerInfoUri = ('http://127.0.0.1:' + $port + '/serverinfo')
    } else {
        $Params.ServerInfoUri = ('http://' + $UserInfo + '@127.0.0.1:' + $port + '/serverinfo')
    }
    $Params.AsJson = $true

    $ps = [powershell]::Create()
    try {
        $childScript = "param(`$Path, `$Params)`r`n& `$Path @Params"
        $null = $ps.AddScript($childScript)
        $null = $ps.AddParameter('Path', $diagPath)
        $null = $ps.AddParameter('Params', $Params)
        $handle = $ps.BeginInvoke()

        # Wait (bounded) for diagnose to connect, then answer.
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        $client = $null
        while ($null -eq $client -and [DateTime]::UtcNow -lt $deadline) {
            if ($listener.Pending()) { $client = $listener.AcceptTcpClient() }
            else { Start-Sleep -Milliseconds 25 }
        }
        if ($null -eq $client) { throw 'fake serverinfo: diagnose never connected' }
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            # Drain the request first. Closing a socket that still has unread
            # received data makes Windows send an RST, which can destroy the
            # response bytes in flight.
            $buffer = New-Object byte[] 4096
            $receivedText = ''
            while (-not $receivedText.Contains("`r`n`r`n")) {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $receivedText = $receivedText + [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
            }
            if ($HoldOpen) {
                Start-Sleep -Milliseconds (($Params.TimeoutSec * 1000) + 2000)
            } elseif ($null -ne $RawWriter) {
                & $RawWriter $stream $client
            } else {
                $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
                if ($StatusLine -ne '') {
                    $resolvedStatusLine = $StatusLine
                } elseif ($StatusCode -eq 200) {
                    $resolvedStatusLine = 'HTTP/1.1 200 OK'
                } elseif ($StatusCode -eq 503) {
                    $resolvedStatusLine = 'HTTP/1.1 503 Service Unavailable'
                } else {
                    $resolvedStatusLine = ('HTTP/1.1 ' + $StatusCode + ' Status')
                }
                $header = $resolvedStatusLine + "`r`n" +
                    'Content-Type: text/xml' + "`r`n" +
                    ('Content-Length: ' + $bodyBytes.Length) + "`r`n"
                foreach ($extra in $ExtraHeaders) { $header = $header + $extra + "`r`n" }
                $header = $header + 'Connection: close' + "`r`n`r`n"
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                if ($bodyBytes.Length -gt 0) { $stream.Write($bodyBytes, 0, $bodyBytes.Length) }
                $stream.Flush()
                # Shut down the send side and give the client a moment to
                # pull the response before the socket goes away.
                $client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
                Start-Sleep -Milliseconds 150
            }
        } finally { $client.Close() }

        # Hard completion deadline: stop the runspace and fail on overrun.
        $finishBy = [DateTime]::UtcNow.AddSeconds($CompletionTimeoutSeconds)
        $done = $false
        while ([DateTime]::UtcNow -lt $finishBy) {
            if ($handle.AsyncWaitHandle.WaitOne(200)) { $done = $true; break }
        }
        if (-not $done) {
            try { $ps.Stop() } catch { }
            try { $null = $handle.AsyncWaitHandle.WaitOne(3000) } catch { }
            throw ('diagnose did not finish within ' + $CompletionTimeoutSeconds + 's (fake serverinfo)')
        }
        return @{
            Output = @($ps.EndInvoke($handle))
            Errors = @($ps.Streams.Error)
            Port   = $port
        }
    } finally {
        $ps.Dispose()
        $listener.Stop()
    }
}

# ---------------------------------------------------------------------------
# Shared fixture run
# ---------------------------------------------------------------------------
try {
    if (-not (Test-Path -LiteralPath $diagPath -PathType Leaf)) {
        Write-Host "FAIL diagnose script exists :: missing $diagPath"
        exit 1
    }

    $fullFixture = New-Fixture 'full'
    $fullParams = New-CommonParams $fullFixture
    $fullReport = @(Invoke-Diagnose $fullParams)[0]

    $freeXml = '<root status_code="200"><state>OS_SERVER_FREE</state><currentgame>0</currentgame></root>'
    $busyXml = '<root status_code="200"><state>OS_SERVER_BUSY</state><currentgame>258</currentgame></root>'

    # ---- Report shape ----
    Invoke-Test 'report is a single object with schemaVersion 1 and every section' {
        $out = @(Invoke-Diagnose $fullParams)
        Assert-Equal 1 $out.Count 'exactly one output object'
        $r = $out[0]
        Assert-Equal 1 $r.schemaVersion 'schemaVersion'
        Assert-True ($r.generatedAtUtc -match 'Z$') "generatedAtUtc is UTC ISO: $($r.generatedAtUtc)"
        Assert-Equal ([System.Environment]::MachineName) $r.computerName 'computerName'
        Assert-True ($r.powerShellVersion.Length -gt 0) 'powerShellVersion present'
        foreach ($section in @('paths', 'product', 'runtimeConfig', 'status', 'serverInfo', 'components', 'runtimeBundle', 'supervisorLog', 'hygiene', 'host', 'extraLogs', 'errors')) {
            Assert-True ($null -ne $r.PSObject.Properties[$section]) "section $section present"
        }
        Assert-Equal 0 $LASTEXITCODE 'script exit code'
    }

    Invoke-Test 'every section carries a boolean ok and an errors array' {
        foreach ($name in @('product', 'runtimeConfig', 'status', 'serverInfo', 'components', 'runtimeBundle', 'supervisorLog', 'hygiene', 'host')) {
            $section = $fullReport.PSObject.Properties[$name].Value
            Assert-True ($section.ok -is [bool]) "$name.ok is boolean"
            Assert-True ($null -ne $section.errors) "$name.errors present"
        }
    }

    Invoke-Test 'paths section reflects the effective parameters' {
        Assert-Equal $fullFixture.Install $fullReport.paths.installDir 'installDir'
        Assert-Equal $fullFixture.State $fullReport.paths.stateDir 'stateDir'
        Assert-Equal $fullFixture.Logs $fullReport.paths.logDir 'logDir'
        Assert-Equal (Join-Path $fullFixture.Install 'Modules') $fullReport.paths.moduleRoot 'moduleRoot'
    }

    Invoke-Test 'aggregated errors name their section, code and message' {
        $agg = @($fullReport.errors)
        Assert-True ($agg.Count -gt 0) 'closed-port serverinfo produces at least one error'
        foreach ($e in $agg) {
            Assert-True ($null -ne $e.PSObject.Properties['section']) 'error has section'
            Assert-True ($null -ne $e.code) 'error has code'
            Assert-True ($null -ne $e.message) 'error has message'
        }
        $serverErrors = @($agg | Where-Object { $_.section -eq 'serverInfo' })
        Assert-True ($serverErrors.Count -gt 0) 'serverInfo failure is aggregated'
    }

    # ---- product ----
    Invoke-Test 'product: entry hash and module versions from the fake install' {
        $p = $fullReport.product
        Assert-True $p.ok 'product section ok'
        Assert-Equal (Join-Path $fullFixture.Install 'gs-product.ps1') $p.productEntryPath 'entry path'
        Assert-Equal (Get-KnownSha256 (Get-FakeProductEntryText)) $p.productEntrySha256 'entry SHA-256'
        $mods = @($p.modules)
        Assert-Equal 3 $mods.Count 'three modules'
        Assert-Equal 'GsControl' $mods[0].name 'module name'
        Assert-Equal '9.9.1' $mods[0].version 'module version'
        Assert-Equal (Get-KnownSha256 (Get-FakePsd1Text '9.9.1')) $mods[0].psd1Sha256 'psd1 SHA-256'
        Assert-Equal (Get-KnownSha256 (Get-FakePsm1Text 'GsControl')) $mods[0].psm1Sha256 'psm1 SHA-256'
        Assert-Equal '9.9.2' $mods[1].version 'second version'
        Assert-Equal '9.9.3' $mods[2].version 'third version'
    }

    Invoke-Test 'product: broken module manifest is an error, not a throw' {
        $fx = New-Fixture 'brokenmanifest'
        Write-Utf8File (Join-Path $fx.Install 'Modules\GsControl\GsControl.psd1') 'this is not = = a hashtable {'
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-True (-not $r.product.ok) 'product section not ok'
        Assert-True ($null -eq @($r.product.modules)[0].version) 'version stays null'
        $codes = @($r.product.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'ManifestReadFailed') "ManifestReadFailed in errors: $($codes -join ',')"
    }

    Invoke-Test 'product: installed MSI lookup skipped by switch' {
        Assert-True $fullReport.product.installedMsi.lookupSkipped 'lookupSkipped true'
        Assert-True (-not $fullReport.product.installedMsi.found) 'found false when skipped'
    }

    # ---- runtimeConfig ----
    Invoke-Test 'runtimeConfig: valid file parsed with schemaVersion and four dirs' {
        $c = $fullReport.runtimeConfig
        Assert-True $c.ok 'section ok'
        Assert-Equal (Join-Path $fullFixture.State 'runtime-config.json') $c.path 'path'
        Assert-True $c.exists 'exists'
        Assert-Equal '1' $c.schemaVersion 'schemaVersion'
        Assert-Equal $fullFixture.Install $c.installDir 'installDir'
        Assert-Equal $fullFixture.State $c.stateDir 'stateDir'
        Assert-Equal $fullFixture.Logs $c.logDir 'logDir'
        Assert-Equal $fullFixture.ComponentSource $c.componentSourceDir 'componentSourceDir'
    }

    Invoke-Test 'runtimeConfig: broken JSON is an error, not a throw' {
        $fx = New-Fixture 'brokenconfig'
        Write-Utf8File (Join-Path $fx.State 'runtime-config.json') '{ broken'
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-True (-not $r.runtimeConfig.ok) 'section not ok'
        Assert-True $r.runtimeConfig.exists 'file exists'
        $codes = @($r.runtimeConfig.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'InvalidJson') "InvalidJson in errors: $($codes -join ',')"
    }

    Invoke-Test 'runtimeConfig: missing file reported with exists false' {
        $fx = New-Fixture 'noconfig'
        Remove-Item -LiteralPath (Join-Path $fx.State 'runtime-config.json') -Force
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-True (-not $r.runtimeConfig.exists) 'exists false'
        Assert-True ($null -eq $r.runtimeConfig.schemaVersion) 'no schemaVersion'
        $codes = @($r.runtimeConfig.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'FileNotFound') "FileNotFound in errors: $($codes -join ',')"
    }

    # ---- status ----
    Invoke-Test 'status: primary candidate used, fields redacted' {
        $s = $fullReport.status
        Assert-True $s.ok 'section ok'
        Assert-Equal (Join-Path $fullFixture.State 'runtime\state\status.json') $s.path 'path used'
        Assert-True $s.exists 'exists'
        Assert-True ($s.lastWriteTimeUtc -match 'Z$') 'lastWriteTimeUtc ISO'
        Assert-Equal 'ready' $s.state 'state'
        Assert-Equal 'run-1234' $s.runId 'runId'
        Assert-Equal 'password=<redacted> token=<redacted>' $s.lastError 'lastError redacted'
    }

    Invoke-Test 'status: non-whitelisted fields are never dumped' {
        $json = $fullReport | ConvertTo-Json -Depth 8
        Assert-True (-not $json.Contains($secretJunkField)) 'sessionToken value absent from the report'
    }

    Invoke-Test 'status: secondary candidate used when only it exists' {
        $fx = New-Fixture 'onlyB'
        Remove-Item -LiteralPath (Join-Path $fx.State 'runtime\state\status.json') -Force
        Write-Utf8File (Join-Path $fx.State 'status.json') '{ "state": "busy" }'
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal (Join-Path $fx.State 'status.json') $r.status.path 'path used'
        Assert-Equal 'busy' $r.status.state 'state'
        Assert-True $r.status.exists 'exists'
    }

    Invoke-Test 'status: both candidates -> newer file wins (B newer)' {
        $fx = New-Fixture 'bothB'
        $pathA = Join-Path $fx.State 'runtime\state\status.json'
        $pathB = Join-Path $fx.State 'status.json'
        Write-Utf8File $pathB '{ "state": "from-b" }'
        $t1 = [DateTime]::SpecifyKind([DateTime]::Parse('2026-01-01T00:00:00'), [DateTimeKind]::Utc)
        $t2 = $t1.AddMinutes(5)
        (Get-Item -LiteralPath $pathA).LastWriteTimeUtc = $t1
        (Get-Item -LiteralPath $pathB).LastWriteTimeUtc = $t2
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal $pathB $r.status.path 'newer B wins'
        Assert-Equal 'from-b' $r.status.state 'state from B'
    }

    Invoke-Test 'status: both candidates -> newer file wins (A newer)' {
        $fx = New-Fixture 'bothA'
        $pathA = Join-Path $fx.State 'runtime\state\status.json'
        $pathB = Join-Path $fx.State 'status.json'
        Write-Utf8File $pathB '{ "state": "from-b" }'
        Write-Utf8File $pathA '{ "state": "from-a" }'
        $t1 = [DateTime]::SpecifyKind([DateTime]::Parse('2026-01-01T00:00:00'), [DateTimeKind]::Utc)
        $t2 = $t1.AddMinutes(5)
        (Get-Item -LiteralPath $pathA).LastWriteTimeUtc = $t2
        (Get-Item -LiteralPath $pathB).LastWriteTimeUtc = $t1
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal $pathA $r.status.path 'newer A wins'
        Assert-Equal 'from-a' $r.status.state 'state from A'
    }

    Invoke-Test 'status: equal timestamps prefer the primary candidate' {
        $fx = New-Fixture 'tie'
        $pathA = Join-Path $fx.State 'runtime\state\status.json'
        $pathB = Join-Path $fx.State 'status.json'
        Write-Utf8File $pathB '{ "state": "from-b" }'
        $t = [DateTime]::SpecifyKind([DateTime]::Parse('2026-01-01T00:00:00'), [DateTimeKind]::Utc)
        (Get-Item -LiteralPath $pathA).LastWriteTimeUtc = $t
        (Get-Item -LiteralPath $pathB).LastWriteTimeUtc = $t
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal $pathA $r.status.path 'tie goes to A'
    }

    Invoke-Test 'status: run_id / last_error spellings are tolerated' {
        $fx = New-Fixture 'spellings'
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') '{ "state": "ready", "run_id": "rid-9", "last_error": "e9" }'
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal 'rid-9' $r.status.runId 'run_id'
        Assert-Equal 'e9' $r.status.lastError 'last_error'
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') '{ "state": "ready", "runId": "rid-1", "run_id": "rid-9", "error": "boom" }'
        $r2 = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal 'rid-1' $r2.status.runId 'runId preferred over run_id'
        Assert-Equal 'boom' $r2.status.lastError 'error spelling tolerated'
    }

    Invoke-Test 'status: long values truncated to 512 characters' {
        $fx = New-Fixture 'truncated'
        $long = ('e' * 600)
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ('{ "state": "ready", "lastError": "' + $long + '" }')
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal 512 $r.status.lastError.Length 'lastError truncated to 512'
    }

    Invoke-Test 'status: missing status file is an error entry, not a throw' {
        $fx = New-Fixture 'nostatus'
        Remove-Item -LiteralPath (Join-Path $fx.State 'runtime\state\status.json') -Force
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-True (-not $r.status.exists) 'exists false'
        Assert-True ($null -eq $r.status.state) 'no state'
        $codes = @($r.status.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'FileNotFound') "FileNotFound in errors: $($codes -join ',')"
        Assert-Equal 2 @($r.status.candidates).Count 'both candidates reported'
    }

    # ---- components ----
    Invoke-Test 'components: alive plain-integer pid reported running' {
        $items = @($fullReport.components.items)
        Assert-Equal 4 $items.Count 'four components'
        $broker = @($items | Where-Object { $_.name -eq 'broker' })[0]
        Assert-True $broker.exists 'pid file exists'
        Assert-Equal $PID $broker.pid 'pid is this test process'
        Assert-True $broker.running 'running true'
        Assert-True ($broker.processName.Length -gt 0) 'process name visible'
        Assert-True ($null -ne $broker.processStartTimeUtc) 'start time visible'
    }

    Invoke-Test 'components: JSON processId and missing/malformed pid files tolerated' {
        $items = @($fullReport.components.items)
        $nvs = @($items | Where-Object { $_.name -eq 'nvs' })[0]
        Assert-True $nvs.exists 'nvs pid file exists'
        Assert-Equal $fullFixture.GhostPid $nvs.pid 'pid parsed from JSON processId'
        Assert-True (-not $nvs.running) 'ghost pid is not running'

        $nss = @($items | Where-Object { $_.name -eq 'nss' })[0]
        Assert-True $nss.exists 'nss pid file exists'
        Assert-True ($null -eq $nss.pid) 'malformed file yields no pid'
        Assert-True (-not $nss.running) 'malformed file is not running'

        $ssau = @($items | Where-Object { $_.name -eq 'ssau' })[0]
        Assert-True (-not $ssau.exists) 'ssau pid file missing'

        $codes = @($fullReport.components.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'MalformedPidFile') "MalformedPidFile in errors: $($codes -join ',')"
        Assert-True (-not $fullReport.components.ok) 'components section not ok'
    }

    # ---- runtimeBundle ----
    Invoke-Test 'runtimeBundle: known hashes, .log files skipped, top level only' {
        $dirs = @($fullReport.runtimeBundle.directories)
        Assert-Equal 3 $dirs.Count 'three directories'
        $installBin = @($dirs | Where-Object { $_.label -eq 'installBin' })[0]
        Assert-True $installBin.available 'install bin available'
        $names = @(@($installBin.files) | ForEach-Object { $_.name })
        Assert-Equal 'bundle-alpha.dat' $names[0] 'files sorted by name'
        Assert-Equal 2 @($installBin.files).Count 'log file skipped'
        $alpha = @(@($installBin.files) | Where-Object { $_.name -eq 'bundle-alpha.dat' })[0]
        Assert-Equal (Get-KnownSha256 'bundle-alpha-payload') $alpha.sha256 'known SHA-256'
        Assert-Equal 20 $alpha.sizeBytes 'size'
        Assert-True ($alpha.lastWriteTimeUtc -match 'Z$') 'lastWriteTimeUtc ISO'

        $runtimeBin = @($dirs | Where-Object { $_.label -eq 'runtimeBin' })[0]
        Assert-Equal 1 @($runtimeBin.files).Count 'supervisor log not listed'
        Assert-Equal 'gs_supervisor.ps1' @($runtimeBin.files)[0].name 'runtime bin file'

        $runtimeRoot = @($dirs | Where-Object { $_.label -eq 'runtimeRoot' })[0]
        Assert-Equal 1 @($runtimeRoot.files).Count 'runtime root lists top-level files only'
        Assert-Equal 'hook.dat' @($runtimeRoot.files)[0].name 'runtime root file'
    }

    Invoke-Test 'runtimeBundle: missing directory is available false with an error' {
        $fx = New-Fixture 'nobin'
        Remove-Item -LiteralPath (Join-Path $fx.Install 'bin') -Recurse -Force
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        $dirs = @($r.runtimeBundle.directories)
        $installBin = @($dirs | Where-Object { $_.label -eq 'installBin' })[0]
        Assert-True (-not $installBin.available) 'not available'
        Assert-Equal 0 $installBin.fileCount 'no files'
        $codes = @($r.runtimeBundle.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'DirectoryMissing') "DirectoryMissing in errors: $($codes -join ',')"
    }

    # ---- supervisorLog ----
    Invoke-Test 'supervisorLog: exactly the last 50 lines, PEM state kept across the window edge' {
        $sl = $fullReport.supervisorLog
        Assert-True $sl.ok 'section ok'
        Assert-Equal 50 $sl.requestedLines 'requested lines'
        Assert-Equal 50 $sl.returnedLines 'returned lines'
        $lines = @($sl.lines)
        # Raw line N appears at index N-11 (window = raw lines 11..60).
        Assert-Equal '<redacted>' $lines[0] 'raw 11 sits inside the PEM opened on raw 9'
        Assert-Equal '<redacted>' $lines[1] 'raw 12 is the PEM END line'
        Assert-Equal 'token=<redacted>' $lines[4] 'raw 15'
        Assert-Equal '"password": <redacted>' $lines[19] 'raw 30'
        Assert-Equal 'rikey=<redacted>' $lines[29] 'raw 40'
        Assert-Equal 'checksum <redacted> end' $lines[34] 'raw 45'
        Assert-Equal 'authorization: <redacted>' $lines[39] 'raw 50 (header form redacts past the colon)'
        Assert-Equal 'RESULT OK' $lines[41] 'raw 52 ordinary text kept'
        Assert-Equal 'state=ready' $lines[42] 'raw 53 ordinary text kept'
        Assert-Equal 'Video stream is 3840x2160x60' $lines[43] 'raw 54 ordinary text kept'
        Assert-Equal 'ORD 60 ordinary line 60' $lines[49] 'raw 60 is the last line'
    }

    Invoke-Test 'supervisorLog: no secret material anywhere in the lines' {
        $joined = @($fullReport.supervisorLog.lines) -join "`n"
        foreach ($secret in @($secretToken, $secretRikey, $secretHex40, $secretJwt, $pemBodyRsa, $pemBodyDsa, 'hunter2')) {
            Assert-True (-not $joined.Contains([string]$secret)) "secret absent: $($secret.Substring(0, 6))..."
        }
    }

    Invoke-Test 'supervisorLog: -LogTailLines 0 returns no lines' {
        $p = New-CommonParams $fullFixture
        $p.LogTailLines = 0
        $r = @(Invoke-Diagnose $p)[0]
        Assert-Equal 0 $r.supervisorLog.returnedLines 'no lines'
        Assert-Equal 0 @($r.supervisorLog.lines).Count 'lines empty'
    }

    Invoke-Test 'supervisorLog: short log returns everything available' {
        $fx = New-Fixture 'shortlog'
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') "one`r`ntwo"
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal 2 $r.supervisorLog.returnedLines 'both lines'
        Assert-Equal 'one' @($r.supervisorLog.lines)[0] 'first line'
    }

    # ---- serverInfo ----
    Invoke-Test 'serverInfo: 200 with a free state parses state and currentgame' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 -Body $freeXml
        Assert-Equal 0 $res.Errors.Count 'no runspace errors'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True $si.ok 'section ok'
        Assert-Equal 200 $si.httpStatus 'http status'
        Assert-Equal 'OS_SERVER_FREE' $si.state 'state'
        Assert-Equal '0' $si.currentgame 'currentgame'
        Assert-True ($si.elapsedMs -ge 0) 'elapsed recorded'
        Assert-True ($null -eq $si.error) 'no error text'
    }

    Invoke-Test 'serverInfo: 200 with a busy state parses' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 -Body $busyXml
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True $si.ok 'section ok'
        Assert-Equal 'OS_SERVER_BUSY' $si.state 'state'
        Assert-Equal '258' $si.currentgame 'currentgame'
    }

    Invoke-Test 'serverInfo: HTTP 503 is a section error with the status recorded' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 503 -Body 'busy'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-Equal 503 $si.httpStatus 'http status recorded'
        Assert-True ($null -ne $si.error) 'error text present'
    }

    Invoke-Test 'serverInfo: closed port is a section error, not a throw' {
        $si = $fullReport.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-True ($null -eq $si.httpStatus) 'no http status'
        Assert-True ($null -ne $si.error) 'error text present'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'RequestFailed') "RequestFailed in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo: malformed XML is a section error' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 -Body 'this is definitely not xml <'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-Equal 200 $si.httpStatus 'http status was 200'
        Assert-True ($null -eq $si.state) 'no state parsed'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'InvalidXml') "InvalidXml in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo: server that never responds is a section error, not a throw' {
        $p = New-CommonParams $fullFixture
        $p.TimeoutSec = 1
        $res = Invoke-DiagnoseWithFakeServer -Params $p -StatusCode 200 -Body '' -HoldOpen
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-True ($null -eq $si.httpStatus) 'no http status'
        # Locale-independent: only check that an error was reported after at
        # least the timeout window, not its (localized) wording.
        Assert-True ($null -ne $si.error) 'error text present'
        Assert-True ($si.elapsedMs -ge 900) "elapsed reflects the timeout: $($si.elapsedMs) ms"
    }

    Invoke-Test 'serverInfo: non-http ServerInfoUri throws ArgumentException' {
        $base = 'powershell.exe -File usage validates parameters'
        Assert-ArgumentException {
            & $diagPath -InstallDir $fullFixture.Install -StateDir $fullFixture.State -LogDir $fullFixture.Logs `
                -ServerInfoUri 'https://127.0.0.1:47984/serverinfo' -SkipInstalledProductLookup
        } 'ServerInfoUri' "$base (https rejected)"
        Assert-ArgumentException {
            & $diagPath -InstallDir $fullFixture.Install -StateDir $fullFixture.State -LogDir $fullFixture.Logs `
                -ServerInfoUri 'not a uri' -SkipInstalledProductLookup
        } 'ServerInfoUri' "$base (unparseable rejected)"
    }

    # ---- whole-report guarantees ----
    Invoke-Test 'everything missing still produces a report with errors and exit code 0' {
        # B10: routed through the deadline-enforcing child helper, so a
        # stuck child fails the test instead of hanging the suite.
        $emptyBase = Join-Path $workDir 'empty'
        New-Item -ItemType Directory -Path $emptyBase -Force | Out-Null
        $p = @{
            InstallDir                 = (Join-Path $emptyBase 'install')
            StateDir                   = (Join-Path $emptyBase 'state')
            LogDir                     = (Join-Path $emptyBase 'logs')
            ModuleRoot                 = (Join-Path $emptyBase 'install\Modules')
            ServerInfoUri              = ('http://127.0.0.1:' + $closedPort + '/serverinfo')
            TimeoutSec                 = 2
            SupervisorTaskName         = '""'
            SkipInstalledProductLookup = $true
            SkipAclCheck               = $true
            SkipHostCheck              = $true
        }
        $child = Invoke-DiagnoseChild -Params $p -TimeoutSeconds 90
        Assert-Equal 0 $child.ExitCode 'exit code 0 with everything missing'
        $rep = $child.StdOut | ConvertFrom-Json
        Assert-Equal 1 $rep.schemaVersion 'schemaVersion'
        Assert-True (-not $rep.product.ok) 'product not ok'
        Assert-True (-not $rep.status.exists) 'status missing'
        Assert-True (@($rep.errors).Count -gt 0) 'aggregated errors present'
    }

    Invoke-Test '-AsJson emits exactly one JSON string that parses and leaks no secrets' {
        $p = New-CommonParams $fullFixture
        $p.AsJson = $true
        $out = @(Invoke-Diagnose $p)
        Assert-Equal 1 $out.Count 'exactly one output object'
        $json = [string]$out[0]
        $rep = $json | ConvertFrom-Json
        Assert-Equal 1 $rep.schemaVersion 'parsed schemaVersion'
        Assert-True ($null -ne $rep.supervisorLog) 'sections survive JSON'
        foreach ($secret in $allSecrets) {
            Assert-True (-not $json.Contains([string]$secret)) "secret absent from JSON: $($secret.Substring(0, 6))..."
        }
        Assert-True (-not $json.Contains('"password": "x"')) 'raw password pair absent'
    }

    Invoke-Test 'works via powershell.exe -File with default-derived paths overridden by params' {
        # B10: routed through the deadline-enforcing child helper.
        $p = @{
            StateDir                   = $fullFixture.State
            LogDir                     = $fullFixture.Logs
            ModuleRoot                 = (Join-Path $fullFixture.Install 'Modules')
            ServerInfoUri              = ('http://127.0.0.1:' + $closedPort + '/serverinfo')
            TimeoutSec                 = 2
            SupervisorTaskName         = '""'
            SkipInstalledProductLookup = $true
            SkipAclCheck               = $true
            SkipHostCheck              = $true
        }
        $child = Invoke-DiagnoseChild -Params $p -TimeoutSeconds 90
        Assert-Equal 0 $child.ExitCode 'child exit code'
        $rep = $child.StdOut | ConvertFrom-Json
        # InstallDir was not passed: it defaults to the script folder in the
        # body (the PS 5.1 -File param-default quirk), so the real product
        # entry in this repository is hashed.
        Assert-Equal (Split-Path -Parent $realProductEntry) $rep.paths.installDir 'InstallDir derived from script location'
        Assert-Equal $realProductEntry $rep.product.productEntryPath 'product entry path'
        Assert-Equal ((Get-FileHash -LiteralPath $realProductEntry -Algorithm SHA256).Hash.ToLowerInvariant()) $rep.product.productEntrySha256 'real entry hash'
        Assert-True (-not $rep.serverInfo.ok) 'closed-port serverinfo reported'
        Assert-True $rep.status.ok 'fixture status section ok'
    }

    # ------------------------------------------------------------------
    # Round-2 hardening (D2-1): redaction matrix, log lines.
    # ------------------------------------------------------------------
    Invoke-Test 'redaction matrix: every log-line defect case is handled' {
        $fx = New-Fixture 'matrix'
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') (Get-RedactionMatrixLogText)
        $p = New-CommonParams $fx
        $p.LogTailLines = 50
        $r = @(Invoke-Diagnose $p)[0]
        $sl = $r.supervisorLog
        Assert-True $sl.ok 'section ok'
        Assert-Equal 27 $sl.returnedLines 'all 27 lines returned'
        Assert-True (-not $sl.truncated) 'nothing truncated on a small file'
        Assert-True (-not $sl.unterminatedPem) 'PEM block closed'
        $lines = @($sl.lines)
        # PEM markers: any line with a marker is fully masked; state follows
        # the LAST marker in text order, so line 3 (END then BEGIN) leaves
        # the scan inside a block and line 4 must be masked too.
        Assert-Equal '<redacted>' $lines[0] 'BEGIN line masked'
        Assert-Equal '<redacted>' $lines[1] 'PEM body masked'
        Assert-Equal '<redacted>' $lines[2] 'END-then-BEGIN line masked, state back in block'
        Assert-Equal '<redacted>' $lines[3] 'QUJDRA== masked (still inside the block)'
        Assert-Equal '<redacted>' $lines[4] 'final END line masked, state out'
        Assert-Equal 'access_token=<redacted>' $lines[5] 'access_token'
        Assert-Equal 'client_secret=<redacted>' $lines[6] 'client_secret'
        Assert-Equal 'refresh_token=<redacted>' $lines[7] 'refresh_token'
        Assert-Equal 'x-api-key=<redacted>' $lines[8] 'x-api-key'
        Assert-Equal 'sessionid=<redacted>' $lines[9] 'sessionid'
        Assert-Equal 'Authorization: <redacted>' $lines[10] 'Authorization header form'
        Assert-Equal 'Proxy-Authorization: <redacted>' $lines[11] 'Proxy-Authorization header form'
        Assert-Equal 'Set-Cookie: <redacted>' $lines[12] 'Set-Cookie header form'
        Assert-Equal 'Cookie: <redacted>' $lines[13] 'Cookie header form'
        Assert-Equal 'X-Api-Key: <redacted>' $lines[14] 'X-Api-Key header form'
        Assert-Equal '{\"token\":<redacted>}' $lines[15] 'escaped JSON pair'
        Assert-Equal "'token': <redacted>" $lines[16] 'single-quoted JSON pair'
        Assert-Equal 'token: <redacted>' $lines[17] 'array value redacted whole'
        Assert-Equal 'pinball=1234 spinning=1234 opinion certainly' $lines[18] 'ordinary words never fire'
        Assert-Equal 'PIN <redacted>' $lines[19] 'bare PIN 1234'
        Assert-Equal 'pin: <redacted>' $lines[20] 'pin: 1234'
        Assert-Equal 'GET http://127.0.0.1:47989/x?a=1&sig=<redacted> HTTP/1.1' $lines[21] 'URL query credential parameter'
        Assert-Equal 'callback http://host/cb#access_token=<redacted> done' $lines[22] 'URL fragment credential parameter'
        Assert-Equal 'accessing C:\hex\<redacted>\path free text' $lines[23] 'long hex run redacted on a log line'
        Assert-Equal 'token=<redacted>' $lines[24] 'plain pair still works, state is out of the PEM'
        Assert-Equal 'certificate=<redacted> credential=<redacted> api-key=<redacted> private-key=<redacted> rikeyid=<redacted>' $lines[25] 'longer key names'
        Assert-Equal 'ORD ordinary line untouched' $lines[26] 'ordinary line kept'
        $joined = $lines -join "`n"
        Assert-True (-not $joined.Contains('S3cr3t')) 'no S3cr3t anywhere in the tail'
        Assert-True (-not $joined.Contains($secretHex40)) 'no long hex secret in the tail'
    }

    # ------------------------------------------------------------------
    # Round-3 hardening (D2b-1): credential headers and auth schemes that
    # are NOT at the start of the line. Four leak repro lines (mid-line
    # headers, a quoted header value, a Basic token below the 32-character
    # long-token threshold), the two timestamped lines that already worked
    # through the pair rule, prose that must never change, a mid-sentence
    # and a bare scheme + token.
    # ------------------------------------------------------------------
    $round3Secrets = @('S3cr3t', 'eyJ', 'QWxhZGRpbjpTM2NyM3Q')
    $round3Lines = @(
        '2026-10-31 10:00:02 Authorization: Bearer eyJS3cr3t',          # 0 timestamped header
        '[INFO] request header Authorization: Bearer eyJS3cr3t',        # 1 log-prefixed header
        'proxy said Proxy-Authorization: Basic QWxhZGRpbjpTM2NyM3Q=',   # 2 short Basic token
        'curl -H "Authorization: Bearer eyJS3cr3t" http://x',           # 3 quoted header in a command
        '2026-10-31 10:00:02 Cookie: a=1; sid=S3cr3t',                  # 4 already fine via the pair rule
        '2026-10-31 10:00:02 X-Api-Key: S3cr3t',                        # 5 already fine via the pair rule
        'basic setup done and Digest authentication fine',              # 6 prose must not change
        'tried Bearer eyJS3cr3t against the api',                       # 7 mid-sentence scheme + token
        'Bearer eyJS3cr3t'                                              # 8 bare scheme + token
    )
    $round3Expected = @(
        '2026-10-31 10:00:02 Authorization: <redacted>',
        '[INFO] request header Authorization: <redacted>',
        'proxy said Proxy-Authorization: <redacted>',
        'curl -H "Authorization: <redacted>" http://x',
        '2026-10-31 10:00:02 Cookie: <redacted>',
        '2026-10-31 10:00:02 X-Api-Key: <redacted>',
        'basic setup done and Digest authentication fine',
        'tried Bearer <redacted> against the api',
        'Bearer <redacted>'
    )

    Invoke-Test 'redaction round-3 (D2b-1): mid-line headers and auth schemes on the free-text path' {
        $fx = New-Fixture 'round3free'
        $status = [ordered]@{ state = 'ready'; lastError = ($round3Lines -join "`n") }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        $got = @([System.Text.RegularExpressions.Regex]::Split([string]$r.status.lastError, "`n"))
        Assert-Equal $round3Expected.Count $got.Count 'line count preserved'
        for ($i = 0; $i -lt $round3Expected.Count; $i++) {
            Assert-Equal $round3Expected[$i] $got[$i] ("free-text line ${i} for: " + $round3Lines[$i])
        }
        Assert-True ($got[3].EndsWith(' http://x')) 'closing quote and the text after it are kept'
        $joined = $got -join "`n"
        foreach ($s in $round3Secrets) {
            Assert-True (-not $joined.Contains($s)) "free text leaks: $s"
        }
    }

    Invoke-Test 'redaction round-3 (D2b-1): mid-line headers and auth schemes on the supervisor log path' {
        $fx = New-Fixture 'round3log'
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') (($round3Lines -join "`r`n") + "`r`n")
        $p = New-CommonParams $fx
        $p.LogTailLines = 20
        $r = @(Invoke-Diagnose $p)[0]
        $sl = $r.supervisorLog
        Assert-True $sl.ok 'section ok'
        Assert-Equal $round3Lines.Count $sl.returnedLines 'all lines returned'
        $lines = @($sl.lines)
        for ($i = 0; $i -lt $round3Expected.Count; $i++) {
            Assert-Equal $round3Expected[$i] $lines[$i] ("log line ${i} for: " + $round3Lines[$i])
        }
        Assert-True ($lines[3].EndsWith(' http://x')) 'closing quote and the text after it are kept'
        $joined = $lines -join "`n"
        foreach ($s in $round3Secrets) {
            Assert-True (-not $joined.Contains($s)) "supervisor log leaks: $s"
        }
    }

    Invoke-Test 'redaction round-3 (D2b-1): -AsJson end-to-end keeps mid-line header secrets out of the report' {
        $fx = New-Fixture 'round3json'
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') (($round3Lines -join "`r`n") + "`r`n")
        $p = New-CommonParams $fx
        $p.LogTailLines = 20
        $child = Invoke-DiagnoseChild -Params $p -TimeoutSeconds 90
        Assert-Equal 0 $child.ExitCode 'child exit code 0'
        foreach ($s in $round3Secrets) {
            Assert-True (-not $child.StdOut.Contains($s)) "JSON report leaks: $s"
        }
        $rep = $child.StdOut | ConvertFrom-Json
        $lines = @($rep.supervisorLog.lines)
        Assert-Equal $round3Lines.Count $lines.Count 'all lines through JSON'
        Assert-Equal 'curl -H "Authorization: <redacted>" http://x' $lines[3] 'quoted header line through JSON'
    }

    Invoke-Test 'redaction round-3 (D2b-1): header-name left boundary (xauthorization / my-cookie are not headers)' {
        $fx = New-Fixture 'round3boundary'
        $status = [ordered]@{ state = 'ready'; lastError = 'xauthorization: S3cr3t my-cookie: S3cr3t' }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal 'xauthorization: S3cr3t my-cookie: <redacted>' $r.status.lastError 'longer words are not headers; my-cookie still caught by the pair rule'
    }

    # ---- D2-1/D2-2: free-text (status fields) redaction ----
    Invoke-Test 'status free text: multi-line PEM with unterminated BEGIN masks to the end' {
        $fx = New-Fixture 'freetextpem'
        $lastError = "line1 access_token=S3cr3t`n-----BEGIN PRIVATE KEY-----`nQUJDRA==`nunterminated keeps S3cr3t"
        $status = [ordered]@{ state = 'ready'; lastError = $lastError }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        $expected = "line1 access_token=<redacted>`n<redacted>`n<redacted>`n<redacted>"
        Assert-Equal $expected $r.status.lastError 'multi-line PEM state applied to free text'
    }

    Invoke-Test 'status free text: terminated PEM block redacts across lines' {
        $fx = New-Fixture 'freetextpem2'
        $lastError = "a`n-----BEGIN X-----`nbody`n-----END X-----`nafter token=S3cr3t"
        $status = [ordered]@{ state = 'ready'; lastError = $lastError }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        $expected = "a`n<redacted>`n<redacted>`n<redacted>`nafter token=<redacted>"
        Assert-Equal $expected $r.status.lastError 'terminated block redacts, following lines recover'
    }

    Invoke-Test 'status free text: long hex path survives (long-token rule is log-line only)' {
        $fx = New-Fixture 'freethex'
        $lastError = ('C:\hex\' + $secretHex40 + '\path')
        $status = [ordered]@{ state = 'ready'; lastError = $lastError }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal $lastError $r.status.lastError 'free-text long hex untouched'
    }

    # ---- D2-3: outside strings are redacted/validated before the report ----
    Invoke-Test 'D2-3 leak test: poisoned inputs never reach the JSON report' {
        $fx = New-Fixture 'poison'
        Write-Utf8File (Join-Path $fx.Install 'Modules\GsControl\GsControl.psd1') (Get-FakePsd1Text '9.9.1 token=FAKEVER1')
        $config = [ordered]@{
            schemaVersion      = 1
            installDir         = ($fx.Install + ' token=FAKERC1')
            stateDir           = ($fx.State + ' password=FAKERC2')
            logDir             = ($fx.Logs + ' pin=FAKERC3')
            componentSourceDir = ($fx.ComponentSource + ' passwd=FAKERC4')
        }
        Write-Utf8File (Join-Path $fx.State 'runtime-config.json') ($config | ConvertTo-Json)
        $status = [ordered]@{ state = 'ready'; runId = 'run-1 sessionid=FAKERUN1'; lastError = 'password=FAKELE1' }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') "hello token=FAKESL1`r`n"
        $p = New-CommonParams $fx
        $res = Invoke-DiagnoseWithFakeServer -Params $p -StatusCode 200 `
            -Body '<root status_code="200"><state>OS_SERVER_FREE sid=FAKESI1</state><currentgame>7</currentgame></root>' `
            -UserInfo 'FAKEU1:FAKEP1'
        $json = [string]$res.Output[0]
        $rep = $json | ConvertFrom-Json
        foreach ($s in @('FAKEVER1', 'FAKERC1', 'FAKERC2', 'FAKERC3', 'FAKERC4', 'FAKERUN1', 'FAKELE1', 'FAKESI1', 'FAKESL1', 'FAKEU1', 'FAKEP1')) {
            Assert-True (-not $json.Contains($s)) "poison absent from JSON: $s"
        }
        Assert-Equal '9.9.1 token=<redacted>' (@($rep.product.modules)[0].version) 'ModuleVersion redacted but present'
        Assert-Equal ('ready') $rep.status.state 'status state kept'
        Assert-Equal 'run-1 sessionid=<redacted>' $rep.status.runId 'runId redacted but present'
        Assert-Equal 'OS_SERVER_FREE sid=<redacted>' $rep.serverInfo.state 'serverinfo state redacted but present'
        Assert-Equal ('http://127.0.0.1:' + $res.Port + '/serverinfo') $rep.serverInfo.uri 'uri is a display URI without userinfo or query'
        Assert-Equal '7' $rep.serverInfo.currentgame 'valid currentgame kept'
    }

    # ---- D2-4: serverinfo validity ----
    Invoke-Test 'serverInfo: 302 is UnexpectedStatus with the raw status kept' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) `
            -StatusLine 'HTTP/1.1 302 Found' -ExtraHeaders @('Location: http://127.0.0.1:9/moved') -Body ''
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-Equal 302 $si.httpStatus 'raw status kept'
        Assert-True ($null -eq $si.state) 'no state'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'UnexpectedStatus') "UnexpectedStatus in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo: 204 is UnexpectedStatus' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) `
            -StatusLine 'HTTP/1.1 204 No Content' -Body ''
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-Equal 204 $si.httpStatus 'raw status kept'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'UnexpectedStatus') "UnexpectedStatus in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo: 200 with an empty body is EmptyBody' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 -Body ''
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-Equal 200 $si.httpStatus 'status 200'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'EmptyBody') "EmptyBody in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo: unexpected root element is UnexpectedRoot' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<other status_code="200"><state>ok</state><currentgame>1</currentgame></other>'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'UnexpectedRoot') "UnexpectedRoot in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo: missing status_code attribute is MissingField' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<root><state>ok</state><currentgame>1</currentgame></root>'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $codes = @($rep.serverInfo.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'MissingField') "MissingField in errors: $($codes -join ',')"
        Assert-True (-not $rep.serverInfo.ok) 'section not ok'
    }

    Invoke-Test 'serverInfo: non-200 status_code attribute is ProtocolStatus' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<root status_code="302"><state>ok</state><currentgame>1</currentgame></root>'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $codes = @($rep.serverInfo.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'ProtocolStatus') "ProtocolStatus in errors: $($codes -join ',')"
        Assert-True (-not $rep.serverInfo.ok) 'section not ok'
    }

    Invoke-Test 'serverInfo: empty state is InvalidField' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<root status_code="200"><state></state><currentgame>1</currentgame></root>'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $codes = @($rep.serverInfo.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'InvalidField') "InvalidField in errors: $($codes -join ',')"
        Assert-True (-not $rep.serverInfo.ok) 'section not ok'
    }

    Invoke-Test 'serverInfo: missing currentgame element is MissingField' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<root status_code="200"><state>ok</state></root>'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $codes = @($rep.serverInfo.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'MissingField') "MissingField in errors: $($codes -join ',')"
        Assert-True (-not $rep.serverInfo.ok) 'section not ok'
    }

    Invoke-Test 'serverInfo: non-numeric currentgame is dropped with InvalidField' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<root status_code="200"><state>ok</state><currentgame>S3cr3t</currentgame></root>'
        $json = [string]$res.Output[0]
        $rep = $json | ConvertFrom-Json
        Assert-True (-not $rep.serverInfo.ok) 'section not ok'
        Assert-True ($null -eq $rep.serverInfo.currentgame) 'currentgame is null'
        $codes = @($rep.serverInfo.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'InvalidField') "InvalidField in errors: $($codes -join ',')"
        Assert-True (-not $json.Contains('S3cr3t')) 'poisoned currentgame never reaches JSON'
    }

    # ---- D2-5: serverinfo bounds ----
    Invoke-Test 'serverInfo: oversized body (> 64 KB) is BodyTooLarge' {
        $writer = {
            param($stream, $client)
            $header = "HTTP/1.1 200 OK`r`nContent-Type: text/xml`r`nContent-Length: 1000000`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
            $stream.Write($hb, 0, $hb.Length)
            $chunk = New-Object byte[] 65536
            try {
                $stream.Write($chunk, 0, $chunk.Length)
                $stream.Write($chunk, 0, $chunk.Length)
                $stream.Flush()
            } catch { }
            Start-Sleep -Milliseconds 300
        }
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -RawWriter $writer
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-Equal 200 $si.httpStatus 'status was 200'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'BodyTooLarge') "BodyTooLarge in errors: $($codes -join ',')"
        Assert-True ($si.elapsedMs -le 2500) "returned promptly: $($si.elapsedMs) ms"
    }

    Invoke-Test 'serverInfo: trickling body hits the total deadline and the section returns' {
        $writer = {
            param($stream, $client)
            $header = "HTTP/1.1 200 OK`r`nContent-Type: text/xml`r`nContent-Length: 1000000`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
            try {
                $stream.Write($hb, 0, $hb.Length)
                $stream.Flush()
            } catch { return }
            $one = [System.Text.Encoding]::ASCII.GetBytes('x')
            for ($i = 0; $i -lt 40; $i++) {
                try {
                    $stream.Write($one, 0, 1)
                    $stream.Flush()
                } catch { return }
                Start-Sleep -Milliseconds 200
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -RawWriter $writer
        $sw.Stop()
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-Equal 200 $si.httpStatus 'status was 200'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'Timeout') "Timeout in errors: $($codes -join ',')"
        Assert-True ($si.elapsedMs -le 3500) "section returned within TimeoutSec + 1.5s: $($si.elapsedMs) ms"
        Assert-True ($sw.ElapsedMilliseconds -lt 15000) "whole call returned without hanging: $($sw.ElapsedMilliseconds) ms"
    }

    # ---- D2-6: supervisor log reading ----
    Invoke-Test 'supervisorLog: -LogTailLines 0 never opens the file (exclusive lock held)' {
        $fx = New-Fixture 'tail0lock'
        $logPath = Join-Path $fx.State 'runtime\bin\_supervisor.log'
        $lock = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            $p = New-CommonParams $fx
            $p.LogTailLines = 0
            $r = @(Invoke-Diagnose $p)[0]
            $sl = $r.supervisorLog
            Assert-Equal 0 $sl.returnedLines 'no lines'
            Assert-Equal 0 $sl.scannedBytes 'nothing scanned'
            Assert-True ($sl.ok) 'section ok without opening the file'
            $codes = @($sl.errors | ForEach-Object { $_.code })
            Assert-True ($codes -notcontains 'ReadFailed') "no ReadFailed despite the exclusive lock: $($codes -join ',')"
            Assert-True (-not $sl.truncated) 'not truncated'
            Assert-True (-not $sl.incomplete) 'not incomplete'
        } finally { $lock.Dispose() }
    }

    Invoke-Test 'supervisorLog: 20 MB log, secrets near the end, byte-capped scan (child process, hard deadline)' {
        $fx = New-Fixture 'biglog'
        $logPath = Join-Path $fx.State 'runtime\bin\_supervisor.log'
        $pad = ('x' * 4300)
        $writer = New-Object System.IO.StreamWriter($logPath, $false, $utf8)
        try {
            for ($i = 1; $i -le 4900; $i++) { $writer.WriteLine(('ORD ' + $i + ' ' + $pad)) }
            $writer.WriteLine('-----BEGIN PRIVATE KEY-----')
            $writer.WriteLine($pemBodyRsa)
            $writer.WriteLine('-----END PRIVATE KEY-----')
            for ($i = 4901; $i -le 4990; $i++) { $writer.WriteLine(('ORD ' + $i + ' ' + $pad)) }
            $writer.WriteLine('token=FAKEBIG1')
            $writer.WriteLine('password=FAKEBIG2')
            $writer.WriteLine('TAIL-02 second to last')
            $writer.WriteLine('TAIL-01 final line')
        } finally { $writer.Dispose() }
        Assert-True ((Get-Item -LiteralPath $logPath).Length -ge 20MB) 'fixture is at least 20 MB'

        $p = New-CommonParams $fx
        $p.LogTailLines = 20
        # Generous total-time budget for the 8 MB scan on slow disks; the
        # serverinfo endpoint refuses instantly, so this adds no wall time.
        $p.TimeoutSec = 30
        $child = Invoke-DiagnoseChild -Params $p -TimeoutSeconds 90
        Assert-Equal 0 $child.ExitCode 'child exit code 0'
        $rep = $child.StdOut | ConvertFrom-Json
        $sl = $rep.supervisorLog
        Assert-True $sl.truncated 'truncated true (scan started mid-file)'
        Assert-True ($sl.scannedBytes -le 8388608) "scannedBytes within the 8 MB cap: $($sl.scannedBytes)"
        Assert-True ($sl.scannedBytes -gt 0) 'scannedBytes positive'
        Assert-Equal 20 $sl.returnedLines 'last 20 lines returned'
        Assert-True (-not $sl.incomplete) 'not incomplete'
        Assert-True (-not $sl.unterminatedPem) 'PEM block closed before the tail'
        $lines = @($sl.lines)
        Assert-Equal 'TAIL-01 final line' $lines[19] 'final line correct'
        Assert-Equal 'TAIL-02 second to last' $lines[18] 'second to last correct'
        Assert-Equal 'token=<redacted>' $lines[16] 'secret line near the end redacted'
        Assert-Equal 'password=<redacted>' $lines[17] 'second secret line redacted'
        $json = $child.StdOut
        foreach ($s in @('FAKEBIG1', 'FAKEBIG2', $pemBodyRsa)) {
            Assert-True (-not $json.Contains([string]$s)) "secret absent from JSON: ..."
        }
    }

    Invoke-Test 'supervisorLog: 1 MB newline-free line is capped, never held whole (child process, hard deadline)' {
        $fx = New-Fixture 'oneline'
        $logPath = Join-Path $fx.State 'runtime\bin\_supervisor.log'
        [System.IO.File]::WriteAllText($logPath, ('START token=S3cr3t ' + ('A' * 1048576)), $utf8)
        $p = New-CommonParams $fx
        $p.LogTailLines = 5
        $p.TimeoutSec = 30
        $child = Invoke-DiagnoseChild -Params $p -TimeoutSeconds 60
        Assert-Equal 0 $child.ExitCode 'child exit code 0'
        $rep = $child.StdOut | ConvertFrom-Json
        $sl = $rep.supervisorLog
        Assert-True $sl.ok 'section ok'
        Assert-Equal 1 $sl.returnedLines 'single line returned'
        $lines = @($sl.lines)
        Assert-True ($lines[0].Length -le 2048) "line capped at 2048 chars: $($lines[0].Length)"
        # D3-2: any line over the raw cap is now the placeholder, redacted
        # wholesale, instead of a truncated redacted prefix.
        Assert-Equal '<redacted: long line truncated>' $lines[0] 'line over the raw cap is the long-line placeholder'
        Assert-True (-not $child.StdOut.Contains('S3cr3t')) 'secret absent from JSON'
    }

    Invoke-Test 'supervisorLog: concurrent writer during the read completes without error' {
        $fx = New-Fixture 'writer'
        $logPath = Join-Path $fx.State 'runtime\bin\_supervisor.log'
        $sb = New-Object System.Text.StringBuilder
        $pad = ('y' * 4000)
        for ($i = 1; $i -le 1500; $i++) { $null = $sb.AppendLine(('BASE ' + $i + ' ' + $pad)) }
        [System.IO.File]::WriteAllText($logPath, $sb.ToString(), $utf8)
        $writerPs = [powershell]::Create()
        try {
            $null = $writerPs.AddScript({
                param($AppendedPath)
                $w = New-Object System.IO.StreamWriter($AppendedPath, $true, [System.Text.Encoding]::UTF8)
                try {
                    for ($i = 1; $i -le 40; $i++) {
                        $w.WriteLine(('APP ' + $i + ' appended line'))
                        $w.Flush()
                        Start-Sleep -Milliseconds 50
                    }
                } finally { $w.Dispose() }
            })
            $null = $writerPs.AddParameter('AppendedPath', $logPath)
            $wHandle = $writerPs.BeginInvoke()
            try {
                $p = New-CommonParams $fx
                $p.LogTailLines = 10
                $p.TimeoutSec = 10
                $p.AsJson = $true
                $diagPs = [powershell]::Create()
                try {
                    $null = $diagPs.AddScript('param($ScriptPath, $Params) & $ScriptPath @Params')
                    $null = $diagPs.AddParameter('ScriptPath', $diagPath)
                    $null = $diagPs.AddParameter('Params', $p)
                    $handle = $diagPs.BeginInvoke()
                    $finishBy = [DateTime]::UtcNow.AddSeconds(60)
                    $done = $false
                    while ([DateTime]::UtcNow -lt $finishBy) {
                        if ($handle.AsyncWaitHandle.WaitOne(250)) { $done = $true; break }
                    }
                    if (-not $done) {
                        try { $diagPs.Stop() } catch { }
                        throw 'diagnose exceeded its 60s hard deadline while a writer was appending'
                    }
                    $out = @($diagPs.EndInvoke($handle))
                    $rep = ([string]$out[0]) | ConvertFrom-Json
                    $sl = $rep.supervisorLog
                    $codes = @($sl.errors | ForEach-Object { $_.code })
                    Assert-True ($codes -notcontains 'ReadFailed') "no read error while a writer appends: $($codes -join ',')"
                    Assert-True ($sl.returnedLines -ge 1) "lines returned: $($sl.returnedLines)"
                    Assert-True ($sl.ok) 'section ok'
                } finally { $diagPs.Dispose() }
            } finally {
                try { $writerPs.Stop() } catch { }
            }
        } finally { $writerPs.Dispose() }
    }

    Invoke-Test 'supervisorLog: log file can be renamed while the read handle is open' {
        $fx = New-Fixture 'rename'
        $logPath = Join-Path $fx.State 'runtime\bin\_supervisor.log'
        $renamedPath = $logPath + '.moved'
        $sb = New-Object System.Text.StringBuilder
        $pad = ('z' * 4000)
        for ($i = 1; $i -le 2000; $i++) { $null = $sb.AppendLine(('REN ' + $i + ' ' + $pad)) }
        [System.IO.File]::WriteAllText($logPath, $sb.ToString(), $utf8)
        $p = New-CommonParams $fx
        $p.LogTailLines = 10
        $p.TimeoutSec = 10
        $p.AsJson = $true
        $diagPs = [powershell]::Create()
        try {
            $null = $diagPs.AddScript('param($ScriptPath, $Params) & $ScriptPath @Params')
            $null = $diagPs.AddParameter('ScriptPath', $diagPath)
            $null = $diagPs.AddParameter('Params', $p)
            $handle = $diagPs.BeginInvoke()
            # Wait until diagnose actually holds the log open: an exclusive
            # open succeeds only while no other handle exists, so a sharing
            # violation proves diagnose is mid-read. Renaming an open file
            # succeeds only when every open handle specified FileShare Delete.
            $probeOpened = $false
            $probeDeadline = [DateTime]::UtcNow.AddSeconds(30)
            while ([DateTime]::UtcNow -lt $probeDeadline) {
                $probe = $null
                try {
                    $probe = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                    $probe.Dispose()
                    Start-Sleep -Milliseconds 25
                } catch {
                    $probeOpened = $true
                    break
                }
            }
            if (-not $probeOpened) {
                try { $diagPs.Stop() } catch { }
                throw 'diagnose never opened the supervisor log within 30s'
            }
            $moveError = $null
            try { [System.IO.File]::Move($logPath, $renamedPath) } catch { $moveError = $_.Exception.Message }
            $finishBy = [DateTime]::UtcNow.AddSeconds(60)
            $done = $false
            while ([DateTime]::UtcNow -lt $finishBy) {
                if ($handle.AsyncWaitHandle.WaitOne(250)) { $done = $true; break }
            }
            if (-not $done) {
                try { $diagPs.Stop() } catch { }
                throw 'diagnose exceeded its 60s hard deadline during the rename test'
            }
            Assert-True ($null -eq $moveError) "rename during read failed: $moveError"
            Assert-True (-not (Test-Path -LiteralPath $logPath)) 'original name gone after rename'
            $out = @($diagPs.EndInvoke($handle))
            $rep = ([string]$out[0]) | ConvertFrom-Json
            $sl = $rep.supervisorLog
            $codes = @($sl.errors | ForEach-Object { $_.code })
            Assert-True ($codes -notcontains 'ReadFailed') "no sharing violation: $($codes -join ',')"
            Assert-Equal 10 $sl.returnedLines 'tail lines returned despite the rename'
            Assert-True ($sl.ok) 'section ok'
        } finally {
            try { $diagPs.Dispose() } catch { }
            if (Test-Path -LiteralPath $renamedPath) { Remove-Item -LiteralPath $renamedPath -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-Test 'supervisorLog: byte-capped scan masks from the skipped boundary until the first END' {
        $fx = New-Fixture 'midskip'
        $bigLine = ('q' * 5000)
        $text = $bigLine + "`r`n" + 'QUJDRA== body before any END' + "`r`n" + '-----END PRIVATE KEY-----' + "`r`n" + 'token=S3cr3t' + "`r`n" + 'plain tail'
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') $text
        $p = New-CommonParams $fx
        $p.LogTailLines = 10
        $p.LogScanMaxBytes = 1024
        $r = @(Invoke-Diagnose $p)[0]
        $sl = $r.supervisorLog
        Assert-True $sl.truncated 'truncated true (started mid-file)'
        Assert-True ($sl.scannedBytes -le 1024) "scannedBytes within the cap: $($sl.scannedBytes)"
        $lines = @($sl.lines)
        Assert-Equal '<redacted>' $lines[0] 'unknown PEM state masks until the first END'
        Assert-Equal '<redacted>' $lines[1] 'END line masked'
        Assert-Equal 'token=<redacted>' $lines[2] 'state out after END'
        Assert-Equal 'plain tail' $lines[3] 'ordinary line after END'
        Assert-True (-not $sl.unterminatedPem) 'PEM state resolved by the END marker'
    }

    Invoke-Test 'supervisorLog: unterminated PEM at end of log reports unterminatedPem' {
        $fx = New-Fixture 'untpem'
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') "ok line`r`n-----BEGIN PRIVATE KEY-----`r`nQUJDRA=="
        $p = New-CommonParams $fx
        $p.LogTailLines = 10
        $r = @(Invoke-Diagnose $p)[0]
        $sl = $r.supervisorLog
        Assert-True $sl.unterminatedPem 'unterminatedPem true'
        $lines = @($sl.lines)
        Assert-Equal 'ok line' $lines[0] 'line before the block kept'
        Assert-Equal '<redacted>' $lines[1] 'BEGIN line masked'
        Assert-Equal '<redacted>' $lines[2] 'body masked'
        Assert-True (-not ((@($sl.lines) -join "`n")).Contains('QUJDRA==')) 'PEM body absent'
    }

    # ---- D2-7: paths ----
    Invoke-Test 'paths on a missing drive produce a report with section errors and exit 0' {
        $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
        $letter = $null
        foreach ($c in @('D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
            if ($used -notcontains $c) { $letter = $c; break }
        }
        if ($null -eq $letter) { throw 'no free drive letter available for the test' }
        $missingInstall = ($letter + ':\GsDiagnoseMissingInstall')
        $missingState = ($letter + ':\GsDiagnoseMissingState')
        $p = New-CommonParams $fullFixture
        $p.InstallDir = $missingInstall
        $p.StateDir = $missingState
        # String concatenation here: Join-Path would itself throw
        # DriveNotFoundException on the missing drive before the script runs.
        $p.ModuleRoot = ($missingInstall + '\Modules')
        $r = @(Invoke-Diagnose $p)[0]
        Assert-Equal 0 $LASTEXITCODE 'exit code 0'
        Assert-Equal $missingState $r.paths.stateDir 'normalized state path (no drive access at resolution)'
        Assert-True (-not $r.product.ok) 'product section not ok'
        $productCodes = @($r.product.errors | ForEach-Object { $_.code })
        Assert-True ($productCodes -contains 'FileNotFound') "FileNotFound in product errors: $($productCodes -join ',')"
        Assert-True (-not $r.runtimeConfig.ok) 'runtimeConfig not ok'
        Assert-True (-not $r.status.ok) 'status not ok'
        Assert-True (@($r.errors).Count -gt 0) 'aggregated errors present'
    }

    Invoke-Test 'relative StateDir resolves against the process current directory' {
        $oldCwd = [System.Environment]::CurrentDirectory
        $relBase = Join-Path $workDir 'relbase'
        New-Item -ItemType Directory -Path $relBase -Force | Out-Null
        try {
            [System.Environment]::CurrentDirectory = $relBase
            $fx = New-Fixture 'relstate'
            $p = New-CommonParams $fx
            $p.StateDir = 'relstate'
            $r = @(Invoke-Diagnose $p)[0]
            $expected = [System.IO.Path]::GetFullPath('relstate')
            Assert-Equal $expected $r.paths.stateDir 'stateDir resolved against [Environment]::CurrentDirectory'
            Assert-True ([System.IO.Path]::IsPathRooted($r.paths.stateDir)) 'resulting path is rooted'
            Assert-Equal 0 $LASTEXITCODE 'exit code 0'
        } finally {
            [System.Environment]::CurrentDirectory = $oldCwd
        }
    }

    Invoke-Test 'paths with illegal characters throw ArgumentException naming the parameter' {
        $base = 'documented parameter error for illegal path characters'
        Assert-ArgumentException {
            & $diagPath -InstallDir 'C:\bad|path' -StateDir $fullFixture.State -LogDir $fullFixture.Logs `
                -ModuleRoot (Join-Path $fullFixture.Install 'Modules') -SkipInstalledProductLookup
        } 'InstallDir' "$base (InstallDir)"
        Assert-ArgumentException {
            & $diagPath -InstallDir $fullFixture.Install -StateDir 'C:\bad<state' -LogDir $fullFixture.Logs `
                -ModuleRoot (Join-Path $fullFixture.Install 'Modules') -SkipInstalledProductLookup
        } 'StateDir' "$base (StateDir)"
        Assert-ArgumentException {
            & $diagPath -InstallDir $fullFixture.Install -StateDir $fullFixture.State -LogDir 'C:\bad>logs' `
                -ModuleRoot (Join-Path $fullFixture.Install 'Modules') -SkipInstalledProductLookup
        } 'LogDir' "$base (LogDir)"
        Assert-ArgumentException {
            & $diagPath -InstallDir $fullFixture.Install -StateDir $fullFixture.State -LogDir $fullFixture.Logs `
                -ModuleRoot 'C:\bad"modules' -SkipInstalledProductLookup
        } 'ModuleRoot' "$base (ModuleRoot)"
    }

    # ---- D2-8: documented running semantics ----
    Invoke-Test 'D2-8: script header and release manifest document the running caveat' {
        $scriptText = [System.IO.File]::ReadAllText($diagPath)
        Assert-True ($scriptText -match 'recorded PID') 'gs-diagnose.ps1 header says running means the recorded PID exists'
        Assert-True ($scriptText -match 'reused') 'gs-diagnose.ps1 header mentions PID reuse'
        $manifestPath = Join-Path $repoRoot 'docs\release-manifest.md'
        $manifestText = [System.IO.File]::ReadAllText($manifestPath)
        Assert-True ($manifestText -match 'recorded PID') 'release-manifest.md says running means the recorded PID exists'
        Assert-True ($manifestText -match 'reused') 'release-manifest.md mentions PID reuse'
    }
    # ------------------------------------------------------------------
    # Round-4 hardening (D3-1): redaction leaks. Four reproduced strings
    # (scheme token of pure letters, nested JSON array value, escaped quote
    # inside a quoted header value, credential key waiting for its value on
    # the next line) plus the prose that must stay untouched.
    # ------------------------------------------------------------------
    $d31Repros = @(
        'auth failed: Bearer abcdefghijklmnop',
        'tokens=[["abc123"],"def456"]',
        'curl -H "Cookie: sid=\"abc123\"; other=def456"',
        'token='
    )
    $d31NextLineSecret = 'S3cr3tOnNextLine'
    $d31Joined = (($d31Repros -join "`n") + "`n" + $d31NextLineSecret)
    $d31Expected = @(
        'auth failed: Bearer <redacted>',
        'tokens=<redacted>',
        'curl -H "Cookie: <redacted>"',
        'token=',
        '<redacted>'
    )
    $d31Secrets = @('abcdefghijklmnop', 'abc123', 'def456', 'S3cr3tOnNextLine')

    Invoke-Test 'redaction round-4 (D3-1): repro strings on the free-text path' {
        $fx = New-Fixture 'd31free'
        $status = [ordered]@{ state = 'ready'; lastError = $d31Joined }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        $got = @([System.Text.RegularExpressions.Regex]::Split([string]$r.status.lastError, "`n"))
        Assert-Equal $d31Expected.Count $got.Count 'line count preserved'
        for ($i = 0; $i -lt $d31Expected.Count; $i++) {
            Assert-Equal $d31Expected[$i] $got[$i] ("free-text line ${i}")
        }
        $joined = $got -join "`n"
        foreach ($s in $d31Secrets) {
            Assert-True (-not $joined.Contains($s)) "free text leaks: $s"
        }
    }

    Invoke-Test 'redaction round-4 (D3-1): repro strings on the supervisor log path' {
        $fx = New-Fixture 'd31log'
        $logLines = @($d31Repros + $d31NextLineSecret)
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') (($logLines -join "`r`n") + "`r`n")
        $p = New-CommonParams $fx
        $p.LogTailLines = 20
        $r = @(Invoke-Diagnose $p)[0]
        $sl = $r.supervisorLog
        Assert-True $sl.ok 'section ok'
        Assert-Equal $logLines.Count $sl.returnedLines 'all lines returned'
        $lines = @($sl.lines)
        for ($i = 0; $i -lt $d31Expected.Count; $i++) {
            Assert-Equal $d31Expected[$i] $lines[$i] ("log line ${i} for: " + $logLines[$i])
        }
        $joined = $lines -join "`n"
        foreach ($s in $d31Secrets) {
            Assert-True (-not $joined.Contains($s)) "supervisor log leaks: $s"
        }
    }

    Invoke-Test 'redaction round-4 (D3-1): prose keep-unchanged list under the new scheme rule' {
        $fx = New-Fixture 'd31keep'
        $keepLines = @('basic setup done', 'negotiate later', 'bearer of bad news', 'pinball=1234')
        $status = [ordered]@{ state = 'ready'; lastError = ($keepLines -join "`n") }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal ($keepLines -join "`n") $r.status.lastError 'prose untouched by the scheme rules'
    }

    Invoke-Test 'redaction round-4 (D3-1): YAML-style pair masks the next line; blank lines keep the state' {
        $fx = New-Fixture 'd31yaml'
        $yaml = "db:`n  password:`n    S3cr3t"
        $status = [ordered]@{ state = 'ready'; lastError = $yaml }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        Assert-Equal "db:`n  password:`n<redacted>" $r.status.lastError 'YAML value line masked whole'
        $fx2 = New-Fixture 'd31blank'
        $blanked = "token=`n`nS3cr3t after a blank line"
        $status2 = [ordered]@{ state = 'ready'; lastError = $blanked }
        Write-Utf8File (Join-Path $fx2.State 'runtime\state\status.json') ($status2 | ConvertTo-Json)
        $r2 = @(Invoke-Diagnose (New-CommonParams $fx2))[0]
        Assert-Equal "token=`n`n<redacted>" $r2.status.lastError 'blank line does not clear the pending state'
    }

    Invoke-Test 'redaction round-4 (D3-1): -AsJson end-to-end keeps the repro secrets out of the report' {
        $fx = New-Fixture 'd31json'
        $status = [ordered]@{ state = 'ready'; lastError = $d31Joined }
        Write-Utf8File (Join-Path $fx.State 'runtime\state\status.json') ($status | ConvertTo-Json)
        $logLines = @($d31Repros + $d31NextLineSecret)
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') (($logLines -join "`r`n") + "`r`n")
        $p = New-CommonParams $fx
        $p.LogTailLines = 20
        $child = Invoke-DiagnoseChild -Params $p -TimeoutSeconds 90
        Assert-Equal 0 $child.ExitCode 'child exit code 0'
        foreach ($s in $d31Secrets) {
            Assert-True (-not $child.StdOut.Contains($s)) "JSON report leaks: $s"
        }
        $rep = $child.StdOut | ConvertFrom-Json
        $gotStatus = @([System.Text.RegularExpressions.Regex]::Split([string]$rep.status.lastError, "`n"))
        Assert-Equal $d31Expected.Count $gotStatus.Count 'status line count through JSON'
        for ($i = 0; $i -lt $d31Expected.Count; $i++) {
            Assert-Equal $d31Expected[$i] $gotStatus[$i] ("status line ${i} through JSON")
        }
        $lines = @($rep.supervisorLog.lines)
        Assert-Equal $logLines.Count $lines.Count 'log line count through JSON'
        for ($i = 0; $i -lt $d31Expected.Count; $i++) {
            Assert-Equal $d31Expected[$i] $lines[$i] ("log line ${i} through JSON")
        }
    }

    # ------------------------------------------------------------------
    # Round-4 hardening (D3-2): PEM markers are found in every raw chunk of
    # a line (including beyond the per-line cap and across chunk
    # boundaries), and any line over the raw cap is the placeholder.
    # ------------------------------------------------------------------
    Invoke-Test 'supervisorLog (D3-2): PEM marker beyond the raw line cap still opens the block' {
        $fx = New-Fixture 'd32long'
        $lines = @(
            ((' ' * 5000) + '-----BEGIN PRIVATE KEY-----'),
            'QUJDRA==',
            'RUZHSA==',
            '-----END PRIVATE KEY-----',
            'normal line'
        )
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') (($lines -join "`r`n") + "`r`n")
        $p = New-CommonParams $fx
        $p.LogTailLines = 10
        $r = @(Invoke-Diagnose $p)[0]
        $sl = $r.supervisorLog
        Assert-True $sl.ok 'section ok'
        Assert-Equal 5 $sl.returnedLines 'five lines returned'
        $got = @($sl.lines)
        Assert-Equal '<redacted: long line truncated>' $got[0] 'long line is the placeholder'
        Assert-Equal '<redacted>' $got[1] 'first base64 line masked'
        Assert-Equal '<redacted>' $got[2] 'second base64 line masked'
        Assert-Equal '<redacted>' $got[3] 'END line masked'
        Assert-Equal 'normal line' $got[4] 'normal line survives'
        Assert-True (-not $sl.unterminatedPem) 'PEM block closed'
        $joined = $got -join "`n"
        Assert-True (-not $joined.Contains('QUJDRA==')) 'no first base64 leak'
        Assert-True (-not $joined.Contains('RUZHSA==')) 'no second base64 leak'
    }

    Invoke-Test 'supervisorLog (D3-2): PEM marker split across the 16 KB chunk boundary is still detected' {
        $fx = New-Fixture 'd32split'
        # The marker starts 4 characters before the 16384-byte chunk
        # boundary, so its first dashes land in one read chunk and the rest
        # in the next.
        $prefix = 'A' * (16384 - 4)
        $lines = @(
            ($prefix + '-----BEGIN PRIVATE KEY-----'),
            'QUJDRA==',
            '-----END PRIVATE KEY-----',
            'after end'
        )
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') (($lines -join "`r`n") + "`r`n")
        $p = New-CommonParams $fx
        $p.LogTailLines = 10
        $r = @(Invoke-Diagnose $p)[0]
        $sl = $r.supervisorLog
        Assert-True $sl.ok 'section ok'
        Assert-Equal 4 $sl.returnedLines 'four lines returned'
        $got = @($sl.lines)
        Assert-Equal '<redacted: long line truncated>' $got[0] 'over-cap line is the placeholder'
        Assert-Equal '<redacted>' $got[1] 'base64 line after the split marker masked'
        Assert-Equal '<redacted>' $got[2] 'END line masked'
        Assert-Equal 'after end' $got[3] 'line after the block survives'
        Assert-True (-not $sl.unterminatedPem) 'PEM block closed'
        Assert-True (-not (($got -join "`n")).Contains('QUJDRA==')) 'no base64 leak across the split marker'
    }

    # ------------------------------------------------------------------
    # Round-4 hardening (D3-3): the serverinfo body read has an
    # independent abort bounded by the remaining timeout, so a server that
    # trickles chunk-extension bytes forever cannot stall the section.
    # ------------------------------------------------------------------
    Invoke-Test 'serverInfo (D3-3): chunk-extension trickle aborts within TimeoutSec + 1.5s with Timeout' {
        $writer = {
            param($stream, $client)
            $header = "HTTP/1.1 200 OK`r`nContent-Type: text/xml`r`nTransfer-Encoding: chunked`r`nConnection: close`r`n`r`n"
            $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
            try {
                $stream.Write($hb, 0, $hb.Length)
                $size = [System.Text.Encoding]::ASCII.GetBytes('5;')
                $stream.Write($size, 0, $size.Length)
                $stream.Flush()
                $one = [System.Text.Encoding]::ASCII.GetBytes('x')
                for ($i = 0; $i -lt 30; $i++) {
                    $stream.Write($one, 0, $one.Length)
                    $stream.Flush()
                    Start-Sleep -Milliseconds 200
                }
            } catch { return }
        }
        $p = New-CommonParams $fullFixture
        $p.TimeoutSec = 2
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-DiagnoseWithFakeServer -Params $p -RawWriter $writer
        $sw.Stop()
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-Equal 200 $si.httpStatus 'status was 200'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'Timeout') "Timeout in errors: $($codes -join ',')"
        Assert-True ($si.elapsedMs -le 3500) "section returned within TimeoutSec + 1.5s: $($si.elapsedMs) ms"
        Assert-True ($sw.ElapsedMilliseconds -lt 15000) "whole call returned without hanging: $($sw.ElapsedMilliseconds) ms"
    }

    # ------------------------------------------------------------------
    # Round-4 hardening (D3-4): the unified serverinfo validity rule.
    # ------------------------------------------------------------------
    Invoke-Test 'serverInfo (D3-4): ROOT element name is UnexpectedRoot (case-sensitive)' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<ROOT status_code="200"><state>ok</state><currentgame>1</currentgame></ROOT>'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-True ($null -eq $si.state) 'no state parsed from the wrong root'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'UnexpectedRoot') "UnexpectedRoot in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo (D3-4): whitespace-only state is InvalidField' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<root status_code="200"><state>   </state><currentgame>1</currentgame></root>'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-True ($null -eq $si.state) 'no state reported'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'InvalidField') "InvalidField in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo (D3-4): currentgame with surrounding whitespace is valid and reported trimmed' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<root status_code="200"><state>ok</state><currentgame> 1 </currentgame></root>'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True $si.ok 'section ok'
        Assert-Equal '1' $si.currentgame 'currentgame reported trimmed'
    }

    Invoke-Test 'serverInfo (D3-4): 11-digit currentgame is InvalidField' {
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -StatusCode 200 `
            -Body '<root status_code="200"><state>ok</state><currentgame>12345678901</currentgame></root>'
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-True ($null -eq $si.currentgame) 'currentgame is null'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'InvalidField') "InvalidField in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo (D3-4): 302 Location target is never contacted' {
        $second = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $second.Start()
        $secondPort = $second.LocalEndpoint.Port
        try {
            $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) `
                -StatusLine 'HTTP/1.1 302 Found' `
                -ExtraHeaders @(('Location: http://127.0.0.1:' + $secondPort + '/serverinfo')) -Body ''
            $rep = ([string]$res.Output[0]) | ConvertFrom-Json
            Assert-Equal 302 $rep.serverInfo.httpStatus 'raw status kept'
            $codes = @($rep.serverInfo.errors | ForEach-Object { $_.code })
            Assert-True ($codes -contains 'UnexpectedStatus') "UnexpectedStatus in errors: $($codes -join ',')"
            # The second fake would answer with valid XML; it must never be
            # asked.
            Start-Sleep -Milliseconds 300
            Assert-True (-not $second.Pending()) 'redirect target received a connection'
        } finally { $second.Stop() }
    }

    Invoke-Test 'serverInfo (D3-4): 65537-byte multibyte body is BodyTooLarge counted before decoding' {
        $writer = {
            param($stream, $client)
            # 21845 three-byte characters plus two ASCII characters:
            # 65537 bytes in UTF-8, but only 21847 characters.
            $euro = [string][char]0x20AC
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((($euro * 21845) + 'xx'))
            $header = ('HTTP/1.1 200 OK' + "`r`n" + 'Content-Type: text/xml' + "`r`n" +
                ('Content-Length: ' + $bodyBytes.Length) + "`r`n" + 'Connection: close' + "`r`n`r`n")
            $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
            try {
                $stream.Write($hb, 0, $hb.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                $stream.Flush()
            } catch { }
            Start-Sleep -Milliseconds 300
        }
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -RawWriter $writer
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True (-not $si.ok) 'section not ok'
        Assert-Equal 200 $si.httpStatus 'status was 200'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'BodyTooLarge') "BodyTooLarge in errors: $($codes -join ',')"
    }

    Invoke-Test 'serverInfo (D3-4): exactly 65536-byte body is valid (byte cap is inclusive)' {
        $writer = {
            param($stream, $client)
            # 21819 three-byte characters plus two ASCII characters inside
            # the root element: 65459 filler bytes; with the 77 bytes of
            # markup the body is exactly 65536 bytes (the inclusive cap).
            $euro = [string][char]0x20AC
            $bodyText = '<root status_code="200"><state>cap</state>' + ($euro * 21819) + 'xx' + '<currentgame>1</currentgame></root>'
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
            if ($bodyBytes.Length -ne 65536) { throw ('fixture is ' + $bodyBytes.Length + ' bytes, expected 65536') }
            $header = ('HTTP/1.1 200 OK' + "`r`n" + 'Content-Type: text/xml' + "`r`n" +
                ('Content-Length: ' + $bodyBytes.Length) + "`r`n" + 'Connection: close' + "`r`n`r`n")
            $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
            try {
                $stream.Write($hb, 0, $hb.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                $stream.Flush()
            } catch { }
            Start-Sleep -Milliseconds 300
        }
        $res = Invoke-DiagnoseWithFakeServer -Params (New-CommonParams $fullFixture) -RawWriter $writer
        $rep = ([string]$res.Output[0]) | ConvertFrom-Json
        $si = $rep.serverInfo
        Assert-True $si.ok 'section ok at exactly the cap'
        Assert-Equal 200 $si.httpStatus 'status was 200'
        Assert-Equal 'cap' $si.state 'state parsed at the cap'
        Assert-Equal '1' $si.currentgame 'currentgame parsed at the cap'
        $codes = @($si.errors | ForEach-Object { $_.code })
        Assert-True ($codes -notcontains 'BodyTooLarge') "no BodyTooLarge at the cap: $($codes -join ',')"
    }

    # ------------------------------------------------------------------
    # Night batch A (K2): the hygiene section. Every real-system probe
    # (task query, ACL read) stays off in tests: the task store is only
    # ever exercised through the -SupervisorTaskInfo seam or skipped with
    # -SupervisorTaskName '', and the ACL read only through the
    # -ScriptDirAclSddl seam or -SkipAclCheck.
    # ------------------------------------------------------------------
    Invoke-Test 'hygiene (A2): section present with all four fields; schemaVersion stays 1 (additive)' {
        $h = $fullReport.hygiene
        Assert-True ($null -ne $h) 'hygiene section present'
        Assert-Equal 1 $fullReport.schemaVersion 'schemaVersion stays 1'
        Assert-True ($h.ok -is [bool]) 'ok boolean'
        Assert-True ($null -ne $h.errors) 'errors array'
        $st = $h.supervisorTask
        Assert-True ($null -ne $st) 'supervisorTask present'
        Assert-True $st.skipped 'task query skipped by the common params'
        Assert-True ($null -eq $st.exists) 'exists null when skipped'
        $flags = @($h.pauseFlags)
        Assert-Equal 2 $flags.Count 'both pause flag candidates reported'
        foreach ($flag in $flags) {
            Assert-True (-not $flag.exists) 'no pause flag in the fixture'
            Assert-True ($null -eq $flag.lastWriteTimeUtc) 'no timestamp when absent'
            Assert-True ($null -eq $flag.firstLine) 'no first line when absent'
        }
        $acl = @($h.scriptDirAcl)
        Assert-Equal 2 $acl.Count 'both ACL targets reported'
        foreach ($entry in $acl) {
            Assert-True $entry.skipped 'ACL probe skipped by the common params'
            Assert-True ($null -eq $entry.available) 'available null when skipped'
            Assert-True ($null -eq $entry.protected) 'protected null when skipped'
            Assert-True ($null -eq $entry.ownerSid) 'no owner when skipped'
            Assert-Equal 0 @($entry.writers).Count 'no writers when skipped'
        }
        Assert-Equal 0 @($h.findings).Count 'no findings for a clean fixture'
    }

    Invoke-Test 'hygiene (A2): empty -SupervisorTaskName reports skipped and no task findings' {
        $fx = New-Fixture 'hygskiptask'
        $p = New-CommonParams $fx
        $p.SupervisorTaskName = ''
        $r = @(Invoke-Diagnose $p)[0]
        Assert-True $r.hygiene.supervisorTask.skipped 'skipped'
        Assert-Equal '' $r.hygiene.supervisorTask.name 'empty name reported'
        Assert-True ($null -eq $r.hygiene.supervisorTask.exists) 'exists null when skipped'
        $codes = @($r.hygiene.findings | ForEach-Object { $_.code })
        Assert-True ($codes -notcontains 'OrphanedSupervisorTask') 'no orphan finding when skipped'
        Assert-True ($codes -notcontains 'SupervisorTaskMissing') 'no missing finding when skipped'
    }

    Invoke-Test 'hygiene (A2): injected task present with the entry script present => no task findings' {
        $fx = New-Fixture 'hygtaskok'
        $p = New-CommonParams $fx
        # A unique name that cannot exist on this machine: the coordinator
        # addendum forbids the real task name in tests (elevated shell).
        $p.SupervisorTaskName = ('GsCoordTest-' + [guid]::NewGuid().ToString('N'))
        $p.SupervisorTaskInfo = [pscustomobject]@{
            State   = 'Ready'
            Actions = @([pscustomobject]@{ Execute = (Join-Path $fx.Install 'gs-product.ps1'); Arguments = '-Action Supervisor' })
        }
        $r = @(Invoke-Diagnose $p)[0]
        $st = $r.hygiene.supervisorTask
        Assert-True (-not $st.skipped) 'injected seam used instead of the real query'
        Assert-True $st.exists 'task exists'
        Assert-Equal 'Ready' $st.state 'task state'
        Assert-Equal (Join-Path $fx.Install 'gs-product.ps1') $st.actionPath 'action path'
        $codes = @($r.hygiene.findings | ForEach-Object { $_.code })
        Assert-True ($codes -notcontains 'OrphanedSupervisorTask') 'entry script present, not orphaned'
        Assert-True ($codes -notcontains 'SupervisorTaskMissing') 'task present'
    }

    Invoke-Test 'hygiene (A2): task present but no gs-product.ps1 => OrphanedSupervisorTask warning' {
        $fx = New-Fixture 'hygorphan'
        Remove-Item -LiteralPath (Join-Path $fx.Install 'gs-product.ps1') -Force
        $p = New-CommonParams $fx
        $p.SupervisorTaskName = ('GsCoordTest-' + [guid]::NewGuid().ToString('N'))
        $p.SupervisorTaskInfo = [pscustomobject]@{ State = 'Ready'; Actions = @() }
        $r = @(Invoke-Diagnose $p)[0]
        $f = @($r.hygiene.findings | Where-Object { $_.code -eq 'OrphanedSupervisorTask' })
        Assert-Equal 1 $f.Count 'one orphan finding'
        Assert-Equal 'warning' $f[0].severity 'severity warning'
        Assert-Equal (Join-Path $fx.Install 'gs-product.ps1') $f[0].path 'finding path is the entry script'
        Assert-True ($f[0].message.Length -gt 0) 'message present'
        Assert-True $r.hygiene.supervisorTask.exists 'task still reported as existing'
    }

    Invoke-Test 'hygiene (A2): injected not-found task => SupervisorTaskMissing info' {
        $fx = New-Fixture 'hygmissing'
        $p = New-CommonParams $fx
        $p.SupervisorTaskName = ('GsCoordTest-' + [guid]::NewGuid().ToString('N'))
        # Binding the parameter with $null IS the seam for "task not found":
        # PSBoundParameters.ContainsKey is true, so no real query runs.
        $p.SupervisorTaskInfo = $null
        $r = @(Invoke-Diagnose $p)[0]
        Assert-True (-not $r.hygiene.supervisorTask.exists) 'exists false'
        $f = @($r.hygiene.findings | Where-Object { $_.code -eq 'SupervisorTaskMissing' })
        Assert-Equal 1 $f.Count 'one missing finding'
        Assert-Equal 'info' $f[0].severity 'severity info'
    }

    Invoke-Test 'hygiene (A2): pause flags on both candidate paths => two SupervisorPaused findings' {
        $fx = New-Fixture 'hygpause'
        Write-Utf8File (Join-Path $fx.State 'supervisor_pause.flag') "pause line one password=S3cr3tPF1`r`nsecond line"
        Write-Utf8File (Join-Path $fx.State 'runtime\state\supervisor_pause.flag') 'outer pause token=S3cr3tPF2'
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        $flags = @($r.hygiene.pauseFlags)
        Assert-Equal 2 $flags.Count 'both candidates'
        Assert-Equal (Join-Path $fx.State 'supervisor_pause.flag') $flags[0].path 'product-level flag first'
        Assert-True $flags[0].exists 'product-level flag exists'
        Assert-True ($flags[0].lastWriteTimeUtc -match 'Z$') 'timestamp ISO'
        Assert-Equal 'pause line one password=<redacted>' $flags[0].firstLine 'first line redacted'
        Assert-True $flags[1].exists 'runtime-state flag exists'
        Assert-Equal 'outer pause token=<redacted>' $flags[1].firstLine 'second first line redacted'
        $f = @($r.hygiene.findings | Where-Object { $_.code -eq 'SupervisorPaused' })
        Assert-Equal 2 $f.Count 'two paused findings'
        $paths = @($f | ForEach-Object { $_.path })
        foreach ($item in $f) {
            Assert-Equal 'warning' $item.severity 'severity warning'
        }
        Assert-True ($paths -contains (Join-Path $fx.State 'supervisor_pause.flag')) 'product-level path in findings'
        Assert-True ($paths -contains (Join-Path $fx.State 'runtime\state\supervisor_pause.flag')) 'runtime-state path in findings'
    }

    Invoke-Test 'hygiene (A2): pause flag first line redacted then truncated to 200 characters' {
        $fx = New-Fixture 'hyglongflag'
        Write-Utf8File (Join-Path $fx.State 'supervisor_pause.flag') (('a' * 250) + ' password=S3cr3tLongFlag')
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        $flags = @($r.hygiene.pauseFlags)
        Assert-True $flags[0].exists 'flag exists'
        Assert-Equal 200 $flags[0].firstLine.Length 'first line capped at 200'
        Assert-True (-not $flags[0].firstLine.Contains('S3cr3tLongFlag')) 'secret never in the first line'
    }

    Invoke-Test 'hygiene (A2): both status candidates present => StatusFileAmbiguous warning' {
        $fx = New-Fixture 'hygambiguous'
        Write-Utf8File (Join-Path $fx.State 'status.json') '{ "state": "secondary" }'
        $r = @(Invoke-Diagnose (New-CommonParams $fx))[0]
        $f = @($r.hygiene.findings | Where-Object { $_.code -eq 'StatusFileAmbiguous' })
        Assert-Equal 1 $f.Count 'one ambiguity finding'
        Assert-Equal 'warning' $f[0].severity 'severity warning'
        Assert-Equal (Join-Path $fx.State 'runtime\state\status.json') $f[0].path 'finding path is the primary candidate'
        Assert-True ($f[0].message.Length -gt 0) 'message present'
    }

    Invoke-Test 'ACL pure function (A2): SDDL decision table over in-memory DirectorySecurity' {
        # Extract the self-contained decision function from the script and
        # run it in this session. No disk ACL is ever touched: the inputs
        # are SDDL strings, one produced by an in-memory DirectorySecurity.
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($diagPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($null -ne $ast) 'script parses'
        $fn = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Test-GsSddlWritableByNonAdmin' }, $true))
        Assert-Equal 1 $fn.Count 'decision function found exactly once'
        Invoke-Expression $fn[0].Extent.Text
        $userSid = 'S-1-5-21-99-88-77-1001'
        # A specific user SID with FullControl: the case the allowlist rule
        # exists for (a UAC-filtered token keeps the user SID).
        $res = Test-GsSddlWritableByNonAdmin -Sddl ('D:P(A;OICI;FA;;;' + $userSid + ')')
        Assert-Equal 1 @($res.Writers).Count 'user full control flagged'
        Assert-Equal $userSid $res.Writers[0].sid 'raw SID reported by the pure function'
        # The stored mask is the granted WRITE-bit subset of FullControl
        # (0x1f01ff & the write-bit union = 0xd0156).
        Assert-Equal '0xd0156' ('0x{0:x}' -f $res.Writers[0].mask) 'granted write-bit mask'
        # NOTE: hold every result in a variable. @(fn).Writers member
        # enumeration on a wrapped single object flattens EMPTY collection
        # values to nothing, which then fails under StrictMode.
        $usersRes = Test-GsSddlWritableByNonAdmin -Sddl 'D:P(A;OICI;FA;;;S-1-5-32-545)'
        Assert-Equal 'S-1-5-32-545' $usersRes.Writers[0].sid 'Users full control flagged'
        $readRes = Test-GsSddlWritableByNonAdmin -Sddl 'D:P(A;OICI;FRFX;;;S-1-5-32-545)'
        Assert-Equal 0 @($readRes.Writers).Count 'Users read+execute clean'
        foreach ($case in @(
                @{ mask = '0x2'; note = 'write data' },
                @{ mask = '0x4'; note = 'append data' },
                @{ mask = '0x10'; note = 'write ea' },
                @{ mask = '0x40'; note = 'delete child' },
                @{ mask = '0x100'; note = 'write attributes' },
                @{ mask = '0x10000'; note = 'delete' },
                @{ mask = '0x40000'; note = 'write dacl' },
                @{ mask = '0x80000'; note = 'write owner' },
                @{ mask = '0x10000000'; note = 'generic all' },
                @{ mask = '0x40000000'; note = 'generic write' })) {
            $sddlCase = 'D:P(A;OICI;' + $case.mask + ';;;S-1-5-32-545)'
            $caseRes = Test-GsSddlWritableByNonAdmin -Sddl $sddlCase
            $found = @($caseRes.Writers)
            Assert-Equal 1 $found.Count ("write bit flagged: " + $case.note)
        }
        foreach ($trusted in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')) {
            $trustedSddl = ('D:P(A;OICI;FA;;;' + $trusted + ')')
            $trustedRes = Test-GsSddlWritableByNonAdmin -Sddl $trustedSddl
            Assert-Equal 0 @($trustedRes.Writers).Count "allowlisted SID clean: $trusted"
        }
        # Owner outside the allowlist is a finding even without write ACEs.
        $ownerRes = Test-GsSddlWritableByNonAdmin -Sddl ('O:' + $userSid + 'G:S-1-5-18D:P(A;OICI;FA;;;S-1-5-18)')
        Assert-Equal $userSid $ownerRes.OwnerSid 'raw owner reported'
        Assert-Equal 0 @($ownerRes.Writers).Count 'no write ACEs'
        $noOwnerRes = Test-GsSddlWritableByNonAdmin -Sddl 'D:P(A;OICI;FRFX;;;S-1-5-18)'
        Assert-Equal $null $noOwnerRes.OwnerSid 'no owner in the SDDL => null'
        # Inherit-only CREATOR OWNER ACEs are ignored ('CIIO': container
        # inherit + inherit-only; note 'CIOI' parses as CI + OI, without
        # InheritOnly).
        $creatorOwnerRes = Test-GsSddlWritableByNonAdmin -Sddl 'D:P(A;CIIO;FA;;;S-1-3-0)'
        Assert-Equal 0 @($creatorOwnerRes.Writers).Count 'inherit-only CREATOR OWNER ignored'
        # A deny ACE is never a grant.
        $denyRes = Test-GsSddlWritableByNonAdmin -Sddl 'D:P(D;OICI;FA;;;S-1-5-32-545)'
        Assert-Equal 0 @($denyRes.Writers).Count 'deny ACE not a grant'
        # The protected flag follows the SDDL P control flag.
        $protectedRes = Test-GsSddlWritableByNonAdmin -Sddl 'D:P(A;OICI;FRFX;;;S-1-5-18)'
        Assert-True $protectedRes.Protected 'P flag => protected'
        $unprotectedRes = Test-GsSddlWritableByNonAdmin -Sddl 'D:(A;OICI;FRFX;;;S-1-5-18)'
        Assert-True (-not $unprotectedRes.Protected) 'no P flag => not protected'
        # An in-memory DirectorySecurity built without touching any disk path.
        $sec = New-Object System.Security.AccessControl.DirectorySecurity
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule([System.Security.Principal.SecurityIdentifier]'S-1-5-32-545', [System.Security.AccessControl.FileSystemRights]::Modify, [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit', [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $sec.AddAccessRule($rule)
        $fromObject = Test-GsSddlWritableByNonAdmin -Sddl $sec.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
        Assert-Equal 1 @($fromObject.Writers).Count 'in-memory DirectorySecurity Modify rule flagged'
        # An unparseable SDDL throws; a read-only SDDL yields no grants.
        $threw = $false
        try { $null = Test-GsSddlWritableByNonAdmin -Sddl 'D:P(A;OICI;FA;;;' } catch { $threw = $true }
        Assert-True $threw 'unparseable SDDL throws'
        $cleanRes = Test-GsSddlWritableByNonAdmin -Sddl 'D:P(A;OICI;FRFX;;;S-1-5-11)'
        Assert-Equal 0 @($cleanRes.Writers).Count 'read-only SDDL clean'
    }

    Invoke-Test 'ACL seam (A2): user FullControl ACE and user owner => ScriptDirWritableByNonAdmin (high)' {
        $fx = New-Fixture 'hygaclbad'
        $p = New-CommonParams $fx
        $p.SkipAclCheck = $false
        $userSid = 'S-1-5-21-1-2-3-1001'
        $p.ScriptDirAclSddl = @(
            ('D:P(A;OICI;FA;;;' + $userSid + ')'),
            ('O:' + $userSid + 'G:S-1-5-18D:P(A;OICI;FA;;;S-1-5-18)'))
        $r = @(Invoke-Diagnose $p)[0]
        $acl = @($r.hygiene.scriptDirAcl)
        Assert-Equal 2 $acl.Count 'two entries'
        Assert-Equal (Join-Path $fx.State 'runtime') $acl[0].path 'runtime first'
        Assert-Equal (Join-Path $fx.State 'runtime\bin') $acl[1].path 'runtime bin second'
        Assert-True (-not $acl[0].skipped) 'not skipped'
        Assert-True $acl[0].available 'available'
        Assert-True ($null -eq $acl[0].ownerSid) 'no owner in the first SDDL'
        Assert-Equal 1 @($acl[0].writers).Count 'one writer on runtime'
        Assert-Equal 'S-1-5-21-*-1001' $acl[0].writers[0].sid 'writer SID masked'
        Assert-Equal '0xd0156' $acl[0].writers[0].rightsHex 'granted write-bit mask'
        Assert-Equal 'S-1-5-21-*-1001' $acl[1].ownerSid 'owner SID masked'
        Assert-Equal 0 @($acl[1].writers).Count 'no writer ACE on runtime bin'
        $f = @($r.hygiene.findings | Where-Object { $_.code -eq 'ScriptDirWritableByNonAdmin' })
        Assert-Equal 2 $f.Count 'one ACE finding plus one owner finding'
        foreach ($item in $f) {
            Assert-Equal 'high' $item.severity 'severity high'
        }
        $messages = @($f | ForEach-Object { $_.message })
        Assert-True (@($messages | Where-Object { $_.Contains('S-1-5-21-*-1001') }).Count -ge 1) 'messages name the masked SID, never an account name'
        Assert-True (@($messages | Where-Object { $_.Contains((Join-Path $fx.State 'runtime')) }).Count -ge 1) 'messages name the directory'
    }

    Invoke-Test 'ACL seam (A2): allowlisted-only SDDL => no ACL findings' {
        $fx = New-Fixture 'hygaclgood'
        $p = New-CommonParams $fx
        $p.SkipAclCheck = $false
        $p.ScriptDirAclSddl = @(
            'D:P(A;OICI;FRFX;;;S-1-5-18)',
            'O:S-1-5-18G:S-1-5-18D:P(A;OICI;FA;;;S-1-5-32-544)')
        $r = @(Invoke-Diagnose $p)[0]
        $acl = @($r.hygiene.scriptDirAcl)
        Assert-Equal 'S-1-5-18' $acl[1].ownerSid 'well-known owner SID stays as is'
        foreach ($entry in $acl) {
            Assert-Equal 0 @($entry.writers).Count 'no writers'
        }
        $codes = @($r.hygiene.findings | ForEach-Object { $_.code })
        Assert-True ($codes -notcontains 'ScriptDirWritableByNonAdmin') 'no ACL finding'
    }

    Invoke-Test 'ACL masking (A2): machine-local SIDs are masked in findings and the report' {
        $fx = New-Fixture 'hygaclmask'
        $p = New-CommonParams $fx
        $p.SkipAclCheck = $false
        $p.ScriptDirAclSddl = @(
            'O:S-1-5-21-1-2-3-1001G:S-1-5-18D:P(A;OICI;FA;;;S-1-5-21-1-2-3-1001)',
            'D:P(A;OICI;FRFX;;;S-1-5-18)')
        $r = @(Invoke-Diagnose $p)[0]
        $f = @($r.hygiene.findings | Where-Object { $_.code -eq 'ScriptDirWritableByNonAdmin' })
        # The same masked SID is both writer and owner: a writer finding
        # plus an owner finding, both high, both masked.
        Assert-True ($f.Count -ge 1) "at least one ACL finding: $($f.Count)"
        foreach ($item in $f) {
            Assert-Equal 'high' $item.severity 'severity high'
        }
        $messages = @($f | ForEach-Object { $_.message })
        $maskedCount = @($messages | Where-Object { $_.Contains('S-1-5-21-*-1001') }).Count
        Assert-True ($maskedCount -ge 1) 'a message carries the masked SID'
        $rawCount = @($messages | Where-Object { $_.Contains('S-1-5-21-1-2-3') }).Count
        Assert-Equal 0 $rawCount 'no message carries a raw machine SID'
        $json = $r | ConvertTo-Json -Depth 8
        Assert-True (-not $json.Contains('S-1-5-21-1-2-3')) 'raw machine SID absent from the whole report'
    }

    Invoke-Test 'hygiene (B5): machine-local SIDs are masked in pause flags, log lines and every emitted string' {
        # The final masking pass applies to every emitted string after
        # classification: pause flag first lines and log lines included.
        $fx = New-Fixture 'hygpausemask'
        Write-Utf8File (Join-Path $fx.State 'supervisor_pause.flag') 'paused by S-1-5-21-1-2-3-1001'
        Write-Utf8File (Join-Path $fx.State 'runtime\bin\_supervisor.log') "paused by S-1-5-21-1-2-3-1002`r`n"
        $p = New-CommonParams $fx
        $p.LogTailLines = 5
        $r = @(Invoke-Diagnose $p)[0]
        $flags = @($r.hygiene.pauseFlags)
        Assert-True $flags[0].exists 'pause flag exists'
        Assert-Equal 'paused by S-1-5-21-*-1001' $flags[0].firstLine 'pause flag first line masked'
        $sl = @($r.supervisorLog.lines)
        Assert-Equal 'paused by S-1-5-21-*-1002' $sl[0] 'supervisor log line masked'
        $json = $r | ConvertTo-Json -Depth 8
        Assert-True (-not $json.Contains('S-1-5-21-1-2-3')) 'raw machine SID absent from the whole report'
    }

    Invoke-Test 'test infrastructure (B10): every child powershell.exe call routes through the deadline helper' {
        # Guard: this suite must never start a child powershell.exe outside
        # Invoke-DiagnoseChild, which enforces a hard deadline. A direct
        # synchronous call would hang the whole suite on a stuck child.
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($null -ne $ast) 'test file parses'
        $helper = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-DiagnoseChild' }, $true))
        Assert-Equal 1 $helper.Count 'the deadline-enforcing child helper exists exactly once'
        $helperStart = $helper[0].Extent.StartOffset
        $helperEnd = $helper[0].Extent.EndOffset
        $isChildProcCall = {
            param($a)
            if ($a -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
            if ($a.CommandElements.Count -eq 0) { return $false }
            $text = $a.CommandElements[0].Extent.Text.TrimStart('&', ' ')
            return ($text -eq '$exe' -or $text -ieq 'powershell.exe' -or $text -ieq 'powershell')
        }
        $all = @($ast.FindAll($isChildProcCall, $true))
        $outside = @($all | Where-Object { ($_.Extent.StartOffset -lt $helperStart) -or ($_.Extent.EndOffset -gt $helperEnd) })
        Assert-Equal 0 $outside.Count "no direct child powershell.exe call outside the helper (found $($outside.Count))"
        # The helper starts the child itself, bounded: it owns the process
        # start, the hard deadline and the kill on overrun.
        $helperText = $helper[0].Extent.Text
        Assert-True ($helperText.Contains('$proc.StartInfo.FileName')) 'the helper starts the child process itself'
        Assert-True ($helperText.Contains('WaitForExit')) 'the helper enforces a deadline'
        Assert-True ($helperText.Contains('Kill()')) 'the helper kills the child on overrun'
        $helperCalls = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and ($a.CommandElements.Count -gt 0) -and ($a.CommandElements[0].Extent.Text -eq 'Invoke-DiagnoseChild') }, $true))
        Assert-True ($helperCalls.Count -ge 6) "every child-using test routes through the helper (found $($helperCalls.Count))"
    }

    # ------------------------------------------------------------------
    # Night batch A (K1): -ExtraLogPath produces the extraLogs[] section,
    # reusing the existing bounded, redacting log reader.
    # ------------------------------------------------------------------
    Invoke-Test 'extraLogs (A1): -ExtraLogPath reads a log through the bounded redacting reader' {
        $fx = New-Fixture 'extralog'
        $extraPath = Join-Path $workDir 'extra-tray.log'
        $extraLines = @(
            'EXTRA ordinary line',
            'token=ExtraLeak1',
            '-----BEGIN PRIVATE KEY-----',
            'ExtraPemBody0000000000000000000000000000',
            '-----END PRIVATE KEY-----',
            'seed QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWY= end'
        )
        Write-Utf8File $extraPath (($extraLines -join "`r`n") + "`r`n")
        $p = New-CommonParams $fx
        $p.ExtraLogPath = @($extraPath)
        $r = @(Invoke-Diagnose $p)[0]
        $logs = @($r.extraLogs)
        Assert-Equal 1 $logs.Count 'one extra log'
        $entry = $logs[0]
        Assert-True ($entry.ok -is [bool]) 'entry ok boolean'
        Assert-True ($null -ne $entry.errors) 'entry errors array'
        Assert-Equal $extraPath $entry.path 'path recorded'
        Assert-True $entry.exists 'exists'
        Assert-Equal 6 $entry.returnedLines 'all lines'
        Assert-Equal 'EXTRA ordinary line' $entry.lines[0] 'ordinary line kept'
        Assert-Equal 'token=<redacted>' $entry.lines[1] 'pair redacted'
        Assert-Equal '<redacted>' $entry.lines[2] 'BEGIN masked'
        Assert-Equal '<redacted>' $entry.lines[3] 'PEM body masked'
        Assert-Equal '<redacted>' $entry.lines[4] 'END masked'
        Assert-Equal 'seed <redacted> end' $entry.lines[5] 'long base64 redacted on the log path'
        Assert-True (-not ((@($entry.lines) -join "`n")).Contains('ExtraLeak1')) 'secret absent'
    }

    Invoke-Test 'extraLogs (A1): missing extra log => exists false with FileNotFound, report still produced' {
        $fx = New-Fixture 'extramissing'
        $p = New-CommonParams $fx
        $p.ExtraLogPath = @(Join-Path $workDir 'not-there.log')
        $r = @(Invoke-Diagnose $p)[0]
        Assert-Equal 0 $LASTEXITCODE 'exit code 0'
        $logs = @($r.extraLogs)
        Assert-Equal 1 $logs.Count 'entry still present'
        Assert-True (-not $logs[0].exists) 'exists false'
        Assert-Equal 0 $logs[0].returnedLines 'no lines'
        $codes = @($logs[0].errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'FileNotFound') 'FileNotFound in the entry errors'
        $agg = @($r.errors | Where-Object { $_.section -eq 'extraLogs' })
        Assert-True ($agg.Count -ge 1) 'aggregated under section extraLogs'
    }

    Invoke-Test 'extraLogs (A1): parameter absent => empty array' {
        Assert-Equal 0 @($fullReport.extraLogs).Count 'no extra logs by default'
    }

    # ------------------------------------------------------------------
    # Night batch A (A3): the host section. The live lookups are read-only
    # CIM queries; tests exercise the structure and the error path through
    # the injected scriptblock seams only.
    # ------------------------------------------------------------------
    Invoke-Test 'host (A3): section structure from the injected query seams' {
        $fx = New-Fixture 'hostok'
        $p = New-CommonParams $fx
        $p.SkipHostCheck = $false
        $p.HostGpuQuery = { @([pscustomobject]@{ Name = 'Synthetic GPU 4000'; DriverVersion = '31.0.15.1234'; DriverDate = [datetime]'2026-03-15T00:00:00' }) }
        $p.HostOsQuery = { [pscustomobject]@{ Caption = 'Synthetic OS 11 Pro'; Version = '10.0.22631'; BuildNumber = '22631' } }
        $r = @(Invoke-Diagnose $p)[0]
        $h = $r.host
        Assert-True ($h.ok -is [bool]) 'ok boolean'
        Assert-True $h.ok 'section ok'
        Assert-True (-not $h.skipped) 'not skipped'
        $gpus = @($h.gpus)
        Assert-Equal 1 $gpus.Count 'one GPU'
        Assert-Equal 'Synthetic GPU 4000' $gpus[0].name 'GPU name'
        Assert-Equal '31.0.15.1234' $gpus[0].driverVersion 'driver version'
        Assert-True ($gpus[0].driverDate -match 'Z$') "driver date ISO: $($gpus[0].driverDate)"
        Assert-Equal 'Synthetic OS 11 Pro' $h.os.caption 'OS caption'
        Assert-Equal '10.0.22631' $h.os.version 'OS version'
        Assert-Equal '22631' $h.os.build 'OS build'
        Assert-Equal 0 @($r.errors | Where-Object { $_.section -eq 'host' }).Count 'no host errors aggregated'
    }

    Invoke-Test 'host (A3): failing queries => HostLookupFailed errors, report still produced' {
        $fx = New-Fixture 'hostfail'
        $p = New-CommonParams $fx
        $p.SkipHostCheck = $false
        $p.HostGpuQuery = { throw 'synthetic gpu lookup failure' }
        $p.HostOsQuery = { throw 'synthetic os lookup failure' }
        $r = @(Invoke-Diagnose $p)[0]
        Assert-Equal 0 $LASTEXITCODE 'exit code 0'
        Assert-True (-not $r.host.ok) 'section not ok'
        $codes = @($r.host.errors | ForEach-Object { $_.code })
        Assert-True ($codes -contains 'HostLookupFailed') "HostLookupFailed reported: $($codes -join ',')"
        Assert-Equal 0 @($r.host.gpus).Count 'no GPUs reported'
        $agg = @($r.errors | Where-Object { $_.section -eq 'host' })
        Assert-True ($agg.Count -ge 2) 'both failures aggregated'
    }

    Invoke-Test 'host (A3): -SkipHostCheck marks the section skipped' {
        $h = $fullReport.host
        Assert-True ($null -ne $h) 'host section present'
        Assert-True $h.skipped 'skipped by the common params'
        Assert-True ($null -eq $h.os) 'no OS data when skipped'
        Assert-Equal 0 @($h.gpus).Count 'no GPUs when skipped'
    }

} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
