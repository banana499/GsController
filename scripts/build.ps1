#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Build')]
param(
    [Parameter(ParameterSetName='Tools', Mandatory=$true)][switch]$CheckTools,
    [Parameter(ParameterSetName='Build')][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.1.0',
    [Parameter(ParameterSetName='Build')][string]$OutputDirectory = '',
    [Parameter(ParameterSetName='Build')][string]$WixDir = 'C:\Tools\GsBuild\wix314'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$wix = [IO.Path]::GetFullPath($WixDir)
$candle = Join-Path $wix 'candle.exe'
$light = Join-Path $wix 'light.exe'
foreach ($tool in @($candle, $light)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Required WiX tool not found: $tool" }
}
if ($CheckTools) {
    & $candle -? | Select-Object -First 2
    & $light -? | Select-Object -First 2
    Write-Host "WiX tools OK: $wix"
    exit 0
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'artifacts\msi' }
$out = [IO.Path]::GetFullPath($OutputDirectory)
$sample = Join-Path $root 'installer\sample'
$wxs = Join-Path $root 'installer\Product.wxs'
foreach ($required in @($sample, $wxs)) { if (-not (Test-Path -LiteralPath $required)) { throw "Missing input: $required" } }
$sampleFile = Join-Path $sample 'Get-SampleInfo.ps1'
$content = [IO.File]::ReadAllText($sampleFile)
$updated = [Text.RegularExpressions.Regex]::Replace($content, "Version = '[^']+'", "Version = '$Version'")
if ($updated -ne $content) { [IO.File]::WriteAllText($sampleFile, $updated, (New-Object Text.UTF8Encoding($false))) }
New-Item -ItemType Directory -Path $out -Force | Out-Null
$build = Join-Path $root 'artifacts\wix'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$obj = Join-Path $build "GsControllerSample-$Version.wixobj"
$msi = Join-Path $out "GsControllerSample-$Version.msi"
& $candle -nologo -arch x64 "-dVersion=$Version" "-dSampleDir=$sample" -out $obj $wxs
if ($LASTEXITCODE -ne 0) { throw "candle.exe failed: $LASTEXITCODE" }
& $light -nologo -sice:ICE03 -out $msi $obj
if ($LASTEXITCODE -ne 0) { throw "light.exe failed: $LASTEXITCODE" }
Write-Host "MSI built: $msi"
