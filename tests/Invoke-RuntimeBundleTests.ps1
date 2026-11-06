#Requires -Version 5.1
<#
.SYNOPSIS
    Runtime bundle packaging tests for GsRuntime (Install-GsRuntimeBundle and
    Test-GsRuntimeBundle). Synthetic helper files under %TEMP% only; never
    touches an installed product. Exits 0 only when every test passes.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot 'src\GsRuntime\GsRuntime.psd1'

$script:Passed = 0
$script:Failed = 0

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
        $script:Failed++
        Write-Host "FAIL $Name :: $($_.Exception.Message)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

try {
    Import-Module $manifestPath -Force -ErrorAction Stop
} catch {
    Write-Host "FAIL module import :: $($_.Exception.Message)"
    exit 1
}

$helpers = @('gs_start_private.ps1', 'gs_stop_private.ps1', 'gs_start_with_hook.ps1', 'gs_supervisor.ps1',
    'gs_grant_pipe_acl.ps1', 'gs_process_identity.ps1', 'gs_launcher.py', 'inject_nvstreamer.py',
    'patch_applist_mem.py', 'gs_nsc_supported.py', 'gs_mdns_probe.py')

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('GsRuntimeBundle_' + [guid]::NewGuid().ToString('N'))

function New-TestLayout {
    param([string]$Name)
    $base = Join-Path $workDir $Name
    $r = New-GsRuntimeLayout -InstallDir (Join-Path $base 'install') -StateDir (Join-Path $base 'state') -LogDir (Join-Path $base 'logs') -ComponentSourceDir (Join-Path $base 'components')
    if (-not $r.Success) { throw ('layout failed: ' + ($r.Errors | Out-String)) }
    return $r.Layout
}

function New-HelperSource {
    param([string]$Name, [string[]]$Skip = @(), [switch]$NoGuard)
    $src = Join-Path $workDir ($Name + '-source')
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    foreach ($h in $helpers) {
        if ($Skip -contains $h) { continue }
        [System.IO.File]::WriteAllText((Join-Path $src $h), '# synthetic helper')
    }
    [System.IO.File]::WriteAllBytes((Join-Path $src 'NvStreamerBusHook.dll'), [byte[]](1, 2, 3, 4))
    if (-not $NoGuard) { [System.IO.File]::WriteAllBytes((Join-Path $src 'GsStreamGuard.dll'), [byte[]](5, 6, 7, 8)) }
    return $src
}

try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    Invoke-Test 'Install-GsRuntimeBundle copies the process identity helper and the stream guard byte for byte' {
        $layout = New-TestLayout 'full'
        $r = Install-GsRuntimeBundle -Layout $layout -HelperSourceDir (New-HelperSource 'full') -Force
        Assert-True $r.Success ('install failed: ' + ($r.Errors | Out-String))
        Assert-True (Test-Path -LiteralPath (Join-Path $layout.RuntimeBinDir 'gs_process_identity.ps1')) 'gs_process_identity.ps1 copied'
        $guard = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes((Join-Path $layout.RuntimeBinDir 'GsStreamGuard.dll')))
        Assert-True ($guard -eq '05-06-07-08') ('guard bytes preserved, got ' + $guard)
        $check = Test-GsRuntimeBundle -Layout $layout
        Assert-True $check.Success ('bundle check failed: ' + ($check.Errors | Out-String))
    }

    Invoke-Test 'Install-GsRuntimeBundle refuses a source without gs_process_identity.ps1' {
        $layout = New-TestLayout 'noidentity'
        $r = Install-GsRuntimeBundle -Layout $layout -HelperSourceDir (New-HelperSource 'noidentity' -Skip 'gs_process_identity.ps1') -Force
        Assert-True (-not $r.Success) 'install must fail'
        Assert-True (@($r.Errors | Where-Object { $_.Code -eq 'HelperMissing' -and $_.Message -like '*gs_process_identity.ps1*' }).Count -eq 1) 'HelperMissing names gs_process_identity.ps1'
    }

    Invoke-Test 'Install-GsRuntimeBundle refuses a source without GsStreamGuard.dll before copying anything' {
        $layout = New-TestLayout 'noguard'
        $r = Install-GsRuntimeBundle -Layout $layout -HelperSourceDir (New-HelperSource 'noguard' -NoGuard) -Force
        Assert-True (-not $r.Success) 'install must fail'
        Assert-True (@($r.Errors | Where-Object { $_.Code -eq 'HelperMissing' -and $_.Message -like '*GsStreamGuard.dll*' }).Count -eq 1) 'HelperMissing names GsStreamGuard.dll'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.RuntimeBinDir 'NvStreamerBusHook.dll'))) 'no hook DLL copied'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $layout.RuntimeBinDir 'gs_supervisor.ps1'))) 'no helper script copied'
    }

    Invoke-Test 'Install-GsRuntimeBundle without -Force refuses an existing GsStreamGuard.dll' {
        $layout = New-TestLayout 'noforce'
        $src = New-HelperSource 'noforce'
        $first = Install-GsRuntimeBundle -Layout $layout -HelperSourceDir $src -Force
        Assert-True $first.Success 'first install'
        $second = Install-GsRuntimeBundle -Layout $layout -HelperSourceDir $src
        Assert-True (-not $second.Success) 'second install without -Force must fail'
        Assert-True (@($second.Errors | Where-Object { $_.Code -eq 'AlreadyExists' -and $_.Message -like '*GsStreamGuard.dll*' }).Count -eq 1) 'AlreadyExists names GsStreamGuard.dll'
    }

    Invoke-Test 'Test-GsRuntimeBundle reports a missing GsStreamGuard.dll' {
        $layout = New-TestLayout 'check'
        $r = Install-GsRuntimeBundle -Layout $layout -HelperSourceDir (New-HelperSource 'check') -Force
        Assert-True $r.Success 'install'
        Remove-Item -LiteralPath (Join-Path $layout.RuntimeBinDir 'GsStreamGuard.dll') -Force
        $check = Test-GsRuntimeBundle -Layout $layout
        Assert-True (-not $check.Success) 'check must fail'
        Assert-True (@($check.Errors | Where-Object { $_.Code -eq 'BundleFileMissing' -and $_.Field -eq 'runtimeBinDir' }).Count -eq 1) 'BundleFileMissing for runtimeBinDir'
    }
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
