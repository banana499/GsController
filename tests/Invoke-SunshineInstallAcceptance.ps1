#Requires -Version 5.1
<#
.SYNOPSIS
    Isolated real-install acceptance harness for the GsController
    Sunshine-profile MSI (0.3.0 -> 0.3.1).

.DESCRIPTION
    Default mode is PLAN ONLY: it prints the static acceptance plan and,
    when MSI paths are supplied, runs the READ-ONLY MSI database precheck.
    It never touches the system unless -Execute is requested AND every
    runner gate passes.

    The gate layers (GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=github-hosted,
    RUNNER_OS=Windows, 64-bit Windows PowerShell 5.1 administrator, inputs
    and logs strictly below RUNNER_TEMP) are multiple tripwires against
    accidentally running the install path. They are explicitly NOT an
    unforgeable security boundary: environment variables can be faked, and
    nothing here should be described as a sandbox. The real isolation basis
    is the pinned GitHub-hosted windows-2022 runner defined in
    .github\workflows\sunshine-msi-acceptance.yml. There is deliberately NO
    seam to inject a simulated environment into the real path: the Execute
    gate always evaluates the live process environment, and the pure gate
    function is only unit-tested with synthetic inputs (never executed
    against the system).

    Installed-product detection uses read-only MSI COM and native MSI
    metadata APIs only (Installer.Products/ProductInfo for standard
    properties, MsiEnumRelatedProducts + MsiQueryProductState). NEVER
    Win32_Product: that WMI class triggers a repair of every listed
    product.

    Execute sequence: read-only MSI COM precheck (ProductName=GsController,
    known UpgradeCode on both, ProductCode differs, versions increase, no
    CustomAction / ServiceInstall / ServiceControl / Registry table in the
    Sunshine MSI), refusal of any installed related product / existing
    install directory / existing start menu entry / either target
    ProductCode already installed, install 0.3.0, verify the staged
    manifest hashes + gs-install-profile.json (backend=sunshine) + start
    menu shortcut and its advertised target (MsiGetShortcutTarget ->
    MsiGetComponentPath with INSTALLSTATE_LOCAL), start the installed
    gs-console.ps1 with an in-memory test session (-SessionToken,
    -NoBrowser -NoTray, temp port; the packaged profile decides the
    backend - never -Backend), verify the four static routes, the
    session-protected GET /api/sunshine/status JSON and the rejection of
    the legacy /api/actions route, stop the console process and confirm it
    exited, repair after deleting one payload file, stop-confirmed again,
    upgrade to 0.3.1 (manifest031 hashes, new ProductCode installed with
    the expected version, new shortcut ProductCode), uninstall and verify:
    known payload residue is a FAILURE, only empty directories are recorded
    (never deleted). Every msiexec runs with an absolute System32 path, a
    log, /norestart, a timeout and an explicitly non-null exit code (a null
    exit code is a failure, never a silent success). Exit 3010 is reported
    as RebootRequired and never as a full pass. The finally block cleans
    only the exact ProductCodes recorded for this run (recorded before any
    install attempt, so failed-but-installed states are covered) and only
    the console process this run started; every kill/uninstall is verified
    and a cleanup failure forces the overall verdict to Failed (cleanup
    output never claims "uninstalled" without verification).

    No real Sunshine installation, account, certificate, pairing or GPU
    check runs here; nothing in this harness may be reported as Windows 11
    desktop or streaming acceptance. The test session token is never
    written into the result JSON or step details (masked if it ever
    reaches a diagnostic string).
#>
[CmdletBinding()]
param(
    # Plan (default): zero system actions. Execute: gated real actions.
    [switch]$Execute,
    # Defines only the functions and returns (used by the unit suite).
    [switch]$DefineOnly,
    [string]$Version030 = '0.3.0',
    [string]$Version031 = '0.3.1',
    # Every Execute input and output must live below RUNNER_TEMP.
    [string]$Msi03 = '',
    [string]$Msi031 = '',
    [string]$Manifest030 = '',
    [string]$Manifest031 = '',
    [string]$JsonOut = '',
    [string]$LogDirectory = ''
)

$script:GsAcceptanceProductName = 'GsController'
# The canonical braced GUID form, exactly as the MSI Property table stores
# it and as the native Msi APIs (MsiEnumRelatedProducts/MsiQueryProductState)
# expect it.
$script:GsAcceptanceUpgradeCode = '{3B7F2C64-9A1D-4E58-8C2B-6D5A0F7E4B19}'
$script:GsAcceptanceInstallRelDir = 'Local Development\GsController'
$script:GsAcceptanceShortcutName = 'GsController.lnk'
$script:GsAcceptanceMsiExecTimeoutMs = 600000
$script:GsAcceptanceConsoleStartTimeoutMs = 30000

# INSTALLSTATE values returned by MsiQueryProductStateW / MsiGetComponentPathW.
$script:GsInstallStateLocal = 3
$script:GsInstallStateSource = 4
$script:GsInstallStateDefault = 5
$script:GsErrorNoMoreItems = 259

# ---------------------------------------------------------------------------
# Native MSI metadata (read-only; exact ABI: MsiGetShortcutTargetW outputs
# product code, feature id, component code in that order;
# MsiGetComponentPathW's last parameter is a ref uint buffer size and its
# return value is an INSTALLSTATE). Defining these helpers is side-effect
# free; Add-Type compiles only on the first call.
# ---------------------------------------------------------------------------

function Get-GsMsiNative {
    if (-not ('GsMsiNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Text;
using System.Runtime.InteropServices;
public static class GsMsiNative {
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern uint MsiGetShortcutTargetW(string szShortcutTargetPath, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder szProductCode, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder szFeatureId, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder szComponentCode);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int MsiGetComponentPathW(string szProductCode, string szComponentCode, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder lpPathBuf, [In][Out] ref uint pcchPathBuf);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern uint MsiEnumRelatedProductsW(string lpUpgradeCode, uint rReserved, uint dwProductIndex, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder lpProductCode);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int MsiQueryProductStateW(string szProductCode);
}
'@
    }
    return [GsMsiNative]
}

function Get-GsProductState {
    param([Parameter(Mandatory = $true)][string]$ProductCode)
    return [int](Get-GsMsiNative)::MsiQueryProductStateW($ProductCode)
}

function Test-GsProductInstalled {
    param([Parameter(Mandatory = $true)][string]$ProductCode)
    return ((Get-GsProductState -ProductCode $ProductCode) -eq $script:GsInstallStateDefault)
}

function Test-GsProductRegistered {
    # Advertised, absent-for-this-user and damaged registrations also count.
    # Only INSTALLSTATE_UNKNOWN (-1) proves that this code is not registered.
    param([Parameter(Mandatory = $true)][string]$ProductCode)
    return ((Get-GsProductState -ProductCode $ProductCode) -ne -1)
}

function Get-GsRegisteredRelatedProducts {
    # Every registered related code is a conflict, including advertised or
    # incomplete installations. Enumeration is read-only (never Win32_Product).
    param([Parameter(Mandatory = $true)][string]$UpgradeCode)
    $native = Get-GsMsiNative
    $installed = @()
    for ($index = 0; $index -lt 4096; $index++) {
        $codeBuf = New-Object System.Text.StringBuilder 64
        $call = $native::MsiEnumRelatedProductsW($UpgradeCode, 0, $index, $codeBuf)
        if ($call -eq $script:GsErrorNoMoreItems) { break }
        if ($call -ne 0) { throw ('MsiEnumRelatedProductsW failed with ' + $call) }
        $code = $codeBuf.ToString()
        $installed += $code
    }
    return @($installed)
}

# ---------------------------------------------------------------------------
# Pure functions (unit-tested by tests\Invoke-SunshineInstallAcceptanceTests.ps1)
# ---------------------------------------------------------------------------

function Get-GsAcceptancePlan {
    # Static, controlled order. Nothing outside this list may run.
    return @(
        [pscustomobject]@{ Id = 'ReadMsiPair'; Kind = 'Read'; Summary = 'Read-only MSI COM precheck of both packages' },
        [pscustomobject]@{ Id = 'RefuseConflicts'; Kind = 'Precheck'; Summary = 'Refuse installed related products, either target ProductCode, an existing install directory or an existing start menu entry' },
        [pscustomobject]@{ Id = 'Install030'; Kind = 'Install'; Summary = 'Install the 0.3.0 Sunshine MSI to the default per-machine location' },
        [pscustomobject]@{ Id = 'VerifyInstall030'; Kind = 'Verify'; Summary = 'Verify manifest hashes, install profile, shortcut presence and advertised target' },
        [pscustomobject]@{ Id = 'ConsoleProbe'; Kind = 'Probe'; Summary = 'Start the installed console with an in-memory test session and verify static assets, protected status JSON and legacy API rejection, then stop it' },
        [pscustomobject]@{ Id = 'RepairRound'; Kind = 'Repair'; Summary = 'Delete one installed payload file, repair and verify restoration' },
        [pscustomobject]@{ Id = 'Upgrade031'; Kind = 'Upgrade'; Summary = 'Upgrade to the 0.3.1 Sunshine MSI' },
        [pscustomobject]@{ Id = 'VerifyUpgrade031'; Kind = 'Verify'; Summary = 'Verify manifest031 hashes, new ProductCode installed with the expected version, old code gone and new shortcut ProductCode' },
        [pscustomobject]@{ Id = 'Uninstall031'; Kind = 'Uninstall'; Summary = 'Uninstall the 0.3.1 product by its recorded ProductCode' },
        [pscustomobject]@{ Id = 'VerifyUninstall031'; Kind = 'Verify'; Summary = 'Verify no known payload or shortcut residue (empty directories are recorded, never deleted)' },
        [pscustomobject]@{ Id = 'CleanupOwnArtifacts'; Kind = 'Cleanup'; Summary = 'Uninstall only this run ProductCodes and stop only this run console process, each verified' }
    )
}

function Test-GsRunnerGate {
    # Pure gate evaluation. The reasons are tripwires, not a sandbox.
    param(
        [hashtable]$Environment,
        [bool]$IsAdministrator,
        [bool]$Is64BitProcess,
        [version]$PowerShellVersion,
        [string]$PowerShellEdition
    )
    $reasons = @()
    if ($Environment['GITHUB_ACTIONS'] -ne 'true') { $reasons += 'GITHUB_ACTIONS must be true' }
    if ($Environment['RUNNER_ENVIRONMENT'] -ne 'github-hosted') { $reasons += 'RUNNER_ENVIRONMENT must be github-hosted' }
    if ($Environment['RUNNER_OS'] -ne 'Windows') { $reasons += 'RUNNER_OS must be Windows' }
    if (-not $IsAdministrator) { $reasons += 'an administrator PowerShell session is required' }
    if (-not $Is64BitProcess) { $reasons += 'a 64-bit process is required' }
    if ($PowerShellEdition -ne 'Desktop' -or $PowerShellVersion.Major -ne 5 -or $PowerShellVersion.Minor -lt 1) {
        $reasons += 'Windows PowerShell 5.1 Desktop x64 is required'
    }
    return [pscustomobject]@{ Allowed = ($reasons.Count -eq 0); Reasons = @($reasons) }
}

function Test-GsAcceptancePathScope {
    # True only when $Path equals or is below $RunnerTemp. GetFullPath is a
    # LEXICAL normalization (it does not resolve reparse points); the
    # physical guarantee comes from the separate ancestor-reparse refusal in
    # the Execute path. Empty paths are refused.
    param([string]$Path, [string]$RunnerTemp)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($RunnerTemp)) { return $false }
    try {
        $p = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $t = [IO.Path]::GetFullPath($RunnerTemp).TrimEnd('\')
    } catch { return $false }
    if ($p.Equals($t, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return ($p.Length -gt $t.Length -and $p.StartsWith($t + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-GsMsiExecVerdict {
    param([int]$ExitCode)
    if ($ExitCode -eq 0) {
        return [pscustomobject]@{ Verdict = 'Passed'; Summary = 'msiexec reported success' }
    }
    if ($ExitCode -eq 3010) {
        return [pscustomobject]@{ Verdict = 'RebootRequired'; Summary = 'msiexec reported 3010: a restart is required; the state is incomplete and cannot count as a full pass' }
    }
    return [pscustomobject]@{ Verdict = 'Failed'; Summary = ('msiexec failed with exit code ' + $ExitCode) }
}

function Test-GsMsiLogContent {
    # Pure log judgment: known fatal markers in an msiexec log text.
    param([string]$LogText)
    if ([string]::IsNullOrEmpty($LogText)) { return [pscustomobject]@{ Fatal = $false; Marker = '' } }
    foreach ($marker in @('Installation operation failed', 'Return value 3.')) {
        if ($LogText.Contains($marker)) {
            return [pscustomobject]@{ Fatal = $true; Marker = $marker }
        }
    }
    return [pscustomobject]@{ Fatal = $false; Marker = '' }
}

function Test-GsInstallProfileJson {
    # Pure content verdict for the packaged install profile.
    param([string]$Content, [string]$ExpectedBackend)
    try {
        $parsed = $Content | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ Verdict = 'Failed'; Detail = 'the install profile is not valid JSON' }
    }
    if ($null -eq $parsed -or $parsed.GetType().Name -ne 'PSCustomObject' -or
        -not $parsed.PSObject.Properties['schemaVersion'] -or -not $parsed.PSObject.Properties['backend']) {
        return [pscustomobject]@{ Verdict = 'Failed'; Detail = 'the profile must be an object with schemaVersion and backend' }
    }
    if (@($parsed.PSObject.Properties | Where-Object { $_.Name -notin @('schemaVersion', 'backend') }).Count -gt 0 -or
        ($parsed.schemaVersion -isnot [int] -and $parsed.schemaVersion -isnot [long]) -or $parsed.schemaVersion -ne 1) {
        return [pscustomobject]@{ Verdict = 'Failed'; Detail = 'the profile must contain only the supported fields and integer schemaVersion 1' }
    }
    if ($parsed.backend -isnot [string] -or $parsed.backend -cne $ExpectedBackend) {
        return [pscustomobject]@{ Verdict = 'Failed'; Detail = 'the backend does not match the required profile' }
    }
    return [pscustomobject]@{ Verdict = 'Passed'; Detail = ('backend=' + $parsed.backend + ', schemaVersion=1') }
}

function Test-GsMsiPairAcceptable {
    # Pure verdict over the parsed summaries of the two MSIs.
    param(
        [pscustomobject]$Msi030,
        [pscustomobject]$Msi031,
        [string]$ExpectedUpgradeCode,
        [string]$ExpectedProductName
    )
    $violations = @()
    # GUID spelling normalization: the MSI Property table stores the braced
    # form while callers may pass either; compare brace-stripped.
    $expectedUpgrade = $ExpectedUpgradeCode.Trim('{', '}')
    foreach ($summary in @($Msi030, $Msi031)) {
        $productGuid = [guid]::Empty
        if (-not [guid]::TryParse([string]$summary.ProductCode, [ref]$productGuid) -or $productGuid -eq [guid]::Empty) {
            $violations += ($summary.Path + ': ProductCode must be a nonempty GUID')
        }
        if ($summary.ProductName -ne $ExpectedProductName) {
            $violations += ($summary.Path + ': ProductName is ' + $summary.ProductName + ', expected ' + $ExpectedProductName)
        }
        if (@($summary.UpgradeCodes | Where-Object { $_.Trim('{', '}') -eq $expectedUpgrade }).Count -ne 1) {
            $violations += ($summary.Path + ': the known UpgradeCode is not present')
        }
        if ($summary.HasServiceInstall -or $summary.HasServiceControl) {
            $violations += ($summary.Path + ': ServiceInstall/ServiceControl tables must not exist')
        }
        if (@($summary.CustomActionNames).Count -gt 0) {
            $violations += ($summary.Path + ': arbitrary CustomAction table entries must not exist (found ' +
                (@($summary.CustomActionNames) -join ', ') + ')')
        }
        if ($summary.HasRegistryTable) {
            $violations += ($summary.Path + ': a Registry table must not exist (the product creates no registry entries)')
        }
    }
    if ($Msi030.ProductCode -eq $Msi031.ProductCode) {
        $violations += 'the two packages must have different ProductCodes'
    }
    try {
        if (-not ([version]$Msi030.Version -lt [version]$Msi031.Version)) {
            $violations += ('versions must strictly increase: ' + $Msi030.Version + ' -> ' + $Msi031.Version)
        }
    } catch {
        $violations += 'a ProductVersion is not parseable as a System.Version'
    }
    return [pscustomobject]@{ Accepted = ($violations.Count -eq 0); Violations = @($violations) }
}

function Test-GsManifestRows {
    # Pure structural validation of a staged-manifest JSON (parsed rows):
    # non-empty, unique relative paths, relative-only, no .. escapes, and
    # well-formed lowercase SHA-256 digests.
    param([AllowNull()][object[]]$Rows)
    $violations = @()
    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        return [pscustomobject]@{ Accepted = $false; Violations = @('the manifest is empty') }
    }
    $seen = @{}
    foreach ($row in $Rows) {
        if ($null -eq $row -or $row.GetType().Name -ne 'PSCustomObject' -or
            -not $row.PSObject.Properties['relativePath'] -or -not $row.PSObject.Properties['sha256'] -or
            $row.relativePath -isnot [string] -or $row.sha256 -isnot [string]) {
            $violations += 'each manifest row must be an object with scalar string relativePath and sha256'
            continue
        }
        $relative = $row.relativePath
        if ([string]::IsNullOrWhiteSpace($relative)) {
            $violations += 'a manifest row has a blank relativePath'
            continue
        }
        if ($seen.ContainsKey($relative)) {
            $violations += ('duplicate relativePath: ' + $relative)
        }
        $seen[$relative] = $true
        if ([IO.Path]::IsPathRooted($relative)) {
            $violations += ('absolute path not allowed: ' + $relative)
        }
        if ($relative -match '(^|[\\/])\.\.($|[\\/])' -or $relative.Contains('/')) {
            $violations += ('path escapes or uses foreign separators: ' + $relative)
        }
        if ($row.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            $violations += ('invalid sha256 for ' + $relative)
        }
    }
    return [pscustomobject]@{ Accepted = ($violations.Count -eq 0); Violations = @($violations) }
}

function ConvertFrom-GsAcceptanceManifestJson {
    # PS 5.1 emits a JSON array as one pipeline object. Do not surround the
    # conversion pipeline with @(), which introduces an extra array layer.
    param([Parameter(Mandatory = $true)][string]$Content)
    $parsed = ConvertFrom-Json -InputObject $Content -ErrorAction Stop
    if ($parsed -isnot [array]) { throw 'The manifest must be a JSON array.' }
    $rows = [object[]]$parsed
    $validation = Test-GsManifestRows -Rows $rows
    if (-not $validation.Accepted) { throw ('Invalid manifest: ' + ($validation.Violations -join '; ')) }
    return ,$rows
}

function Test-GsManifestComparison {
    # Pure hash comparison: expected staged rows vs actual installed hashes.
    # $Actual maps relativePath -> sha256 (or a missing key when absent).
    param(
        [AllowNull()][object[]]$Expected,
        [hashtable]$Actual
    )
    $violations = @()
    foreach ($row in $Expected) {
        if (-not $Actual.ContainsKey($row.relativePath)) {
            $violations += ('missing installed file: ' + $row.relativePath)
        } elseif ($Actual[$row.relativePath] -ne $row.sha256) {
            $violations += ('hash mismatch: ' + $row.relativePath)
        }
    }
    return [pscustomobject]@{ Accepted = ($violations.Count -eq 0); Violations = @($violations) }
}

function Get-GsMaskedText {
    # Pure masking: replaces any occurrence of the session token (and other
    # secrets) in diagnostic text so tokens can never leak into logs or the
    # result JSON.
    param([string]$Text, [string]$Secret)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Secret)) { return $Text }
    return $Text.Replace($Secret, '[masked-session]')
}

function Test-GsReparseAncestor {
    # Read-only metadata walk: returns the first existing ancestor-or-self
    # component of $Path that is a reparse point (junction/symlink), or
    # $null when the whole existing chain is plain. Complements the purely
    # lexical GetFullPath normalization used by the scope checks.
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $parts = @($full.Split('\') | Where-Object { $_.Length -gt 0 })
    if ($parts.Count -eq 0) { return $null }
    $current = $parts[0]
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $current = Join-Path $current $parts[$i]
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (-not [string]::IsNullOrEmpty($item.LinkType)) { return $current }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Read-only MSI COM helpers. Rowset contract: these helpers return a PLAIN
# array of row arrays - enumerate with `foreach ($row in (Get-...))` or
# capture with @(); never pipe-unwrap or guess the nesting level. The
# helpers are read-only (msiOpenDatabaseModeReadOnly) and are exposed to
# the unit suite through -DefineOnly.
# ---------------------------------------------------------------------------

function Get-MsiDatabaseRows {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [Parameter(Mandatory = $true)][string]$Sql,
        [Parameter(Mandatory = $true)][int]$Columns
    )
    $installer = New-Object -ComObject WindowsInstaller.Installer
    try {
        $database = $installer.OpenDatabase($MsiPath, 0)  # 0 = msiOpenDatabaseModeReadOnly
        try {
            $view = $database.OpenView($Sql)
            try {
                $view.Execute() | Out-Null
                $rows = @()
                while ($true) {
                    $record = $view.Fetch()
                    if ($null -eq $record) { break }
                    $row = @()
                    for ($i = 1; $i -le $Columns; $i++) { $row += [string]$record.StringData($i) }
                    [Runtime.InteropServices.Marshal]::ReleaseComObject($record) | Out-Null
                    $rows += , $row
                }
                return @($rows)
            } finally {
                [Runtime.InteropServices.Marshal]::ReleaseComObject($view) | Out-Null
            }
        } finally {
            [Runtime.InteropServices.Marshal]::ReleaseComObject($database) | Out-Null
        }
    } finally {
        [Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null
    }
}

function Get-MsiRowsIfTableExists {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [Parameter(Mandatory = $true)][string]$Sql,
        [Parameter(Mandatory = $true)][int]$Columns,
        [Parameter(Mandatory = $true)][string]$TableName
    )
    $tables = @(Get-MsiDatabaseRows -MsiPath $MsiPath -Sql 'SELECT `Name` FROM `_Tables`' -Columns 1)
    if (0 -eq @($tables | Where-Object { $_[0] -eq $TableName }).Count) { return @() }
    return @(Get-MsiDatabaseRows -MsiPath $MsiPath -Sql $Sql -Columns $Columns)
}

function Get-GsMsiSummary {
    param([Parameter(Mandatory = $true)][string]$MsiPath)
    if (-not (Test-Path -LiteralPath $MsiPath -PathType Leaf)) { throw "MSI not found: $MsiPath" }
    $properties = @{}
    foreach ($row in (Get-MsiDatabaseRows -MsiPath $MsiPath -Sql 'SELECT `Property`, `Value` FROM `Property`' -Columns 2)) {
        $properties[$row[0]] = $row[1]
    }
    $customActions = @()
    foreach ($row in (Get-MsiRowsIfTableExists -MsiPath $MsiPath -TableName 'CustomAction' `
            -Sql 'SELECT `Action` FROM `CustomAction`' -Columns 1)) {
        $customActions += $row[0]
    }
    $tableNames = @()
    foreach ($row in (Get-MsiDatabaseRows -MsiPath $MsiPath -Sql 'SELECT `Name` FROM `_Tables`' -Columns 1)) {
        $tableNames += $row[0]
    }
    return [pscustomobject]@{
        Path = $MsiPath
        ProductName = $properties['ProductName']
        ProductCode = $properties['ProductCode']
        Version = $properties['ProductVersion']
        UpgradeCodes = @($properties['UpgradeCode'])
        CustomActionNames = @($customActions)
        HasServiceInstall = ($tableNames -contains 'ServiceInstall')
        HasServiceControl = ($tableNames -contains 'ServiceControl')
        HasRegistryTable = ($tableNames -contains 'Registry')
    }
}

# Defines only the functions above; the main flow below never runs when the
# unit suite dot-sources this file with -DefineOnly.
if ($DefineOnly) { return }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Gate, scope and input resolution
# ---------------------------------------------------------------------------

$result = [ordered]@{
    mode = 'plan'
    gate = $null
    scope = $null
    precheck = $null
    steps = @()
    cleanup = $null
    overall = 'PlanOnly'
}
# Recorded BEFORE any install attempt so a 3010/failed-but-installed state
# is still covered by the finally cleanup.
$script:GsOwnProductCodes = @()
$script:GsOwnConsoleProcess = $null

function Add-StepResult {
    param([string]$Id, [string]$Verdict, [string]$Detail)
    $script:result.steps += [pscustomobject]@{ id = $Id; verdict = $Verdict; detail = $Detail }
}

$gate = Test-GsRunnerGate -Environment @{
    GITHUB_ACTIONS = [string]$env:GITHUB_ACTIONS
    RUNNER_ENVIRONMENT = [string]$env:RUNNER_ENVIRONMENT
    RUNNER_OS = [string]$env:RUNNER_OS
} -IsAdministrator ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) `
    -Is64BitProcess ([Environment]::Is64BitProcess) `
    -PowerShellVersion $PSVersionTable.PSVersion -PowerShellEdition $PSVersionTable.PSEdition
$result.gate = [pscustomobject]@{ allowed = $gate.Allowed; reasons = $gate.Reasons }

if ($Execute) {
    if (-not $gate.Allowed) {
        Write-Host ("EXECUTE REFUSED: " + ($gate.Reasons -join '; '))
        $result.overall = 'Failed'
        Write-Host (($result | ConvertTo-Json -Depth 6))
        exit 1
    }
    $runnerTemp = [string]$env:RUNNER_TEMP
    foreach ($candidate in @(
            @{ Name = 'Msi03'; Value = $Msi03 }, @{ Name = 'Msi031'; Value = $Msi031 },
            @{ Name = 'Manifest030'; Value = $Manifest030 }, @{ Name = 'Manifest031'; Value = $Manifest031 },
            @{ Name = 'JsonOut'; Value = $JsonOut }, @{ Name = 'LogDirectory'; Value = $LogDirectory })) {
        if (-not (Test-GsAcceptancePathScope -Path $candidate.Value -RunnerTemp $runnerTemp)) {
            Write-Host ("EXECUTE REFUSED: " + $candidate.Name + " must live below RUNNER_TEMP.")
            $result.overall = 'Failed'
            Write-Host (($result | ConvertTo-Json -Depth 6))
            exit 1
        }
    }
    $result.mode = 'execute'
    $result.scope = [pscustomobject]@{ runnerTemp = $runnerTemp; lexicalScopeVerified = $true }
} else {
    Write-Host 'PLAN ONLY: the static acceptance plan is listed below; no action is taken.'
}

# Read-only MSI precheck runs in both modes whenever paths are supplied.
if (-not [string]::IsNullOrWhiteSpace($Msi03) -and -not [string]::IsNullOrWhiteSpace($Msi031)) {
    $summary030 = Get-GsMsiSummary -MsiPath $Msi03
    $summary031 = Get-GsMsiSummary -MsiPath $Msi031
    $pair = Test-GsMsiPairAcceptable -Msi030 $summary030 -Msi031 $summary031 `
        -ExpectedUpgradeCode $script:GsAcceptanceUpgradeCode -ExpectedProductName $script:GsAcceptanceProductName
    $result.precheck = [pscustomobject]@{
        msi030 = $summary030; msi031 = $summary031
        accepted = $pair.Accepted; violations = $pair.Violations
    }
    Add-StepResult -Id 'ReadMsiPair' -Verdict $(if ($pair.Accepted) { 'Passed' } else { 'Failed' }) `
        -Detail ($(if ($pair.Accepted) { 'both MSI summaries accepted' } else { ($pair.Violations -join '; ') }))
    if (-not $pair.Accepted) { $result.overall = 'Failed' }
} else {
    Add-StepResult -Id 'ReadMsiPair' -Verdict 'Skipped' -Detail 'no MSI paths supplied'
}
if ($Execute -and $result.overall -eq 'Failed') {
    Write-Host (($result | ConvertTo-Json -Depth 6))
    exit 1
}

if (-not $Execute) {
    foreach ($step in (Get-GsAcceptancePlan)) {
        Write-Host ('PLAN STEP [' + $step.Kind + '] ' + $step.Id + ': ' + $step.Summary)
    }
    if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonOut
    }
    Write-Host (($result | ConvertTo-Json -Depth 6))
    Write-Host 'PLAN ONLY: zero actions were performed.'
    exit 0
}

# ---------------------------------------------------------------------------
# Execute path (never runs outside the gated GitHub-hosted runner)
# ---------------------------------------------------------------------------

try {
    $installRoot = Join-Path $env:ProgramFiles $script:GsAcceptanceInstallRelDir
    $commonPrograms = [Environment]::GetFolderPath('CommonPrograms')
    $shortcutPath = Join-Path $commonPrograms $script:GsAcceptanceShortcutName
    # GetFullPath is lexical only; refuse any existing ancestor reparse
    # point on the paths this run will write to or install into, so a
    # junction cannot redirect the acceptance outside its scope.
    foreach ($scopeTarget in @($runnerTemp, $LogDirectory, $JsonOut, $Msi03, $Msi031, $Manifest030, $Manifest031, $installRoot, $commonPrograms)) {
        $reparse = Test-GsReparseAncestor -Path $scopeTarget
        if ($null -ne $reparse) {
            throw ('ancestor reparse point refused: ' + $reparse)
        }
    }

    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

    # --- RefuseConflicts -------------------------------------------------
    # Read-only MSI COM and native metadata only; NEVER Win32_Product.
    $conflicts = @()
    $comInstaller = New-Object -ComObject WindowsInstaller.Installer
    foreach ($code in (Get-GsRegisteredRelatedProducts -UpgradeCode $script:GsAcceptanceUpgradeCode)) {
        $name = '<unknown>'
        try { $name = [string]$comInstaller.ProductInfo($code, 'ProductName') } catch { }
        $conflicts += ('related product already installed: ' + $code + ' (' + $name + ')')
    }
    foreach ($target in @($summary030.ProductCode, $summary031.ProductCode)) {
        if (Test-GsProductRegistered -ProductCode $target) {
            $conflicts += ('target product code is already installed: ' + $target)
        }
    }
    if (Test-Path -LiteralPath $installRoot) { $conflicts += ('install directory already exists: ' + $installRoot) }
    if (Test-Path -LiteralPath $shortcutPath) { $conflicts += ('start menu entry already exists: ' + $shortcutPath) }
    if ($conflicts.Count -gt 0) { throw ('refusing to install over an existing state: ' + ($conflicts -join '; ')) }
    Add-StepResult -Id 'RefuseConflicts' -Verdict 'Passed' -Detail 'no installed related product, target ProductCode, directory or shortcut collision'
    if ($summary030.Version -ne $Version030 -or $summary031.Version -ne $Version031) {
        throw 'The supplied MSI versions do not match the requested acceptance versions.'
    }
    # Record BOTH codes before any install attempt so a 3010 or a failed-but-
    # installed state is still covered by the finally cleanup.
    $script:GsOwnProductCodes = @($summary030.ProductCode, $summary031.ProductCode)
    # Validate both manifests before any install attempt.
    $manifest030Rows = ConvertFrom-GsAcceptanceManifestJson -Content ([IO.File]::ReadAllText($Manifest030))
    $manifest030Structure = Test-GsManifestRows -Rows $manifest030Rows
    if (-not $manifest030Structure.Accepted) { throw ('manifest030 is invalid: ' + ($manifest030Structure.Violations -join '; ')) }
    $manifest031Rows = ConvertFrom-GsAcceptanceManifestJson -Content ([IO.File]::ReadAllText($Manifest031))
    $manifest031Structure = Test-GsManifestRows -Rows $manifest031Rows
    if (-not $manifest031Structure.Accepted) { throw ('manifest031 is invalid: ' + ($manifest031Structure.Violations -join '; ')) }

    # --- msiexec runner (absolute System32 path; null exit code = failure) -
    function Invoke-GsMsiExec {
        param([string]$ArgumentsText, [string]$LogName)
        $log = Join-Path $LogDirectory $LogName
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $psi.Arguments = ($ArgumentsText + ' /norestart /l*v "' + $log + '"')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($script:GsAcceptanceMsiExecTimeoutMs)) {
            try { $proc.Kill() } catch { }
            return [pscustomobject]@{ Verdict = 'Failed'; Summary = 'msiexec timed out'; Log = $log; ExitCode = $null }
        }
        if (-not $proc.HasExited) {
            return [pscustomobject]@{ Verdict = 'Failed'; Summary = 'msiexec has not exited'; Log = $log; ExitCode = $null }
        }
        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode) {
            # A null exit code must never be treated as success.
            return [pscustomobject]@{ Verdict = 'Failed'; Summary = 'msiexec exit code unavailable (null)'; Log = $log; ExitCode = $null }
        }
        $verdict = Get-GsMsiExecVerdict -ExitCode ([int]$exitCode)
        $logText = ''
        try { $logText = [IO.File]::ReadAllText($log) } catch { }
        $fatal = Test-GsMsiLogContent -LogText $logText
        if ($fatal.Fatal -and $verdict.Verdict -ne 'Failed') {
            return [pscustomobject]@{ Verdict = 'Failed'; Summary = ('log fatal marker: ' + $fatal.Marker); Log = $log; ExitCode = ([int]$exitCode) }
        }
        return [pscustomobject]@{ Verdict = $verdict.Verdict; Summary = $verdict.Summary; Log = $log; ExitCode = ([int]$exitCode) }
    }

    # --- shared verifiers -------------------------------------------------
    function Test-GsInstalledManifest {
        param([Parameter(Mandatory = $true)][AllowNull()][object[]]$Rows, [Parameter(Mandatory = $true)][string]$Root)
        $structure = Test-GsManifestRows -Rows $Rows
        if (-not $structure.Accepted) { return $structure }
        $actual = @{}
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        foreach ($row in $Rows) {
            $installed = [IO.Path]::GetFullPath((Join-Path $Root $row.relativePath))
            # Lexical containment (physical protection comes from the
            # ancestor-reparse refusal above).
            if (-not $installed.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Accepted = $false; Violations = @('manifest path escapes the install root: ' + $row.relativePath) }
            }
            if (Test-Path -LiteralPath $installed -PathType Leaf) {
                $actual[$row.relativePath] = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        return (Test-GsManifestComparison -Expected $rows -Actual $actual)
    }

    function Get-GsShortcutTargetCheck {
        param([Parameter(Mandatory = $true)][string]$ShortcutPath, [Parameter(Mandatory = $true)][string]$ExpectedProductCode)
        $native = Get-GsMsiNative
        $productBuf = New-Object System.Text.StringBuilder 64
        $featureBuf = New-Object System.Text.StringBuilder 128
        $componentBuf = New-Object System.Text.StringBuilder 64
        $call = $native::MsiGetShortcutTargetW($ShortcutPath, $productBuf, $featureBuf, $componentBuf)
        if ($call -ne 0) {
            return [pscustomobject]@{ Ok = $false; ProductCode = ''; ResolvedPath = ''; Detail = ('MsiGetShortcutTargetW failed with ' + $call) }
        }
        $pathBuf = New-Object System.Text.StringBuilder 1024
        $capacity = [uint32]$pathBuf.Capacity
        $state = $native::MsiGetComponentPathW($productBuf.ToString(), $componentBuf.ToString(), $pathBuf, [ref]$capacity)
        if ($state -ne $script:GsInstallStateLocal) {
            return [pscustomobject]@{ Ok = $false; ProductCode = $productBuf.ToString(); ResolvedPath = ''; Detail = ('component state is ' + $state + ', expected INSTALLSTATE_LOCAL') }
        }
        $resolved = $pathBuf.ToString()
        $expectedTarget = Join-Path $installRoot 'gs-console.vbs'
        $ok = ($productBuf.ToString() -eq $ExpectedProductCode -and
            $resolved.Equals([IO.Path]::GetFullPath($expectedTarget), [StringComparison]::OrdinalIgnoreCase))
        return [pscustomobject]@{ Ok = $ok; ProductCode = $productBuf.ToString(); ResolvedPath = $resolved;
            Detail = ('shortcut -> product ' + $productBuf.ToString() + ', component path ' + $resolved) }
    }

    function Stop-GsOwnConsole {
        # Stops and CONFIRMS the console process this run owns, if any.
        if ($null -ne $script:GsOwnConsoleProcess) {
            $proc = $script:GsOwnConsoleProcess
            if (-not $proc.HasExited) {
                try { $proc.Kill() } catch { }
                if (-not $proc.WaitForExit(5000)) {
                    throw 'the console process this run started did not exit after being killed'
                }
            }
            $script:GsOwnConsoleProcess = $null
        }
    }

    # --- Install030 ------------------------------------------------------
    $install030 = Invoke-GsMsiExec -ArgumentsText ('/i "' + $Msi03 + '" /qn') -LogName 'install-0.3.0.log'
    Add-StepResult -Id 'Install030' -Verdict $install030.Verdict -Detail ($install030.Summary + ' | log: ' + $install030.Log)
    if ($install030.Verdict -ne 'Passed') { throw ('install 0.3.0 did not fully pass: ' + $install030.Summary) }

    # --- VerifyInstall030 ------------------------------------------------
    $hashCheck = Test-GsInstalledManifest -Rows $manifest030Rows -Root $installRoot
    $profileCheck = Test-GsInstallProfileJson -Content ([IO.File]::ReadAllText((Join-Path $installRoot 'gs-install-profile.json'))) -ExpectedBackend 'sunshine'
    $shortcutOk = (Test-Path -LiteralPath $shortcutPath -PathType Leaf)
    Add-StepResult -Id 'VerifyInstall030' -Verdict $(if ($hashCheck.Accepted -and $profileCheck.Verdict -eq 'Passed' -and $shortcutOk) { 'Passed' } else { 'Failed' }) `
        -Detail ('hashes: ' + ($(if ($hashCheck.Accepted) { 'all match' } else { ($hashCheck.Violations -join '; ') })) +
            ' | profile: ' + $profileCheck.Detail + ' | shortcut present: ' + $shortcutOk)
    if ($hashCheck.Accepted -ne $true -or $profileCheck.Verdict -ne 'Passed' -or $shortcutOk -ne $true) {
        throw 'the 0.3.0 install verification failed'
    }

    $targetCheck = Get-GsShortcutTargetCheck -ShortcutPath $shortcutPath -ExpectedProductCode $summary030.ProductCode
    Add-StepResult -Id 'VerifyShortcutTarget' -Verdict $(if ($targetCheck.Ok) { 'Passed' } else { 'Failed' }) -Detail $targetCheck.Detail
    if (-not $targetCheck.Ok) { throw 'the advertised shortcut does not resolve to the installed gs-console.vbs' }

    # --- ConsoleProbe ----------------------------------------------------
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $consolePort = ($listener.LocalEndpoint).Port
    $listener.Stop()
    $sessionToken = [guid]::NewGuid().ToString('N')
    Write-Host ('::add-mask::' + $sessionToken)
    # Console stdout/stderr live in a private subfolder: they can contain the
    # launch URL fragment with the session token and are never uploaded.
    $consolePrivate = Join-Path $LogDirectory 'console-private'
    New-Item -ItemType Directory -Path $consolePrivate -Force | Out-Null
    $consoleOut = Join-Path $consolePrivate 'console-stdout.txt'
    $consoleErr = Join-Path $consolePrivate 'console-stderr.txt'
    $consoleProc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $installRoot 'gs-console.ps1') + '" -NoBrowser -NoTray -Port ' + $consolePort + ' -SessionToken ' + $sessionToken) `
        -RedirectStandardOutput $consoleOut -RedirectStandardError $consoleErr `
        -WindowStyle Hidden -PassThru
    $script:GsOwnConsoleProcess = $consoleProc
    $ready = $false
    $deadline = [DateTime]::UtcNow.AddMilliseconds($script:GsAcceptanceConsoleStartTimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($consoleProc.HasExited) { break }
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $consolePort)
            $tcp.Close()
            $ready = $true
            break
        } catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) {
        $stderrTail = ''
        try { $stderrTail = ([IO.File]::ReadAllText($consoleErr)) } catch { }
        Stop-GsOwnConsole
        throw ('the installed console did not start listening in time; stderr: ' + (Get-GsMaskedText -Text $stderrTail -Secret $sessionToken))
    }
    function Invoke-GsProbeHttp {
        param([string]$Path, [string]$Session = '')
        $request = [System.Net.HttpWebRequest]::Create(('http://127.0.0.1:' + $consolePort + $Path))
        $request.Method = 'GET'
        $request.Host = ('127.0.0.1:' + $consolePort)
        $request.Timeout = 5000
        $request.ReadWriteTimeout = 5000
        $request.Proxy = $null
        $request.AllowAutoRedirect = $false
        $response = $null
        try {
            try {
                $response = $request.GetResponse()
                $body = (New-Object IO.StreamReader($response.GetResponseStream())).ReadToEnd()
                $status = [int]$response.StatusCode
            } catch [System.Net.WebException] {
                $response = $_.Exception.Response
                if ($null -eq $response) { throw }
                $status = [int]$response.StatusCode
                $body = ''
            }
            return [pscustomobject]@{ Status = $status; Body = $body }
        } finally {
            if ($null -ne $response) { $response.Close() }
        }
    }
    $probeFailures = @()
    foreach ($route in @('/', '/gs-sunshine.js', '/gs-console.css', '/gs-sunshine.css')) {
        $res = Invoke-GsProbeHttp -Path $route
        if ($res.Status -ne 200) { $probeFailures += ('static ' + $route + ' -> ' + $res.Status) }
    }
    $noSession = Invoke-GsProbeHttp -Path '/api/sunshine/status'
    if ($noSession.Status -eq 200) { $probeFailures += 'status API answered without a session' }
    $withSession = Invoke-GsProbeHttp -Path '/api/sunshine/status' -Session $sessionToken
    $statusBackend = ''
    if ($withSession.Status -eq 200) {
        try { $statusBackend = (($withSession.Body | ConvertFrom-Json).data.backend) } catch { $probeFailures += 'status JSON not parseable' }
        if ($statusBackend -ne 'sunshine') { $probeFailures += ('status backend is ' + $statusBackend) }
    } else { $probeFailures += ('status API with session -> ' + $withSession.Status) }
    $legacy = Invoke-GsProbeHttp -Path '/api/actions' -Session $sessionToken
    if (-not ($legacy.Status -ge 400 -and $legacy.Status -lt 500)) {
        $probeFailures += ('legacy /api/actions was not rejected -> ' + $legacy.Status)
    }
    # Stop the console BEFORE any repair/upgrade attempt and confirm exit.
    Stop-GsOwnConsole
    Add-StepResult -Id 'ConsoleProbe' -Verdict $(if ($probeFailures.Count -eq 0) { 'Passed' } else { 'Failed' }) `
        -Detail ($(if ($probeFailures.Count -eq 0) { 'static routes 200, status JSON backend=sunshine, legacy route rejected, console stopped and confirmed exited' } else { (Get-GsMaskedText -Text ($probeFailures -join '; ') -Secret $sessionToken) }))
    if ($probeFailures.Count -gt 0) { throw 'the console probe failed' }

    # --- RepairRound -----------------------------------------------------
    $victimRel = 'gs-console.html'
    $victim = Join-Path $installRoot $victimRel
    $victimExpected = $manifest030Rows | Where-Object { $_.relativePath -eq $victimRel }
    Remove-Item -LiteralPath $victim -Force
    $repair = Invoke-GsMsiExec -ArgumentsText ('/i "' + $Msi03 + '" /qn REINSTALL=ALL REINSTALLMODE=vomus') -LogName 'repair-0.3.0.log'
    $restored = $false
    if ($repair.Verdict -eq 'Passed' -and $null -ne $victimExpected -and (Test-Path -LiteralPath $victim -PathType Leaf)) {
        $restored = ((Get-FileHash -LiteralPath $victim -Algorithm SHA256).Hash.ToLowerInvariant() -eq $victimExpected.sha256)
    }
    $repairLayoutOk = $false
    if ($repair.Verdict -eq 'Passed') {
        $repairHashes = Test-GsInstalledManifest -Rows $manifest030Rows -Root $installRoot
        $repairProfile = Test-GsInstallProfileJson -Content ([IO.File]::ReadAllText((Join-Path $installRoot 'gs-install-profile.json'))) -ExpectedBackend 'sunshine'
        $repairShortcut = Get-GsShortcutTargetCheck -ShortcutPath $shortcutPath -ExpectedProductCode $summary030.ProductCode
        $repairLayoutOk = $repairHashes.Accepted -and $repairProfile.Verdict -eq 'Passed' -and $repairShortcut.Ok
    }
    Add-StepResult -Id 'RepairRound' -Verdict $(if ($restored -and $repair.Verdict -eq 'Passed' -and $repairLayoutOk) { 'Passed' } else { 'Failed' }) `
        -Detail ('repair verdict: ' + $repair.Verdict + ', file restored with matching hash: ' + $restored + ', complete layout verified: ' + $repairLayoutOk)
    if ($repair.Verdict -ne 'Passed' -or -not $restored -or -not $repairLayoutOk) { throw 'the repair round failed' }

    # --- Upgrade031 ------------------------------------------------------
    $upgrade = Invoke-GsMsiExec -ArgumentsText ('/i "' + $Msi031 + '" /qn') -LogName 'upgrade-0.3.1.log'
    Add-StepResult -Id 'Upgrade031' -Verdict $upgrade.Verdict -Detail ($upgrade.Summary + ' | log: ' + $upgrade.Log)
    if ($upgrade.Verdict -ne 'Passed') { throw ('upgrade did not fully pass: ' + $upgrade.Summary) }

    # --- VerifyUpgrade031 ------------------------------------------------
    $hashCheck031 = Test-GsInstalledManifest -Rows $manifest031Rows -Root $installRoot
    $profile031 = Test-GsInstallProfileJson -Content ([IO.File]::ReadAllText((Join-Path $installRoot 'gs-install-profile.json'))) -ExpectedBackend 'sunshine'
    $newInstalled = (Test-GsProductInstalled -ProductCode $summary031.ProductCode)
    $oldGone = (-not (Test-GsProductRegistered -ProductCode $summary030.ProductCode))
    $comInstaller = New-Object -ComObject WindowsInstaller.Installer
    $installedVersion = ''
    try { $installedVersion = [string]$comInstaller.ProductInfo($summary031.ProductCode, 'VersionString') } catch { }
    $versionOk = ($installedVersion -eq $Version031)
    $targetCheck031 = Get-GsShortcutTargetCheck -ShortcutPath $shortcutPath -ExpectedProductCode $summary031.ProductCode
    $upgradeOk = ($hashCheck031.Accepted -and $profile031.Verdict -eq 'Passed' -and $newInstalled -and $oldGone -and $versionOk -and $targetCheck031.Ok)
    Add-StepResult -Id 'VerifyUpgrade031' -Verdict $(if ($upgradeOk) { 'Passed' } else { 'Failed' }) `
        -Detail ('hashes: ' + ($(if ($hashCheck031.Accepted) { 'all match' } else { ($hashCheck031.Violations -join '; ') })) +
            ' | profile: ' + $profile031.Detail +
            ' | new code installed: ' + $newInstalled + ' | installed version: ' + $installedVersion +
            ' | old code gone: ' + $oldGone + ' | shortcut: ' + $targetCheck031.Detail)
    if (-not $upgradeOk) { throw 'the upgrade verification failed' }

    # --- Uninstall031 ----------------------------------------------------
    $uninstall = Invoke-GsMsiExec -ArgumentsText ('/x "' + $summary031.ProductCode + '" /qn') -LogName 'uninstall-0.3.1.log'
    Add-StepResult -Id 'Uninstall031' -Verdict $uninstall.Verdict -Detail ($uninstall.Summary + ' | log: ' + $uninstall.Log)
    if ($uninstall.Verdict -ne 'Passed') { throw ('uninstall did not fully pass: ' + $uninstall.Summary) }

    # --- VerifyUninstall031 ----------------------------------------------
    # Known payload residue (any manifest031 file still on disk) is a
    # FAILURE; only EMPTY directory residue is recorded, never deleted.
    # MSI product registration is checked separately from payload removal.
    $payloadResidue = @()
    foreach ($row in $manifest031Rows) {
        $installed = Join-Path $installRoot $row.relativePath
        if (Test-Path -LiteralPath $installed -PathType Leaf) { $payloadResidue += $row.relativePath }
    }
    $dirResidue = @()
    if (Test-Path -LiteralPath $installRoot -PathType Container) {
        $dirResidue = @(Get-ChildItem -LiteralPath $installRoot -Recurse -Directory -Force | ForEach-Object { $_.FullName })
    }
    $shortcutGone = (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf))
    $newCodeGone = (-not (Test-GsProductRegistered -ProductCode $summary031.ProductCode))
    $uninstallOk = ($payloadResidue.Count -eq 0 -and $shortcutGone -and $newCodeGone)
    Add-StepResult -Id 'VerifyUninstall031' -Verdict $(if ($uninstallOk) { 'Passed' } else { 'Failed' }) `
        -Detail ('payload residue files: ' + $payloadResidue.Count + ' | empty-directory residue recorded (not deleted): ' + $dirResidue.Count +
            ' | shortcut removed: ' + $shortcutGone + ' | product code gone: ' + $newCodeGone)
    if (-not $uninstallOk) { throw ('the uninstall verification failed: payload residue ' + $payloadResidue.Count + ', shortcut gone ' + $shortcutGone + ', code gone ' + $newCodeGone) }

    $result.overall = 'Passed'
} catch {
    Add-StepResult -Id 'HarnessException' -Verdict 'Failed' -Detail $_.Exception.Message
    $result.overall = 'Failed'
} finally {
    $cleanupActions = @()
    $cleanupFailed = $false
    if ($null -ne $script:GsOwnConsoleProcess) {
        $proc = $script:GsOwnConsoleProcess
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch { $cleanupFailed = $true; $cleanupActions += 'killing the console process failed' }
            if (-not $proc.WaitForExit(5000)) {
                $cleanupFailed = $true
                $cleanupActions += 'the console process did not exit after kill'
            } else {
                $cleanupActions += 'console process terminated (exit confirmed)'
            }
        } else {
            $cleanupActions += 'console process already exited'
        }
        $script:GsOwnConsoleProcess = $null
    }
    foreach ($code in $script:GsOwnProductCodes) {
        try {
            if (Test-GsProductRegistered -ProductCode $code) {
                $log = Join-Path $LogDirectory ('cleanup-' + $code + '.log')
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = Join-Path $env:SystemRoot 'System32\msiexec.exe'
                $psi.Arguments = ('/x "' + $code + '" /qn /norestart /l*v "' + $log + '"')
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                if (-not $p.WaitForExit($script:GsAcceptanceMsiExecTimeoutMs)) {
                    try { $p.Kill() } catch { }
                    throw 'cleanup uninstall timed out'
                }
                if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0) {
                    throw 'cleanup uninstall did not return success'
                }
                if (Test-GsProductRegistered -ProductCode $code) {
                    throw 'product registration remains after cleanup'
                }
                $cleanupActions += ('own product code uninstalled and verified: ' + $code)
            }
        } catch {
            $cleanupFailed = $true
            $cleanupActions += ('cleanup FAILED for ' + $code + ': ' + $_.Exception.Message)
        }
    }
    $result.cleanup = [pscustomobject]@{ actions = @($cleanupActions); failed = $cleanupFailed }
    # A cleanup failure must never leave the overall verdict at Passed.
    if ($cleanupFailed) { $result.overall = 'Failed' }
    if (@($result.steps | Where-Object { $_.verdict -eq 'Failed' }).Count -gt 0) {
        $result.overall = 'Failed'
    }
}

if (-not [string]::IsNullOrWhiteSpace($JsonOut)) {
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonOut
}
Write-Host (($result | ConvertTo-Json -Depth 6))
if ($result.overall -eq 'Passed') { exit 0 }
exit 1
