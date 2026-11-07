#Requires -Version 5.1
<#
.SYNOPSIS
    Pure unit and Plan-safety tests for tests\Invoke-SunshineInstallAcceptance.ps1.

.DESCRIPTION
    Everything here is offline and side-effect free. The suite only
    exercises the harness's PURE functions (runner gate, path scope,
    static plan, msiexec verdicts, log markers, install profile verdict,
    MSI pair verdict, manifest comparison) and its default PLAN mode in a
    child process. It NEVER invokes -Execute - not even for negative
    cases - and never fakes CI environment variables to reach the install
    path. The real-install acceptance itself runs only inside the pinned
    GitHub-hosted runner (.github\workflows\sunshine-msi-acceptance.yml).

    Exits 0 only when every test passed.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$harnessPath = Join-Path $repoRoot 'tests\Invoke-SunshineInstallAcceptance.ps1'

$script:Passed = 0
$script:Failed = 0

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
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

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Message)
    Assert-True ($Text -ne $null -and $Text.Contains($Expected)) "$Message (expected '$Expected' in: $Text)"
}

# Load the harness's pure functions only (no main flow runs).
. $harnessPath -DefineOnly

$workDir = Join-Path ([IO.Path]::GetTempPath()) ('GsSunshineAcceptanceTests_' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    Invoke-Test 'define-only: the harness defines its pure functions and prints nothing' {
        $probe = ". '$harnessPath' -DefineOnly; Write-Host 'DEFINED-OK'"
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $probe 2>&1)
        Assert-True (($output -join '').Contains('DEFINED-OK')) 'the -DefineOnly dot-source completes'
    }

    Invoke-Test 'gate: a fully correct GitHub-hosted environment is allowed' {
        $gate = Test-GsRunnerGate -Environment @{
            GITHUB_ACTIONS = 'true'; RUNNER_ENVIRONMENT = 'github-hosted'; RUNNER_OS = 'Windows'
        } -IsAdministrator $true -Is64BitProcess $true -PowerShellVersion ([version]'5.1.22621.1') -PowerShellEdition 'Desktop'
        Assert-True $gate.Allowed 'all gates pass'
        Assert-True (0 -eq @($gate.Reasons).Count) 'no reasons'
    }

    Invoke-Test 'gate: every wrong input produces its own tripwire reason' {
        $cases = @(
            @{ Environment = @{ GITHUB_ACTIONS = 'false'; RUNNER_ENVIRONMENT = 'github-hosted'; RUNNER_OS = 'Windows' }; Expected = 'GITHUB_ACTIONS must be true' },
            @{ Environment = @{ GITHUB_ACTIONS = 'true'; RUNNER_ENVIRONMENT = 'local'; RUNNER_OS = 'Windows' }; Expected = 'RUNNER_ENVIRONMENT must be github-hosted' },
            @{ Environment = @{ GITHUB_ACTIONS = 'true'; RUNNER_ENVIRONMENT = 'github-hosted'; RUNNER_OS = 'Linux' }; Expected = 'RUNNER_OS must be Windows' }
        )
        foreach ($case in $cases) {
            $gate = Test-GsRunnerGate -Environment $case.Environment -IsAdministrator $true -Is64BitProcess $true `
                -PowerShellVersion ([version]'5.1.1') -PowerShellEdition 'Desktop'
            Assert-True (-not $gate.Allowed) ('refused: ' + $case.Expected)
            Assert-True (1 -eq @($gate.Reasons | Where-Object { $_ -eq $case.Expected }).Count) ('reason listed: ' + $case.Expected)
        }
        foreach ($setup in @(
                @{ Admin = $false; Expected = 'an administrator PowerShell session is required' },
                @{ Admin = $true; Expected = 'a 64-bit process is required' })) {
            $gate = Test-GsRunnerGate -Environment @{ GITHUB_ACTIONS = 'true'; RUNNER_ENVIRONMENT = 'github-hosted'; RUNNER_OS = 'Windows' } `
                -IsAdministrator $setup.Admin -Is64BitProcess (-not $setup.Admin) `
                -PowerShellVersion ([version]'5.1.1') -PowerShellEdition 'Desktop'
            Assert-True (-not $gate.Allowed) 'refused'
            Assert-True (1 -eq @($gate.Reasons | Where-Object { $_ -eq $setup.Expected }).Count) ('reason listed: ' + $setup.Expected)
        }
        foreach ($ps in @(@([version]'7.4.1', 'Core'), @([version]'5.0', 'Desktop'))) {
            $gate = Test-GsRunnerGate -Environment @{ GITHUB_ACTIONS = 'true'; RUNNER_ENVIRONMENT = 'github-hosted'; RUNNER_OS = 'Windows' } `
                -IsAdministrator $true -Is64BitProcess $true -PowerShellVersion $ps[0] -PowerShellEdition $ps[1]
            Assert-True (-not $gate.Allowed) 'refused non-5.1-Desktop'
            Assert-Contains ($gate.Reasons -join '; ') 'Windows PowerShell 5.1 Desktop x64 is required' 'PowerShell gate reason'
        }
    }

    Invoke-Test 'path scope: only RUNNER_TEMP itself and its descendants are in scope' {
        $temp = Join-Path $workDir 'runner-temp'
        $inside = Join-Path $temp 'msi\pkg.msi'
        Assert-True (Test-GsAcceptancePathScope -Path $inside -RunnerTemp $temp) 'a descendant is in scope'
        Assert-True (Test-GsAcceptancePathScope -Path $temp -RunnerTemp $temp) 'RUNNER_TEMP itself is in scope'
        Assert-True (Test-GsAcceptancePathScope -Path $inside -RunnerPath:($temp + '\') -RunnerTemp ($temp + '\')) 'trailing separators normalize'
        $sibling = Join-Path $workDir 'runner-temps'
        Assert-True (-not (Test-GsAcceptancePathScope -Path $sibling -RunnerTemp $temp)) 'a sibling prefix look-alike is out of scope'
        Assert-True (-not (Test-GsAcceptancePathScope -Path $workDir -RunnerTemp $temp)) 'the parent is out of scope'
        Assert-True (-not (Test-GsAcceptancePathScope -Path 'C:\Windows\temp\x' -RunnerTemp $temp)) 'unrelated paths are out of scope'
        Assert-True (-not (Test-GsAcceptancePathScope -Path '' -RunnerTemp $temp)) 'empty paths are refused'
        Assert-True (-not (Test-GsAcceptancePathScope -Path $inside -RunnerTemp '')) 'an empty runner temp refuses everything'
    }

    Invoke-Test 'plan: the static plan is ordered, unique and kind-whitelisted' {
        $plan = Get-GsAcceptancePlan
        Assert-True (11 -eq @($plan).Count) 'eleven steps'
        $expectedIds = @('ReadMsiPair', 'RefuseConflicts', 'Install030', 'VerifyInstall030', 'ConsoleProbe',
            'RepairRound', 'Upgrade031', 'VerifyUpgrade031', 'Uninstall031', 'VerifyUninstall031', 'CleanupOwnArtifacts')
        for ($i = 0; $i -lt $expectedIds.Count; $i++) {
            Assert-True ($plan[$i].Id -eq $expectedIds[$i]) ('step ' + $i + ' is ' + $expectedIds[$i])
        }
        Assert-True (11 -eq @(($plan | ForEach-Object { $_.Id }) | Select-Object -Unique).Count) 'all ids unique'
        foreach ($step in $plan) {
            Assert-True ($step.Kind -in @('Read', 'Precheck', 'Install', 'Verify', 'Probe', 'Repair', 'Upgrade', 'Uninstall', 'Cleanup')) ('kind whitelisted: ' + $step.Kind)
            Assert-True ($step.Summary.Length -gt 0) 'every step carries a summary'
        }
        Assert-True ($plan[0].Kind -eq 'Read') 'the plan starts with a read-only step'
        Assert-True ($plan[10].Kind -eq 'Cleanup') 'the plan ends with cleanup'
    }

    Invoke-Test 'msiexec verdicts: 0 passes, 3010 is reboot-required, everything else fails' {
        Assert-True ((Get-GsMsiExecVerdict -ExitCode 0).Verdict -eq 'Passed') '0 passes'
        $reboot = Get-GsMsiExecVerdict -ExitCode 3010
        Assert-True ($reboot.Verdict -eq 'RebootRequired') '3010 is RebootRequired'
        Assert-Contains $reboot.Summary 'restart is required' 'the reboot summary says the state is incomplete'
        foreach ($code in @(1602, 1603, 1618, 1625, 999)) {
            Assert-True ((Get-GsMsiExecVerdict -ExitCode $code).Verdict -eq 'Failed') ('exit ' + $code + ' fails')
        }
    }

    Invoke-Test 'log judgment: known fatal markers are detected' {
        Assert-True (-not (Test-GsMsiLogContent -LogText '').Fatal) 'empty log is not fatal'
        Assert-True (-not (Test-GsMsiLogContent -LogText 'Installation completed successfully').Fatal) 'clean log is not fatal'
        Assert-True (Test-GsMsiLogContent -LogText '...Installation operation failed...').Fatal 'failed operation marker'
        Assert-True (Test-GsMsiLogContent -LogText 'NOTE: ...Return value 3.').Fatal 'return value 3 marker'
    }

    Invoke-Test 'profile verdict: only a sunshine schemaVersion-1 profile passes' {
        $good = Test-GsInstallProfileJson -Content ("{`r`n  `"schemaVersion`": 1,`r`n  `"backend`": `"sunshine`"`r`n}") -ExpectedBackend 'sunshine'
        Assert-True ($good.Verdict -eq 'Passed') 'the generated sunshine profile passes'
        Assert-True ((Test-GsInstallProfileJson -Content '{"schemaVersion": 1, "backend": "legacy"}' -ExpectedBackend 'sunshine').Verdict -eq 'Failed') 'legacy content fails'
        Assert-True ((Test-GsInstallProfileJson -Content '{"schemaVersion": 2, "backend": "sunshine"}' -ExpectedBackend 'sunshine').Verdict -eq 'Failed') 'wrong schema fails'
        Assert-True ((Test-GsInstallProfileJson -Content 'not json' -ExpectedBackend 'sunshine').Verdict -eq 'Failed') 'malformed content fails'
        foreach ($invalid in @('{"schemaVersion":1,"backend":"sunshine","extra":true}', '{"schemaVersion":"1","backend":"sunshine"}', '{}', '[{"schemaVersion":1,"backend":"sunshine"}]')) {
            Assert-True ((Test-GsInstallProfileJson -Content $invalid -ExpectedBackend 'sunshine').Verdict -eq 'Failed') 'invalid profiles rejected consistently with the application'
        }
    }

    Invoke-Test 'MSI pair verdict: the documented checks all decide' {
        $bracedCode = '{3B7F2C64-9A1D-4E58-8C2B-6D5A0F7E4B19}'
        # The fixtures use the braced Property-table form; the expected value
        # is passed UNBRACED to prove brace-normalization on both sides.
        $script:pairGood030 = [pscustomobject]@{ Path = 'a.msi'; ProductName = 'GsController'; ProductCode = '{11111111-1111-4111-8111-111111111111}'; Version = '0.3.0'; UpgradeCodes = @($bracedCode); CustomActionNames = @(); HasServiceInstall = $false; HasServiceControl = $false; HasRegistryTable = $false }
        $script:pairGood031 = [pscustomobject]@{ Path = 'b.msi'; ProductName = 'GsController'; ProductCode = '{22222222-2222-4222-8222-222222222222}'; Version = '0.3.1'; UpgradeCodes = @($bracedCode); CustomActionNames = @(); HasServiceInstall = $false; HasServiceControl = $false; HasRegistryTable = $false }
        $pair = Test-GsMsiPairAcceptable -Msi030 $script:pairGood030 -Msi031 $script:pairGood031 `
            -ExpectedUpgradeCode '3B7F2C64-9A1D-4E58-8C2B-6D5A0F7E4B19' -ExpectedProductName 'GsController'
        Assert-True $pair.Accepted 'the good pair is accepted (brace-normalized comparison)'

        $variants = @(
            @{ Name = 'product name mismatch'; Patch = { param($s) $s.ProductName = 'Other' } },
            @{ Name = 'invalid product code'; Patch = { param($s) $s.ProductCode = 'not-a-guid' } },
            @{ Name = 'upgrade code mismatch'; Patch = { param($s) $s.UpgradeCodes = @('OTHER') } },
            @{ Name = 'same product code'; Patch = { param($s) $s.ProductCode = '{11111111-1111-4111-8111-111111111111}' } },
            @{ Name = 'version not increasing'; Patch = { param($s) $s.Version = '0.2.9' } },
            @{ Name = 'custom action present'; Patch = { param($s) $s.CustomActionNames = @('GsPrepareUninstall') } },
            @{ Name = 'service install present'; Patch = { param($s) $s.HasServiceInstall = $true } },
            @{ Name = 'service control present'; Patch = { param($s) $s.HasServiceControl = $true } },
            @{ Name = 'registry table present'; Patch = { param($s) $s.HasRegistryTable = $true } }
        )
        foreach ($variant in $variants) {
            $patched = $script:pairGood031 | Select-Object *
            & $variant.Patch $patched
            $result = Test-GsMsiPairAcceptable -Msi030 $script:pairGood030 -Msi031 $patched `
                -ExpectedUpgradeCode '3B7F2C64-9A1D-4E58-8C2B-6D5A0F7E4B19' -ExpectedProductName 'GsController'
            Assert-True (-not $result.Accepted) ($variant.Name + ' is rejected')
        }
    }

    Invoke-Test 'manifest comparison: missing files and hash mismatches are named' {
        $expected = @(
            [pscustomobject]@{ relativePath = 'gs-console.ps1'; sha256 = 'hash-1' },
            [pscustomobject]@{ relativePath = 'Modules\GsRuntime\GsRuntime.psm1'; sha256 = 'hash-2' }
        )
        $actual = @{ 'gs-console.ps1' = 'hash-1'; 'Modules\GsRuntime\GsRuntime.psm1' = 'DIFFERENT' }
        $result = Test-GsManifestComparison -Expected $expected -Actual $actual
        Assert-True (-not $result.Accepted) 'a hash mismatch is rejected'
        Assert-Contains ($result.Violations -join '; ') 'hash mismatch: Modules\GsRuntime\GsRuntime.psm1' 'the mismatching file is named'
        $missing = Test-GsManifestComparison -Expected $expected -Actual @{ 'gs-console.ps1' = 'hash-1' }
        Assert-True (-not $missing.Accepted) 'a missing file is rejected'
        Assert-Contains ($missing.Violations -join '; ') 'missing installed file' 'the missing file is named'
        $ok = Test-GsManifestComparison -Expected $expected -Actual @{ 'gs-console.ps1' = 'hash-1'; 'Modules\GsRuntime\GsRuntime.psm1' = 'hash-2'; 'extra' = 'x' }
        Assert-True $ok.Accepted 'exact match is accepted (extra installed files are not a violation)'
    }

    Invoke-Test 'source guard: no WMI Win32_Product and no environment-injection seam' {
        # The guard checks live code only: the header help block and '#'
        # comment lines are stripped first (the harness's own warning comment
        # mentions the forbidden class by name).
        $fullText = [IO.File]::ReadAllText($harnessPath)
        $codeOnly = $fullText.Substring($fullText.IndexOf('#>') + 2)
        $codeOnly = (@($codeOnly -split "`n") | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
        Assert-True (-not $codeOnly.Contains('Win32_Product')) 'installed-product detection never uses Win32_Product (it would trigger repairs of other products)'
        Assert-True (-not $codeOnly.Contains('Get-CimInstance')) 'no CIM/WMI queries at all'
        Assert-True (-not $codeOnly.Contains('Get-WmiObject')) 'no legacy WMI queries at all'
        # The pure gate function is invoked exactly once, on the live process
        # environment: there is no seam to inject a simulated environment into
        # the real Execute path.
        Assert-True (1 -eq @([System.Text.RegularExpressions.Regex]::Matches($codeOnly, 'Test-GsRunnerGate -Environment')).Count) 'exactly one gate call site (live environment only)'
        Assert-True ($codeOnly.Contains('GITHUB_ACTIONS = [string]$env:GITHUB_ACTIONS')) 'the gate call site reads the live environment'
    }

    Invoke-Test 'msi rowsets: multiple rows and absent tables use only synthetic metadata' {
        $fixtureMsi = Join-Path $workDir 'metadata-fixture.msi'
        [IO.File]::WriteAllText($fixtureMsi, 'synthetic metadata; never installed or opened as MSI')
        $originalRows = (Get-Item Function:Get-MsiDatabaseRows).ScriptBlock
        $fakeRows = {
            param($MsiPath, $Sql, $Columns)
            $rows = @()
            if ($Sql.Contains('FROM `Property`')) {
                $rows += ,@('ProductName', 'GsController')
                $rows += ,@('ProductCode', '{11111111-1111-4111-8111-111111111111}')
                $rows += ,@('ProductVersion', '0.3.0')
                $rows += ,@('UpgradeCode', '{3B7F2C64-9A1D-4E58-8C2B-6D5A0F7E4B19}')
            } elseif ($Sql.Contains('FROM `_Tables`')) {
                foreach ($name in @('Property', 'Directory', 'File', 'ServiceControl')) { $rows += ,@($name) }
            } else { throw 'Unexpected metadata query in fixture.' }
            return $rows
        }
        try {
            Set-Item Function:script:Get-MsiDatabaseRows -Value $fakeRows
            $summary = Get-GsMsiSummary -MsiPath $fixtureMsi
            Assert-True ($summary.ProductName -eq 'GsController') 'property rows retain both columns'
            Assert-True ($summary.HasServiceControl) 'a service table after the first row is detected'
            Assert-True (-not $summary.HasServiceInstall) 'an absent service table stays absent'
            Assert-True ($summary.CustomActionNames.Count -eq 0) 'missing custom-action table yields no rows'
            $absent = @(Get-MsiRowsIfTableExists -MsiPath $fixtureMsi -TableName 'ServiceInstall' -Sql 'unused' -Columns 1)
            Assert-True ($absent.Count -eq 0) 'missing table does not index an empty row'
        } finally {
            Set-Item Function:script:Get-MsiDatabaseRows -Value $originalRows
        }
    }

    Invoke-Test 'plan mode: the child-process run performs zero actions and lists the plan' {
        $out = Join-Path $workDir 'plan-out.json'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath -JsonOut $out 2>&1)
        Assert-True ($LASTEXITCODE -eq 0) 'plan mode exits 0'
        $text = $output -join "`n"
        Assert-Contains $text 'PLAN ONLY' 'plan-only banner'
        Assert-Contains $text 'PLAN STEP [Read]' 'the read step is listed'
        Assert-Contains $text 'PLAN STEP [Cleanup]' 'the cleanup step is listed'
        Assert-True (11 -eq @($text.Split("`n") | Where-Object { $_.Contains('PLAN STEP [') }).Count) 'all eleven steps listed'
        $json = Get-Content -LiteralPath $out | ConvertFrom-Json
        Assert-True ($json.mode -eq 'plan') 'the JSON mode is plan'
        Assert-True ($json.overall -eq 'PlanOnly') 'the JSON overall is PlanOnly'
        Assert-True (0 -eq @($json.steps | Where-Object { $_.verdict -notin @('Skipped', 'Passed') }).Count) 'plan mode never records failed steps'
    }

    Invoke-Test 'manifest rows: empty, duplicate, absolute, ..-escape and invalid hashes are all rejected' {
        Assert-True (-not (Test-GsManifestRows -Rows $null).Accepted) 'a null manifest is rejected'
        Assert-True (-not (Test-GsManifestRows -Rows @()).Accepted) 'an empty manifest is rejected'
        $good = [pscustomobject]@{ relativePath = 'gs-console.ps1'; sha256 = ('a' * 64) }
        Assert-True (Test-GsManifestRows -Rows @($good)).Accepted 'a valid row is accepted'
        $rows = @(
            [pscustomobject]@{ relativePath = 'same.txt'; sha256 = ('a' * 64) },
            [pscustomobject]@{ relativePath = 'same.txt'; sha256 = ('b' * 64) }
        )
        $result = Test-GsManifestRows -Rows $rows
        Assert-True (-not $result.Accepted) 'duplicate relativePath rejected'
        Assert-Contains ($result.Violations -join '; ') 'duplicate relativePath: same.txt' 'the duplicate is named'
        $result = Test-GsManifestRows -Rows @([pscustomobject]@{ relativePath = 'C:\abs\path.txt'; sha256 = ('a' * 64) })
        Assert-Contains ($result.Violations -join '; ') 'absolute path not allowed' 'absolute paths rejected'
        $result = Test-GsManifestRows -Rows @([pscustomobject]@{ relativePath = 'a\..\b.txt'; sha256 = ('a' * 64) })
        Assert-Contains ($result.Violations -join '; ') 'path escapes' '..-escape rejected'
        $result = Test-GsManifestRows -Rows @([pscustomobject]@{ relativePath = 'a/b.txt'; sha256 = ('a' * 64) })
        Assert-Contains ($result.Violations -join '; ') 'foreign separators' 'forward separators rejected'
        foreach ($bad in @('short', ('Z' * 64), ('g' * 64), '')) {
            $result = Test-GsManifestRows -Rows @([pscustomobject]@{ relativePath = 'x.txt'; sha256 = $bad })
            Assert-Contains ($result.Violations -join '; ') 'invalid sha256' ('invalid hash rejected: ' + $bad)
        }
    }

    Invoke-Test 'native ABI: declarations match the documented Msi signatures exactly (reflection only)' {
        $native = Get-GsMsiNative
        $target = $native.GetMethod('MsiGetShortcutTargetW')
        Assert-True ($null -ne $target) 'MsiGetShortcutTargetW declared'
        $parameters = @($target.GetParameters())
        Assert-True (4 -eq $parameters.Count) 'four parameters'
        # Output order is product code, feature id, component code.
        Assert-True ($parameters[1].Name -eq 'szProductCode') 'the SECOND buffer is the product code'
        Assert-True ($parameters[2].Name -eq 'szFeatureId') 'the THIRD buffer is the feature id (not used as a component)'
        Assert-True ($parameters[3].Name -eq 'szComponentCode') 'the FOURTH buffer is the component code'
        foreach ($index in @(1, 2, 3)) {
            Assert-True ($parameters[$index].ParameterType -eq [System.Text.StringBuilder]) ('buffer ' + $index + ' is a StringBuilder')
        }
        $import = [Runtime.InteropServices.DllImportAttribute]($target.GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false)[0])
        Assert-True ($import.Value -eq 'msi.dll') 'imported from msi.dll'
        Assert-True $import.ExactSpelling 'ExactSpelling is set'
        $path = $native.GetMethod('MsiGetComponentPathW')
        Assert-True ($null -ne $path) 'MsiGetComponentPathW declared'
        $pathParams = @($path.GetParameters())
        Assert-True (4 -eq $pathParams.Count) 'four parameters'
        Assert-True ($pathParams[3].Name -eq 'pcchPathBuf' -and $pathParams[3].ParameterType.IsByRef -and
            $pathParams[3].ParameterType.GetElementType() -eq [uint32]) 'the buffer-size parameter is a ref uint32'
        Assert-True ($path.ReturnType -eq [int32]) 'INSTALLSTATE is signed and preserves negative error states'
        $related = $native.GetMethod('MsiEnumRelatedProductsW')
        Assert-True ($null -ne $related) 'MsiEnumRelatedProductsW declared'
        $state = $native.GetMethod('MsiQueryProductStateW')
        Assert-True ($null -ne $state -and $state.ReturnType -eq [int32]) 'MsiQueryProductStateW returns the INSTALLSTATE int'
    }

    Invoke-Test 'registration checks retain advertised and incomplete products without querying the host' {
        $originalState = (Get-Item Function:Get-GsProductState).ScriptBlock
        try {
            Set-Item Function:script:Get-GsProductState -Value { param($ProductCode) return $script:fixtureProductState }
            $script:fixtureProductState = -1
            Assert-True (-not (Test-GsProductRegistered -ProductCode 'fixture')) 'unknown is unregistered'
            foreach ($state in @(1, 2, -6)) {
                $script:fixtureProductState = $state
                Assert-True (Test-GsProductRegistered -ProductCode 'fixture') 'partial registration must block a fresh install and trigger cleanup'
                Assert-True (-not (Test-GsProductInstalled -ProductCode 'fixture')) 'partial registration is not a completed install'
            }
            $script:fixtureProductState = 5
            Assert-True (Test-GsProductInstalled -ProductCode 'fixture') 'default state is installed'
        } finally { Set-Item Function:script:Get-GsProductState -Value $originalState }
    }

    Invoke-Test 'masking: the session token never survives into diagnostic text' {
        $token = [guid]::NewGuid().ToString('N')
        $masked = Get-GsMaskedText -Text ('launch url http://127.0.0.1:1/#session=' + $token + ' end') -Secret $token
        Assert-True (-not $masked.Contains($token)) 'the token is gone'
        Assert-Contains $masked '[masked-session]' 'the mask marker is present'
        Assert-True ((Get-GsMaskedText -Text 'plain' -Secret '') -eq 'plain') 'an empty secret is a no-op'
        Assert-True ((Get-GsMaskedText -Text '' -Secret $token) -eq '') 'empty text stays empty'
    }

    Invoke-Test 'reparse walk: plain temp chains are clean, junction ancestors are named' {
        $plain = Join-Path $workDir 'plain-dir'
        New-Item -ItemType Directory -Path $plain -Force | Out-Null
        Assert-True ($null -eq (Test-GsReparseAncestor -Path $plain)) 'a plain directory chain has no reparse ancestor'
        $realDir = Join-Path $workDir 'junction-target'
        New-Item -ItemType Directory -Path $realDir -Force | Out-Null
        $link = Join-Path $workDir 'junction-link'
        $null = & cmd.exe /d /c mklink /J "$link" "$realDir"
        if ($LASTEXITCODE -ne 0) { throw 'mklink /J failed for the junction fixture' }
        try {
            $found = Test-GsReparseAncestor -Path (Join-Path $link 'sub')
            Assert-True ($null -ne $found -and $found.EndsWith('junction-link')) 'a junction ancestor is detected and named'
        } finally {
            # Remove the link itself first so no recursive delete follows it.
            $null = & cmd.exe /d /c rmdir "$link"
        }
    }

} finally {
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}

Write-Host ("Summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
