#Requires -Version 5.1
<#
.SYNOPSIS
    Discovers and runs the repository's tests\Invoke-*Tests.ps1 suites, one
    child powershell.exe per suite, with a per-suite timeout.

.DESCRIPTION
    Each test file runs in its own powershell.exe -NoProfile process, wrapped
    in cmd.exe so its output is captured to temp files. A test file is an
    integration test when it
    is Invoke-Stage3Tests.ps1 or Invoke-Stage12Tests.ps1, or when one of its
    first 30 lines is exactly '# GsTestKind: integration'. Integration tests
    are skipped with a printed reason unless -IncludeIntegration is given,
    and even then skipped when the caller is not elevated (they install a
    real MSI / register a real scheduled task).

    A child that exits non-zero or is killed on timeout is a FAIL regardless
    of its Summary line; a child that exits 0 while its Summary line reports
    failures is also a FAIL (the Summary line is the contract). On timeout
    the child's whole process tree gets taskkill /T /F, run as a Process
    with a bounded WaitForExit(10000) - a hung taskkill is killed and the
    test marked KillFailed - and 'child killed' is only printed after the
    kill is confirmed with a bounded wait on the child.

    Child output is captured to temp FILES through cmd.exe redirection (the
    child runs as `cmd /d /c ""powershell" ... > out 2> err"`), so no pipe
    has to be drained: a detached grandchild that survives the kill cannot
    block the runner on a read, and the exit code still comes from the
    powershell test process via cmd. Only the last 256 KB of each file are
    read back (opened with FileShare ReadWrite|Delete so the read works even
    while a surviving descendant still holds the file), both for the
    Summary/FAIL lines and for the saved full-output log; the temp files are
    deleted afterwards, and a file that could not be deleted (a survivor
    still holds it) is reported on its own line.

    Usage:
        tests/Invoke-All.ps1                       # unit tests only
        tests/Invoke-All.ps1 -IncludeIntegration   # also run integration tests (elevated)
        tests/Invoke-All.ps1 -Name Lifecycle       # only file names containing 'Lifecycle'
        tests/Invoke-All.ps1 -Name Stage1 -Exact   # exact file/base name match
        tests/Invoke-All.ps1 -TestsDir <dir>       # discover tests in <dir>

    Prints one status line per test and a final
    "Total: X passed, Y skipped, Z failed". Exits 1 only when something
    failed or no test file was found; otherwise 0 (skips alone are fine).
#>
[CmdletBinding()]
param(
    [switch]$IncludeIntegration,
    [string]$Name = '',
    # With -Name, require an exact file name or base name match instead of a
    # substring match (so 'Stage1' does not select Invoke-Stage12Tests.ps1).
    [switch]$Exact,
    # Per-test timeout in seconds. On timeout only that test's child process
    # tree is killed and the test is marked FAIL.
    [ValidateRange(1, 86400)]
    [int]$TestTimeoutSec = 900,
    # Folder to discover Invoke-*Tests.ps1 in. Defaults to this script's own
    # folder, resolved in the body because $PSScriptRoot is empty in
    # parameter defaults under powershell.exe -File.
    [string]$TestsDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$integrationFileNames = @('Invoke-Stage3Tests.ps1', 'Invoke-Stage12Tests.ps1')
$integrationMarker = '# GsTestKind: integration'

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsIntegrationTest {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($integrationFileNames -contains (Split-Path -Leaf $Path)) { return $true }
    $lines = [System.IO.File]::ReadAllLines($Path)
    $take = [Math]::Min(30, $lines.Count)
    for ($i = 0; $i -lt $take; $i++) {
        if ($lines[$i].Trim() -eq $integrationMarker) { return $true }
    }
    return $false
}

# Reads back at most the last 256 KB of a child output file. The captured
# output lives in files (not pipes), so nothing here can block on a
# descendant that survived the kill; the open uses FileShare
# ReadWrite|Delete so the read works even while a survivor still holds the
# file open for writing.
function Read-ChildOutputTail {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $length = $stream.Length
            $tail = [Math]::Min([long]256KB, [long]$length)
            $stream.Seek($length - $tail, [System.IO.SeekOrigin]::Begin) | Out-Null
            $memory = New-Object System.IO.MemoryStream
            try {
                $buffer = New-Object byte[] (64KB)
                while ($memory.Length -lt $tail) {
                    $toRead = [int][Math]::Min([long]$buffer.Length, ([long]$tail - $memory.Length))
                    $read = $stream.Read($buffer, 0, $toRead)
                    if ($read -le 0) { break }
                    $memory.Write($buffer, 0, $read)
                }
                return [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
            } finally {
                $memory.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } catch {
        return ('[output unavailable: {0}]' -f $_.Exception.Message)
    }
}

# Runs one test file in a child powershell.exe wrapped in cmd.exe, which
# redirects the child's stdout/stderr to temp files: nothing holds a pipe,
# so grandchildren cannot block the runner's reads, and cmd's exit code is
# the powershell test process's own exit code. On timeout the child's whole
# process tree is killed with taskkill /T /F, run as a Process and awaited
# with a bounded WaitForExit(10000); a hung taskkill is killed itself and
# the result flagged KillFailed. 'child killed' is only reported once the
# kill is confirmed (bounded WaitForExit). If the child still has not
# exited after the kill attempt, the result is flagged KillFailed and the
# caller does not block on it.
function Invoke-TestFileChild {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$TimeoutSec)
    $process = $null
    $taskkill = $null
    $tempPath = [System.IO.Path]::GetTempPath()
    $outFile = Join-Path $tempPath ('Invoke-All-' + [guid]::NewGuid().ToString('N') + '.out')
    $errFile = Join-Path $tempPath ('Invoke-All-' + [guid]::NewGuid().ToString('N') + '.err')
    $timedOut = $false
    $killFailed = $false
    $taskkillExit = $null
    try {
        $powershellExe = (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Join-Path $env:windir 'System32\cmd.exe')
        # /d skips AutoRun; the outer quotes keep cmd from mangling the
        # quoted program path and apply the redirections to the child.
        $psi.Arguments = ('/d /c ""' + $powershellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $Path + '" > "' + $outFile + '" 2> "' + $errFile + '""')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($psi)
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            # Kill this test's whole child tree; no other test is touched.
            # taskkill itself is bounded: a hung taskkill is killed and the
            # test reported as KillFailed.
            try {
                $taskkillPsi = New-Object System.Diagnostics.ProcessStartInfo
                $taskkillPsi.FileName = (Join-Path $env:windir 'System32\taskkill.exe')
                $taskkillPsi.Arguments = ('/PID ' + $process.Id + ' /T /F')
                $taskkillPsi.UseShellExecute = $false
                $taskkillPsi.CreateNoWindow = $true
                $taskkill = [System.Diagnostics.Process]::Start($taskkillPsi)
                if (-not $taskkill.WaitForExit(10000)) {
                    try { $taskkill.Kill() } catch { }
                    $killFailed = $true
                } else {
                    $taskkillExit = $taskkill.ExitCode
                }
            } catch {
                $killFailed = $true
            }
            # Bounded: never block forever on a child that survived the kill.
            if (-not $killFailed -and -not $process.WaitForExit(10000)) {
                $killFailed = $true
            }
        }
        $stdout = Read-ChildOutputTail -Path $outFile
        $stderr = Read-ChildOutputTail -Path $errFile
        # Best-effort cleanup; a survivor that still holds a file open makes
        # the delete fail, and the kept path is reported by the caller.
        $keptFiles = @()
        foreach ($tempFile in @($outFile, $errFile)) {
            try {
                if ([System.IO.File]::Exists($tempFile)) { [System.IO.File]::Delete($tempFile) }
            } catch {
                $keptFiles += $tempFile
            }
        }
        $exitCode = $null
        if ($process.HasExited) { $exitCode = $process.ExitCode }
        return ([pscustomobject]@{
            ExitCode         = $exitCode
            StdOut           = $stdout
            StdErr           = $stderr
            TimedOut         = $timedOut
            KillFailed       = $killFailed
            Pid              = $process.Id
            TaskkillExitCode = $taskkillExit
            KeptFiles        = $keptFiles
        })
    } finally {
        if ($null -ne $taskkill) { try { $taskkill.Dispose() } catch { } }
        if ($null -ne $process) { try { $process.Dispose() } catch { } }
    }
}

$script:Passed = 0
$script:Skipped = 0
$script:Failed = 0
$script:AnyFailed = $false

$elevated = Test-IsElevated
if ([string]::IsNullOrWhiteSpace($TestsDir)) {
    $TestsDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($TestsDir)) { $TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
}
if ([string]::IsNullOrWhiteSpace($TestsDir) -or -not (Test-Path -LiteralPath $TestsDir -PathType Container)) {
    Write-Host ("Tests directory not found: {0}" -f $TestsDir)
    exit 1
}

$testFiles = @(Get-ChildItem -LiteralPath $TestsDir -Filter 'Invoke-*Tests.ps1' -File | Sort-Object -Property Name)
if (-not [string]::IsNullOrWhiteSpace($Name)) {
    if ($Exact) {
        $testFiles = @($testFiles | Where-Object { $_.Name -eq $Name -or $_.BaseName -eq $Name })
    } else {
        $testFiles = @($testFiles | Where-Object { $_.Name -like ('*' + $Name + '*') })
    }
}

if ($testFiles.Count -eq 0) {
    Write-Host 'No test files found (tests/Invoke-*Tests.ps1).'
    exit 1
}

foreach ($file in $testFiles) {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $isIntegration = Test-IsIntegrationTest -Path $file.FullName

    if ($isIntegration -and -not $IncludeIntegration) {
        $script:Skipped++
        Write-Host ("SKIP {0} :: integration test; rerun with -IncludeIntegration (installs a real MSI / registers a real scheduled task)" -f $file.Name)
        continue
    }
    if ($isIntegration -and -not $elevated) {
        $script:Skipped++
        Write-Host ("SKIP {0} :: integration test requires an elevated PowerShell session" -f $file.Name)
        continue
    }

    # Everything from starting the child to writing its log is guarded so a
    # process-start or log-write failure fails exactly this suite and the
    # final Total line still prints.
    try {
        $child = Invoke-TestFileChild -Path $file.FullName -TimeoutSec $TestTimeoutSec
        $stopwatch.Stop()
        $duration = ('{0:N1}s' -f $stopwatch.Elapsed.TotalSeconds)

        $summaryLine = $null
        $summaryFailed = $null
        $failLines = @()
        foreach ($line in (($child.StdOut -split "`r?`n") + ($child.StdErr -split "`r?`n"))) {
            if ($line -match '^Summary:\s*(\d+) passed,\s*(\d+) failed') {
                $summaryLine = $line.Trim()
                $summaryFailed = [int]$Matches[2]
            }
            if ($line.StartsWith('FAIL ')) { $failLines += $line.Trim() }
        }

        if ($child.KillFailed) {
            $script:Failed++
            $script:AnyFailed = $true
            Write-Host ("FAIL {0} :: KillFailed (pid {1} survived taskkill /T /F, taskkill exit {2}; not waiting for it)" -f $file.Name, $child.Pid, $child.TaskkillExitCode)
        } elseif ($child.TimedOut) {
            $script:Failed++
            $script:AnyFailed = $true
            Write-Host ("FAIL {0} :: timed out after {1}s (child killed)" -f $file.Name, $TestTimeoutSec)
        } elseif ($child.ExitCode -eq 0 -and $null -ne $summaryFailed -and $summaryFailed -gt 0) {
            $script:Failed++
            $script:AnyFailed = $true
            Write-Host ("FAIL {0} (exit {1}, {2}) {3} :: summary reports failures" -f $file.Name, $child.ExitCode, $duration, $summaryLine)
        } elseif ($child.ExitCode -ne 0) {
            $script:Failed++
            $script:AnyFailed = $true
            Write-Host ("FAIL {0} (exit {1}, {2}) {3}" -f $file.Name, $child.ExitCode, $duration, $summaryLine)
        } else {
            $script:Passed++
            Write-Host ("PASS {0} (exit {1}, {2}) {3}" -f $file.Name, $child.ExitCode, $duration, $summaryLine)
        }

        if ($child.KillFailed -or $child.TimedOut -or $child.ExitCode -ne 0 -or ($null -ne $summaryFailed -and $summaryFailed -gt 0)) {
            # A child output temp file that could not be deleted is held open
            # by a process that survived the kill; name it so the operator
            # (or a test) can remove it once the survivor is gone.
            foreach ($keptFile in $child.KeptFiles) {
                Write-Host ("     child output file kept: {0}" -f $keptFile)
            }
            foreach ($failLine in $failLines) { Write-Host ("     {0}" -f $failLine) }
            $logPath = Join-Path ([System.IO.Path]::GetTempPath()) ('Invoke-All-' + [guid]::NewGuid().ToString('N') + '-' + $file.BaseName + '.log')
            [System.IO.File]::WriteAllText($logPath, ('--- stdout ---' + "`r`n" + $child.StdOut + "`r`n" + '--- stderr ---' + "`r`n" + $child.StdErr), (New-Object System.Text.UTF8Encoding($false)))
            Write-Host ("     full output: {0}" -f $logPath)
        }
    } catch {
        $stopwatch.Stop()
        $script:Failed++
        $script:AnyFailed = $true
        Write-Host ("FAIL {0} :: runner error: {1}" -f $file.Name, $_.Exception.Message)
    }
}

Write-Host ("Total: {0} passed, {1} skipped, {2} failed" -f $script:Passed, $script:Skipped, $script:Failed)
if ($script:AnyFailed) { exit 1 }
exit 0
