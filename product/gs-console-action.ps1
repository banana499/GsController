#requires -Version 5.1
<#
.SYNOPSIS
  Fixed -File helper for the GsController local console server.

.DESCRIPTION
  The server spawns this script (with an explicit system powershell.exe
  path and -STA) for long actions and for the STA folder picker. ALL inputs
  come from a server-generated JSON request file (request.json); the server
  also generates the result file path (result.json). Browser requests can
  never choose a command, script or path.

  Request JSON: { schemaVersion: 1, action, productPath, moduleRoot,
  installDir, stateDir, logDir, componentSourceDir, helperSourceDir,
  catalogPath, diagnoseScript, serverInfoUri }.

  Result JSON: { schemaVersion: 1, action, success (strict JSON boolean),
  code, reason, data }. The helper always exits 0; a best-effort result
  write failure leaves the result file missing and the server reports a
  truthful NoResult failure.

  For each CLI invocation the helper keeps ONLY the LAST output element
  that is an object with a Success property (the product result; stray
  runtime output before it is dropped and is never a browser response or a
  log). A deploy runs CreateCatalog first, then Install, and reports the
  Install outcome. The helper never kills processes and never touches
  scheduled tasks, services, ACLs, the registry or the firewall; those are
  the CLI's own concerns on explicit user actions only.

  -PickFolder mode (STA): shows one native folder browser dialog for the
  field the server named in the request and writes
  { success, code, data: { selectedPath } }. Cancelling reports
  code 'Cancelled' with selectedPath null - a completed browse, not a
  failure. Demo mode never reaches this helper at all.
#>
[CmdletBinding()]
param(
    [string]$RequestFile = '',
    [string]$ResultFile = '',
    [switch]$PickFolder,
    # Test seam: define the functions and exit without running anything.
    [switch]$DefineOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AllowedActions = @('start', 'stop', 'recover', 'check', 'deploy', 'diagnose',
    'autostart-enable', 'autostart-disable')

function Get-LastSuccessResult {
    # Picks the LAST output element that is a pscustomobject with a Success
    # property; $null when there is none (the caller reports NoResult).
    param($Output)
    if ($null -eq $Output) { return $null }
    $items = @($Output)
    for ($i = $items.Count - 1; $i -ge 0; $i--) {
        $item = $items[$i]
        if ($null -ne $item -and $item -is [pscustomobject] -and $null -ne $item.PSObject.Properties['Success']) {
            return $item
        }
    }
    return $null
}

function Read-GsActionRequest {
    # Bounded, strict request read. Returns a hashtable or $null.
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $info = Get-Item -LiteralPath $Path
        if ($info.Length -gt 65536) { return $null }
        $text = [IO.File]::ReadAllText($Path)
        $doc = $text | ConvertFrom-Json
        if ($null -eq $doc -or $doc -isnot [pscustomobject]) { return $null }
        if (-not $doc.PSObject.Properties['schemaVersion']) { return $null }
        if (([string]$doc.schemaVersion) -ne '1') { return $null }
        if (-not $doc.PSObject.Properties['action']) { return $null }
        $action = $doc.action
        if ($action -isnot [string] -or $action -notin $script:AllowedActions) { return $null }
        $request = @{ action = $action }
        foreach ($name in @('productPath', 'moduleRoot', 'installDir', 'stateDir', 'logDir',
                'componentSourceDir', 'helperSourceDir', 'catalogPath', 'diagnoseScript', 'serverInfoUri')) {
            $value = ''
            $prop = $doc.PSObject.Properties[$name]
            if ($null -ne $prop -and $prop.Value -is [string]) { $value = [string]$prop.Value }
            $request.$name = $value
        }
        return $request
    } catch { return $null }
}

function Build-GsActionCliArguments {
    # Pure mapping: validated request hashtable -> an ordered list of CLI
    # splatting hashtables (deploy = CreateCatalog then Install; every other
    # action is a single fixed invocation). HASHTABLES are mandatory here:
    # array splatting passes elements POSITIONALLY, which would feed the
    # literal string '-Action' into the CLI's first parameter. Keys match
    # the gs-product.ps1 parameter names exactly; no free-form flags exist.
    param([Parameter(Mandatory = $true)]$Request)
    $invocations = @()
    switch ($Request.action) {
        'start' {
            $splat = @{ Action = 'Start' }
            if ($Request.stateDir -ne '') { $splat.StateDir = $Request.stateDir }
            if ($Request.logDir -ne '') { $splat.LogDir = $Request.logDir }
            if ($Request.installDir -ne '') { $splat.InstallDir = $Request.installDir }
            if ($Request.moduleRoot -ne '') { $splat.ModuleRoot = $Request.moduleRoot }
            $invocations += , $splat
        }
        'stop' {
            $splat = @{ Action = 'Stop' }
            if ($Request.stateDir -ne '') { $splat.StateDir = $Request.stateDir }
            if ($Request.logDir -ne '') { $splat.LogDir = $Request.logDir }
            $invocations += , $splat
        }
        'recover' {
            $splat = @{ Action = 'Recover' }
            if ($Request.stateDir -ne '') { $splat.StateDir = $Request.stateDir }
            if ($Request.logDir -ne '') { $splat.LogDir = $Request.logDir }
            if ($Request.serverInfoUri -ne '') { $splat.ServerInfoUri = $Request.serverInfoUri }
            $invocations += , $splat
        }
        'check' {
            $splat = @{ Action = 'Check' }
            if ($Request.stateDir -ne '') { $splat.StateDir = $Request.stateDir }
            if ($Request.logDir -ne '') { $splat.LogDir = $Request.logDir }
            $invocations += , $splat
        }
        'diagnose' {
            $splat = @{ Action = 'Diagnose' }
            if ($Request.stateDir -ne '') { $splat.StateDir = $Request.stateDir }
            if ($Request.logDir -ne '') { $splat.LogDir = $Request.logDir }
            if ($Request.installDir -ne '') { $splat.InstallDir = $Request.installDir }
            if ($Request.diagnoseScript -ne '') { $splat.DiagnoseScript = $Request.diagnoseScript }
            if ($Request.serverInfoUri -ne '') { $splat.ServerInfoUri = $Request.serverInfoUri }
            $invocations += , $splat
        }
        'autostart-enable' {
            $splat = @{ Action = 'RegisterAutostart' }
            if ($Request.stateDir -ne '') { $splat.StateDir = $Request.stateDir }
            if ($Request.logDir -ne '') { $splat.LogDir = $Request.logDir }
            if ($Request.installDir -ne '') { $splat.InstallDir = $Request.installDir }
            if ($Request.moduleRoot -ne '') { $splat.ModuleRoot = $Request.moduleRoot }
            $invocations += , $splat
        }
        'autostart-disable' {
            $splat = @{ Action = 'UnregisterAutostart' }
            if ($Request.stateDir -ne '') { $splat.StateDir = $Request.stateDir }
            if ($Request.logDir -ne '') { $splat.LogDir = $Request.logDir }
            $invocations += , $splat
        }
        'deploy' {
            # Create catalog parent, then CreateCatalog, then Install, with
            # explicit source/layout/module/catalog inputs.
            $stateParent = Split-Path -Parent $Request.catalogPath
            if (-not [string]::IsNullOrEmpty($stateParent) -and -not (Test-Path -LiteralPath $stateParent)) {
                New-Item -ItemType Directory -Path $stateParent -Force | Out-Null
            }
            $catalogSplat = @{
                Action             = 'CreateCatalog'
                ComponentSourceDir = $Request.componentSourceDir
                CatalogPath        = $Request.catalogPath
            }
            if ($Request.stateDir -ne '') { $catalogSplat.StateDir = $Request.stateDir }
            if ($Request.logDir -ne '') { $catalogSplat.LogDir = $Request.logDir }
            if ($Request.moduleRoot -ne '') { $catalogSplat.ModuleRoot = $Request.moduleRoot }
            $invocations += , $catalogSplat

            $installSplat = @{
                Action             = 'Install'
                ComponentSourceDir = $Request.componentSourceDir
                CatalogPath        = $Request.catalogPath
            }
            if ($Request.helperSourceDir -ne '') { $installSplat.HelperSourceDir = $Request.helperSourceDir }
            if ($Request.installDir -ne '') { $installSplat.InstallDir = $Request.installDir }
            if ($Request.stateDir -ne '') { $installSplat.StateDir = $Request.stateDir }
            if ($Request.logDir -ne '') { $installSplat.LogDir = $Request.logDir }
            if ($Request.moduleRoot -ne '') { $installSplat.ModuleRoot = $Request.moduleRoot }
            $invocations += , $installSplat
        }
    }
    # Preserve the list shape across the pipeline boundary (a plain return
    # would enumerate the inner splatting hashtables' entries).
    return , $invocations
}

function Invoke-GsActionRunCli {
    # Runs ONE fixed CLI invocation inline and returns
    # { Success; Code; Reason; Data } from its LAST Success object.
    # Structured failures, throws and result-less runs all become a
    # truthful failure code; raw output is dropped, never stored or shown.
    param(
        [Parameter(Mandatory = $true)][string]$ProductPath,
        # A splatting hashtable (named parameters); array splatting would be
        # POSITIONAL and would feed '-Action' into the first parameter.
        [Parameter(Mandatory = $true)]$Arguments
    )
    try {
        $output = & $ProductPath @Arguments
        $result = Get-LastSuccessResult -Output $output
        if ($null -eq $result) {
            return @{ Success = $false; Code = 'NoResult'; Reason = ''; Data = $null }
        }
        $success = $false
        if ($result.Success -is [bool]) { $success = [bool]$result.Success }
        $code = ''
        $reason = ''
        if (-not $success -and $null -ne $result.PSObject.Properties['Errors'] -and $null -ne $result.Errors) {
            $first = @($result.Errors)[0]
            if ($null -ne $first -and $first -is [pscustomobject]) {
                if ($first.PSObject.Properties['Code'] -and $first.Code -is [string]) { $code = [string]$first.Code }
                if ($first.PSObject.Properties['Reason'] -and $first.Reason -is [string]) { $reason = [string]$first.Reason }
            }
        }
        $data = $null
        if ($null -ne $result.PSObject.Properties['Data']) { $data = $result.Data }
        return @{ Success = $success; Code = $code; Reason = $reason; Data = $data; Errors = $result.Errors }
    } catch {
        return @{ Success = $false; Code = 'CliException'; Reason = ''; Data = $null }
    }
}

function Write-GsActionResult {
    # Best-effort result write (UTF-8, no BOM). A failed write leaves the
    # result file missing; the child still exits 0 and the server reports
    # NoResult truthfully.
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][bool]$Success,
        [AllowEmptyString()][string]$Code,
        [AllowEmptyString()][string]$Reason,
        [AllowNull()]$Data
    )
    try {
        $doc = [ordered]@{
            schemaVersion = 1
            action        = $Action
            success       = [bool]$Success
            code          = [string]$Code
            reason        = [string]$Reason
            data          = $Data
        }
        $parent = Split-Path -Parent $ResultFile
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllText($ResultFile, ($doc | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    } catch { }
    exit 0
}

function Invoke-GsActionPickFolder {
    # STA folder picker for exactly the field the server named. The selected
    # path is the only data returned; the user still saves explicitly.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'GsController'
        $dialog.ShowNewFolderButton = $true
        $choice = $dialog.ShowDialog((New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }))
        if ($choice -eq [System.Windows.Forms.DialogResult]::OK) {
            $selected = ''
            try { $selected = [string]$dialog.SelectedPath } catch { $selected = '' }
            if ([string]::IsNullOrWhiteSpace($selected)) {
                Write-GsActionResult -Action 'browse' -Success $false -Code 'Cancelled' -Data ([pscustomobject]@{ selectedPath = $null })
            }
            Write-GsActionResult -Action 'browse' -Success $true -Code 'Ok' -Data ([pscustomobject]@{ selectedPath = $selected })
        }
        Write-GsActionResult -Action 'browse' -Success $true -Code 'Cancelled' -Data ([pscustomobject]@{ selectedPath = $null })
    } catch {
        Write-GsActionResult -Action 'browse' -Success $false -Code 'PickFolderUnavailable' -Data ([pscustomobject]@{ selectedPath = $null })
    }
}

# --- main -------------------------------------------------------------------
if (-not $DefineOnly) {
    if ($PickFolder) {
        if ([string]::IsNullOrWhiteSpace($ResultFile)) { exit 2 }
        Invoke-GsActionPickFolder
    }
    if ([string]::IsNullOrWhiteSpace($RequestFile) -or [string]::IsNullOrWhiteSpace($ResultFile)) { exit 2 }

    $request = Read-GsActionRequest -Path $RequestFile
    if ($null -eq $request) {
        Write-GsActionResult -Action 'unknown' -Success $false -Code 'InvalidRequest' -Data $null
    }
    if ([string]::IsNullOrWhiteSpace($request.productPath) -or -not (Test-Path -LiteralPath $request.productPath -PathType Leaf)) {
        Write-GsActionResult -Action $request.action -Success $false -Code 'InvalidRequest' -Data $null
    }

    $invocations = Build-GsActionCliArguments -Request $request
    $outcome = $null
    foreach ($invocation in $invocations) {
        $outcome = Invoke-GsActionRunCli -ProductPath $request.productPath -Arguments $invocation
        if (-not $outcome.Success) {
            # Deploy: a failed CreateCatalog is the reported failure; Install
            # is never attempted. Single-invocation actions end here too.
            break
        }
    }
    if ($null -eq $outcome) {
        Write-GsActionResult -Action $request.action -Success $false -Code 'NoResult' -Data $null
    }

    $data = $outcome.Data
    if ($request.action -eq 'check') {
        # Structured check errors only (code + field) for the server's summary.
        $errors = @()
        if ($null -ne $outcome.Errors) {
            foreach ($entry in @($outcome.Errors)) {
                if ($null -eq $entry -or $entry -isnot [pscustomobject]) { continue }
                $code = ''
                $field = ''
                if ($entry.PSObject.Properties['Code'] -and $entry.Code -is [string]) { $code = [string]$entry.Code }
                if ($entry.PSObject.Properties['Field'] -and $entry.Field -is [string]) { $field = [string]$entry.Field }
                $errors += [pscustomobject]@{ code = $code; field = $field }
            }
        }
        $data = [pscustomobject]@{ errors = $errors }
    }
    Write-GsActionResult -Action $request.action -Success ([bool]$outcome.Success) -Code $outcome.Code -Reason $outcome.Reason -Data $data
}
