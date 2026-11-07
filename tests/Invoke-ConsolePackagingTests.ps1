#Requires -Version 5.1
<#
.SYNOPSIS
    Console packaging completeness tests for scripts\build-product.ps1.

.DESCRIPTION
    Verifies that the product build treats the seven-file local console set
    (gs-console.ps1, gs-console-action.ps1, gs-console.vbs, gs-console.html,
    gs-console.css, gs-console.js, gs-console-strings.zh-CN.json) as required
    inputs, that the check runs BEFORE any directory is created or deleted,
    and that a complete synthetic repository stages the console assets into
    the product stage alongside the pre-existing tray, CLI, license and
    module inputs. It also verifies the independent gs-tray-model.ps1
    dependency (gs-console.ps1 dot-sources it unconditionally at startup)
    and the runtime bundle completeness gate over the shared public 13-file
    contract from scripts\Test-GsPrerequisites.ps1; file presence is a
    metadata completeness gate only and never validates the legitimacy,
    compatibility or runnability of the runtime.

    It also covers the Sunshine build profile: an explicit -RuntimeBundleDir
    is rejected as a contradictory input, the four Sunshine resources
    (gs-sunshine.ps1/html/js/css) are required inputs, a complete Sunshine
    build stages no runtime payload at all, and every build writes a
    generated gs-install-profile.json (schemaVersion 1, lowercase backend)
    that a same-named product-source file can never override.

    Conventions follow tests\Invoke-BuildPreflightTests.ps1: everything runs
    against synthetic repositories under a unique %TEMP% directory with a
    synthetic runtime bundle and fake (csc-compiled) WiX tools. This suite
    never runs msiexec, never reads the real runtime-bundle (the synthetic
    bundle is created inside this suite's own %TEMP% GUID directory), never
    runs the repository build script on its default paths, never signs
    anything and never calls another test suite (no Invoke-All, Stage3,
    Stage12, TvBox, adb). The MSI produced by the fake WiX tools is fake
    output that only proves the pipeline reached its final step; it is not a
    validated installer.

    Exits 0 only when every test passed and at least one test ran; skipped
    tests are counted separately and never count as passes.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:buildScriptPath = Join-Path $repoRoot 'scripts\build-product.ps1'
$script:preflightScriptPath = Join-Path $repoRoot 'scripts\GsBuildPreflight.ps1'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

# A test signals a skip by throwing with this prefix (environment cannot
# run it, e.g. no csc compiler on this machine).
$script:SkipPrefix = 'GSSKIP:'

$script:ConsoleInputNames = @(
    'gs-console.ps1', 'gs-console-action.ps1', 'gs-console.vbs',
    'gs-console.html', 'gs-console.css', 'gs-console.js',
    'gs-console-strings.zh-CN.json'
)
$script:TrayFileNames = @('gs-tray.ps1', 'gs-tray.vbs', 'gs-tray-strings.zh-CN.json', 'gs-tray-model.ps1')
$script:CliFileNames = @('gs-diagnose.ps1', 'gs-support.ps1')
# Sunshine backend resources (frontend list confirmed by worker B): the
# Sunshine profile requires all four; the page reuses gs-console.css, so
# both stylesheets always ship with the stage.
$script:SunshineFileNames = @('gs-sunshine.ps1', 'gs-sunshine.html', 'gs-sunshine.js', 'gs-sunshine.css')
# The public runtime bundle contract shared with scripts\Test-GsPrerequisites.ps1:
# the build rejects a bundle missing any of these names, so the synthetic
# bundle carries all of them and the staged set is asserted verbatim.
$script:BundleFileNames = @(
    'gs_start_private.ps1', 'gs_stop_private.ps1', 'gs_start_with_hook.ps1',
    'gs_supervisor.ps1', 'gs_grant_pipe_acl.ps1', 'gs_process_identity.ps1',
    'gs_launcher.py', 'inject_nvstreamer.py', 'patch_applist_mem.py',
    'gs_nsc_supported.py', 'gs_mdns_probe.py',
    'NvStreamerBusHook.dll', 'GsStreamGuard.dll'
)

function New-ProductSentinel {
    param([Parameter(Mandatory)][string]$Name)
    return ('SENTINEL-PRODUCT ' + $Name + ' synthetic fixture, must never be executed')
}

function New-BundleSentinel {
    param([Parameter(Mandatory)][string]$Name)
    return ('SENTINEL-BUNDLE ' + $Name + ' synthetic fixture, must never be executed')
}

function New-InstallProfileJson {
    param([Parameter(Mandatory)][ValidateSet('legacy', 'sunshine')][string]$Backend)
    return ('{' + "`r`n" +
        '  "schemaVersion": 1,' + "`r`n" +
        ('  "backend": "{0}"' -f $Backend) + "`r`n" +
        '}')
}

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
        $msg = $_.Exception.Message
        if ($null -eq $msg) { $msg = '' }
        if ($msg.StartsWith($script:SkipPrefix)) {
            $script:Skipped++
            Write-Host ("SKIP {0} :: {1}" -f $Name, $msg.Substring($script:SkipPrefix.Length))
        } else {
            $script:Failed++
            Write-Host "FAIL $Name :: $msg"
        }
    }
}

function Skip-Test {
    param([Parameter(Mandatory)][string]$Reason)
    throw ($script:SkipPrefix + $Reason)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Message)
    Assert-True ($Text -ne $null -and $Text.Contains($Expected)) "$Message (expected substring '$Expected' in: $Text)"
}

function Assert-FileContent {
    param([string]$Path, [string]$ExpectedContent, [string]$Message)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "$Message (file missing: $Path)"
    $actual = [IO.File]::ReadAllText($Path)
    Assert-True ($actual -eq $ExpectedContent) "$Message (content differs: $Path)"
}

function Test-FileAscii {
    param([Parameter(Mandatory)][string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "file missing: $Path"
    $bytes = [IO.File]::ReadAllBytes($Path)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 127) { return $false }
    }
    return $true
}

$script:workDir = Join-Path ([IO.Path]::GetTempPath()) ('GsConsolePackaging_' + [guid]::NewGuid().ToString('N'))
$script:LicenseSentinelContent = 'SENTINEL-LICENSE synthetic product license text, not a real license'
$script:LicensingSentinelContent = 'SENTINEL-LICENSING synthetic licensing notice, not a real license'
$script:StageSentinelContent = 'STAGE-SENTINEL-MUST-SURVIVE'
$script:OutputSentinelContent = 'OUTPUT-SENTINEL-MUST-SURVIVE'

try {

    # ------------------------------------------------------------------
    # Synthetic fixtures (all below $script:workDir = %TEMP%\GUID)
    # ------------------------------------------------------------------

    function New-SyntheticRepo {
        param([Parameter(Mandatory)][string]$Name)
        $repo = Join-Path $script:workDir $Name
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        foreach ($d in @('product', 'src\GsControl', 'src\GsLifecycle', 'src\GsRuntime',
                'installer', 'runtime-bundle', 'artifacts', 'scripts')) {
            New-Item -ItemType Directory -Path (Join-Path $repo $d) -Force | Out-Null
        }
        # Complete top-level product set: the seven-file console, the tray
        # entry points and strings, the CLI/diagnose/support tools, the
        # Sunshine backend resources and the required gs-product.ps1 entry.
        foreach ($name in @($script:ConsoleInputNames + $script:TrayFileNames + $script:CliFileNames + $script:SunshineFileNames + @('gs-product.ps1'))) {
            $content = (New-ProductSentinel -Name $name) + "`r`n"
            if ($name -eq 'gs-console-strings.zh-CN.json') {
                $content = '{"syntheticConsoleStrings": true}'
            }
            [IO.File]::WriteAllText((Join-Path $repo "product\$name"), $content)
        }
        foreach ($m in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
            [IO.File]::WriteAllText((Join-Path $repo "src\$m\$m.psd1"), "# synthetic $m psd1`r`n")
            [IO.File]::WriteAllText((Join-Path $repo "src\$m\$m.psm1"), "# synthetic $m psm1`r`n")
        }
        [IO.File]::WriteAllText((Join-Path $repo 'installer\GsController.wxs'), "<Wix></Wix>`r`n")
        Copy-Item -LiteralPath (Join-Path $repoRoot 'installer\GsConsoleShortcut.xsl') -Destination (Join-Path $repo 'installer\GsConsoleShortcut.xsl')
        [IO.File]::WriteAllText((Join-Path $repo 'LICENSE'), ($script:LicenseSentinelContent + "`r`n"))
        [IO.File]::WriteAllText((Join-Path $repo 'LICENSING.md'), ($script:LicensingSentinelContent + "`r`n"))
        # Synthetic runtime bundle created by this suite only: documentation
        # file plus the full public bundle contract (the build ignores
        # README.md when deciding the bundle is non-empty, and rejects the
        # bundle when any public name is missing). The real runtime-bundle is
        # never read or touched.
        [IO.File]::WriteAllText((Join-Path $repo 'runtime-bundle\README.md'), "documentation only`r`n")
        foreach ($name in $script:BundleFileNames) {
            [IO.File]::WriteAllText((Join-Path $repo ("runtime-bundle\" + $name)), ((New-BundleSentinel -Name $name) + "`r`n"))
        }
        Copy-Item -LiteralPath $script:buildScriptPath -Destination (Join-Path $repo 'scripts\build-product.ps1')
        Copy-Item -LiteralPath $script:preflightScriptPath -Destination (Join-Path $repo 'scripts\GsBuildPreflight.ps1')
        # The build reuses the shared public bundle name list from the
        # checker through -DefineOnly, so the synthetic repo carries it too.
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Test-GsPrerequisites.ps1') -Destination (Join-Path $repo 'scripts\Test-GsPrerequisites.ps1')
        return $repo
    }

    function Set-StageSentinel {
        param([Parameter(Mandatory)][string]$RepoRoot)
        $stage = Join-Path $RepoRoot 'artifacts\product-stage'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'SENTINEL.txt'), $script:StageSentinelContent)
    }

    function Set-OutputSentinel {
        param([Parameter(Mandatory)][string]$RepoRoot)
        $out = Join-Path $RepoRoot 'artifacts\msi'
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $out 'OUTPUT-SENTINEL.txt'), $script:OutputSentinelContent)
    }

    function Assert-SentinelsSurvived {
        param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Message)
        $stage = Join-Path $RepoRoot 'artifacts\product-stage'
        Assert-FileContent (Join-Path $stage 'SENTINEL.txt') $script:StageSentinelContent "$Message stage sentinel content intact"
        $stageFiles = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force)
        Assert-True ($stageFiles.Count -eq 1) "$Message stage holds only the sentinel (staging never ran); found $($stageFiles.Count) files"
        Assert-FileContent (Join-Path $RepoRoot 'artifacts\msi\OUTPUT-SENTINEL.txt') $script:OutputSentinelContent "$Message output sentinel content intact"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'artifacts\wix'))) "$Message wix build dir not created"
    }

    # Runs the copied build script in a child powershell process.
    function Invoke-ProductBuild {
        param(
            [Parameter(Mandatory)][string]$RepoRoot,
            [string[]]$Arguments = @()
        )
        $outFile = Join-Path $script:workDir ('stdout-' + [guid]::NewGuid().ToString('N') + '.txt')
        $errFile = Join-Path $script:workDir ('stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
        $argString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
            (Join-Path $RepoRoot 'scripts\build-product.ps1') + '"'
        foreach ($a in $Arguments) {
            $v = $a
            # A trailing backslash would escape the closing quote during
            # native argument parsing; double it.
            if ($v.EndsWith('\')) { $v += '\' }
            $argString += ' "' + ($v -replace '"', '\"') + '"'
        }
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString `
            -WorkingDirectory $RepoRoot `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -WindowStyle Hidden -Wait -PassThru
        $stdout = ''
        if (Test-Path -LiteralPath $outFile) { $stdout = [IO.File]::ReadAllText($outFile) }
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) { $stderr = [IO.File]::ReadAllText($errFile) }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
    }

    # Compiles three fake WiX tools (heat/candle/light) with the .NET
    # Framework csc compiler into a %TEMP% directory (cached). The fake
    # tools create their -out target (file or trailing-backslash directory)
    # and exit 0; they validate nothing, so the resulting MSI is fake output
    # only and never a validated installer.
    $script:fakeWixDir = $null
    function New-FakeWix {
        if ($null -ne $script:fakeWixDir) { return $script:fakeWixDir }
        $dir = Join-Path $script:workDir 'fake-wix'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $cs = @'
using System;
using System.IO;
static class FakeTool
{
    static int Main(string[] args)
    {
        string outPath = null;
        for (int i = 0; i + 1 < args.Length; i++)
        {
            if (string.Equals(args[i], "-out", StringComparison.Ordinal)) { outPath = args[i + 1]; }
        }
        if (!string.IsNullOrEmpty(outPath))
        {
            if (outPath.EndsWith("\\"))
            {
                Directory.CreateDirectory(outPath);
                File.WriteAllText(Path.Combine(outPath, "candle-fake"), "fake candle output\n");
            }
            else
            {
                string dir = Path.GetDirectoryName(outPath);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) { Directory.CreateDirectory(dir); }
                File.WriteAllText(outPath, "fake wix tool output\n");
            }
        }
        return 0;
    }
}
'@
        $csPath = Join-Path $dir 'FakeTool.cs'
        [IO.File]::WriteAllText($csPath, $cs)
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
            $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
        }
        if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
            throw "csc.exe not found; fake WiX tools unavailable"
        }
        foreach ($t in @('heat.exe', 'candle.exe', 'light.exe')) {
            # Build the /out argument as one string: PowerShell splits
            # '/out:(...)' into two arguments at the parenthesis.
            $outArg = '/out:' + (Join-Path $dir $t)
            & $csc /nologo /target:exe $outArg $csPath
            if ($LASTEXITCODE -ne 0) { throw "csc compile failed for $t" }
        }
        $script:fakeWixDir = $dir
        return $dir
    }

    # Returns the fake WiX directory, or throws a skip exception when the
    # compiler is unavailable on this machine.
    function Assert-FakeWixAvailable {
        try {
            return (New-FakeWix)
        } catch {
            Skip-Test -Reason $_.Exception.Message
        }
    }

    # ------------------------------------------------------------------
    # Fixture parity and script hygiene (in-process, read-only)
    # ------------------------------------------------------------------

    Invoke-Test 'fixture parity: the seven required console inputs exist in the real product directory' {
        foreach ($name in $script:ConsoleInputNames) {
            $real = Join-Path $repoRoot ("product\" + $name)
            Assert-True (Test-Path -LiteralPath $real -PathType Leaf) "real product input missing: $real"
        }
    }

    Invoke-Test 'script: build-product.ps1 stays pure ASCII' {
        Assert-True (Test-FileAscii $script:buildScriptPath) 'scripts\build-product.ps1 must be pure ASCII'
    }

    # ------------------------------------------------------------------
    # Required-input gate: every missing console resource is rejected
    # before any create/delete (full build mode, sentinels pre-seeded)
    # ------------------------------------------------------------------

    foreach ($missing in $script:ConsoleInputNames) {
        Invoke-Test "required: missing $missing is rejected before any create or delete" {
            $repo = New-SyntheticRepo 'missing-console-input'
            Remove-Item -LiteralPath (Join-Path $repo ("product\" + $missing)) -Force
            Set-StageSentinel -RepoRoot $repo
            Set-OutputSentinel -RepoRoot $repo
            $wix = Assert-FakeWixAvailable
            # Full mode (no -PreflightOnly): if the input check did not run
            # first, the build would delete the stage and re-stage it.
            $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0',
                '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
            Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
            Assert-Contains $r.StdErr 'Missing input' 'missing input reported'
            Assert-Contains $r.StdErr $missing 'the missing console file is named'
            Assert-SentinelsSurvived -RepoRoot $repo -Message 'early rejection:'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi\GsController-0.2.0.msi'))) 'no fake MSI written'
        }
    }

    Invoke-Test 'required: missing gs-tray-model.ps1 is rejected before any create or delete' {
        # gs-console.ps1 dot-sources gs-tray-model.ps1 unconditionally at
        # startup, so the build requires it in its own right; missing it
        # must abort exactly like a missing console file.
        $repo = New-SyntheticRepo 'missing-tray-model'
        Remove-Item -LiteralPath (Join-Path $repo 'product\gs-tray-model.ps1') -Force
        Set-StageSentinel -RepoRoot $repo
        Set-OutputSentinel -RepoRoot $repo
        $wix = Assert-FakeWixAvailable
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdErr 'Missing input' 'missing input reported'
        Assert-Contains $r.StdErr 'gs-tray-model.ps1' 'the missing tray model file is named'
        Assert-SentinelsSurvived -RepoRoot $repo -Message 'early rejection:'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi\GsController-0.2.0.msi'))) 'no fake MSI written'
    }

    Invoke-Test 'required: a runtime bundle missing a required public file is rejected before any create or delete' {
        # The bundle must carry every name of the shared public contract
        # (scripts\Test-GsPrerequisites.ps1, reused through -DefineOnly);
        # presence is a metadata completeness gate only.
        $repo = New-SyntheticRepo 'missing-bundle-file'
        Remove-Item -LiteralPath (Join-Path $repo 'runtime-bundle\gs_supervisor.ps1') -Force
        Set-StageSentinel -RepoRoot $repo
        Set-OutputSentinel -RepoRoot $repo
        $wix = Assert-FakeWixAvailable
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdErr 'missing 1 required public file(s)' 'the missing count is reported'
        Assert-Contains $r.StdErr 'gs_supervisor.ps1' 'the missing bundle file is named'
        Assert-SentinelsSurvived -RepoRoot $repo -Message 'bundle gate:'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi\GsController-0.2.0.msi'))) 'no fake MSI written'
    }

    Invoke-Test 'required: a missing console input is rejected under -PreflightOnly too' {
        $repo = New-SyntheticRepo 'missing-console-preflight'
        Remove-Item -LiteralPath (Join-Path $repo 'product\gs-console.js') -Force
        Set-StageSentinel -RepoRoot $repo
        Set-OutputSentinel -RepoRoot $repo
        $wix = Assert-FakeWixAvailable
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdErr 'Missing input' 'missing input reported'
        Assert-Contains $r.StdErr 'gs-console.js' 'the missing console file is named'
        Assert-SentinelsSurvived -RepoRoot $repo -Message 'preflight-only rejection:'
    }

    Invoke-Test 'required: a directory cannot substitute for a console input' {
        $repo = New-SyntheticRepo 'console-input-is-directory'
        $victim = Join-Path $repo 'product\gs-console.html'
        Remove-Item -LiteralPath $victim -Force
        New-Item -ItemType Directory -Path $victim -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $victim 'inner.txt'), 'a directory must not pass the leaf check')
        Set-StageSentinel -RepoRoot $repo
        Set-OutputSentinel -RepoRoot $repo
        $wix = Assert-FakeWixAvailable
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdErr 'Missing input' 'missing input reported'
        Assert-Contains $r.StdErr 'gs-console.html' 'the substituted console file is named'
        Assert-SentinelsSurvived -RepoRoot $repo -Message 'directory substitution:'
    }

    # ------------------------------------------------------------------
    # Packaging with complete inputs (fake WiX tools; fake MSI is output
    # evidence only, never a validated installer)
    # ------------------------------------------------------------------

    Invoke-Test 'packaging: complete inputs stage the console set with tray, CLI, licenses and modules' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'complete-packaging'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stderr: {1}; stdout: {2}" -f $r.ExitCode, $r.StdErr, $r.StdOut)
        Assert-Contains $r.StdOut 'Staged ' 'staged line'
        Assert-Contains $r.StdOut 'MSI built:' 'MSI built line'
        $stage = Join-Path $repo 'artifacts\product-stage'
        # Every console asset staged verbatim at the stage root.
        foreach ($name in $script:ConsoleInputNames) {
            $expected = (New-ProductSentinel -Name $name) + "`r`n"
            if ($name -eq 'gs-console-strings.zh-CN.json') { $expected = '{"syntheticConsoleStrings": true}' }
            Assert-FileContent (Join-Path $stage $name) $expected ("console asset staged verbatim: " + $name)
        }
        # Pre-existing product inputs still staged alongside.
        foreach ($name in @($script:TrayFileNames + $script:CliFileNames + @('gs-product.ps1'))) {
            Assert-FileContent (Join-Path $stage $name) ((New-ProductSentinel -Name $name) + "`r`n") ("product file staged verbatim: " + $name)
        }
        Assert-FileContent (Join-Path $stage 'LICENSE') ($script:LicenseSentinelContent + "`r`n") 'LICENSE staged byte-for-byte'
        Assert-FileContent (Join-Path $stage 'LICENSING.md') ($script:LicensingSentinelContent + "`r`n") 'LICENSING.md staged byte-for-byte'
        foreach ($m in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
            foreach ($ext in @('psd1', 'psm1')) {
                Assert-True (Test-Path -LiteralPath (Join-Path $stage "Modules\$m\$m.$ext") -PathType Leaf) "module staged: $m.$ext"
            }
        }
        # The synthetic runtime bundle is staged verbatim into bin\.
        foreach ($name in $script:BundleFileNames) {
            Assert-FileContent (Join-Path $stage ("bin\" + $name)) ((New-BundleSentinel -Name $name) + "`r`n") ("runtime bundle file staged verbatim: " + $name)
        }
        # The fake tools must not have consumed or modified any source input.
        Assert-FileContent (Join-Path $repo 'product\gs-console.ps1') ((New-ProductSentinel -Name 'gs-console.ps1') + "`r`n") 'console source preserved'
        Assert-FileContent (Join-Path $repo 'runtime-bundle\gs_supervisor.ps1') ((New-BundleSentinel -Name 'gs_supervisor.ps1') + "`r`n") 'bundle source preserved'
        # Fake MSI: proof the pipeline reached its final step only.
        Assert-True (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi\GsController-0.2.0.msi') -PathType Leaf) 'fake MSI output exists (fake tool output, not a validated installer)'
    }

    Invoke-Test 'packaging: -PreflightOnly passes with complete inputs and creates nothing' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'complete-preflight'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0', '-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stderr: {1}; stdout: {2}" -f $r.ExitCode, $r.StdErr, $r.StdOut)
        Assert-Contains $r.StdOut 'PREFLIGHT OK: all checks passed' 'PREFLIGHT OK line'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\product-stage'))) 'stage not created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi'))) 'output not created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\wix'))) 'wixbuild not created'
    }

    # ------------------------------------------------------------------
    # Sunshine profile: contradictory inputs, its own required resource
    # set, staging without any runtime payload, and the install profile.
    # ------------------------------------------------------------------

    Invoke-Test 'sunshine: an explicit runtime bundle with the Sunshine profile is rejected before any create or delete' {
        $repo = New-SyntheticRepo 'sunshine-explicit-runtime'
        Set-StageSentinel -RepoRoot $repo
        Set-OutputSentinel -RepoRoot $repo
        $wix = Assert-FakeWixAvailable
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0', '-RuntimeProfile', 'Sunshine',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdErr 'Conflicting input' 'the contradiction is reported'
        Assert-Contains $r.StdErr 'Sunshine' 'the profile is named'
        Assert-SentinelsSurvived -RepoRoot $repo -Message 'sunshine conflict gate:'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi\GsController-Sunshine-0.2.0.msi'))) 'no fake MSI written'
    }

    foreach ($missing in $script:SunshineFileNames) {
        Invoke-Test "sunshine: missing $missing is rejected before any create or delete" {
            $repo = New-SyntheticRepo 'missing-sunshine-input'
            Remove-Item -LiteralPath (Join-Path $repo ("product\" + $missing)) -Force
            Set-StageSentinel -RepoRoot $repo
            Set-OutputSentinel -RepoRoot $repo
            $wix = Assert-FakeWixAvailable
            # Full mode, Sunshine profile, and NO -RuntimeBundleDir: the
            # Sunshine build has no runtime input at all.
            $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0', '-RuntimeProfile', 'Sunshine',
                '-WixDir', $wix)
            Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
            Assert-Contains $r.StdErr 'Missing input' 'missing input reported'
            Assert-Contains $r.StdErr $missing 'the missing Sunshine file is named'
            Assert-SentinelsSurvived -RepoRoot $repo -Message 'sunshine required gate:'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi\GsController-Sunshine-0.2.0.msi'))) 'no fake MSI written'
        }
    }

    Invoke-Test 'sunshine: a missing Sunshine resource is rejected under -PreflightOnly and creates nothing' {
        $repo = New-SyntheticRepo 'missing-sunshine-preflight'
        Remove-Item -LiteralPath (Join-Path $repo 'product\gs-sunshine.js') -Force
        $wix = Assert-FakeWixAvailable
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly', '-RuntimeProfile', 'Sunshine',
            '-WixDir', $wix)
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdErr 'Missing input' 'missing input reported'
        Assert-Contains $r.StdErr 'gs-sunshine.js' 'the missing Sunshine file is named'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\product-stage'))) 'stage not created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi'))) 'output not created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\wix'))) 'wixbuild not created'
    }

    Invoke-Test 'sunshine: complete Sunshine build stages the sunshine set and the generated install profile with no runtime payload' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'complete-sunshine'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0', '-RuntimeProfile', 'Sunshine',
            '-WixDir', $wix)
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stderr: {1}; stdout: {2}" -f $r.ExitCode, $r.StdErr, $r.StdOut)
        Assert-Contains $r.StdOut 'Staged ' 'staged line'
        Assert-Contains $r.StdOut 'MSI built:' 'MSI built line'
        $stage = Join-Path $repo 'artifacts\product-stage'
        # Every Sunshine resource staged verbatim at the stage root.
        foreach ($name in $script:SunshineFileNames) {
            Assert-FileContent (Join-Path $stage $name) ((New-ProductSentinel -Name $name) + "`r`n") ("Sunshine resource staged verbatim: " + $name)
        }
        # The generated install profile binds the MSI to the Sunshine
        # backend.
        Assert-FileContent (Join-Path $stage 'gs-install-profile.json') (New-InstallProfileJson -Backend 'sunshine') 'Sunshine install profile generated verbatim'
        # No runtime payload anywhere: no bin directory, no bundle file.
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage 'bin'))) 'no bin directory in a Sunshine stage'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stage 'gs_supervisor.ps1'))) 'no bundle payload in a Sunshine stage'
        # The pre-existing product inputs are still staged alongside.
        Assert-FileContent (Join-Path $stage 'gs-console.vbs') ((New-ProductSentinel -Name 'gs-console.vbs') + "`r`n") 'console launcher staged verbatim'
        Assert-FileContent (Join-Path $stage 'gs-tray-model.ps1') ((New-ProductSentinel -Name 'gs-tray-model.ps1') + "`r`n") 'tray model staged verbatim'
        Assert-FileContent (Join-Path $stage 'LICENSE') ($script:LicenseSentinelContent + "`r`n") 'LICENSE staged byte-for-byte'
        foreach ($m in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $stage "Modules\$m\$m.psd1") -PathType Leaf) "module staged: $m.psd1"
        }
        # Sources preserved.
        Assert-FileContent (Join-Path $repo 'product\gs-sunshine.ps1') ((New-ProductSentinel -Name 'gs-sunshine.ps1') + "`r`n") 'Sunshine source preserved'
        # The fake MSI is output evidence only, never a validated installer;
        # the Sunshine profile carries its own artifact name.
        Assert-True (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi\GsController-Sunshine-0.2.0.msi') -PathType Leaf) 'fake MSI output exists under the Sunshine artifact name'
    }

    Invoke-Test 'profile: the Legacy build generates a legacy install profile and a product-source file cannot override it' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'legacy-profile'
        [IO.File]::WriteAllText((Join-Path $repo 'product\gs-install-profile.json'), '{"backend": "decoy"}')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stderr: {1}" -f $r.ExitCode, $r.StdErr)
        Assert-FileContent (Join-Path $repo 'artifacts\product-stage\gs-install-profile.json') (New-InstallProfileJson -Backend 'legacy') 'the generated Legacy profile wins over the product-source decoy'
        Assert-FileContent (Join-Path $repo 'product\gs-install-profile.json') '{"backend": "decoy"}' 'the product-source decoy itself is preserved'
    }

    Invoke-Test 'sunshine: -PreflightOnly passes with the Sunshine profile and creates nothing' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'complete-sunshine-preflight'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0', '-PreflightOnly',
            '-RuntimeProfile', 'Sunshine', '-WixDir', $wix)
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stderr: {1}; stdout: {2}" -f $r.ExitCode, $r.StdErr, $r.StdOut)
        Assert-Contains $r.StdOut 'PREFLIGHT OK: all checks passed' 'PREFLIGHT OK line'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\product-stage'))) 'stage not created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi'))) 'output not created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\wix'))) 'wixbuild not created'
    }

} finally {
    if ([string]::IsNullOrWhiteSpace($script:workDir) -or -not (Test-Path -LiteralPath $script:workDir)) {
        # Nothing to clean.
    } else {
        Remove-Item -LiteralPath $script:workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ("Summary: {0} passed, {1} failed, {2} skipped" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
