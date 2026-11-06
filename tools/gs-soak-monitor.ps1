#requires -Version 5.1
<#
.SYNOPSIS
  Long-run stability monitor for the private GameStream controller (read-only).

.DESCRIPTION
  Mode Monitor samples, every -IntervalSec, the runtime status file (both candidate
  paths, newest write wins), the GameStream serverinfo endpoint (own bounded reader,
  the shared validity rule) and the role processes (broker, nvs, nss, ssau via their
  PID files) plus any -WatchProcessNames. It writes samples.csv (one row per sample,
  flushed), events.jsonl (state/PID/currentgame/serverinfo/orphan events) and
  summary.json into -OutputDir. summary.json is written in a finally block, so a
  Ctrl+C abort still leaves a summary behind.

  Mode Cycle drives -ProductPath through -Count Stop -> Start cycles, waiting each
  cycle for the status file to say ready AND serverinfo to be valid, and records
  Success/Code/duration per cycle in summary.json (cycleResults). Cycle mode only
  prints its plan unless -Execute is given. Each product action runs in a hidden
  child powershell.exe (the tray's result-file pattern) with a hard deadline
  (-ActionTimeoutSec); on timeout the child is killed, the cycle records
  ActionTimeout, the run stops cycling, and summary.json is still written.

  Monitor mode never writes anything under StateDir and never runs the product.
  secondsToAvailableAfterQuit uses the tray's Ready rule: after the first sample
  where a valid currentgame goes non-zero -> 0 (the quit), serverinfo is probed
  at 1 s start-to-start until it is valid with currentgame 0 AND a <state> that
  does not end in _SERVER_BUSY (an idle host reports something like
  ..._SERVER_FREE), capped at -MaxSecondsToAvailableAfterQuit + 5 s. EVERY quit
  outcome is recorded as an event (AvailableAfterQuit / AvailableAfterQuitTimeout);
  the summary scalar is the WORST successful delay and a quit that never becomes
  free is counted in quitTimeouts and fails the verdict. All threshold defaults
  below are PROVISIONAL: tune them after the first real machine runs
  (docs/lifecycle-hardening.md). -OutputDir must be an absolute path OUTSIDE
  this repository (reparse points along existing ancestors are resolved before
  the containment check).

  Exit code: 0 when the verdict is pass (or a plan was printed), 1 on a usage
  error or a failing verdict.

.EXAMPLE
  tools\gs-soak-monitor.ps1 -Mode Monitor -DurationMin 30 -IntervalSec 10 -OutputDir C:\gs-evidence\soak
  Sample the default installed layout for 30 minutes, one sample every 10 seconds.

.EXAMPLE
  tools\gs-soak-monitor.ps1 -Mode Monitor -DurationMin 60 -OutputDir C:\gs-evidence\soak -WatchProcessNames powershell
  Sample for 60 minutes and additionally track every powershell process.

.EXAMPLE
  tools\gs-soak-monitor.ps1 -Mode Cycle -Count 10 -OutputDir C:\gs-evidence\soak
  Print the 10-cycle Stop -> Start plan only; nothing runs without -Execute.

.EXAMPLE
  tools\gs-soak-monitor.ps1 -Mode Cycle -Count 10 -Execute -OutputDir C:\gs-evidence\soak
  Run 10 real Stop -> Start cycles (restarts the streaming stack every cycle).
#>
[CmdletBinding()]
param(
    [ValidateSet('Monitor', 'Cycle')]
    [string]$Mode = 'Monitor',
    # Monitor mode: total sampling duration in minutes.
    [double]$DurationMin = 30,
    # Test seam: when > 0 it overrides -DurationMin. Production default is 0.
    [int]$DurationSec = 0,
    # Seconds between two sample starts.
    [ValidateRange(1, 86400)]
    [int]$IntervalSec = 10,
    # Cycle mode: number of Stop -> Start cycles.
    [ValidateRange(1, 10000)]
    [int]$Count = 10,
    # Required output directory. Absolute; must resolve outside this repository.
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    [string]$StateDir = (Join-Path $env:ProgramData 'Local Development\GsController'),
    [string]$ServerInfoUri = 'http://127.0.0.1:47989/serverinfo',
    [ValidateRange(1, 60)]
    [int]$ServerInfoTimeoutSec = 2,
    # Cycle mode: gs-product.ps1 to drive. Empty resolves to ..\product\gs-product.ps1.
    [string]$ProductPath = '',
    # Extra process names to track (by process name, in addition to the four roles).
    [string[]]$WatchProcessNames = @(),
    # Cycle mode: actually run the cycles. Without it only the plan is printed.
    [switch]$Execute,
    # PROVISIONAL thresholds (see .DESCRIPTION and docs/lifecycle-hardening.md).
    [ValidateRange(0, 1000000)]
    [double]$MaxMemorySlopeMBPerHour = 50,
    [ValidateRange(0, 1000000)]
    [int]$MaxPidChanges = 5,
    [ValidateRange(0, 1000000)]
    [int]$MaxSecondsToAvailableAfterQuit = 10,
    # Cycle mode: seconds to wait per cycle for status ready + valid serverinfo.
    [ValidateRange(1, 86400)]
    [int]$CycleReadyTimeoutSec = 120,
    # Cycle mode: hard deadline for one product action (Stop or Start) child
    # process. On timeout the child is killed, the cycle records ActionTimeout
    # and the run stops cycling (summary.json is still written).
    [ValidateRange(1, 86400)]
    [int]$ActionTimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$roleNames = @('broker', 'nvs', 'nss', 'ssau')

# ------------ small helpers ------------

function Test-GsSoakOutputDir {
    # Rejects relative paths and any path inside this repository (same guard
    # as client/New-CompatibilityEvidence.ps1: full-path compare with a
    # trailing separator, case-insensitive). Before the compare, reparse
    # points (junctions / directory symlinks) along the EXISTING portion of
    # both paths are resolved: a junction under %TEMP% targeting this
    # repository is lexically outside but physically inside, so a purely
    # lexical check would let samples.csv, events.jsonl and summary.json be
    # written into the repository. Paths whose reparse target cannot be
    # established are rejected instead of guessed. Returns the full output
    # path.
    param([Parameter(Mandatory = $true)][string]$OutputDirectory)
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { throw 'OutputDir is required' }
    if (-not [System.IO.Path]::IsPathRooted($OutputDirectory)) {
        throw ('OutputDir must be an absolute path: {0}' -f $OutputDirectory)
    }
    $outFull = [System.IO.Path]::GetFullPath($OutputDirectory)
    $outFull = Get-GsSoakReparseResolvedPath -Path $outFull
    $repoFull = [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
    $repoFull = Get-GsSoakReparseResolvedPath -Path $repoFull
    $outCmp = $outFull.TrimEnd('\') + '\'
    $repoCmp = $repoFull.TrimEnd('\') + '\'
    if ($outCmp.StartsWith($repoCmp, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('OutputDir must be outside the repository ({0}): {1}' -f $repoFull, $outFull)
    }
    return $outFull
}

function Get-GsSoakReparseResolvedPath {
    # Resolves reparse points along the EXISTING portion of a path. Walking
    # from the full path upward, the deepest existing container that is a
    # reparse point is replaced by its target and the walk restarts on the
    # rewritten path (bounded hops, so nested junctions still resolve). A
    # path with no existing reparse-point ancestor is returned unchanged
    # (normalized). Throws when a reparse point's target cannot be
    # established: the caller must not guess where the bytes would land.
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    for ($hop = 0; $hop -lt 16; $hop++) {
        $reparseAncestor = $null
        $probe = $resolved
        for ($depth = 0; $depth -lt 64; $depth++) {
            if (Test-Path -LiteralPath $probe) {
                $probeItem = $null
                try { $probeItem = Get-Item -Force -LiteralPath $probe } catch { $probeItem = $null }
                if ($null -ne $probeItem -and (($probeItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    $reparseAncestor = $probeItem
                    break
                }
            }
            $parent = Split-Path -Parent $probe
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $probe) { break }
            $probe = $parent
        }
        if ($null -eq $reparseAncestor) { return $resolved }
        $target = $null
        try { $target = @($reparseAncestor.Target)[0] } catch { $target = $null }
        if ([string]::IsNullOrWhiteSpace($target)) {
            throw ('OutputDir containment could not be verified: {0} is a reparse point whose target cannot be established' -f $reparseAncestor.FullName)
        }
        if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = (Join-Path (Split-Path -Parent $reparseAncestor.FullName) $target)
        }
        $suffix = ''
        if ($resolved.Length -gt $reparseAncestor.FullName.Length) {
            $suffix = $resolved.Substring($reparseAncestor.FullName.Length).TrimStart('\', '/')
        }
        $resolved = [System.IO.Path]::GetFullPath((Join-Path $target $suffix))
    }
    throw 'OutputDir containment could not be verified: too many nested reparse points'
}

function ConvertTo-GsSoakCsvField {
    param($Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    if ($text -match '[",\r\n]') { return ('"' + ($text -replace '"', '""') + '"') }
    return $text
}

function Get-GsMemorySlopeMBPerHour {
    # Least-squares slope of private MB over elapsed seconds, scaled to MB/hour.
    # $null when there are fewer than 2 points, the array lengths disagree, or
    # the x variance is zero (all samples at the same timestamp).
    param([double[]]$Seconds, [double[]]$PrivateMb)
    $n = @($Seconds).Count
    if ($n -lt 2) { return $null }
    if (@($PrivateMb).Count -ne $n) { return $null }
    $meanX = 0.0
    $meanY = 0.0
    for ($i = 0; $i -lt $n; $i++) { $meanX += $Seconds[$i]; $meanY += $PrivateMb[$i] }
    $meanX = $meanX / $n
    $meanY = $meanY / $n
    $cov = 0.0
    $var = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $dx = $Seconds[$i] - $meanX
        $cov += $dx * ($PrivateMb[$i] - $meanY)
        $var += $dx * $dx
    }
    if ($var -le 0) { return $null }
    return [math]::Round(($cov / $var) * 3600.0, 3)
}

# ------------ status file (newest of the two candidates wins) ------------

function Get-GsSoakStatusState {
    # Same candidate rule as the tray UI and gs-product's Get-GsStatusFilePath:
    # <StateDir>\runtime\state\status.json first, <StateDir>\status.json second,
    # and when both exist the newer LastWriteTimeUtc wins. The reported state is
    # the JSON `state` property ONLY when it is a real string; anything else is
    # reported as $null (the monitor observes, it does not guess).
    param([Parameter(Mandatory = $true)][string]$StateDirectory)
    $candidates = @(
        (Join-Path $StateDirectory 'runtime\state\status.json'),
        (Join-Path $StateDirectory 'status.json')
    )
    $found = $null
    $foundWritten = [datetime]::MinValue
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $written = (Get-Item -LiteralPath $candidate).LastWriteTimeUtc
            if ($null -eq $found -or $written -gt $foundWritten) {
                $found = $candidate
                $foundWritten = $written
            }
        }
    }
    if ($null -eq $found) {
        return [pscustomobject]@{ State = $null; Source = 'none'; Path = $null }
    }
    $kind = 'state-dir'
    if ($found -like ('*' + [System.IO.Path]::DirectorySeparatorChar + 'runtime' + [System.IO.Path]::DirectorySeparatorChar + 'state' + [System.IO.Path]::DirectorySeparatorChar + 'status.json')) { $kind = 'runtime-state' }
    $state = $null
    try {
        $parsed = [IO.File]::ReadAllText($found) | ConvertFrom-Json
        if ($null -ne $parsed -and $parsed -is [pscustomobject] -and $parsed.PSObject.Properties['state']) {
            $value = $parsed.state
            if ($value -is [string]) { $state = $value }
        }
    } catch {
        $state = $null
    }
    return [pscustomobject]@{ State = $state; Source = $kind; Path = $found }
}

# ------------ bounded serverinfo reader (own copy, shared validity rule) ------------

function Read-GsSoakHttpBody {
    # Bounded chunked body read: every ReadAsync is bounded by the REMAINING
    # total deadline and the body is capped at 64 KB counted in bytes before
    # decoding (inclusive). Returns Body/TimedOut/TooLarge.
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$Clock,
        [Parameter(Mandatory = $true)][long]$DeadlineElapsedMs
    )
    $maxBytes = 64KB
    $buffer = New-Object byte[] 4096
    $stream = $null
    $memory = New-Object System.IO.MemoryStream
    try {
        $stream = $Response.GetResponseStream()
        while ($true) {
            $remainingMs = $DeadlineElapsedMs - $Clock.ElapsedMilliseconds
            if ($remainingMs -le 0) {
                return [pscustomobject]@{ Body = $null; TimedOut = $true; TooLarge = $false }
            }
            $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait([int][Math]::Min($remainingMs, [int]::MaxValue))) {
                return [pscustomobject]@{ Body = $null; TimedOut = $true; TooLarge = $false }
            }
            $read = $readTask.GetAwaiter().GetResult()
            if ($read -le 0) { break }
            if (($memory.Length + $read) -gt $maxBytes) {
                return [pscustomobject]@{ Body = $null; TimedOut = $false; TooLarge = $true }
            }
            $memory.Write($buffer, 0, $read)
        }
        return [pscustomobject]@{ Body = [System.Text.Encoding]::UTF8.GetString($memory.ToArray()); TimedOut = $false; TooLarge = $false }
    } finally {
        $memory.Dispose()
        if ($null -ne $stream) { try { $stream.Close() } catch { } }
    }
}

function Get-GsSoakServerInfo {
    # Bounded serverinfo read with the SHARED validity rule (same rule as the
    # product, the tray and the contracts): HTTP exactly 200, redirects NOT
    # followed, 65536-byte body cap counted before decoding (inclusive), root
    # element exactly 'root', status_code ^\d{1,10}$ equal to 200, a non-empty
    # <state> after trim, a <currentgame> matching ^\d{1,10}$ after trim. The
    # total deadline of TimeoutSec is enforced with an independent async wait
    # plus Abort, independent of the framework's own timers. Never throws.
    # Returns Http/State/CurrentGame/Error (Error = $null on a clean, valid 200).
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSec = 2
    )
    $result = [pscustomobject]@{ Http = $null; State = $null; CurrentGame = $null; Error = $null }
    $response = $null
    $request = $null
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $deadlineElapsedMs = [Math]::Max(1, $TimeoutSec) * 1000
    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Timeout = [int]$deadlineElapsedMs
        $request.ReadWriteTimeout = [int]$deadlineElapsedMs
        $request.Proxy = $null
        $request.KeepAlive = $false
        $request.AllowAutoRedirect = $false
        $pending = $request.BeginGetResponse($null, $null)
        $remainingMs = $deadlineElapsedMs - $clock.ElapsedMilliseconds
        if ($remainingMs -le 0 -or -not $pending.AsyncWaitHandle.WaitOne([int][Math]::Min($remainingMs, [int]::MaxValue))) {
            try { $request.Abort() } catch { }
            $result.Error = ('Timeout: serverinfo did not respond within {0}s' -f $TimeoutSec)
            return $result
        }
        $response = $request.EndGetResponse($pending)
        $result.Http = [int]$response.StatusCode
        # The shared validity rule requires HTTP EXACTLY 200, checked BEFORE
        # any body byte is read: a 201 (or any other 2xx/3xx that does not
        # throw in EndGetResponse) carrying valid XML must be rejected, not
        # parsed. >=400 and unfollowed redirects throw in EndGetResponse and
        # are handled by the catch below.
        if ($result.Http -ne 200) {
            try { $request.Abort() } catch { }
            $result.Error = ('HTTP status {0}: serverinfo must return exactly 200' -f $result.Http)
            return $result
        }
        $bodyRead = Read-GsSoakHttpBody -Response $response -Clock $clock -DeadlineElapsedMs $deadlineElapsedMs
        if ($bodyRead.TimedOut) {
            try { $request.Abort() } catch { }
            $result.Error = ('Timeout: serverinfo body was not complete within {0}s' -f $TimeoutSec)
            return $result
        }
        if ($bodyRead.TooLarge) {
            try { $request.Abort() } catch { }
            $result.Error = 'BodyTooLarge: serverinfo body exceeds 64 KB'
            return $result
        }
        try {
            $xml = [xml]$bodyRead.Body
            $root = $xml.DocumentElement
            if ($null -eq $root -or $root.Name -cne 'root') {
                $result.Error = 'serverinfo response has no <root> root element'
            } else {
                $statusCodeAttribute = $null
                $statusAttribute = $root.Attributes['status_code']
                if ($null -ne $statusAttribute) { $statusCodeAttribute = $statusAttribute.Value }
                if ($null -eq $statusCodeAttribute) {
                    $result.Error = 'serverinfo XML has no numeric status_code attribute'
                } elseif ($statusCodeAttribute -notmatch '^\d{1,10}$') {
                    $result.Error = ('serverinfo XML status_code is not 1-10 digits: {0}' -f $statusCodeAttribute)
                } elseif ([int]$statusCodeAttribute -ne 200) {
                    $result.Error = ('serverinfo XML status_code is {0}, expected 200' -f ([int]$statusCodeAttribute))
                } else {
                    $stateNode = $root.SelectSingleNode('state')
                    if ($null -eq $stateNode) {
                        $result.Error = 'serverinfo response has no state element'
                    } elseif (([string]$stateNode.InnerText).Trim().Length -eq 0) {
                        $result.Error = 'serverinfo state element is empty'
                    } else {
                        $result.State = ([string]$stateNode.InnerText).Trim()
                        $gameNode = $root.SelectSingleNode('currentgame')
                        if ($null -eq $gameNode) {
                            $result.Error = 'serverinfo response has no currentgame element'
                        } else {
                            $currentGame = ([string]$gameNode.InnerText).Trim()
                            if ($currentGame -notmatch '^\d{1,10}$') {
                                $result.Error = ('serverinfo currentgame is not numeric: {0}' -f $currentGame)
                            } else {
                                $result.CurrentGame = $currentGame
                            }
                        }
                    }
                }
            }
        } catch {
            $result.Error = ('serverinfo response is not valid XML: {0}' -f $_.Exception.Message)
        }
        return $result
    } catch {
        $ex = $_.Exception
        while ($null -ne $ex -and $null -ne $ex.InnerException -and (
                $ex -is [System.Management.Automation.MethodInvocationException] -or
                $ex -is [System.Management.Automation.RuntimeException])) {
            $ex = $ex.InnerException
        }
        $webException = $ex -as [System.Net.WebException]
        if ($null -ne $webException -and $null -ne $webException.Response) {
            $httpResponse = $webException.Response -as [System.Net.HttpWebResponse]
            if ($null -ne $httpResponse) {
                $result.Http = [int]$httpResponse.StatusCode
                try { $httpResponse.Close() } catch { }
            }
        }
        $result.Error = ('{0}: {1}' -f $ex.GetType().FullName, $ex.Message)
        return $result
    } finally {
        if ($null -ne $response) { try { $response.Close() } catch { } }
    }
}

# ------------ process sampling ------------

function ConvertFrom-GsSoakPidFile {
    # Tolerant PID-file formats, identical to gs-diagnose: (1) a plain 1-10
    # digit integer, (2) a JSON object with a pid or processId property, (3) a
    # quoted number such as "1234". Exists = $false when the file is missing;
    # Pid = $null with Malformed = $true when it exists but parses to nothing.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Pid = $null; Malformed = $false }
    }
    $text = $null
    try { $text = [IO.File]::ReadAllText($Path) } catch {
        return [pscustomobject]@{ Exists = $true; Pid = $null; Malformed = $true }
    }
    $trimmed = $text.Trim()
    $rawPid = $null
    if ($trimmed -match '^\d{1,10}$') {
        $rawPid = $trimmed
    } else {
        $doc = $null
        try { $doc = $trimmed | ConvertFrom-Json } catch { $doc = $null }
        # NOTE: in PowerShell 5.1 every object passes `-is [pscustomobject]`
        # (the accelerator is System.Management.Automation.PSObject and every
        # pipeline item is wrapped in one), so the object test must look at the
        # actual type name; a JSON scalar string must fall through to the
        # tolerated "quoted number" format.
        $docIsObject = $false
        if ($null -ne $doc) {
            if ($doc.GetType().Name -eq 'PSCustomObject') { $docIsObject = $true }
        }
        if ($docIsObject) {
            foreach ($propName in @('pid', 'processId')) {
                $prop = $doc.PSObject.Properties[$propName]
                if ($null -ne $prop) { $rawPid = [string]$prop.Value; break }
            }
        } elseif ($null -ne $doc) {
            $rawPid = [string]$doc
        }
    }
    if ($null -ne $rawPid) {
        $parsed = [int64]0
        if ([int64]::TryParse($rawPid, [ref]$parsed) -and $parsed -ge 0) {
            return [pscustomobject]@{ Exists = $true; Pid = $parsed; Malformed = $false }
        }
    }
    return [pscustomobject]@{ Exists = $true; Pid = $null; Malformed = $true }
}

function Get-GsSoakProcessSample {
    # Live metrics for one PID. Returns $null when no process with that PID
    # exists (the identity of the process is NOT verified; PIDs can be reused,
    # same caveat as gs-diagnose).
    param([AllowNull()][Nullable[int64]]$ProcId)
    if ($null -eq $ProcId -or $ProcId -le 0) { return $null }
    $proc = $null
    try { $proc = Get-Process -Id $ProcId -ErrorAction Stop } catch { return $null }
    $startUtc = $null
    try { $startUtc = $proc.StartTime.ToUniversalTime().ToString('o') } catch { }
    return [pscustomobject]@{
        Pid         = [int64]$proc.Id
        Alive       = $true
        ProcessName = [string]$proc.ProcessName
        WorkingSetMb = [math]::Round($proc.WorkingSet64 / 1MB, 3)
        PrivateMb   = [math]::Round($proc.PrivateMemorySize64 / 1MB, 3)
        Handles     = [int64]$proc.HandleCount
        StartUtc    = $startUtc
    }
}

function Get-GsSoakWatchTotals {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Names)
    $totals = [ordered]@{ Procs = 0; WorkingSetMb = 0.0; PrivateMb = 0.0; Handles = 0; Pids = @() }
    $pids = New-Object System.Collections.Generic.List[object]
    foreach ($name in $Names) {
        $procs = @()
        try { $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue) } catch { $procs = @() }
        foreach ($proc in $procs) {
            $totals.Procs += 1
            try { $totals.WorkingSetMb += $proc.WorkingSet64 / 1MB } catch { }
            try { $totals.PrivateMb += $proc.PrivateMemorySize64 / 1MB } catch { }
            try { $totals.Handles += $proc.HandleCount } catch { }
            $pids.Add([int]$proc.Id)
        }
    }
    $totals.Pids = @($pids.ToArray() | Sort-Object)
    $totals.WorkingSetMb = [math]::Round($totals.WorkingSetMb, 3)
    $totals.PrivateMb = [math]::Round($totals.PrivateMb, 3)
    return $totals
}

# ------------ Cycle mode helpers ------------

function Get-GsSoakProductChildScript {
    # Builds the hidden child powershell.exe script that runs one product CLI
    # action and writes its serialized result to $ResultFile (the tray's
    # child-command pattern, extended so a CLI that leaves no structured
    # result still records its process exit code). The child always exits 0;
    # the result file alone carries the outcome, and a missing or invalid
    # file means NoResult.
    param(
        [Parameter(Mandatory = $true)][string]$ProductScript,
        [Parameter(Mandatory = $true)][string]$ProductAction,
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][string]$ResultFile
    )
    $sqProduct = "'" + $ProductScript.Replace("'", "''") + "'"
    $sqState = "'" + $StateDirectory.Replace("'", "''") + "'"
    $sqResult = "'" + $ResultFile.Replace("'", "''") + "'"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('$ErrorActionPreference = ''Stop''')
    $lines.Add('$exitCode = $null')
    $lines.Add('try {')
    $lines.Add('    $output = & ' + $sqProduct + ' -Action ' + $ProductAction + ' -StateDir ' + $sqState)
    $lines.Add('    $exitCode = $LASTEXITCODE')
    $lines.Add('    $result = $null')
    $lines.Add('    foreach ($item in @($output)) { if ($null -ne $item -and $null -ne $item.PSObject.Properties[''Success'']) { $result = $item } }')
    $lines.Add('    if ($null -eq $result) {')
    $lines.Add('        if ($exitCode -ne 0) { $result = [pscustomobject]@{ Success = $false; Data = [pscustomobject]@{ ExitCode = $exitCode }; Errors = @([pscustomobject]@{ Code = (''Exit'' + $exitCode); Message = (''the product script exited '' + $exitCode + '' without a structured result'') }) } }')
    $lines.Add('        else { $result = [pscustomobject]@{ Success = $false; Data = $null; Errors = @([pscustomobject]@{ Code = ''NoStructuredResult''; Message = ''the product script left no structured result and exited 0'' }) } }')
    $lines.Add('    }')
    $lines.Add('} catch {')
    $lines.Add('    $result = [pscustomobject]@{ Success = $false; Data = $null; Errors = @([pscustomobject]@{ Code = ''CliException''; Message = $_.Exception.Message }) }')
    $lines.Add('}')
    $lines.Add('# Best effort: if any of this fails, the result file stays missing or')
    $lines.Add('# invalid and the caller reports NoResult.')
    $lines.Add('try {')
    $lines.Add('    $resultDir = Split-Path -Parent ' + $sqResult)
    $lines.Add('    if (-not (Test-Path -LiteralPath $resultDir)) { New-Item -ItemType Directory -Path $resultDir -Force | Out-Null }')
    $lines.Add('    $json = $result | ConvertTo-Json -Depth 8')
    $lines.Add('    [IO.File]::WriteAllText(' + $sqResult + ', $json, (New-Object Text.UTF8Encoding($false)))')
    $lines.Add('} catch { }')
    $lines.Add('exit 0')
    return ($lines -join "`r`n")
}

function Stop-GsSoakOwnedProcess {
    # The action child this tool started must never outlive the call: on
    # EVERY exit path - the normal timeout, an exception, or a pipeline stop
    # (Ctrl+C) unwinding through the caller's try - a still-running child is
    # killed here and the kill is awaited with a bounded wait, then the
    # Process object is disposed. Never throws.
    param([AllowNull()]$Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            try { $Process.Kill() } catch { }
            try { $null = $Process.WaitForExit(10000) } catch { }
        }
    } catch { }
    try { $Process.Dispose() } catch { }
}

function Invoke-GsSoakProductAction {
    # Runs one product Stop or Start in a hidden child powershell.exe (the
    # tray's child-command pattern) with a HARD deadline. Returns
    # Success/Code: Code is the structured error code from the result file
    # ('OK' on success), 'Exit<n>' when the CLI left no structured result but
    # exited non-zero, 'NoStructuredResult', 'CliException', 'NoResult' when
    # the result file was never written, or 'ActionTimeout' when the child
    # was killed at the deadline.
    param(
        [Parameter(Mandatory = $true)][string]$ProductScript,
        [Parameter(Mandatory = $true)][string]$ProductAction,
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][int]$TimeoutSec,
        [Parameter(Mandatory = $true)][string]$WorkDir
    )
    $resultFile = Join-Path $WorkDir ('cycle-result-' + [guid]::NewGuid().ToString('N') + '.json')
    $childScript = Get-GsSoakProductChildScript -ProductScript $ProductScript -ProductAction $ProductAction -StateDirectory $StateDirectory -ResultFile $resultFile
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childScript))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $encoded)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill() } catch { }
            if (-not $process.WaitForExit(10000)) {
                # The child survived the kill; the result file is meaningless.
                return [pscustomobject]@{ Success = $false; Code = 'ActionTimeout'; ResultFile = $resultFile }
            }
            return [pscustomobject]@{ Success = $false; Code = 'ActionTimeout'; ResultFile = $resultFile }
        }
    } finally {
        # Cancellation cleanup on EVERY exit path: a pipeline stop (Ctrl+C)
        # while a hanging action is running unwinds through this finally, and
        # the owned child must not be left running without its deadline
        # monitor (C-B5). After the normal timeout path the child is already
        # dead and this only disposes it.
        Stop-GsSoakOwnedProcess -Process $process
    }
    if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; Code = 'NoResult'; ResultFile = $resultFile }
    }
    $result = $null
    try {
        $parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($resultFile))
        $items = @($parsed)
        for ($i = $items.Count - 1; $i -ge 0; $i--) {
            $item = $items[$i]
            if ($null -ne $item -and $null -ne $item.PSObject.Properties['Success']) { $result = $item; break }
        }
    } catch {
        $result = $null
    }
    try { Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue } catch { }
    if ($null -eq $result) {
        return [pscustomobject]@{ Success = $false; Code = 'NoResult'; ResultFile = $resultFile }
    }
    $success = $false
    try { $success = [bool]$result.Success } catch { $success = $false }
    $code = 'OK'
    if (-not $success) {
        $code = 'Unknown'
        $errProp = $result.PSObject.Properties['Errors']
        if ($null -ne $errProp -and $null -ne $errProp.Value) {
            $errs = @($errProp.Value)
            if ($errs.Count -gt 0 -and $null -ne $errs[0]) {
                $codeProp = $errs[0].PSObject.Properties['Code']
                if ($null -ne $codeProp -and $null -ne $codeProp.Value -and -not [string]::IsNullOrWhiteSpace([string]$codeProp.Value)) {
                    $code = [string]$codeProp.Value
                }
            }
        }
    }
    return [pscustomobject]@{ Success = $success; Code = $code; ResultFile = $resultFile }
}

function Test-GsSoakHostFree {
    # The tray's Ready rule for serverinfo: valid under the shared rule,
    # currentgame '0' after trim, and <state> NOT ending in '_SERVER_BUSY'
    # (case-insensitive). The serverinfo <state> is never the literal 'ready';
    # an idle host reports something like '..._SERVER_FREE'.
    param([Parameter(Mandatory = $true)]$ServerInfo)
    if ($null -eq $ServerInfo -or -not [string]::IsNullOrEmpty($ServerInfo.Error)) { return $false }
    if ($ServerInfo.CurrentGame -ne '0') { return $false }
    $state = ''
    if ($null -ne $ServerInfo.State) { $state = [string]$ServerInfo.State }
    if ($state.ToUpperInvariant().EndsWith('_SERVER_BUSY')) { return $false }
    return $true
}

function Test-GsSoakCycleReady {
    # One wait iteration: $true when the status file says ready AND
    # serverinfo passes the SHARED Ready rule (Test-GsSoakHostFree: valid,
    # currentgame '0', state not ending in _SERVER_BUSY) - not merely "no
    # error". A serverinfo with currentgame=1 or a *_SERVER_BUSY state means
    # the host is not free yet and the cycle is not ready. Never throws.
    param(
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][string]$ServerInfoUri,
        [Parameter(Mandatory = $true)][int]$ServerInfoTimeoutSec
    )
    $status = Get-GsSoakStatusState -StateDirectory $StateDirectory
    $info = Get-GsSoakServerInfo -Uri $ServerInfoUri -TimeoutSec $ServerInfoTimeoutSec
    if ($null -ne $status.State -and $status.State -ieq 'ready' -and (Test-GsSoakHostFree -ServerInfo $info)) { return $true }
    return $false
}

# ------------ validation and plan-only short circuit ------------

$effectiveDurationSec = 0
if ($DurationSec -gt 0) {
    $effectiveDurationSec = $DurationSec
} else {
    $effectiveDurationSec = [int][math]::Round($DurationMin * 60)
}
if ($Mode -eq 'Monitor' -and $effectiveDurationSec -lt 1) {
    throw ('the monitor duration must be at least 1 second (DurationMin={0}, DurationSec={1})' -f $DurationMin, $DurationSec)
}

$outFull = Test-GsSoakOutputDir -OutputDirectory $OutputDir

if ($Mode -eq 'Cycle' -and -not $Execute) {
    Write-Host ('CYCLE PLAN: {0} cycles of Stop -> Start -> wait for status ready + valid serverinfo (wait timeout {1}s per cycle)' -f $Count, $CycleReadyTimeoutSec)
    for ($i = 1; $i -le $Count; $i++) {
        Write-Host ('PLAN cycle {0}/{1}: Stop -> Start -> wait' -f $i, $Count)
    }
    Write-Host 'PLAN-ONLY: nothing was executed and nothing was written. Pass -Execute to run the cycles.'
    exit 0
}

$resolvedProduct = $ProductPath
if ($Mode -eq 'Cycle') {
    if ([string]::IsNullOrWhiteSpace($resolvedProduct)) {
        $resolvedProduct = Join-Path $scriptDir '..\product\gs-product.ps1'
    }
    if (-not (Test-Path -LiteralPath $resolvedProduct -PathType Leaf)) {
        throw ('ProductPath not found: {0}' -f $resolvedProduct)
    }
}

$watchNames = @($WatchProcessNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

# ------------ run ------------

$summary = [ordered]@{
    schemaVersion               = 1
    tool                        = 'gs-soak-monitor'
    mode                        = $Mode
    startedUtc                  = $null
    endedUtc                    = $null
    config                      = [ordered]@{
        stateDir                      = $StateDir
        serverInfoUri                 = $ServerInfoUri
        serverInfoTimeoutSec          = $ServerInfoTimeoutSec
        intervalSec                   = $IntervalSec
        durationSec                   = $effectiveDurationSec
        count                         = $Count
        productPath                   = $resolvedProduct
        watchProcessNames             = @($watchNames)
        maxMemorySlopeMBPerHour       = $MaxMemorySlopeMBPerHour
        maxPidChanges                 = $MaxPidChanges
        maxSecondsToAvailableAfterQuit = $MaxSecondsToAvailableAfterQuit
        cycleReadyTimeoutSec          = $CycleReadyTimeoutSec
        actionTimeoutSec              = $ActionTimeoutSec
        thresholdsProvisional         = $true
    }
    samples                     = 0
    verdict                     = 'fail'
    verdictReasons              = @()
    memorySlopeMBPerHour        = $null
    pidChanges                  = 0
    streamTransitions           = 0
    secondsToAvailableAfterQuit = $null
    quitTimeouts                = 0
    orphans                     = 0
    serverInfoErrors            = 0
    cycleResults                = @()
}
$verdictReasons = New-Object System.Collections.Generic.List[string]
$cycleResults = New-Object System.Collections.Generic.List[object]
$csvWriter = $null
$eventsWriter = $null
$csvPath = Join-Path $outFull 'samples.csv'
$eventsPath = Join-Path $outFull 'events.jsonl'
$summaryPath = Join-Path $outFull 'summary.json'
$script:FinalExitCode = 1

try {
    New-Item -ItemType Directory -Path $outFull -Force | Out-Null
    $summary.startedUtc = (Get-Date).ToUniversalTime().ToString('o')
    # The outputs are opened with FileShare.ReadWrite so an operator (or a
    # test) can tail samples.csv / events.jsonl WHILE the run is in progress;
    # a plain StreamWriter's FileShare.Read handle rejects readers whose own
    # share mode must tolerate the still-open writer.
    $csvStream = New-Object System.IO.FileStream($csvPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $csvWriter = New-Object System.IO.StreamWriter($csvStream, (New-Object System.Text.UTF8Encoding($false)))
    $eventsStream = New-Object System.IO.FileStream($eventsPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $eventsWriter = New-Object System.IO.StreamWriter($eventsStream, (New-Object System.Text.UTF8Encoding($false)))
    $eventsWriter.AutoFlush = $true

    if ($Mode -eq 'Monitor') {
        # ---- CSV header (fixed columns) ----
        $columns = New-Object System.Collections.Generic.List[string]
        foreach ($c in @('timestampUtc', 'elapsedSec', 'statusState', 'statusSource', 'serverInfoValid', 'serverInfoState', 'currentGame', 'serverInfoError')) { $columns.Add($c) }
        foreach ($role in $roleNames) {
            foreach ($suffix in @('Pid', 'WsMb', 'PrivMb', 'Handles')) { $columns.Add(($role + $suffix)) }
        }
        foreach ($suffix in @('Procs', 'WsMb', 'PrivMb', 'Handles')) { $columns.Add(('watch' + $suffix)) }
        $columns.Add('trackedPrivMbTotal')
        $csvWriter.WriteLine(($columns.ToArray() -join ','))

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $prev = $null                 # previous sample record
        $prevValidGame = $null        # last valid currentgame value
        $quitAtUtc = $null
        $waitingAvailable = $false
        $quitDelays = New-Object System.Collections.Generic.List[double]
        $slopeSeconds = New-Object System.Collections.Generic.List[double]
        $slopePrivateMb = New-Object System.Collections.Generic.List[double]

        while ($true) {
            $sampleStartUtc = [DateTime]::UtcNow
            $elapsedSec = $stopwatch.Elapsed.TotalSeconds

            # status file
            $status = Get-GsSoakStatusState -StateDirectory $StateDir
            # serverinfo (the SAMPLE's own reading; the available-after-quit
            # poll below reuses $info for its own probes and must not leak
            # into the CSV row)
            $info = Get-GsSoakServerInfo -Uri $ServerInfoUri -TimeoutSec $ServerInfoTimeoutSec
            $sampleInfo = $info
            # role processes
            $roleSamples = @{ }
            $roleOrphan = @{ }
            $trackedPrivMb = 0.0
            $trackedAny = $false
            foreach ($role in $roleNames) {
                $pidInfo = ConvertFrom-GsSoakPidFile -Path (Join-Path $StateDir ($role + '_pid.json'))
                $procSample = $null
                if ($null -ne $pidInfo.Pid) { $procSample = Get-GsSoakProcessSample -ProcId $pidInfo.Pid }
                $roleSamples[$role] = $procSample
                if ($null -ne $procSample) {
                    $trackedPrivMb += $procSample.PrivateMb
                    $trackedAny = $true
                }
                $wasOrphan = $false
                if ($null -ne $prev -and $prev.RoleOrphan.ContainsKey($role)) { $wasOrphan = $prev.RoleOrphan[$role] }
                $isOrphan = ($null -ne $status.State -and $status.State -ieq 'stopped' -and $null -ne $procSample)
                $roleOrphan[$role] = $isOrphan
                if ($isOrphan -and -not $wasOrphan) {
                    $summary.orphans += 1
                    $orphanEvent = [ordered]@{
                        timestampUtc = $sampleStartUtc.ToString('o')
                        type         = 'Orphan'
                        role         = $role
                        pid          = $procSample.Pid
                    }
                    $eventsWriter.WriteLine(($orphanEvent | ConvertTo-Json -Compress -Depth 5))
                }
            }
            # watch processes
            $watch = Get-GsSoakWatchTotals -Names ([string[]]$watchNames)
            if ($watch.Procs -gt 0) {
                $trackedPrivMb += $watch.PrivateMb
                $trackedAny = $true
            }
            if (-not $trackedAny) { $trackedPrivMb = $null } else { $trackedPrivMb = [math]::Round($trackedPrivMb, 3) }

            # ---- events vs previous sample ----
            if ($null -ne $prev) {
                if ($prev.StatusState -ne $status.State) {
                    $eventsWriter.WriteLine(([ordered]@{
                        timestampUtc = $sampleStartUtc.ToString('o')
                        type         = 'StateChange'
                        from         = $prev.StatusState
                        to           = $status.State
                    } | ConvertTo-Json -Compress -Depth 5))
                }
                foreach ($role in $roleNames) {
                    $prevPid = $null
                    if ($prev.RolePids.ContainsKey($role)) { $prevPid = $prev.RolePids[$role] }
                    $curPid = $null
                    if ($null -ne $roleSamples[$role]) { $curPid = $roleSamples[$role].Pid }
                    if (($null -ne $prevPid -or $null -ne $curPid) -and $prevPid -ne $curPid) {
                        $summary.pidChanges += 1
                        $eventsWriter.WriteLine(([ordered]@{
                            timestampUtc = $sampleStartUtc.ToString('o')
                            type         = 'PidChange'
                            role         = $role
                            from         = $prevPid
                            to           = $curPid
                        } | ConvertTo-Json -Compress -Depth 5))
                    }
                }
                if ($null -ne $prev.WatchPids -and (($prev.WatchPids -join ',') -ne ($watch.Pids -join ','))) {
                    $summary.pidChanges += 1
                    $eventsWriter.WriteLine(([ordered]@{
                        timestampUtc = $sampleStartUtc.ToString('o')
                        type         = 'WatchProcessSetChange'
                        from         = @($prev.WatchPids)
                        to           = @($watch.Pids)
                    } | ConvertTo-Json -Compress -Depth 5))
                }
            }
            # A serverinfo error is emitted on EVERY sample that has one (it
            # is environmental and repeated errors matter more than dedupe).
            if (-not [string]::IsNullOrEmpty($info.Error)) {
                $summary.serverInfoErrors += 1
                $eventsWriter.WriteLine(([ordered]@{
                    timestampUtc = $sampleStartUtc.ToString('o')
                    type         = 'ServerInfoError'
                    error        = $info.Error
                    http         = $info.Http
                } | ConvertTo-Json -Compress -Depth 5))
            }

            # ---- currentgame transitions and secondsToAvailableAfterQuit ----
            if ($null -eq $info.Error) {
                $game = $info.CurrentGame
                if ($null -ne $prevValidGame) {
                    $prevStreaming = ($prevValidGame -ne '0')
                    $curStreaming = ($game -ne '0')
                    if ($game -cne $prevValidGame) {
                        $eventsWriter.WriteLine(([ordered]@{
                            timestampUtc = $sampleStartUtc.ToString('o')
                            type         = 'CurrentGameChange'
                            from         = $prevValidGame
                            to           = $game
                        } | ConvertTo-Json -Compress -Depth 5))
                    }
                    if ($prevStreaming -ne $curStreaming) {
                        $summary.streamTransitions += 1
                        if (-not $curStreaming) {
                            $quitAtUtc = $sampleStartUtc
                            $waitingAvailable = $true
                        }
                    }
                }
                $prevValidGame = $game
            }
            if ($waitingAvailable) {
                # T0 was the quit sample and the quit sample's own serverinfo
                # is the FIRST check. T1 is the first check AT OR AFTER T0
                # where the tray's Ready rule holds (valid serverinfo,
                # currentgame '0', state not ending in _SERVER_BUSY). The
                # probes run at 1 s START-TO-START (the next probe is
                # scheduled one second after the previous probe STARTED, not
                # one second after it finished), until T1 or quitAt +
                # MaxSecondsToAvailableAfterQuit + 5 s. EVERY quit outcome is
                # recorded: a success appends its delay (events + list), and
                # reaching the cap records a timeout event - a quit that
                # never becomes free can no longer disappear from the
                # summary and the verdict.
                $waitCapUtc = $quitAtUtc.AddSeconds($MaxSecondsToAvailableAfterQuit + 5)
                $foundAvailable = $false
                $nextProbeAtUtc = [DateTime]::UtcNow
                while ($true) {
                    if (Test-GsSoakHostFree -ServerInfo $info) {
                        $foundAvailable = $true
                        $delaySec = [math]::Round(([DateTime]::UtcNow - $quitAtUtc).TotalSeconds, 3)
                        $quitDelays.Add($delaySec)
                        $eventsWriter.WriteLine(([ordered]@{
                            timestampUtc = ([DateTime]::UtcNow).ToString('o')
                            type         = 'AvailableAfterQuit'
                            quitAtUtc    = $quitAtUtc.ToString('o')
                            seconds      = $delaySec
                        } | ConvertTo-Json -Compress -Depth 5))
                        break
                    }
                    if ([DateTime]::UtcNow -ge $waitCapUtc) { break }
                    $sleepMs = [int][Math]::Max(0, [Math]::Min(
                        ($nextProbeAtUtc - [DateTime]::UtcNow).TotalMilliseconds,
                        ($waitCapUtc - [DateTime]::UtcNow).TotalMilliseconds))
                    if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
                    if ([DateTime]::UtcNow -ge $waitCapUtc) { break }
                    $probeStartUtc = [DateTime]::UtcNow
                    $info = Get-GsSoakServerInfo -Uri $ServerInfoUri -TimeoutSec $ServerInfoTimeoutSec
                    $nextProbeAtUtc = $probeStartUtc.AddSeconds(1)
                }
                $waitingAvailable = $false
                if (-not $foundAvailable) {
                    $summary.quitTimeouts += 1
                    $waitedSec = [math]::Round(([DateTime]::UtcNow - $quitAtUtc).TotalSeconds, 3)
                    $eventsWriter.WriteLine(([ordered]@{
                        timestampUtc = ([DateTime]::UtcNow).ToString('o')
                        type         = 'AvailableAfterQuitTimeout'
                        quitAtUtc    = $quitAtUtc.ToString('o')
                        waitedSec    = $waitedSec
                        capSec       = $MaxSecondsToAvailableAfterQuit + 5
                    } | ConvertTo-Json -Compress -Depth 5))
                }
            }

            # ---- CSV row ----
            $row = New-Object System.Collections.Generic.List[string]
            $row.Add((ConvertTo-GsSoakCsvField $sampleStartUtc.ToString('o')))
            $row.Add((ConvertTo-GsSoakCsvField ([math]::Round($elapsedSec, 3))))
            $row.Add((ConvertTo-GsSoakCsvField $status.State))
            $row.Add((ConvertTo-GsSoakCsvField $status.Source))
            $row.Add((ConvertTo-GsSoakCsvField $(if ($null -eq $sampleInfo.Error) { 'true' } else { 'false' })))
            $row.Add((ConvertTo-GsSoakCsvField $sampleInfo.State))
            $row.Add((ConvertTo-GsSoakCsvField $sampleInfo.CurrentGame))
            $row.Add((ConvertTo-GsSoakCsvField $sampleInfo.Error))
            foreach ($role in $roleNames) {
                $procSample = $roleSamples[$role]
                if ($null -eq $procSample) {
                    foreach ($placeholder in @(1, 2, 3, 4)) { $row.Add('') }
                } else {
                    $row.Add((ConvertTo-GsSoakCsvField $procSample.Pid))
                    $row.Add((ConvertTo-GsSoakCsvField $procSample.WorkingSetMb))
                    $row.Add((ConvertTo-GsSoakCsvField $procSample.PrivateMb))
                    $row.Add((ConvertTo-GsSoakCsvField $procSample.Handles))
                }
            }
            $row.Add((ConvertTo-GsSoakCsvField $watch.Procs))
            $row.Add((ConvertTo-GsSoakCsvField $watch.WorkingSetMb))
            $row.Add((ConvertTo-GsSoakCsvField $watch.PrivateMb))
            $row.Add((ConvertTo-GsSoakCsvField $watch.Handles))
            $row.Add((ConvertTo-GsSoakCsvField $trackedPrivMb))
            $csvWriter.WriteLine(($row.ToArray() -join ','))
            $csvWriter.Flush()

            $summary.samples += 1
            if ($null -ne $trackedPrivMb) {
                $slopeSeconds.Add($elapsedSec)
                $slopePrivateMb.Add($trackedPrivMb)
            }

            # carry the per-role PID map and orphan state for the next diff
            $pidMap = @{ }
            foreach ($role in $roleNames) {
                $pidMap[$role] = $null
                if ($null -ne $roleSamples[$role]) { $pidMap[$role] = $roleSamples[$role].Pid }
            }
            $prev = [pscustomobject]@{
                StatusState = $status.State
                SiError     = $sampleInfo.Error
                RolePids    = $pidMap
                RoleOrphan  = $roleOrphan
                WatchPids   = $watch.Pids
            }

            if ($stopwatch.Elapsed.TotalSeconds -ge $effectiveDurationSec) { break }
            $remainingSec = $effectiveDurationSec - $stopwatch.Elapsed.TotalSeconds
            $sleepMs = [int]([math]::Min($remainingSec, [math]::Max(0, $IntervalSec - ($stopwatch.Elapsed.TotalSeconds - $elapsedSec))) * 1000)
            if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
            if ($stopwatch.Elapsed.TotalSeconds -ge $effectiveDurationSec) { break }
        }

        $summary.memorySlopeMBPerHour = Get-GsMemorySlopeMBPerHour -Seconds $slopeSeconds.ToArray() -PrivateMb $slopePrivateMb.ToArray()
        # The summary scalar is the WORST successful delay across the run, so
        # a later fast quit cannot hide an earlier over-threshold one.
        if ($quitDelays.Count -gt 0) {
            $worstDelay = $quitDelays[0]
            foreach ($d in $quitDelays) { if ($d -gt $worstDelay) { $worstDelay = $d } }
            $summary.secondsToAvailableAfterQuit = $worstDelay
        }
        if ($summary.samples -lt 1) { $verdictReasons.Add('NoSamples') }
        if ($null -ne $summary.memorySlopeMBPerHour -and $summary.memorySlopeMBPerHour -gt $MaxMemorySlopeMBPerHour) {
            $verdictReasons.Add(('MemorySlope {0} MB/h exceeds the provisional threshold {1} MB/h' -f $summary.memorySlopeMBPerHour, $MaxMemorySlopeMBPerHour))
        }
        if ($summary.pidChanges -gt $MaxPidChanges) {
            $verdictReasons.Add(('PidChanges {0} exceed the provisional threshold {1}' -f $summary.pidChanges, $MaxPidChanges))
        }
        if ($summary.orphans -gt 0) {
            $verdictReasons.Add(('Orphan role processes detected while stopped: {0}' -f $summary.orphans))
        }
        if ($summary.quitTimeouts -gt 0) {
            $verdictReasons.Add(('SecondsToAvailableAfterQuit: {0} quit(s) did not become available within {1}s + 5s and were recorded as timeouts' -f $summary.quitTimeouts, $MaxSecondsToAvailableAfterQuit))
        }
        if ($null -ne $summary.secondsToAvailableAfterQuit -and $summary.secondsToAvailableAfterQuit -gt $MaxSecondsToAvailableAfterQuit) {
            $verdictReasons.Add(('SecondsToAvailableAfterQuit {0}s exceeds the provisional threshold {1}s' -f $summary.secondsToAvailableAfterQuit, $MaxSecondsToAvailableAfterQuit))
        }
    }

    if ($Mode -eq 'Cycle') {
        $cycleWorkDir = $outFull
        for ($cycle = 1; $cycle -le $Count; $cycle++) {
            $cycleStartUtc = [DateTime]::UtcNow
            $phase = 'Stop'
            $success = $false
            $code = 'Unknown'
            $timedOut = $false
            $stopOutcome = Invoke-GsSoakProductAction -ProductScript $resolvedProduct -ProductAction 'Stop' -StateDirectory $StateDir -TimeoutSec $ActionTimeoutSec -WorkDir $cycleWorkDir
            if ($stopOutcome.Code -eq 'ActionTimeout') { $timedOut = $true }
            if (-not $stopOutcome.Success) {
                $code = $stopOutcome.Code
            } else {
                $phase = 'Start'
                $startOutcome = Invoke-GsSoakProductAction -ProductScript $resolvedProduct -ProductAction 'Start' -StateDirectory $StateDir -TimeoutSec $ActionTimeoutSec -WorkDir $cycleWorkDir
                if ($startOutcome.Code -eq 'ActionTimeout') { $timedOut = $true }
                if (-not $startOutcome.Success) {
                    $code = $startOutcome.Code
                } else {
                    $phase = 'Wait'
                    $ready = $false
                    $waitDeadline = [DateTime]::UtcNow.AddSeconds($CycleReadyTimeoutSec)
                    while ([DateTime]::UtcNow -lt $waitDeadline) {
                        if (Test-GsSoakCycleReady -StateDirectory $StateDir -ServerInfoUri $ServerInfoUri -ServerInfoTimeoutSec $ServerInfoTimeoutSec) {
                            $ready = $true
                            break
                        }
                        Start-Sleep -Milliseconds 500
                    }
                    if ($ready) {
                        $success = $true
                        $code = 'OK'
                    } else {
                        $code = 'ReadyTimeout'
                    }
                }
            }
            $durationSec = [math]::Round(([DateTime]::UtcNow - $cycleStartUtc).TotalSeconds, 3)
            $record = [pscustomobject]@{
                cycle       = $cycle
                phase       = $phase
                success     = $success
                code        = $code
                durationSec = $durationSec
            }
            $cycleResults.Add($record)
            $eventsWriter.WriteLine(([ordered]@{
                timestampUtc = ([DateTime]::UtcNow).ToString('o')
                type         = 'Cycle'
                cycle        = $cycle
                phase        = $phase
                success      = $success
                code         = $code
                durationSec  = $durationSec
            } | ConvertTo-Json -Compress -Depth 5))
            Write-Host ('CYCLE {0}/{1}: success={2} code={3} phase={4} durationSec={5}' -f $cycle, $Count, $success, $code, $phase, $durationSec)
            # An action that had to be killed means the runtime is not
            # cooperating: stop cycling (the remaining cycles would each burn
            # the same timeout), fail the verdict, and let the finally write
            # summary.json.
            if ($timedOut) {
                $verdictReasons.Add(('Cycle {0} stopped: a product action was killed at the {1}s deadline (ActionTimeout)' -f $cycle, $ActionTimeoutSec))
                break
            }
        }
        $summary.cycleResults = @($cycleResults.ToArray())
        foreach ($record in $summary.cycleResults) {
            if (-not $record.success) {
                $verdictReasons.Add(('Cycle {0} failed in phase {1} with code {2}' -f $record.cycle, $record.phase, $record.code))
            }
        }
    }

    $summary.verdictReasons = @($verdictReasons.ToArray())
    if ($summary.verdictReasons.Count -eq 0) { $summary.verdict = 'pass' }
    $script:FinalExitCode = 0
    if ($summary.verdict -ne 'pass') { $script:FinalExitCode = 1 }
} catch {
    $verdictReasons.Add(('Error: {0}' -f $_.Exception.Message))
    $summary.verdictReasons = @($verdictReasons.ToArray())
    $summary.verdict = 'fail'
    $script:FinalExitCode = 1
    Write-Error $_
} finally {
    # C-N2: an interrupted run must still report everything it already
    # finished. The normal paths above assign these from the same
    # accumulators; here only MISSING values are finalized so a Ctrl+C (or
    # any other unwind) mid-loop leaves completed cycles and the observed
    # regression data in summary.json instead of dropping them.
    if ($Mode -eq 'Cycle') {
        try { $summary.cycleResults = @($cycleResults.ToArray()) } catch { }
    }
    if ($Mode -eq 'Monitor') {
        try {
            if ($null -eq $summary.memorySlopeMBPerHour -and $null -ne $slopeSeconds) {
                $summary.memorySlopeMBPerHour = Get-GsMemorySlopeMBPerHour -Seconds $slopeSeconds.ToArray() -PrivateMb $slopePrivateMb.ToArray()
            }
            if ($null -eq $summary.secondsToAvailableAfterQuit -and $null -ne $quitDelays -and $quitDelays.Count -gt 0) {
                $worstDelay = $quitDelays[0]
                foreach ($d in $quitDelays) { if ($d -gt $worstDelay) { $worstDelay = $d } }
                $summary.secondsToAvailableAfterQuit = $worstDelay
            }
        } catch { }
    }
    $summary.endedUtc = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($writer in @($csvWriter, $eventsWriter)) {
        if ($null -ne $writer) {
            try { $writer.Flush() } catch { }
            try { $writer.Dispose() } catch { }
        }
    }
    try {
        [IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ('SUMMARY {0}: verdict={1} samples={2} slopeMBPerHour={3} pidChanges={4} streamTransitions={5} secondsToAvailableAfterQuit={6} orphans={7}' -f $summaryPath, $summary.verdict, $summary.samples, $summary.memorySlopeMBPerHour, $summary.pidChanges, $summary.streamTransitions, $summary.secondsToAvailableAfterQuit, $summary.orphans)
    } catch {
        Write-Error ('could not write summary.json: {0}' -f $_.Exception.Message)
    }
}

if ($script:FinalExitCode -ne 0) { exit 1 }
exit 0
