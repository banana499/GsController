#Requires -Version 5.1
<#
.SYNOPSIS
    Synthetic prerequisite tests. No real runtime, tools, hardware or product
    actions are used. Fixtures exist only below a unique temporary directory.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checker = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Test-GsPrerequisites.ps1'
$script:Passed = 0
$script:Failed = 0
$workDir = Join-Path ([IO.Path]::GetTempPath()) ('GsPrerequisite_' + [guid]::NewGuid().ToString('N'))
$goodEnvironment = {
    [pscustomobject]@{ IsWindows = $true; Architecture = 'AMD64'; Is64BitProcess = $true; PowerShellVersion = '5.1'; PSEdition = 'Desktop' }
}
function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name :: $($_.Exception.Message)" }
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Code {
    param($Result, [string]$Code)
    Assert-True (@($Result.Errors | Where-Object { $_.Code -eq $Code }).Count -gt 0) "Expected $Code"
}
function New-FixtureFile {
    param([string]$Path)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    [IO.File]::WriteAllText($Path, 'throw "Synthetic fixture must never execute"', [Text.Encoding]::ASCII)
}
function New-Fixture {
    $base = Join-Path $workDir ([guid]::NewGuid().ToString('N') + ' custom paths [literal]')
    $repo = Join-Path $base 'source checkout'
    $runtime = Join-Path $base 'external helpers'
    $components = Join-Path $base 'user components'
    $wix = Join-Path $base 'wix tools'
    foreach ($relative in @('product/gs-product.ps1', 'scripts/build-product.ps1',
        'scripts/GsBuildPreflight.ps1', 'installer/GsController.wxs', 'LICENSE', 'LICENSING.md')) {
        New-FixtureFile (Join-Path $repo $relative)
    }
    foreach ($module in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
        foreach ($extension in @('psd1', 'psm1')) { New-FixtureFile (Join-Path $repo ('src/{0}/{0}.{1}' -f $module, $extension)) }
    }
    foreach ($name in @('gs_start_private.ps1', 'gs_stop_private.ps1', 'gs_start_with_hook.ps1',
        'gs_supervisor.ps1', 'gs_grant_pipe_acl.ps1', 'gs_process_identity.ps1',
        'gs_launcher.py', 'inject_nvstreamer.py', 'patch_applist_mem.py',
        'gs_nsc_supported.py', 'gs_mdns_probe.py', 'NvStreamerBusHook.dll', 'GsStreamGuard.dll')) {
        New-FixtureFile (Join-Path $runtime $name)
    }
    foreach ($relative in @('NvContainer/NvContainer.exe', 'GSRoot/LocalSystem/NvMessageBusBroadcast.dll.disabled')) {
        New-FixtureFile (Join-Path $components $relative)
    }
    foreach ($relative in @('GSRoot/NetworkService', 'NvStreamSrv/Plugins/SSAU')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $components $relative) -Force
    }
    foreach ($name in @('heat.exe', 'candle.exe', 'light.exe')) { New-FixtureFile (Join-Path $wix $name) }
    return @{ RepoRoot = $repo; RuntimeBundleDir = $runtime; ComponentSourceDir = $components; WixDir = $wix; EnvironmentProbe = $goodEnvironment }
}

try {
    $null = New-Item -ItemType Directory -Path $workDir
    Invoke-Test 'Source succeeds without external dependencies or WiX' {
        $f = New-Fixture
        $r = & $checker -RepoRoot $f.RepoRoot -EnvironmentProbe $goodEnvironment
        Assert-True $r.Success 'source prerequisite result'
        Assert-True ($r.Errors.Count -eq 0) 'no fatal errors'
        Assert-True (@($r.Data.Checks | Where-Object { $_.Status -eq 'MissingDependency' }).Count -eq 2) 'runtime/components absence visible'
        Assert-True ($r.Data.NextSteps.Count -eq 2) 'actionable optional dependency steps'
    }
    Invoke-Test 'Custom paths with spaces and literal brackets succeed' {
        $f = New-Fixture
        $r = & $checker @f
        Assert-True $r.Success 'all synthetic metadata present'
        Assert-True (@($r.Data.Checks | Where-Object { $_.Path -eq $f.RuntimeBundleDir }).Count -eq 1) 'explicit runtime path used'
    }
    Invoke-Test 'Structured result never claims runtime or security validation' {
        $f = New-Fixture
        $output = @(& $checker @f)
        Assert-True ($output.Count -eq 1) 'only one pipeline object'
        $r = $output[0]
        Assert-True ($r.Success -is [bool]) 'boolean success'
        Assert-True ($r.Errors -is [array]) 'errors is always an array'
        Assert-True ($r.Data.MetadataOnly -and $r.Data.EnvironmentSimulated) 'scope and injection visible'
        Assert-True (-not $r.Data.RuntimeValidated -and -not $r.Data.SecurityValidated) 'acceptance remains false'
        $roundtrip = $r | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        Assert-True ($roundtrip.Data.Checks.Count -gt 10) 'JSON shape preserved'
    }
    Invoke-Test 'Build requires explicit runtime and WiX' {
        $f = New-Fixture
        $r = & $checker -RepoRoot $f.RepoRoot -Mode Build -EnvironmentProbe $goodEnvironment
        Assert-True (-not $r.Success) 'build blocked'
        Assert-Code $r 'MissingDependency'
        Assert-True (@($r.Errors | Where-Object { $_.Field -eq 'WixDir' }).Count -eq 1) 'WiX required'
        Assert-True (@($r.Errors | Where-Object { $_.Field -eq 'RuntimeBundleDir' }).Count -eq 1) 'runtime required'
    }
    Invoke-Test 'Build with complete metadata does not require components' {
        $f = New-Fixture
        $f.Remove('ComponentSourceDir')
        $r = & $checker @f -Mode Build
        Assert-True $r.Success 'components not packaged by build'
    }
    Invoke-Test 'Source ignores even a supplied missing WiX directory' {
        $f = New-Fixture
        $f.WixDir = Join-Path $workDir 'absent wix'
        $r = & $checker @f
        Assert-True $r.Success 'WiX only required for Build'
    }
    foreach ($tool in @('heat.exe', 'candle.exe', 'light.exe')) {
        Invoke-Test "Build rejects missing $tool" {
            $f = New-Fixture
            Remove-Item -LiteralPath (Join-Path $f.WixDir $tool)
            $r = & $checker @f -Mode Build
            Assert-True (-not $r.Success) 'missing WiX tool'
            Assert-Code $r 'MissingDependency'
        }
    }
    foreach ($relative in @('product/gs-product.ps1', 'src/GsControl/GsControl.psd1', 'src/GsLifecycle/GsLifecycle.psm1', 'src/GsRuntime/GsRuntime.psd1')) {
        Invoke-Test "Source rejects missing $relative" {
            $f = New-Fixture
            Remove-Item -LiteralPath (Join-Path $f.RepoRoot $relative)
            $r = & $checker @f
            Assert-True (-not $r.Success) 'missing source input'
            Assert-Code $r 'MissingDependency'
        }
    }
    Invoke-Test 'Build requires installer source but Source does not' {
        $f = New-Fixture
        Remove-Item -LiteralPath (Join-Path $f.RepoRoot 'installer/GsController.wxs')
        Assert-True ((& $checker @f).Success) 'Source independent of installer'
        Assert-True (-not (& $checker @f -Mode Build).Success) 'Build requires installer'
    }
    foreach ($relative in @('scripts/GsBuildPreflight.ps1', 'LICENSE', 'LICENSING.md')) {
        Invoke-Test "Build requires $relative but Source does not" {
            $f = New-Fixture
            $missingPath = Join-Path $f.RepoRoot $relative
            Remove-Item -LiteralPath $missingPath
            Assert-True ((& $checker @f -Mode Source).Success) 'Source contract unchanged'
            $r = & $checker @f -Mode Build
            Assert-True (-not $r.Success) 'Build must reject the missing input'
            Assert-Code $r 'MissingDependency'
            Assert-True ($r.Errors.Count -eq 1) 'only the missing input fails'
            Assert-True ($r.Errors[0].Field -eq ('Source:' + $relative)) 'error identifies the input'
            Assert-True ($r.Errors[0].Path -eq $missingPath) 'error identifies the explicit path'
            Assert-True ($r.Errors[0].NextStep.Length -gt 0) 'repair guidance is present'
        }
    }
    Invoke-Test 'Explicit missing runtime fails with next step' {
        $f = New-Fixture
        $f.RuntimeBundleDir = Join-Path $workDir 'absent runtime'
        $r = & $checker @f
        Assert-True (-not $r.Success) 'explicit dependency not silently ignored'
        Assert-Code $r 'MissingDependency'
        Assert-True ($r.Errors[0].NextStep.Length -gt 0) 'actionable error'
    }
    Invoke-Test 'Every public helper and DLL is required' {
        $f = New-Fixture
        $files = @(Get-ChildItem -LiteralPath $f.RuntimeBundleDir -File)
        foreach ($file in $files) {
            Remove-Item -LiteralPath $file.FullName
            $r = & $checker @f
            Assert-True (-not $r.Success) ('missing ' + $file.Name)
            Assert-Code $r 'MissingDependency'
            New-FixtureFile $file.FullName
        }
        Assert-True ($files.Count -eq 13) 'public bundle fixture count'
    }
    Invoke-Test 'A directory cannot substitute for a required file' {
        $f = New-Fixture
        $path = Join-Path $f.RuntimeBundleDir 'gs_supervisor.ps1'
        Remove-Item -LiteralPath $path
        $null = New-Item -ItemType Directory -Path $path
        Assert-True (-not (& $checker @f).Success) 'requires leaf'
    }
    Invoke-Test 'Missing component layout fails' {
        $f = New-Fixture
        Remove-Item -LiteralPath (Join-Path $f.ComponentSourceDir 'NvContainer/NvContainer.exe')
        Remove-Item -LiteralPath (Join-Path $f.ComponentSourceDir 'GSRoot/NetworkService')
        $r = & $checker @f
        Assert-True (-not $r.Success -and $r.Errors.Count -eq 2) 'both component gaps reported'
    }
    Invoke-Test 'Missing repository returns structured failure' {
        $r = & $checker -RepoRoot (Join-Path $workDir 'absent repo') -EnvironmentProbe $goodEnvironment
        Assert-True (-not $r.Success) 'repo required'
        Assert-Code $r 'MissingDependency'
    }
    Invoke-Test 'Relative paths are rejected instead of guessed' {
        $r = & $checker -RepoRoot 'relative checkout' -EnvironmentProbe $goodEnvironment
        Assert-Code $r 'InvalidPath'
    }
    foreach ($path in @('C:drive-relative', '\root-relative')) {
        Invoke-Test "Ambiguous path is rejected: $path" {
            $r = & $checker -RepoRoot $path -EnvironmentProbe $goodEnvironment
            Assert-Code $r 'InvalidPath'
        }
    }
    Invoke-Test 'Empty repository is a missing dependency' {
        $r = & $checker -RepoRoot '' -EnvironmentProbe $goodEnvironment
        Assert-Code $r 'MissingDependency'
    }
    foreach ($case in @('NonWindows', 'ARM64', 'x86', '32BitProcess', 'OldPowerShell', 'Core')) {
        Invoke-Test "Unsupported environment: $case" {
            $envResult = & $goodEnvironment
            switch ($case) {
                'NonWindows' { $envResult.IsWindows = $false }
                'ARM64' { $envResult.Architecture = 'ARM64' }
                'x86' { $envResult.Architecture = 'x86' }
                '32BitProcess' { $envResult.Is64BitProcess = $false }
                'OldPowerShell' { $envResult.PowerShellVersion = '5.0' }
                'Core' { $envResult.PowerShellVersion = '7.4'; $envResult.PSEdition = 'Core' }
            }
            $probe = { $envResult }.GetNewClosure()
            $r = & $checker -RepoRoot (Join-Path $workDir 'never inspect') -EnvironmentProbe $probe
            Assert-Code $r 'UnsupportedEnvironment'
            Assert-True ($r.Data.Checks.Count -eq 1) 'unsupported environment stops before filesystem checks'
        }
    }
    Invoke-Test 'Probe exceptions are structured' {
        $r = & $checker -RepoRoot $workDir -EnvironmentProbe { throw 'synthetic probe failure' }
        Assert-Code $r 'EnvironmentProbeFailed'
    }
    Invoke-Test 'Malformed probe fails closed' {
        $r = & $checker -RepoRoot $workDir -EnvironmentProbe { [pscustomobject]@{ IsWindows = 'false' } }
        Assert-Code $r 'EnvironmentProbeFailed'
    }
    Invoke-Test 'External file content is not opened and fixtures stay unchanged' {
        $f = New-Fixture
        $before = @(Get-ChildItem -LiteralPath (Split-Path -Parent $f.RepoRoot) -File -Recurse | ForEach-Object { $_.FullName + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks })
        $handles = New-Object 'System.Collections.Generic.List[object]'
        try {
            foreach ($dir in @($f.RuntimeBundleDir, $f.ComponentSourceDir, $f.WixDir)) {
                foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Recurse)) {
                    $handles.Add([IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None))
                }
            }
            $r = & $checker @f -Mode Build
            Assert-True $r.Success 'locked contents do not affect metadata checks'
        } finally { foreach ($handle in $handles) { $handle.Dispose() } }
        $after = @(Get-ChildItem -LiteralPath (Split-Path -Parent $f.RepoRoot) -File -Recurse | ForEach-Object { $_.FullName + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks })
        Assert-True (@(Compare-Object $before $after).Count -eq 0) 'no file additions, writes or removals'
    }
} finally {
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
Write-Host "Summary: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
exit 0
