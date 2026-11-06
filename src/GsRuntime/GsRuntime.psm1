Set-StrictMode -Version Latest

$controlManifest = Join-Path $PSScriptRoot '..\GsControl\GsControl.psd1'
Import-Module $controlManifest -Force

$script:HexSha256 = '^[0-9a-fA-F]{64}$'

function New-GsRuntimeError {
    param([string]$Code, [string]$Field, [string]$Message)
    [pscustomobject]@{ Code = $Code; Field = $Field; Message = $Message }
}

function New-GsRuntimeResult {
    param([bool]$Success, $Layout, $Plan, [object[]]$Errors)
    [pscustomobject]@{
        Success = $Success
        Layout  = $Layout
        Plan    = $Plan
        Errors  = @($Errors)
    }
}

function ConvertTo-GsRuntimePath {
    param([string]$Value, [string]$Field)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject]@{ Path = $null; Errors = @(New-GsRuntimeError 'EmptyPath' $Field "$Field must not be empty.") }
    }
    if (-not [IO.Path]::IsPathRooted($Value)) {
        return [pscustomobject]@{ Path = $null; Errors = @(New-GsRuntimeError 'NotAbsolute' $Field "$Field must be absolute.") }
    }
    try {
        $resolved = Resolve-GsPath -Path $Value
    } catch {
        return [pscustomobject]@{ Path = $null; Errors = @(New-GsRuntimeError 'InvalidPath' $Field $_.Exception.Message) }
    }
    if (-not [IO.Path]::IsPathRooted($resolved)) {
        return [pscustomobject]@{ Path = $null; Errors = @(New-GsRuntimeError 'NotAbsolute' $Field "$Field must be absolute.") }
    }
    [pscustomobject]@{ Path = $resolved; Errors = @() }
}

function Get-GsComparablePath {
    param([string]$Path)
    return $Path.TrimEnd('\', '/').ToLowerInvariant()
}

function Test-GsPathInside {
    param([string]$Candidate, [string]$Parent)
    $c = Get-GsComparablePath $Candidate
    $p = Get-GsComparablePath $Parent
    if ($c -eq $p) { return $true }
    return $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
}

function New-GsRuntimeLayout {
    <#
    .SYNOPSIS
        Validates and derives a portable runtime layout. Does not create directories.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$InstallDir,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$StateDir,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$LogDir,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$ComponentSourceDir
    )

    $errors = New-Object System.Collections.Generic.List[object]
    $fields = [ordered]@{
        InstallDir         = ConvertTo-GsRuntimePath $InstallDir 'installDir'
        StateDir           = ConvertTo-GsRuntimePath $StateDir 'stateDir'
        LogDir             = ConvertTo-GsRuntimePath $LogDir 'logDir'
        ComponentSourceDir = ConvertTo-GsRuntimePath $ComponentSourceDir 'componentSourceDir'
    }
    foreach ($key in $fields.Keys) {
        foreach ($e in $fields[$key].Errors) { $errors.Add($e) }
    }
    if ($errors.Count -gt 0) {
        return (New-GsRuntimeResult $false $null $null $errors.ToArray())
    }

    $dirs = @(
        @('installDir', $fields.InstallDir.Path),
        @('stateDir', $fields.StateDir.Path),
        @('logDir', $fields.LogDir.Path),
        @('componentSourceDir', $fields.ComponentSourceDir.Path)
    )
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        for ($j = $i + 1; $j -lt $dirs.Count; $j++) {
            $a = $dirs[$i]
            $b = $dirs[$j]
            if ((Get-GsComparablePath $a[1]) -eq (Get-GsComparablePath $b[1])) {
                $errors.Add((New-GsRuntimeError 'SameDirectory' ($a[0] + ',' + $b[0]) ("{0} and {1} are the same directory." -f $a[0], $b[0])))
            } elseif ((Test-GsPathInside $a[1] $b[1]) -or (Test-GsPathInside $b[1] $a[1])) {
                $errors.Add((New-GsRuntimeError 'NestedDirectory' ($a[0] + ',' + $b[0]) ("{0} and {1} must not be nested." -f $a[0], $b[0])))
            }
        }
    }
    if ($errors.Count -gt 0) {
        return (New-GsRuntimeResult $false $null $null $errors.ToArray())
    }

    $install = $fields.InstallDir.Path
    $state = $fields.StateDir.Path
    $logs = $fields.LogDir.Path
    # The supervisor pause flag has TWO locations with distinct roles:
    # - PauseFlagPath is the CANONICAL location
    #   (<StateDir>\runtime\state\supervisor_pause.flag), the one the
    #   black-box supervisor reads according to the public operator docs
    #   (docs/remote-client-test.md). Stop/PrepareUninstall write here.
    # - LegacyPauseFlagPath (<StateDir>\supervisor_pause.flag) is where
    #   older product builds wrote the flag. It is preserved with its exact
    #   bytes whenever found (never overwritten, never deleted by Stop);
    #   an explicit successful Start clears both locations. The runtime\state
    #   directory does not exist until the runtime is deployed or the first
    #   canonical pause is written.
    $runtimeStateDir = Join-Path $state 'runtime\state'
    $layout = [pscustomobject]@{
        InstallDir          = $install
        StateDir            = $state
        LogDir              = $logs
        ComponentSourceDir  = $fields.ComponentSourceDir.Path
        BrokerDir           = Join-Path $install 'Broker'
        PluginsDir          = Join-Path $install 'Broker\plugins'
        BrokerLogDir        = Join-Path $install 'Broker\logs'
        BinDir              = Join-Path $install 'bin'
        RuntimeDir          = Join-Path $state 'runtime'
        RuntimeBinDir       = Join-Path $state 'runtime\bin'
        GeneratedConfigPath = Join-Path $state 'runtime-config.json'
        StatusPath          = Join-Path $state 'status.json'
        PauseFlagPath       = Join-Path $runtimeStateDir 'supervisor_pause.flag'
        LegacyPauseFlagPath = Join-Path $state 'supervisor_pause.flag'
        StateLockPath       = Join-Path $state 'lifecycle.lock'
    }
    return (New-GsRuntimeResult $true $layout $null @())
}

function Write-GsRuntimeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $errors = @()
    if ($null -eq $Layout -or $null -eq $Layout.PSObject.Properties['InstallDir']) {
        $errors += New-GsRuntimeError 'InvalidLayout' 'layout' 'Layout is missing required directories.'
    }
    try { $target = Resolve-GsPath -Path $Path } catch {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'InvalidPath' 'path' $_.Exception.Message))
    }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $errors += New-GsRuntimeError 'DirectoryMissing' 'path' "Parent directory does not exist: $parent"
    }
    if ($errors.Count -gt 0) { return (New-GsRuntimeResult $false $null $null $errors) }

    $doc = [ordered]@{
        schemaVersion      = 1
        installDir         = $Layout.InstallDir
        stateDir           = $Layout.StateDir
        logDir             = $Layout.LogDir
        componentSourceDir = $Layout.ComponentSourceDir
    }
    try {
        $tmp = $target + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $target -Force
    } catch {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'PersistFailed' 'path' $_.Exception.Message))
    }
    return (New-GsRuntimeResult $true $Layout $null @())
}

function Read-GsRuntimeConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    try { $target = Resolve-GsPath -Path $Path } catch {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'InvalidPath' 'path' $_.Exception.Message))
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'FileNotFound' 'path' "Config not found: $target"))
    }
    try { $doc = [IO.File]::ReadAllText($target) | ConvertFrom-Json } catch {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'InvalidJson' 'path' 'Config is not valid JSON.'))
    }
    $errors = New-Object System.Collections.Generic.List[object]
    if ($null -eq $doc -or $doc -isnot [pscustomobject]) {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'InvalidType' '' 'Config root must be an object.'))
    }
    if (-not $doc.PSObject.Properties['schemaVersion']) {
        $errors.Add((New-GsRuntimeError 'MissingField' 'schemaVersion' 'schemaVersion is required.'))
    } elseif ($doc.schemaVersion -ne 1) {
        $errors.Add((New-GsRuntimeError 'UnsupportedValue' 'schemaVersion' 'Only schemaVersion 1 is supported.'))
    }
    foreach ($name in @('installDir', 'stateDir', 'logDir', 'componentSourceDir')) {
        if (-not $doc.PSObject.Properties[$name]) {
            $errors.Add((New-GsRuntimeError 'MissingField' $name "$name is required."))
        }
    }
    if ($errors.Count -gt 0) { return (New-GsRuntimeResult $false $null $null $errors.ToArray()) }
    return (New-GsRuntimeLayout -InstallDir ([string]$doc.installDir) -StateDir ([string]$doc.stateDir) `
        -LogDir ([string]$doc.logDir) -ComponentSourceDir ([string]$doc.componentSourceDir))
}

function Test-GsRuntimeLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Layout)
    $errors = @()
    foreach ($pair in @(@('installDir', $Layout.InstallDir), @('stateDir', $Layout.StateDir), @('logDir', $Layout.LogDir), @('componentSourceDir', $Layout.ComponentSourceDir))) {
        if (-not (Test-Path -LiteralPath $pair[1] -PathType Container)) {
            $errors += New-GsRuntimeError 'DirectoryMissing' $pair[0] "Directory does not exist: $($pair[1])"
        }
    }
    [pscustomobject]@{ Success = ($errors.Count -eq 0); Layout = $Layout; Plan = $null; Errors = $errors }
}

function New-GsRuntimePlan {
    <#
    .SYNOPSIS
        Builds role definitions from a user-supplied component catalog. Read-only:
        verifies containment, existence, kind and SHA-256; never executes anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$CatalogPath
    )
    $errors = New-Object System.Collections.Generic.List[object]
    try { $catalogFile = Resolve-GsPath -Path $CatalogPath } catch {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'InvalidPath' 'catalogPath' $_.Exception.Message))
    }
    if (-not (Test-Path -LiteralPath $catalogFile -PathType Leaf)) {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'FileNotFound' 'catalogPath' "Catalog not found: $catalogFile"))
    }
    try { $catalog = [IO.File]::ReadAllText($catalogFile) | ConvertFrom-Json } catch {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'InvalidJson' 'catalogPath' 'Catalog is not valid JSON.'))
    }
    if ($null -eq $catalog -or $catalog -isnot [pscustomobject]) {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'InvalidType' '' 'Catalog root must be an object.'))
    }
    if (-not $catalog.PSObject.Properties['schemaVersion'] -or $catalog.schemaVersion -ne 1) {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'UnsupportedValue' 'schemaVersion' 'Only schemaVersion 1 is supported.'))
    }
    if (-not $catalog.PSObject.Properties['components'] -or $catalog.components -isnot [array] -or @($catalog.components).Count -eq 0) {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'InvalidType' 'components' 'components must be a non-empty array.'))
    }

    $source = $Layout.ComponentSourceDir
    $sourceFull = [IO.Path]::GetFullPath($source).TrimEnd('\')
    $components = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($item in @($catalog.components)) {
        if ($null -eq $item -or $item -isnot [pscustomobject]) {
            $errors.Add((New-GsRuntimeError 'InvalidType' 'components' 'Component entry must be an object.')); continue
        }
        $name = [string]$item.name
        if ([string]::IsNullOrWhiteSpace($name)) {
            $errors.Add((New-GsRuntimeError 'MissingField' 'name' 'Component name is required.')); continue
        }
        if ($seen.ContainsKey($name.ToLowerInvariant())) {
            $errors.Add((New-GsRuntimeError 'DuplicateComponent' 'name' "Duplicate component: $name")); continue
        }
        $seen[$name.ToLowerInvariant()] = $true
        foreach ($field in @('role', 'relativePath', 'kind')) {
            if (-not $item.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$item.$field)) {
                $errors.Add((New-GsRuntimeError 'MissingField' $field "Component $name is missing $field."))
            }
        }
        if ($errors.Count -gt 0) { continue }
        $kind = [string]$item.kind
        if ($kind -notin @('file', 'directory')) {
            $errors.Add((New-GsRuntimeError 'UnsupportedValue' 'kind' "Component $name has unsupported kind: $kind")); continue
        }
        $relative = [string]$item.relativePath
        if ([IO.Path]::IsPathRooted($relative)) {
            $errors.Add((New-GsRuntimeError 'PathEscape' 'relativePath' "Component $name must use a relative path.")); continue
        }
        $candidate = [IO.Path]::GetFullPath([IO.Path]::Combine($sourceFull, $relative))
        if (-not ($candidate -eq $sourceFull -or $candidate.StartsWith($sourceFull + '\', [StringComparison]::OrdinalIgnoreCase))) {
            $errors.Add((New-GsRuntimeError 'PathEscape' 'relativePath' "Component $name escapes the component source directory.")); continue
        }
        if ($kind -eq 'file') {
            if (-not (Test-Path -LiteralPath $candidate)) {
                $errors.Add((New-GsRuntimeError 'ComponentMissing' 'relativePath' "Component file not found: $candidate")); continue
            }
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $errors.Add((New-GsRuntimeError 'KindMismatch' 'kind' "Component $name is not a file.")); continue
            }
            $sha = [string]$item.sha256
            if ($sha -notmatch $script:HexSha256) {
                $errors.Add((New-GsRuntimeError 'MissingField' 'sha256' "Component $name needs a 64-hex sha256.")); continue
            }
            $actual = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $sha.ToLowerInvariant()) {
                $errors.Add((New-GsRuntimeError 'HashMismatch' 'sha256' "Component $name hash mismatch.")); continue
            }
        } else {
            if (-not (Test-Path -LiteralPath $candidate)) {
                $errors.Add((New-GsRuntimeError 'ComponentMissing' 'relativePath' "Component directory not found: $candidate")); continue
            }
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
                $errors.Add((New-GsRuntimeError 'KindMismatch' 'kind' "Component $name is not a directory.")); continue
            }
        }
        $components.Add([pscustomobject]@{
            Name         = $name
            Role         = [string]$item.role
            SourcePath   = $candidate
            Kind         = $kind
            Sha256       = $(if ($kind -eq 'file') { ([string]$item.sha256).ToLowerInvariant() } else { '' })
        })
    }
    if ($errors.Count -gt 0) { return (New-GsRuntimeResult $false $Layout $null $errors.ToArray()) }

    $requiredRoles = @('launcher', 'broker', 'nvs', 'nss', 'ssau')
    foreach ($role in $requiredRoles) {
        $found = @($components | Where-Object { $_.Role -eq $role })
        if ($found.Count -ne 1) {
            $errors.Add((New-GsRuntimeError 'RoleMissing' 'role' "Exactly one component must have role '$role' (found $($found.Count))."))
        }
    }
    if ($errors.Count -gt 0) { return (New-GsRuntimeResult $false $Layout $null $errors.ToArray()) }

    $launcher = @($components | Where-Object { $_.Role -eq 'launcher' })[0].SourcePath
    $broker = @($components | Where-Object { $_.Role -eq 'broker' })[0].SourcePath
    $nvs = @($components | Where-Object { $_.Role -eq 'nvs' })[0].SourcePath
    $nss = @($components | Where-Object { $_.Role -eq 'nss' })[0].SourcePath
    $ssau = @($components | Where-Object { $_.Role -eq 'ssau' })[0].SourcePath
    $roles = @(
        [pscustomobject]@{ Name='broker'; LauncherPath=$launcher; WorkingDirectory=$Layout.BinDir; PluginsPath=$Layout.PluginsDir; LogPath=(Join-Path $Layout.LogDir 'broker.log'); PidPath=(Join-Path $Layout.StateDir 'broker_pid.json'); ExpectedPipe='GsMessageBusBroadcast'; SessionMode='System'; SourcePath=$broker },
        [pscustomobject]@{ Name='nvs'; LauncherPath=$launcher; WorkingDirectory=$Layout.BinDir; PluginsPath=$nvs; LogPath=(Join-Path $Layout.LogDir 'nvs.log'); PidPath=(Join-Path $Layout.StateDir 'nvs_pid.json'); ExpectedPipe='GsMessageBusBroadcast'; SessionMode='System'; SourcePath=$nvs },
        [pscustomobject]@{ Name='nss'; LauncherPath=$launcher; WorkingDirectory=$Layout.BinDir; PluginsPath=$nss; LogPath=(Join-Path $Layout.LogDir 'nss.log'); PidPath=(Join-Path $Layout.StateDir 'nss_pid.json'); ExpectedPipe='GsMessageBusBroadcast'; SessionMode='System'; SourcePath=$nss },
        [pscustomobject]@{ Name='ssau'; LauncherPath=$launcher; WorkingDirectory=$Layout.BinDir; PluginsPath=$ssau; LogPath=(Join-Path $Layout.LogDir 'ssau.log'); PidPath=(Join-Path $Layout.StateDir 'ssau_pid.json'); ExpectedPipe='GsMessageBusBroadcast'; SessionMode='ActiveConsole'; SourcePath=$ssau }
    )
    $plan = [pscustomobject]@{
        Roles      = $roles
        Components = $components.ToArray()
        ConfigPath = $Layout.GeneratedConfigPath
    }
    return (New-GsRuntimeResult $true $Layout $plan @())
}

function New-GsComponentCatalog {
    <#
    .SYNOPSIS
        Generates a component catalog for the expected private-stack layout,
        computing SHA-256 for the launcher and broadcaster. Read-only on source.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ComponentSourceDir,
        [Parameter(Mandatory = $true)][string]$CatalogPath,
        [switch]$Force
    )
    try { $source = Resolve-GsPath -Path $ComponentSourceDir } catch {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'InvalidPath' 'componentSourceDir' $_.Exception.Message))
    }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'DirectoryMissing' 'componentSourceDir' "Source tree not found: $source"))
    }
    try { $catalog = Resolve-GsPath -Path $CatalogPath } catch {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'InvalidPath' 'catalogPath' $_.Exception.Message))
    }
    $parent = Split-Path -Parent $catalog
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'DirectoryMissing' 'catalogPath' "Catalog parent not found: $parent"))
    }
    if ((Test-Path -LiteralPath $catalog) -and -not $Force) {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'AlreadyExists' 'catalogPath' "Catalog exists: $catalog (use -Force)"))
    }
    $expected = @(
        [pscustomobject]@{ Name='NvContainer'; Role='launcher'; RelativePath='NvContainer\NvContainer.exe'; Kind='file' },
        [pscustomobject]@{ Name='Broadcaster'; Role='broker'; RelativePath='GSRoot\LocalSystem\NvMessageBusBroadcast.dll.disabled'; Kind='file' },
        [pscustomobject]@{ Name='NVS'; Role='nvs'; RelativePath='GSRoot\LocalSystem'; Kind='directory' },
        [pscustomobject]@{ Name='NSS'; Role='nss'; RelativePath='GSRoot\NetworkService'; Kind='directory' },
        [pscustomobject]@{ Name='SSAU'; Role='ssau'; RelativePath='NvStreamSrv\Plugins\SSAU'; Kind='directory' }
    )
    $errors = New-Object System.Collections.Generic.List[object]
    $components = New-Object System.Collections.Generic.List[object]
    foreach ($e in $expected) {
        $p = [IO.Path]::GetFullPath([IO.Path]::Combine($source, $e.RelativePath))
        if ($e.Kind -eq 'file') {
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
                $errors.Add((New-GsRuntimeError 'ComponentMissing' $e.Name "Component file not found: $p")); continue
            }
            $hash = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
            $components.Add([ordered]@{ name=$e.Name; role=$e.Role; relativePath=$e.RelativePath; kind='file'; sha256=$hash })
        } else {
            if (-not (Test-Path -LiteralPath $p -PathType Container)) {
                $errors.Add((New-GsRuntimeError 'ComponentMissing' $e.Name "Component directory not found: $p")); continue
            }
            $components.Add([ordered]@{ name=$e.Name; role=$e.Role; relativePath=$e.RelativePath; kind='directory'; sha256='' })
        }
    }
    if ($errors.Count -gt 0) { return (New-GsRuntimeResult $false $null $null $errors.ToArray()) }
    $doc = [ordered]@{ schemaVersion = 1; components = $components.ToArray() }
    try {
        $tmp = $catalog + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $catalog -Force
    } catch {
        return (New-GsRuntimeResult $false $null $null @(New-GsRuntimeError 'PersistFailed' 'catalogPath' $_.Exception.Message))
    }
    $plan = [pscustomobject]@{ CatalogPath = $catalog; Components = $components.ToArray() }
    return (New-GsRuntimeResult $true $null $plan @())
}

function Import-GsRuntimeTree {
    <#
    .SYNOPSIS
        Copies a user-provided component tree into the product install directory.
        Excludes runtime state/log/backup directories. Never writes to the source.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$ComponentSourceDir,
        [switch]$Force
    )
    try { $source = Resolve-GsPath -Path $ComponentSourceDir } catch {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'InvalidPath' 'componentSourceDir' $_.Exception.Message))
    }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'DirectoryMissing' 'componentSourceDir' "Source tree not found: $source"))
    }
    $sourceCmp = (Get-GsComparablePath $source)
    $installCmp = (Get-GsComparablePath $Layout.InstallDir)
    if ($sourceCmp -eq $installCmp -or (Test-GsPathInside $Layout.InstallDir $source) -or (Test-GsPathInside $source $Layout.InstallDir)) {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'NestedDirectory' 'componentSourceDir' 'Component source and install directory must not overlap.'))
    }
    if (-not (Test-Path -LiteralPath $Layout.InstallDir)) { New-Item -ItemType Directory -Path $Layout.InstallDir -Force | Out-Null }
    $excluded = @('gsprivate', 'logs', 'backup', 'state')
    $copied = 0
    try {
        foreach ($item in @(Get-ChildItem -LiteralPath $source -Force)) {
            if ($excluded -contains $item.Name.ToLowerInvariant()) { continue }
            $dst = Join-Path $Layout.InstallDir $item.Name
            if ((Test-Path -LiteralPath $dst) -and -not $Force) {
                return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'AlreadyExists' 'installDir' "Target exists: $dst (use -Force)"))
            }
            Copy-Item -LiteralPath $item.FullName -Destination $dst -Recurse -Force
            $copied++
        }
    } catch {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'CopyFailed' 'installDir' $_.Exception.Message))
    }
    $plan = [pscustomobject]@{ SourceDir = $source; InstallDir = $Layout.InstallDir; CopiedTopLevelItems = $copied }
    return (New-GsRuntimeResult $true $Layout $plan @())
}

$script:BundleHelpers = @(
    'gs_start_private.ps1',
    'gs_stop_private.ps1',
    'gs_start_with_hook.ps1',
    'gs_supervisor.ps1',
    'gs_grant_pipe_acl.ps1',
    'gs_process_identity.ps1',
    'gs_launcher.py',
    'inject_nvstreamer.py',
    'patch_applist_mem.py',
    'gs_nsc_supported.py',
    'gs_mdns_probe.py'
)

function Install-GsRuntimeBundle {
    <#
    .SYNOPSIS
        Copies the proven control scripts into the product bin directory and
        rewrites the legacy C:\Tools\NvStreamSrv root to this layout.
        Does not start processes, services or scheduled tasks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$HelperSourceDir,
        [switch]$Force
    )
    $errors = New-Object System.Collections.Generic.List[object]
    try { $source = Resolve-GsPath -Path $HelperSourceDir } catch {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'InvalidPath' 'helperSourceDir' $_.Exception.Message))
    }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        return (New-GsRuntimeResult $false $Layout $null @(New-GsRuntimeError 'DirectoryMissing' 'helperSourceDir' "Helper source not found: $source"))
    }
    foreach ($name in $script:BundleHelpers) {
        $p = Join-Path $source $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            $errors.Add((New-GsRuntimeError 'HelperMissing' 'helperSourceDir' "Required helper missing: $p"))
        }
    }
    if ($errors.Count -gt 0) { return (New-GsRuntimeResult $false $Layout $null $errors.ToArray()) }

    $runtimeDir = $Layout.RuntimeDir
    $runtimeBin = $Layout.RuntimeBinDir
    $dirs = @($Layout.InstallDir, $Layout.StateDir, $Layout.LogDir, $Layout.BinDir, $runtimeDir, $runtimeBin, $Layout.PluginsDir, $Layout.BrokerLogDir)
    foreach ($d in $dirs) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

    $hookSource = Join-Path $source 'NvStreamerBusHook.dll'
    if (-not (Test-Path -LiteralPath $hookSource -PathType Leaf)) {
        $errors.Add((New-GsRuntimeError 'HelperMissing' 'helperSourceDir' "Required helper missing: $hookSource"))
        return (New-GsRuntimeResult $false $Layout $null $errors.ToArray())
    }
    # The stream guard DLL is checked before anything is copied so a missing
    # guard never leaves a half-installed runtime.
    $guardSource = Join-Path $source 'GsStreamGuard.dll'
    if (-not (Test-Path -LiteralPath $guardSource -PathType Leaf)) {
        $errors.Add((New-GsRuntimeError 'HelperMissing' 'helperSourceDir' "Required helper missing: $guardSource"))
        return (New-GsRuntimeResult $false $Layout $null $errors.ToArray())
    }
    $guardTarget = Join-Path $runtimeBin 'GsStreamGuard.dll'
    if ((Test-Path -LiteralPath $guardTarget) -and -not $Force) {
        $errors.Add((New-GsRuntimeError 'AlreadyExists' 'runtimeBinDir' "Target exists: $guardTarget (use -Force)"))
    }
    $hookTargets = @((Join-Path $runtimeDir 'NvStreamerBusHook.dll'), (Join-Path $runtimeBin 'NvStreamerBusHook.dll'))
    foreach ($t in $hookTargets) {
        if ((Test-Path -LiteralPath $t) -and -not $Force) {
            $errors.Add((New-GsRuntimeError 'AlreadyExists' 'runtimeDir' "Target exists: $t (use -Force)"))
        }
    }
    if ($errors.Count -gt 0) { return (New-GsRuntimeResult $false $Layout $null $errors.ToArray()) }
    foreach ($t in $hookTargets) { Copy-Item -LiteralPath $hookSource -Destination $t -Force }
    Copy-Item -LiteralPath $guardSource -Destination $guardTarget -Force

    $legacyPrivate = 'C:\Tools\NvStreamSrv\GsPrivate'
    $legacyRoot = 'C:\Tools\NvStreamSrv'
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:BundleHelpers) {
        $src = Join-Path $source $name
        $dst = Join-Path $runtimeBin $name
        if ((Test-Path -LiteralPath $dst) -and -not $Force) {
            $errors.Add((New-GsRuntimeError 'AlreadyExists' 'runtimeBinDir' "Target exists: $dst (use -Force)")); continue
        }
        $text = [IO.File]::ReadAllText($src)
        $text = $text.Replace($legacyPrivate, $runtimeDir).Replace($legacyRoot, $Layout.InstallDir)
        $text = $text.Replace($legacyPrivate.Replace('\', '/'), $runtimeDir.Replace('\', '/')).Replace($legacyRoot.Replace('\', '/'), $Layout.InstallDir.Replace('\', '/'))
        [IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding($false)))
        $files.Add($dst)
    }
    if ($errors.Count -gt 0) { return (New-GsRuntimeResult $false $Layout $null $errors.ToArray()) }
    $written = Write-GsRuntimeConfig -Layout $Layout -Path $Layout.GeneratedConfigPath
    if (-not $written.Success) { return $written }
    $plan = [pscustomobject]@{ RuntimeDir = $runtimeDir; Files = $files.ToArray(); ConfigPath = $Layout.GeneratedConfigPath }
    return (New-GsRuntimeResult $true $Layout $plan @())
}

function Test-GsRuntimeBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Layout)
    $errors = @()
    foreach ($name in $script:BundleHelpers) {
        $p = Join-Path $Layout.RuntimeBinDir $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            $errors += New-GsRuntimeError 'BundleFileMissing' 'binDir' "Bundle file missing: $p"
            continue
        }
        $text = [IO.File]::ReadAllText($p)
        if ($text.Contains('C:\Tools\NvStreamSrv') -or $text.Contains('C:/Tools/NvStreamSrv')) {
            $errors += New-GsRuntimeError 'LegacyPath' 'binDir' "Bundle file still references the legacy root: $p"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Layout.RuntimeDir 'NvStreamerBusHook.dll') -PathType Leaf)) {
        $errors += New-GsRuntimeError 'BundleFileMissing' 'runtimeDir' 'NvStreamerBusHook.dll is missing from the runtime directory.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Layout.RuntimeBinDir 'GsStreamGuard.dll') -PathType Leaf)) {
        $errors += New-GsRuntimeError 'BundleFileMissing' 'runtimeBinDir' 'GsStreamGuard.dll is missing from the runtime bin directory.'
    }
    if (-not (Test-Path -LiteralPath $Layout.GeneratedConfigPath -PathType Leaf)) {
        $errors += New-GsRuntimeError 'ConfigMissing' 'config' "Runtime config missing: $($Layout.GeneratedConfigPath)"
    }
    [pscustomobject]@{ Success = ($errors.Count -eq 0); Layout = $Layout; Plan = $null; Errors = $errors }
}

Export-ModuleMember -Function New-GsRuntimeLayout, Read-GsRuntimeConfig, Write-GsRuntimeConfig, Test-GsRuntimeLayout, New-GsRuntimePlan, New-GsComponentCatalog, Import-GsRuntimeTree, Install-GsRuntimeBundle, Test-GsRuntimeBundle
