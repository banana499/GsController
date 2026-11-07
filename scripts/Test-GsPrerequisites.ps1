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
.PARAMETER DefineOnly
    Only defines the script's functions (including the shared public bundle
    file-name contract) and returns immediately. No check runs, no path is
    inspected and no output is produced. Dot-sourcing with this switch lets
    scripts\build-product.ps1 reuse Get-GsPublicBundleFileNames without
    duplicating the list.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RepoRoot,
    [string]$RuntimeBundleDir = '',
    [string]$ComponentSourceDir = '',
    [string]$WixDir = '',
    [ValidateSet('Source', 'Build')][string]$Mode = 'Source',
    # Must agree with the build profile: Legacy (default) requires the
    # runtime bundle in Build mode; Sunshine never requires, enumerates or
    # reads it, and an explicitly supplied -RuntimeBundleDir is a
    # contradictory input.
    [ValidateSet('Legacy', 'Sunshine')][string]$RuntimeProfile = 'Legacy',
    [scriptblock]$EnvironmentProbe,
    [switch]$DefineOnly
)

# Single shared list of the public runtime bundle file names. Both this
# checker's Build mode and scripts\build-product.ps1 require exactly these
# names. Presence is a metadata completeness gate only; it never establishes
# authenticity, compatibility, licensing or runnability of the runtime,
# which stays an external, opaque dependency.
function Get-GsPublicBundleFileNames {
    return @(
        'gs_start_private.ps1', 'gs_stop_private.ps1', 'gs_start_with_hook.ps1',
        'gs_supervisor.ps1', 'gs_grant_pipe_acl.ps1', 'gs_process_identity.ps1',
        'gs_launcher.py', 'inject_nvstreamer.py', 'patch_applist_mem.py',
        'gs_nsc_supported.py', 'gs_mdns_probe.py',
        'NvStreamerBusHook.dll', 'GsStreamGuard.dll'
    )
}

if ($DefineOnly) { return }

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
        # The product build rejects an incomplete local console set, so a
        # build-mode prerequisite check must flag the same seven files.
        $sourceFiles += @('product/gs-console.ps1', 'product/gs-console-action.ps1',
            'product/gs-console.vbs', 'product/gs-console.html', 'product/gs-console.css',
            'product/gs-console.js', 'product/gs-console-strings.zh-CN.json')
        # gs-console.ps1 dot-sources gs-tray-model.ps1 unconditionally at
        # startup; it is an independent build dependency, not part of the
        # console file set.
        $sourceFiles += 'product/gs-tray-model.ps1'
        if ($RuntimeProfile -eq 'Sunshine') {
            # Sunshine-profile build (frontend resource list confirmed by
            # worker B): the backend plus the three page assets must all be
            # present; gs-sunshine.css builds on the shared gs-console.css.
            $sourceFiles += @('product/gs-sunshine.ps1', 'product/gs-sunshine.html',
                'product/gs-sunshine.js', 'product/gs-sunshine.css')
        }
        $sourceFiles += @('scripts/build-product.ps1', 'scripts/GsBuildPreflight.ps1',
            'scripts/Test-GsPrerequisites.ps1',
            'installer/GsController.wxs', 'installer/GsConsoleShortcut.xsl',
            'LICENSE', 'LICENSING.md')
    }
    foreach ($relative in $sourceFiles) {
        $null = Test-InputPath ('Source:' + $relative) (Join-Path $repo $relative) $true 'Leaf' 'Restore the missing source file from the intended repository revision.'
    }
}

# Sunshine profile agreement: Sunshine consumes neither the private runtime
# bundle nor the NVIDIA self-provided component tree. An explicitly supplied
# legacy dependency contradicts the profile and is refused with a structured
# error - never probed, never silently checked. Without them the two inputs
# are reported as NotRequired with an empty NextStep (no preparation
# advice). Source mode keeps its original semantics under the default
# Legacy profile.
$sunshineProfile = ($RuntimeProfile -eq 'Sunshine')
if ($sunshineProfile) {
    foreach ($legacyDependency in @(
            @{ Name = 'RuntimeBundleDir'; Value = $RuntimeBundleDir; What = 'runtime bundle' },
            @{ Name = 'ComponentSourceDir'; Value = $ComponentSourceDir; What = 'self-provided component tree' })) {
        if (-not [string]::IsNullOrWhiteSpace($legacyDependency.Value)) {
            Add-Check $legacyDependency.Name 'InvalidPath' $true $legacyDependency.Value `
                ('The Sunshine profile does not consume the private {0}; supplying it contradicts the profile.' -f $legacyDependency.What) `
                'Remove the parameter, or select -RuntimeProfile Legacy.'
        }
    }
    $contradictions = @($checks | Where-Object {
        ($_.Name -eq 'RuntimeBundleDir' -or $_.Name -eq 'ComponentSourceDir') -and $_.Status -eq 'InvalidPath'
    })
    if ($contradictions.Count -eq 0) {
        Add-Check 'RuntimeBundleDir' 'NotRequired' $false '' 'Sunshine profile: no private runtime bundle is consumed.' ''
        Add-Check 'ComponentSourceDir' 'NotRequired' $false '' 'Sunshine profile: no self-provided component tree is consumed.' ''
    }
} else {
    $runtimeRequired = ($Mode -eq 'Build' -or -not [string]::IsNullOrWhiteSpace($RuntimeBundleDir))
    $runtime = Test-InputPath 'RuntimeBundleDir' $RuntimeBundleDir $runtimeRequired -NextStep 'For streaming/builds, obtain a lawful compatible runtime from its supplier and pass -RuntimeBundleDir explicitly. No public download is documented.'
    if ($null -ne $runtime) {
        # Public filename contract: GsRuntime.psm1 BundleHelpers and the two DLLs
        # required by Install-GsRuntimeBundle. Never read or execute these files.
        # The list is the shared Get-GsPublicBundleFileNames contract.
        foreach ($name in (Get-GsPublicBundleFileNames)) {
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
