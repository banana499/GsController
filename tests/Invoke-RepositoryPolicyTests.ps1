#Requires -Version 5.1
<#
.SYNOPSIS
    Static checks for the public CI trust boundary. No workflow code is run.
    The YAML checks deliberately accept a small, explicit layout, not all YAML.
    Negative in-memory fixtures prove that broadening key boundaries is rejected.
    This is not a YAML parser or a substitute for GitHub workflow validation.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
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

function Get-PolicyErrors {
    param([string]$Text)
    $textLf = $Text.Replace("`r`n", "`n")
    $errors = New-Object 'System.Collections.Generic.List[string]'
    # Match the whole event/permission blocks, not a permissive substring.
    if ($textLf -notmatch '(?m)^on:\n  push:\n  pull_request:\n\n') { $errors.Add('events') }
    if ($textLf -notmatch '(?m)^permissions:\n  contents: read\n\n' -or
        @([regex]::Matches($textLf, '(?m)^\s*permissions:')).Count -ne 1) { $errors.Add('permissions') }
    if ($textLf -match '(?i)pull_request_target|workflow_run|secrets\s*[.\[]|id-token|write-all|self-hosted|continue-on-error:') { $errors.Add('trust') }
    if ($textLf -match "`t" -or $textLf -match '(?m)^\s*(?:<<:|[&*!])') { $errors.Add('unsupported-yaml') }
    $topKeys = @([regex]::Matches($textLf, '(?m)^([a-z][a-z-]*):') | ForEach-Object { $_.Groups[1].Value })
    if (($topKeys -join ',') -cne 'name,on,permissions,concurrency,jobs') { $errors.Add('top-level') }
    $jobs = [regex]::Match($textLf, '(?ms)^jobs:\n(.+)\z').Groups[1].Value
    if (@([regex]::Matches($jobs, '(?m)^  [a-z][a-z0-9_-]*:\s*$')).Count -ne 1 -or
        $textLf -notmatch '(?m)^jobs:\n  safe-tests:\n    runs-on: windows-2022\n    timeout-minutes: (?:[1-9]|[1-5][0-9]|60)\n') { $errors.Add('runner') }
    if (@([regex]::Matches($textLf, '(?m)^\s*shell:')).Count -ne 1 -or
        $textLf -notmatch '(?m)^        shell: powershell\.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \{0\}$') { $errors.Add('shell') }
    $actions = @([regex]::Matches($textLf, '(?m)^\s*uses: (.+)$') | ForEach-Object { $_.Groups[1].Value })
    if (($actions -join ',') -cne 'actions/checkout@v4,actions/upload-artifact@v4' -or
        @([regex]::Matches($textLf, '(?m)^      - name:')).Count -ne 3) { $errors.Add('steps') }
    if ($textLf -notmatch '(?m)^          persist-credentials: false$') { $errors.Add('credentials') }
    if ($textLf -match '(?i)-IncludeIntegration\b|-TestsDir\b' -or
        $textLf -match '(?m)^\s*(?:env|environment|services|container):') { $errors.Add('safe-default') }
    $upload = [regex]::Match($textLf, '(?m)^          path: \|\n((?:            .+\n)+)')
    $expectedPaths = @(
        '${{ runner.temp }}/gs-fixture-logs/stdout.log',
        '${{ runner.temp }}/gs-fixture-logs/stderr.log',
        '${{ runner.temp }}/gs-fixture-logs/Invoke-All-*-Invoke-*Tests.log'
    )
    $actualPaths = @($upload.Groups[1].Value.TrimEnd("`n").Split("`n") | ForEach-Object { $_.Trim() })
    if (($actualPaths -join "`n") -cne ($expectedPaths -join "`n") -or
        @([regex]::Matches($textLf, '(?m)^\s*path:')).Count -ne 1) { $errors.Add('upload-scope') }
    if ($textLf -notmatch '(?m)^        if: always\(\)\n        uses: actions/upload-artifact@v4$' -or
        $textLf -notmatch '(?m)^          include-hidden-files: false$' -or
        $textLf -notmatch '(?m)^          retention-days: [1-7]$' -or
        $textLf -notmatch '(?m)^          if-no-files-found: warn$') { $errors.Add('upload-policy') }

    $run = [regex]::Match($textLf, '(?m)^        run: \|\n((?:          .*\n|\n)+)')
    if (-not $run.Success -or @([regex]::Matches($textLf, '(?m)^\s*run: \|')).Count -ne 1) {
        $errors.Add('run-block')
        return $errors.ToArray()
    }
    $code = [regex]::Replace($run.Groups[1].Value, '(?m)^          ', '')
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { $errors.Add('powershell-syntax') }
    $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    $allowedCommands = @('Join-Path', 'New-Item', 'Out-Null', 'Start-Process', 'Get-Content', 'Get-ChildItem', 'Copy-Item')
    foreach ($command in $commands) {
        if ($allowedCommands -notcontains $command.GetCommandName()) { $errors.Add('command-allowlist') }
    }
    $starts = @($commands | Where-Object { $_.GetCommandName() -eq 'Start-Process' })
    if ($starts.Count -ne 1) { $errors.Add('child-process') } else {
        $start = $starts[0].Extent.Text
        if ($start -notmatch '-FilePath \$powershellExe\b' -or
            $start -notmatch '-ArgumentList @\(''-NoProfile'', ''-NonInteractive'', ''-ExecutionPolicy'', ''Bypass'', ''-File'', ''"\.\\tests\\Invoke-All\.ps1"''\)' -or
            $start -notmatch '-WorkingDirectory \$env:GITHUB_WORKSPACE\b' -or
            $start -notmatch '-RedirectStandardOutput \$stdout\b' -or
            $start -notmatch '-RedirectStandardError \$stderr\b' -or
            $start -notmatch '-Wait\b' -or $start -notmatch '-PassThru\b') { $errors.Add('child-process') }
    }
    if ($code -notmatch "(?m)^\s*if \(\`$PSVersionTable.PSEdition -ne 'Desktop' -or \`$PSVersionTable.PSVersion.Major -ne 5 -or \`$PSVersionTable.PSVersion.Minor -ne 1\)" -or
        $code -notmatch "(?m)^\`$powershellExe = Join-Path \`$env:SystemRoot 'System32\\WindowsPowerShell\\v1.0\\powershell.exe'$") { $errors.Add('powershell-version') }
    if ($code -notmatch '(?m)^\$process = Start-Process .+\n\$testExitCode = \$process.ExitCode\n' -or
        $code -notmatch '(?m)^if \(\$null -eq \$testExitCode\) \{ throw ''[^'']+'' \}\nexit \$testExitCode$' -or
        $code.TrimEnd() -notmatch '(?m)^exit \$testExitCode$' -or
        @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)).Count -ne 1 -or
        @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$testExitCode' }, $true)).Count -ne 1) { $errors.Add('exit-code') }
    if ($code -notmatch '(?m)^\$env:TEMP = \$fixtureRoot\n\$env:TMP = \$fixtureRoot$' -or
        $code -notmatch "(?m)^\`$logRoot = Join-Path \`$env:RUNNER_TEMP 'gs-fixture-logs'$" -or
        $code -notmatch "(?m)^\`$fixtureRoot = Join-Path \`$env:RUNNER_TEMP \('gs-fixture-work-' \+ \[guid\]::NewGuid\(\).ToString\('N'\)\)$" -or
        $code -notmatch "(?m)^Get-ChildItem -LiteralPath \`$fixtureRoot -Filter 'Invoke-All-\*-Invoke-\*Tests.log' -File \| Copy-Item -Destination \`$logRoot$" -or
        $code -match '(?i)-Recurse\b') { $errors.Add('log-collection') }
    return $errors.ToArray()
}

$workflowPath = Join-Path $repoRoot '.github\workflows\windows-tests.yml'
$workflow = [System.IO.File]::ReadAllText($workflowPath)
Invoke-Test 'Workflow satisfies the default safe CI contract' {
    $errors = @(Get-PolicyErrors $workflow)
    Assert-True ($errors.Count -eq 0) ('policy violations: ' + ($errors -join ', '))
}

$mutations = @(
    @{ Name = 'privileged PR event'; From = '  pull_request:'; To = '  pull_request_target:'; Error = 'events' },
    @{ Name = 'write permission'; From = '  contents: read'; To = '  contents: write'; Error = 'permissions' },
    @{ Name = 'job permission override'; From = '    runs-on:'; To = "    permissions: write-all`n    runs-on:"; Error = 'permissions' },
    @{ Name = 'self-hosted runner'; From = 'runs-on: windows-2022'; To = 'runs-on: self-hosted'; Error = 'runner' },
    @{ Name = 'PowerShell 7 shell'; From = 'shell: powershell.exe'; To = 'shell: pwsh'; Error = 'shell' },
    @{ Name = 'retained checkout credential'; From = 'persist-credentials: false'; To = 'persist-credentials: true'; Error = 'credentials' },
    @{ Name = 'integration switch'; From = 'Invoke-All.ps1'; To = 'Invoke-All.ps1 -IncludeIntegration'; Error = 'safe-default' },
    @{ Name = 'masked failure exit'; From = 'exit $testExitCode'; To = 'exit 0'; Error = 'exit-code' },
    @{ Name = 'missing exit-code guard'; From = 'if ($null -eq $testExitCode)'; To = 'if ($false)'; Error = 'exit-code' },
    @{ Name = 'unawaited child'; From = ' -Wait -PassThru'; To = ' -PassThru'; Error = 'child-process' },
    @{ Name = 'broad artifact glob'; From = '/gs-fixture-logs/stdout.log'; To = '/**'; Error = 'upload-scope' },
    @{ Name = 'hidden artifact files'; From = 'include-hidden-files: false'; To = 'include-hidden-files: true'; Error = 'upload-policy' },
    @{ Name = 'recursive temp copy'; From = '-File | Copy-Item'; To = '-File -Recurse | Copy-Item'; Error = 'log-collection' },
    @{ Name = 'host temp collection'; From = '-LiteralPath $fixtureRoot -Filter'; To = '-LiteralPath $env:LOCALAPPDATA -Filter'; Error = 'log-collection' },
    @{ Name = 'product execution'; From = 'Get-Content -LiteralPath $stdout, $stderr'; To = '& .\product\gs-product.ps1 -Action Install'; Error = 'command-allowlist' },
    @{ Name = 'secret expression'; From = 'name: Windows fixture tests'; To = 'name: ${{ secrets.TEST_TOKEN }}'; Error = 'trust' }
)
foreach ($mutation in $mutations) {
    Invoke-Test ('Reject ' + $mutation.Name) {
        Assert-True ($workflow.Contains($mutation.From)) 'mutation must actually change the fixture'
        $errors = @(Get-PolicyErrors ($workflow.Replace($mutation.From, $mutation.To)))
        Assert-True ($errors -contains $mutation.Error) ('expected violation: ' + $mutation.Error)
    }
}

Invoke-Test 'New source is ASCII and PowerShell 5.1 parses it' {
    $sourcePath = Join-Path $PSScriptRoot 'Invoke-RepositoryPolicyTests.ps1'
    Assert-True (@([System.IO.File]::ReadAllBytes($sourcePath) | Where-Object { $_ -gt 127 }).Count -eq 0) 'ASCII source'
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'PowerShell syntax'
}

Invoke-Test 'Contribution and security documents are strict UTF-8 without BOM' {
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    foreach ($name in @('CONTRIBUTING.md', 'SECURITY.md')) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot $name))
        Assert-True ($bytes.Length -gt 0) ('nonempty: ' + $name)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) ('no BOM: ' + $name)
        [void]$encoding.GetString($bytes)
    }
}

Write-Host ("Summary: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
