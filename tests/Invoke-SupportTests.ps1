#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for product/gs-support.ps1 (contract K1, one-click support bundle).
    Uses only temporary synthetic directories, a closed loopback port for
    serverinfo and fake diagnose scripts. Never queries the real scheduled
    task (SupervisorTaskName ''), never touches the registry
    (SkipInstalledProductLookup), never hits live CIM (SkipHostCheck
    forwarded to gs-support's diagnose child) and never runs the real
    gs-product.ps1. The bundle's diagnose child always runs the read-only
    hygiene ACL check (there is no skip switch; K2), but it reads ACLs of
    the %TEMP% fixture directories only - real system ACLs are never
    touched. The diagnose child inside gs-support has a hard deadline
    (process exit AND both pipe drains) inside gs-support itself, and the
    tests that could hang run gs-support as a child process with their own
    deadline, so a regression fails the suite instead of hanging it.
    Exits 0 only when every test passes and at least one ran.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$supportPath = Join-Path $repoRoot 'product\gs-support.ps1'

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

try { Add-Type -AssemblyName System.IO.Compression | Out-Null } catch { }
try { Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null } catch { }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
$utf8 = New-Object System.Text.UTF8Encoding($false)
$tempRoot = [System.IO.Path]::GetTempPath()
# Guid format 'N' (no dashes): A-N1 reverted the earlier 'D' rename that
# existed only to keep dashless 32-character hex segments out of the
# fixture paths. Path metadata is exempt from the extra-log long-run scan
# now, so the fixture name must not dodge it.
$workDir = Join-Path $tempRoot ('GsSupport_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null
$workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath

# Secret material planted in the fixtures. Must never appear in the bundle.
$secToken = 'S3cr3tTok1'                                                            # 1 plain pair
$secPass = 'S3cr3tPass2'                                                            # 2 quoted JSON pair
$secJwt = 'eyJhbGciOiJS3cr3tJWT3x'                                                  # 3 Bearer header
$secTsJwt = 'eyJTS3cr3tJWT4xyz'                                                     # 4 timestamp-prefixed Bearer
$secRikey = 'S3cr3tRike5'                                                           # 5 rikey pair
$secRikeyid = 'S3cr3tRkid6'                                                         # 6 rikeyid pair
$pemBody = 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7Zm9vYmFyYmF6'       # 7 PEM body
$secPin = '9p9xq9zZ'                                                                # 8 bare PIN value
$secLong = 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWY='                           # 9 long base64 run
$secUrl = 'S3cr3tUrl10'                                                             # 10 URL credential parameter
$secStatus = 'S3cr3tStat88'                                                         # non-whitelisted status field
$secStatusLe = 'S3cr3tLE77'                                                         # status lastError value
$secSupLog = 'S3cr3tSup1'                                                           # supervisor log pair
$secSupPass = 'Hunter2Sup'                                                          # supervisor log password

$allSupportSecrets = @($secToken, $secPass, $secJwt, $secTsJwt, $secRikey, $secRikeyid,
    $pemBody, $secPin, $secLong, $secUrl, $secStatus, $secStatusLe, $secSupLog, $secSupPass)

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

# A loopback port that refuses connections (listener created, then stopped).
$closedListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$closedListener.Start()
$closedPort = $closedListener.LocalEndpoint.Port
$closedListener.Stop()

function Get-TrayLogText {
    # 14 lines planting all ten secret kinds, including the
    # timestamp-prefixed Bearer header.
    $lines = @(
        'TRAY ordinary line one',
        ('token=' + $secToken),
        ('"password": "' + $secPass + '"'),
        ('Authorization: Bearer ' + $secJwt),
        ('2026-10-31 10:00:00 Authorization: Bearer ' + $secTsJwt),
        ('rikey=' + $secRikey),
        ('rikeyid=' + $secRikeyid),
        '-----BEGIN PRIVATE KEY-----',
        $pemBody,
        '-----END PRIVATE KEY-----',
        ('PIN ' + $secPin),
        ('seed ' + $secLong + ' end'),
        ('GET http://127.0.0.1:47989/x?access_token=' + $secUrl + ' HTTP/1.1'),
        'TRAY ordinary line last'
    )
    return (($lines -join "`r`n") + "`r`n")
}

function Get-TrayLog1Text {
    $lines = @(
        'rotated token=OldRotatedSecret1',
        'old rikey=OldRikeySecret2'
    )
    return (($lines -join "`r`n") + "`r`n")
}

function Get-SupportSupervisorLogText {
    $lines = @(
        'SUP ordinary line',
        ('supervisor token=' + $secSupLog),
        ('password=' + $secSupPass),
        'SUP final line'
    )
    return (($lines -join "`r`n") + "`r`n")
}

function New-SupportFixture {
    param([string]$Name)

    $base = Join-Path $workDir $Name
    $install = Join-Path $base 'install'
    $state = Join-Path $base 'state'
    $logs = Join-Path $base 'logs'
    $tray = Join-Path $base 'tray'
    $out = Join-Path $base 'out'
    foreach ($d in @($install, $state, $logs, $tray, $out)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    Write-Utf8File (Join-Path $install 'gs-product.ps1') '# synthetic product entry'
    $counter = 0
    foreach ($moduleName in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
        $counter++
        $modDir = Join-Path $install (Join-Path 'Modules' $moduleName)
        Write-Utf8File (Join-Path $modDir ($moduleName + '.psd1')) ("@{`r`n    ModuleVersion = '9.9." + $counter + "'`r`n}")
        Write-Utf8File (Join-Path $modDir ($moduleName + '.psm1')) ('# synthetic module ' + $moduleName)
    }
    Write-Utf8File (Join-Path $install 'bin\bundle-alpha.dat') 'bundle-alpha-payload'

    $config = [ordered]@{
        schemaVersion      = 1
        installDir         = $install
        stateDir           = $state
        logDir             = $logs
        componentSourceDir = $install
    }
    Write-Utf8File (Join-Path $state 'runtime-config.json') ($config | ConvertTo-Json)

    $status = [ordered]@{
        state        = 'ready'
        runId        = 'run-42'
        lastError    = ('password=' + $secStatusLe)
        sessionToken = $secStatus
    }
    Write-Utf8File (Join-Path $state 'runtime\state\status.json') ($status | ConvertTo-Json)

    Write-Utf8File (Join-Path $state 'runtime\bin\gs_supervisor.ps1') '# synthetic supervisor'
    Write-Utf8File (Join-Path $state 'runtime\bin\_supervisor.log') (Get-SupportSupervisorLogText)
    Write-Utf8File (Join-Path $state 'broker_pid.json') ([string]$PID)

    Write-Utf8File (Join-Path $tray 'tray.log') (Get-TrayLogText)
    Write-Utf8File (Join-Path $tray 'tray.log.1') (Get-TrayLog1Text)

    return @{ Base = $base; Install = $install; State = $state; Logs = $logs; Tray = $tray; Out = $out }
}

function New-SupportParams {
    # Parameters that keep every run off the real machine: synthetic dirs,
    # MSI lookup skipped, task query skipped, serverinfo on a closed
    # loopback port, and the host section skipped so tests never hit live
    # CIM. The hygiene ACL check cannot be skipped (K2): the diagnose
    # child reads the ACLs of the %TEMP% fixture directories only.
    param([hashtable]$Fixture)
    return @{
        InstallDir                 = $Fixture.Install
        StateDir                   = $Fixture.State
        LogDir                     = $Fixture.Logs
        TrayLogDir                 = $Fixture.Tray
        OutputDir                  = $Fixture.Out
        ServerInfoUri              = ('http://127.0.0.1:' + $closedPort + '/serverinfo')
        SupervisorTaskName         = ''
        SkipInstalledProductLookup = $true
        SkipHostCheck              = $true
    }
}

function Invoke-Support {
    # Runs gs-support in-process. The script ends with exit 0/1, which sets
    # $LASTEXITCODE and returns here without ending this process (same
    # pattern as the diagnose suite). The diagnose child inside gs-support
    # carries its own hard deadline.
    param([hashtable]$Params)
    $out = @(& $supportPath @Params)
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}

function Invoke-TreeKill {
    # Kills a process and its whole descendant tree (taskkill /T /F).
    param([int]$ProcessId)
    $taskkill = Join-Path ([System.Environment]::SystemDirectory) 'taskkill.exe'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $taskkill
    $startInfo.Arguments = ('/PID ' + $ProcessId + ' /T /F')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $killer = [System.Diagnostics.Process]::Start($startInfo)
    try { $null = $killer.WaitForExit(5000) } finally { $killer.Dispose() }
}

function Invoke-SupportChild {
    # Runs gs-support as a real child powershell.exe with a hard deadline,
    # for the tests whose regression would hang gs-support itself: on
    # overrun the whole child tree (gs-support plus any descendant it
    # owns) is killed and the test fails instead of hanging the suite.
    # Both output pipes are drained asynchronously from the start. The
    # script is invoked through -Command with ConvertTo-Json so the child's
    # stdout is the result object as JSON (under -File it would be the
    # default formatter's text form).
    param([hashtable]$Params, [int]$TimeoutSeconds = 60)
    $exe = Join-Path $PSHOME 'powershell.exe'
    $command = '& ' + "'" + $supportPath + "'"
    foreach ($key in @('OutputDir', 'InstallDir', 'StateDir', 'LogDir', 'TrayLogDir', 'ServerInfoUri', 'DiagnoseScript', 'SupervisorTaskName')) {
        if ($Params.ContainsKey($key) -and ($null -ne $Params[$key])) {
            $command = $command + (' -' + $key + ' ' + "'" + $Params[$key] + "'")
        }
    }
    if ($Params.ContainsKey('DiagnoseTimeoutSec')) {
        $command = $command + (' -DiagnoseTimeoutSec ' + [int]$Params['DiagnoseTimeoutSec'])
    }
    foreach ($key in @('SkipInstalledProductLookup', 'SkipHostCheck')) {
        if ($Params.ContainsKey($key) -and $Params[$key]) {
            $command = $command + (' -' + $key)
        }
    }
    $command = $command + ' | ConvertTo-Json -Depth 6; exit $LASTEXITCODE'
    $argText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + $command + '"'
    $proc = New-Object System.Diagnostics.Process
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $proc.StartInfo.FileName = $exe
        $proc.StartInfo.Arguments = $argText
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $null = $proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            Invoke-TreeKill -ProcessId $proc.Id
            throw ('support child exceeded its ' + $TimeoutSeconds + 's hard deadline')
        }
        $stdout = $outTask.Result
        $stderrText = $errTask.Result
        return @{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderrText; ElapsedMs = $sw.ElapsedMilliseconds }
    } finally {
        $proc.Dispose()
        $sw.Stop()
    }
}

function Get-ResultObject {
    # The contract: the LAST output element is the result object.
    param([hashtable]$Invoked)
    if ($Invoked.Output.Count -eq 0) { throw 'gs-support produced no output' }
    return $Invoked.Output[$Invoked.Output.Count - 1]
}

function Get-ErrorCodes {
    param($Result)
    return @(@($Result.Errors) | ForEach-Object { $_.code })
}

function Count-ZipFiles {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Filter '*.zip' -File -ErrorAction SilentlyContinue).Count
}

function Get-ZipEntryText {
    param([string]$ZipPath, [string]$EntryName)
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $EntryName }
        if ($null -eq $entry) { return $null }
        $stream = $entry.Open()
        try {
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            return $reader.ReadToEnd()
        } finally { $stream.Dispose() }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Get-ZipEntryNames {
    param([string]$ZipPath)
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        return @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object)
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Get-ZipEntryBytes {
    param([string]$ZipPath, [string]$EntryName)
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $EntryName }
        if ($null -eq $entry) { return $null }
        $stream = $entry.Open()
        try {
            $memory = New-Object System.IO.MemoryStream
            $stream.CopyTo($memory)
            return $memory.ToArray()
        } finally { $stream.Dispose() }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Get-KnownSha256 {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function New-FakeDiagnose {
    # Writes a fake diagnose script that accepts the arguments gs-support
    # passes and then emits a fixed payload.
    param([string]$Name, [string]$Body)
    $path = Join-Path $workDir ($Name + '.fake-diagnose.ps1')
    Write-Utf8File $path $Body
    return $path
}

$fakeDiagnoseParamBlock = @'
param(
    [string]$InstallDir,
    [string]$StateDir,
    [string]$LogDir,
    [string]$ServerInfoUri,
    [string]$SupervisorTaskName,
    [string[]]$ExtraLogPath,
    [switch]$SkipInstalledProductLookup,
    [switch]$SkipHostCheck
)
'@

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
try {
    if (-not (Test-Path -LiteralPath $supportPath -PathType Leaf)) {
        Write-Host "FAIL support script exists :: missing $supportPath"
        $script:Failed++
    } else {

        Invoke-Test 'support: success bundle produces the result object, exit code 0 and a zip' {
            $fx = New-SupportFixture 'success'
            $invoked = Invoke-Support (New-SupportParams $fx)
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            Assert-Equal 1 $r.schemaVersion 'schemaVersion 1'
            Assert-True $r.Success 'Success true'
            Assert-True (-not [string]::IsNullOrEmpty([string]$r.ZipPath)) 'ZipPath present'
            Assert-True (Test-Path -LiteralPath $r.ZipPath -PathType Leaf) 'zip exists on disk'
            Assert-True ($r.ZipPath.StartsWith($fx.Out, [System.StringComparison]::OrdinalIgnoreCase)) 'zip inside OutputDir'
            Assert-Equal 3 @($r.Entries).Count 'three entries'
            Assert-Equal 0 @($r.Errors).Count 'no errors'
            $names = @($r.Entries | ForEach-Object { $_.name })
            foreach ($n in @('diagnose.json', 'extra-logs.json', 'manifest.json')) {
                Assert-True ($names -contains $n) "entry $n listed"
            }
        }

        Invoke-Test 'support: zip contains exactly the three entries and never status.json' {
            $fx = New-SupportFixture 'entries'
            $invoked = Invoke-Support (New-SupportParams $fx)
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            $names = Get-ZipEntryNames -ZipPath $r.ZipPath
            Assert-Equal 3 $names.Count 'exactly three entries in the zip'
            Assert-Equal 'diagnose.json,extra-logs.json,manifest.json' ($names -join ',') 'entry names'
            $leaf = Split-Path -Leaf $r.ZipPath
            Assert-True ($leaf.StartsWith('GsController-support-')) "zip name prefix: $leaf"
            Assert-True ($leaf.EndsWith('.zip')) 'zip suffix'
        }

        Invoke-Test 'support: no planted secret appears in any zip entry' {
            $fx = New-SupportFixture 'secrets'
            $invoked = Invoke-Support (New-SupportParams $fx)
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            foreach ($entryName in @('diagnose.json', 'extra-logs.json', 'manifest.json')) {
                $text = Get-ZipEntryText -ZipPath $r.ZipPath -EntryName $entryName
                Assert-True ($null -ne $text) "entry readable: $entryName"
                foreach ($secret in $allSupportSecrets) {
                    Assert-True (-not $text.Contains([string]$secret)) "secret absent from ${entryName}: $($secret.Substring(0, 8))..."
                }
            }
        }

        Invoke-Test 'support: diagnose.json parses with schemaVersion 1, skipped probes and redacted extraLogs' {
            $fx = New-SupportFixture 'diagjson'
            $invoked = Invoke-Support (New-SupportParams $fx)
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            $raw = Get-ZipEntryText -ZipPath $r.ZipPath -EntryName 'diagnose.json'
            $diag = $raw | ConvertFrom-Json
            Assert-Equal 1 $diag.schemaVersion 'schemaVersion'
            Assert-True ($null -ne $diag.hygiene) 'hygiene section present'
            Assert-True $diag.hygiene.supervisorTask.skipped 'task query skipped inside the bundle'
            $acl = @($diag.hygiene.scriptDirAcl)
            Assert-Equal 2 $acl.Count 'two ACL entries'
            # B4: there is no skip switch any more - the bundle's ACL probe
            # always runs, here against the %TEMP% fixture directories.
            Assert-True (-not $acl[0].skipped) 'ACL probe runs inside the bundle'
            Assert-True $acl[0].available 'fixture runtime dir ACL readable'
            Assert-True ($null -ne $diag.extraLogs) 'extraLogs present'
            $logs = @($diag.extraLogs)
            Assert-Equal 2 $logs.Count 'both tray logs captured'
            $first = $logs[0]
            Assert-True ($first.path.EndsWith('tray.log')) 'first is tray.log'
            Assert-Equal 14 $first.returnedLines 'all tray.log lines'
            $joined = @($first.lines) -join "`n"
            Assert-True ($joined.Contains('token=<redacted>')) 'plain pair redacted'
            Assert-True ($joined.Contains('"password": <redacted>')) 'quoted pair redacted'
            Assert-True ($joined.Contains('Authorization: <redacted>')) 'Bearer header redacted'
            Assert-True ($joined.Contains('2026-10-31 10:00:00 Authorization: <redacted>')) 'timestamped Bearer redacted'
            Assert-True ($joined.Contains('rikey=<redacted>')) 'rikey redacted'
            Assert-True ($joined.Contains('PIN <redacted>')) 'bare PIN redacted'
            Assert-True ($joined.Contains('access_token=<redacted>')) 'URL credential parameter redacted'
            Assert-True (-not $joined.Contains('-----BEGIN')) 'PEM marker masked'
            $second = $logs[1]
            Assert-True ($second.path.EndsWith('tray.log.1')) 'second is tray.log.1'
            Assert-True (((@($second.lines) -join "`n")).Contains('token=<redacted>')) 'rotated token redacted'
        }

        Invoke-Test 'support: manifest.json carries generatedAtUtc, productVersion and matching per-entry hashes' {
            $fx = New-SupportFixture 'manifest'
            $invoked = Invoke-Support (New-SupportParams $fx)
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            $manifestText = Get-ZipEntryText -ZipPath $r.ZipPath -EntryName 'manifest.json'
            $manifest = $manifestText | ConvertFrom-Json
            Assert-Equal 1 $manifest.schemaVersion 'manifest schemaVersion'
            $ts = [datetime]::Parse($manifest.generatedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            Assert-True ($ts.ToUniversalTime() -gt (Get-Date).ToUniversalTime().AddMinutes(-10)) 'generatedAtUtc is recent'
            Assert-Equal '9.9.1' $manifest.productVersion 'product version from the fake GsControl module'
            $manifestNames = @(@($manifest.entries) | ForEach-Object { $_.name })
            Assert-Equal 'diagnose.json,extra-logs.json,manifest.json' (($manifestNames | Sort-Object) -join ',') 'manifest lists all three entries'
            foreach ($entry in @($manifest.entries)) {
                if ($entry.name -eq 'manifest.json') { continue }  # the manifest cannot hash itself
                $bytes = Get-ZipEntryBytes -ZipPath $r.ZipPath -EntryName $entry.name
                Assert-True ($null -ne $bytes) "entry bytes readable: $($entry.name)"
                Assert-Equal (Get-KnownSha256 $bytes) $entry.sha256 "manifest hash matches bytes: $($entry.name)"
                Assert-Equal $bytes.Length $entry.sizeBytes "manifest size matches bytes: $($entry.name)"
            }
            foreach ($outEntry in @($r.Entries)) {
                $m = @($manifest.entries) | Where-Object { $_.name -eq $outEntry.name }
                Assert-True ($null -ne $m) "output entry present in manifest: $($outEntry.name)"
                Assert-Equal $m.sha256 $outEntry.sha256 "output entry hash matches manifest: $($outEntry.name)"
            }
        }

        Invoke-Test 'support: two consecutive runs produce different zip file names, both valid' {
            $fx = New-SupportFixture 'tworuns'
            $p = New-SupportParams $fx
            $r1 = Get-ResultObject (Invoke-Support $p)
            Assert-Equal 0 $LASTEXITCODE 'first run exit code 0'
            $r2 = Get-ResultObject (Invoke-Support $p)
            Assert-Equal 0 $LASTEXITCODE 'second run exit code 0'
            Assert-True $r1.Success 'first run success'
            Assert-True $r2.Success 'second run success'
            Assert-True ($r1.ZipPath -ne $r2.ZipPath) 'different file names'
            Assert-True (Test-Path -LiteralPath $r1.ZipPath -PathType Leaf) 'first zip still there'
            Assert-True (Test-Path -LiteralPath $r2.ZipPath -PathType Leaf) 'second zip exists'
            Assert-Equal 2 (Count-ZipFiles $fx.Out) 'two zips in the output dir'
        }

        Invoke-Test 'support: OutputDir is created when missing (nested path)' {
            $fx = New-SupportFixture 'newdir'
            $p = New-SupportParams $fx
            $p.OutputDir = (Join-Path $fx.Base 'made\up\nested')
            $r = Get-ResultObject (Invoke-Support $p)
            Assert-Equal 0 $LASTEXITCODE 'exit code 0'
            Assert-True $r.Success 'success'
            Assert-True (Test-Path -LiteralPath $r.ZipPath -PathType Leaf) 'zip inside the created dir'
        }

        Invoke-Test 'support: missing diagnose script => DiagnoseUnavailable, exit 1, no zip' {
            $fx = New-SupportFixture 'missingdiag'
            $p = New-SupportParams $fx
            $p.DiagnoseScript = (Join-Path $workDir 'definitely-missing-diagnose.ps1')
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True (-not $r.Success) 'Success false'
            Assert-True ((Get-ErrorCodes $r) -contains 'DiagnoseUnavailable') "DiagnoseUnavailable reported: $((Get-ErrorCodes $r) -join ',')"
            Assert-True ([string]::IsNullOrEmpty([string]$r.ZipPath)) 'no ZipPath'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support: diagnose child exits nonzero => DiagnoseFailed, no zip' {
            $fx = New-SupportFixture 'exitfail'
            $p = New-SupportParams $fx
            $p.DiagnoseScript = New-FakeDiagnose 'exitfail' ($fakeDiagnoseParamBlock + "`r`nWrite-Output 'partial output then failure'`r`nexit 3`r`n")
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'DiagnoseFailed') 'DiagnoseFailed reported'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support: diagnose output that is not JSON => DiagnoseFailed, no zip' {
            $fx = New-SupportFixture 'notjson'
            $p = New-SupportParams $fx
            $p.DiagnoseScript = New-FakeDiagnose 'notjson' ($fakeDiagnoseParamBlock + "`r`nWrite-Output 'this is definitely not json at all'`r`nexit 0`r`n")
            $r = Get-ResultObject (Invoke-Support $p)
            Assert-Equal 1 $LASTEXITCODE 'exit code 1'
            Assert-True (-not $r.Success) 'Success false'
            Assert-True ((Get-ErrorCodes $r) -contains 'DiagnoseFailed') 'DiagnoseFailed reported'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support: diagnose schemaVersion 2 => DiagnoseFailed, no zip' {
            $fx = New-SupportFixture 'schema2'
            $p = New-SupportParams $fx
            $p.DiagnoseScript = New-FakeDiagnose 'schema2' ($fakeDiagnoseParamBlock + "`r`nWrite-Output '{`"schemaVersion`": 2}'`r`nexit 0`r`n")
            $r = Get-ResultObject (Invoke-Support $p)
            Assert-Equal 1 $LASTEXITCODE 'exit code 1'
            Assert-True ((Get-ErrorCodes $r) -contains 'DiagnoseFailed') 'DiagnoseFailed reported (schemaVersion 1 required)'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support: unredacted password in diagnose output => RedactionCheckFailed, no zip (fail closed)' {
            $fx = New-SupportFixture 'leakpass'
            $p = New-SupportParams $fx
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''{"schemaVersion":1,"productVersion":"9.9.9","extraLogs":[],"note":"password=PlantedLeak1"}''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'leakpass' $body
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'RedactionCheckFailed') "RedactionCheckFailed reported: $((Get-ErrorCodes $r) -join ',')"
            Assert-True ([string]::IsNullOrEmpty([string]$r.ZipPath)) 'no ZipPath'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created (fail closed)'
            foreach ($e in @($r.Errors)) {
                Assert-True (-not ([string]$e.message).Contains('PlantedLeak1')) 'error message never echoes the secret'
            }
        }

        Invoke-Test 'support: unredacted rikey in extraLogs => RedactionCheckFailed, no zip (fail closed)' {
            $fx = New-SupportFixture 'leakrikey'
            $p = New-SupportParams $fx
            $json = '{"schemaVersion":1,"extraLogs":[{"path":"C:/synthetic/tray.log","exists":true,"lines":["rikey=PlantedLeak2"]}]}'
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''' + $json + '''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'leakrikey' $body
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'RedactionCheckFailed') "RedactionCheckFailed reported: $((Get-ErrorCodes $r) -join ',')"
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support: PEM BEGIN marker in diagnose output => RedactionCheckFailed' {
            $fx = New-SupportFixture 'leakpem'
            $p = New-SupportParams $fx
            $json = '{"schemaVersion":1,"note":"-----BEGIN PRIVATE KEY-----"}'
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''' + $json + '''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'leakpem' $body
            $r = Get-ResultObject (Invoke-Support $p)
            Assert-Equal 1 $LASTEXITCODE 'exit code 1'
            Assert-True ((Get-ErrorCodes $r) -contains 'RedactionCheckFailed') 'RedactionCheckFailed reported'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support: redacted placeholder forms never trip the second pass' {
            # A fake diagnose whose output is full of correctly redacted
            # forms must produce a zip: the second pass only fires on
            # non-placeholder values.
            $fx = New-SupportFixture 'placeholders'
            $p = New-SupportParams $fx
            # The lines are exactly the forms the diagnose redaction emits:
            # header form consumes the whole value ('Bearer' disappears),
            # the scheme rule keeps the scheme word.
            $json = '{"schemaVersion":1,"lines":["token=<redacted>","Authorization: <redacted>","password=<redacted>","rikeyid=<redacted>","PIN <redacted>","?sig=<redacted>","tried Bearer <redacted> against the api"]}'
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''' + $json + '''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'placeholders' $body
            $invoked = Invoke-Support $p
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            Assert-True $r.Success 'redacted placeholders pass the second pass'
            Assert-Equal 1 (Count-ZipFiles $fx.Out) 'zip produced'
        }

        Invoke-Test 'support: relative OutputDir rejected => OutputDirInvalid' {
            $fx = New-SupportFixture 'relout'
            $p = New-SupportParams $fx
            $p.OutputDir = 'relative-support-out'
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'OutputDirInvalid') 'OutputDirInvalid reported'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support: OutputDir inside InstallDir rejected => OutputDirInvalid' {
            $fx = New-SupportFixture 'insideinstall'
            $p = New-SupportParams $fx
            $p.OutputDir = (Join-Path $fx.Install 'support')
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'OutputDirInvalid') 'OutputDirInvalid reported'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support: OutputDir equal to InstallDir rejected => OutputDirInvalid' {
            $fx = New-SupportFixture 'equalinstall'
            $p = New-SupportParams $fx
            $p.OutputDir = $fx.Install
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'OutputDirInvalid') 'OutputDirInvalid reported'
        }

        Invoke-Test 'support: OutputDir that exists as a file rejected => OutputDirInvalid' {
            $fx = New-SupportFixture 'fileout'
            $filePath = Join-Path $fx.Base 'occupied'
            Write-Utf8File $filePath 'not a directory'
            $p = New-SupportParams $fx
            $p.OutputDir = $filePath
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'OutputDirInvalid') 'OutputDirInvalid reported'
        }

        Invoke-Test 'support: empty TrayLogDir still yields an extra-logs.json entry with no logs' {
            $fx = New-SupportFixture 'emptytray'
            Remove-Item -LiteralPath (Join-Path $fx.Tray 'tray.log') -Force
            Remove-Item -LiteralPath (Join-Path $fx.Tray 'tray.log.1') -Force
            $r = Get-ResultObject (Invoke-Support (New-SupportParams $fx))
            Assert-Equal 0 $LASTEXITCODE 'exit code 0'
            Assert-True $r.Success 'success without tray logs'
            $extra = Get-ZipEntryText -ZipPath $r.ZipPath -EntryName 'extra-logs.json'
            Assert-True ($null -ne $extra) 'extra-logs.json present'
            # The file is exactly '[]'; PS 5.1 ConvertFrom-Json wraps empty
            # arrays on output, so the raw text is asserted directly.
            Assert-Equal '[]' $extra.Trim() 'no extra logs'
        }

        Invoke-Test 'support: invalid ServerInfoUri surfaces as DiagnoseFailed, no zip' {
            $fx = New-SupportFixture 'baduri'
            $p = New-SupportParams $fx
            $p.ServerInfoUri = 'not a uri'
            $r = Get-ResultObject (Invoke-Support $p)
            Assert-Equal 1 $LASTEXITCODE 'exit code 1'
            Assert-True ((Get-ErrorCodes $r) -contains 'DiagnoseFailed') 'DiagnoseFailed reported'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support: exit code is 0 on success and 1 on failure' {
            $fxOk = New-SupportFixture 'exitok'
            $null = Invoke-Support (New-SupportParams $fxOk)
            Assert-Equal 0 $LASTEXITCODE 'success exit code 0'
            $fxBad = New-SupportFixture 'exitbad'
            $p = New-SupportParams $fxBad
            $p.DiagnoseScript = (Join-Path $workDir 'still-missing.ps1')
            $null = Invoke-Support $p
            Assert-Equal 1 $LASTEXITCODE 'failure exit code 1'
        }

        # ------------------------------------------------------------------
        # Round-4 review fixes (night batch A). Each regression test below
        # failed on the round-4 baseline before the corresponding
        # gs-support change; the failing-first FAIL lines are in the batch
        # report.
        # ------------------------------------------------------------------

        Invoke-Test 'support (B1): hex credential in a status free-text field is rejected (Q1 example 1)' {
            # A planted pairing key hidden as a 32-hex status lastError must
            # be rejected: the long-run rule now applies to status free text
            # of the DECODED report, not only to serialized extra logs.
            $fx = New-SupportFixture 'b1status'
            $p = New-SupportParams $fx
            $json = '{"schemaVersion":1,"extraLogs":[],"status":{"state":"ready","lastError":"0123456789abcdef0123456789abcdef"}}'
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''' + $json + '''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'b1status' $body
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'RedactionCheckFailed') "RedactionCheckFailed reported: $((Get-ErrorCodes $r) -join ',')"
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created (fail closed)'
        }

        Invoke-Test 'support (B1): escaped credential pair inside extraLogs lines is rejected (Q1 example 2)' {
            # The escaped-quotes form defeated the old scan of serialized
            # text; scanning the DECODED log line catches it.
            $fx = New-SupportFixture 'b1escaped'
            $p = New-SupportParams $fx
            $json = '{"schemaVersion":1,"extraLogs":[{"lines":["\"password\": \"PlantedLeak1\""]}]}'
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''' + $json + '''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'b1escaped' $body
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'RedactionCheckFailed') "RedactionCheckFailed reported: $((Get-ErrorCodes $r) -join ',')"
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created (fail closed)'
        }

        Invoke-Test 'support (B1 follow-up): 64-hex credential in status lastError is rejected' {
            # The 64-hex exemption is field-name gated: a planted pairing
            # key hidden as a whole 64-hex status lastError must be
            # rejected by the long-run rule, not excused as metadata.
            $fx = New-SupportFixture 'b1hexstatus'
            $p = New-SupportParams $fx
            $hex64 = ('0123456789abcdef' * 4)
            $json = '{"schemaVersion":1,"extraLogs":[],"status":{"state":"ready","lastError":"' + $hex64 + '"}}'
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''' + $json + '''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'b1hexstatus' $body
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'RedactionCheckFailed') "RedactionCheckFailed reported: $((Get-ErrorCodes $r) -join ',')"
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created (fail closed)'
        }

        Invoke-Test 'support (B1 follow-up): a 64-hex log line is rejected' {
            $fx = New-SupportFixture 'b1hexlog'
            $p = New-SupportParams $fx
            $hex64 = ('a1b2c3d4' * 8)
            # Reuse the byte-exact (verified valid) template from the
            # escaped-pair test and swap in the plain hex value.
            $json = '{"schemaVersion":1,"extraLogs":[{"lines":["\"password\": \"PlantedLeak1\""]}]}'
            $json = $json.Replace('\"password\": \"PlantedLeak1\"', $hex64)
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''' + $json + '''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'b1hexlog' $body
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'RedactionCheckFailed') "RedactionCheckFailed reported: $((Get-ErrorCodes $r) -join ',')"
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created (fail closed)'
        }

        Invoke-Test 'support (B1 follow-up): sha256-named hash values still produce a bundle' {
            # Guard: the exemption survives for hash-named fields - the
            # diagnose report legitimately carries 64-hex SHA-256 values
            # in fields ending in Sha256/sha256.
            $fx = New-SupportFixture 'b1hexguard'
            $p = New-SupportParams $fx
            $sha = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            $json = '{"schemaVersion":1,"extraLogs":[],"product":{"productEntrySha256":"' + $sha + '"}}'
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''' + $json + '''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'b1hexguard' $body
            $invoked = Invoke-Support $p
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            Assert-True $r.Success "hash-named metadata still bundles: $((Get-ErrorCodes $r) -join ',')"
            Assert-Equal 1 (Count-ZipFiles $fx.Out) 'zip produced'
        }

        Invoke-Test 'support (B2): child stderr secret never reaches the public result' {
            $fx = New-SupportFixture 'b2stderr'
            $p = New-SupportParams $fx
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                '[Console]::Error.WriteLine(''password=PlantedLeak1'')' + "`r`nexit 1`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'b2stderr' $body
            $invoked = Invoke-Support $p
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True ((Get-ErrorCodes $r) -contains 'DiagnoseFailed') 'DiagnoseFailed reported'
            $resultText = ($invoked.Output | ConvertTo-Json -Depth 6)
            Assert-True (-not $resultText.Contains('PlantedLeak1')) 'stderr secret absent from the public result'
        }

        Invoke-Test 'support (B6): masked and well-known ACL SID metadata produce a bundle' {
            # ACL writers[].sid / ownerSid values in SID form are validated
            # metadata, not session credentials.
            $fx = New-SupportFixture 'b6sid'
            $p = New-SupportParams $fx
            $json = '{"schemaVersion":1,"extraLogs":[],"hygiene":{"scriptDirAcl":[{"path":"C:/synthetic/runtime","skipped":false,"available":true,"protected":true,"ownerSid":"S-1-5-21-*-1001","writers":[{"sid":"S-1-5-21-*-1001","rightsHex":"0xd0156"}]},{"path":"C:/synthetic/runtime/bin","skipped":false,"available":true,"protected":true,"ownerSid":"S-1-5-18","writers":[]}]}}'
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                'Write-Output ''' + $json + '''' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'b6sid' $body
            $invoked = Invoke-Support $p
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            Assert-True $r.Success "ACL SID metadata is not a credential: $((Get-ErrorCodes $r) -join ',')"
            Assert-Equal 1 (Count-ZipFiles $fx.Out) 'zip produced'
        }

        Invoke-Test 'support (B7): TrayLogDir defaults to LOCALAPPDATA\GsController\tray when omitted' {
            $fx = New-SupportFixture 'b7traydefault'
            $fakeLocal = Join-Path $fx.Base 'fakelocal'
            $defaultTray = Join-Path $fakeLocal 'GsController\tray'
            New-Item -ItemType Directory -Path $defaultTray -Force | Out-Null
            Write-Utf8File (Join-Path $defaultTray 'tray.log') "TRAY default line token=DefaultTray1`r`n"
            $oldLocal = $env:LOCALAPPDATA
            try {
                $env:LOCALAPPDATA = $fakeLocal
                $p = New-SupportParams $fx
                $null = $p.Remove('TrayLogDir')
                $invoked = Invoke-Support $p
                Assert-Equal 0 $invoked.ExitCode 'exit code 0'
                $r = Get-ResultObject $invoked
                Assert-True $r.Success 'success'
                $raw = Get-ZipEntryText -ZipPath $r.ZipPath -EntryName 'diagnose.json'
                $diag = $raw | ConvertFrom-Json
                $logs = @($diag.extraLogs)
                Assert-Equal 1 $logs.Count "the LOCALAPPDATA default tray log was captured (got $($logs.Count))"
                Assert-Equal (Join-Path $defaultTray 'tray.log') $logs[0].path 'default path used'
                Assert-True (((@($logs[0].lines) -join "`n")).Contains('token=<redacted>')) 'default tray log line redacted'
            } finally {
                $env:LOCALAPPDATA = $oldLocal
            }
        }

        Invoke-Test 'support (B8): Windows native argument encoder doubles backslashes correctly' {
            # AST-extract the encoder and test the Windows quoting rules
            # directly: backslashes before a quote and at the end of a
            # quoted argument are doubled.
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($supportPath, [ref]$tokens, [ref]$parseErrors)
            Assert-True ($null -ne $ast) 'gs-support parses'
            $fn = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'ConvertTo-SupportWindowsArgument' }, $true))
            Assert-Equal 1 $fn.Count 'encoder function found exactly once'
            Invoke-Expression $fn[0].Extent.Text
            Assert-Equal '"C:\Gs State\\"' (ConvertTo-SupportWindowsArgument 'C:\Gs State\') 'trailing backslash doubled inside quotes'
            Assert-Equal 'plain' (ConvertTo-SupportWindowsArgument 'plain') 'plain token unquoted'
            Assert-Equal '""' (ConvertTo-SupportWindowsArgument '') 'empty becomes a quoted empty argument'
            Assert-Equal '"a\"b"' (ConvertTo-SupportWindowsArgument 'a"b') 'embedded quote escaped'
            Assert-Equal '"C:\say \"hi\"\\"' (ConvertTo-SupportWindowsArgument 'C:\say "hi"\') 'quotes and trailing backslash combined'
            Assert-Equal '"two  spaces"' (ConvertTo-SupportWindowsArgument 'two  spaces') 'spaces quoted'
            Assert-Equal 'C:\a\b\\c' (ConvertTo-SupportWindowsArgument 'C:\a\b\\c') 'internal backslashes untouched when unquoted'
        }

        Invoke-Test 'support (B8): StateDir with a trailing backslash and a space reaches diagnose intact' {
            $fx = New-SupportFixture 'b8state'
            $p = New-SupportParams $fx
            $stateWithSpace = $fx.Base + '\Gs State\'
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                '$out = @{ schemaVersion = 1; stateDirSeen = $StateDir; extraLogs = @() } | ConvertTo-Json -Depth 4' + "`r`n" +
                'Write-Output $out' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'b8state' $body
            $p.StateDir = $stateWithSpace
            $invoked = Invoke-Support $p
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            Assert-True $r.Success 'success with the trailing-backslash StateDir'
            $raw = Get-ZipEntryText -ZipPath $r.ZipPath -EntryName 'diagnose.json'
            $diag = $raw | ConvertFrom-Json
            Assert-Equal $stateWithSpace $diag.stateDirSeen 'StateDir reached the diagnose child unmodified'
        }

        Invoke-Test 'support (B9): unexpected exception returns the SupportFailed contract result' {
            $fx = New-SupportFixture 'b9boundary'
            $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
            $letter = $null
            foreach ($c in @('D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
                if ($used -notcontains $c) { $letter = $c; break }
            }
            if ($null -eq $letter) { throw 'no free drive letter available for the test' }
            $p = New-SupportParams $fx
            $p.TrayLogDir = ($letter + ':\tray')
            try {
                $invoked = Invoke-Support $p
            } catch {
                throw ('B9: gs-support threw instead of returning the contract result: ' + $_.Exception.Message)
            }
            Assert-Equal 1 $invoked.ExitCode 'exit code 1'
            $r = Get-ResultObject $invoked
            Assert-True (-not $r.Success) 'Success false'
            Assert-True ((Get-ErrorCodes $r) -contains 'SupportFailed') "SupportFailed reported: $((Get-ErrorCodes $r) -join ',')"
            Assert-Equal 'The support bundle failed unexpectedly.' ([string](@($r.Errors)[0].message)) 'fixed English message'
            Assert-True ([string]::IsNullOrEmpty([string]$r.ZipPath)) 'no ZipPath'
            Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
        }

        Invoke-Test 'support (N1): a 32-char segment in the tray log path no longer trips the long-run scan' {
            # Path metadata is exempt from the long-run rule: a tray log
            # under a directory named with a dashless GUID still bundles.
            $fx = New-SupportFixture 'n1longseg'
            $segDir = Join-Path $fx.Base ('seg-' + [guid]::NewGuid().ToString('N'))
            $tray = Join-Path $segDir 'tray'
            New-Item -ItemType Directory -Path $tray -Force | Out-Null
            Write-Utf8File (Join-Path $tray 'tray.log') ('TRAY ordinary long-segment line' + "`r`n")
            $p = New-SupportParams $fx
            $p.TrayLogDir = $tray
            $invoked = Invoke-Support $p
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            Assert-True $r.Success 'bundle produced despite the 32-char path segment'
            $raw = Get-ZipEntryText -ZipPath $r.ZipPath -EntryName 'diagnose.json'
            $diag = $raw | ConvertFrom-Json
            Assert-Equal 1 @($diag.extraLogs).Count 'tray log captured'
            Assert-Equal 'TRAY ordinary long-segment line' @($diag.extraLogs)[0].lines[0] 'line intact'
        }

        Invoke-Test 'support (B3): a descendant holding stdout is killed within the deadline' {
            # A fake diagnose starts a sleeping descendant that inherits
            # stdout, prints valid JSON and exits. One deadline inside
            # gs-support must cover process exit AND the pipe drains, so
            # gs-support returns (DiagnoseFailed) within deadline + 5 s
            # and the whole child tree is killed. Run as a child process
            # with its own deadline: the old code hung forever here.
            $fx = New-SupportFixture 'b3pipe'
            $trayEmpty = Join-Path $fx.Base 'emptytray'
            New-Item -ItemType Directory -Path $trayEmpty -Force | Out-Null
            $deadlineSec = 12
            $pidFile = Join-Path $workDir 'b3-descendant.pid'
            if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force }
            $psExe = Join-Path $PSHOME 'powershell.exe'
            $fakeBody = @'
param(
    [string]$InstallDir,
    [string]$StateDir,
    [string]$LogDir,
    [string]$ServerInfoUri,
    [string]$SupervisorTaskName,
    [string[]]$ExtraLogPath,
    [switch]$SkipInstalledProductLookup,
    [switch]$SkipHostCheck
)
$descendant = Start-Process -FilePath 'PSEXEHOLDER' -ArgumentList @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 300') -PassThru -NoNewWindow
[System.IO.File]::WriteAllText('PIDFILEHOLDER', [string]$descendant.Id)
Write-Output '{"schemaVersion":1,"extraLogs":[]}'
exit 0
'@
            $fakeBody = $fakeBody.Replace('PSEXEHOLDER', $psExe).Replace('PIDFILEHOLDER', $pidFile)
            $p = New-SupportParams $fx
            $p.DiagnoseScript = New-FakeDiagnose 'b3pipe' $fakeBody
            $p.TrayLogDir = $trayEmpty
            $p.DiagnoseTimeoutSec = $deadlineSec
            $descendantStopped = $false
            try {
                $child = Invoke-SupportChild -Params $p -TimeoutSeconds 30
                Assert-True ($child.ElapsedMs -le (($deadlineSec + 5) * 1000)) "returned within deadline + 5s: $($child.ElapsedMs) ms"
                Assert-Equal 1 $child.ExitCode 'exit code 1'
                $r = $child.StdOut.Trim() | ConvertFrom-Json
                Assert-True (-not $r.Success) 'Success false'
                Assert-True ((@($r.Errors) | ForEach-Object { $_.code }) -contains 'DiagnoseFailed') 'DiagnoseFailed reported'
                $deadlineHits = @(@($r.Errors) | Where-Object { ([string]$_.message) -match 'deadline' })
                Assert-True ($deadlineHits.Count -ge 1) 'deadline message present'
                Assert-Equal 0 (Count-ZipFiles $fx.Out) 'no zip created'
            } finally {
                if (Test-Path -LiteralPath $pidFile) {
                    $rawPid = [System.IO.File]::ReadAllText($pidFile).Trim()
                    $parsed = 0
                    if ([int]::TryParse($rawPid, [ref]$parsed)) {
                        try { Stop-Process -Id $parsed -Force -ErrorAction Stop; $descendantStopped = $true } catch { }
                    }
                }
                Assert-True (-not $descendantStopped) 'the descendant was already killed by gs-support (tree kill)'
            }
        }

        Invoke-Test 'support (N2): SkipHostCheck is forwarded to the diagnose child' {
            # Tests must never hit live CIM: gs-support forwards
            # -SkipHostCheck and the child reports receiving it.
            $fx = New-SupportFixture 'n2host'
            $p = New-SupportParams $fx
            $body = $fakeDiagnoseParamBlock + "`r`n" +
                '$forwarded = $(if ($SkipHostCheck) { ''true'' } else { ''false'' })' + "`r`n" +
                'Write-Output (''{"schemaVersion":1,"extraLogs":[],"hostCheckSkippedSeen":'' + $forwarded + ''}'')' + "`r`nexit 0`r`n"
            $p.DiagnoseScript = New-FakeDiagnose 'n2host' $body
            $invoked = Invoke-Support $p
            Assert-Equal 0 $invoked.ExitCode 'exit code 0'
            $r = Get-ResultObject $invoked
            Assert-True $r.Success 'success'
            $raw = Get-ZipEntryText -ZipPath $r.ZipPath -EntryName 'diagnose.json'
            $diag = $raw | ConvertFrom-Json
            Assert-True $diag.hostCheckSkippedSeen 'SkipHostCheck reached the diagnose child'
        }

    }
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
