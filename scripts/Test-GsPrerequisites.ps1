<#
.SYNOPSIS
    Read-only source/build prerequisite checks. Returns Success, Data, Errors.
.DESCRIPTION
    Does not import product modules, read external file contents, run helpers,
    install, elevate, download, or change tasks, services or permissions.
    Source mode needs only the source tree and supported PowerShell environment.
    Supplied external paths are checked; absent optional inputs are reported as
    MissingDependency without failing Source mode. Build needs runtime and WiX.
    Success means metadata checks passed, NOT runtime or security acceptance.
.PARAMETER EnvironmentProbe
    Test seam returning IsWindows (bool), Architecture, Is64BitProcess (bool),
    PowerShellVersion and PSEdition. Results identify simulated environments.
    Do not use this parameter for an operator's real prerequisite check.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RepoRoot,
    [string]$RuntimeBundleDir = '',
    [string]$ComponentSourceDir = '',
    [string]$WixDir = '',
    [ValidateSet('Source', 'Build')][string]$Mode = 'Source',
    [scriptblock]$EnvironmentProbe
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$checks = New-Object 'System.Collections.Generic.List[object]'
$errors = New-Object 'System.Collections.Generic.List[object]'

function Add-Check {
    param([string]$Name, [string]$Status, [bool]$Required,
        [string]$Path, [string]$Message, [string]$NextStep)
    $check = [pscustomobject]@{
        Name = $Name; Status = $Status; Required = $Required
        Path = $Path; Message = $Message; NextStep = $NextStep
    }
    $checks.Add($check)
    if ($Required -and $Status -ne 'Present') {
        $errors.Add([pscustomobject]@{
            Code = $Status; Field = $Name; Path = $Path
            Message = $Message; NextStep = $NextStep
        })
    }
}
function Test-InputPath {
    param([string]$Name, [string]$Path, [bool]$Required,
        [string]$Kind = 'Container', [string]$NextStep)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Check $Name 'MissingDependency' $Required '' 'No explicit path was supplied.' $NextStep
        return $null
    }
    try {
        $root = [IO.Path]::GetPathRoot($Path)
        if (-not [IO.Path]::IsPathRooted($Path) -or $root -notmatch '[\\/]$' -or $root -eq '\' -or $root -eq '/') {
            Add-Check $Name 'InvalidPath' $Required $Path 'Supply an absolute filesystem path.' $NextStep
            return $null
        }
        $full = [IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $full -PathType $Kind -ErrorAction Stop)) {
            Add-Check $Name 'MissingDependency' $Required $full ('Expected {0} not found.' -f $Kind) $NextStep
            return $null
        }
        Add-Check $Name 'Present' $Required $full 'Path exists (metadata only).' ''
        return $full
    } catch {
        Add-Check $Name 'PathCheckFailed' $Required $Path 'Could not inspect the supplied path.' $NextStep
        return $null
    }
}
function New-PrerequisiteResult {
    [pscustomobject]@{
        Success = ($errors.Count -eq 0)
        Data = [pscustomobject]@{
            Mode = $Mode
            MetadataOnly = $true
            EnvironmentSimulated = ($null -ne $EnvironmentProbe)
            RuntimeValidated = $false
            SecurityValidated = $false
            Checks = $checks.ToArray()
            NextSteps = @($checks | Where-Object { $_.NextStep } | ForEach-Object { $_.NextStep } | Select-Object -Unique)
            Limitations = @(
                'File presence does not establish authenticity, compatibility, licensing or runtime behavior.',
                'GPU, drivers, network, Python/helper dependencies, permissions and streaming are not tested.',
                'There is currently no documented public runtime download channel.'
            )
        }
        Errors = $errors.ToArray()
    }
}

try {
    if ($null -ne $EnvironmentProbe) {
        $environment = & $EnvironmentProbe
    } else {
        $architecture = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = $env:PROCESSOR_ARCHITECTURE }
        $edition = 'Desktop'
        if ($PSVersionTable.ContainsKey('PSEdition')) { $edition = $PSVersionTable.PSEdition }
        $environment = [pscustomobject]@{
            IsWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
            Architecture = $architecture
            Is64BitProcess = [Environment]::Is64BitProcess
            PowerShellVersion = $PSVersionTable.PSVersion
            PSEdition = $edition
        }
    }
    $version = [version]$environment.PowerShellVersion
    $supported = ($environment.IsWindows -is [bool] -and $environment.IsWindows -and
        $environment.Architecture -eq 'AMD64' -and
        $environment.Is64BitProcess -is [bool] -and $environment.Is64BitProcess -and
        $environment.PSEdition -eq 'Desktop' -and
        $version -ge [version]'5.1' -and $version.Major -eq 5)
    if (-not $supported) {
        Add-Check 'Environment' 'UnsupportedEnvironment' $true '' 'Windows x64 and 64-bit Windows PowerShell 5.1 are required.' 'Open 64-bit Windows PowerShell 5.1 on Windows x64, then rerun.'
        return (New-PrerequisiteResult)
    }
    Add-Check 'Environment' 'Present' $true '' 'Windows x64 / Windows PowerShell 5.1 environment reported.' ''
} catch {
    Add-Check 'Environment' 'EnvironmentProbeFailed' $true '' 'Environment probe failed or returned an invalid result.' 'Use the default environment probe in 64-bit Windows PowerShell 5.1.'
    return (New-PrerequisiteResult)
}

$repo = Test-InputPath 'RepoRoot' $RepoRoot $true -NextStep 'Set -RepoRoot to the absolute path of a complete source checkout.'
if ($null -ne $repo) {
    $sourceFiles = @('product/gs-product.ps1')
    foreach ($module in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
        foreach ($extension in @('psd1', 'psm1')) {
            $sourceFiles += ('src/{0}/{0}.{1}' -f $module, $extension)
        }
    }
    if ($Mode -eq 'Build') {
        $sourceFiles += @('scripts/build-product.ps1', 'scripts/GsBuildPreflight.ps1',
            'installer/GsController.wxs', 'LICENSE', 'LICENSING.md')
    }
    foreach ($relative in $sourceFiles) {
        $null = Test-InputPath ('Source:' + $relative) (Join-Path $repo $relative) $true 'Leaf' 'Restore the missing source file from the intended repository revision.'
    }
}

$runtimeRequired = ($Mode -eq 'Build' -or -not [string]::IsNullOrWhiteSpace($RuntimeBundleDir))
$runtime = Test-InputPath 'RuntimeBundleDir' $RuntimeBundleDir $runtimeRequired -NextStep 'For streaming/builds, obtain a lawful compatible runtime from its supplier and pass -RuntimeBundleDir explicitly. No public download is documented.'
if ($null -ne $runtime) {
    # Public filename contract: GsRuntime.psm1 BundleHelpers and the two DLLs
    # required by Install-GsRuntimeBundle. Never read or execute these files.
    $runtimeFiles = @(
        'gs_start_private.ps1', 'gs_stop_private.ps1', 'gs_start_with_hook.ps1',
        'gs_supervisor.ps1', 'gs_grant_pipe_acl.ps1', 'gs_process_identity.ps1',
        'gs_launcher.py', 'inject_nvstreamer.py', 'patch_applist_mem.py',
        'gs_nsc_supported.py', 'gs_mdns_probe.py',
        'NvStreamerBusHook.dll', 'GsStreamGuard.dll'
    )
    foreach ($name in $runtimeFiles) {
        $null = Test-InputPath ('Runtime:' + $name) (Join-Path $runtime $name) $true 'Leaf' 'Ask the runtime supplier for the complete compatible bundle; do not substitute mock files.'
    }
}

$componentsRequired = -not [string]::IsNullOrWhiteSpace($ComponentSourceDir)
$components = Test-InputPath 'ComponentSourceDir' $ComponentSourceDir $componentsRequired -NextStep 'Before deployment, supply your own lawfully obtained component tree with -ComponentSourceDir.'
if ($null -ne $components) {
    # Public component catalog layout only. No recursive enumeration or hashing.
    foreach ($relative in @('NvContainer/NvContainer.exe', 'GSRoot/LocalSystem/NvMessageBusBroadcast.dll.disabled')) {
        $null = Test-InputPath ('Component:' + $relative) (Join-Path $components $relative) $true 'Leaf' 'Supply the component tree expected by New-GsComponentCatalog; review its license separately.'
    }
    foreach ($relative in @('GSRoot/LocalSystem', 'GSRoot/NetworkService', 'NvStreamSrv/Plugins/SSAU')) {
        $null = Test-InputPath ('Component:' + $relative) (Join-Path $components $relative) $true 'Container' 'Supply the component tree expected by New-GsComponentCatalog; review its license separately.'
    }
}

if ($Mode -eq 'Build') {
    $wix = Test-InputPath 'WixDir' $WixDir $true -NextStep 'Obtain WiX Toolset 3.14 separately and pass the directory containing heat.exe, candle.exe and light.exe with -WixDir.'
    if ($null -ne $wix) {
        foreach ($name in @('heat.exe', 'candle.exe', 'light.exe')) {
            $null = Test-InputPath ('WiX:' + $name) (Join-Path $wix $name) $true 'Leaf' 'Supply all three WiX 3.14 tools. This check does not execute or verify their version.'
        }
    }
} else {
    Add-Check 'WiX' 'NotRequired' $false '' 'WiX is not checked in Source mode, even when -WixDir is supplied.' ''
}
New-PrerequisiteResult
