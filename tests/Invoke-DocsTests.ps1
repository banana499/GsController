#requires -Version 5.1
<#
.SYNOPSIS
  Batch-D docs self-check for the operator docs added tonight (docs/*.md).

.DESCRIPTION
  Pure file parsing; the product script is never executed. Checks:

  - each new doc decodes as STRICT UTF-8 (UTF8Encoding($false, $true)) and
    has no BOM;
  - each new doc contains its required headings (full heading-line match;
    Chinese heading text is stored ASCII-escaped as \uXXXX and decoded at
    runtime so this file stays ASCII-only, per the signing/5.1 rule);
  - every relative markdown link target resolves against the docs folder,
    except targets on the in-test PENDING link list (files that only exist
    on other branches tonight);
  - every `-Action X` mentioned in the docs is in the ValidateSet of the
    $Action parameter of -ProductPath (parsed with the PowerShell AST), or
    is on the PENDING action list; names written as `-Action Start/Stop`
    are split on '/'; single- and double-quoted arguments are validated
    too, and the product script must parse with zero parser errors;
  - the stability matrix case IDs are unique and complete;
  - the stability matrix is parsed BY HEADER: every row must have the
    header cell count and the actual Status column cell must come from the
    allowed set {pass, fail, unsupported, not covered};
  - no device-identifier patterns in the new docs (MAC addresses in
    colon/dash/dotted form, ro.product/ro.build/ro.serialno properties,
    serial key=value, and COMPLETE IPv4 literals - every octet 0-255,
    never a fragment of a longer run - outside the allowlist
    {127.0.0.1, 0.0.0.0, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24});
  - no unescaped pipes inside inline code spans of table rows (they would
    split the rendered column);
  - rollback/uninstall keep the elevated PrepareUninstall-first order with
    the 0.2.0 fallback and task verification before msiexec /x;
  - threat-model.md covers the user-writable tray result directory
    (forged/stale results, link-following by the elevated writer).

  PENDING items print "PENDING <name> :: <why>" and never count as
  failures. An item that IS present in the target prints
  "RESOLVED <name> :: <why>" so the integration pass (E1) can empty the
  list. The final line is "Summary: X passed, Y failed"; the exit code is
  0 only when nothing failed and at least one check ran.

.PARAMETER ProductPath
  gs-product.ps1 whose -Action ValidateSet the docs are checked against.
  Default: product\gs-product.ps1 next to the tests folder.

.PARAMETER RepoRoot
  Repository root used to resolve PENDING file names (product/...,
  tools/...). Default: the parent of ProductPath's folder.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-DocsTests.ps1

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-DocsTests.ps1 -ProductPath C:\path\to\night-integration\product\gs-product.ps1
#>
[CmdletBinding()]
param(
    [string]$ProductPath = '',
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Path resolution. Done in the body, not in param defaults: PS 5.1 leaves
# $PSScriptRoot empty in param-block defaults under powershell.exe -File.
# ---------------------------------------------------------------------------
$testRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($testRoot)) { $testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ProductPath)) {
    $ProductPath = Join-Path (Join-Path (Split-Path -Parent $testRoot) 'product') 'gs-product.ps1'
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $ProductPath)
}
$docsDir = Join-Path (Split-Path -Parent $testRoot) 'docs'

# ---------------------------------------------------------------------------
# Helpers. ASCII-only source: Chinese literals arrive as \uXXXX escapes.
# ---------------------------------------------------------------------------
function ConvertFrom-EscapedUnicode([string]$Value) {
    $rx = [regex]'\\u([0-9A-Fa-f]{4})'
    $builder = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in $rx.Matches($Value)) {
        [void]$builder.Append($Value.Substring($pos, $m.Index - $pos))
        [void]$builder.Append([char][Convert]::ToInt32($m.Groups[1].Value, 16))
        $pos = $m.Index + $m.Length
    }
    [void]$builder.Append($Value.Substring($pos))
    return $builder.ToString()
}

function ConvertTo-EscapedUnicode([string]$Value) {
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        if ([int]$ch -gt 126) { [void]$builder.Append(('\u{0:X4}' -f [int]$ch)) } else { [void]$builder.Append($ch) }
    }
    return $builder.ToString()
}

$script:Passed = 0
$script:Failed = 0
function Assert-Test([string]$Name, [bool]$Condition, [string]$Detail) {
    if ($Condition) {
        $script:Passed++
        Write-Output ('PASS {0}' -f $Name)
    } else {
        $script:Failed++
        Write-Output ('FAIL {0} :: {1}' -f $Name, $Detail)
    }
}

# ---------------------------------------------------------------------------
# PENDING lists. Emptied at integration (E1, 2026-11-01): every action, file
# and link the docs reference now exists. New entries need a reason.
# ---------------------------------------------------------------------------
$pendingActions = @()
$pendingFiles = @()
$pendingLinks = @()
$pendingActionNames = @($pendingActions | ForEach-Object { $_.Name })
$pendingLinkNames = @($pendingLinks | ForEach-Object { $_.Name })

# ---------------------------------------------------------------------------
# Load the docs (strict UTF-8, tracked for the encoding test).
# ---------------------------------------------------------------------------
$docNames = @('operator-guide.md', 'file-locations.md', 'troubleshooting.md', 'threat-model.md', 'stability-test-plan.md')
$docText = @{}
$docLines = @{}
foreach ($name in $docNames) {
    $path = Join-Path $docsDir $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $text = $null
        try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { $text = $null }
        $docText[$name] = $text
        if ($null -ne $text) { $docLines[$name] = @($text -split "`n" | ForEach-Object { $_.TrimEnd("`r") }) }
    } else {
        $docText[$name] = $null
    }
}

# ---------------------------------------------------------------------------
# 1) Encoding: strict UTF-8, no BOM (per doc).
# ---------------------------------------------------------------------------
foreach ($name in $docNames) {
    $path = Join-Path $docsDir $name
    $detail = 'file not found under the docs folder'
    $ok = $false
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if ($hasBom) {
            $detail = 'file starts with a UTF-8 BOM'
        } else {
            try {
                $null = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
                $ok = $true
            } catch {
                $detail = 'does not decode as strict UTF-8: ' + $_.Exception.Message
            }
        }
    }
    Assert-Test ('encoding strict UTF-8 without BOM: ' + $name) $ok $detail
}

# ---------------------------------------------------------------------------
# 2) Required headings (per doc). Escapes decode to the exact heading lines.
# ---------------------------------------------------------------------------
$requiredHeadings = @{
    'operator-guide.md' = @(
        '# GsController \u8FD0\u7EF4\u624B\u518C',
        '## \u7CFB\u7EDF\u8981\u6C42',
        '## \u5B89\u88C5\uFF08MSI\uFF09',
        '## \u90E8\u7F72\u7EC4\u4EF6\uFF08Install / Check\uFF09',
        '## \u542F\u52A8\u3001\u505C\u6B62\u4E0E\u72B6\u6001',
        '## \u6258\u76D8',
        '## \u5F00\u673A\u81EA\u542F\u4E0E\u6682\u505C\u6807\u5FD7',
        '## \u8BCA\u65AD\u4E0E\u652F\u6301\u5305',
        '## \u6062\u590D\u5361\u4F4F\u7684\u4F1A\u8BDD\uFF08Recover\uFF09',
        '## \u5347\u7EA7',
        '## \u56DE\u9000',
        '## \u5378\u8F7D',
        '## \u5BA2\u6237\u7AEF\u8FDE\u63A5',
        '## \u5DF2\u77E5\u9650\u5236'
    )
    'file-locations.md' = @(
        '# \u6587\u4EF6\u4E0E\u65E5\u5FD7\u4F4D\u7F6E',
        '## \u5B89\u88C5\u76EE\u5F55',
        '## StateDir\uFF08\u72B6\u6001\u76EE\u5F55\uFF09',
        '## \u65E5\u5FD7',
        '## \u6258\u76D8\u65E5\u5FD7\u4E0E\u7ED3\u679C\u6587\u4EF6',
        '## \u652F\u6301\u5305\u8F93\u51FA',
        '## \u8BC1\u636E\u76EE\u5F55',
        '## Moonlight \u5BA2\u6237\u7AEF\u65E5\u5FD7'
    )
    'troubleshooting.md' = @(
        '# \u6545\u969C\u6392\u67E5',
        '## \u6392\u67E5\u8868'
    )
    'threat-model.md' = @(
        '# \u5A01\u80C1\u6A21\u578B',
        '## \u8303\u56F4\u4E0E\u5047\u8BBE',
        '## \u8D44\u4EA7',
        '## \u4FE1\u4EFB\u8FB9\u754C',
        '## \u5A01\u80C1\u3001\u73B0\u6709\u7F13\u89E3\u4E0E\u7F3A\u53E3',
        '## \u4E0D\u5728\u8303\u56F4\u5185'
    )
    'stability-test-plan.md' = @(
        '# \u7A33\u5B9A\u6027\u6D4B\u8BD5\u8BA1\u5212\uFF1A\u957F\u65F6\u95F4\u8FD0\u884C\u4E0E\u91CD\u8FDE',
        '## \u8303\u56F4',
        '## \u57FA\u7EBF\u5BA2\u6237\u7AEF',
        '## \u72B6\u6001',
        '## \u7528\u4F8B\u77E9\u9635',
        '## \u6B65\u9AA4\uFF1AP-STB-COMMON',
        '## \u901A\u8FC7\u6807\u51C6\uFF08\u901A\u7528\uFF09',
        '## \u8BC1\u636E\u76EE\u5F55'
    )
}
foreach ($name in $docNames) {
    $missing = @()
    $lines = $docLines[$name]
    if ($null -eq $lines) {
        $missing += '<doc missing or not valid UTF-8>'
    } else {
        foreach ($escaped in $requiredHeadings[$name]) {
            $heading = ConvertFrom-EscapedUnicode $escaped
            $found = $false
            foreach ($line in $lines) {
                if ($line.Trim() -eq $heading) { $found = $true; break }
            }
            if (-not $found) { $missing += (ConvertTo-EscapedUnicode $heading) }
        }
    }
    $detail = ''
    if ($missing.Count -gt 0) { $detail = 'missing headings: ' + ($missing -join ', ') }
    Assert-Test ('required headings present: ' + $name) ($missing.Count -eq 0) $detail
}

# ---------------------------------------------------------------------------
# 3) Product ValidateSet via the PowerShell AST (never executed). Factored
#    into a helper so probe tests can exercise the same code path with
#    fixture scripts under %TEMP%.
# ---------------------------------------------------------------------------
function Get-ProductActionInfo([string]$Path) {
    $info = @{ Found = $false; ParseErrorCount = 0; ActionValues = @(); Detail = '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $info.Detail = '-ProductPath not found: ' + $Path
        return $info
    }
    $tokens = $null
    $parseErrors = $null
    $ast = $null
    try { $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) }
    catch { $ast = $null; $info.Detail = 'parser threw: ' + $_.Exception.Message }
    $info.ParseErrorCount = @($parseErrors).Count
    if ($null -ne $ast) {
        $values = @()
        if ($null -ne $ast.ParamBlock) {
            foreach ($paramAst in $ast.ParamBlock.Parameters) {
                if ($paramAst.Name.VariablePath.UserPath -ne 'Action') { continue }
                foreach ($attr in $paramAst.Attributes) {
                    $typeName = $attr.TypeName.Name
                    if ($typeName -eq 'ValidateSet' -or $typeName -like '*.ValidateSet') {
                        foreach ($positional in $attr.PositionalArguments) {
                            if ($positional -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                $values += $positional.Value
                            }
                        }
                    }
                }
            }
        }
        $info.ActionValues = @($values)
        if ($values.Count -gt 0) { $info.Found = $true }
        else { $info.Detail = 'no ValidateSet values found for the $Action parameter in ' + $Path }
    }
    return $info
}

$productInfo = Get-ProductActionInfo $ProductPath
$actionValues = $productInfo.ActionValues
$productDetail = $productInfo.Detail
if ($productInfo.ParseErrorCount -gt 0) {
    $productDetail = ('parser errors: ' + $productInfo.ParseErrorCount + ' in ' + $ProductPath)
}
Assert-Test 'product: -ProductPath parses with zero parser errors and the $Action ValidateSet is extracted' ($productInfo.Found -and $productInfo.ParseErrorCount -eq 0) $productDetail

# ---------------------------------------------------------------------------
# 4) Every -Action X mentioned in the docs is in the ValidateSet (or pending).
#    Factored so probe tests can exercise the same scan.
# ---------------------------------------------------------------------------
function Get-BadActionMentions([string]$Text, [string[]]$ValidActions, [string[]]$PendingActions) {
    $bad = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Text) { return @($bad) }
    # Unquoted and quoted (single or double) -Action arguments are both
    # captured; every captured name is validated.
    $actionRx = [regex]'-\s*Action\s+(?:''([^'']+)''|"([^"]+)"|([A-Za-z][A-Za-z0-9/]*))'
    foreach ($m in $actionRx.Matches($Text)) {
        $raw = $m.Groups[1].Value
        if ($m.Groups[2].Success) { $raw = $m.Groups[2].Value }
        elseif ($m.Groups[3].Success) { $raw = $m.Groups[3].Value }
        foreach ($part in ($raw -split '/')) {
            $action = $part.Trim()
            if ([string]::IsNullOrEmpty($action)) { continue }
            if ($null -eq $ValidActions -or -not ($ValidActions -contains $action)) {
                if ($PendingActions -notcontains $action) {
                    $bad.Add(('-Action ' + $action))
                }
            }
        }
    }
    return @($bad)
}
$badActions = New-Object System.Collections.Generic.List[string]
foreach ($name in $docNames) {
    $text = $docText[$name]
    if ($null -eq $text) { continue }
    foreach ($bad in (Get-BadActionMentions $text $actionValues $pendingActionNames)) {
        $badActions.Add(($name + ' -> ' + $bad))
    }
}
Assert-Test 'every -Action X in the docs is in the ValidateSet (or on the pending action list)' ($badActions.Count -eq 0) ('not in ValidateSet and not pending: ' + ($badActions -join '; '))

# PENDING / RESOLVED report for actions.
foreach ($item in $pendingActions) {
    $present = (($null -ne $actionValues) -and ($actionValues -contains $item.Name))
    if ($present) { Write-Output ('RESOLVED {0} :: {1}' -f $item.Name, $item.Why) }
    else { Write-Output ('PENDING {0} :: {1}' -f $item.Name, $item.Why) }
}

# PENDING / RESOLVED report for files (resolved against -RepoRoot).
foreach ($item in $pendingFiles) {
    $target = Join-Path $RepoRoot ($item.Name -replace '/', '\')
    if (Test-Path -LiteralPath $target) { Write-Output ('RESOLVED {0} :: {1}' -f $item.Name, $item.Why) }
    else { Write-Output ('PENDING {0} :: {1}' -f $item.Name, $item.Why) }
}

# ---------------------------------------------------------------------------
# 4b) Probe tests for the product/action validation (fixtures under %TEMP%,
#     removed afterwards). Round-4 regressions: a product script with parse
#     errors must not pass, and quoted -Action arguments must be validated.
# ---------------------------------------------------------------------------
$probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ('GsDocsProbe_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeDir | Out-Null
try {
    $brokenScript = Join-Path $probeDir 'broken-product.ps1'
    $brokenBody = 'param([ValidateSet("Start")][string]$Action)' + "`r`n" + 'function Broken {' + "`r`n"
    [System.IO.File]::WriteAllText($brokenScript, $brokenBody, (New-Object System.Text.UTF8Encoding($false)))
    $brokenInfo = Get-ProductActionInfo $brokenScript
    Assert-Test 'probe: a product script with parse errors reports them (zero parse errors required)' ($brokenInfo.ParseErrorCount -gt 0) ('ParseErrorCount was ' + $brokenInfo.ParseErrorCount)

    $cleanScript = Join-Path $probeDir 'clean-product.ps1'
    $cleanBody = 'param([ValidateSet("Start", "Stop")][string]$Action)' + "`r`n"
    [System.IO.File]::WriteAllText($cleanScript, $cleanBody, (New-Object System.Text.UTF8Encoding($false)))
    $cleanInfo = Get-ProductActionInfo $cleanScript
    Assert-Test 'probe: a clean product fixture yields ValidateSet values with zero parse errors' ($cleanInfo.Found -and $cleanInfo.ParseErrorCount -eq 0) ('Found=' + $cleanInfo.Found + ' ParseErrorCount=' + $cleanInfo.ParseErrorCount)

    $validActions = @('Start', 'Stop')
    $scanText = 'run `-Action ''Bogus''` then `-Action "Bogus2"` or plain `-Action Start/Stop`'
    $scanBad = Get-BadActionMentions $scanText $validActions @()
    Assert-Test 'probe: quoted -Action arguments are validated' (($scanBad -contains '-Action Bogus') -and ($scanBad -contains '-Action Bogus2')) ('bad list: ' + ($scanBad -join '; '))
    $scanOk = Get-BadActionMentions 'plain `-Action Stop` command' $validActions @()
    Assert-Test 'probe: a valid unquoted -Action passes the scan' ($scanOk.Count -eq 0) ('unexpected bad list: ' + ($scanOk -join '; '))
} finally {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 5) Relative markdown links resolve (or are on the pending link list).
# ---------------------------------------------------------------------------
$linkRx = [regex]'\[[^\]\r\n]*\]\(([^)\r\n]+)\)'
$badLinks = New-Object System.Collections.Generic.List[string]
foreach ($name in $docNames) {
    $text = $docText[$name]
    if ($null -eq $text) { continue }
    foreach ($m in $linkRx.Matches($text)) {
        $raw = $m.Groups[1].Value.Trim()
        if ($raw.StartsWith('http://') -or $raw.StartsWith('https://') -or $raw.StartsWith('mailto:') -or $raw.StartsWith('#')) { continue }
        $filePart = ($raw -split '#')[0].Trim()
        if ([string]::IsNullOrEmpty($filePart)) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $docsDir $filePart))) {
            if ($pendingLinkNames -notcontains $filePart) {
                $badLinks.Add(($name + ' -> ' + $filePart))
            }
        }
    }
}
Assert-Test 'relative markdown links resolve (or are on the pending link list)' ($badLinks.Count -eq 0) ('unresolved, not pending: ' + ($badLinks -join '; '))

# PENDING / RESOLVED report for link targets (resolved against the docs folder).
foreach ($item in $pendingLinks) {
    if (Test-Path -LiteralPath (Join-Path $docsDir $item.Name)) { Write-Output ('RESOLVED {0} :: {1}' -f $item.Name, $item.Why) }
    else { Write-Output ('PENDING {0} :: {1}' -f $item.Name, $item.Why) }
}

# ---------------------------------------------------------------------------
# 6) Stability matrix. Parsed BY HEADER: the Status column is located by its
#    header cell, row cell counts are checked, and the actual Status cell is
#    validated. Factored so probe tests exercise the same validation.
# ---------------------------------------------------------------------------
function Split-MatrixRow([string]$Line) {
    $t = $Line.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|')) { $t = $t.Substring(0, $t.Length - 1) }
    return , @($t.Split('|') | ForEach-Object { $_.Trim() })
}

function Get-StabilityMatrixViolations([string[]]$DocLines) {
    $allowedStatuses = @('pass', 'fail', 'unsupported', 'not covered')
    $statusHeader = ConvertFrom-EscapedUnicode '\u72B6\u6001'  # Status
    $idHeader = 'ID'
    $bad = New-Object System.Collections.Generic.List[string]
    if ($null -eq $DocLines) { return @($bad) }
    $headerCells = $null
    $statusIdx = -1
    $idIdx = -1
    $inMatrix = $false
    for ($i = 0; $i -lt $DocLines.Count; $i++) {
        $line = $DocLines[$i]
        if (-not $inMatrix) {
            if ($line -match '^\s*\|\s*ID\s*\|') {
                $inMatrix = $true
                $headerCells = Split-MatrixRow $line
                for ($c = 0; $c -lt $headerCells.Count; $c++) {
                    if ($headerCells[$c] -eq $idHeader) { $idIdx = $c }
                    if ($headerCells[$c] -eq $statusHeader) { $statusIdx = $c }
                }
                if ($statusIdx -lt 0) { $bad.Add(('status column "' + $statusHeader + '" not found in the matrix header')) }
                if ($idIdx -lt 0) { $bad.Add('ID column not found in the matrix header') }
            }
            continue
        }
        if ($line -notmatch '^\s*\|') { break }
        if ($line -match '^\s*\|[\s:\-\|]+\|\s*$') { continue }
        $cells = Split-MatrixRow $line
        $caseId = ''
        if ($idIdx -ge 0 -and $idIdx -lt $cells.Count) { $caseId = $cells[$idIdx] }
        if ($cells.Count -ne $headerCells.Count) {
            $bad.Add(('cells ' + $caseId + ': row has ' + $cells.Count + ' cells, header has ' + $headerCells.Count))
            continue
        }
        if ($statusIdx -ge 0) {
            $statusCell = $cells[$statusIdx]
            if ($allowedStatuses -notcontains $statusCell) {
                $bad.Add(('status ' + $caseId + ': Status column cell is "' + $statusCell + '"'))
            }
        }
    }
    return @($bad)
}

$stabilityDocLines = $docLines['stability-test-plan.md']
$matrixViolations = Get-StabilityMatrixViolations $stabilityDocLines
$matrixIds = @()
foreach ($line in $stabilityDocLines) {
    if ($line -match '^\|\s*(STB-[A-Za-z0-9-]+)\s*\|') { $matrixIds += $Matches[1] }
}
$expectedCaseIds = @('STB-S1-MAC', 'STB-S1-TV', 'STB-S2-MAC', 'STB-S2-TV', 'STB-S3-MAC', 'STB-S3-TV', 'STB-S4-MAC', 'STB-S4-TV', 'STB-S5-MAC', 'STB-S5-TV', 'STB-S6-MAC', 'STB-S6-TV')
$duplicateIds = @($matrixIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$absentIds = @($expectedCaseIds | Where-Object { $matrixIds -notcontains $_ })
$matrixIdDetail = ''
if ($duplicateIds.Count -gt 0) { $matrixIdDetail = 'duplicate IDs: ' + ($duplicateIds -join ', ') }
if ($absentIds.Count -gt 0) {
    if ($matrixIdDetail.Length -gt 0) { $matrixIdDetail += '; ' }
    $matrixIdDetail += 'expected IDs not found: ' + ($absentIds -join ', ')
}
Assert-Test 'stability matrix: case IDs unique and complete' (($duplicateIds.Count -eq 0) -and ($absentIds.Count -eq 0)) $matrixIdDetail

# ---------------------------------------------------------------------------
# 7) Stability matrix: the Status column cell is from the allowed set
#    (header-parsed) and every row has the header cell count.
# ---------------------------------------------------------------------------
$statusViolations = @($matrixViolations | Where-Object { $_ -like 'status *' })
$cellViolations = @($matrixViolations | Where-Object { $_ -like 'cells *' })
$otherViolations = @($matrixViolations | Where-Object { $_ -notlike 'status *' -and $_ -notlike 'cells *' })
$allDetail = ''
if ($statusViolations.Count -gt 0) { $allDetail = 'rows: ' + ($statusViolations -join '; ') }
elseif ($otherViolations.Count -gt 0) { $allDetail = ($otherViolations -join '; ') }
Assert-Test 'stability matrix: the Status column cell is from the allowed set (parsed by header)' (($statusViolations.Count -eq 0) -and ($otherViolations.Count -eq 0)) $allDetail
Assert-Test 'stability matrix: every row has the header cell count' ($cellViolations.Count -eq 0) ('rows: ' + ($cellViolations -join '; '))

# Probe: the validation must parse the header and validate the actual Status
# column cell, not count allowed words anywhere in the row.
$stbStatus = ConvertFrom-EscapedUnicode '\u72B6\u6001'  # Status column header
$stbReason = ConvertFrom-EscapedUnicode '\u539F\u56E0'  # Reason column header
$probeMatrix = @(
    ('| ID | ' + $stbStatus + ' | ' + $stbReason + ' |'),
    '|---|---|---|',
    '| STB-P1 | not covered |  |',
    '| STB-P2 | banana | fail |',
    '| STB-P3 | pass |'
)
$probeViolations = Get-StabilityMatrixViolations $probeMatrix
$p2 = @($probeViolations | Where-Object { $_ -like '*STB-P2*' })
$p3 = @($probeViolations | Where-Object { $_ -like '*STB-P3*' })
$p1 = @($probeViolations | Where-Object { $_ -like '*STB-P1*' })
Assert-Test 'probe: stability Status column cell is validated (not word count)' ($p2.Count -eq 1) ('STB-P2 violations: ' + ($p2 -join '; ') + ' / all: ' + ($probeViolations -join '; '))
Assert-Test 'probe: stability rows with a wrong cell count are flagged' ($p3.Count -eq 1) ('STB-P3 violations: ' + ($p3 -join '; '))
Assert-Test 'probe: a clean stability row is not flagged' ($p1.Count -eq 0) ('STB-P1 violations: ' + ($p1 -join '; '))

# ---------------------------------------------------------------------------
# 8) No device identifiers in the new docs. Factored so the probe test
#    exercises the same scan.
# ---------------------------------------------------------------------------
function Test-AllowedIdentifierIp([string]$Ip) {
    # The only permitted literal IPv4 addresses in the new docs: loopback,
    # the unspecified address, and the three documentation ranges.
    if ($Ip -ceq '127.0.0.1' -or $Ip -ceq '0.0.0.0') { return $true }
    foreach ($prefix in @('192.0.2.', '198.51.100.', '203.0.113.')) {
        if ($Ip.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-IdentifierHits([string]$Text) {
    # Complete IPv4 addresses only: every octet must be 0-255 and the match
    # must not be a fragment of a longer dotted or digit run.
    $ipv4Rx = [regex]'(?<![\d.])((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\d.])'
    $patterns = @(
        @{ Name = 'mac-colon';       Rx = [regex]'([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' },
        @{ Name = 'mac-dash';        Rx = [regex]'([0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}' },
        @{ Name = 'mac-dotted';      Rx = [regex]'([0-9A-Fa-f]{4}\.){2}[0-9A-Fa-f]{4}' },
        @{ Name = 'android-prop';    Rx = [regex]'ro\.(product|build|serialno)' },
        @{ Name = 'serial-keyvalue'; Rx = [regex]'(?i)\bserial\s*[=:]' }
    )
    $hits = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Text) { return @($hits) }
    foreach ($pattern in $patterns) {
        foreach ($m in $pattern.Rx.Matches($Text)) {
            $hits.Add(($pattern.Name + ': ' + $m.Value))
        }
    }
    foreach ($m in $ipv4Rx.Matches($Text)) {
        if (-not (Test-AllowedIdentifierIp $m.Value)) {
            $hits.Add(('non-allowlisted IPv4: ' + $m.Value))
        }
    }
    return @($hits)
}
$identifierHits = New-Object System.Collections.Generic.List[string]
foreach ($name in $docNames) {
    $text = $docText[$name]
    if ($null -eq $text) { continue }
    foreach ($hit in (Get-IdentifierHits $text)) {
        $identifierHits.Add(($name + ' [' + $hit + ']'))
    }
}
Assert-Test 'no device identifiers (MAC/serial/ro.*/LAN IP) in the new docs' ($identifierHits.Count -eq 0) ('hits: ' + ($identifierHits -join '; '))

# Probe: the scan must match complete IPv4 addresses (not just three-octet
# prefixes) and enforce the documented address allowlist.
$probeHitsA = @(Get-IdentifierHits 'client 192.168.1.23 gateway 10.1.2.3 wifi 172.16.4.5 overflow 192.168.1.230 mac AA:BB:CC:DD:EE:FF')
$needA = @('192.168.1.23', '10.1.2.3', '172.16.4.5', '192.168.1.230', 'AA:BB:CC:DD:EE:FF')
$missingA = @()
foreach ($need in $needA) {
    $found = $false
    foreach ($h in $probeHitsA) { if ($h.Contains($need)) { $found = $true; break } }
    if (-not $found) { $missingA += $need }
}
Assert-Test 'probe: identifier scan catches complete IPv4 addresses' ($missingA.Count -eq 0) ('not caught: ' + ($missingA -join ', '))
$probeHitsB = @(Get-IdentifierHits 'loopback 127.0.0.1 any 0.0.0.0 doc-range 192.0.2.55 198.51.100.7 203.0.113.9')
Assert-Test 'probe: allowlisted addresses are not flagged' ($probeHitsB.Count -eq 0) ('unexpected hits: ' + ($probeHitsB -join '; '))
$probeHitsC = @(Get-IdentifierHits 'public dns 8.8.8.8')
$cHit = $false
foreach ($h in $probeHitsC) { if ($h.Contains('8.8.8.8')) { $cHit = $true; break } }
Assert-Test 'probe: non-allowlisted IPv4 addresses are flagged' $cHit ('hits: ' + ($probeHitsC -join '; '))

# ---------------------------------------------------------------------------
# 9) Rollback / uninstall order (D-B1): elevated PrepareUninstall (or the
#    0.2.0 fallback) plus task verification must come before msiexec /x.
# ---------------------------------------------------------------------------
function Get-DocSection([string[]]$Lines, [string]$StartHeading, [string]$StopHeading) {
    $out = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Lines) { return @($out) }
    $inSection = $false
    foreach ($line in $Lines) {
        if (-not $inSection) {
            if ($line.Trim() -eq $StartHeading) { $inSection = $true; $out.Add($line) }
        } else {
            if ($line.Trim() -eq $StopHeading) { break }
            $out.Add($line)
        }
    }
    return @($out)
}

function Find-LineIndex([string[]]$Lines, [scriptblock]$Predicate) {
    if ($null -eq $Lines) { return -1 }
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (& $Predicate $Lines[$i]) { return $i }
    }
    return -1
}

function Get-FirstFencedLineIndex([string[]]$Lines, [string]$Needle) {
    # Index of the first line inside a ``` fence that contains $Needle.
    if ($null -eq $Lines) { return -1 }
    $inFence = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].TrimStart().StartsWith('```')) { $inFence = -not $inFence; continue }
        if ($inFence -and $Lines[$i].IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0) { return $i }
    }
    return -1
}

$rollbackHeading = '## ' + (ConvertFrom-EscapedUnicode '\u56DE\u9000')                # Rollback
$uninstallHeading = '## ' + (ConvertFrom-EscapedUnicode '\u5378\u8F7D')               # Uninstall
$clientHeading = '## ' + (ConvertFrom-EscapedUnicode '\u5BA2\u6237\u7AEF\u8FDE\u63A5') # Client connection
$adminLabel = ConvertFrom-EscapedUnicode '\u7BA1\u7406\u5458'                          # administrator
$pendingMarker = ConvertFrom-EscapedUnicode '\u5F85\u96C6\u6210'                       # awaiting integration
$stepOneLabel = ConvertFrom-EscapedUnicode '\u7B2C 1 \u6B65'                           # step 1

$rbLines = Get-DocSection $docLines['operator-guide.md'] $rollbackHeading $uninstallHeading
$unLines = Get-DocSection $docLines['operator-guide.md'] $uninstallHeading $clientHeading

$rbPrepIdx = Find-LineIndex $rbLines { param($l) $l.Contains('PrepareUninstall') }
$rbVerifyIdx = Find-LineIndex $rbLines { param($l) $l.Contains('Get-ScheduledTask') }
$rbMsiXIdx = Get-FirstFencedLineIndex $rbLines 'msiexec /x'
$rbAdminPrep = $false
for ($i = 0; $i -lt $rbLines.Count; $i++) {
    if ($rbLines[$i].Contains('PrepareUninstall') -and $rbLines[$i].Contains($adminLabel)) { $rbAdminPrep = $true; break }
}
$rbOk = ($rbPrepIdx -ge 0) -and ($rbVerifyIdx -ge 0) -and ($rbMsiXIdx -ge 0) -and
    ($rbPrepIdx -lt $rbVerifyIdx) -and ($rbVerifyIdx -lt $rbMsiXIdx) -and
    ($rbAdminPrep) -and
    ((Find-LineIndex $rbLines { param($l) $l.Contains('UnregisterAutostart') }) -ge 0) -and
    ((Find-LineIndex $rbLines { param($l) $l.Contains('-Action Stop') }) -ge 0)
$rbDetailParts = @()
if ($rbPrepIdx -lt 0) { $rbDetailParts += 'no PrepareUninstall step' }
if ($rbVerifyIdx -lt 0) { $rbDetailParts += 'no task-verification step (Get-ScheduledTask)' }
if ($rbMsiXIdx -lt 0) { $rbDetailParts += 'no fenced msiexec /x step' }
if ($rbPrepIdx -ge 0 -and $rbVerifyIdx -ge 0 -and $rbPrepIdx -gt $rbVerifyIdx) { $rbDetailParts += 'verification before cleanup' }
if ($rbPrepIdx -ge 0 -and $rbMsiXIdx -ge 0 -and $rbVerifyIdx -ge 0 -and $rbVerifyIdx -gt $rbMsiXIdx) { $rbDetailParts += 'verification after msiexec /x' }
if (-not $rbAdminPrep) { $rbDetailParts += 'cleanup step not labeled elevated' }
if ((Find-LineIndex $rbLines { param($l) $l.Contains('UnregisterAutostart') }) -lt 0) { $rbDetailParts += 'no UnregisterAutostart fallback' }
if ((Find-LineIndex $rbLines { param($l) $l.Contains('-Action Stop') }) -lt 0) { $rbDetailParts += 'fallback missing Stop' }
Assert-Test 'rollback: elevated PrepareUninstall first (with 0.2.0 fallback), task verified before msiexec /x' $rbOk ('rollback issues: ' + ($rbDetailParts -join '; '))

$unPrepIdx = Find-LineIndex $unLines { param($l) $l.Contains('PrepareUninstall') }
$unVerifyIdx = Find-LineIndex $unLines { param($l) $l.Contains('Get-ScheduledTask') }
$unMsiXIdx = Get-FirstFencedLineIndex $unLines 'msiexec /x'
$unStepOneAdmin = $false
for ($i = 0; $i -lt $unLines.Count; $i++) {
    if ($unLines[$i].Contains($stepOneLabel) -and $unLines[$i].Contains($adminLabel)) { $unStepOneAdmin = $true; break }
}
$unOk = ($unPrepIdx -ge 0) -and ($unVerifyIdx -ge 0) -and ($unMsiXIdx -ge 0) -and
    ($unPrepIdx -lt $unVerifyIdx) -and ($unVerifyIdx -lt $unMsiXIdx) -and
    ($unStepOneAdmin) -and
    ((Find-LineIndex $unLines { param($l) $l.Contains('UnregisterAutostart') }) -ge 0) -and
    ((Find-LineIndex $unLines { param($l) $l.Contains($pendingMarker) }) -lt 0)
$unDetailParts = @()
if ($unPrepIdx -lt 0) { $unDetailParts += 'no PrepareUninstall step' }
if ($unVerifyIdx -lt 0) { $unDetailParts += 'no task-verification step before msiexec /x' }
if ($unMsiXIdx -lt 0) { $unDetailParts += 'no fenced msiexec /x step' }
if ($unPrepIdx -ge 0 -and $unVerifyIdx -ge 0 -and $unVerifyIdx -lt $unPrepIdx) { $unDetailParts += 'verification before cleanup' }
if ($unPrepIdx -ge 0 -and $unMsiXIdx -ge 0 -and $unVerifyIdx -ge 0 -and $unVerifyIdx -gt $unMsiXIdx) { $unDetailParts += 'verification after msiexec /x' }
if (-not $unStepOneAdmin) { $unDetailParts += 'step 1 not labeled elevated' }
if ((Find-LineIndex $unLines { param($l) $l.Contains('UnregisterAutostart') }) -lt 0) { $unDetailParts += 'no UnregisterAutostart fallback' }
if ((Find-LineIndex $unLines { param($l) $l.Contains($pendingMarker) }) -ge 0) { $unDetailParts += 'stale pending-integration marker (PrepareUninstall is integrated)' }
Assert-Test 'uninstall: elevated PrepareUninstall step, task verified before msiexec /x, fallback documented' $unOk ('uninstall issues: ' + ($unDetailParts -join '; '))

# ---------------------------------------------------------------------------
# 10) Table cells (D-N2): no unescaped pipes inside inline code spans of a
#     table row; they would split the rendered column.
# ---------------------------------------------------------------------------
function Get-CodeSpanPipeViolations([string[]]$Lines) {
    $bad = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Lines) { return @($bad) }
    for ($ln = 0; $ln -lt $Lines.Count; $ln++) {
        $line = $Lines[$ln]
        if ($line -notmatch '^\s*\|') { continue }
        $inCode = $false
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if ($ch -eq '`') { $inCode = -not $inCode; continue }
            if ($inCode -and $ch -eq '|' -and ($i -eq 0 -or ([string]$line[$i - 1]) -ne '\')) {
                $bad.Add(('line ' + ($ln + 1) + ': unescaped pipe inside a code span'))
            }
        }
    }
    return @($bad)
}
$pipeViolations = New-Object System.Collections.Generic.List[string]
foreach ($name in $docNames) {
    $lines = $docLines[$name]
    if ($null -eq $lines) { continue }
    foreach ($v in (Get-CodeSpanPipeViolations $lines)) { $pipeViolations.Add(($name + ' ' + $v)) }
}
Assert-Test 'table cells: no unescaped pipes inside code spans' ($pipeViolations.Count -eq 0) ('violations: ' + ($pipeViolations -join '; '))

# ---------------------------------------------------------------------------
# 11) Threat model (D-N3): the user-writable tray result directory must be
#     covered as a boundary (forged/stale results, link-following).
# ---------------------------------------------------------------------------
$tmText = $docText['threat-model.md']
$tmNeed = @(
    @{ Needle = '%LOCALAPPDATA%\GsController\tray\results';                     Label = 'results directory path' },
    @{ Needle = (ConvertFrom-EscapedUnicode '\u4F2A\u9020');                     Label = 'forged results' },
    @{ Needle = (ConvertFrom-EscapedUnicode '\u9648\u65E7');                     Label = 'stale results' },
    @{ Needle = (ConvertFrom-EscapedUnicode '\u94FE\u63A5');                     Label = 'link-following' }
)
$tmMissing = @()
foreach ($item in $tmNeed) {
    if ($null -eq $tmText -or -not $tmText.Contains($item.Needle)) { $tmMissing += $item.Label }
}
Assert-Test 'threat model: tray result directory boundary is a known gap' ($tmMissing.Count -eq 0) ('missing: ' + ($tmMissing -join ', '))

# ---------------------------------------------------------------------------
# Summary and exit code.
# ---------------------------------------------------------------------------
Write-Output ('Summary: {0} passed, {1} failed' -f $script:Passed, $script:Failed)
if ($script:Failed -eq 0 -and $script:Passed -ge 1) { exit 0 }
exit 1
