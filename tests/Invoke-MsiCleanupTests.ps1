#Requires -Version 5.1
<#
.SYNOPSIS
    Offline checks for the MSI uninstall cleanup wiring in
    installer/GsController.wxs (security design 3.5: run the deployed
    PrepareUninstall CLI before RemoveFiles, then delete the fixed-name
    supervisor task with schtasks as a fallback - on plain uninstalls
    only).

.DESCRIPTION
    Unit-level only; three layers, all offline and read-only:

    1. Structure (always runs): parse the real installer/GsController.wxs
       and assert both cleanup custom actions are declared inside the
       Product element (so they are always linked into the final
       database), are deferred + no-impersonate + return-ignore, use
       explicit 64-bit system paths instead of a PATH lookup, invoke the
       deployed gs-product.ps1 through -File (never an ad-hoc
       -Command/-EncodedCommand expression), are scheduled before
       RemoveFiles with the uninstall-only condition, and keep the fixed
       task name in sync with the gs-product.ps1 constants.

    2. Condition semantics (always runs): evaluate the REAL condition
       strings parsed out of the wxs with a small offline fixture
       evaluator over five scenarios - fresh install, repair and feature
       modify (false), plain uninstall (true), major upgrade old-product
       removal (false, keeps the task for the upgraded product).

    3. Built MSI database (skipped with an explicit SKIP line when the
       WiX3 toolchain is absent; default C:\Tools\GsBuild\wix314, the
       same default as scripts/build-product.ps1): stage synthetic
       fixture files in %TEMP% (a fake gs-product.ps1, fake module and
       bin files; the real runtime-bundle is never read), compile with
       heat/candle/light exactly like scripts/build-product.ps1, then
       open the resulting MSI through the WindowsInstaller COM API in
       READ-ONLY mode (msiOpenDatabaseModeReadOnly = 0) and assert the
       CustomAction table (ids, type 34 + deferred + no-impersonate +
       continue-on-error, working directories, full command lines) and
       the InstallExecuteSequence (conditions, ordering against
       InstallInitialize / RemoveExistingProducts / RemoveFiles, absence
       from InstallUISequence).

    Safety envelope: this suite never runs msiexec, never installs or
    uninstalls anything, never queries, registers, deletes or stops any
    real scheduled task, service, registry value or ACL, never touches
    the real runtime-bundle, never calls another test suite, and writes
    only inside its own %TEMP% fixture directory (removed afterwards).

    Exits 0 only when at least one test ran and none failed. A missing
    WiX toolchain skips layer 3 explicitly but never skips layers 1-2,
    and a build or database failure is a FAIL, never a silent skip.
#>
[CmdletBinding()]
param(
    # WiX3 toolchain directory (heat.exe/candle.exe/light.exe). Empty means
    # the scripts/build-product.ps1 default: C:\Tools\GsBuild\wix314.
    [string]$WixDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$wxsPath = Join-Path $repoRoot 'installer\GsController.wxs'
$productPath = Join-Path $repoRoot 'product\gs-product.ps1'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

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
        $atLine = ''
        if ($null -ne $_.InvocationInfo) { $atLine = (' (line ' + $_.InvocationInfo.ScriptLineNumber + ')') }
        Write-Host "FAIL $Name :: $($_.Exception.Message)$atLine"
    }
}

function Invoke-Skip {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Reason
    )
    $script:Skipped++
    Write-Host "SKIP $Name :: $Reason"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message (expected '$Expected', actual '$Actual')"
    }
}

function Get-NormalizedCondition {
    param([string]$Text)
    return (($Text -replace '\s+', ' ').Trim())
}

# ---------------------------------------------------------------------------
# Shared inputs: the real wxs parsed once, plus the product constants that
# the wiring must stay in sync with.
# ---------------------------------------------------------------------------
$script:WxsDoc = New-Object System.Xml.XmlDocument
$script:WxsDoc.Load($wxsPath)
$script:NsMgr = New-Object System.Xml.XmlNamespaceManager($script:WxsDoc.NameTable)
$script:NsMgr.AddNamespace('w', 'http://schemas.microsoft.com/wix/2006/wi')
$script:PrepareActionId = 'GsPrepareUninstall'
$script:TaskActionId = 'GsRemoveSupervisorTask'
$script:TaskName = 'GsControllerSupervisor'
$script:UninstallCondition = 'REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE'
$script:MsiPath = ''

function Get-CustomActionNode {
    param([Parameter(Mandatory = $true)][string]$Id)
    $nodes = @($script:WxsDoc.SelectNodes(('//w:Product/w:CustomAction[@Id="' + $Id + '"]'), $script:NsMgr))
    if ($nodes.Count -ne 1) {
        throw ('Expected exactly one CustomAction ' + $Id + ' inside Product, found ' + $nodes.Count)
    }
    return $nodes[0]
}

function Get-SequenceEntryNode {
    param([Parameter(Mandatory = $true)][string]$ActionId)
    $nodes = @($script:WxsDoc.SelectNodes(('//w:Product/w:InstallExecuteSequence/w:Custom[@Action="' + $ActionId + '"]'), $script:NsMgr))
    if ($nodes.Count -ne 1) {
        throw ('Expected exactly one InstallExecuteSequence entry for ' + $ActionId + ', found ' + $nodes.Count)
    }
    return $nodes[0]
}

# Evaluator for exactly the condition grammar the wxs uses:
#   clause ( " AND " clause )*,  clause := PROP="value"  |  "NOT " PROP
# Offline MSI approximation: PROP="value" compares the property's string
# value (undefined -> ''); NOT PROP is true when the property is undefined
# or empty. The evaluator THROWS on any clause shape outside this grammar,
# so a wxs condition change that the scenarios below no longer cover fails
# loudly instead of silently passing.
function Test-GsConditionText {
    param(
        [Parameter(Mandatory = $true)][string]$Condition,
        [Parameter(Mandatory = $true)][hashtable]$Properties
    )
    $clauses = @($Condition -split ' AND ' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($clauses.Count -eq 0) { throw 'Empty condition text' }
    foreach ($clause in $clauses) {
        if ($clause.StartsWith('NOT ')) {
            $name = $clause.Substring(4).Trim()
            if ($name -eq '' -or $name -match '[="()]') { throw ('Unsupported NOT clause: ' + $clause) }
            $value = ''
            if ($Properties.ContainsKey($name)) { $value = [string]$Properties[$name] }
            if (-not [string]::IsNullOrEmpty($value)) { return $false }
        } elseif ($clause -match '^([A-Za-z_][A-Za-z0-9_.]*)="([^"]*)"$') {
            $name = $Matches[1]
            $value = ''
            if ($Properties.ContainsKey($name)) { $value = [string]$Properties[$name] }
            if ($value -ne $Matches[2]) { return $false }
        } else {
            throw ('Unsupported condition clause: ' + $clause)
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# Layer 1: structure of the real GsController.wxs.
# ---------------------------------------------------------------------------

Invoke-Test 'structure: both cleanup actions are declared inside Product (always linked)' {
    $products = @($script:WxsDoc.SelectNodes('//w:Product', $script:NsMgr))
    Assert-True ($products.Count -eq 1) 'exactly one Product element expected'
    $insideProduct = @($products[0].SelectNodes('w:CustomAction', $script:NsMgr))
    $ids = @($insideProduct | ForEach-Object { $_.GetAttribute('Id') })
    Assert-True (1 -eq @($ids | Where-Object { $_ -eq $script:PrepareActionId }).Count) 'GsPrepareUninstall declared exactly once inside Product'
    Assert-True (1 -eq @($ids | Where-Object { $_ -eq $script:TaskActionId }).Count) 'GsRemoveSupervisorTask declared exactly once inside Product'
    $fragmentActions = @($script:WxsDoc.SelectNodes('//w:Fragment//w:CustomAction', $script:NsMgr))
    Assert-True (0 -eq $fragmentActions.Count) 'no custom action hidden in a Fragment (an unreferenced Fragment copy would silently link nothing)'
}

Invoke-Test 'structure: both actions are deferred, no-impersonate and return-ignore' {
    foreach ($id in @($script:PrepareActionId, $script:TaskActionId)) {
        $node = Get-CustomActionNode -Id $id
        Assert-Equal 'deferred' $node.GetAttribute('Execute') ($id + ' Execute')
        Assert-Equal 'no' $node.GetAttribute('Impersonate') ($id + ' Impersonate (needs the elevated session for the task removal)')
        Assert-Equal 'ignore' $node.GetAttribute('Return') ($id + ' Return (cleanup failure must not block the MSI uninstall)')
    }
}

Invoke-Test 'structure: PrepareUninstall action calls the deployed CLI via explicit system PowerShell and -File' {
    $node = Get-CustomActionNode -Id $script:PrepareActionId
    Assert-Equal 'INSTALLFOLDER' $node.GetAttribute('Directory') 'working directory (the CLI is staged at the install root)'
    $command = $node.GetAttribute('ExeCommand')
    Assert-True ($command.StartsWith('"[WindowsFolder]System32\WindowsPowerShell\v1.0\powershell.exe"')) 'command starts with the quoted 64-bit system PowerShell (no PATH lookup; System32 is the 64-bit folder in the x64 package)'
    Assert-True ($command.Contains('-File "[INSTALLFOLDER]gs-product.ps1"')) 'the deployed gs-product.ps1 is referenced by -File with a quoted INSTALLFOLDER path'
    Assert-True ($command.EndsWith('-Action PrepareUninstall')) 'the command is exactly the PrepareUninstall invocation (no extra arguments)'
    Assert-True (-not $command.Contains('-Command')) 'no -Command expression concatenation'
    Assert-True (-not $command.Contains('-EncodedCommand')) 'no -EncodedCommand expression'
    Assert-True (-not ($command -match '(?<!\\)powershell\.exe ')) 'no bare powershell.exe PATH lookup anywhere in the command'
}

Invoke-Test 'structure: schtasks fallback deletes the fixed supervisor task via explicit system path' {
    $node = Get-CustomActionNode -Id $script:TaskActionId
    Assert-Equal 'SystemFolder' $node.GetAttribute('Directory') 'working directory (resolves to the 64-bit system folder in the x64 package)'
    $command = $node.GetAttribute('ExeCommand')
    Assert-True ($command.StartsWith('"[WindowsFolder]System32\schtasks.exe"')) 'command starts with the quoted 64-bit system schtasks.exe (no PATH lookup)'
    Assert-True ($command.Contains('/Delete')) 'schtasks deletes (not creates) the task'
    Assert-True ($command.Contains('/TN "' + $script:TaskName + '"')) 'the fixed supervisor task name is passed quoted'
    Assert-True ($command.EndsWith('/F')) 'the fallback force-deletes so a second cleanup is idempotent'
}

Invoke-Test 'structure: fallback task name matches the gs-product.ps1 constants' {
    $productText = [System.IO.File]::ReadAllText($productPath)
    $paramMatches = [System.Text.RegularExpressions.Regex]::Matches($productText, '\[string\]\$SupervisorTaskName\s*=\s*''([^'']+)''')
    Assert-True ($paramMatches.Count -ge 1) 'gs-product.ps1 declares a $SupervisorTaskName default'
    foreach ($match in $paramMatches) {
        Assert-Equal $script:TaskName $match.Groups[1].Value 'the $SupervisorTaskName default stays the fixed task name'
    }
    $literalMatches = [System.Text.RegularExpressions.Regex]::Matches($productText, '\$taskName\s*=\s*''([^'']+)''')
    Assert-True ($literalMatches.Count -ge 1) 'gs-product.ps1 (UnregisterAutostart) assigns a literal $taskName'
    foreach ($match in $literalMatches) {
        Assert-Equal $script:TaskName $match.Groups[1].Value 'the UnregisterAutostart literal stays the fixed task name'
    }
}

Invoke-Test 'structure: user data and ACLs are untouched by both commands' {
    foreach ($id in @($script:PrepareActionId, $script:TaskActionId)) {
        $command = (Get-CustomActionNode -Id $id).GetAttribute('ExeCommand')
        Assert-True (-not $command.Contains('icacls')) ('no ACL tooling in ' + $id)
        Assert-True (-not $command.Contains('Remove-Item')) ('no file deletion outside the MSI RemoveFiles in ' + $id)
        Assert-True (-not $command.Contains('-StateDir')) ('no custom StateDir argument in ' + $id + ' (the MSI path drives the default layout only)')
        Assert-True (-not $command.Contains('-LogDir')) ('no custom LogDir argument in ' + $id + ' (StateDir/LogDir stay for the operator)')
    }
}

Invoke-Test 'structure: execution sequence is uninstall-only and ordered CLI -> task fallback -> RemoveFiles' {
    $prepareEntry = Get-SequenceEntryNode -ActionId $script:PrepareActionId
    $taskEntry = Get-SequenceEntryNode -ActionId $script:TaskActionId
    Assert-Equal $script:TaskActionId $prepareEntry.GetAttribute('Before') 'PrepareUninstall runs before the schtasks fallback'
    Assert-Equal 'RemoveFiles' $taskEntry.GetAttribute('Before') 'the fallback runs before RemoveFiles (gs-product.ps1 must still exist for the CLI step)'
    Assert-Equal (Get-NormalizedCondition -Text $script:UninstallCondition) (Get-NormalizedCondition -Text $prepareEntry.InnerText) 'PrepareUninstall carries the uninstall-only condition'
    Assert-Equal (Get-NormalizedCondition -Text $script:UninstallCondition) (Get-NormalizedCondition -Text $taskEntry.InnerText) 'the schtasks fallback carries the uninstall-only condition'
    $uiEntries = @($script:WxsDoc.SelectNodes('//w:Product/w:InstallUISequence/w:Custom', $script:NsMgr))
    foreach ($entry in $uiEntries) {
        $action = $entry.GetAttribute('Action')
        Assert-True (($action -ne $script:PrepareActionId) -and ($action -ne $script:TaskActionId)) ('deferred cleanup must not run in the UI sequence: ' + $action)
    }
}

# ---------------------------------------------------------------------------
# Layer 2: condition semantics, evaluated offline over the REAL wxs strings.
# ---------------------------------------------------------------------------
$script:PrepareCondition = Get-NormalizedCondition -Text (Get-SequenceEntryNode -ActionId $script:PrepareActionId).InnerText
$script:TaskCondition = Get-NormalizedCondition -Text (Get-SequenceEntryNode -ActionId $script:TaskActionId).InnerText

Invoke-Test 'condition: fresh install does not run cleanup' {
    Assert-True (-not (Test-GsConditionText -Condition $script:PrepareCondition -Properties @{})) 'install scenario (REMOVE undefined) against the PrepareUninstall condition'
    Assert-True (-not (Test-GsConditionText -Condition $script:TaskCondition -Properties @{})) 'install scenario (REMOVE undefined) against the fallback condition'
}

Invoke-Test 'condition: repair does not run cleanup' {
    $properties = @{}
    Assert-True (-not (Test-GsConditionText -Condition $script:PrepareCondition -Properties $properties)) 'repair scenario (REMOVE unset) against the PrepareUninstall condition'
    Assert-True (-not (Test-GsConditionText -Condition $script:TaskCondition -Properties $properties)) 'repair scenario (REMOVE unset) against the fallback condition'
}

Invoke-Test 'condition: feature modify does not run cleanup' {
    $properties = @{ REMOVE = 'Main' }
    Assert-True (-not (Test-GsConditionText -Condition $script:PrepareCondition -Properties $properties)) 'modify scenario (REMOVE lists features, not ALL)'
    Assert-True (-not (Test-GsConditionText -Condition $script:TaskCondition -Properties $properties)) 'modify scenario against the fallback condition'
}

Invoke-Test 'condition: plain uninstall runs cleanup' {
    $properties = @{ REMOVE = 'ALL' }
    Assert-True (Test-GsConditionText -Condition $script:PrepareCondition -Properties $properties) 'plain uninstall (REMOVE=ALL, no UPGRADINGPRODUCTCODE)'
    Assert-True (Test-GsConditionText -Condition $script:TaskCondition -Properties $properties) 'plain uninstall against the fallback condition'
}

Invoke-Test 'condition: major upgrade old-product removal keeps the task for the new version' {
    $properties = @{ REMOVE = 'ALL'; UPGRADINGPRODUCTCODE = '{11111111-2222-3333-4444-555555555555}' }
    Assert-True (-not (Test-GsConditionText -Condition $script:PrepareCondition -Properties $properties)) 'old-product removal during a major upgrade is excluded (NOT UPGRADINGPRODUCTCODE)'
    Assert-True (-not (Test-GsConditionText -Condition $script:TaskCondition -Properties $properties)) 'old-product removal is excluded from the fallback too'
}

# ---------------------------------------------------------------------------
# Layer 3: fixture build + read-only MSI database checks. Skipped only when
# the WiX toolchain is absent; never skipped silently, never skipped when a
# build or database read fails.
# ---------------------------------------------------------------------------
$wixRoot = $WixDir
if ([string]::IsNullOrWhiteSpace($wixRoot)) { $wixRoot = 'C:\Tools\GsBuild\wix314' }
$heat = Join-Path $wixRoot 'heat.exe'
$candle = Join-Path $wixRoot 'candle.exe'
$light = Join-Path $wixRoot 'light.exe'
$toolsFound = @(@($heat, $candle, $light) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

if ($toolsFound.Count -ne 3) {
    Invoke-Skip -Name 'MSI build layer (heat/candle/light + read-only database checks)' `
        -Reason ("WiX toolchain incomplete under '{0}' (found {1} of 3 tools); pass -WixDir to point at one. The structure and condition layers still ran." -f $wixRoot, $toolsFound.Count)
} else {
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('GsMsiCleanup_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath
    try {
        # Synthetic fixture stage: a fake entry point, fake module files and
        # a fake bin payload. Nothing from the real runtime-bundle is read.
        $stage = Join-Path $workDir 'stage'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $ascii = New-Object System.Text.ASCIIEncoding
        [System.IO.File]::WriteAllText((Join-Path $stage 'gs-product.ps1'), "# fixture entry point for the offline MSI build; never executed by tests.`r`nparam()`r`n", $ascii)
        foreach ($moduleName in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
            $moduleDir = Join-Path $stage ('Modules\' + $moduleName)
            New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $moduleDir ($moduleName + '.psd1')), "# fixture module manifest`r`n", $ascii)
            [System.IO.File]::WriteAllText((Join-Path $moduleDir ($moduleName + '.psm1')), "# fixture module body`r`n", $ascii)
        }
        New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $stage 'bin\gs_fake_runtime.txt'), "fixture runtime payload placeholder`r`n", $ascii)

        Invoke-Test 'MSI build: heat/candle/light compile the real wxs into a fixture MSI' {
            $buildDir = Join-Path $workDir 'build'
            New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
            $harvest = Join-Path $buildDir 'ProductFiles.wxs'
            $stageDir = (Resolve-Path -LiteralPath $stage).ProviderPath
            & $heat dir $stageDir -nologo -cg ProductFiles -gg -g1 -srd -sreg -dr INSTALLFOLDER -var var.StageDir -out $harvest
            if ($LASTEXITCODE -ne 0) { throw ('heat.exe failed with exit code ' + $LASTEXITCODE) }
            & $candle -nologo -arch x64 '-dVersion=0.0.1' ('-dStageDir=' + $stageDir) -out ($buildDir + '\') $wxsPath $harvest
            if ($LASTEXITCODE -ne 0) { throw ('candle.exe failed with exit code ' + $LASTEXITCODE) }
            $msi = Join-Path $workDir 'GsController-0.0.1.msi'
            & $light -nologo -out $msi (Join-Path $buildDir 'GsController.wixobj') (Join-Path $buildDir 'ProductFiles.wixobj')
            if ($LASTEXITCODE -ne 0) { throw ('light.exe failed with exit code ' + $LASTEXITCODE) }
            Assert-True ([System.IO.File]::Exists($msi)) 'the fixture MSI was produced (no msiexec involved anywhere)'
            $script:MsiPath = $msi
        }

        # Read-only MSI database helper: OpenDatabase mode 0 is
        # msiOpenDatabaseModeReadOnly. Nothing here (or anywhere in this
        # suite) calls ConfigureProduct/InstallProduct or mode 1. The COM
        # calls are direct IDispatch calls (PowerShell marshals the string
        # and integer arguments itself); Type::InvokeMember-based late
        # binding mis-binds these arguments.
        function Get-MsiDatabaseRows {
            param(
                [Parameter(Mandatory = $true)][string]$MsiPath,
                [Parameter(Mandatory = $true)][string]$Sql,
                # Number of selected columns. The COM record's FieldCount
                # property is not reachable through the PowerShell RCW, so
                # the caller states the column count up front.
                [Parameter(Mandatory = $true)][int]$Columns
            )
            if ([string]::IsNullOrEmpty($MsiPath)) {
                throw 'no fixture MSI to read (the build step failed; see its FAIL line above)'
            }
            $installer = New-Object -ComObject WindowsInstaller.Installer
            try {
                $database = $installer.OpenDatabase($MsiPath, 0)
                try {
                    $view = $database.OpenView($Sql)
                    try {
                        # Out-Null: the COM call otherwise emits a $null into
                        # this function's output pipeline and corrupts the
                        # returned collection.
                        $view.Execute() | Out-Null
                        $rows = @()
                        while ($true) {
                            $record = $view.Fetch()
                            if ($null -eq $record) { break }
                            $row = @()
                            for ($i = 1; $i -le $Columns; $i++) {
                                $row += [string]$record.StringData($i)
                            }
                            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($record) | Out-Null
                            $rows += , $row
                        }
                        return @($rows)
                    } finally {
                        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($view) | Out-Null
                    }
                } finally {
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($database) | Out-Null
                }
            } finally {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null
            }
        }

        Invoke-Test 'MSI database: both actions linked with type 34 deferred no-impersonate continue-on-error' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Action`, `Type`, `Source`, `Target` FROM `CustomAction`' -Columns 4)
            $byAction = @{}
            foreach ($row in $rows) { $byAction[$row[0]] = $row }
            Assert-True $byAction.ContainsKey($script:PrepareActionId) 'GsPrepareUninstall row exists in the CustomAction table (linked into the final database)'
            Assert-True $byAction.ContainsKey($script:TaskActionId) 'GsRemoveSupervisorTask row exists in the CustomAction table (linked into the final database)'
            foreach ($id in @($script:PrepareActionId, $script:TaskActionId)) {
                $row = $byAction[$id]
                # 34 = exe + working directory from Source; modifiers:
                # 0x40 continue-on-error (Return="ignore"), 0x400 deferred
                # (Execute="deferred"), 0x800 no-impersonate (Impersonate="no").
                Assert-Equal '3170' $row[1] ($id + ' Type (34 exe+directory + 64 continue-on-error + 1024 deferred + 2048 no-impersonate)')
                if ($id -eq $script:PrepareActionId) {
                    Assert-Equal 'INSTALLFOLDER' $row[2] ($id + ' working directory column')
                } else {
                    Assert-Equal 'SystemFolder' $row[2] ($id + ' working directory column')
                }
            }
        }

        Invoke-Test 'MSI database: command lines keep the explicit system paths, the -File call and the task fallback' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Action`, `Target` FROM `CustomAction`' -Columns 2)
            $byAction = @{}
            foreach ($row in $rows) { $byAction[$row[0]] = $row }
            $prepareTarget = $byAction[$script:PrepareActionId][1]
            Assert-True ($prepareTarget.StartsWith('"[WindowsFolder]System32\WindowsPowerShell\v1.0\powershell.exe"')) 'compiled PrepareUninstall target keeps the quoted 64-bit system PowerShell path'
            Assert-True ($prepareTarget.Contains('-File "[INSTALLFOLDER]gs-product.ps1"')) 'compiled PrepareUninstall target keeps the -File reference to the deployed CLI'
            Assert-True ($prepareTarget.EndsWith('-Action PrepareUninstall')) 'compiled PrepareUninstall target is exactly the PrepareUninstall invocation'
            Assert-True (-not $prepareTarget.Contains('-Command')) 'compiled target has no -Command expression'
            $taskTarget = $byAction[$script:TaskActionId][1]
            Assert-True ($taskTarget.StartsWith('"[WindowsFolder]System32\schtasks.exe"')) 'compiled fallback target keeps the quoted 64-bit system schtasks.exe path'
            Assert-True ($taskTarget.Contains('/TN "' + $script:TaskName + '"')) 'compiled fallback target keeps the quoted fixed task name'
            foreach ($target in @($prepareTarget, $taskTarget)) {
                Assert-True (-not $target.Contains('icacls')) 'no ACL tooling in the compiled targets'
                Assert-True (-not $target.Contains('-StateDir')) 'no custom StateDir argument (default layout only, per the documented boundary)'
                Assert-True (-not $target.Contains('-LogDir')) 'no custom LogDir argument (user data stays)'
            }
        }

        Invoke-Test 'MSI database: execution sequence conditions and order against InstallInitialize/RemoveFiles' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Action`, `Condition`, `Sequence` FROM `InstallExecuteSequence`' -Columns 3)
            $byAction = @{}
            foreach ($row in $rows) { $byAction[$row[0]] = $row }
            Assert-True $byAction.ContainsKey($script:PrepareActionId) 'GsPrepareUninstall sequenced in InstallExecuteSequence'
            Assert-True $byAction.ContainsKey($script:TaskActionId) 'GsRemoveSupervisorTask sequenced in InstallExecuteSequence'
            Assert-True $byAction.ContainsKey('InstallInitialize') 'InstallInitialize present (deferred actions run inside the execute transaction)'
            Assert-True $byAction.ContainsKey('RemoveFiles') 'RemoveFiles present'
            Assert-True $byAction.ContainsKey('RemoveExistingProducts') 'RemoveExistingProducts present (MajorUpgrade wired, so the NOT UPGRADINGPRODUCTCODE case is real)'
            foreach ($id in @($script:PrepareActionId, $script:TaskActionId)) {
                Assert-Equal (Get-NormalizedCondition -Text $script:UninstallCondition) (Get-NormalizedCondition -Text $byAction[$id][1]) ($id + ' condition column in the compiled MSI')
            }
            $seqInstallInitialize = [int]$byAction['InstallInitialize'][2]
            $seqPrepare = [int]$byAction[$script:PrepareActionId][2]
            $seqTask = [int]$byAction[$script:TaskActionId][2]
            $seqRemoveFiles = [int]$byAction['RemoveFiles'][2]
            Assert-True ($seqInstallInitialize -lt $seqPrepare) 'cleanup runs after InstallInitialize (inside the deferred execute transaction)'
            Assert-True ($seqPrepare -lt $seqTask) 'the CLI stop/task removal runs before the schtasks fallback'
            Assert-True ($seqTask -lt $seqRemoveFiles) 'both cleanup actions run before RemoveFiles (gs-product.ps1 still on disk for the CLI step)'
        }

        Invoke-Test 'MSI database: deferred cleanup actions are absent from InstallUISequence' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Action` FROM `InstallUISequence`' -Columns 1)
            foreach ($row in $rows) {
                Assert-True (($row[0] -ne $script:PrepareActionId) -and ($row[0] -ne $script:TaskActionId)) ('deferred cleanup must not run in the UI sequence: ' + $row[0])
            }
        }

        Invoke-Test 'MSI database: upgrade detection is wired for the fixed UpgradeCode' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `UpgradeCode`, `ActionProperty` FROM `Upgrade`' -Columns 2)
            Assert-True ($rows.Count -ge 1) 'the Upgrade table has at least one row (MajorUpgrade detection)'
            Assert-Equal '{3B7F2C64-9A1D-4E58-8C2B-6D5A0F7E4B19}' ($rows[0][0].ToUpperInvariant()) 'the upgrade detection uses the fixed UpgradeCode from the wxs'
        }
    } finally {
        if ([System.IO.Directory]::Exists($workDir)) {
            Remove-Item -LiteralPath $workDir -Recurse -Force
        }
    }
}

Write-Host ("Summary: {0} passed, {1} failed, {2} skipped" -f $script:Passed, $script:Failed, $script:Skipped)
if ($script:Passed -eq 0 -or $script:Failed -gt 0) { exit 1 }
exit 0
