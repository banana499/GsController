#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 2 unit tests for the GsLifecycle module. Uses only temporary synthetic
    directories and mock script-block callbacks; touches no services, registry,
    drivers or processes. Exits 0 only when every test passes; exits 1 otherwise.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot 'src\GsLifecycle\GsLifecycle.psd1'

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
    if ($Expected -cne $Actual) {
        throw "Assertion failed: $Message (expected '$Expected', actual '$Actual')"
    }
}

function Assert-HasErrorCode {
    param($Result, [string]$Code, [string]$Message)
    $codes = @($Result.Errors | ForEach-Object { $_.Code })
    if ($codes -cnotcontains $Code) {
        throw "Assertion failed: $Message (expected error code '$Code', actual '$($codes -join ',')')"
    }
}

try {
    Import-Module $manifestPath -Force -ErrorAction Stop
} catch {
    Write-Host "FAIL module import :: $($_.Exception.Message)"
    exit 1
}

$tempRoot = [System.IO.Path]::GetTempPath()
$workDir = Join-Path $tempRoot ("GsLifecycleStage2_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null
$workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath

$utf8 = New-Object System.Text.UTF8Encoding($false)

# Creates a fresh synthetic install/state/log layout and returns its config.
function New-TestEnv {
    $root = Join-Path $workDir ([guid]::NewGuid().ToString('N'))
    $cfg = [pscustomobject]@{
        InstallDir = Join-Path $root 'install'
        StateDir   = Join-Path $root 'state'
        LogDir     = Join-Path $root 'logs'
    }
    foreach ($d in @($cfg.InstallDir, $cfg.StateDir, $cfg.LogDir)) { New-Item -ItemType Directory -Path $d | Out-Null }
    return $cfg
}

function Get-StatePath { param($Cfg) return (Join-Path $Cfg.StateDir 'lifecycle-state.json') }

# Writes a well-formed state file directly (test setup only).
function Set-TestState {
    param($Cfg, [string]$State)
    $err = $null
    if ($State -eq 'Failed') {
        $err = [ordered]@{ code = 'SeededFailure'; occurredAtUtc = '2026-01-01T00:00:00.0000000Z'; diagnostics = [ordered]@{} }
    }
    $doc = [ordered]@{ schemaVersion = 1; state = $State; changedAtUtc = '2026-01-01T00:00:00.0000000Z'; error = $err }
    [System.IO.File]::WriteAllText((Get-StatePath $Cfg), (ConvertTo-Json -InputObject $doc -Depth 5), $utf8)
}

function Read-RawState {
    param($Cfg)
    return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Get-StatePath $Cfg))))
}

function Get-TempLeftovers {
    param($Cfg)
    return , @(Get-ChildItem -LiteralPath $Cfg.StateDir -Filter '*.tmp' -Force)
}

# Independent copy of the required transition table (from the stage-2 ask).
$expected = @{
    'Starting' = @('Running', 'Failed')
    'Running'  = @('Stopping', 'Failed')
    'Stopping' = @('Stopped')
    'Failed'   = @('Starting', 'Stopping')
    'Stopped'  = @('Starting', 'Paused')
    'Paused'   = @('Starting')
}
$allStates = @('Stopped', 'Starting', 'Running', 'Stopping', 'Failed', 'Paused')

$okOp = { param($ctx) }
$throwOp = { param($ctx) throw 'synthetic failure password=hunter2' }
$falseOp = { param($ctx) $false }

try {
    # -------------------------------------------------------------------
    # InstallationConfig
    # -------------------------------------------------------------------
    Invoke-Test 'Config: valid absolute sibling directories' {
        $r = Test-GsInstallationConfig -InstallDir 'C:\Gs\app' -StateDir 'C:\Gs\state' -LogDir 'D:\logs\gs'
        Assert-True $r.Success 'should succeed'
        Assert-Equal 'C:\Gs\app' $r.Config.InstallDir 'InstallDir'
        Assert-Equal 'C:\Gs\state' $r.Config.StateDir 'StateDir'
        Assert-Equal 'D:\logs\gs' $r.Config.LogDir 'LogDir'
    }

    Invoke-Test 'Config: paths are normalized via Resolve-GsPath' {
        $r = Test-GsInstallationConfig -InstallDir 'C:/Gs/x/../app/' -StateDir 'C:\Gs\.\state' -LogDir '\\srv\share\logs'
        Assert-True $r.Success 'should succeed'
        Assert-Equal 'C:\Gs\app\' $r.Config.InstallDir 'InstallDir normalized'
        Assert-Equal 'C:\Gs\state' $r.Config.StateDir 'StateDir normalized'
        Assert-Equal '\\srv\share\logs' $r.Config.LogDir 'UNC accepted'
    }

    foreach ($case in @(
            @{ v = $null; code = 'EmptyPath' }, @{ v = ''; code = 'EmptyPath' }, @{ v = '   '; code = 'EmptyPath' },
            @{ v = 'relative\dir'; code = 'NotAbsolute' }, @{ v = '.\dir'; code = 'NotAbsolute' }, @{ v = '..'; code = 'NotAbsolute' },
            @{ v = 'C:foo'; code = 'InvalidPath' }, @{ v = '\rooted'; code = 'InvalidPath' }, @{ v = 'HKLM:\SOFTWARE'; code = 'InvalidPath' },
            @{ v = 'C:\bad|name'; code = 'InvalidPath' }, @{ v = 5; code = 'InvalidType' })) {
        $c = $case
        Invoke-Test "Config: installDir '$($c.v)' rejected as $($c.code)" {
            $r = Test-GsInstallationConfig -InstallDir $c.v -StateDir 'C:\Gs\state' -LogDir 'C:\Gs\logs'
            Assert-True (-not $r.Success) 'should fail'
            Assert-True ($null -eq $r.Config) 'Config null on failure'
            $e = @($r.Errors | Where-Object { $_.Field -eq 'installDir' })
            Assert-Equal 1 $e.Count 'one installDir error'
            Assert-Equal $c.code $e[0].Code 'error code'
        }
    }

    Invoke-Test 'Config: each field validated (state and log empty)' {
        $r = Test-GsInstallationConfig -InstallDir 'C:\Gs\app' -StateDir '' -LogDir $null
        Assert-True (-not $r.Success) 'should fail'
        Assert-Equal 2 @($r.Errors).Count 'two errors'
        Assert-True (@($r.Errors | Where-Object { $_.Field -eq 'stateDir' -and $_.Code -eq 'EmptyPath' }).Count -eq 1) 'stateDir'
        Assert-True (@($r.Errors | Where-Object { $_.Field -eq 'logDir' -and $_.Code -eq 'EmptyPath' }).Count -eq 1) 'logDir'
    }

    Invoke-Test 'Config: identical directories rejected (case and trailing slash ignored)' {
        $r = Test-GsInstallationConfig -InstallDir 'C:\Gs\App' -StateDir 'c:\gs\app\' -LogDir 'C:\Gs\logs'
        Assert-True (-not $r.Success) 'should fail'
        Assert-HasErrorCode $r 'SameDirectory' 'same directory'
    }

    foreach ($case in @(
            @{ i = 'C:\Gs'; s = 'C:\Gs\state'; l = 'C:\Logs'; f = 'installDir,stateDir' },
            @{ i = 'C:\Gs\app'; s = 'C:\Gs\app\sub\state'; l = 'C:\Logs'; f = 'installDir,stateDir' },
            @{ i = 'C:\Gs\state\app'; s = 'C:\Gs\state'; l = 'C:\Logs'; f = 'installDir,stateDir' },
            @{ i = 'C:\App'; s = 'C:\State'; l = 'C:\State\logs'; f = 'stateDir,logDir' },
            @{ i = 'C:\App'; s = 'C:\State'; l = 'C:\APP\LOGS'; f = 'installDir,logDir' },
            @{ i = 'C:\'; s = 'C:\State'; l = 'D:\Logs'; f = 'installDir,stateDir' })) {
        $c = $case
        Invoke-Test "Config: nesting rejected ($($c.i) | $($c.s) | $($c.l))" {
            $r = Test-GsInstallationConfig -InstallDir $c.i -StateDir $c.s -LogDir $c.l
            Assert-True (-not $r.Success) 'should fail'
            $nested = @($r.Errors | Where-Object { $_.Code -eq 'NestedDirectory' -and $_.Field -like "*$($c.f)*" })
            Assert-True ($nested.Count -ge 1) "NestedDirectory on $($c.f): $(@($r.Errors | ForEach-Object { $_.Code + ':' + $_.Field }) -join ';')"
        }
    }

    Invoke-Test 'Config: shared name prefix is not nesting' {
        $r = Test-GsInstallationConfig -InstallDir 'C:\Gs\app' -StateDir 'C:\Gs\app2' -LogDir 'C:\Gs\app-logs'
        Assert-True $r.Success 'C:\Gs\app and C:\Gs\app2 are siblings'
    }

    Invoke-Test 'Config: Test-GsInstallationConfig does not create directories' {
        $p = Join-Path $workDir 'never-created'
        $r = Test-GsInstallationConfig -InstallDir "$p\a" -StateDir "$p\b" -LogDir "$p\c"
        Assert-True $r.Success 'valid'
        Assert-True (-not (Test-Path -LiteralPath $p)) 'nothing created'
    }

    Invoke-Test 'Config file: valid file read' {
        $f = Join-Path $workDir 'cfg-ok.json'
        $json = ConvertTo-Json -InputObject ([ordered]@{ schemaVersion = 1; installDir = 'C:\Gs\app'; stateDir = 'C:\Gs\state'; logDir = 'C:\Gs\logs'; extra = 1 })
        [System.IO.File]::WriteAllText($f, $json, $utf8)
        $r = Read-GsInstallationConfig -Path $f
        Assert-True $r.Success "should succeed: $(@($r.Errors | ForEach-Object { $_.Message }) -join ';')"
        Assert-Equal $f $r.Path 'Path'
        Assert-Equal 'C:\Gs\state' $r.Config.StateDir 'StateDir'
    }

    Invoke-Test 'Config file: missing file' {
        $r = Read-GsInstallationConfig -Path (Join-Path $workDir 'nope.json')
        Assert-True (-not $r.Success) 'fail'
        Assert-HasErrorCode $r 'FileNotFound' 'FileNotFound'
    }

    foreach ($case in @(
            @{ n = 'empty'; t = ''; code = 'InvalidJson' }, @{ n = 'garbage'; t = '{not json'; code = 'InvalidJson' },
            @{ n = 'array'; t = '[1,2]'; code = 'InvalidType' })) {
        $c = $case
        Invoke-Test "Config file: $($c.n) content -> $($c.code)" {
            $f = Join-Path $workDir "cfg-$($c.n).json"
            [System.IO.File]::WriteAllText($f, $c.t, $utf8)
            $r = Read-GsInstallationConfig -Path $f
            Assert-True (-not $r.Success) 'fail'
            Assert-HasErrorCode $r $c.code $c.code
        }
    }

    Invoke-Test 'Config file: missing fields all listed' {
        $f = Join-Path $workDir 'cfg-missing.json'
        [System.IO.File]::WriteAllText($f, '{}', $utf8)
        $r = Read-GsInstallationConfig -Path $f
        Assert-True (-not $r.Success) 'fail'
        Assert-Equal 4 @($r.Errors | Where-Object { $_.Code -eq 'MissingField' }).Count 'four missing fields'
    }

    Invoke-Test 'Config file: bad schemaVersion and relative dir reported together' {
        $f = Join-Path $workDir 'cfg-bad.json'
        $json = ConvertTo-Json -InputObject ([ordered]@{ schemaVersion = 2; installDir = 'app'; stateDir = 'C:\Gs\state'; logDir = 'C:\Gs\logs' })
        [System.IO.File]::WriteAllText($f, $json, $utf8)
        $r = Read-GsInstallationConfig -Path $f
        Assert-True (-not $r.Success) 'fail'
        Assert-HasErrorCode $r 'UnsupportedValue' 'schemaVersion'
        Assert-HasErrorCode $r 'NotAbsolute' 'installDir relative'
    }

    Invoke-Test 'Config file: non-string directory -> InvalidType' {
        $f = Join-Path $workDir 'cfg-type.json'
        [System.IO.File]::WriteAllText($f, '{"schemaVersion":1,"installDir":["C:\\a"],"stateDir":"C:\\b","logDir":"C:\\c"}', $utf8)
        $r = Read-GsInstallationConfig -Path $f
        Assert-True (-not $r.Success) 'fail'
        Assert-HasErrorCode $r 'InvalidType' 'installDir array'
    }

    # -------------------------------------------------------------------
    # Transition table (pure)
    # -------------------------------------------------------------------
    Invoke-Test 'Table: exported table equals the required table exactly' {
        $t = Get-GsLifecycleTransitionTable
        Assert-Equal 6 $t.Count 'six states'
        foreach ($s in $allStates) {
            Assert-Equal (($expected[$s] | Sort-Object) -join ',') ((@($t[$s]) | Sort-Object) -join ',') "targets of $s"
        }
    }

    Invoke-Test 'Table: returned table is a copy' {
        $t = Get-GsLifecycleTransitionTable
        $t['Stopped'] = @('Running')
        Assert-True (-not (Test-GsLifecycleTransition -From 'Stopped' -To 'Running').Allowed) 'mutation has no effect'
    }

    Invoke-Test 'Table: unknown and wrong-case states rejected' {
        foreach ($p in @(@('Stopped', 'Bogus'), @('Bogus', 'Starting'), @('stopped', 'Starting'), @('', 'Starting'), @('Stopped', $null))) {
            $r = Test-GsLifecycleTransition -From $p[0] -To $p[1]
            Assert-True (-not $r.Allowed) "$($p[0]) -> $($p[1])"
            Assert-Equal 'UnknownState' $r.Code "code for $($p[0]) -> $($p[1])"
        }
    }

    # -------------------------------------------------------------------
    # Full 6x6 matrix through the public low-level entry point. Legal edges to
    # Failed/Paused persist; legal edges to operation-backed targets return
    # OperationRequired without writing; illegal edges return IllegalTransition.
    $operationTargets = @('Starting', 'Running', 'Stopping', 'Stopped')
    foreach ($from in $allStates) {
        foreach ($to in $allStates) {
            $f = $from; $t = $to
            $legal = $expected[$f] -ccontains $t
            $needsOp = $legal -and ($operationTargets -ccontains $t)
            $label = $(if (-not $legal) { 'rejected' } elseif ($needsOp) { 'legal, OperationRequired' } else { 'legal' })
            Invoke-Test "Transition: $f -> $t is $label" {
                $cfg = New-TestEnv
                Set-TestState $cfg $f
                $before = [System.IO.File]::ReadAllText((Get-StatePath $cfg))
                $pure = Test-GsLifecycleTransition -From $f -To $t
                Assert-Equal $legal $pure.Allowed 'pure check'
                $args2 = @{ Config = $cfg; To = $t }
                if ($t -eq 'Failed') { $args2['ErrorCode'] = 'TestFailure'; $args2['Diagnostics'] = @{ step = 'matrix' } }
                $r = Invoke-GsLifecycleTransition @args2
                Assert-Equal ($legal -and -not $needsOp) $r.Success 'Success'
                Assert-Equal $f $r.From 'From'
                Assert-Equal $t $r.To 'To'
                if ($legal -and -not $needsOp) {
                    Assert-Equal 'Ok' $r.Code 'Code'
                    Assert-Equal $t (Read-RawState $cfg).state 'persisted state'
                    Assert-Equal $t $r.State.State 'result state'
                } else {
                    Assert-Equal $(if ($needsOp) { 'OperationRequired' } else { 'IllegalTransition' }) $r.Code 'Code'
                    Assert-True ($r.Message -like "*$f -> $t*") 'message names transition'
                    Assert-Equal $before ([System.IO.File]::ReadAllText((Get-StatePath $cfg))) 'file unchanged'
                    Assert-Equal $f $r.State.State 'reported current state'
                }
                Assert-Equal 0 (Get-TempLeftovers $cfg).Count 'no temp files left'
            }
        }
    }

    # The same 36 pairs through the internal core that Start/Stop use, to prove
    # every legal edge (including operation-backed ones) persists.
    foreach ($from in $allStates) {
        foreach ($to in $allStates) {
            $f = $from; $t = $to
            $legal = $expected[$f] -ccontains $t
            Invoke-Test "Core: $f -> $t is $(if ($legal) { 'persisted' } else { 'rejected' })" {
                $cfg = New-TestEnv
                Set-TestState $cfg $f
                $sp = Get-StatePath $cfg
                $before = [System.IO.File]::ReadAllText($sp)
                $ec = $(if ($t -eq 'Failed') { 'TestFailure' } else { $null })
                $r = & (Get-Module GsLifecycle) {
                    param($p, $tt, $e)
                    $cur = (Read-GsStateFile -StatePath $p).Record
                    Invoke-GsTransitionCore -StatePath $p -Current $cur -To $tt -ErrorCode $e
                } $sp $t $ec
                Assert-Equal $legal $r.Success 'Success'
                if ($legal) {
                    Assert-Equal $t (Read-RawState $cfg).state 'persisted'
                } else {
                    Assert-Equal 'IllegalTransition' $r.Code 'Code'
                    Assert-Equal $before ([System.IO.File]::ReadAllText($sp)) 'unchanged'
                }
            }
        }
    }

    Invoke-Test 'Transition: missing state file defaults to Stopped' {
        $cfg = New-TestEnv
        $g = Get-GsLifecycleState -Config $cfg
        Assert-True $g.Success 'Success'
        Assert-Equal 'Default' $g.Source 'Source'
        Assert-Equal 'Stopped' $g.State.State 'State'
        Assert-True (-not (Test-Path -LiteralPath (Get-StatePath $cfg))) 'read does not create file'
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Running'
        Assert-Equal 'IllegalTransition' $r.Code 'Stopped -> Running rejected'
    }

    Invoke-Test 'Transition: unknown target -> UnknownState' {
        $cfg = New-TestEnv
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Exploded'
        Assert-True (-not $r.Success) 'fail'
        Assert-Equal 'UnknownState' $r.Code 'code'
    }

    Invoke-Test 'Transition: Failed requires ErrorCode' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Failed'
        Assert-Equal 'ErrorCodeRequired' $r.Code 'code'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'unchanged'
    }

    Invoke-Test 'Transition: malformed ErrorCode rejected' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Failed' -ErrorCode 'has spaces; and junk'
        Assert-Equal 'InvalidErrorCode' $r.Code 'code'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'unchanged'
    }

    foreach ($bad in @("Abc`n", "Abc`r`n", "`nAbc", "Abc`n`n", "Ab`nc", "1Abc", ('A' * 65), "Abc ", "Ab-c")) {
        $b = $bad
        Invoke-Test "Transition: ErrorCode $(ConvertTo-Json -InputObject $b -Compress) rejected" {
            $cfg = New-TestEnv
            Set-TestState $cfg 'Running'
            $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Failed' -ErrorCode $b
            Assert-Equal 'InvalidErrorCode' $r.Code 'code'
            Assert-Equal 'Running' (Read-RawState $cfg).state 'unchanged'
        }
    }

    Invoke-Test 'Transition: ErrorCode boundary values accepted' {
        foreach ($good in @('A', ('A' * 64), 'Probe.Failed_2')) {
            $cfg = New-TestEnv
            Set-TestState $cfg 'Running'
            $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Failed' -ErrorCode $good
            Assert-True $r.Success "accepted: $good"
            Assert-Equal $good (Read-RawState $cfg).error.code 'stored exactly'
        }
    }

    Invoke-Test 'Corrupt: persisted ErrorCode with trailing newline reads as corrupt' {
        $cfg = New-TestEnv
        $doc = '{"schemaVersion":1,"state":"Failed","changedAtUtc":"2026-01-01T00:00:00.0000000Z","error":{"code":"Abc\n","occurredAtUtc":"2026-01-01T00:00:00.0000000Z","diagnostics":{}}}'
        [System.IO.File]::WriteAllText((Get-StatePath $cfg), $doc, $utf8)
        $g = Get-GsLifecycleState -Config $cfg
        Assert-Equal 'Corrupt' $g.Source 'source'
        Assert-Equal 'StateCorrupt' $g.State.Error.Code 'code'
    }

    Invoke-Test 'Transition: ErrorCode on non-Failed target rejected' {
        $cfg = New-TestEnv
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Paused' -ErrorCode 'Oops'
        Assert-Equal 'ErrorCodeNotAllowed' $r.Code 'code'
        Assert-True (-not (Test-Path -LiteralPath (Get-StatePath $cfg))) 'nothing written'
    }

    Invoke-Test 'Transition: direct Invoke cannot forge Running or Stopped (OperationRequired)' {
        $cfg = New-TestEnv
        $r1 = Invoke-GsLifecycleTransition -Config $cfg -To 'Starting'
        Assert-Equal 'OperationRequired' $r1.Code 'Stopped -> Starting'
        Assert-True ($r1.Message -like '*Start-GsLifecycle*') 'points to Start-GsLifecycle'
        Assert-True (-not (Test-Path -LiteralPath (Get-StatePath $cfg))) 'nothing written'
        Set-TestState $cfg 'Starting'
        Assert-Equal 'OperationRequired' (Invoke-GsLifecycleTransition -Config $cfg -To 'Running').Code 'Starting -> Running'
        Set-TestState $cfg 'Running'
        $r2 = Invoke-GsLifecycleTransition -Config $cfg -To 'Stopping'
        Assert-Equal 'OperationRequired' $r2.Code 'Running -> Stopping'
        Assert-True ($r2.Message -like '*Stop-GsLifecycle*') 'points to Stop-GsLifecycle'
        Set-TestState $cfg 'Stopping'
        Assert-Equal 'OperationRequired' (Invoke-GsLifecycleTransition -Config $cfg -To 'Stopped').Code 'Stopping -> Stopped'
        Assert-Equal 'Stopping' (Read-RawState $cfg).state 'unchanged'
    }

    Invoke-Test 'Transition: invalid config rejected structurally' {
        $r = Invoke-GsLifecycleTransition -Config ([pscustomobject]@{ InstallDir = 'rel'; StateDir = 'C:\x'; LogDir = 'C:\x\y' }) -To 'Starting'
        Assert-True (-not $r.Success) 'fail'
        Assert-Equal 'InvalidConfig' $r.Code 'code'
        Assert-HasErrorCode $r 'NotAbsolute' 'relative'
        Assert-HasErrorCode $r 'NestedDirectory' 'nested'
        $r2 = Invoke-GsLifecycleTransition -Config $null -To 'Starting'
        Assert-Equal 'InvalidConfig' $r2.Code 'null config'
    }

    Invoke-Test 'Transition: hashtable config accepted' {
        $cfg = New-TestEnv
        $h = @{ InstallDir = $cfg.InstallDir; StateDir = $cfg.StateDir; LogDir = $cfg.LogDir }
        $r = Invoke-GsLifecycleTransition -Config $h -To 'Paused'
        Assert-True $r.Success 'hashtable works'
    }

    Invoke-Test 'Transition: missing state directory rejected, not created' {
        $root = Join-Path $workDir ([guid]::NewGuid().ToString('N'))
        $cfg = [pscustomobject]@{ InstallDir = "$root\i"; StateDir = "$root\s"; LogDir = "$root\l" }
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Starting'
        Assert-Equal 'StateDirectoryMissing' $r.Code 'code'
        Assert-True (-not (Test-Path -LiteralPath $root)) 'not created'
    }

    # -------------------------------------------------------------------
    # Persistence format, failure record, sanitization
    # -------------------------------------------------------------------
    Invoke-Test 'Persist: format of a non-failed state' {
        $cfg = New-TestEnv
        $null = Invoke-GsLifecycleTransition -Config $cfg -To 'Paused'
        $raw = Read-RawState $cfg
        Assert-Equal 1 $raw.schemaVersion 'schemaVersion'
        Assert-Equal 'Paused' $raw.state 'state'
        Assert-True ($raw.changedAtUtc -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z$') "changedAtUtc ISO UTC: $($raw.changedAtUtc)"
        Assert-True ($null -eq $raw.error) 'error null'
        $bytes = [System.IO.File]::ReadAllBytes((Get-StatePath $cfg))
        Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'UTF-8 without BOM'
    }

    Invoke-Test 'Persist: Failed stores code, UTC time and diagnostics; secrets redacted' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $diag = [ordered]@{
            step = 'probe'; attempt = 3; ok = $false
            Password = 'hunter2'; apiToken = 'abc'; nested = @{ secretValue = 's'; port = 47989 }
            list = @(1, 'two'); secure = (ConvertTo-SecureString 'p' -AsPlainText -Force)
            obj = (New-Object System.Text.StringBuilder)
        }
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Failed' -ErrorCode 'ProbeFailed' -Diagnostics $diag
        Assert-True $r.Success "transition ok: $($r.Message)"
        $text = [System.IO.File]::ReadAllText((Get-StatePath $cfg))
        Assert-True ($text -notmatch 'hunter2') 'password value not stored'
        Assert-True ($text -notmatch '"abc"') 'token value not stored'
        $raw = ConvertFrom-Json -InputObject $text
        Assert-Equal 'Failed' $raw.state 'state'
        Assert-Equal 'ProbeFailed' $raw.error.code 'code'
        Assert-True ($raw.error.occurredAtUtc -match 'Z$') 'UTC time'
        Assert-Equal 'probe' $raw.error.diagnostics.step 'step'
        Assert-Equal 3 $raw.error.diagnostics.attempt 'attempt'
        Assert-Equal '[REDACTED]' $raw.error.diagnostics.Password 'Password'
        Assert-Equal '[REDACTED]' $raw.error.diagnostics.apiToken 'apiToken'
        Assert-Equal '[REDACTED]' $raw.error.diagnostics.nested.secretValue 'nested secret'
        Assert-Equal 47989 $raw.error.diagnostics.nested.port 'nested port'
        Assert-Equal '[REDACTED]' $raw.error.diagnostics.secure 'SecureString'
        Assert-True ($raw.error.diagnostics.obj -like '[[]unserializable:*') 'non-serializable object stringified as type only'
        $g = Get-GsLifecycleState -Config $cfg
        Assert-Equal 'File' $g.Source 'source'
        Assert-Equal 'ProbeFailed' $g.State.Error.Code 'reload error code'
    }

    Invoke-Test 'Persist: diagnostics depth and size are bounded' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $deep = @{ a = @{ b = @{ c = @{ d = @{ e = @{ f = 1 } } } } } }
        $big = @{}; 1..80 | ForEach-Object { $big["k$_"] = $_ }
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Failed' -ErrorCode 'Big' -Diagnostics @{ deep = $deep; big = $big; long = ('x' * 5000) }
        Assert-True $r.Success 'ok'
        $text = [System.IO.File]::ReadAllText((Get-StatePath $cfg))
        Assert-True ($text -match 'depth-limit') 'depth limited'
        Assert-True ($text -match '_truncated') 'entry count limited'
        Assert-True ($text.Length -lt 6000) "string truncated (length $($text.Length))"
    }

    Invoke-Test 'Persist: leaving Failed clears the error record' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Failed'
        $r = Start-GsLifecycle -Config $cfg -StartOperation $okOp
        Assert-True $r.Success 'ok'
        Assert-True ($null -eq (Read-RawState $cfg).error) 'error cleared'
    }

    Invoke-Test 'Persist: write failure keeps the old file and leaves no temp file' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Stopped'
        $p = Get-StatePath $cfg
        $before = [System.IO.File]::ReadAllText($p)
        [System.IO.File]::SetAttributes($p, [System.IO.FileAttributes]::ReadOnly)
        try {
            $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Paused'
        } finally {
            [System.IO.File]::SetAttributes($p, [System.IO.FileAttributes]::Normal)
        }
        Assert-True (-not $r.Success) 'fail'
        Assert-Equal 'PersistFailed' $r.Code 'code'
        Assert-Equal 'Stopped' $r.State.State 'reported state is the unchanged one'
        Assert-Equal $before ([System.IO.File]::ReadAllText($p)) 'file unchanged'
        Assert-Equal 0 (Get-TempLeftovers $cfg).Count 'temp removed'
    }

    Invoke-Test 'Persist: concurrent readers never lose the state file and no transition fails' {
        $cfg = New-TestEnv
        $noop = { param($ctx) }
        $seedStart = Start-GsLifecycle -Config $cfg -StartOperation $noop
        $seedStop = Stop-GsLifecycle -Config $cfg -StopOperation $noop
        Assert-True ($seedStart.Success -and $seedStop.Success) 'seed the state file'

        $statePath = Get-StatePath $cfg
        $stopPath = Join-Path $cfg.StateDir 'reader.stop'
        # A reader that cannot see the file counts it. File.Replace moved the
        # target aside before publishing the new one, so a concurrent read
        # found nothing for a moment (measured on this host: 82-90 of ~3150
        # reads over 200 writes, and 1 of 100 cycles failed to persist).
        $readerScript = {
            param($Path, $StopPath)
            $reads = 0
            $absent = 0
            while (-not [System.IO.File]::Exists($StopPath)) {
                $reads++
                try { $null = [System.IO.File]::ReadAllText($Path) }
                catch {
                    $e = $_.Exception
                    while ($e -is [System.Management.Automation.MethodInvocationException] -and $null -ne $e.InnerException) { $e = $e.InnerException }
                    if ($e -is [System.IO.FileNotFoundException] -or $e -is [System.IO.DirectoryNotFoundException]) { $absent++ }
                }
            }
            [pscustomobject]@{ Reads = $reads; Absent = $absent }
        }

        $pools = @()
        $handles = @()
        $writeFailures = 0
        try {
            for ($i = 0; $i -lt 2; $i++) {
                $ps = [powershell]::Create()
                [void]$ps.AddScript($readerScript).AddArgument($statePath).AddArgument($stopPath)
                $pools += $ps
                $handles += $ps.BeginInvoke()
            }
            Start-Sleep -Milliseconds 100
            for ($i = 0; $i -lt 50; $i++) {
                $r = Start-GsLifecycle -Config $cfg -StartOperation $noop
                if (-not $r.Success) { $writeFailures++ }
                $r = Stop-GsLifecycle -Config $cfg -StopOperation $noop
                if (-not $r.Success) { $writeFailures++ }
            }
            New-Item -ItemType File -Path $stopPath -Force | Out-Null
            $results = @()
            for ($i = 0; $i -lt $pools.Count; $i++) { $results += $pools[$i].EndInvoke($handles[$i]) | Select-Object -Last 1 }
        } finally {
            if (-not [System.IO.File]::Exists($stopPath)) { New-Item -ItemType File -Path $stopPath -Force | Out-Null }
            foreach ($ps in $pools) { $ps.Dispose() }
        }

        $reads = 0
        $absent = 0
        foreach ($x in $results) { $reads += $x.Reads; $absent += $x.Absent }
        Assert-True ($reads -gt 500) "readers ran (reads=$reads)"
        Assert-Equal 0 $absent 'the state file was never absent'
        Assert-Equal 0 $writeFailures 'no transition failed to persist'
        Assert-Equal 'Stopped' (Read-RawState $cfg).state 'final state'
        Assert-Equal 0 (Get-TempLeftovers $cfg).Count 'temp removed'
    }

    Invoke-Test 'Read: a brief sharing violation is retried, not reported as a failed state' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $p = Get-StatePath $cfg
        $fs = [System.IO.File]::Open($p, 'Open', 'Read', 'None')
        $ps = [powershell]::Create()
        [void]$ps.AddScript({ param($Handle) Start-Sleep -Milliseconds 40; $Handle.Dispose() }).AddArgument($fs)
        $h = $ps.BeginInvoke()
        try {
            $g = Get-GsLifecycleState -Config $cfg
        } finally {
            $ps.EndInvoke($h)
            $ps.Dispose()
            if ($null -ne $fs) { $fs.Dispose() }
        }
        Assert-Equal 'File' $g.Source 'the read was retried'
        Assert-Equal 'Running' $g.State.State 'state read'
    }

    # -------------------------------------------------------------------
    # Corrupt state
    # -------------------------------------------------------------------
    $corruptCases = [ordered]@{
        'empty file'               = ''
        'garbage'                  = '{{{ not json'
        'json array root'          = '["Running"]'
        'missing schemaVersion'    = '{"state":"Running","changedAtUtc":"2026-01-01T00:00:00.0000000Z","error":null}'
        'schemaVersion 2'          = '{"schemaVersion":2,"state":"Running","changedAtUtc":"2026-01-01T00:00:00.0000000Z","error":null}'
        'unknown state'            = '{"schemaVersion":1,"state":"Zombie","changedAtUtc":"2026-01-01T00:00:00.0000000Z","error":null}'
        'lowercase state'          = '{"schemaVersion":1,"state":"running","changedAtUtc":"2026-01-01T00:00:00.0000000Z","error":null}'
        'non-string state'         = '{"schemaVersion":1,"state":2,"changedAtUtc":"2026-01-01T00:00:00.0000000Z","error":null}'
        'bad timestamp'            = '{"schemaVersion":1,"state":"Running","changedAtUtc":"yesterday","error":null}'
        'local timestamp'          = '{"schemaVersion":1,"state":"Running","changedAtUtc":"2026-01-01T00:00:00.0000000+08:00","error":null}'
        'missing error'            = '{"schemaVersion":1,"state":"Running","changedAtUtc":"2026-01-01T00:00:00.0000000Z"}'
        'Running with error'       = '{"schemaVersion":1,"state":"Running","changedAtUtc":"2026-01-01T00:00:00.0000000Z","error":{"code":"X"}}'
        'Failed without error'     = '{"schemaVersion":1,"state":"Failed","changedAtUtc":"2026-01-01T00:00:00.0000000Z","error":null}'
        'Failed bad diagnostics'   = '{"schemaVersion":1,"state":"Failed","changedAtUtc":"2026-01-01T00:00:00.0000000Z","error":{"code":"X","occurredAtUtc":"2026-01-01T00:00:00.0000000Z","diagnostics":5}}'
        'truncated write'          = '{"schemaVersion":1,"state":"Running","changedAt'
    }
    foreach ($name in $corruptCases.Keys) {
        $n = $name; $content = $corruptCases[$name]
        Invoke-Test "Corrupt: $n reads as Failed, never Running" {
            $cfg = New-TestEnv
            [System.IO.File]::WriteAllText((Get-StatePath $cfg), $content, $utf8)
            $g = Get-GsLifecycleState -Config $cfg
            Assert-Equal 'Corrupt' $g.Source 'source'
            Assert-Equal 'Failed' $g.State.State 'state'
            Assert-Equal 'StateCorrupt' $g.State.Error.Code 'error code'
            Assert-Equal $content ([System.IO.File]::ReadAllText((Get-StatePath $cfg))) 'Get does not modify'
        }
    }

    Invoke-Test 'Corrupt: transition persists Failed first, backs up the bad file, then applies rules' {
        $cfg = New-TestEnv
        [System.IO.File]::WriteAllText((Get-StatePath $cfg), 'garbage', $utf8)
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Running'
        Assert-True (-not $r.Success) 'Failed -> Running rejected'
        Assert-Equal 'IllegalTransition' $r.Code 'code'
        Assert-Equal 'Failed' $r.From 'from Failed'
        $raw = Read-RawState $cfg
        Assert-Equal 'Failed' $raw.state 'persisted Failed'
        Assert-Equal 'StateCorrupt' $raw.error.code 'persisted code'
        Assert-Equal 'InvalidJson' $raw.error.diagnostics.reason 'reason'
        Assert-Equal 'garbage' ([System.IO.File]::ReadAllText((Get-StatePath $cfg) + '.corrupt')) 'backup kept'
    }

    Invoke-Test 'Corrupt: Start-GsLifecycle recovers via Failed -> Starting -> Running' {
        $cfg = New-TestEnv
        [System.IO.File]::WriteAllText((Get-StatePath $cfg), '{"schemaVersion":1,"state":"Running"', $utf8)
        $r = Start-GsLifecycle -Config $cfg -StartOperation $okOp
        Assert-True $r.Success "start: $($r.Message)"
        Assert-Equal 'Failed' $r.From 'recovered from Failed'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'Running'
    }

    Invoke-Test 'Corrupt: locked (unreadable) state file reports Failed and is not overwritten' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $fs = [System.IO.File]::Open((Get-StatePath $cfg), 'Open', 'Read', 'None')
        try {
            $g = Get-GsLifecycleState -Config $cfg
            $r = Stop-GsLifecycle -Config $cfg -StopOperation $okOp
        } finally { $fs.Dispose() }
        Assert-Equal 'ReadFailed' $g.Source 'source'
        Assert-Equal 'Failed' $g.State.State 'Failed, not Running'
        Assert-True (-not $r.Success) 'stop refused'
        Assert-Equal 'StateReadFailed' $r.Code 'code'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'file untouched'
    }

    # -------------------------------------------------------------------
    # Start / Stop with injected operations
    # -------------------------------------------------------------------
    Invoke-Test 'Start: refused when no operation injected' {
        $cfg = New-TestEnv
        $r = Start-GsLifecycle -Config $cfg
        Assert-True (-not $r.Success) 'fail'
        Assert-Equal 'OperationNotProvided' $r.Code 'code'
        Assert-True (-not (Test-Path -LiteralPath (Get-StatePath $cfg))) 'no state written'
        $r2 = Start-GsLifecycle -Config $cfg -StartOperation $null
        Assert-Equal 'OperationNotProvided' $r2.Code 'explicit null'
    }

    Invoke-Test 'Stop: refused when no operation injected' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $r = Stop-GsLifecycle -Config $cfg
        Assert-Equal 'OperationNotProvided' $r.Code 'code'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'unchanged'
    }

    Invoke-Test 'Start: Stopped -> Running; callback sees Starting persisted and gets context' {
        $cfg = New-TestEnv
        $seen = @{}
        $op = {
            param($ctx)
            $seen['ctx'] = $ctx
            $seen['stateDuring'] = (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $ctx.StateDir 'lifecycle-state.json')))).state
        }.GetNewClosure()
        $r = Start-GsLifecycle -Config $cfg -StartOperation $op
        Assert-True $r.Success "ok: $($r.Message)"
        Assert-Equal 'Stopped' $r.From 'from'
        Assert-Equal 'Running' $r.State.State 'state'
        Assert-Equal 'Starting' $seen['stateDuring'] 'Starting persisted before callback'
        Assert-Equal 'Start' $seen['ctx'].Action 'Action'
        Assert-Equal 'Stopped' $seen['ctx'].From 'ctx From'
        Assert-Equal $cfg.InstallDir $seen['ctx'].InstallDir 'InstallDir'
        Assert-Equal $cfg.LogDir $seen['ctx'].LogDir 'LogDir'
    }

    Invoke-Test 'Start: from Paused and from Failed succeed' {
        foreach ($s in @('Paused', 'Failed')) {
            $cfg = New-TestEnv
            Set-TestState $cfg $s
            $r = Start-GsLifecycle -Config $cfg -StartOperation $okOp
            Assert-True $r.Success "$s : $($r.Message)"
            Assert-Equal 'Running' (Read-RawState $cfg).state "$s -> Running"
        }
    }

    Invoke-Test 'Start: repeated start is rejected without calling the operation' {
        $cfg = New-TestEnv
        $null = Start-GsLifecycle -Config $cfg -StartOperation $okOp
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        $r = Start-GsLifecycle -Config $cfg -StartOperation $count
        Assert-True (-not $r.Success) 'fail'
        Assert-Equal 'AlreadyRunning' $r.Code 'code'
        Assert-Equal 0 $calls.n 'operation not called'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'still Running'
    }

    Invoke-Test 'Start: result reports OperationInvoked/OperationSucceeded on success' {
        $cfg = New-TestEnv
        $r = Start-GsLifecycle -Config $cfg -StartOperation $okOp
        Assert-Equal $true $r.OperationInvoked 'invoked'
        Assert-Equal $true $r.OperationSucceeded 'succeeded'
        Assert-True ($null -eq $r.Recovered) 'nothing recovered'
        $r2 = Start-GsLifecycle -Config $cfg -StartOperation $okOp
        Assert-Equal $false $r2.OperationInvoked 'AlreadyRunning: not invoked'
    }

    Invoke-Test 'Start: operation throws -> Failed with StartOperationFailed, message not persisted' {
        $cfg = New-TestEnv
        $r = Start-GsLifecycle -Config $cfg -StartOperation $throwOp
        Assert-True (-not $r.Success) 'fail'
        Assert-Equal 'StartOperationFailed' $r.Code 'code'
        Assert-True ($r.OperationError -like '*synthetic failure*') 'operation error reported to caller'
        Assert-Equal 'Failed' $r.State.State 'result state Failed'
        $text = [System.IO.File]::ReadAllText((Get-StatePath $cfg))
        $raw = ConvertFrom-Json -InputObject $text
        Assert-Equal 'Failed' $raw.state 'persisted Failed'
        Assert-Equal 'StartOperationFailed' $raw.error.code 'persisted code'
        Assert-Equal 'System.Management.Automation.RuntimeException' $raw.error.diagnostics.exceptionType 'exception type'
        Assert-True ($text -notmatch 'hunter2') 'exception message not persisted'
    }

    Invoke-Test 'Start: operation returning $false -> Failed' {
        $cfg = New-TestEnv
        $r = Start-GsLifecycle -Config $cfg -StartOperation $falseOp
        Assert-Equal 'StartOperationFailed' $r.Code 'code'
        Assert-Equal 'ReturnedFalse' (Read-RawState $cfg).error.diagnostics.reason 'reason'
    }

    Invoke-Test 'Stop: Running -> Stopped; callback runs before Stopping is persisted' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $seen = @{}
        $op = {
            param($ctx)
            $seen['ctx'] = $ctx
            $seen['stateDuring'] = (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $ctx.StateDir 'lifecycle-state.json')))).state
        }.GetNewClosure()
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $op
        Assert-True $r.Success "ok: $($r.Message)"
        Assert-Equal 'Running' $r.From 'from'
        Assert-Equal 'Stopped' (Read-RawState $cfg).state 'Stopped'
        Assert-Equal 'Running' $seen['stateDuring'] 'state during callback'
        Assert-Equal 'Stop' $seen['ctx'].Action 'Action'
    }

    Invoke-Test 'Stop: Failed -> Stopped' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Failed'
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $okOp
        Assert-True $r.Success "ok: $($r.Message)"
        Assert-Equal 'Stopped' (Read-RawState $cfg).state 'Stopped'
        Assert-True ($null -eq (Read-RawState $cfg).error) 'error cleared'
    }

    Invoke-Test 'Stop: repeated stop is rejected without calling the operation' {
        $cfg = New-TestEnv
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $count
        Assert-Equal 'AlreadyStopped' $r.Code 'default Stopped'
        Set-TestState $cfg 'Running'
        $r1 = Stop-GsLifecycle -Config $cfg -StopOperation $count
        $r2 = Stop-GsLifecycle -Config $cfg -StopOperation $count
        Assert-True $r1.Success 'first stop'
        Assert-Equal 'AlreadyStopped' $r2.Code 'second stop'
        Assert-Equal 1 $calls.n 'operation called once'
    }

    Invoke-Test 'Stop: from Paused rejected without calling the operation' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Paused'
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $count
        Assert-Equal 'IllegalTransition' $r.Code 'code'
        Assert-Equal 0 $calls.n 'not called'
        Assert-Equal 'Paused' (Read-RawState $cfg).state 'unchanged'
        Assert-True ($null -eq $r.Recovered) 'nothing recovered'
    }

    # -------------------------------------------------------------------
    # Interrupted Starting / Stopping (no live lock holder)
    # -------------------------------------------------------------------
    Invoke-Test 'Recover: Get reports residual Starting/Stopping as Interrupted, without writing' {
        foreach ($s in @('Starting', 'Stopping')) {
            $cfg = New-TestEnv
            Set-TestState $cfg $s
            $before = [System.IO.File]::ReadAllText((Get-StatePath $cfg))
            $g = Get-GsLifecycleState -Config $cfg
            Assert-Equal $s $g.State.State "$s reported as-is"
            Assert-Equal $true $g.Interrupted "$s Interrupted"
            Assert-Equal $before ([System.IO.File]::ReadAllText((Get-StatePath $cfg))) "$s not modified"
        }
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        Assert-Equal $false (Get-GsLifecycleState -Config $cfg).Interrupted 'Running not interrupted'
    }

    Invoke-Test 'Recover: Get reports Interrupted=false while a live holder owns the lock' {
        $cfg = New-TestEnv
        $seen = @{}
        $op = { param($ctx) $seen['g'] = Get-GsLifecycleState -Config $cfg }.GetNewClosure()
        $r = Start-GsLifecycle -Config $cfg -StartOperation $op
        Assert-True $r.Success 'start ok'
        Assert-Equal 'Starting' $seen['g'].State.State 'Starting during callback'
        Assert-Equal $false $seen['g'].Interrupted 'not interrupted while in progress'
    }

    Invoke-Test 'Recover: Start from residual Starting -> Failed(StartInterrupted) -> Starting -> Running' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Starting'
        $seen = @{}
        $op = { param($ctx) $seen['from'] = $ctx.From }.GetNewClosure()
        $r = Start-GsLifecycle -Config $cfg -StartOperation $op
        Assert-True $r.Success "ok: $($r.Message)"
        Assert-Equal 'Failed' $r.From 'From after recovery'
        Assert-Equal 'Failed' $seen['from'] 'callback sees Failed'
        Assert-Equal 'StartInterrupted' $r.Recovered.Code 'Recovered.Code'
        Assert-Equal 'Starting' $r.Recovered.From 'Recovered.From'
        Assert-Equal 'Failed' $r.Recovered.To 'Recovered.To'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'Running'
    }

    Invoke-Test 'Recover: Start from residual Starting with failing operation stays Failed' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Starting'
        $r = Start-GsLifecycle -Config $cfg -StartOperation $throwOp
        Assert-Equal 'StartOperationFailed' $r.Code 'code'
        Assert-Equal 'StartInterrupted' $r.Recovered.Code 'recovered'
        Assert-Equal 'Failed' (Read-RawState $cfg).state 'Failed'
    }

    Invoke-Test 'Recover: Stop from residual Starting -> Failed(StartInterrupted), then stop callback runs' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Starting'
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $count
        Assert-True $r.Success "ok: $($r.Message)"
        Assert-Equal 1 $calls.n 'stop callback called (component state unknown)'
        Assert-Equal 'StartInterrupted' $r.Recovered.Code 'recovered'
        Assert-Equal 'Failed' $r.From 'From'
        Assert-Equal 'Stopped' (Read-RawState $cfg).state 'Stopped'
    }

    Invoke-Test 'Recover: Stop from residual Starting with failing callback stays Failed(StartInterrupted)' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Starting'
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $throwOp
        Assert-Equal 'StopOperationFailed' $r.Code 'code'
        Assert-Equal 'Failed' $r.State.State 'Failed'
        Assert-Equal 'StartInterrupted' (Read-RawState $cfg).error.code 'interruption recorded'
    }

    Invoke-Test 'Recover: Stop from residual Stopping completes to Stopped without the callback' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Stopping'
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $count
        Assert-True $r.Success "ok: $($r.Message)"
        Assert-Equal 0 $calls.n 'callback not called again'
        Assert-Equal 'StopCompleted' $r.Recovered.Code 'recovered'
        Assert-Equal $false $r.OperationInvoked 'OperationInvoked false'
        Assert-Equal 'Stopped' (Read-RawState $cfg).state 'Stopped'
    }

    Invoke-Test 'Recover: Start from residual Stopping -> Stopped(StopCompleted) -> Running' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Stopping'
        $r = Start-GsLifecycle -Config $cfg -StartOperation $okOp
        Assert-True $r.Success "ok: $($r.Message)"
        Assert-Equal 'StopCompleted' $r.Recovered.Code 'recovered'
        Assert-Equal 'Stopped' $r.From 'From'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'Running'
    }

    Invoke-Test 'Recover: recovery write failure is reported, state unchanged, callback not run' {
        foreach ($s in @('Starting', 'Stopping')) {
            $cfg = New-TestEnv
            Set-TestState $cfg $s
            $p = Get-StatePath $cfg
            $calls = @{ n = 0 }
            $count = { param($ctx) $calls.n++ }.GetNewClosure()
            [System.IO.File]::SetAttributes($p, [System.IO.FileAttributes]::ReadOnly)
            try {
                $r1 = Start-GsLifecycle -Config $cfg -StartOperation $count
                $r2 = Stop-GsLifecycle -Config $cfg -StopOperation $count
            } finally { [System.IO.File]::SetAttributes($p, [System.IO.FileAttributes]::Normal) }
            foreach ($r in @($r1, $r2)) {
                Assert-Equal 'PersistFailed' $r.Code "$s code"
                Assert-True ($r.Message -like "*Interrupted $s*") "$s message"
            }
            Assert-Equal 0 $calls.n "$s callback not run"
            Assert-Equal $s (Read-RawState $cfg).state "$s unchanged"
        }
    }

    Invoke-Test 'Recover: Invoke-GsLifecycleTransition does not repair residual states' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Starting'
        $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Failed' -ErrorCode 'Manual'
        Assert-True $r.Success 'Starting -> Failed is a legal direct edge'
        Assert-True ($null -eq $r.Recovered) 'no recovery'
        Assert-Equal 'Manual' (Read-RawState $cfg).error.code 'caller code kept'
    }

    # -------------------------------------------------------------------
    # Write failures in the middle of Start / Stop (fault injection on the
    # Nth state write through the module-internal seam)
    # -------------------------------------------------------------------
    function Invoke-WithWriteFault {
        # Fails every state write whose target State is in $FailStates.
        param([string[]]$FailStates, [scriptblock]$Body)
        $mod = Get-Module GsLifecycle
        $fault = { param($rec) if ($FailStates -ccontains $rec.State) { throw "injected write fault for $($rec.State)" } }.GetNewClosure()
        & $mod { param($f) $script:TestWriteFault = $f } $fault
        try { & $Body } finally { & $mod { $script:TestWriteFault = $null } }
    }

    Invoke-Test 'MidWrite: Start op succeeds, Running write fails -> Failed(StartPersistFailed), OperationSucceeded' {
        $cfg = New-TestEnv
        $r = Invoke-WithWriteFault @('Running') { Start-GsLifecycle -Config $cfg -StartOperation $okOp }
        Assert-True (-not $r.Success) 'not success'
        Assert-Equal 'PersistFailed' $r.Code 'code'
        Assert-Equal $true $r.OperationInvoked 'OperationInvoked'
        Assert-Equal $true $r.OperationSucceeded 'OperationSucceeded'
        Assert-True ($r.Message -like '*may be running*') 'message warns'
        Assert-Equal 'Failed' $r.State.State 'result Failed'
        $raw = Read-RawState $cfg
        Assert-Equal 'Failed' $raw.state 'persisted Failed'
        Assert-Equal 'StartPersistFailed' $raw.error.code 'code persisted'
        $s = Stop-GsLifecycle -Config $cfg -StopOperation $okOp
        Assert-True $s.Success 'Stop can clean up afterwards'
    }

    Invoke-Test 'MidWrite: Start op succeeds, Running and Failed writes fail -> Starting left, next call recovers' {
        $cfg = New-TestEnv
        $r = Invoke-WithWriteFault @('Running', 'Failed') { Start-GsLifecycle -Config $cfg -StartOperation $okOp }
        Assert-Equal 'PersistFailed' $r.Code 'code'
        Assert-Equal $true $r.OperationSucceeded 'OperationSucceeded'
        Assert-Equal 'Starting' $r.State.State 'reports Starting'
        Assert-Equal 'Starting' (Read-RawState $cfg).state 'Starting persisted'
        Assert-Equal $true (Get-GsLifecycleState -Config $cfg).Interrupted 'Interrupted'
        $s = Stop-GsLifecycle -Config $cfg -StopOperation $okOp
        Assert-True $s.Success "stop recovers: $($s.Message)"
        Assert-Equal 'StartInterrupted' $s.Recovered.Code 'recovered'
        Assert-Equal 'Stopped' (Read-RawState $cfg).state 'Stopped'
    }

    Invoke-Test 'MidWrite: Starting write fails -> operation not invoked' {
        $cfg = New-TestEnv
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        $r = Invoke-WithWriteFault @('Starting') { Start-GsLifecycle -Config $cfg -StartOperation $count }
        Assert-Equal 'PersistFailed' $r.Code 'code'
        Assert-Equal $false $r.OperationInvoked 'OperationInvoked false'
        Assert-True ($null -eq $r.OperationSucceeded) 'OperationSucceeded null'
        Assert-Equal 0 $calls.n 'not called'
    }

    Invoke-Test 'MidWrite: Start op fails and Failed write fails -> PersistFailed, OperationSucceeded false' {
        $cfg = New-TestEnv
        $r = Invoke-WithWriteFault @('Failed') { Start-GsLifecycle -Config $cfg -StartOperation $throwOp }
        Assert-Equal 'PersistFailed' $r.Code 'code'
        Assert-Equal $false $r.OperationSucceeded 'OperationSucceeded false'
        Assert-True ($r.OperationError -like '*synthetic*') 'OperationError kept'
        Assert-Equal 'Starting' (Read-RawState $cfg).state 'Starting left for recovery'
    }

    Invoke-Test 'MidWrite: Stop op succeeds, Stopping write fails -> Failed(StopPersistFailed)' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $r = Invoke-WithWriteFault @('Stopping') { Stop-GsLifecycle -Config $cfg -StopOperation $okOp }
        Assert-Equal 'PersistFailed' $r.Code 'code'
        Assert-Equal $true $r.OperationSucceeded 'OperationSucceeded'
        Assert-True ($r.Message -like '*may be stopped*') 'message'
        Assert-Equal 'StopPersistFailed' (Read-RawState $cfg).error.code 'Failed recorded'
    }

    Invoke-Test 'MidWrite: Stop op succeeds, Stopping and Failed writes fail -> Running left, reported' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $r = Invoke-WithWriteFault @('Stopping', 'Failed') { Stop-GsLifecycle -Config $cfg -StopOperation $okOp }
        Assert-Equal 'PersistFailed' $r.Code 'code'
        Assert-Equal $true $r.OperationSucceeded 'OperationSucceeded'
        Assert-True ($r.Message -like '*still says Running*') 'message'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'Running remains'
    }

    Invoke-Test 'MidWrite: Stop op succeeds, Stopped write fails -> Stopping left, next Stop completes' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        $r = Invoke-WithWriteFault @('Stopped') { Stop-GsLifecycle -Config $cfg -StopOperation $count }
        Assert-Equal 'PersistFailed' $r.Code 'code'
        Assert-Equal $true $r.OperationSucceeded 'OperationSucceeded'
        Assert-Equal 'Stopping' (Read-RawState $cfg).state 'Stopping persisted'
        $r2 = Stop-GsLifecycle -Config $cfg -StopOperation $count
        Assert-True $r2.Success 'completed'
        Assert-Equal 'StopCompleted' $r2.Recovered.Code 'recovered'
        Assert-Equal 1 $calls.n 'stop callback ran once overall'
        Assert-Equal 'Stopped' (Read-RawState $cfg).state 'Stopped'
    }

    Invoke-Test 'MidWrite: Stop callback fails from Running and Failed write fails -> PersistFailed, Running left' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $r = Invoke-WithWriteFault @('Failed') { Stop-GsLifecycle -Config $cfg -StopOperation $throwOp }
        Assert-Equal 'PersistFailed' $r.Code 'code'
        Assert-Equal $false $r.OperationSucceeded 'OperationSucceeded false'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'unchanged'
    }

    # -------------------------------------------------------------------
    # Process crash during a callback (real child powershell.exe, synthetic dirs)
    # -------------------------------------------------------------------
    function Invoke-CrashingChild {
        # Runs Start or Stop in a child process whose callback kills its own
        # process with [Environment]::Exit, simulating a crash mid-operation.
        param($Cfg, [ValidateSet('Start', 'Stop')][string]$Action)
        $script = Join-Path $workDir ("crash_" + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = @'
param($Manifest, $InstallDir, $StateDir, $LogDir, $Action)
Import-Module $Manifest -Force
$cfg = [pscustomobject]@{ InstallDir = $InstallDir; StateDir = $StateDir; LogDir = $LogDir }
$die = { param($ctx) [System.Environment]::Exit(77) }
if ($Action -eq 'Start') { $null = Start-GsLifecycle -Config $cfg -StartOperation $die }
else { $null = Stop-GsLifecycle -Config $cfg -StopOperation $die }
exit 0
'@
        [System.IO.File]::WriteAllText($script, $body, $utf8)
        $exe = Join-Path $PSHOME 'powershell.exe'
        & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $manifestPath $Cfg.InstallDir $Cfg.StateDir $Cfg.LogDir $Action | Out-Null
        return $LASTEXITCODE
    }

    Invoke-Test 'Crash: child dies inside start callback -> Starting left, lock freed, recovered as StartInterrupted' {
        $cfg = New-TestEnv
        $code = Invoke-CrashingChild $cfg 'Start'
        Assert-Equal 77 $code 'child exited from inside callback'
        Assert-Equal 'Starting' (Read-RawState $cfg).state 'Starting left behind'
        $g = Get-GsLifecycleState -Config $cfg
        Assert-Equal $true $g.Interrupted 'Interrupted (lock released by OS)'
        $r = Start-GsLifecycle -Config $cfg -StartOperation $okOp
        Assert-True $r.Success "restart: $($r.Message)"
        Assert-Equal 'StartInterrupted' $r.Recovered.Code 'recovered'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'Running'
    }

    Invoke-Test 'Crash: child dies inside stop callback -> Running left, Stop retried successfully' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $code = Invoke-CrashingChild $cfg 'Stop'
        Assert-Equal 77 $code 'child exited from inside callback'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'Running (Stopping is written only after the callback)'
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $okOp
        Assert-True $r.Success "retry: $($r.Message)"
        Assert-Equal 'Stopped' (Read-RawState $cfg).state 'Stopped'
    }

    # -------------------------------------------------------------------
    # Non-terminating errors in callbacks
    # -------------------------------------------------------------------
    $ntCases = [ordered]@{
        'Write-Error only'                    = { param($ctx) Write-Error 'synthetic non-terminating' }
        'failing cmdlet (Get-Item missing)'   = { param($ctx) Get-Item -LiteralPath (Join-Path $ctx.StateDir 'no-such-file') }
        'Write-Error then normal output'      = { param($ctx) Write-Error 'oops'; 'continued' }
        'local EAP Continue override'         = { param($ctx) $ErrorActionPreference = 'Continue'; Write-Error 'override'; 'continued' }
        'explicit -ErrorAction Continue'      = { param($ctx) Write-Error 'explicit' -ErrorAction Continue; 'continued' }
    }
    foreach ($name in $ntCases.Keys) {
        $n = $name; $op = $ntCases[$name]
        # The test script runs with EAP=Stop, which callbacks would inherit.
        # Callers normally run with the default Continue, so use that here.
        Invoke-Test "NonTerminating: start callback '$n' -> Failed, not Running (caller EAP Continue)" {
            $cfg = New-TestEnv
            $ErrorActionPreference = 'Continue'
            $r = Start-GsLifecycle -Config $cfg -StartOperation $op
            $ErrorActionPreference = 'Stop'
            Assert-True (-not $r.Success) 'not success'
            Assert-Equal 'StartOperationFailed' $r.Code 'code'
            Assert-Equal $false $r.OperationSucceeded 'OperationSucceeded false'
            $raw = Read-RawState $cfg
            Assert-Equal 'Failed' $raw.state 'Failed'
            Assert-Equal 'NonTerminatingError' $raw.error.diagnostics.reason 'reason'
        }
        Invoke-Test "NonTerminating: stop callback '$n' -> Failed, not Stopped (caller EAP Continue)" {
            $cfg = New-TestEnv
            Set-TestState $cfg 'Running'
            $ErrorActionPreference = 'Continue'
            $r = Stop-GsLifecycle -Config $cfg -StopOperation $op
            $ErrorActionPreference = 'Stop'
            Assert-Equal 'StopOperationFailed' $r.Code 'code'
            Assert-Equal 'Failed' (Read-RawState $cfg).state 'Failed'
        }
    }

    Invoke-Test 'NonTerminating: handled error inside try/catch, warnings and verbose do not fail' {
        $cfg = New-TestEnv
        $op = {
            param($ctx)
            try { Get-Item -LiteralPath (Join-Path $ctx.StateDir 'no-such-file') } catch { $null = 'handled' }
            Write-Warning 'synthetic warning' 3>$null
            Write-Verbose 'synthetic verbose'
            'some output'; 1; $true
        }
        $r = Start-GsLifecycle -Config $cfg -StartOperation $op
        Assert-True $r.Success "ok: $($r.Message)"
    }

    Invoke-Test 'NonTerminating: caller ErrorActionPreference is not changed' {
        $cfg = New-TestEnv
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = Start-GsLifecycle -Config $cfg -StartOperation { param($ctx) Write-Error 'x' }
            Assert-Equal 'Continue' $ErrorActionPreference 'unchanged'
        } finally { $ErrorActionPreference = $saved }
    }

    # -------------------------------------------------------------------
    # Control flow escaping a callback (break / continue / labeled / exit).
    # Each call runs inside a labeled 2-iteration caller loop; the loop must
    # complete both iterations and every call must return a result object.
    # -------------------------------------------------------------------
    $cfCases = [ordered]@{
        'break'                = @{ Op = { param($ctx) break }; Type = 'System.Management.Automation.BreakException' }
        'continue'             = @{ Op = { param($ctx) continue }; Type = 'System.Management.Automation.ContinueException' }
        'break callerLoop'     = @{ Op = { param($ctx) break callerLoop }; Type = 'System.Management.Automation.BreakException' }
        'continue callerLoop'  = @{ Op = { param($ctx) continue callerLoop }; Type = 'System.Management.Automation.ContinueException' }
        'break inside if'      = @{ Op = { param($ctx) 'partial output'; if ($true) { break } }; Type = 'System.Management.Automation.BreakException' }
        'exit'                 = @{ Op = { param($ctx) exit 5 }; Type = 'System.Management.Automation.ExitException' }
    }

    # Runs $Call twice inside a labeled caller loop and reports what survived.
    function Invoke-InCallerLoop {
        param([scriptblock]$Call)
        $state = @{ results = New-Object System.Collections.Generic.List[object]; reached = 0; afterLoop = $false }
        :callerLoop foreach ($i in 1..2) {
            $state.results.Add((& $Call))
            $state.reached++
        }
        $state.afterLoop = $true
        return $state
    }

    foreach ($name in $cfCases.Keys) {
        $n = $name; $case = $cfCases[$name]
        Invoke-Test "ControlFlow: start callback '$n' -> structured Failed result, caller loop intact" {
            $cfg = New-TestEnv
            $op = $case.Op
            $s = Invoke-InCallerLoop { Start-GsLifecycle -Config $cfg -StartOperation $op }.GetNewClosure()
            Assert-True $s.afterLoop 'code after caller loop ran'
            Assert-Equal 2 $s.reached 'both caller iterations completed'
            Assert-Equal 2 $s.results.Count 'two results'
            $r1 = $s.results[0]
            Assert-True ($null -ne $r1) 'first call returned a result'
            Assert-Equal $false $r1.Success 'not success'
            Assert-Equal 'StartOperationFailed' $r1.Code 'code'
            Assert-Equal $true $r1.OperationInvoked 'invoked'
            Assert-Equal $false $r1.OperationSucceeded 'not succeeded'
            Assert-True ($r1.OperationError -like '*control-flow*') "OperationError: $($r1.OperationError)"
            Assert-Equal 'Failed' $r1.State.State 'result Failed'
            $raw = Read-RawState $cfg
            Assert-Equal 'Failed' $raw.state 'persisted Failed, not Starting'
            Assert-Equal 'StartOperationFailed' $raw.error.code 'error code'
            Assert-Equal 'ControlFlowEscape' $raw.error.diagnostics.reason 'reason'
            Assert-Equal $case.Type $raw.error.diagnostics.exceptionType 'flow-control type'
            # Second call starts from Failed and fails the same way; nothing left Starting.
            Assert-Equal 'StartOperationFailed' $s.results[1].Code 'second call also structured'
            Assert-Equal $false (Get-GsLifecycleState -Config $cfg).Interrupted 'not left interrupted'
            Assert-True (Start-GsLifecycle -Config $cfg -StartOperation $okOp).Success 'lock released; later start works'
        }
        Invoke-Test "ControlFlow: stop callback '$n' -> Failed (not Stopped), caller loop intact" {
            $cfg = New-TestEnv
            Set-TestState $cfg 'Running'
            $op = $case.Op
            $s = Invoke-InCallerLoop { Stop-GsLifecycle -Config $cfg -StopOperation $op }.GetNewClosure()
            Assert-True $s.afterLoop 'code after caller loop ran'
            Assert-Equal 2 $s.reached 'both caller iterations completed'
            $r1 = $s.results[0]
            Assert-True ($null -ne $r1) 'first call returned a result'
            Assert-Equal 'StopOperationFailed' $r1.Code 'code'
            Assert-Equal $false $r1.OperationSucceeded 'not succeeded'
            Assert-Equal 'Failed' $r1.State.State 'result Failed'
            Assert-Equal 'Running' $r1.From 'from Running'
            # Second call: Failed -> callback escapes again -> stays Failed with first error.
            Assert-Equal 'StopOperationFailed' $s.results[1].Code 'second call structured'
            Assert-Equal 'Failed' $s.results[1].From 'second from Failed'
            $raw = Read-RawState $cfg
            Assert-Equal 'Failed' $raw.state 'persisted Failed'
            Assert-Equal 'ControlFlowEscape' $raw.error.diagnostics.reason 'reason'
            Assert-True (Stop-GsLifecycle -Config $cfg -StopOperation $okOp).Success 'lock released; later stop works'
        }
    }

    Invoke-Test 'ControlFlow: loops and return fully inside the callback are allowed' {
        $cfg = New-TestEnv
        $op = {
            param($ctx)
            foreach ($i in 1..3) { if ($i -eq 2) { continue }; if ($i -eq 3) { break } }
            :inner while ($true) { break inner }
            switch (1) { 1 { break } }
            return 'done'
        }
        $s = Invoke-InCallerLoop { Start-GsLifecycle -Config $cfg -StartOperation $op }.GetNewClosure()
        Assert-Equal 2 $s.reached 'caller loop intact'
        Assert-True $s.results[0].Success "first start ok: $($s.results[0].Message)"
        Assert-Equal 'AlreadyRunning' $s.results[1].Code 'second start AlreadyRunning'
    }

    Invoke-Test 'ControlFlow: exit in a callback does not end the host process' {
        $cfg = New-TestEnv
        $r = Start-GsLifecycle -Config $cfg -StartOperation { param($ctx) exit 9 }
        Assert-Equal 'StartOperationFailed' $r.Code 'structured result'
        # Reaching this line proves the test process is still alive.
        Assert-Equal 'Failed' (Read-RawState $cfg).state 'Failed'
    }

    Invoke-Test 'Stop: callback throws while Running -> Failed, not Stopped' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $throwOp
        Assert-True (-not $r.Success) 'not success'
        Assert-Equal 'StopOperationFailed' $r.Code 'code'
        Assert-Equal 'Failed' $r.State.State 'result state'
        Assert-True ($r.OperationError -like '*synthetic failure*') 'reported'
        $raw = Read-RawState $cfg
        Assert-Equal 'Failed' $raw.state 'persisted Failed'
        Assert-Equal 'StopOperationFailed' $raw.error.code 'persisted code'
        Assert-Equal 'Stop' $raw.error.diagnostics.action 'action'
    }

    Invoke-Test 'Stop: callback returns $false while Running -> Failed' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $falseOp
        Assert-Equal 'StopOperationFailed' $r.Code 'code'
        Assert-Equal 'Failed' (Read-RawState $cfg).state 'Failed'
    }

    Invoke-Test 'Stop: callback fails while Failed -> stays Failed with original error, reported' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Failed'
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $throwOp
        Assert-True (-not $r.Success) 'not success'
        Assert-Equal 'StopOperationFailed' $r.Code 'code'
        Assert-Equal 'Failed' $r.State.State 'result Failed'
        $raw = Read-RawState $cfg
        Assert-Equal 'Failed' $raw.state 'persisted Failed'
        Assert-Equal 'SeededFailure' $raw.error.code 'original error kept'
    }

    Invoke-Test 'Stop: after callback failure a retry with a working callback stops' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $null = Stop-GsLifecycle -Config $cfg -StopOperation $throwOp
        $r = Stop-GsLifecycle -Config $cfg -StopOperation $okOp
        Assert-True $r.Success 'retry ok'
        Assert-Equal 'Failed' $r.From 'from Failed'
        Assert-Equal 'Stopped' (Read-RawState $cfg).state 'Stopped'
    }

    Invoke-Test 'Lifecycle: full cycle Stopped -> Running -> Stopped -> Paused -> Running' {
        $cfg = New-TestEnv
        Assert-True (Start-GsLifecycle -Config $cfg -StartOperation $okOp).Success 'start'
        Assert-True (Stop-GsLifecycle -Config $cfg -StopOperation $okOp).Success 'stop'
        Assert-True (Invoke-GsLifecycleTransition -Config $cfg -To 'Paused').Success 'pause'
        Assert-True (Start-GsLifecycle -Config $cfg -StartOperation $okOp).Success 'resume'
        Assert-Equal 'Running' (Get-GsLifecycleState -Config $cfg).State.State 'Running'
        Assert-Equal 0 (Get-TempLeftovers $cfg).Count 'no temp files'
    }

    # -------------------------------------------------------------------
    # Concurrency guard
    # -------------------------------------------------------------------
    Invoke-Test 'Lock: held lock returns Busy and changes nothing' {
        $cfg = New-TestEnv
        $lockPath = Join-Path $cfg.StateDir 'lifecycle.lock'
        $fs = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        try {
            $r1 = Invoke-GsLifecycleTransition -Config $cfg -To 'Paused'
            $r2 = Start-GsLifecycle -Config $cfg -StartOperation $count
            $r3 = Stop-GsLifecycle -Config $cfg -StopOperation $count
        } finally { $fs.Dispose() }
        foreach ($r in @($r1, $r2, $r3)) { Assert-Equal 'Busy' $r.Code 'Busy' }
        Assert-Equal 0 $calls.n 'operation not called'
        Assert-True (-not (Test-Path -LiteralPath (Get-StatePath $cfg))) 'no state written'
    }

    Invoke-Test 'Lock: re-entrant transition from inside a callback is Busy; lock released afterwards' {
        $cfg = New-TestEnv
        $inner = @{}
        $op = { param($ctx) $inner['r'] = Invoke-GsLifecycleTransition -Config $cfg -To 'Failed' -ErrorCode 'X' }.GetNewClosure()
        $r = Start-GsLifecycle -Config $cfg -StartOperation $op
        Assert-Equal 'Busy' $inner['r'].Code 'inner call Busy'
        Assert-True $r.Success 'outer start ok'
        Assert-True (Invoke-GsLifecycleTransition -Config $cfg -To 'Failed' -ErrorCode 'After').Success 'lock released'
    }

    Invoke-Test 'Lock: stale lock file without an open handle does not block' {
        $cfg = New-TestEnv
        [System.IO.File]::WriteAllText((Join-Path $cfg.StateDir 'lifecycle.lock'), 'stale', $utf8)
        Assert-True (Invoke-GsLifecycleTransition -Config $cfg -To 'Paused').Success 'stale lock ignored'
    }

    Invoke-Test 'Lock: lock released after callback throws' {
        $cfg = New-TestEnv
        $null = Start-GsLifecycle -Config $cfg -StartOperation $throwOp
        Assert-True (Start-GsLifecycle -Config $cfg -StartOperation $okOp).Success 'lock released'
    }

    # Applies a Deny ACE for the current user to $Path for the duration of $Body.
    function Invoke-WithDeniedAcl {
        param([string]$Path, [System.Security.AccessControl.FileSystemRights]$Rights, [scriptblock]$Body)
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($me, $Rights, 'Deny')
        $acl = Get-Acl -LiteralPath $Path
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
        try { & $Body } finally {
            $acl = Get-Acl -LiteralPath $Path
            $null = $acl.RemoveAccessRule($rule)
            Set-Acl -LiteralPath $Path -AclObject $acl
        }
    }

    Invoke-Test 'ACL: StateDir denying file creation -> AccessDenied, not Busy' {
        $cfg = New-TestEnv
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        $res = Invoke-WithDeniedAcl $cfg.StateDir ([System.Security.AccessControl.FileSystemRights]'CreateFiles, AppendData') {
            @(
                (Invoke-GsLifecycleTransition -Config $cfg -To 'Paused'),
                (Start-GsLifecycle -Config $cfg -StartOperation $count),
                (Stop-GsLifecycle -Config $cfg -StopOperation $count)
            )
        }
        foreach ($r in $res) {
            Assert-Equal 'AccessDenied' $r.Code 'code'
            Assert-True ($r.Message -like '*lifecycle.lock*') 'message names lock file'
            Assert-True ($r.Message -notlike '*Another lifecycle operation*') 'not reported as Busy'
        }
        Assert-Equal 0 $calls.n 'callbacks not run'
        Assert-True (Invoke-GsLifecycleTransition -Config $cfg -To 'Paused').Success 'works after ACL restored'
    }

    Invoke-Test 'ACL: existing lock file denying write -> AccessDenied' {
        $cfg = New-TestEnv
        $lockPath = Join-Path $cfg.StateDir 'lifecycle.lock'
        [System.IO.File]::WriteAllText($lockPath, '', $utf8)
        $r = Invoke-WithDeniedAcl $lockPath ([System.Security.AccessControl.FileSystemRights]'WriteData') {
            Invoke-GsLifecycleTransition -Config $cfg -To 'Paused'
        }
        Assert-Equal 'AccessDenied' $r.Code 'code'
    }

    Invoke-Test 'ACL: state file denying read -> Get reports ReadFailed/Failed; Start refuses with StateReadFailed' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Running'
        $p = Get-StatePath $cfg
        $calls = @{ n = 0 }
        $count = { param($ctx) $calls.n++ }.GetNewClosure()
        $res = Invoke-WithDeniedAcl $p ([System.Security.AccessControl.FileSystemRights]'ReadData') {
            @((Get-GsLifecycleState -Config $cfg), (Start-GsLifecycle -Config $cfg -StartOperation $count))
        }
        Assert-Equal 'ReadFailed' $res[0].Source 'Get source'
        Assert-Equal 'Failed' $res[0].State.State 'Get state Failed, not Running'
        Assert-Equal 'StateReadFailed' $res[1].Code 'Start code'
        Assert-Equal 0 $calls.n 'callback not run'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'file untouched'
    }

    Invoke-Test 'ACL: StateDir denying file creation -> Get Interrupted is null for residual Starting' {
        $cfg = New-TestEnv
        Set-TestState $cfg 'Starting'
        $g = Invoke-WithDeniedAcl $cfg.StateDir ([System.Security.AccessControl.FileSystemRights]'CreateFiles, AppendData') {
            Get-GsLifecycleState -Config $cfg
        }
        Assert-True ($null -eq $g.Interrupted) 'unknown when lock cannot be probed'
    }

    # Real concurrency: N child powershell.exe processes race Start-GsLifecycle
    # on the same StateDir. Each callback sleeps while holding the lock, so the
    # others must see Busy. Exactly one start may run its operation.
    Invoke-Test 'Race: concurrent Start from separate processes runs the operation exactly once' {
        $cfg = New-TestEnv
        $marker = Join-Path $cfg.LogDir 'op-calls.txt'
        $gate = Join-Path $cfg.LogDir 'go.txt'
        $script = Join-Path $workDir ("race_" + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = @'
param($Manifest, $InstallDir, $StateDir, $LogDir, $Marker, $Gate)
Import-Module $Manifest -Force
$cfg = [pscustomobject]@{ InstallDir = $InstallDir; StateDir = $StateDir; LogDir = $LogDir }
while (-not [System.IO.File]::Exists($Gate)) { Start-Sleep -Milliseconds 10 }
$op = {
    param($ctx)
    [System.IO.File]::AppendAllText($Marker, "$PID`n")
    Start-Sleep -Milliseconds 1500
}.GetNewClosure()
$r = Start-GsLifecycle -Config $cfg -StartOperation $op
[Console]::Out.WriteLine("RESULT=$($r.Code)")
'@
        [System.IO.File]::WriteAllText($script, $body, $utf8)
        $exe = Join-Path $PSHOME 'powershell.exe'
        $n = 4
        $procs = @()
        $outs = @()
        for ($i = 0; $i -lt $n; $i++) {
            $out = Join-Path $workDir ("race_out_" + [guid]::NewGuid().ToString('N') + '.txt')
            $outs += $out
            $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"",
                "`"$manifestPath`"", "`"$($cfg.InstallDir)`"", "`"$($cfg.StateDir)`"", "`"$($cfg.LogDir)`"", "`"$marker`"", "`"$gate`"")
            $procs += Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardOutput $out
        }
        Start-Sleep -Milliseconds 1500
        [System.IO.File]::WriteAllText($gate, 'go', $utf8)
        foreach ($p in $procs) {
            if (-not $p.WaitForExit(60000)) { $p.Kill(); throw "race child $($p.Id) timed out" }
        }
        $codes = @($outs | ForEach-Object { ([System.IO.File]::ReadAllText($_) -split "`r?`n") | Where-Object { $_ -like 'RESULT=*' } } |
                ForEach-Object { $_.Substring(7) })
        Assert-Equal $n $codes.Count "all children reported: $($codes -join ',')"
        Assert-Equal 1 @($codes | Where-Object { $_ -eq 'Ok' }).Count "exactly one Ok: $($codes -join ',')"
        $others = @($codes | Where-Object { $_ -ne 'Ok' })
        foreach ($c in $others) { Assert-True ($c -eq 'Busy' -or $c -eq 'AlreadyRunning') "loser code $c" }
        $calls = @([System.IO.File]::ReadAllLines($marker) | Where-Object { $_ })
        Assert-Equal 1 $calls.Count 'operation ran exactly once'
        Assert-Equal 'Running' (Read-RawState $cfg).state 'Running'
        Assert-Equal 0 (Get-TempLeftovers $cfg).Count 'no temp files'
    }

    # Real concurrency on the low-level entry point: many processes alternate
    # Paused/Failed writes; the file must always parse and never be corrupt.
    Invoke-Test 'Race: concurrent writers from separate processes never corrupt the state file' {
        $cfg = New-TestEnv
        $script = Join-Path $workDir ("writer_" + [guid]::NewGuid().ToString('N') + '.ps1')
        $body = @'
param($Manifest, $InstallDir, $StateDir, $LogDir)
Import-Module $Manifest -Force
$cfg = [pscustomobject]@{ InstallDir = $InstallDir; StateDir = $StateDir; LogDir = $LogDir }
$counts = @{}
for ($i = 0; $i -lt 40; $i++) {
    $g = Get-GsLifecycleState -Config $cfg
    if ($g.Source -eq 'Corrupt') { $counts['CORRUPT'] = 1 + [int]$counts['CORRUPT'] }
    $r = Invoke-GsLifecycleTransition -Config $cfg -To 'Paused'
    $counts[$r.Code] = 1 + [int]$counts[$r.Code]
}
[Console]::Out.WriteLine('COUNTS=' + (($counts.Keys | Sort-Object | ForEach-Object { "$_=$($counts[$_])" }) -join ';'))
'@
        [System.IO.File]::WriteAllText($script, $body, $utf8)
        # Alternate Stopped <-> Paused is not possible directly (Paused -> Stopped
        # needs Start); so seed Stopped and let all writers race the same edge,
        # plus a resetter in this process that rewrites Stopped between rounds.
        $exe = Join-Path $PSHOME 'powershell.exe'
        $procs = @(); $outs = @()
        for ($i = 0; $i -lt 3; $i++) {
            $out = Join-Path $workDir ("writer_out_" + [guid]::NewGuid().ToString('N') + '.txt')
            $outs += $out
            $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"",
                "`"$manifestPath`"", "`"$($cfg.InstallDir)`"", "`"$($cfg.StateDir)`"", "`"$($cfg.LogDir)`"")
            $procs += Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardOutput $out
        }
        $corruptSeen = 0
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (@($procs | Where-Object { -not $_.HasExited }).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            $g = Get-GsLifecycleState -Config $cfg
            if ($g.Source -eq 'Corrupt') { $corruptSeen++ }
            # Reset to Stopped through the supported path so the edge stays legal.
            $null = Start-GsLifecycle -Config $cfg -StartOperation $okOp
            $null = Stop-GsLifecycle -Config $cfg -StopOperation $okOp
        }
        foreach ($p in $procs) { if (-not $p.WaitForExit(30000)) { $p.Kill(); throw "writer $($p.Id) timed out" } }
        $lines = @($outs | ForEach-Object { ([System.IO.File]::ReadAllText($_) -split "`r?`n") | Where-Object { $_ -like 'COUNTS=*' } })
        Assert-Equal 3 $lines.Count "all writers reported: $($lines -join ' | ')"
        foreach ($l in $lines) {
            Assert-True ($l -notmatch 'CORRUPT') "writer saw corrupt file: $l"
            foreach ($pair in ($l.Substring(7) -split ';')) {
                $k = ($pair -split '=')[0]
                Assert-True (@('Ok', 'Busy', 'IllegalTransition') -contains $k) "unexpected code in $l"
            }
        }
        Assert-Equal 0 $corruptSeen 'parent never saw a corrupt file'
        $final = Get-GsLifecycleState -Config $cfg
        Assert-Equal 'File' $final.Source 'final file valid'
        Assert-Equal 0 (Get-TempLeftovers $cfg).Count 'no temp files'
    }

    # -------------------------------------------------------------------
    # Isolation
    # -------------------------------------------------------------------
    Invoke-Test 'Isolation: module exports only the documented functions' {
        $names = @((Get-Module GsLifecycle).ExportedFunctions.Keys | Sort-Object)
        $want = @('Get-GsLifecycleState', 'Get-GsLifecycleTransitionTable', 'Invoke-GsLifecycleTransition', 'Read-GsInstallationConfig',
            'Start-GsLifecycle', 'Stop-GsLifecycle', 'Test-GsInstallationConfig', 'Test-GsLifecycleTransition')
        Assert-Equal ($want -join ',') ($names -join ',') 'exports'
    }

    Invoke-Test 'Isolation: module source contains no system-operation commands' {
        $src = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'src\GsLifecycle\GsLifecycle.psm1'))
        foreach ($pat in @('Start-Service', 'Stop-Service', 'Set-Service', 'New-Service', 'sc\.exe', 'Start-Process', 'Stop-Process',
                'HKLM:', 'HKCU:', 'Registry', 'Get-WmiObject', 'Get-CimInstance', 'Invoke-Expression', 'netsh', 'pnputil')) {
            Assert-True ($src -notmatch $pat) "no '$pat'"
        }
    }
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

$total = $script:Passed + $script:Failed
Write-Host "Summary: $($script:Passed) passed, $($script:Failed) failed"
if ($total -eq 0 -or $script:Failed -gt 0) { exit 1 }
exit 0
