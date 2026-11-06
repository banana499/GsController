#Requires -Version 5.1
<#
.SYNOPSIS
    Checks docs/compatibility-test-plan.md (matrix structure, coverage, status
    rules, both the CMP- and ATV- tables, fictional device data, no MAC or
    unexpected IPv4 addresses, first table unchanged from git HEAD) and
    client/New-CompatibilityEvidence.ps1 (evidence skeleton for CMP- and ATV-
    cases, all-table reading, fixed-timestamp seam, byte-identical CMP
    output). No streaming, no adb, no host or client changes. Exits 0 only
    when every test passes and at least one ran; exits 1 otherwise.
    SKIP lines are counted separately and reported as
    "Summary: X passed, Y failed (skipped: Z)"; they do not affect the exit
    code as passes.

    The two historical-evidence comparisons (first matrix table identical to
    git HEAD, CMP output byte-identical to the pre-change script) SKIP only
    when the history side is structurally unavailable: git not on PATH, or
    an isolated source copy without .git metadata. A repository with .git
    but a failing `git show` (for example a missing blob) FAILS
    conservatively; with full history present, both comparisons must match
    exactly.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Thrown by a test body to record a SKIP (printed as "SKIP <name> :: <reason>";
# counts as a pass for the exit code).
class CompatTestSkip : System.Exception {
    CompatTestSkip([string]$Message) : base($Message) { }
}

function Skip-Test {
    param([Parameter(Mandatory)][string]$Reason)
    throw ([CompatTestSkip]::new($Reason))
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$planPath = Join-Path $repoRoot 'docs\compatibility-test-plan.md'
$scriptPath = Join-Path $repoRoot 'client\New-CompatibilityEvidence.ps1'

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
        if ($_.Exception -is [CompatTestSkip]) {
            $script:Skipped++
            Write-Host "SKIP $Name :: $($_.Exception.Message)"
            return
        }
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

function Assert-Empty {
    param($Items, [string]$Message)
    $list = @($Items)
    if ($list.Count -gt 0) { throw "Assertion failed: $Message :: $($list -join '; ')" }
}

function Assert-SameBytes {
    param([byte[]]$BytesA, [byte[]]$BytesB, [string]$Message)
    if ($BytesA.Length -ne $BytesB.Length) {
        throw "Assertion failed: $Message (byte length $($BytesA.Length) vs $($BytesB.Length))"
    }
    for ($i = 0; $i -lt $BytesA.Length; $i++) {
        if ($BytesA[$i] -ne $BytesB[$i]) { throw "Assertion failed: $Message (byte $i differs)" }
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

# True when the repo root carries git repository metadata: a .git directory,
# or a .git FILE as in worktrees and linked checkouts. An isolated source
# copy without it has no history to compare against; only the two
# historical-evidence tests consult this and SKIP on its absence. It is a
# plain filesystem check: Get-GitHeadText's FAIL contract for nonzero exits,
# timeouts and drain failures is untouched, so a repo WITH .git but a
# failing git show (for example a missing blob) still FAILs conservatively.
function Test-GitHistoryPresent([string]$RepoPath) {
    $dotGit = Join-Path $RepoPath '.git'
    return ((Test-Path -LiteralPath $dotGit -PathType Container) -or (Test-Path -LiteralPath $dotGit -PathType Leaf))
}

# Runs `git show <GitSpec>` in $RepoPath with ONE hard deadline that covers
# both the process exit and the draining of stdout/stderr. Returns a
# structured result @{ GitAvailable; OK; Text; Reason }:
#   - GitAvailable is $false ONLY when git is not on PATH. That is the only
#     situation callers may report as a SKIP.
#   - Every other problem (start failure, nonzero exit, process timeout,
#     stdout/stderr drain past the shared deadline) is a failure that
#     callers must FAIL on.
# -GitExecutable is a test seam (a stand-in git executable path).
function Get-GitHeadText {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$GitSpec,
        [int]$TimeoutMs = 20000,
        [string]$GitExecutable = 'git'
    )
    $exe = $GitExecutable
    if ($exe -eq 'git') {
        $cmd = Get-Command git -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            return @{ GitAvailable = $false; OK = $false; Text = ''; Reason = 'git is not on PATH' }
        }
        $exe = $cmd.Source
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = 'show "' + $GitSpec + '"'
    $psi.WorkingDirectory = $RepoPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try {
        try {
            if (-not $p.Start()) {
                return @{ GitAvailable = $true; OK = $false; Text = ''; Reason = 'git process could not be started' }
            }
        } catch {
            return @{ GitAvailable = $true; OK = $false; Text = ''; Reason = ('git process start failed: ' + $_.Exception.Message) }
        }
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return @{ GitAvailable = $true; OK = $false; Text = ''; Reason = ('git did not exit within the shared ' + $TimeoutMs + ' ms deadline; killed') }
        }
        $leftMs = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($leftMs -lt 0) { $leftMs = 0 }
        if (-not $outTask.Wait($leftMs)) {
            try { $p.Kill() } catch { }
            return @{ GitAvailable = $true; OK = $false; Text = ''; Reason = ('stdout did not drain within the shared ' + $TimeoutMs + ' ms deadline') }
        }
        $leftMs = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($leftMs -lt 0) { $leftMs = 0 }
        if (-not $errTask.Wait($leftMs)) {
            return @{ GitAvailable = $true; OK = $false; Text = ''; Reason = ('stderr did not drain within the shared ' + $TimeoutMs + ' ms deadline') }
        }
        if ($p.ExitCode -ne 0) {
            return @{ GitAvailable = $true; OK = $false; Text = ''; Reason = ('git exited with code ' + $p.ExitCode + ': ' + $errTask.Result.Trim()) }
        }
        return @{ GitAvailable = $true; OK = $true; Text = $outTask.Result; Reason = '' }
    } finally {
        $p.Dispose()
    }
}

# ---- Plan parsing and checks (independent of the evidence script) ----

$RequiredColumns = @('ID', 'Dimension', 'Settings', 'Prerequisites', 'Procedure',
    'Pass criteria', 'Evidence required', 'Status', 'Evidence path', 'Reason')
$AllowedStatuses = @('pass', 'fail', 'unsupported', 'not covered')
$KnownDimensions = @('Baseline', 'H.264', 'HDR', 'AV1', '5.1', '7.1', '1080p',
    'Gamepad-Xbox', 'Gamepad-DS4', 'Gamepad-Generic')
$RequiredDimensions = @('HDR', 'AV1', '7.1', 'Gamepad-Xbox', 'Gamepad-DS4', 'Gamepad-Generic')
$ExpectedAtvIds = @('ATV-BASE-01', 'ATV-H264-01', 'ATV-1080-01', 'ATV-1080-02', 'ATV-HDR-01',
    'ATV-AV1-01', 'ATV-AV1-02', 'ATV-AUD-01', 'ATV-AUD-02', 'ATV-PAD-01')

function Split-MarkdownRow {
    param([string]$Line)
    $t = $Line.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|')) { $t = $t.Substring(0, $t.Length - 1) }
    return , @($t.Split('|') | ForEach-Object { $_.Trim() })
}

# Parses the first markdown table whose header starts with "| ID |".
# Returns @{ Header = string[]; Rows = object[] } where each row carries
# Cells (raw), CellCount, and one property per header column.
function ConvertFrom-MatrixMarkdown {
    param([Parameter(Mandatory)][string]$Text)
    $lines = $Text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\|\s*ID\s*\|') { $start = $i; break }
    }
    if ($start -lt 0) { throw 'matrix table (header starting with "| ID |") not found' }
    $header = Split-MarkdownRow $lines[$start]
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -notmatch '^\s*\|') { break }
        if ($line -match '^\s*\|[\s:\-\|]+\|\s*$') { continue }
        $cells = Split-MarkdownRow $line
        $row = [ordered]@{ Cells = $cells; CellCount = $cells.Count; Line = $line.Trim() }
        for ($c = 0; $c -lt $header.Count; $c++) {
            $value = ''
            if ($c -lt $cells.Count) { $value = $cells[$c].Trim('`').Trim() }
            $row[$header[$c]] = $value
        }
        $rows.Add([pscustomobject]$row)
    }
    return @{ Header = $header; Rows = $rows.ToArray() }
}

# Parses EVERY markdown table whose header starts with "| ID |" (not just the
# first). Returns an array of @{ HeaderLine; Header; Rows } in document order.
function ConvertFrom-AllMatrixTables {
    param([Parameter(Mandatory)][string]$Text)
    $lines = $Text -split "`r?`n"
    $tables = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^\s*\|\s*ID\s*\|') { continue }
        $headerLine = $lines[$i].Trim()
        $header = Split-MarkdownRow $lines[$i]
        $rows = New-Object System.Collections.Generic.List[object]
        $i++
        while ($i -lt $lines.Count -and $lines[$i] -match '^\s*\|') {
            if ($lines[$i] -notmatch '^\s*\|[\s:\-\|]+\|\s*$') {
                $cells = Split-MarkdownRow $lines[$i]
                $row = [ordered]@{ Cells = $cells; CellCount = $cells.Count; Line = $lines[$i].Trim() }
                for ($c = 0; $c -lt $header.Count; $c++) {
                    $value = ''
                    if ($c -lt $cells.Count) { $value = $cells[$c].Trim('`').Trim() }
                    $row[$header[$c]] = $value
                }
                $rows.Add([pscustomobject]$row)
            }
            $i++
        }
        $tables += , @{ HeaderLine = $headerLine; Header = $header; Rows = $rows.ToArray() }
    }
    return , $tables
}

# Lines of the first "| ID |" table as the COMPLETE RAW block: the header
# line through the last consecutive line that starts with '|', the separator
# row and all whitespace included, compared ORDINALLY. Factored so the probe
# test exercises the same extraction/comparison.
function Get-FirstTableBlockLines([string]$Text) {
    if ($null -eq $Text) { throw 'matrix table (header starting with "| ID |") not found' }
    $lines = $Text -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\|\s*ID\s*\|') { $start = $i; break }
    }
    if ($start -lt 0) { throw 'matrix table (header starting with "| ID |") not found' }
    $end = $start
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\|') { $end = $i } else { break }
    }
    $out = @()
    for ($i = $start; $i -le $end; $i++) { $out += $lines[$i] }
    return $out
}

function Compare-FirstTableBlocks([string]$OldText, [string]$NewText) {
    $o = Get-FirstTableBlockLines $OldText
    $n = Get-FirstTableBlockLines $NewText
    if ($o.Count -ne $n.Count) { return 'line count differs' }
    for ($i = 0; $i -lt $o.Count; $i++) {
        if ($o[$i] -cne $n[$i]) { return ('line ' + $i + ' differs') }
    }
    return ''
}

function Get-StatusViolations {
    param([object[]]$Rows)
    foreach ($r in $Rows) {
        if ($AllowedStatuses -cnotcontains $r.Status) { "$($r.ID): status '$($r.Status)' is not allowed" }
    }
}

function Get-PassEvidenceViolations {
    param([object[]]$Rows)
    foreach ($r in $Rows) {
        if ($r.Status -ceq 'pass' -and [string]::IsNullOrWhiteSpace($r.'Evidence path')) {
            "$($r.ID): pass without evidence path"
        }
    }
}

function Get-UnsupportedReasonViolations {
    param([object[]]$Rows)
    foreach ($r in $Rows) {
        if ($r.Status -ceq 'unsupported' -and [string]::IsNullOrWhiteSpace($r.Reason)) {
            "$($r.ID): unsupported without reason"
        }
    }
}

function Get-DimensionTokens {
    param([object[]]$Rows)
    foreach ($r in $Rows) { foreach ($t in ($r.Dimension -split '\+')) { $t.Trim() } }
}

function Read-Utf8 {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

# Rows of ALL "| ID |" tables, in document order.
function Get-PlanRows {
    if ($null -eq $script:AllTables -or @($script:AllTables).Count -eq 0) { throw 'plan not parsed' }
    foreach ($t in $script:AllTables) { $t.Rows }
}

# IPv4 scan used by the plan/script/test self-scan. Factored so the probe
# test exercises the same rule. Matches COMPLETE IPv4 addresses only: every
# octet 0-255, and never a fragment of a longer dotted or digit run.
$script:Ipv4Rx = [regex]'(?<![\d.])((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\d.])'

function Test-TvboxAllowedIp([string]$Ip) {
    # Allowlist: loopback, the unspecified address, and the three
    # documentation ranges. No real LAN address is allowed anywhere.
    if ($Ip -ceq '127.0.0.1' -or $Ip -ceq '0.0.0.0') { return $true }
    foreach ($prefix in @('192.0.2.', '198.51.100.', '203.0.113.')) {
        if ($Ip.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

$fixtureHeader = '| ID | Dimension | Settings | Prerequisites | Procedure | Pass criteria | Evidence required | Status | Evidence path | Reason |'
$fixtureSep = '|---|---|---|---|---|---|---|---|---|---|'
function New-FixturePlanText {
    param([string[]]$RowLines)
    return (@('# Fixture', '', '## Matrix', '', $fixtureHeader, $fixtureSep) + $RowLines + @('', '## After')) -join "`r`n"
}

# A fixture plan with two "| ID |" tables and prose between them.
function New-FixtureTwoTableText {
    param([string[]]$TableOneRows, [string[]]$TableTwoRows)
    $lines = @('# Fixture', '', '## One', '', $fixtureHeader, $fixtureSep) + $TableOneRows +
        @('', 'Prose between the tables.', '', '## Two', '', $fixtureHeader, $fixtureSep) + $TableTwoRows +
        @('', '## After')
    return ($lines -join "`r`n")
}

$script:PlanText = $null
$script:AllTables = @()

$tempRoot = [System.IO.Path]::GetTempPath()
$workDir = Join-Path $tempRoot ('GsCompatPlan_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null
$workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath
$inRepoRoot = Join-Path $repoRoot 'docs'
# Names of compat-* directories already in docs/ before the run; only new ones
# (created by a faulty script under test) are removed in the finally block.
$preExistingInRepo = @(Get-ChildItem -LiteralPath $inRepoRoot -Directory -Filter 'compat-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

function New-EvidenceRoot {
    param([string]$Name)
    $p = Join-Path $workDir $Name
    New-Item -ItemType Directory -Path $p | Out-Null
    return $p
}

try {
    # ---- Parser self-checks on fixtures ----
    Invoke-Test 'parser reads fixture rows and columns' {
        $text = New-FixturePlanText @('| CMP-TST-01 | HDR | `--hdr` | p | P-COMMON | c | e | not covered |  |  |')
        $p = ConvertFrom-MatrixMarkdown -Text $text
        Assert-Equal 1 @($p.Rows).Count 'one row'
        Assert-Equal 'CMP-TST-01' $p.Rows[0].ID 'ID'
        Assert-Equal 'not covered' $p.Rows[0].Status 'Status'
        Assert-Equal '' $p.Rows[0].'Evidence path' 'empty evidence path'
    }

    Invoke-Test 'status check flags a status outside the allowed set' {
        $text = New-FixturePlanText @('| CMP-TST-01 | HDR | s | p | P-COMMON | c | e | passed |  |  |')
        $v = @(Get-StatusViolations (ConvertFrom-MatrixMarkdown -Text $text).Rows)
        Assert-Equal 1 $v.Count 'one violation'
    }

    Invoke-Test 'pass check flags a pass row without evidence path' {
        $text = New-FixturePlanText @(
            '| CMP-TST-01 | HDR | s | p | P-COMMON | c | e | pass |  |  |',
            '| CMP-TST-02 | HDR | s | p | P-COMMON | c | e | pass | C:\gs-evidence\compat-CMP-TST-02-20260101_000000 |  |')
        $v = @(Get-PassEvidenceViolations (ConvertFrom-MatrixMarkdown -Text $text).Rows)
        Assert-Equal 1 $v.Count 'one violation'
        Assert-True ($v[0] -like 'CMP-TST-01*') 'violation names CMP-TST-01'
    }

    Invoke-Test 'unsupported check flags an unsupported row without reason' {
        $text = New-FixturePlanText @(
            '| CMP-TST-01 | AV1 | s | p | P-COMMON | c | e | unsupported |  |  |',
            '| CMP-TST-02 | AV1 | s | p | P-COMMON | c | e | unsupported |  | Client has no AV1 hardware decoder |')
        $v = @(Get-UnsupportedReasonViolations (ConvertFrom-MatrixMarkdown -Text $text).Rows)
        Assert-Equal 1 $v.Count 'one violation'
        Assert-True ($v[0] -like 'CMP-TST-01*') 'violation names CMP-TST-01'
    }

    # ---- The real plan ----
    Invoke-Test 'plan file exists and matrix parses' {
        Assert-True (Test-Path -LiteralPath $planPath -PathType Leaf) "plan exists at $planPath"
        $script:PlanText = Read-Utf8 $planPath
        $script:AllTables = ConvertFrom-AllMatrixTables -Text $script:PlanText
        Assert-True (@($script:AllTables).Count -ge 1) 'at least one matrix table'
        Assert-True (@(Get-PlanRows).Count -gt 0) 'matrix has rows'
    }

    Invoke-Test 'matrix header has the required columns in order' {
        if (@($script:AllTables).Count -eq 0) { throw 'plan not parsed' }
        foreach ($t in $script:AllTables) {
            Assert-Equal ($RequiredColumns -join ' | ') ($t.Header -join ' | ') 'header columns'
        }
    }

    Invoke-Test 'every matrix row has the header cell count' {
        $bad = @()
        foreach ($t in $script:AllTables) {
            $n = $t.Header.Count
            $bad += @($t.Rows | Where-Object { $_.CellCount -ne $n } | ForEach-Object { $_.Line })
        }
        Assert-Empty $bad 'rows with wrong cell count'
    }

    Invoke-Test 'case IDs are well-formed' {
        Assert-Empty @(Get-PlanRows | Where-Object { $_.ID -cnotmatch '^(CMP|ATV)-[A-Z0-9]+-\d{2}$' } | ForEach-Object { $_.ID }) 'malformed IDs'
    }

    Invoke-Test 'case IDs are unique' {
        $dupes = @(Get-PlanRows | Group-Object -Property ID | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        Assert-Empty $dupes 'duplicate IDs'
    }

    Invoke-Test 'dimension tokens use the known vocabulary' {
        Assert-Empty @(Get-DimensionTokens (Get-PlanRows) | Where-Object { $KnownDimensions -cnotcontains $_ }) 'unknown dimension tokens'
    }

    foreach ($dim in $RequiredDimensions) {
        Invoke-Test "dimension $dim has at least one row" {
            $tokens = @(Get-DimensionTokens (Get-PlanRows))
            Assert-True ($tokens -ccontains $dim) "no row covers $dim"
        }
    }

    Invoke-Test 'every status is one of the allowed values' {
        Assert-Empty @(Get-StatusViolations (Get-PlanRows)) 'status violations'
    }

    Invoke-Test 'every pass row has an evidence path' {
        Assert-Empty @(Get-PassEvidenceViolations (Get-PlanRows)) 'pass rows without evidence'
    }

    Invoke-Test 'every unsupported row has a reason' {
        Assert-Empty @(Get-UnsupportedReasonViolations (Get-PlanRows)) 'unsupported rows without reason'
    }

    Invoke-Test 'every procedure ref resolves to a plan heading' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($r in (Get-PlanRows)) {
            $refs = @([regex]::Matches($r.Procedure, 'P-[A-Z0-9]+') | ForEach-Object { $_.Value })
            if ($refs.Count -eq 0) { $bad.Add("$($r.ID): no procedure ref") }
            foreach ($ref in $refs) {
                if ($script:PlanText -notmatch ('(?m)^###\s+' + [regex]::Escape($ref) + '\b')) { $bad.Add("$($r.ID): $ref") }
            }
        }
        Assert-Empty $bad 'unresolved procedure refs'
    }

    Invoke-Test 'plan documents each allowed status' {
        foreach ($s in $AllowedStatuses) {
            Assert-True ($script:PlanText -match ('(?m)^\|\s*`' + [regex]::Escape($s) + '`\s*\|')) "status table row for '$s'"
        }
    }

    # ---- The ATV part of the plan ----
    Invoke-Test 'ATV matrix has the ten planned rows' {
        $actual = @(Get-PlanRows | Where-Object { $_.ID -like 'ATV-*' } | ForEach-Object { $_.ID })
        Assert-Equal ($ExpectedAtvIds -join ',') ($actual -join ',') 'ATV row IDs in order'
    }

    Invoke-Test 'every ATV row keeps ui: settings and references P-ANDROID' {
        $rows = @(Get-PlanRows | Where-Object { $_.ID -like 'ATV-*' })
        Assert-True ($rows.Count -gt 0) 'no ATV rows found'
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($r in $rows) {
            if (-not $r.Settings.StartsWith('ui:')) { $bad.Add("$($r.ID): settings do not start with 'ui:'") }
            if ($r.Procedure -notmatch 'P-ANDROID') { $bad.Add("$($r.ID): procedure does not reference P-ANDROID") }
        }
        Assert-Empty $bad 'ATV settings or procedure violations'
    }

    Invoke-Test 'every ATV row is not covered' {
        $bad = @(Get-PlanRows | Where-Object { $_.ID -like 'ATV-*' -and $_.Status -cne 'not covered' } | ForEach-Object { "$($_.ID): $($_.Status)" })
        Assert-Empty $bad 'ATV rows not in status "not covered"'
    }

    Invoke-Test 'ATV section uses only the fictional device data' {
        Assert-True ($script:PlanText -match '(?m)^## Android TV client matrix\s*$') 'ATV section heading'
        foreach ($token in @('TESTBOX', '192.0.2.10:5555', '2160p60', '4:2:0', '12.2', 'frac_rate_policy')) {
            Assert-True ($script:PlanText.Contains($token)) "plan mentions $token"
        }
        # The fictional placeholders must appear in the ATV section itself
        # (the TV box baseline table), not just somewhere in the plan.
        $atvSection = $script:PlanText.Substring($script:PlanText.IndexOf('## Android TV client matrix'))
        Assert-True ($atvSection.Contains('TESTBOX')) 'ATV baseline table names the TESTBOX placeholder'
        Assert-True ($atvSection.Contains('192.0.2.10:5555')) 'ATV baseline table uses the documentation-range address'
    }

    Invoke-Test 'plan and scripts contain no MAC pattern and only allowed IPv4 addresses' {
        $files = @($planPath, $scriptPath, $PSCommandPath)
        $macPattern = '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'
        foreach ($f in $files) {
            Assert-True (Test-Path -LiteralPath $f -PathType Leaf) "scan target exists: $f"
            $text = Read-Utf8 $f
            $macs = @([regex]::Matches($text, $macPattern) | ForEach-Object { $_.Value })
            Assert-Equal 0 $macs.Count "MAC-address pattern in $f :: $($macs -join ', ')"
            $ips = @($script:Ipv4Rx.Matches($text) | ForEach-Object { $_.Value })
            foreach ($ip in $ips) {
                Assert-True (Test-TvboxAllowedIp $ip) "unexpected IPv4 address '$ip' in $f"
            }
        }
    }

    Invoke-Test 'first matrix table is identical to git HEAD' {
        if (-not (Test-GitHistoryPresent $repoRoot)) {
            Skip-Test 'no git history available (isolated source copy without .git)'
        }
        $head = Get-GitHeadText -RepoPath $repoRoot -GitSpec 'HEAD:docs/compatibility-test-plan.md'
        if (-not $head.GitAvailable) { Skip-Test $head.Reason }
        Assert-True $head.OK ('git show failed: ' + $head.Reason)
        $oldLines = Get-FirstTableBlockLines $head.Text
        $newLines = Get-FirstTableBlockLines $script:PlanText
        Assert-Equal $oldLines.Count $newLines.Count 'first table line count changed'
        for ($i = 0; $i -lt $oldLines.Count; $i++) {
            Assert-True ([System.StringComparer]::Ordinal.Equals($oldLines[$i], $newLines[$i])) ('first matrix table line ' + $i + ' changed: [' + $oldLines[$i] + '] vs [' + $newLines[$i] + ']')
        }
    }

    # ---- New-CompatibilityEvidence.ps1 ----
    Invoke-Test 'evidence script exists' {
        Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) "script exists at $scriptPath"
    }

    Invoke-Test 'evidence script creates case directory and record.md' {
        $root = New-EvidenceRoot 'create'
        $out = @(& $scriptPath -CaseId 'CMP-HDR-01' -EvidenceRoot $root)
        Assert-Equal 1 $out.Count 'one output object'
        $dir = [string]$out[0]
        Assert-True (Test-Path -LiteralPath $dir -PathType Container) 'returned path is a directory'
        Assert-Equal $root (Split-Path -Parent $dir) 'directory is directly under EvidenceRoot'
        Assert-True ((Split-Path -Leaf $dir) -cmatch '^compat-CMP-HDR-01-\d{8}_\d{6}$') "directory name '$(Split-Path -Leaf $dir)'"
        $record = Join-Path $dir 'record.md'
        Assert-True (Test-Path -LiteralPath $record -PathType Leaf) 'record.md exists'
        $text = Read-Utf8 $record
        $row = @(Get-PlanRows | Where-Object { $_.ID -ceq 'CMP-HDR-01' })[0]
        Assert-True ($text.Contains('CMP-HDR-01')) 'record contains case ID'
        Assert-True ($text.Contains($row.Settings)) 'record contains the plan row settings'
        foreach ($field in @('Client device', 'Moonlight version', 'Host GPU / driver', 'Result status', 'Observations', 'Files')) {
            Assert-True ($text.Contains($field)) "record contains field '$field'"
        }
    }

    Invoke-Test 'evidence script rejects an unknown CaseId and creates nothing' {
        $root = New-EvidenceRoot 'unknown'
        Assert-ArgumentException { & $scriptPath -CaseId 'CMP-NOPE-99' -EvidenceRoot $root } 'CaseId' 'unknown CaseId'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $root -Force).Count 'nothing created'
    }

    Invoke-Test 'evidence script rejects a missing EvidenceRoot' {
        $missing = Join-Path $workDir 'does-not-exist'
        Assert-ArgumentException { & $scriptPath -CaseId 'CMP-HDR-01' -EvidenceRoot $missing } 'EvidenceRoot' 'missing root'
        Assert-True (-not (Test-Path -LiteralPath $missing)) 'root not created'
    }

    Invoke-Test 'evidence script refuses an EvidenceRoot inside the repository' {
        Assert-ArgumentException { & $scriptPath -CaseId 'CMP-HDR-01' -EvidenceRoot $inRepoRoot } 'EvidenceRoot' 'in-repo root'
        $created = @(Get-ChildItem -LiteralPath $inRepoRoot -Directory -Filter 'compat-*' | Where-Object { $preExistingInRepo -notcontains $_.Name })
        Assert-Equal 0 $created.Count 'nothing created in repo'
    }

    Invoke-Test 'evidence script validates CaseId against -PlanPath' {
        $fixturePlan = Join-Path $workDir 'fixture-plan.md'
        $text = New-FixturePlanText @('| CMP-TST-01 | 7.1 | `--audio-config 7.1-surround` | p | P-COMMON | c | e | not covered |  |  |')
        [System.IO.File]::WriteAllText($fixturePlan, $text, (New-Object System.Text.UTF8Encoding($false)))
        $root = New-EvidenceRoot 'planpath'
        $dir = [string](@(& $scriptPath -CaseId 'CMP-TST-01' -EvidenceRoot $root -PlanPath $fixturePlan)[0])
        Assert-True ((Split-Path -Leaf $dir) -cmatch '^compat-CMP-TST-01-\d{8}_\d{6}$') 'fixture case directory'
        Assert-True ((Read-Utf8 (Join-Path $dir 'record.md')).Contains('--audio-config 7.1-surround')) 'fixture settings in record'
        Assert-ArgumentException { & $scriptPath -CaseId 'CMP-HDR-01' -EvidenceRoot $root -PlanPath $fixturePlan } 'CaseId' 'ID absent from fixture plan'
    }

    Invoke-Test 'evidence script works via powershell.exe -File with default PlanPath' {
        $root = New-EvidenceRoot 'childproc'
        $exe = Join-Path $PSHOME 'powershell.exe'
        $out = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -CaseId 'CMP-AV1-01' -EvidenceRoot $root 2>&1)
        Assert-Equal 0 $LASTEXITCODE "child exit code; output: $($out -join ' / ')"
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory)
        Assert-Equal 1 $dirs.Count 'one case directory'
        Assert-True ($dirs[0].Name -cmatch '^compat-CMP-AV1-01-\d{8}_\d{6}$') "directory name '$($dirs[0].Name)'"
        Assert-True (Test-Path -LiteralPath (Join-Path $dirs[0].FullName 'record.md') -PathType Leaf) 'record.md exists'
        Assert-True (($out -join "`n").Contains($dirs[0].FullName)) 'created path written to output'
    }

    Invoke-Test 'audio case record has a per-channel table' {
        $root = New-EvidenceRoot 'audio'
        $dir = [string](@(& $scriptPath -CaseId 'CMP-AUD-02' -EvidenceRoot $root)[0])
        $text = Read-Utf8 (Join-Path $dir 'record.md')
        foreach ($ch in @('FL', 'FR', 'FC', 'LFE', 'BL', 'BR', 'SL', 'SR')) {
            Assert-True ($text -match ('(?m)^\|\s*' + $ch + '\s*\|')) "channel row $ch"
        }
    }

    Invoke-Test 'gamepad case record has input and reconnect checks' {
        $root = New-EvidenceRoot 'pad'
        $dir = [string](@(& $scriptPath -CaseId 'CMP-PAD-02' -EvidenceRoot $root)[0])
        $text = Read-Utf8 (Join-Path $dir 'record.md')
        foreach ($item in @('joy.cpl', 'Disconnect', 'Reconnect')) {
            Assert-True ($text.Contains($item)) "gamepad record mentions '$item'"
        }
    }

    # ---- ATV evidence records ----
    Invoke-Test 'ATV evidence record has P-ANDROID checks and overlay fields' {
        $root = New-EvidenceRoot 'atv'
        $out = @(& $scriptPath -CaseId 'ATV-BASE-01' -EvidenceRoot $root)
        Assert-Equal 1 $out.Count 'one output object'
        $dir = [string]$out[0]
        Assert-True ((Split-Path -Leaf $dir) -cmatch '^compat-ATV-BASE-01-\d{8}_\d{6}$') "directory name '$(Split-Path -Leaf $dir)'"
        $text = Read-Utf8 (Join-Path $dir 'record.md')
        $row = @(Get-PlanRows | Where-Object { $_.ID -ceq 'ATV-BASE-01' })[0]
        Assert-True ($text.Contains($row.Settings)) 'record contains the ATV row settings'
        foreach ($field in @('P-ANDROID', 'frac_rate_policy', 'screencap', 'com.limelight',
                'settings-page.png', 'overlay.png', 'logcat-limelight.txt',
                'Video stream:', 'Decoder:', 'Incoming frame rate from network:', 'Rendering frame rate:',
                'Frames dropped by your network connection:', 'Average network latency:', 'Average decoding time:',
                '57 FPS', '55 FPS', '1%',
                'host-status-before.txt', 'host-qos.txt', 'host-status-after.txt')) {
            Assert-True ($text.Contains($field)) "ATV record contains '$field'"
        }
        Assert-True ($text -notmatch 'Moonlight stream') 'ATV record contains a Moonlight command line'
    }

    Invoke-Test 'evidence script finds case rows in later tables' {
        $fixturePlan = Join-Path $workDir 'twotable-plan.md'
        $text = New-FixtureTwoTableText `
            @('| CMP-TST-01 | HDR | `--hdr` | p | P-COMMON | c | e | not covered |  |  |') `
            @('| CMP-TST-02 | 5.1 | `--audio-config 5.1-surround` | p | P-COMMON | c | e | not covered |  |  |')
        [System.IO.File]::WriteAllText($fixturePlan, $text, (New-Object System.Text.UTF8Encoding($false)))
        $root = New-EvidenceRoot 'twotables'
        $dir = [string](@(& $scriptPath -CaseId 'CMP-TST-02' -EvidenceRoot $root -PlanPath $fixturePlan)[0])
        Assert-True ((Split-Path -Leaf $dir) -cmatch '^compat-CMP-TST-02-\d{8}_\d{6}$') 'second-table case directory'
        Assert-True ((Read-Utf8 (Join-Path $dir 'record.md')).Contains('--audio-config 5.1-surround')) 'second-table settings in record'
    }

    Invoke-Test 'evidence script rejects duplicate case IDs across tables' {
        $fixturePlan = Join-Path $workDir 'dupe-plan.md'
        $text = New-FixtureTwoTableText `
            @('| CMP-TST-01 | HDR | `--hdr` | p | P-COMMON | c | e | not covered |  |  |') `
            @('| CMP-TST-01 | AV1 | `--video-codec AV1` | p | P-COMMON | c | e | not covered |  |  |')
        [System.IO.File]::WriteAllText($fixturePlan, $text, (New-Object System.Text.UTF8Encoding($false)))
        $root = New-EvidenceRoot 'dupes'
        Assert-ArgumentException { & $scriptPath -CaseId 'CMP-TST-01' -EvidenceRoot $root -PlanPath $fixturePlan } 'PlanPath' 'duplicate ID across tables'
    }

    Invoke-Test 'evidence script -Now fixes the timestamp' {
        $stamp = [datetime]::ParseExact('20260203_040506', 'yyyyMMdd_HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        $root1 = New-EvidenceRoot 'now1'
        $root2 = New-EvidenceRoot 'now2'
        $d1 = [string](@(& $scriptPath -CaseId 'CMP-BASE-01' -EvidenceRoot $root1 -Now $stamp)[0])
        $d2 = [string](@(& $scriptPath -CaseId 'CMP-BASE-01' -EvidenceRoot $root2 -Now $stamp)[0])
        Assert-Equal 'compat-CMP-BASE-01-20260203_040506' (Split-Path -Leaf $d1) 'fixed directory name (run 1)'
        Assert-Equal (Split-Path -Leaf $d1) (Split-Path -Leaf $d2) 'same -Now gives the same directory name'
    }

    # ---- Round-4 probes: allowlist/git/table-comparison/screenshot/CaseId ----
    Invoke-Test 'probe: IPv4 scan matches complete addresses and enforces the allowlist' {
        $badA = '192.168.' + '1.23'
        $badB = '10.0.' + '0.9'
        $badC = '172.16.' + '3.4'
        $sample = 'client ' + $badA + ' gateway ' + $badB + ' wifi ' + $badC
        $hits = @($script:Ipv4Rx.Matches($sample) | ForEach-Object { $_.Value })
        foreach ($bad in @($badA, $badB, $badC)) {
            Assert-True ($hits -ccontains $bad) ('scan did not match ' + $bad)
            Assert-True (-not (Test-TvboxAllowedIp $bad)) ('allowlist accepted ' + $bad)
        }
        foreach ($ok in @('127.0.0.1', '0.0.0.0', '192.0.2.10', '198.51.100.7', '203.0.113.9')) {
            Assert-True (Test-TvboxAllowedIp $ok) ('allowlist rejected ' + $ok)
        }
        $longer = '9.9.9.' + '9.1'  # a longer dotted run; no complete address inside
        $hitsL = @($script:Ipv4Rx.Matches(('addr ' + $longer + ' end')) | ForEach-Object { $_.Value })
        Assert-Equal 0 $hitsL.Count ('scan matched a fragment of a longer dotted run: ' + ($hitsL -join ', '))
    }

    Invoke-Test 'probe: git failure is a FAIL, not a SKIP (exit code surface)' {
        $fake = Join-Path $workDir 'fakegit-fail.cmd'
        $body = '@echo off' + "`r`n" + 'echo fatal: bad object 1>&2' + "`r`n" + 'exit /b 7' + "`r`n"
        [System.IO.File]::WriteAllText($fake, $body, [System.Text.Encoding]::ASCII)
        $r = Get-GitHeadText -RepoPath $repoRoot -GitSpec 'HEAD:docs/compatibility-test-plan.md' -GitExecutable $fake
        if ($null -eq $r) { throw 'git failure returned $null (would be reported as a SKIP)' }
        Assert-True (-not $r.OK) 'git failure not reported as a failure'
        Assert-True ($r.Reason -match '7') ('reason does not carry the exit code: ' + $r.Reason)
    }

    Invoke-Test 'probe: git that never exits fails within the deadline (not SKIP)' {
        $fake = Join-Path $workDir 'fakegit-hang.cmd'
        $body = '@echo off' + "`r`n" + 'powershell.exe -NoProfile -Command "Start-Sleep 5"' + "`r`n"
        [System.IO.File]::WriteAllText($fake, $body, [System.Text.Encoding]::ASCII)
        $r = Get-GitHeadText -RepoPath $repoRoot -GitSpec 'HEAD:docs/compatibility-test-plan.md' -GitExecutable $fake -TimeoutMs 1500
        if ($null -eq $r) { throw 'deadline exceeded returned $null (would be reported as a SKIP)' }
        Assert-True (-not $r.OK) 'timeout not reported as a failure'
    }

    Invoke-Test 'probe: stdout drain is bounded by the same deadline' {
        $holder = Join-Path $workDir 'fakegit-drain.ps1'
        $holderBody = @'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = '-NoProfile -Command "Start-Sleep 6"'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
[void][System.Diagnostics.Process]::Start($psi)
[Console]::Out.Write('HEADfake')
'@
        [System.IO.File]::WriteAllText($holder, $holderBody, (New-Object System.Text.UTF8Encoding($false)))
        $fake = Join-Path $workDir 'fakegit-drain.cmd'
        $fakeBody = '@echo off' + "`r`n" + ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $holder) + "`r`n"
        [System.IO.File]::WriteAllText($fake, $fakeBody, [System.Text.Encoding]::ASCII)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Get-GitHeadText -RepoPath $repoRoot -GitSpec 'HEAD:docs/compatibility-test-plan.md' -GitExecutable $fake -TimeoutMs 3000
        $sw.Stop()
        if ($null -eq $r) { throw 'drain timeout returned $null (would be reported as a SKIP)' }
        Assert-True (-not $r.OK) 'stdout drain timeout not reported as a failure'
        Assert-True ($sw.ElapsedMilliseconds -lt 9000) ('drain probe took too long: ' + $sw.ElapsedMilliseconds + ' ms')
    }

    Invoke-Test 'probe: a working git returns the text with a structured result' {
        $fake = Join-Path $workDir 'fakegit-ok.cmd'
        $body = '@echo off' + "`r`n" + 'echo HEADfake-content' + "`r`n" + 'exit /b 0' + "`r`n"
        [System.IO.File]::WriteAllText($fake, $body, [System.Text.Encoding]::ASCII)
        $r = Get-GitHeadText -RepoPath $repoRoot -GitSpec 'HEAD:docs/compatibility-test-plan.md' -GitExecutable $fake
        if ($null -eq $r) { throw 'successful git returned $null' }
        Assert-True $r.OK 'success not reported'
        Assert-True ($r.Text -match 'HEADfake-content') ('text missing: ' + $r.Text)
    }

    Invoke-Test 'probe: SKIP path only when git is not on PATH' {
        $saved = $env:PATH
        try {
            $env:PATH = 'C:\Windows\System32'
            $r = Get-GitHeadText -RepoPath $repoRoot -GitSpec 'HEAD:docs/compatibility-test-plan.md'
            if ($null -eq $r) { throw 'unavailable git returned $null instead of a structured result' }
            Assert-True (-not $r.GitAvailable) 'unavailable git not flagged as unavailable'
        } finally {
            $env:PATH = $saved
        }
    }

    Invoke-Test 'probe: first-table comparison covers separators and whitespace (ordinal)' {
        $base = (@('# Fixture', '', '## Matrix', '', $fixtureHeader, $fixtureSep,
                '| CMP-A | HDR | x | p | P-COMMON | c | e | not covered |  |  |', '', '## After') -join "`r`n")
        Assert-Equal '' (Compare-FirstTableBlocks $base $base) 'identical text flagged'
        $realign = $base.Replace($fixtureSep, '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
        Assert-True ((Compare-FirstTableBlocks $base $realign).Length -gt 0) 'separator realignment passed the comparison'
        $rowText = '| CMP-A | HDR | x | p | P-COMMON | c | e | not covered |  |  |'
        $trail = $base.Replace($rowText, $rowText + ' ')
        Assert-True ((Compare-FirstTableBlocks $base $trail).Length -gt 0) 'added trailing whitespace passed the comparison'
        $two = (@('# Fixture', '', '## Matrix', '', $fixtureHeader, $fixtureSep,
                '| CMP-A | HDR | x | p | P-COMMON | c | e | not covered |  |  |', '', '## Two', '',
                $fixtureHeader, $fixtureSep, '| ATV-A | HDR | x | p | P-ANDROID | c | e | not covered |  |  |', '', '## After') -join "`r`n")
        Assert-Equal '' (Compare-FirstTableBlocks $base $two) 'appending a second table flagged as a first-table change'
    }

    Invoke-Test 'evidence script rejects a path-like CaseId before touching the filesystem' {
        $fixturePlan = Join-Path $workDir 'escape-plan.md'
        $text = New-FixturePlanText @('| X\..\..\outside | HDR | s | p | P-COMMON | c | e | not covered |  |  |')
        [System.IO.File]::WriteAllText($fixturePlan, $text, (New-Object System.Text.UTF8Encoding($false)))
        $root = New-EvidenceRoot 'escape'
        Assert-ArgumentException { & $scriptPath -CaseId 'X\..\..\outside' -EvidenceRoot $root -PlanPath $fixturePlan } 'CaseId' 'path-like CaseId must be rejected'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $root -Force).Count 'something was created under EvidenceRoot'
        $escaped = @(Get-ChildItem -LiteralPath $workDir -Directory | Where-Object { $_.Name -like 'outside-*' })
        Assert-Equal 0 $escaped.Count 'evidence escaped EvidenceRoot via the path-like CaseId'
    }

    Invoke-Test 'P-ANDROID screenshot capture is binary-safe (cmd.exe redirection)' {
        Assert-True ($script:PlanText.Contains('cmd /c "adb exec-out screencap -p > overlay.png"')) 'plan does not use the binary-safe cmd /c capture form'
        Assert-True ($script:PlanText -match 're-encodes') 'plan does not explain why PowerShell redirection corrupts the PNG'
        $b2root = Join-Path $workDir 'b2probe'
        New-Item -ItemType Directory -Path $b2root | Out-Null
        $dir = [string](@(& $scriptPath -CaseId 'ATV-BASE-01' -EvidenceRoot $b2root)[0])
        $text = Read-Utf8 (Join-Path $dir 'record.md')
        Assert-True ($text.Contains('cmd /c')) 'ATV record capture hint is not binary-safe'
    }

    Invoke-Test 'CMP evidence output is byte-identical to the pre-change script' {
        if (-not (Test-GitHistoryPresent $repoRoot)) {
            Skip-Test 'no git history available (isolated source copy without .git)'
        }
        $head = Get-GitHeadText -RepoPath $repoRoot -GitSpec 'HEAD:client/New-CompatibilityEvidence.ps1'
        $headPlan = Get-GitHeadText -RepoPath $repoRoot -GitSpec 'HEAD:docs/compatibility-test-plan.md'
        if ((-not $head.GitAvailable) -or (-not $headPlan.GitAvailable)) {
            Skip-Test (($head.Reason, $headPlan.Reason) -join ' / ')
        }
        Assert-True ($head.OK -and $headPlan.OK) ('git show failed: ' + $head.Reason + ' / ' + $headPlan.Reason)
        # The pre-change script treats its own parent directory as the
        # repository and reads ..\docs\compatibility-test-plan.md by default,
        # so it is written to workDir\oldrepo\client\ together with the HEAD
        # plan to mirror the real layout and keep the %TEMP% evidence roots
        # outside it.
        $oldClientDir = Join-Path $workDir 'oldrepo\client'
        $oldDocsDir = Join-Path $workDir 'oldrepo\docs'
        New-Item -ItemType Directory -Path $oldClientDir -Force | Out-Null
        New-Item -ItemType Directory -Path $oldDocsDir -Force | Out-Null
        $oldScript = Join-Path $oldClientDir 'New-CompatibilityEvidence.ps1'
        [System.IO.File]::WriteAllText($oldScript, $head.Text, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $oldDocsDir 'compatibility-test-plan.md'), $headPlan.Text, (New-Object System.Text.UTF8Encoding($false)))
        $root = New-EvidenceRoot 'cmpbyte'
        # Both scripts run against the SAME evidence root: the record embeds
        # the full directory path, so the pre-change run's directory is
        # removed before the fixed-timestamp rerun recreates the same path.
        $oldOut = [string](@(& $oldScript -CaseId 'CMP-HDR-01' -EvidenceRoot $root)[0])
        $name = Split-Path -Leaf $oldOut
        $oldBytes = [System.IO.File]::ReadAllBytes((Join-Path $oldOut 'record.md'))
        Remove-Item -LiteralPath $oldOut -Recurse -Force
        $stamp = [datetime]::ParseExact($name.Substring('compat-CMP-HDR-01-'.Length), 'yyyyMMdd_HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        $newOut = [string](@(& $scriptPath -CaseId 'CMP-HDR-01' -EvidenceRoot $root -Now $stamp)[0])
        Assert-Equal $name (Split-Path -Leaf $newOut) 'directory name differs from the pre-change script'
        $newBytes = [System.IO.File]::ReadAllBytes((Join-Path $newOut 'record.md'))
        Assert-SameBytes $oldBytes $newBytes 'record.md bytes differ from the pre-change script'
    }
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $inRepoRoot -Directory -Filter 'compat-*' -ErrorAction SilentlyContinue |
        Where-Object { $preExistingInRepo -notcontains $_.Name } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Summary: {0} passed, {1} failed (skipped: {2})" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0) { exit 1 }
if ($script:Passed -eq 0 -and $script:Skipped -eq 0) { exit 1 }
exit 0
