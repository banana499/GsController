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
    [string]$RuntimeBundleDir = '',
    # Run every input check and exit before any directory is created or
    # deleted. No staging, no WiX invocation, no signing.
    [switch]$PreflightOnly
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifacts = Join-Path $root 'artifacts'
$wix = [IO.Path]::GetFullPath($WixDir)
$heat = Join-Path $wix 'heat.exe'
$candle = Join-Path $wix 'candle.exe'
$light = Join-Path $wix 'light.exe'
foreach ($tool in @($heat, $candle, $light)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required WiX tool not found: $tool" }
}
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
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $artifacts 'msi' }
$out = [IO.Path]::GetFullPath($OutputDirectory)

$modules = @('GsControl', 'GsLifecycle', 'GsRuntime')
$productDir = Join-Path $root 'product'
$productEntry = Join-Path $productDir 'gs-product.ps1'
$productWxs = Join-Path $root 'installer\GsController.wxs'
# Distribution requires the product license texts to ship inside the MSI;
# both are required inputs and are staged into the MSI's root directory.
$licenseInputs = @((Join-Path $root 'LICENSE'), (Join-Path $root 'LICENSING.md'))
foreach ($required in (@($productEntry, $productWxs) + $licenseInputs)) {
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
Write-Host ("PREFLIGHT [PASS] version={0}" -f $Version)
foreach ($r in $preflight.Resolved.GetEnumerator()) {
    Write-Host ("PREFLIGHT [PASS] {0} -> {1}" -f $r.Key, $r.Value)
}
if ($PreflightOnly) {
    Write-Host 'PREFLIGHT OK: all checks passed; stopping before staging (-PreflightOnly).'
    exit 0
}

# Stage product modules + opaque runtime bundle + every top-level product
# file (gs-product.ps1 is the required entry; other product files such as
# gs-diagnose.ps1 ship alongside it).
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$stageBin = Join-Path $stage 'bin'
New-Item -ItemType Directory -Path $stageBin -Force | Out-Null
foreach ($m in $modules) {
    $dst = Join-Path $stage "Modules\$m"
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root "src\$m\$m.psd1") -Destination $dst
    Copy-Item -LiteralPath (Join-Path $root "src\$m\$m.psm1") -Destination $dst
}
foreach ($f in $bundleFiles) {
    Copy-Item -LiteralPath $f.FullName -Destination $stageBin -Force
}
foreach ($f in $productFiles) {
    Copy-Item -LiteralPath $f.FullName -Destination $stage -Force
}
foreach ($license in $licenseInputs) {
    Copy-Item -LiteralPath $license -Destination $stage -Force
}
$stagedCount = @(Get-ChildItem -LiteralPath $stage -Recurse -File).Count
Write-Host "Staged $stagedCount files: $stage"

# Harvest, compile, link.
if (Test-Path -LiteralPath $wixBuild) { Remove-Item -LiteralPath $wixBuild -Recurse -Force }
New-Item -ItemType Directory -Path $wixBuild -Force | Out-Null
New-Item -ItemType Directory -Path $out -Force | Out-Null
$harvest = Join-Path $wixBuild 'ProductFiles.wxs'
& $heat dir $stage -nologo -cg ProductFiles -gg -g1 -srd -sreg -dr INSTALLFOLDER -var var.StageDir -out $harvest
if ($LASTEXITCODE -ne 0) { throw "heat.exe failed: $LASTEXITCODE" }
& $candle -nologo -arch x64 "-dVersion=$Version" "-dStageDir=$stage" -out ($wixBuild + '\') $productWxs $harvest
if ($LASTEXITCODE -ne 0) { throw "candle.exe failed: $LASTEXITCODE" }
$msi = Join-Path $out "GsController-$Version.msi"
& $light -nologo -out $msi (Join-Path $wixBuild 'GsController.wixobj') (Join-Path $wixBuild 'ProductFiles.wixobj')
if ($LASTEXITCODE -ne 0) { throw "light.exe failed: $LASTEXITCODE" }
Write-Host "MSI built: $msi"
exit 0
