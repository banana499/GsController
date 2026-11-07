#requires -Version 5.1
<#
.SYNOPSIS
  Builds the GsController product MSI from the product modules and a
  separately supplied, prebuilt runtime bundle.

.DESCRIPTION
  This repository contains the product/installer/lifecycle layer only.  The
  runtime bundle (the prebuilt helper scripts and the streamer helper DLL) is
  an external, opaque dependency.  It is not part of this repository and is
  supplied with -RuntimeBundleDir.

  The bundle's files are copied verbatim into the MSI's bin/ directory.  No
  compiler, reverse-engineering source, or NVIDIA binary is needed here.

  Every top-level file in product\ is staged into the MSI's root; among them
  gs-product.ps1 is a required input (the build fails without it).

  The local web console is a fixed seven-file set (gs-console.ps1,
  gs-console-action.ps1, gs-console.vbs, gs-console.html, gs-console.css,
  gs-console.js, gs-console-strings.zh-CN.json). A build missing any member
  would ship a console that cannot start or render, so every member is a
  required input as well. gs-tray-model.ps1 is a required input in its own
  right because gs-console.ps1 dot-sources it unconditionally at startup.
  The runtime bundle must carry every public file of the shared
  Get-GsPublicBundleFileNames contract (scripts\Test-GsPrerequisites.ps1);
  presence is a metadata completeness gate only and never validates the
  legitimacy, compatibility or runnability of the supplied runtime.

  -RuntimeProfile selects the packaged backend. Legacy (default) behaves
  exactly as before, including the runtime bundle gate and the legacy
  uninstall cleanup wiring. Sunshine builds no runtime payload at all: the
  private runtime bundle is neither required nor read, an explicitly
  supplied -RuntimeBundleDir is rejected as contradictory, the Sunshine
  resources (gs-sunshine.ps1/html/js/css) are required inputs, and the legacy
  cleanup custom actions are compiled out of the MSI so uninstalling
  GsController can never touch the legacy scheduled task or an external
  Sunshine installation.

  Every build writes a generated gs-install-profile.json into the stage
  (schemaVersion 1, lowercase backend) binding the selected profile to the
  MSI; a same-named file in the product source directory can never override
  it, because the generated profile is written after every copy.

  All required-input checks run before any directory is created or deleted.

  The product license texts (LICENSE, LICENSING.md) are required inputs as
  well and are staged into the MSI's root so a distributed MSI carries its
  licensing statement.
#>
[CmdletBinding()]
param(
    # Validated by the build preflight (scripts\GsBuildPreflight.ps1) as an
    # MSI ProductVersion: major 0-255, minor 0-255, build 0-65535.
    [string]$Version = '0.2.0',
    [string]$OutputDirectory = '',
    [string]$WixDir = 'C:\Tools\GsBuild\wix314',
    # Legacy (default): the build consumes the opaque runtime bundle exactly
    # as before. Sunshine: the build never requires, enumerates or reads the
    # private runtime bundle, and an explicitly supplied -RuntimeBundleDir is
    # rejected as a contradictory input instead of being packaged.
    [ValidateSet('Legacy', 'Sunshine')][string]$RuntimeProfile = 'Legacy',
    [string]$RuntimeBundleDir = '',
    # Run every input check and exit before any directory is created or
    # deleted. No staging, no WiX invocation, no signing.
    [switch]$PreflightOnly
)
# ValidateSet accepts any casing ('legacy' passes) and binds the value as
# typed, while the WiX preprocessor comparison in GsController.wxs
# ($(var.GsInstallProfile) = "Legacy") is CASE-SENSITIVE. A lowercase
# 'legacy' would otherwise stage the runtime bundle yet compile WITHOUT the
# legacy uninstall cleanup. Normalize to the canonical spelling immediately
# after binding, before anything consumes the value.
$RuntimeProfile = if ($RuntimeProfile -eq 'Legacy') { 'Legacy' } else { 'Sunshine' }
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifacts = Join-Path $root 'artifacts'
$wix = [IO.Path]::GetFullPath($WixDir)
$heat = Join-Path $wix 'heat.exe'
$candle = Join-Path $wix 'candle.exe'
$light = Join-Path $wix 'light.exe'
# Contradictory-input rejection, before ANY tool or path inspection: the
# Sunshine build never consumes the opaque runtime bundle, so an explicitly
# supplied -RuntimeBundleDir is refused instead of being quietly packaged.
if ($RuntimeProfile -eq 'Sunshine' -and -not [string]::IsNullOrWhiteSpace($RuntimeBundleDir)) {
    throw ("Conflicting input: -RuntimeBundleDir '{0}' was supplied with -RuntimeProfile Sunshine; " +
        "the Sunshine build does not consume the private runtime bundle. Remove -RuntimeBundleDir.") -f $RuntimeBundleDir
}
foreach ($tool in @($heat, $candle, $light)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required WiX tool not found: $tool" }
}
if ($RuntimeProfile -eq 'Legacy') {
    if ([string]::IsNullOrWhiteSpace($RuntimeBundleDir)) {
        $RuntimeBundleDir = Join-Path $root 'runtime-bundle'
    }
    $RuntimeBundleDir = [IO.Path]::GetFullPath($RuntimeBundleDir)
    if (-not (Test-Path -LiteralPath $RuntimeBundleDir -PathType Container)) {
        throw "Runtime bundle directory not found: $RuntimeBundleDir"
    }
    $bundleFiles = @(Get-ChildItem -LiteralPath $RuntimeBundleDir -File -Force |
        Where-Object { $_.Name -notin @('README.md', 'manifest.example.json') })
    if ($bundleFiles.Count -eq 0) {
        throw "Runtime bundle is empty (only documentation found): $RuntimeBundleDir"
    }
} else {
    # Explicit omission: the Sunshine preflight sees no runtime input at all
    # (no default resolution, no placeholder path).
    $RuntimeBundleDir = ''
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $artifacts 'msi' }
$out = [IO.Path]::GetFullPath($OutputDirectory)

$modules = @('GsControl', 'GsLifecycle', 'GsRuntime')
$productDir = Join-Path $root 'product'
$productEntry = Join-Path $productDir 'gs-product.ps1'
$productWxs = Join-Path $root 'installer\GsController.wxs'
# Controlled heat XSL transform: attaches the Start Menu advertised shortcut
# to the harvested gs-console.vbs component (see installer\GsConsoleShortcut.xsl).
$harvestXsl = Join-Path $root 'installer\GsConsoleShortcut.xsl'
# Distribution requires the product license texts to ship inside the MSI;
# both are required inputs and are staged into the MSI's root directory.
$licenseInputs = @((Join-Path $root 'LICENSE'), (Join-Path $root 'LICENSING.md'))
# The local web console only works when all seven of its files ship
# together; the check below rejects an incomplete set before any cleanup.
$consoleInputs = @(
    'gs-console.ps1', 'gs-console-action.ps1', 'gs-console.vbs',
    'gs-console.html', 'gs-console.css', 'gs-console.js',
    'gs-console-strings.zh-CN.json'
) | ForEach-Object { Join-Path $productDir $_ }
# The Sunshine backend is a fixed four-file set (confirmed frontend list);
# a Sunshine-profile build missing any member would ship a backend whose
# page cannot render: gs-sunshine.css carries incremental styles on top of
# the shared gs-console.css, so both stylesheets ship with every build.
$sunshineInputs = @('gs-sunshine.ps1', 'gs-sunshine.html', 'gs-sunshine.js',
    'gs-sunshine.css') | ForEach-Object { Join-Path $productDir $_ }
# gs-console.ps1 dot-sources gs-tray-model.ps1 unconditionally at startup,
# so a complete console set without it still ships a build that fails on
# first use. It is a required dependency in its own right, not part of the
# console file set.
$trayModelInput = Join-Path $productDir 'gs-tray-model.ps1'
$requiredInputs = @($productEntry, $productWxs, $trayModelInput, $harvestXsl) + $licenseInputs + $consoleInputs
if ($RuntimeProfile -eq 'Sunshine') { $requiredInputs += $sunshineInputs }
foreach ($required in $requiredInputs) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing input: $required" }
}
$productFiles = @(Get-ChildItem -LiteralPath $productDir -File | Sort-Object -Property Name)
if (@($productFiles | Where-Object { $_.Name -eq 'gs-product.ps1' }).Count -ne 1) {
    throw "gs-product.ps1 is missing from the product directory: $productDir"
}
foreach ($m in $modules) {
    foreach ($ext in @('psd1', 'psm1')) {
        $p = Join-Path $root "src\$m\$m.$ext"
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing input: $p" }
    }
}

# Build preflight: verify the version grammar and that no user-supplied path
# (runtime bundle, WiX tools, output directory) physically overlaps the build
# work directories below or any source input. Work directories are deleted on
# every run, so an overlap would destroy inputs. All checks run BEFORE any
# deletion or creation; a violation aborts the build with inputs untouched.
$stage = Join-Path $artifacts 'product-stage'
$wixBuild = Join-Path $artifacts 'wix\product'
. (Join-Path $PSScriptRoot 'GsBuildPreflight.ps1')
$moduleDirs = @($modules | ForEach-Object { Join-Path $root "src\$_" })
$preflight = Invoke-GsBuildPreflight -Version $Version -Root $root `
    -WixDir $wix -RuntimeBundleDir $RuntimeBundleDir -OutputDirectory $out `
    -StageDir $stage -WixBuildDir $wixBuild -ProductDir $productDir `
    -InstallerDir (Join-Path $root 'installer') -ScriptsDir (Join-Path $root 'scripts') `
    -ModuleDirs $moduleDirs
if ($preflight.Violations.Count -gt 0) {
    foreach ($v in $preflight.Violations) {
        Write-Host ("PREFLIGHT [FAIL] {0}: {1}" -f $v.Code, $v.Message)
    }
    throw ("Build preflight failed with {0} violation(s); nothing was deleted." -f $preflight.Violations.Count)
}
# Public bundle completeness gate: Legacy only, still before any deletion
# or creation (and part of -PreflightOnly), but reported AFTER the overlap
# preflight so a dangerous aliasing configuration is decided by PathOverlap,
# not masked by a completeness error. The file-name list is the single
# shared contract from scripts\Test-GsPrerequisites.ps1, loaded inside a
# child scope ON PURPOSE: dot-sourcing with parameters would bind the
# checker's parameter defaults into this script's scope and clobber
# same-named variables ($RuntimeBundleDir, and $WixDir, which is the same
# variable as $wix). -DefineOnly only defines the checker's functions and
# runs no checks; the function is consumed before the child scope exits.
# File presence is a metadata completeness gate only - it never validates
# the legitimacy, compatibility or runnability of the supplied runtime,
# which stays external and opaque. The Sunshine profile never runs this
# gate: it has no runtime input at all.
if ($RuntimeProfile -eq 'Legacy') {
    $missingBundleFiles = @(& {
        . (Join-Path $PSScriptRoot 'Test-GsPrerequisites.ps1') -RepoRoot 'C:\' -DefineOnly
        Get-GsPublicBundleFileNames
    } | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $RuntimeBundleDir $_) -PathType Leaf)
    })
    if ($missingBundleFiles.Count -gt 0) {
        throw ("Runtime bundle is missing {0} required public file(s): {1}" -f
            $missingBundleFiles.Count, ($missingBundleFiles -join ', '))
    }
}
Write-Host ("PREFLIGHT [PASS] version={0}" -f $Version)
foreach ($r in $preflight.Resolved.GetEnumerator()) {
    Write-Host ("PREFLIGHT [PASS] {0} -> {1}" -f $r.Key, $r.Value)
}
if ($PreflightOnly) {
    Write-Host 'PREFLIGHT OK: all checks passed; stopping before staging (-PreflightOnly).'
    exit 0
}

# Stage product modules +, for Legacy, the opaque runtime bundle + every
# top-level product file (gs-product.ps1 is the required entry; other
# product files such as gs-diagnose.ps1 ship alongside it). The Sunshine
# profile stages no runtime payload at all.
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
if ($RuntimeProfile -eq 'Legacy') {
    $stageBin = Join-Path $stage 'bin'
    New-Item -ItemType Directory -Path $stageBin -Force | Out-Null
    foreach ($f in $bundleFiles) {
        Copy-Item -LiteralPath $f.FullName -Destination $stageBin -Force
    }
}
foreach ($m in $modules) {
    $dst = Join-Path $stage "Modules\$m"
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root "src\$m\$m.psd1") -Destination $dst
    Copy-Item -LiteralPath (Join-Path $root "src\$m\$m.psm1") -Destination $dst
}
foreach ($f in $productFiles) {
    Copy-Item -LiteralPath $f.FullName -Destination $stage -Force
}
foreach ($license in $licenseInputs) {
    Copy-Item -LiteralPath $license -Destination $stage -Force
}
# Install profile binding, written LAST so a same-named file in the product
# source directory can never override the build-generated contract. The
# staged gs-console.ps1 reads it to pick its backend; backend is lowercase.
$installProfileJson = '{' + "`r`n" +
    '  "schemaVersion": 1,' + "`r`n" +
    ('  "backend": "{0}"' -f $RuntimeProfile.ToLowerInvariant()) + "`r`n" +
    '}'
[IO.File]::WriteAllText((Join-Path $stage 'gs-install-profile.json'), $installProfileJson, (New-Object System.Text.UTF8Encoding($false)))
$stagedCount = @(Get-ChildItem -LiteralPath $stage -Recurse -File).Count
Write-Host "Staged $stagedCount files: $stage"

# Harvest, compile, link.
if (Test-Path -LiteralPath $wixBuild) { Remove-Item -LiteralPath $wixBuild -Recurse -Force }
New-Item -ItemType Directory -Path $wixBuild -Force | Out-Null
New-Item -ItemType Directory -Path $out -Force | Out-Null
$harvest = Join-Path $wixBuild 'ProductFiles.wxs'
& $heat dir $stage -nologo -cg ProductFiles -gg -g1 -srd -sreg -dr INSTALLFOLDER -var var.StageDir -t $harvestXsl -out $harvest
if ($LASTEXITCODE -ne 0) { throw "heat.exe failed: $LASTEXITCODE" }
& $candle -nologo -arch x64 "-dVersion=$Version" "-dStageDir=$stage" "-dGsInstallProfile=$RuntimeProfile" -out ($wixBuild + '\') $productWxs $harvest
if ($LASTEXITCODE -ne 0) { throw "candle.exe failed: $LASTEXITCODE" }
# Profile-bound artifact name: the two profiles can target the same output
# directory without overwriting each other, and a downloaded MSI is
# identifiable without opening it. ProductName and UpgradeCode are
# untouched.
$msiName = if ($RuntimeProfile -eq 'Sunshine') { "GsController-Sunshine-$Version.msi" } else { "GsController-$Version.msi" }
$msi = Join-Path $out $msiName
& $light -nologo -out $msi (Join-Path $wixBuild 'GsController.wixobj') (Join-Path $wixBuild 'ProductFiles.wixobj')
if ($LASTEXITCODE -ne 0) { throw "light.exe failed: $LASTEXITCODE" }
Write-Host "MSI built: $msi"
exit 0
