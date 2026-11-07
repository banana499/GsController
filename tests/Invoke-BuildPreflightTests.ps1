#Requires -Version 5.1
<#
.SYNOPSIS
    Build preflight tests for scripts\build-product.ps1 and
    scripts\GsBuildPreflight.ps1.

.DESCRIPTION
    Everything runs against synthetic repositories under %TEMP% with fake
    runtime bundles and fake (csc-compiled) WiX tools. This suite never
    touches the real runtime bundle, never runs the repository build script
    on its default paths, never runs msiexec, never signs anything and never
    runs the forbidden suites (Invoke-All, Stage3, Stage12, TvBox).

    Verified properties:
      - invalid MSI versions fail as a structured violation before any
        deletion (no overflow exceptions);
      - dangerous overlaps (equal / ancestor / descendant, exact, case,
        trailing separator, relative, junction-based) fail before any
        deletion and sentinel input content is preserved;
      - normal fixture paths pass and a full run with fake WiX tools reaches
        the expected staging and output steps with inputs preserved;
      - the baseline build script (pre-preflight) exhibits the old flaws:
        it accepts an out-of-range version and an overlap configuration
        destroys inputs.
    Exits 0 only when every test passes.
#>
[CmdletBinding()]
param(
    # Baseline commit whose scripts\build-product.ps1 is used for the
    # old-behavior evidence tests. Set to '' to skip them.
    [string]$BaselineCommit = '0e545f9'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:buildScriptPath = Join-Path $repoRoot 'scripts\build-product.ps1'
$script:preflightScriptPath = Join-Path $repoRoot 'scripts\GsBuildPreflight.ps1'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

# A test signals a skip by throwing with this prefix (environment cannot
# run it, e.g. no csc compiler or no git baseline on this machine).
$script:SkipPrefix = 'GSSKIP:'

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

function Assert-NotContains {
    param([string]$Text, [string]$Forbidden, [string]$Message)
    Assert-True ($Text -eq $null -or -not $Text.Contains($Forbidden)) "$Message (forbidden substring '$Forbidden' present)"
}

function Assert-FileContent {
    param([string]$Path, [string]$ExpectedContent, [string]$Message)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "$Message (file missing: $Path)"
    $actual = [IO.File]::ReadAllText($Path)
    Assert-True ($actual -eq $ExpectedContent) "$Message (content differs: $Path)"
}

$script:workDir = Join-Path ([IO.Path]::GetTempPath()) ('GsBuildPreflight_' + [guid]::NewGuid().ToString('N'))
$script:BundleSentinelContent = '# SENTINEL-BUNDLE synthetic fixture, must never be executed'
$script:LicenseSentinelContent = 'SENTINEL-LICENSE synthetic product license text, not a real license'
$script:LicensingSentinelContent = 'SENTINEL-LICENSING synthetic licensing notice, not a real license'
# The full public runtime bundle contract: the build now rejects a bundle
# missing any of these names, so the synthetic bundle must carry all of them.
$script:BundleFileNames = @(
    'gs_start_private.ps1', 'gs_stop_private.ps1', 'gs_start_with_hook.ps1',
    'gs_supervisor.ps1', 'gs_grant_pipe_acl.ps1', 'gs_process_identity.ps1',
    'gs_launcher.py', 'inject_nvstreamer.py', 'patch_applist_mem.py',
    'gs_nsc_supported.py', 'gs_mdns_probe.py',
    'NvStreamerBusHook.dll', 'GsStreamGuard.dll'
)

# All junctions created during the run are tracked here so cleanup can
# remove the links themselves before any recursive delete.
$script:Junctions = @()

try {

    try {
        # Load the preflight helpers (pure + resolver functions) in-process.
        . $script:preflightScriptPath
    } catch {
        Write-Host ("FAIL preflight helper load :: {0}" -f $_.Exception.Message)
        exit 1
    }

    # ------------------------------------------------------------------
    # Synthetic fixtures
    # ------------------------------------------------------------------

    function New-SyntheticRepo {
        param([Parameter(Mandatory)][string]$Name)
        $repo = Join-Path $script:workDir $Name
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        foreach ($d in @('product', 'src\GsControl', 'src\GsLifecycle', 'src\GsRuntime',
                'installer', 'runtime-bundle', 'artifacts', 'scripts')) {
            New-Item -ItemType Directory -Path (Join-Path $repo $d) -Force | Out-Null
        }
        [IO.File]::WriteAllText((Join-Path $repo 'product\gs-product.ps1'), "# synthetic product entry`r`n")
        [IO.File]::WriteAllText((Join-Path $repo 'product\gs-diagnose.ps1'), "# synthetic diagnose helper`r`n")
        # The build treats the seven-file local console set as required
        # inputs; the synthetic product directory must carry all of them so
        # the original preflight assertions stay the deciding failures.
        foreach ($name in @('gs-console.ps1', 'gs-console-action.ps1', 'gs-console.vbs',
                'gs-console.html', 'gs-console.css', 'gs-console.js',
                'gs-console-strings.zh-CN.json')) {
            [IO.File]::WriteAllText((Join-Path $repo "product\$name"), ("# synthetic console asset: " + $name + "`r`n"))
        }
        # gs-console.ps1 dot-sources gs-tray-model.ps1 unconditionally, so
        # the build requires it as an independent input.
        [IO.File]::WriteAllText((Join-Path $repo 'product\gs-tray-model.ps1'), "# synthetic tray model`r`n")
        foreach ($m in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
            [IO.File]::WriteAllText((Join-Path $repo "src\$m\$m.psd1"), "# synthetic $m psd1`r`n")
            [IO.File]::WriteAllText((Join-Path $repo "src\$m\$m.psm1"), "# synthetic $m psm1`r`n")
        }
        [IO.File]::WriteAllText((Join-Path $repo 'installer\GsController.wxs'), "<Wix></Wix>`r`n")
        Copy-Item -LiteralPath (Join-Path $repoRoot 'installer\GsConsoleShortcut.xsl') -Destination (Join-Path $repo 'installer\GsConsoleShortcut.xsl')
        [IO.File]::WriteAllText((Join-Path $repo 'LICENSE'), ($script:LicenseSentinelContent + "`r`n"))
        [IO.File]::WriteAllText((Join-Path $repo 'LICENSING.md'), ($script:LicensingSentinelContent + "`r`n"))
        [IO.File]::WriteAllText((Join-Path $repo 'runtime-bundle\README.md'), "documentation only`r`n")
        [IO.File]::WriteAllText((Join-Path $repo 'runtime-bundle\gs-helper.ps1'), ($script:BundleSentinelContent + "`r`n"))
        foreach ($name in $script:BundleFileNames) {
            [IO.File]::WriteAllText((Join-Path $repo ("runtime-bundle\" + $name)), ($script:BundleSentinelContent + "`r`n"))
        }
        Copy-Item -LiteralPath $script:buildScriptPath -Destination (Join-Path $repo 'scripts\build-product.ps1')
        Copy-Item -LiteralPath $script:preflightScriptPath -Destination (Join-Path $repo 'scripts\GsBuildPreflight.ps1')
        # The build reuses the shared public bundle name list from the
        # checker through -DefineOnly, so the synthetic repo carries it too.
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Test-GsPrerequisites.ps1') -Destination (Join-Path $repo 'scripts\Test-GsPrerequisites.ps1')
        return $repo
    }

    function Set-StageSentinel {
        param([Parameter(Mandatory)][string]$RepoRoot, [string]$Content = 'STAGE-SENTINEL-MUST-SURVIVE')
        $stage = Join-Path $RepoRoot 'artifacts\product-stage'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'SENTINEL.txt'), $Content)
        return $Content
    }

    function Get-StageSentinelPath {
        param([Parameter(Mandatory)][string]$RepoRoot)
        return (Join-Path $RepoRoot 'artifacts\product-stage\SENTINEL.txt')
    }

    function New-DirectoryJunction {
        param([Parameter(Mandatory)][string]$LinkPath, [Parameter(Mandatory)][string]$TargetPath)
        $null = & cmd.exe /d /c mklink /J "$LinkPath" "$TargetPath"
        if ($LASTEXITCODE -ne 0) { throw "mklink /J failed for $LinkPath" }
        $script:Junctions += $LinkPath
        return $LinkPath
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
    # and exit 0.
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

    # Returns the baseline build-product.ps1 text, or throws a skip
    # exception when git or the baseline commit is unavailable.
    function Get-BaselineBuildScriptText {
        param([string]$Commit)
        if ([string]::IsNullOrWhiteSpace($Commit)) {
            Skip-Test -Reason 'no baseline commit configured'
        }
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($null -eq $git) {
            Skip-Test -Reason 'git not available'
        }
        $text = & cmd.exe /d /c "git -C `"$repoRoot`" show $Commit`:scripts/build-product.ps1 2>nul"
        if ($LASTEXITCODE -ne 0) {
            Skip-Test -Reason ("baseline commit {0} not readable" -f $Commit)
        }
        $lines = @($text)
        if ($lines.Count -eq 0) {
            Skip-Test -Reason ("baseline commit {0} returned an empty file" -f $Commit)
        }
        return (($lines -join "`r`n") + "`r`n")
    }

    function New-BaselineRepo {
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Text)
        $repo = Join-Path $script:workDir $Name
        New-Item -ItemType Directory -Path (Join-Path $repo 'scripts') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'scripts\build-product.ps1'), $text)
        $fixtures = New-SyntheticRepo ($Name + '-fixtures')
        foreach ($d in @('product', 'src', 'installer', 'runtime-bundle', 'artifacts')) {
            Copy-Item -LiteralPath (Join-Path $fixtures $d) -Destination (Join-Path $repo $d) -Recurse -Force
        }
        return $repo
    }

    # Removes tracked junction links first (the link itself only; cmd
    # rmdir never follows a junction, unlike Remove-Item which has a
    # NullReference bug on dangling junctions in Windows PowerShell 5.1),
    # then the tree, so no recursive delete can follow a link into its
    # target.
    function Remove-TestTree {
        param([string]$Root)
        if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return }
        foreach ($j in $script:Junctions) {
            $null = & cmd.exe /d /c ("rmdir `"" + $j + "`" 2>nul")
        }
        Get-ChildItem -LiteralPath $Root -Recurse -Force -Directory -Attributes ReparsePoint `
            -ErrorAction SilentlyContinue |
            ForEach-Object { $null = & cmd.exe /d /c ("rmdir `"" + $_.FullName + "`" 2>nul") }
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ------------------------------------------------------------------
    # Unit tests: pure functions (in-process)
    # ------------------------------------------------------------------

    Invoke-Test 'unit: Test-GsMsiVersionString accepts in-range versions' {
        foreach ($v in @('0.2.0', '0.0.0', '255.255.65535', '01.02.03', '10.0.1')) {
            Assert-True (Test-GsMsiVersionString -Version $v) "expected valid: $v"
        }
    }

    Invoke-Test 'unit: Test-GsMsiVersionString rejects out-of-range and malformed versions without throwing' {
        foreach ($v in @('256.0.0', '0.256.0', '0.0.65536', '999.999.999', '4294967295.0.0',
                '1.2', '1.2.3.4', 'abc', '', '   ', '1 .2.3', '1.2.3 ', '+1.2.3',
                '99999999999999999999.1.1', '1.2.x', '1,2,3',
                ('1.2.3' + [char]10), ('1.2.3' + [char]13 + [char]10), ('1.2.3' + [char]9),
                (([char]10) + '1.2.3'))) {
            $ok = $false
            try {
                $ok = Test-GsMsiVersionString -Version $v
            } catch {
                throw "threw instead of clean false for '$v': $($_.Exception.Message)"
            }
            Assert-True (-not $ok) "expected invalid: [$v]"
        }
    }

    Invoke-Test 'unit: ConvertTo-GsCanonicalLexical normalizes separators, dots, trailing slashes and device prefixes' {
        $base = 'C:\base\dir'
        Assert-True ((ConvertTo-GsCanonicalLexical -Path 'sub\..\other' -BaseDir $base) -eq 'C:\base\dir\other') 'relative with .. stays under base'
        Assert-True ((ConvertTo-GsCanonicalLexical -Path 'C:/base/dir/x/' -BaseDir $base) -eq 'C:\base\dir\x') 'forward slash + trailing'
        Assert-True ((ConvertTo-GsCanonicalLexical -Path 'C:\' -BaseDir $base) -eq 'C:') 'drive root trimmed'
        Assert-True ((ConvertTo-GsCanonicalLexical -Path '\\?\C:\x\y' -BaseDir $base) -eq 'C:\x\y') 'device prefix stripped'
        Assert-True ((ConvertTo-GsCanonicalLexical -Path '\\?\UNC\srv\share\f' -BaseDir $base) -eq '\\srv\share\f') 'UNC device prefix stripped'
        Assert-True ((ConvertTo-GsCanonicalLexical -Path '.\a\.\b' -BaseDir $base) -eq 'C:\base\dir\a\b') 'dot segments collapsed'
    }

    Invoke-Test 'unit: Test-GsPathOverlap detects equal and nested paths case-insensitively' {
        Assert-True (Test-GsPathOverlap -A 'C:\a\b' -B 'C:\a\b') 'equal'
        Assert-True (Test-GsPathOverlap -A 'c:\a\b' -B 'C:\A\B') 'case-insensitive equal'
        Assert-True (Test-GsPathOverlap -A 'C:\a' -B 'C:\a\b') 'ancestor first'
        Assert-True (Test-GsPathOverlap -A 'C:\a\b' -B 'C:\a') 'descendant first'
        Assert-True (Test-GsPathOverlap -A 'C:' -B 'C:\anything') 'drive root overlaps child'
        Assert-True (Test-GsPathOverlap -A '' -B 'C:\x') 'empty canonical overlaps everything'
    }

    Invoke-Test 'unit: Test-GsPathOverlap rejects component-boundary look-alikes and disjoint paths' {
        Assert-True (-not (Test-GsPathOverlap -A 'C:\abc' -B 'C:\abcd')) 'prefix without boundary'
        Assert-True (-not (Test-GsPathOverlap -A 'C:\ab' -B 'C:\abc\d')) 'nested prefix without boundary'
        Assert-True (-not (Test-GsPathOverlap -A 'C:\a' -B 'D:\a')) 'different drives'
        Assert-True (-not (Test-GsPathOverlap -A 'C:\a\x' -B 'C:\a\y')) 'siblings'
    }

    $resolverBase = Join-Path $script:workDir 'resolver'
    New-Item -ItemType Directory -Path (Join-Path $resolverBase 'real\sub') -Force | Out-Null

    Invoke-Test 'unit: Resolve-GsPhysicalPath expands a junction on the final component' {
        $link = New-DirectoryJunction -LinkPath (Join-Path $resolverBase 'link') -TargetPath (Join-Path $resolverBase 'real')
        $r = Resolve-GsPhysicalPath -Path $link -BaseDir $resolverBase
        Assert-True ($r -eq (Resolve-GsPhysicalPath -Path (Join-Path $resolverBase 'real') -BaseDir $resolverBase)) 'link resolves to target'
        Assert-True ($r.EndsWith('resolver\real')) 'resolved suffix is the real path'
    }

    Invoke-Test 'unit: Resolve-GsPhysicalPath expands a junction in the middle and keeps the remainder' {
        $link = New-DirectoryJunction -LinkPath (Join-Path $resolverBase 'midlink') -TargetPath (Join-Path $resolverBase 'real')
        $r = Resolve-GsPhysicalPath -Path (Join-Path $link 'sub') -BaseDir $resolverBase
        Assert-True ($r -eq (Resolve-GsPhysicalPath -Path (Join-Path $resolverBase 'real\sub') -BaseDir $resolverBase)) 'link\sub resolves to real\sub'
    }

    Invoke-Test 'unit: Resolve-GsPhysicalPath expands 8.3 short names when the volume provides them' {
        $longDir = Join-Path $resolverBase 'aaaaaaaaaabbbbbbbbbbccccccccccddddd'
        New-Item -ItemType Directory -Path $longDir -Force | Out-Null
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder($longDir).ShortPath
        $r = Resolve-GsPhysicalPath -Path $short -BaseDir $resolverBase
        if ($short -ne $longDir) {
            Assert-True ($r -eq (Resolve-GsPhysicalPath -Path $longDir -BaseDir $resolverBase)) 'short name expanded to long path'
        } else {
            Assert-True ($r -eq $longDir) 'no short names on this volume; identity resolution'
        }
    }

    Invoke-Test 'unit: Resolve-GsPhysicalPath keeps a missing tail lexical' {
        $r = Resolve-GsPhysicalPath -Path (Join-Path $resolverBase 'real\notcreated\deep') -BaseDir $resolverBase
        Assert-True ($r -eq (Join-Path $resolverBase 'real\notcreated\deep')) 'missing components preserved'
    }

    Invoke-Test 'unit: Resolve-GsPhysicalPath rejects a reparse cycle with a clear error' {
        $la = Join-Path $resolverBase 'cycleA'
        $lb = Join-Path $resolverBase 'cycleB'
        New-Item -ItemType Directory -Path $la -Force | Out-Null
        New-Item -ItemType Directory -Path $lb -Force | Out-Null
        Remove-Item -LiteralPath $la -Force
        Remove-Item -LiteralPath $lb -Force
        New-DirectoryJunction -LinkPath $la -TargetPath $lb | Out-Null
        New-DirectoryJunction -LinkPath $lb -TargetPath $la | Out-Null
        $threw = $false
        try {
            $null = Resolve-GsPhysicalPath -Path $la -BaseDir $resolverBase
        } catch {
            $threw = $true
            Assert-True ($_.Exception.Message.Contains('reparse cycle')) 'cycle error mentions reparse cycle'
        }
        Assert-True $threw 'cycle must be rejected, never guessed through'
    }

    Invoke-Test 'unit: Resolve-GsPhysicalPath is idempotent' {
        $p = Join-Path $resolverBase 'real\sub'
        $once = Resolve-GsPhysicalPath -Path $p -BaseDir $resolverBase
        $twice = Resolve-GsPhysicalPath -Path $once -BaseDir $resolverBase
        Assert-True ($once -eq $twice) 'resolve twice equals once'
    }

    Invoke-Test 'unit: Get-GsPathReparseComponent finds reparse points strictly below the boundary only' {
        $real = Join-Path $resolverBase 'real'
        $link = New-DirectoryJunction -LinkPath (Join-Path $resolverBase 'relink') -TargetPath $real
        $boundary = $resolverBase
        $found = Get-GsPathReparseComponent -Path (Join-Path $link 'sub') -BelowPath $boundary
        Assert-True ($null -ne $found -and $found.EndsWith('relink')) 'junction component below boundary reported'
        Assert-True ($null -eq (Get-GsPathReparseComponent -Path (Join-Path $real 'sub') -BelowPath $boundary)) 'plain tree has no reparse component'
        Assert-True ($null -eq (Get-GsPathReparseComponent -Path $boundary -BelowPath $boundary)) 'boundary itself is never reported'
        Assert-True ($null -ne (Get-GsPathReparseComponent -Path $link -BelowPath $boundary)) 'a junction below the boundary is reported'
        $otherBase = Join-Path $resolverBase 'outside'
        New-Item -ItemType Directory -Path $otherBase -Force | Out-Null
        Assert-True ($null -eq (Get-GsPathReparseComponent -Path (Join-Path $otherBase 'x') -BelowPath $boundary)) 'paths outside the boundary are skipped'
    }

    # ------------------------------------------------------------------
    # Script tests: real build script in child processes (PreflightOnly
    # unless stated), synthetic repos only
    # ------------------------------------------------------------------

    Invoke-Test 'script: valid fixture passes preflight-only and creates nothing' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'valid-preflight'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0', '-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stderr: {1}; stdout: {2}" -f $r.ExitCode, $r.StdErr, $r.StdOut)
        Assert-Contains $r.StdOut 'PREFLIGHT OK: all checks passed' 'PREFLIGHT OK line'
        Assert-Contains $r.StdOut 'PREFLIGHT [PASS] version=0.2.0' 'version PASS line'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\product-stage'))) 'stage not created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi'))) 'output not created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\wix'))) 'wixbuild not created'
    }

    Invoke-Test 'script: out-of-range version fails with VersionInvalid before deleting the stage' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'bad-version'
        $sentinel = Set-StageSentinel -RepoRoot $repo
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '256.0.0', '-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'VersionInvalid' 'VersionInvalid reported'
        Assert-FileContent (Get-StageSentinelPath $repo) $sentinel 'stage sentinel preserved'
    }

    Invoke-Test 'script: absurdly long version fails cleanly without an overflow exception' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'huge-version'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '1.2.99999999999999999999', '-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'VersionInvalid' 'VersionInvalid reported'
        Assert-NotContains $r.StdOut 'OverflowException' 'no unstructured overflow error on stdout'
        Assert-NotContains $r.StdErr 'OverflowException' 'no unstructured overflow error on stderr'
    }

    Invoke-Test 'script: RuntimeBundleDir equal to the stage fails before deletion' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'bundle-eq-stage'
        $sentinel = Set-StageSentinel -RepoRoot $repo
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'artifacts\product-stage'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
        Assert-FileContent (Get-StageSentinelPath $repo) $sentinel 'stage sentinel preserved'
    }

    Invoke-Test 'script: RuntimeBundleDir ancestor of the stage (artifacts) fails' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'bundle-ancestor'
        $sentinel = Set-StageSentinel -RepoRoot $repo
        # A top-level file is needed so the existing bundle non-empty check
        # (which runs before the preflight) passes and the preflight decides.
        [IO.File]::WriteAllText((Join-Path $repo 'artifacts\bundle-stub.bin'), 'stub')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'artifacts'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
        Assert-FileContent (Get-StageSentinelPath $repo) $sentinel 'stage sentinel preserved'
    }

    Invoke-Test 'script: RuntimeBundleDir inside the wix build dir fails' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'bundle-in-wixbuild'
        $rb = Join-Path $repo 'artifacts\wix\product\rb'
        New-Item -ItemType Directory -Path $rb -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $rb 'helper.dat'), 'sentinel-bundle-file')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', $rb)
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
        Assert-FileContent (Join-Path $rb 'helper.dat') 'sentinel-bundle-file' 'bundle input preserved'
    }

    Invoke-Test 'script: OutputDirectory equal to the runtime bundle fails' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'out-eq-bundle'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'),
            '-OutputDirectory', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
    }

    Invoke-Test 'script: OutputDirectory equal to the product directory fails' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'out-eq-product'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'),
            '-OutputDirectory', (Join-Path $repo 'product'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
    }

    Invoke-Test 'script: relative .. output path is normalized and rejected' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'out-relative'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'),
            '-OutputDirectory', 'artifacts\..\src\GsControl')
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
    }

    Invoke-Test 'script: output path with trailing separator is rejected' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'out-trailing'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'),
            '-OutputDirectory', (($repo + '\src\GsControl') + '\'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
    }

    Invoke-Test 'script: case-different module path as bundle is rejected' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'bundle-case'
        $upper = ($repo + '\SRC\GSCONTROL')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', $upper)
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
    }

    Invoke-Test 'script: junction pointing at the stage is rejected before deletion and sentinel survives' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'bundle-junction-stage'
        $sentinel = Set-StageSentinel -RepoRoot $repo
        $link = New-DirectoryJunction -LinkPath (Join-Path $repo 'jstage') -TargetPath (Join-Path $repo 'artifacts\product-stage')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', $link)
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
        Assert-FileContent (Get-StageSentinelPath $repo) $sentinel 'stage sentinel preserved'
    }

    Invoke-Test 'script: junction resolving to a benign disjoint directory passes' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'bundle-junction-benign'
        $link = New-DirectoryJunction -LinkPath (Join-Path $repo 'jbundle') -TargetPath (Join-Path $repo 'runtime-bundle')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', $link)
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stdout: {1}; stderr: {2}" -f $r.ExitCode, $r.StdOut, $r.StdErr)
        Assert-Contains $r.StdOut 'PREFLIGHT OK' 'PREFLIGHT OK line'
    }

    Invoke-Test 'script: stage as a junction into installer is rejected (WritePathReparse) and the installer sentinel survives' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'stage-junction-installer'
        $installerSentinel = 'INSTALLER-SENTINEL-MUST-SURVIVE'
        [IO.File]::WriteAllText((Join-Path $repo 'installer\INSTALLER-SENTINEL.txt'), $installerSentinel)
        $link = New-DirectoryJunction -LinkPath (Join-Path $repo 'artifacts\product-stage') -TargetPath (Join-Path $repo 'installer')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'WritePathReparse' 'WritePathReparse reported'
        Assert-FileContent (Join-Path $repo 'installer\INSTALLER-SENTINEL.txt') $installerSentinel 'installer sentinel preserved'
    }

    Invoke-Test 'script: wix build dir junction into scripts is rejected' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'wixbuild-junction-scripts'
        [IO.File]::WriteAllText((Join-Path $repo 'scripts\SCRIPTS-SENTINEL.txt'), 'must-survive')
        $null = New-Item -ItemType Directory -Path (Join-Path $repo 'artifacts') -Force
        $link = New-DirectoryJunction -LinkPath (Join-Path $repo 'artifacts\wix') -TargetPath (Join-Path $repo 'scripts')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'WritePathReparse' 'WritePathReparse reported'
        Assert-FileContent (Join-Path $repo 'scripts\SCRIPTS-SENTINEL.txt') 'must-survive' 'scripts sentinel preserved'
    }

    Invoke-Test 'script: artifacts itself as a junction is rejected' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'artifacts-junction'
        $elsewhere = Join-Path $script:workDir 'artifacts-elsewhere'
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        $artifacts = Join-Path $repo 'artifacts'
        # mklink /J cannot target an existing directory; artifacts is empty.
        Remove-Item -LiteralPath $artifacts -Force
        $link = New-DirectoryJunction -LinkPath $artifacts -TargetPath $elsewhere
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'WritePathReparse' 'WritePathReparse reported'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $elsewhere 'product-stage'))) 'nothing staged through the junction'
    }

    Invoke-Test 'script: installer directory junction into the stage is rejected and the wxs sentinel survives' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'installer-junction-stage'
        $stage = Join-Path $repo 'artifacts\product-stage'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'GsController.wxs'), 'WXS-SENTINEL-MUST-SURVIVE')
        # The harvest XSL is a required input too; it must be reachable
        # through the junction so the existing input checks pass and the
        # physical input protection stays the deciding rejection.
        [IO.File]::WriteAllText((Join-Path $stage 'GsConsoleShortcut.xsl'), 'XSL-SENTINEL-MUST-SURVIVE')
        # installer is a junction to the stage; the wxs is reachable through
        # it, so the existing input checks pass and the physical input
        # protection must be the deciding rejection.
        Remove-Item -LiteralPath (Join-Path $repo 'installer') -Recurse -Force
        $link = New-DirectoryJunction -LinkPath (Join-Path $repo 'installer') -TargetPath $stage
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'InstallerDir vs StageDir overlap reported'
        Assert-FileContent (Join-Path $repo 'installer\GsController.wxs') 'WXS-SENTINEL-MUST-SURVIVE' 'installer wxs sentinel preserved'
    }

    Invoke-Test 'script: scripts directory junction into the wix build dir is rejected and the sentinel survives' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'scripts-junction-wixbuild'
        $wb = Join-Path $repo 'artifacts\wix\product'
        New-Item -ItemType Directory -Path $wb -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'scripts\build-product.ps1') -Destination (Join-Path $wb 'build-product.ps1')
        Copy-Item -LiteralPath (Join-Path $repo 'scripts\GsBuildPreflight.ps1') -Destination (Join-Path $wb 'GsBuildPreflight.ps1')
        [IO.File]::WriteAllText((Join-Path $wb 'SCRIPTS-SENTINEL.txt'), 'must-survive')
        Remove-Item -LiteralPath (Join-Path $repo 'scripts') -Recurse -Force
        $link = New-DirectoryJunction -LinkPath (Join-Path $repo 'scripts') -TargetPath $wb
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'ScriptsDir vs WixBuildDir overlap reported'
        Assert-FileContent (Join-Path $wb 'SCRIPTS-SENTINEL.txt') 'must-survive' 'scripts sentinel preserved'
    }

    Invoke-Test 'script: external output with a reparse ancestor outside the repository still passes' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'external-junction-out'
        $realOut = Join-Path $script:workDir 'ext-out-real'
        New-Item -ItemType Directory -Path $realOut -Force | Out-Null
        $link = New-DirectoryJunction -LinkPath (Join-Path $script:workDir 'ext-out-link') -TargetPath $realOut
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'),
            '-OutputDirectory', (Join-Path $link 'msi'))
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stdout: {1}" -f $r.ExitCode, $r.StdOut)
        Assert-Contains $r.StdOut 'PREFLIGHT OK' 'PREFLIGHT OK line'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $realOut 'msi'))) 'external output not created by preflight'
    }

    Invoke-Test 'script: stage and wix build dir physical alias is rejected before any deletion' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'workdirs-alias'
        $sentinel = Set-StageSentinel -RepoRoot $repo
        $null = New-Item -ItemType Directory -Path (Join-Path $repo 'artifacts') -Force
        $link = New-DirectoryJunction -LinkPath (Join-Path $repo 'artifacts\wix') -TargetPath (Join-Path $repo 'artifacts\product-stage')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'work-directory alias reported as PathOverlap'
        Assert-Contains $r.StdOut 'WritePathReparse' 'reparse component in the work path also reported'
        Assert-FileContent (Get-StageSentinelPath $repo) $sentinel 'stage sentinel preserved'
    }

    Invoke-Test 'script: WixDir equal to the stage fails' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'wixdir-eq-stage'
        $sentinel = Set-StageSentinel -RepoRoot $repo
        # The existing WiX tool existence check runs before the preflight,
        # so the fake tools must be inside the stage for the overlap check
        # to be the deciding failure.
        foreach ($t in @('heat.exe', 'candle.exe', 'light.exe')) {
            Copy-Item -LiteralPath (Join-Path $wix $t) -Destination (Join-Path $repo 'artifacts\product-stage')
        }
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', (Join-Path $repo 'artifacts\product-stage'),
            '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
        Assert-FileContent (Get-StageSentinelPath $repo) $sentinel 'stage sentinel preserved'
    }

    Invoke-Test 'script: output inside the wix build dir fails' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'out-in-wixbuild'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'),
            '-OutputDirectory', (Join-Path $repo 'artifacts\wix\product\out'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
    }

    Invoke-Test 'script: default output directory (artifacts msi) passes and preflight does not create it' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'out-default'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stdout: {1}" -f $r.ExitCode, $r.StdOut)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'artifacts\msi'))) 'default output not created by preflight'
    }

    Invoke-Test 'script: normal external new output directory passes and preflight does not create it' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'out-external'
        $external = Join-Path $script:workDir 'external-new-output'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'),
            '-OutputDirectory', $external)
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stdout: {1}" -f $r.ExitCode, $r.StdOut)
        Assert-True (-not (Test-Path -LiteralPath $external)) 'external output not created by preflight'
    }

    Invoke-Test 'script: output path that is an existing file fails with OutputNotADirectory' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'out-is-file'
        $file = Join-Path $repo 'some-file.out'
        [IO.File]::WriteAllText($file, 'x')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-PreflightOnly',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'),
            '-OutputDirectory', $file)
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'OutputNotADirectory' 'OutputNotADirectory reported'
    }

    Invoke-Test 'script: full pipeline with fake WiX tools reaches staging and output with inputs preserved' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'full-pipeline'
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stdout: {1}; stderr: {2}" -f $r.ExitCode, $r.StdOut, $r.StdErr)
        Assert-Contains $r.StdOut 'Staged ' 'staged line'
        Assert-Contains $r.StdOut 'MSI built:' 'MSI built line'
        $msi = Join-Path $repo 'artifacts\msi\GsController-0.2.0.msi'
        Assert-True (Test-Path -LiteralPath $msi -PathType Leaf) 'fake MSI file exists'
        Assert-FileContent (Join-Path $repo 'artifacts\product-stage\bin\gs-helper.ps1') ($script:BundleSentinelContent + "`r`n") 'bundle staged verbatim'
        Assert-True (Test-Path -LiteralPath (Join-Path $repo 'artifacts\product-stage\Modules\GsControl\GsControl.psd1')) 'module staged'
        Assert-True (Test-Path -LiteralPath (Join-Path $repo 'artifacts\product-stage\gs-product.ps1')) 'product entry staged'
        Assert-FileContent (Join-Path $repo 'artifacts\product-stage\LICENSE') ($script:LicenseSentinelContent + "`r`n") 'LICENSE staged byte-for-byte'
        Assert-FileContent (Join-Path $repo 'artifacts\product-stage\LICENSING.md') ($script:LicensingSentinelContent + "`r`n") 'LICENSING.md staged byte-for-byte'
        Assert-FileContent (Join-Path $repo 'runtime-bundle\gs-helper.ps1') ($script:BundleSentinelContent + "`r`n") 'bundle source preserved'
        Assert-FileContent (Join-Path $repo 'src\GsControl\GsControl.psm1') "# synthetic GsControl psm1`r`n" 'module source preserved'
        Assert-FileContent (Join-Path $repo 'product\gs-product.ps1') "# synthetic product entry`r`n" 'product source preserved'
    }

    Invoke-Test 'script: full pipeline refuses a junction bundle overlapping the stage before any deletion' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'full-junction-overlap'
        $sentinel = Set-StageSentinel -RepoRoot $repo
        $link = New-DirectoryJunction -LinkPath (Join-Path $repo 'jstage') -TargetPath (Join-Path $repo 'artifacts\product-stage')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @(
            '-WixDir', $wix, '-RuntimeBundleDir', $link)
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdOut 'PREFLIGHT [FAIL]' 'PREFLIGHT FAIL list printed'
        Assert-Contains $r.StdOut 'PathOverlap' 'PathOverlap reported'
        Assert-FileContent (Get-StageSentinelPath $repo) $sentinel 'stage sentinel preserved'
        Assert-True (Test-Path -LiteralPath (Join-Path $repo 'artifacts\product-stage') -PathType Container) 'stage still exists (not deleted)'
    }

    Invoke-Test 'script: missing LICENSE fails before cleanup and the stage sentinel survives' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'missing-license'
        Remove-Item -LiteralPath (Join-Path $repo 'LICENSE') -Force
        $sentinel = Set-StageSentinel -RepoRoot $repo
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdErr 'Missing input' 'missing input reported'
        Assert-Contains $r.StdErr 'LICENSE' 'the missing file is named'
        Assert-FileContent (Get-StageSentinelPath $repo) $sentinel 'stage sentinel preserved (failed before cleanup)'
    }

    Invoke-Test 'script: missing LICENSING.md fails before cleanup and the stage sentinel survives' {
        $wix = Assert-FakeWixAvailable
        $repo = New-SyntheticRepo 'missing-licensing'
        Remove-Item -LiteralPath (Join-Path $repo 'LICENSING.md') -Force
        $sentinel = Set-StageSentinel -RepoRoot $repo
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -ne 0) 'exit non-zero'
        Assert-Contains $r.StdErr 'Missing input' 'missing input reported'
        Assert-Contains $r.StdErr 'LICENSING.md' 'the missing file is named'
        Assert-FileContent (Get-StageSentinelPath $repo) $sentinel 'stage sentinel preserved (failed before cleanup)'
    }

    # ------------------------------------------------------------------
    # Baseline evidence: the pre-preflight build script had the flaws this
    # change fixes. Runs only inside %TEMP% synthetic repos.
    # ------------------------------------------------------------------

    Invoke-Test 'baseline: old build script accepts an out-of-range version (evidence of the old flaw)' {
        $wix = Assert-FakeWixAvailable
        $text = Get-BaselineBuildScriptText -Commit $BaselineCommit
        $repo = New-BaselineRepo -Name 'baseline-version' -Text $text
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '999.0.0',
            '-WixDir', $wix, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
        Assert-True ($r.ExitCode -eq 0) ("old script exited {0}; stdout: {1}; stderr: {2}" -f $r.ExitCode, $r.StdOut, $r.StdErr)
        Assert-Contains $r.StdOut 'MSI built:' 'old script built an MSI with version 999.0.0'
    }

    Invoke-Test 'baseline: old build script destroys a runtime bundle that overlaps the stage (evidence of the old flaw)' {
        $wix = Assert-FakeWixAvailable
        $text = Get-BaselineBuildScriptText -Commit $BaselineCommit
        $repo = New-BaselineRepo -Name 'baseline-overlap' -Text $text
        $sentinel = Set-StageSentinel -RepoRoot $repo
        $link = New-DirectoryJunction -LinkPath (Join-Path $repo 'jstage') -TargetPath (Join-Path $repo 'artifacts\product-stage')
        $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @(
            '-WixDir', $wix, '-RuntimeBundleDir', $link)
        Assert-True ($r.ExitCode -ne 0) 'old script failed mid-copy after deleting its input'
        Assert-True (-not (Test-Path -LiteralPath (Get-StageSentinelPath $repo))) 'old script destroyed the sentinel input'
    }

} finally {
    Remove-TestTree -Root $script:workDir
}

Write-Host ("Summary: {0} passed, {1} failed, {2} skipped" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
