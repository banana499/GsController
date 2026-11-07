#Requires -Version 5.1
<#
.SYNOPSIS
    Start menu entry tests for the GsController installer: the advertised
    GsController shortcut that installer\GsConsoleShortcut.xsl attaches to
    the harvested gs-console.vbs component at build time.

.DESCRIPTION
    Three layers, offline and read-only:

    1. Structure (always runs): parse the real installer\GsController.wxs
       (the standard ProgramMenuFolder row is declared for the shortcut's
       Directory foreign key; NO component and NO new directory live in the
       profile start menu, so ICE38's HKCU registry keypath demand never
       applies and the product keeps creating no registry entries), parse
       installer\GsConsoleShortcut.xsl (identity transform plus exactly one
       Shortcut append on the component carrying gs-console.vbs), and check
       that scripts\build-product.ps1 wires the transform into heat via -t.

    2. Fixture MSI builds (skipped with an explicit SKIP line when the WiX3
       toolchain is absent; default C:\Tools\GsBuild\wix314, the same
       default as scripts\build-product.ps1): stage synthetic fixture files
       in a unique %TEMP% directory (a complete top-level product set, fake
       modules, licenses and the full synthetic 13-file public bundle; the
       real runtime-bundle is never read), then compile with
       heat -t <real XSL> / candle / light exactly like build-product.ps1,
       TWICE: once with -dGsInstallProfile=Legacy (which keeps both legacy
       uninstall cleanup actions) and once with -dGsInstallProfile=Sunshine
       over a stage that carries the Sunshine resources and the generated
       gs-install-profile.json but no runtime payload at all. A compile
       failure is a FAIL, never a silent skip. No msiexec runs anywhere in
       this suite.

    3. Built MSI database (same skip envelope as layer 2): open the
       resulting MSI through the WindowsInstaller COM API in READ-ONLY mode
       (msiOpenDatabaseModeReadOnly = 0) and assert the Shortcut table
       (id, directory, name, advertised feature target, empty arguments),
       the Directory table (ProgramMenuFolder under TARGETDIR, no new
       profile directory), the absence of a RemoveFile table (nothing new
       is created in the profile, so nothing needs a RemoveFile cleanup row),
       the File/Component keypath binding (the shortcut's component is the
       gs-console.vbs component whose keypath is that file, INSTALLFOLDER),
       and the presence of the console UI assets plus gs-tray-model.ps1 and
       gs-product.ps1 in the File table.

    Safety envelope: this suite never runs msiexec, never installs or
    uninstalls anything, never touches the real runtime-bundle, real
    certificates or system state, never calls another test suite, and
    writes only inside its own %TEMP% fixture directory (removed
    afterwards).

    Exits 0 only when at least one test ran and none failed. A missing
    WiX toolchain skips layers 2-3 explicitly but never skips layer 1.
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
$xslPath = Join-Path $repoRoot 'installer\GsConsoleShortcut.xsl'
$buildScriptPath = Join-Path $repoRoot 'scripts\build-product.ps1'
$shortcutId = 'GsControllerStartMenuShortcut'

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:MsiPath = ''
$script:SunshineMsiPath = ''

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

# ---------------------------------------------------------------------------
# Layer 1: structure of the real wxs, XSL and build wiring (always runs).
# ---------------------------------------------------------------------------
$script:WxsDoc = New-Object System.Xml.XmlDocument
$script:WxsDoc.Load($wxsPath)
$script:NsMgr = New-Object System.Xml.XmlNamespaceManager($script:WxsDoc.NameTable)
$script:NsMgr.AddNamespace('w', 'http://schemas.microsoft.com/wix/2006/wi')
$script:XslDoc = New-Object System.Xml.XmlDocument
$script:XslDoc.Load($xslPath)
$script:XslNsMgr = New-Object System.Xml.XmlNamespaceManager($script:XslDoc.NameTable)
$script:XslNsMgr.AddNamespace('x', 'http://www.w3.org/1999/XSL/Transform')
$script:XslNsMgr.AddNamespace('wix', 'http://schemas.microsoft.com/wix/2006/wi')

Invoke-Test 'structure: wxs declares the standard start menu for the shortcut foreign key, with no profile component' {
    $menuNodes = @($script:WxsDoc.SelectNodes('//w:Directory[@Id="ProgramMenuFolder"]', $script:NsMgr))
    Assert-True ($menuNodes.Count -eq 1) 'exactly one ProgramMenuFolder directory declaration'
    Assert-Equal 'TARGETDIR' $menuNodes[0].ParentNode.GetAttribute('Id') 'ProgramMenuFolder hangs under TARGETDIR'
    # No component may live in a profile directory: ICE38 would demand an
    # HKCU registry keypath and the product intentionally creates none.
    Assert-True (0 -eq @($script:WxsDoc.SelectNodes('//w:Directory[@Id="ProgramMenuFolder"]//w:Component', $script:NsMgr)).Count) 'no component inside the start menu tree'
    # No invented start-menu subdirectory: the entry goes directly into the
    # standard folder, so nothing new needs profile cleanup.
    Assert-True (0 -eq @($script:WxsDoc.SelectNodes('//w:Directory[@Id="ProgramMenuFolder"]//w:Directory', $script:NsMgr)).Count) 'no new subdirectory under ProgramMenuFolder'
}

Invoke-Test 'structure: XSL is an identity transform with exactly one shortcut append on the gs-console.vbs component' {
    $identity = @($script:XslDoc.SelectNodes('//x:template[@match="@* | node()"]', $script:XslNsMgr))
    Assert-True ($identity.Count -eq 1) 'the identity template exists exactly once'
    $appendTemplates = @($script:XslDoc.SelectNodes('//x:template[contains(@match, "wix:Component")]', $script:XslNsMgr))
    Assert-True ($appendTemplates.Count -eq 1) 'exactly one component-matching template (no arbitrary transforms)'
    $match = $appendTemplates[0].GetAttribute('match')
    Assert-True ($match.Contains("'gs-console.vbs'")) 'the template matches only the component whose Source ends with gs-console.vbs'
    # The Shortcut is appended inside the xsl:copy wrapper (the cloned
    # component), not as a direct child of the template.
    $shortcuts = @($appendTemplates[0].SelectNodes('x:copy/wix:Shortcut', $script:XslNsMgr))
    Assert-True ($shortcuts.Count -eq 1) 'exactly one Shortcut element is appended'
    Assert-Equal $shortcutId $shortcuts[0].GetAttribute('Id') 'shortcut id'
    Assert-Equal 'ProgramMenuFolder' $shortcuts[0].GetAttribute('Directory') 'the shortcut lives in the standard start menu'
    Assert-Equal 'GsController' $shortcuts[0].GetAttribute('Name') 'the entry is named GsController'
    Assert-Equal 'yes' $shortcuts[0].GetAttribute('Advertise') 'the shortcut is advertised (keypath launch, no ICE43 HKCU demand)'
    Assert-True (0 -eq @($appendTemplates[0].SelectNodes('.//wix:RemoveFolder | .//wix:RemoveFile | .//wix:RegistryValue | .//wix:ServiceInstall | .//wix:ServiceControl', $script:XslNsMgr)).Count) 'no RemoveFolder/RemoveFile/registry/service writes are injected'
}

Invoke-Test 'structure: build-product.ps1 wires the XSL into heat via -t' {
    $text = [IO.File]::ReadAllText($buildScriptPath)
    Assert-True ($text.Contains('$harvestXsl = Join-Path $root ''installer\GsConsoleShortcut.xsl''')) 'the XSL is the declared installer\GsConsoleShortcut.xsl'
    Assert-True ($text.Contains('-t $harvestXsl')) 'heat receives -t $harvestXsl'
}

# ---------------------------------------------------------------------------
# Layer 2+3: fixture build with the real WiX toolchain + read-only database
# checks. Skipped only when the toolchain is absent; never skipped silently.
# ---------------------------------------------------------------------------
$wixRoot = $WixDir
if ([string]::IsNullOrWhiteSpace($wixRoot)) { $wixRoot = 'C:\Tools\GsBuild\wix314' }
$heat = Join-Path $wixRoot 'heat.exe'
$candle = Join-Path $wixRoot 'candle.exe'
$light = Join-Path $wixRoot 'light.exe'
$toolsFound = @(@($heat, $candle, $light) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

if ($toolsFound.Count -ne 3) {
    Invoke-Skip -Name 'MSI build + read-only database layers' `
        -Reason ("WiX toolchain incomplete under '{0}' (found {1} of 3 tools); pass -WixDir to point at one. The structure layer still ran." -f $wixRoot, $toolsFound.Count)
} else {
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ('GsConsoleShortcutMsi_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $workDir = (Resolve-Path -LiteralPath $workDir).ProviderPath
    try {
        # Synthetic fixture stage: a complete top-level product set (the
        # seven console files, the tray entry points, the CLI tools and the
        # gs-product entry), fake modules, license texts and the full
        # synthetic 13-file public runtime bundle. Nothing from the real
        # runtime-bundle is read and nothing here is ever executed.
        $stage = Join-Path $workDir 'stage'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        $ascii = New-Object System.Text.ASCIIEncoding
        $productFiles = @(
            'gs-console.ps1', 'gs-console-action.ps1', 'gs-console.vbs',
            'gs-console.html', 'gs-console.css', 'gs-console.js',
            'gs-console-strings.zh-CN.json',
            'gs-tray.ps1', 'gs-tray.vbs', 'gs-tray-strings.zh-CN.json', 'gs-tray-model.ps1',
            'gs-diagnose.ps1', 'gs-support.ps1', 'gs-product.ps1',
            'LICENSE', 'LICENSING.md'
        )
        foreach ($name in $productFiles) {
            [System.IO.File]::WriteAllText((Join-Path $stage $name), ("fixture " + $name + " - never executed by tests.`r`n"), $ascii)
        }
        foreach ($moduleName in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
            $moduleDir = Join-Path $stage ('Modules\' + $moduleName)
            New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $moduleDir ($moduleName + '.psd1')), "fixture module manifest`r`n", $ascii)
            [System.IO.File]::WriteAllText((Join-Path $moduleDir ($moduleName + '.psm1')), "fixture module body`r`n", $ascii)
        }
        New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
        foreach ($name in @(
                'gs_start_private.ps1', 'gs_stop_private.ps1', 'gs_start_with_hook.ps1',
                'gs_supervisor.ps1', 'gs_grant_pipe_acl.ps1', 'gs_process_identity.ps1',
                'gs_launcher.py', 'inject_nvstreamer.py', 'patch_applist_mem.py',
                'gs_nsc_supported.py', 'gs_mdns_probe.py',
                'NvStreamerBusHook.dll', 'GsStreamGuard.dll')) {
            [System.IO.File]::WriteAllText((Join-Path $stage ('bin\' + $name)), 'fixture runtime payload placeholder' + "`r`n", $ascii)
        }

        Invoke-Test 'MSI build: heat -t <XSL> / candle / light compile the real wxs into a Legacy fixture MSI' {
            $buildDir = Join-Path $workDir 'build'
            New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
            $harvest = Join-Path $buildDir 'ProductFiles.wxs'
            $stageDir = (Resolve-Path -LiteralPath $stage).ProviderPath
            & $heat dir $stageDir -nologo -cg ProductFiles -gg -g1 -srd -sreg -dr INSTALLFOLDER -var var.StageDir -t $xslPath -out $harvest
            if ($LASTEXITCODE -ne 0) { throw ('heat.exe failed with exit code ' + $LASTEXITCODE) }
            & $candle -nologo -arch x64 '-dVersion=0.0.1' ('-dStageDir=' + $stageDir) '-dGsInstallProfile=Legacy' -out ($buildDir + '\') $wxsPath $harvest
            if ($LASTEXITCODE -ne 0) { throw ('candle.exe failed with exit code ' + $LASTEXITCODE) }
            $msi = Join-Path $workDir 'GsController-Legacy-0.0.1.msi'
            & $light -nologo -out $msi (Join-Path $buildDir 'GsController.wixobj') (Join-Path $buildDir 'ProductFiles.wixobj')
            if ($LASTEXITCODE -ne 0) { throw ('light.exe failed with exit code ' + $LASTEXITCODE) }
            Assert-True ([System.IO.File]::Exists($msi)) 'the fixture MSI was produced (no msiexec involved anywhere)'
            $script:MsiPath = $msi
        }

        # Sunshine fixture stage: the same complete product set plus the
        # four Sunshine resources, but NO runtime payload at all - the
        # Sunshine profile has no runtime input.
        $sunshineStage = Join-Path $workDir 'stage-sunshine'
        New-Item -ItemType Directory -Path $sunshineStage -Force | Out-Null
        foreach ($name in @($productFiles + @('gs-sunshine.ps1', 'gs-sunshine.html', 'gs-sunshine.js', 'gs-sunshine.css'))) {
            [System.IO.File]::WriteAllText((Join-Path $sunshineStage $name), ("fixture " + $name + " - never executed by tests.`r`n"), $ascii)
        }
        foreach ($moduleName in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
            $moduleDir = Join-Path $sunshineStage ('Modules\' + $moduleName)
            New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $moduleDir ($moduleName + '.psd1')), "fixture module manifest`r`n", $ascii)
            [System.IO.File]::WriteAllText((Join-Path $moduleDir ($moduleName + '.psm1')), "fixture module body`r`n", $ascii)
        }
        [System.IO.File]::WriteAllText((Join-Path $sunshineStage 'gs-install-profile.json'), ('{' + "`r`n" + '  "schemaVersion": 1,' + "`r`n" + '  "backend": "sunshine"' + "`r`n" + '}'), $ascii)

        Invoke-Test 'MSI build: the Sunshine profile compiles with the real WiX toolchain and no runtime payload' {
            $buildDir = Join-Path $workDir 'build-sunshine'
            New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
            $harvest = Join-Path $buildDir 'ProductFiles.wxs'
            $stageDir = (Resolve-Path -LiteralPath $sunshineStage).ProviderPath
            & $heat dir $stageDir -nologo -cg ProductFiles -gg -g1 -srd -sreg -dr INSTALLFOLDER -var var.StageDir -t $xslPath -out $harvest
            if ($LASTEXITCODE -ne 0) { throw ('heat.exe failed with exit code ' + $LASTEXITCODE) }
            & $candle -nologo -arch x64 '-dVersion=0.0.1' ('-dStageDir=' + $stageDir) '-dGsInstallProfile=Sunshine' -out ($buildDir + '\') $wxsPath $harvest
            if ($LASTEXITCODE -ne 0) { throw ('candle.exe failed with exit code ' + $LASTEXITCODE) }
            $msi = Join-Path $workDir 'GsController-Sunshine-0.0.1.msi'
            & $light -nologo -out $msi (Join-Path $buildDir 'GsController.wixobj') (Join-Path $buildDir 'ProductFiles.wixobj')
            if ($LASTEXITCODE -ne 0) { throw ('light.exe failed with exit code ' + $LASTEXITCODE) }
            Assert-True ([System.IO.File]::Exists($msi)) 'the Sunshine fixture MSI was produced (no msiexec involved anywhere)'
            $script:SunshineMsiPath = $msi
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

        Invoke-Test 'MSI database: the Legacy profile keeps both cleanup actions and their uninstall-only sequencing' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Action` FROM `CustomAction`' -Columns 1)
            $names = @($rows | ForEach-Object { $_[0] })
            Assert-True (1 -eq @($names | Where-Object { $_ -eq 'GsPrepareUninstall' }).Count) 'Legacy keeps GsPrepareUninstall'
            Assert-True (1 -eq @($names | Where-Object { $_ -eq 'GsRemoveSupervisorTask' }).Count) 'Legacy keeps GsRemoveSupervisorTask'
            $seq = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Action` FROM `InstallExecuteSequence`' -Columns 1)
            $seqNames = @($seq | ForEach-Object { $_[0] })
            Assert-True (1 -eq @($seqNames | Where-Object { $_ -eq 'GsPrepareUninstall' }).Count) 'Legacy keeps the GsPrepareUninstall sequence entry'
            Assert-True (1 -eq @($seqNames | Where-Object { $_ -eq 'GsRemoveSupervisorTask' }).Count) 'Legacy keeps the GsRemoveSupervisorTask sequence entry'
        }

        Invoke-Test 'MSI database: the advertised GsController shortcut is attached to the gs-console.vbs component' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Shortcut`, `Directory_`, `Name`, `Component_`, `Target`, `Arguments` FROM `Shortcut`' -Columns 6)
            Assert-True (1 -eq @($rows | Where-Object { $_[0] -eq $shortcutId }).Count) 'exactly one GsControllerStartMenuShortcut row'
            $row = @($rows | Where-Object { $_[0] -eq $shortcutId })[0]
            Assert-Equal 'ProgramMenuFolder' $row[1] 'the shortcut resolves in the standard start menu'
            Assert-True ($row[2].EndsWith('|GsController') -or $row[2] -eq 'GsController') ('the entry name is GsController (MSI short|long form: ' + $row[2] + ')')
            Assert-Equal 'Main' $row[4] 'an advertised shortcut targets the Main feature (launch resolves through the component keypath)'
            Assert-Equal '' $row[5] 'no shortcut arguments (nothing extra or automatic is started)'

            # The shortcut's component must be the component that carries
            # gs-console.vbs as its keypath file in INSTALLFOLDER.
            $fileRows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `File`, `Component_`, `FileName` FROM `File`' -Columns 3)
            $vbsRow = $null
            foreach ($f in $fileRows) {
                $longName = $f[2]
                if ($longName.Contains('|')) { $longName = $longName.Substring($longName.IndexOf('|') + 1) }
                if ($longName -eq 'gs-console.vbs') { $vbsRow = $f; break }
            }
            Assert-True ($null -ne $vbsRow) 'gs-console.vbs has a File table row'
            Assert-Equal $vbsRow[1] $row[3] 'the shortcut belongs to the gs-console.vbs component'
            $componentRows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Component`, `Directory_`, `KeyPath` FROM `Component`' -Columns 3)
            $compRow = $null
            foreach ($c in $componentRows) {
                if ($c[0] -eq $vbsRow[1]) { $compRow = $c; break }
            }
            Assert-True ($null -ne $compRow) 'the shortcut component exists in the Component table'
            Assert-Equal 'INSTALLFOLDER' $compRow[1] 'the gs-console.vbs component installs to INSTALLFOLDER'
            Assert-Equal $vbsRow[0] $compRow[2] 'gs-console.vbs is the component keypath (what the advertised shortcut launches)'
        }

        Invoke-Test 'MSI database: the start menu stays the standard directory with nothing new to clean' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Directory`, `Directory_Parent` FROM `Directory`' -Columns 2)
            $menuRow = $null
            foreach ($d in $rows) {
                if ($d[0] -eq 'ProgramMenuFolder') { $menuRow = $d; break }
            }
            Assert-True ($null -ne $menuRow) 'ProgramMenuFolder exists in the Directory table'
            Assert-Equal 'TARGETDIR' $menuRow[1] 'ProgramMenuFolder hangs under TARGETDIR'
            Assert-True (0 -eq @($rows | Where-Object { $_[1] -eq 'ProgramMenuFolder' -and $_[0] -ne 'ProgramMenuFolder' }).Count) 'no invented subdirectory under the start menu'
            # Nothing new is created in the profile, so no RemoveFile table
            # row (and no RemoveFolder cleanup) is needed; the .lnk itself is
            # removed with its component on uninstall.
            $tableRows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `Name` FROM `_Tables`' -Columns 1)
            Assert-True (0 -eq @($tableRows | Where-Object { $_[0] -eq 'RemoveFile' }).Count) 'no RemoveFile table (no profile directory was created)'
            Assert-True (0 -eq @($tableRows | Where-Object { $_[0] -eq 'Registry' }).Count) 'no Registry table (the product creates no registry entries)'
        }

        Invoke-Test 'MSI database: the console UI assets and their dependencies are in the File table' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:MsiPath -Sql 'SELECT `File`, `Component_`, `FileName` FROM `File`' -Columns 3)
            $present = @{}
            foreach ($f in $rows) {
                $longName = $f[2]
                if ($longName.Contains('|')) { $longName = $longName.Substring($longName.IndexOf('|') + 1) }
                $present[$longName] = $true
            }
            foreach ($name in @(
                    'gs-console.ps1', 'gs-console-action.ps1', 'gs-console.vbs',
                    'gs-console.html', 'gs-console.css', 'gs-console.js',
                    'gs-console-strings.zh-CN.json',
                    'gs-tray-model.ps1', 'gs-tray.ps1', 'gs-product.ps1')) {
                Assert-True $present.ContainsKey($name) ('File table contains ' + $name)
            }
            # The runtime bundle payloads land in bin\ via harvested
            # subcomponents; spot-check two public contract names.
            Assert-True $present.ContainsKey('gs_supervisor.ps1') 'File table contains the gs_supervisor.ps1 bundle payload'
            Assert-True $present.ContainsKey('GsStreamGuard.dll') 'File table contains the GsStreamGuard.dll bundle payload'
        }

        # ------------------------------------------------------------------
        # Sunshine profile: no legacy cleanup actions, correct shortcut,
        # sunshine assets and install profile, no runtime payload.
        # ------------------------------------------------------------------

        # A Sunshine MSI legitimately has NO CustomAction table at all (no
        # custom action is compiled), so queries against possibly-absent
        # tables go through this existence-guarded wrapper.
        function Get-MsiRowsIfTableExists {
            param(
                [Parameter(Mandatory = $true)][string]$MsiPath,
                [Parameter(Mandatory = $true)][string]$Sql,
                [Parameter(Mandatory = $true)][int]$Columns,
                [Parameter(Mandatory = $true)][string]$TableName
            )
            $tables = @(Get-MsiDatabaseRows -MsiPath $MsiPath -Sql 'SELECT `Name` FROM `_Tables`' -Columns 1)
            if (0 -eq @($tables | Where-Object { $_[0] -eq $TableName }).Count) { return @() }
            return (Get-MsiDatabaseRows -MsiPath $MsiPath -Sql $Sql -Columns $Columns)
        }

        Invoke-Test 'MSI database (Sunshine): no legacy cleanup action or sequence entry exists at all' {
            $rows = @(Get-MsiRowsIfTableExists -MsiPath $script:SunshineMsiPath -TableName 'CustomAction' -Sql 'SELECT `Action` FROM `CustomAction`' -Columns 1)
            $names = @($rows | ForEach-Object { $_[0] })
            Assert-True (0 -eq @($names | Where-Object { $_ -eq 'GsPrepareUninstall' }).Count) 'a Sunshine MSI has no GsPrepareUninstall custom action'
            Assert-True (0 -eq @($names | Where-Object { $_ -eq 'GsRemoveSupervisorTask' }).Count) 'a Sunshine MSI has no GsRemoveSupervisorTask fallback'
            $seq = @(Get-MsiRowsIfTableExists -MsiPath $script:SunshineMsiPath -TableName 'InstallExecuteSequence' -Sql 'SELECT `Action` FROM `InstallExecuteSequence`' -Columns 1)
            $seqNames = @($seq | ForEach-Object { $_[0] })
            Assert-True (0 -eq @($seqNames | Where-Object { $_ -eq 'GsPrepareUninstall' }).Count) 'no GsPrepareUninstall sequence entry in Sunshine'
            Assert-True (0 -eq @($seqNames | Where-Object { $_ -eq 'GsRemoveSupervisorTask' }).Count) 'no GsRemoveSupervisorTask sequence entry in Sunshine'
        }

        Invoke-Test 'MSI database (Sunshine): the advertised shortcut still targets the installed gs-console.vbs' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:SunshineMsiPath -Sql 'SELECT `Shortcut`, `Directory_`, `Name`, `Component_`, `Target`, `Arguments` FROM `Shortcut`' -Columns 6)
            Assert-True (1 -eq @($rows | Where-Object { $_[0] -eq $shortcutId }).Count) 'exactly one GsControllerStartMenuShortcut row in the Sunshine MSI'
            $row = @($rows | Where-Object { $_[0] -eq $shortcutId })[0]
            Assert-Equal 'ProgramMenuFolder' $row[1] 'the Sunshine shortcut resolves in the standard start menu'
            Assert-True ($row[2].EndsWith('|GsController') -or $row[2] -eq 'GsController') 'the Sunshine entry name is GsController'
            Assert-Equal 'Main' $row[4] 'the Sunshine shortcut is advertised to the Main feature'
            Assert-Equal '' $row[5] 'no shortcut arguments (nothing extra or automatic is started)'
            $fileRows = @(Get-MsiDatabaseRows -MsiPath $script:SunshineMsiPath -Sql 'SELECT `File`, `Component_`, `FileName` FROM `File`' -Columns 3)
            $vbsRow = $null
            foreach ($f in $fileRows) {
                $longName = $f[2]
                if ($longName.Contains('|')) { $longName = $longName.Substring($longName.IndexOf('|') + 1) }
                if ($longName -eq 'gs-console.vbs') { $vbsRow = $f; break }
            }
            Assert-True ($null -ne $vbsRow) 'gs-console.vbs has a File table row in the Sunshine MSI'
            Assert-Equal $vbsRow[1] $row[3] 'the Sunshine shortcut belongs to the gs-console.vbs component'
            $componentRows = @(Get-MsiDatabaseRows -MsiPath $script:SunshineMsiPath -Sql 'SELECT `Component`, `Directory_`, `KeyPath` FROM `Component`' -Columns 3)
            $compRow = $null
            foreach ($c in $componentRows) {
                if ($c[0] -eq $vbsRow[1]) { $compRow = $c; break }
            }
            Assert-True ($null -ne $compRow -and $compRow[2] -eq $vbsRow[0]) 'gs-console.vbs is the shortcut component keypath in the Sunshine MSI'
        }

        Invoke-Test 'MSI database (Sunshine): sunshine assets and the install profile ship, no runtime payload' {
            $rows = @(Get-MsiDatabaseRows -MsiPath $script:SunshineMsiPath -Sql 'SELECT `File`, `Component_`, `FileName` FROM `File`' -Columns 3)
            $present = @{}
            foreach ($f in $rows) {
                $longName = $f[2]
                if ($longName.Contains('|')) { $longName = $longName.Substring($longName.IndexOf('|') + 1) }
                $present[$longName] = $true
            }
            foreach ($name in @(
                    'gs-sunshine.ps1', 'gs-sunshine.html', 'gs-sunshine.js', 'gs-sunshine.css',
                    'gs-install-profile.json',
                    'gs-console.ps1', 'gs-console.html', 'gs-console.css', 'gs-tray-model.ps1')) {
                Assert-True $present.ContainsKey($name) ('Sunshine File table contains ' + $name)
            }
            Assert-True (-not $present.ContainsKey('gs_supervisor.ps1')) 'no runtime bundle payload in a Sunshine MSI'
            Assert-True (-not $present.ContainsKey('GsStreamGuard.dll')) 'no bundle DLL in a Sunshine MSI'
        }

        # ------------------------------------------------------------------
        # Profile-casing regression, end to end: PowerShell ValidateSet
        # accepts 'legacy'/'lEgAcY' and binds the value as typed, while the
        # wxs preprocessor comparison is case-sensitive. The real build
        # script must normalize the profile before candle, or a lowercase
        # 'legacy' would stage the runtime bundle yet compile WITHOUT the
        # legacy uninstall cleanup. Runs the real scripts\build-product.ps1
        # in a child process against a synthetic repository with the real
        # WiX toolchain, then opens the produced MSI read-only.
        # ------------------------------------------------------------------

        # Synthetic repository for child-process builds (same conventions as
        # tests\Invoke-ConsolePackagingTests.ps1): complete product set,
        # modules, licenses, the full synthetic 13-file bundle, and copies of
        # the real wxs/XSL and build scripts. Nothing is ever executed.
        function New-SyntheticBuildRepo {
            param([Parameter(Mandatory)][string]$Name)
            $repo = Join-Path $workDir $Name
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            foreach ($d in @('product', 'src\GsControl', 'src\GsLifecycle', 'src\GsRuntime',
                    'installer', 'runtime-bundle', 'artifacts', 'scripts')) {
                New-Item -ItemType Directory -Path (Join-Path $repo $d) -Force | Out-Null
            }
            foreach ($name in @(
                    'gs-console.ps1', 'gs-console-action.ps1', 'gs-console.vbs',
                    'gs-console.html', 'gs-console.css', 'gs-console.js',
                    'gs-console-strings.zh-CN.json',
                    'gs-tray.ps1', 'gs-tray.vbs', 'gs-tray-strings.zh-CN.json', 'gs-tray-model.ps1',
                    'gs-diagnose.ps1', 'gs-support.ps1', 'gs-product.ps1',
                    'gs-sunshine.ps1', 'gs-sunshine.html', 'gs-sunshine.js', 'gs-sunshine.css')) {
                [System.IO.File]::WriteAllText((Join-Path $repo ("product\" + $name)), ("synthetic " + $name + "`r`n"), $ascii)
            }
            [System.IO.File]::WriteAllText((Join-Path $repo 'LICENSE'), "synthetic product license text`r`n", $ascii)
            [System.IO.File]::WriteAllText((Join-Path $repo 'LICENSING.md'), "synthetic licensing notice`r`n", $ascii)
            foreach ($moduleName in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
                $moduleDir = Join-Path $repo ('src\' + $moduleName)
                [System.IO.File]::WriteAllText((Join-Path $moduleDir ($moduleName + '.psd1')), "synthetic $moduleName manifest`r`n", $ascii)
                [System.IO.File]::WriteAllText((Join-Path $moduleDir ($moduleName + '.psm1')), "synthetic $moduleName body`r`n", $ascii)
            }
            [System.IO.File]::WriteAllText((Join-Path $repo 'runtime-bundle\README.md'), "documentation only`r`n", $ascii)
            foreach ($name in @(
                    'gs_start_private.ps1', 'gs_stop_private.ps1', 'gs_start_with_hook.ps1',
                    'gs_supervisor.ps1', 'gs_grant_pipe_acl.ps1', 'gs_process_identity.ps1',
                    'gs_launcher.py', 'inject_nvstreamer.py', 'patch_applist_mem.py',
                    'gs_nsc_supported.py', 'gs_mdns_probe.py',
                    'NvStreamerBusHook.dll', 'GsStreamGuard.dll')) {
                [System.IO.File]::WriteAllText((Join-Path $repo ('runtime-bundle\' + $name)), 'synthetic bundle payload' + "`r`n", $ascii)
            }
            Copy-Item -LiteralPath $wxsPath -Destination (Join-Path $repo 'installer\GsController.wxs')
            Copy-Item -LiteralPath $xslPath -Destination (Join-Path $repo 'installer\GsConsoleShortcut.xsl')
            Copy-Item -LiteralPath $buildScriptPath -Destination (Join-Path $repo 'scripts\build-product.ps1')
            Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\GsBuildPreflight.ps1') -Destination (Join-Path $repo 'scripts\GsBuildPreflight.ps1')
            Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Test-GsPrerequisites.ps1') -Destination (Join-Path $repo 'scripts\Test-GsPrerequisites.ps1')
            return $repo
        }

        # Runs the copied build script in a child powershell process.
        function Invoke-ProductBuild {
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [string[]]$Arguments = @()
            )
            $outFile = Join-Path $workDir ('stdout-' + [guid]::NewGuid().ToString('N') + '.txt')
            $errFile = Join-Path $workDir ('stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
            $argString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
                (Join-Path $RepoRoot 'scripts\build-product.ps1') + '"'
            foreach ($a in $Arguments) {
                $v = $a
                if ($v.EndsWith('\')) { $v += '\' }
                $argString += ' "' + ($v -replace '"', '\"') + '"'
            }
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString `
                -WorkingDirectory $RepoRoot `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                -WindowStyle Hidden -Wait -PassThru
            $stdout = ''
            if (Test-Path -LiteralPath $outFile) { $stdout = [System.IO.File]::ReadAllText($outFile) }
            $stderr = ''
            if (Test-Path -LiteralPath $errFile) { $stderr = [System.IO.File]::ReadAllText($errFile) }
            return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
        }

        Invoke-Test 'profile casing: -RuntimeProfile lEgAcY normalizes to Legacy and compiles the cleanup actions' {
            $repo = New-SyntheticBuildRepo 'repo-case-legacy'
            $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0', '-RuntimeProfile', 'lEgAcY',
                '-WixDir', $wixRoot, '-RuntimeBundleDir', (Join-Path $repo 'runtime-bundle'))
            Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stderr: {1}" -f $r.ExitCode, $r.StdErr)
            Assert-True ($r.StdOut.Contains('GsController-0.2.0.msi')) 'the canonical Legacy artifact name is used'
            $rows = @(Get-MsiDatabaseRows -MsiPath (Join-Path $repo 'artifacts\msi\GsController-0.2.0.msi') -Sql 'SELECT `Action` FROM `CustomAction`' -Columns 1)
            $names = @($rows | ForEach-Object { $_[0] })
            Assert-True (1 -eq @($names | Where-Object { $_ -eq 'GsPrepareUninstall' }).Count) 'mixed-case Legacy keeps GsPrepareUninstall'
            Assert-True (1 -eq @($names | Where-Object { $_ -eq 'GsRemoveSupervisorTask' }).Count) 'mixed-case Legacy keeps GsRemoveSupervisorTask'
        }

        Invoke-Test 'profile casing: -RuntimeProfile sunshine normalizes to Sunshine and compiles without the cleanup actions' {
            $repo = New-SyntheticBuildRepo 'repo-case-sunshine'
            $r = Invoke-ProductBuild -RepoRoot $repo -Arguments @('-Version', '0.2.0', '-RuntimeProfile', 'sunshine',
                '-WixDir', $wixRoot)
            Assert-True ($r.ExitCode -eq 0) ("exit 0, got {0}; stderr: {1}" -f $r.ExitCode, $r.StdErr)
            Assert-True ($r.StdOut.Contains('GsController-Sunshine-0.2.0.msi')) 'the canonical Sunshine artifact name is used'
            $rows = @(Get-MsiRowsIfTableExists -MsiPath (Join-Path $repo 'artifacts\msi\GsController-Sunshine-0.2.0.msi') -TableName 'CustomAction' -Sql 'SELECT `Action` FROM `CustomAction`' -Columns 1)
            $names = @($rows | ForEach-Object { $_[0] })
            Assert-True (0 -eq @($names | Where-Object { $_ -eq 'GsPrepareUninstall' }).Count) 'lowercase sunshine compiles no GsPrepareUninstall'
            Assert-True (0 -eq @($names | Where-Object { $_ -eq 'GsRemoveSupervisorTask' }).Count) 'lowercase sunshine compiles no GsRemoveSupervisorTask'
            $shortcuts = @(Get-MsiDatabaseRows -MsiPath (Join-Path $repo 'artifacts\msi\GsController-Sunshine-0.2.0.msi') -Sql 'SELECT `Shortcut` FROM `Shortcut`' -Columns 1)
            Assert-True (1 -eq @($shortcuts | Where-Object { $_[0] -eq $shortcutId }).Count) 'the advertised start menu shortcut is still present'
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
