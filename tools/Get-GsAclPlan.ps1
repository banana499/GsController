#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only ACL pre-check for the GsController state directory. Prints a
    JSON plan ({ Success, Data, Errors }) describing how each candidate
    target directory compares to the target ACL policy and why nothing can
    be applied yet.

.DESCRIPTION
    For the three explicit candidate targets (<StateDir>, <StateDir>\runtime,
    <StateDir>\runtime\bin) this tool reads ONLY metadata: it walks the
    ancestor chain of each target level by level (from the drive root down
    to the target itself) with at most one Get-Item attribute read per
    unique path per run (results are cached and shared between branches), and
    at most one Get-Acl read per target whose whole chain is clean. It never
    enumerates directory contents, never reads file content, never reads the
    runtime bundle, logs or any credential material, and never modifies
    anything: there is no Set-Acl, no apply and no harden path in this phase.

    Path traversal safety: the ancestor chain of every target is checked
    level by level. A reparse point OBSERVED DURING THE CHECK anywhere on a
    target's ancestor chain (StateDir ancestors included) blocks the whole
    branch. A missing ancestor means the target is missing; a metadata read
    error (anything other than a clear not-found) is a structured failure
    that blocks the branch instead of being misread as "missing".

    LIMITS: the plan is a READ-TIME SNAPSHOT (marked in Data.Snapshot). It
    requires the directory topology to stay stable while the check runs; a
    concurrent junction or ACL change between the metadata walk and the
    Get-Acl read can invalidate the snapshot, and this tool does not defend
    against that (no native handle pinning in this phase). The refusal of
    reparse points covers what the check observed, it is not an atomic
    guarantee. This tool is NOT an access-control sandbox and NOT an apply
    authorization; applyReady stays false everywhere.

    Every target is reported with applyReady = $false, regardless of the ACL
    verdict, because user-session write migration is unconfirmed
    (security-design.md 4.2 / 4.7):
      - stateDir   : StateRootWritesNotConfirmed (phase 2 of the rollout;
                     runtime-config.json / status.json / pause flag writes
                     must be confirmed elevated-only first);
      - runtime    : RuntimeStateUserWritesNotConfirmed (runtime\state needs
                     user-session write for hook_watchers.json until the
                     writes are migrated);
      - runtimeBin : UserSessionLogMigrationNotConfirmed (user-session logs
                     such as _watch_inject_auto.log/.err must be migrated or
                     confirmed SYSTEM-only before hardening).
    A compliant ACL therefore never means "safe to apply"; see
    docs/acl-policy.md. This module is not wired into the product Install
    action.

    Path safety: -StateDir must be an absolute, canonical path; relative
    paths and any non-canonical form (for example '..' or '.' segments or
    forward slashes) are rejected.

    Simulation marking: Data.Simulation.TestSeamsUsed is $true whenever any
    test seam is bound (including seams that simulate error returns), with
    the seam names in Data.Simulation.Seams. Output produced with seams must
    never be presented as evidence from a real machine.

    Privacy: no account names are resolved anywhere; machine-local SIDs are
    masked (S-1-5-21-*-RID) and the user profile path prefix is replaced in
    the emitted JSON.

    Parameters -GetItemReader, -ItemState and -AclSddl are documented TEST
    SEAMS (the same pattern as gs-diagnose.ps1); they only replace reads
    with simulated values and are never a write path.

    JSON output contract: arrays are ALWAYS serialized as arrays (empty
    "[]", single-element "[ ... ]"). The built-in ConvertTo-Json is used
    with -InputObject and -Depth 12; it preserves empty and single-element
    arrays when the input is a proper array, which the redaction layer
    guarantees (array returns are comma-protected against PS unrolling).
    Entry keys are lowercase; nested finding objects keep the module's
    Code/Severity/Message casing.

    Exit code 0 when the plan was produced cleanly (Success = true, even if
    targets deviate or are missing); exit code 1 when arguments were invalid
    or a target had to be refused (Success = false).

.EXAMPLE
    powershell.exe -File tools\Get-GsAclPlan.ps1 -StateDir "$env:ProgramData\Local Development\GsController"
#>
[CmdletBinding()]
param(
    # Root state directory to plan for. Required, absolute and canonical.
    [Parameter(Mandatory = $true)][string]$StateDir,

    # TEST SEAM. When bound: replaces the real metadata read for every
    # ancestor level and target. Contract: receives one path, returns $null
    # for a clear not-found, an object exposing .Attributes otherwise, and
    # THROWS for any other read failure (an exception is a structured
    # failure, never silently treated as missing).
    [AllowNull()][scriptblock]$GetItemReader,

    # TEST SEAM. When bound: one value per target ('stateDir', 'runtime',
    # 'runtimeBin') replacing the whole branch walk. Allowed values:
    # 'missing', 'reparsePoint', 'notDirectory' (alias 'file', accepted for
    # seam compatibility and normalized), 'directory', 'unreadable'. An
    # array shorter than three targets is an argument error.
    [AllowNull()][string[]]$ItemState,

    # TEST SEAM. When bound: one SDDL string per target, parsed in memory and
    # used instead of the real Get-Acl read of that target. An empty value
    # marks that target's ACL as unreadable. Only consulted for targets whose
    # resolved state is 'directory'.
    [AllowNull()][string[]]$AclSddl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleManifest = Join-Path $PSScriptRoot '..\src\GsSecurity\GsSecurity.psd1'
Import-Module $moduleManifest -Force -ErrorAction Stop

function Write-GsPlanStdout {
    # Deterministic stdout encoding: PS 5.1 fixes the redirected-stdout
    # writer encoding at host startup, so changing [Console]::OutputEncoding
    # mid-run does NOT affect Write-Output (verified: under codepage 437 the
    # setter reports utf-8 while Write-Output still emits '?'). The JSON is
    # therefore written as UTF-8 bytes directly to the stdout handle:
    # codepage-independent, process-scoped, no system setting is touched.
    param([AllowNull()][string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8.GetBytes(([string]$Text) + [Environment]::NewLine)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

# ---------------------------------------------------------------------------
# Redaction. Everything emitted passes through a final walk that masks
# machine-local SIDs (S-1-5-21-*-$RID) and the user profile path prefix, so
# neither a machine SID nor the account name inside a %TEMP% path can leak.
# ---------------------------------------------------------------------------
$script:UserProfilePath = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)

function Hide-GsPlanSid {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [System.Text.RegularExpressions.Regex]::Replace($Text, 'S-1-5-21-\d+-\d+-\d+-(\d+)', 'S-1-5-21-*-$1')
}

# Case-insensitive, boundary-aware profile prefix masking: Windows paths
# vary in case, so a literal case-sensitive .Replace() would leak case
# variants. The lookahead keeps the match at a path-component boundary
# (followed by a separator or the end of the string), so a longer sibling
# directory name that merely starts with the profile text is not masked.
$script:UserProfilePathRegex = $null
if (-not [string]::IsNullOrEmpty($script:UserProfilePath)) {
    $script:UserProfilePathRegex = New-Object System.Text.RegularExpressions.Regex ([System.Text.RegularExpressions.Regex]::Escape($script:UserProfilePath) + '(?=\\|$)'), ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Hide-GsPlanProfile {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text) -or ($null -eq $script:UserProfilePathRegex)) { return $Text }
    return $script:UserProfilePathRegex.Replace($Text, '<UserProfile>')
}

function Hide-GsPlanText {
    param([AllowNull()][string]$Text)
    return (Hide-GsPlanSid (Hide-GsPlanProfile $Text))
}

function Hide-GsPlanInObject {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Hide-GsPlanText $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{ }
        foreach ($key in @($Value.Keys)) { $out[$key] = Hide-GsPlanInObject -Value $Value[$key] }
        return $out
    }
    if ($Value -is [pscustomobject]) {
        $out = [ordered]@{ }
        foreach ($prop in @($Value.PSObject.Properties)) { $out[$prop.Name] = Hide-GsPlanInObject -Value $prop.Value }
        return [pscustomobject]$out
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) { $out.Add((Hide-GsPlanInObject -Value $item)) }
        # The comma keeps the array from being unrolled by the function
        # return (PS turns empty arrays into $null and single-element arrays
        # into the bare element otherwise).
        return (,$out.ToArray())
    }
    return $Value
}

function New-PlanError {
    param([string]$Code, [string]$Message, [AllowNull()][string]$Target)
    [pscustomobject]@{ Code = $Code; Target = $Target; Message = $Message }
}

function New-PlanTargetEntry {
    param([string]$Key, [string]$Path, [string[]]$Blockers)
    [ordered]@{
        target     = $Key
        path       = $Path
        status     = 'pendingEvaluation'
        compliant  = $false
        ownerSid   = $null
        writers    = @()
        usersRightsHex = $null
        findings   = @()
        applyReady = $false
        applyBlockers = @($Blockers)
    }
}

# ---------------------------------------------------------------------------
# Argument validation: -StateDir must be absolute and canonical. Non-canonical
# input ('..', '.', forward slashes, relative) is rejected outright instead of
# silently normalized, so a path cannot escape the intended root.
# ---------------------------------------------------------------------------
$errors = New-Object System.Collections.Generic.List[object]
$canonicalStateDir = $null

if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $errors.Add((New-PlanError 'StateDirRequired' 'StateDir must not be empty.' $null))
} elseif (-not [System.IO.Path]::IsPathRooted($StateDir)) {
    $errors.Add((New-PlanError 'StateDirMustBeAbsolute' 'StateDir must be an absolute path.' $null))
} else {
    try {
        $canonicalStateDir = [System.IO.Path]::GetFullPath($StateDir)
    } catch {
        $errors.Add((New-PlanError 'StateDirNotResolvable' 'StateDir could not be resolved to a full path.' $null))
    }
    if ($null -ne $canonicalStateDir) {
        $inputCanonical = $StateDir.TrimEnd('\', '/')
        $fullCanonical = $canonicalStateDir.TrimEnd('\')
        if ($inputCanonical -ine $fullCanonical) {
            $canonicalStateDir = $null
            $errors.Add((New-PlanError 'StateDirMustBeCanonical' 'StateDir must be a canonical absolute path; relative segments (for example .. or .) and non-native separators are rejected.' $null))
        }
    }
}

$itemStateSeam = $PSBoundParameters.ContainsKey('ItemState')
$aclSddlSeam = $PSBoundParameters.ContainsKey('AclSddl')
$getItemReaderSeam = ($PSBoundParameters.ContainsKey('GetItemReader') -and ($null -ne $GetItemReader))

if ($itemStateSeam -and @($ItemState).Count -lt 3) {
    $errors.Add((New-PlanError 'ItemStateSeamTooShort' 'The ItemState test seam needs one value per target (stateDir, runtime, runtimeBin).' $null))
}
if ($aclSddlSeam -and @($AclSddl).Count -lt 3) {
    $errors.Add((New-PlanError 'AclSddlSeamTooShort' 'The AclSddl test seam needs one value per target (stateDir, runtime, runtimeBin).' $null))
}

# Simulation marker: bound BEFORE any result is known, so simulated runs -
# error-return injections included - can never pass as real-machine evidence.
# It is present in Data on EVERY exit path, argument errors included.
$seamsUsed = New-Object System.Collections.Generic.List[string]
if ($getItemReaderSeam) { $seamsUsed.Add('GetItemReader') }
if ($itemStateSeam) { $seamsUsed.Add('ItemState') }
if ($aclSddlSeam) { $seamsUsed.Add('AclSddl') }
$simulation = [ordered]@{
    TestSeamsUsed = ($seamsUsed.Count -gt 0)
    Seams         = $seamsUsed.ToArray()
}

if ($errors.Count -gt 0) {
    $result = [ordered]@{
        Success = $false
        Data    = [ordered]@{
            StateDir   = $null
            PolicySddl = $null
            Simulation = $simulation
            Targets    = @()
            Summary    = $null
        }
        Errors  = $errors.ToArray()
    }
    $masked = Hide-GsPlanInObject -Value $result
    Write-GsPlanStdout -Text (ConvertTo-Json -InputObject $masked -Depth 12)
    exit 1
}

# ---------------------------------------------------------------------------
# Metadata reads. The default reader is the only place this tool touches the
# filesystem: per-level Get-Item metadata (no enumeration, no file content).
# Only a clear not-found maps to 'missing'; any other read error is a
# structured failure that blocks the branch.
# ---------------------------------------------------------------------------
function Read-GsPlanItemDefault {
    param([string]$Path)
    try {
        return (Get-Item -LiteralPath $Path -Force -ErrorAction Stop)
    } catch {
        # Only a clear not-found maps to 'missing'. PowerShell reports a
        # missing path as ItemNotFoundException (not part of the System.IO
        # hierarchy), so both the type names and the Win32 not-found
        # HResults are checked along the inner-exception chain.
        $cursor = $_.Exception
        while ($null -ne $cursor) {
            $typeName = $cursor.GetType().FullName
            if (($cursor -is [System.IO.FileNotFoundException]) -or
                ($cursor -is [System.IO.DirectoryNotFoundException]) -or
                ($typeName -eq 'System.Management.Automation.ItemNotFoundException') -or
                ($cursor.HResult -eq -2147024894) -or
                ($cursor.HResult -eq -2147024893)) {
                return $null
            }
            $cursor = $cursor.InnerException
        }
        throw
    }
}

$readFailedSentinel = '__gsAclPlanReadFailed__'
$itemReadCache = @{}

function Read-GsPlanItemCached {
    param([string]$Path)
    if ($itemReadCache.ContainsKey($Path)) {
        if ($itemReadCache[$Path] -ieq $readFailedSentinel) {
            throw (New-Object System.IO.IOException ('A previous metadata read of this path failed.'))
        }
        return $itemReadCache[$Path]
    }
    try {
        if ($getItemReaderSeam) { $item = & $GetItemReader $Path }
        else { $item = Read-GsPlanItemDefault -Path $Path }
    } catch {
        $itemReadCache[$Path] = $readFailedSentinel
        throw
    }
    $itemReadCache[$Path] = $item
    return $item
}

function Get-GsPlanAncestorChain {
    # Every level from the drive root down to the target itself, inclusive.
    param([string]$Path)
    $chain = New-Object System.Collections.Generic.List[string]
    $current = [System.IO.Path]::GetFullPath($Path)
    while ($true) {
        $chain.Insert(0, $current)
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($parent) -or ($parent -eq $current)) { break }
        $current = $parent
    }
    return $chain.ToArray()
}

function Get-GsPlanTargetState {
    # Walks the ancestor chain level by level. A reparse point, a
    # non-directory level or a metadata read failure at ANY level blocks the
    # whole branch before any ACL read happens.
    param([string]$Path)
    $chain = Get-GsPlanAncestorChain -Path $Path
    foreach ($level in $chain) {
        try {
            $item = Read-GsPlanItemCached -Path $level
        } catch {
            return [pscustomobject]@{ Status = 'aclReadFailed'; BlockedByPath = $level }
        }
        if ($null -eq $item) {
            return [pscustomobject]@{ Status = 'missing'; BlockedByPath = $level }
        }
        try {
            $attributes = [System.IO.FileAttributes]$item.Attributes
        } catch {
            return [pscustomobject]@{ Status = 'notEvaluable'; BlockedByPath = $level }
        }
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne [System.IO.FileAttributes]0) {
            return [pscustomobject]@{ Status = 'reparsePoint'; BlockedByPath = $level }
        }
        if (($attributes -band [System.IO.FileAttributes]::Directory) -eq [System.IO.FileAttributes]0) {
            return [pscustomobject]@{ Status = 'notDirectory'; BlockedByPath = $level }
        }
    }
    return [pscustomobject]@{ Status = 'directory'; BlockedByPath = $null }
}

function Get-TargetAcl {
    param([string]$Path, [int]$Index)
    if ($aclSddlSeam) {
        $sddl = [string]@($AclSddl)[$Index]
        if ([string]::IsNullOrEmpty($sddl)) { return $null }  # simulates an unreadable ACL
        return $sddl
    }
    try {
        return (Get-Acl -LiteralPath $Path -ErrorAction Stop)
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Plan.
# ---------------------------------------------------------------------------
$targets = @(
    @{ key = 'stateDir'; sub = ''; blockers = @('StateRootWritesNotConfirmed') },
    @{ key = 'runtime'; sub = 'runtime'; blockers = @('RuntimeStateUserWritesNotConfirmed') },
    @{ key = 'runtimeBin'; sub = 'runtime\bin'; blockers = @('UserSessionLogMigrationNotConfirmed') }
)

$policy = New-GsAclPolicy
$policySddl = $policy.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)

$targetEntries = New-Object System.Collections.Generic.List[object]
$index = 0
foreach ($target in $targets) {
    $path = if ($target.sub -eq '') { $canonicalStateDir } else { Join-Path $canonicalStateDir $target.sub }
    $entry = New-PlanTargetEntry -Key $target.key -Path $path -Blockers $target.blockers

    $state = $null
    if ($itemStateSeam) {
        $seamState = [string]@($ItemState)[$index]
        if ($seamState -ieq 'file') { $seamState = 'notDirectory' }  # legacy seam alias
        $state = [pscustomobject]@{ Status = $seamState; BlockedByPath = $null }
    } else {
        $state = Get-GsPlanTargetState -Path $path
    }

    switch ($state.Status) {
        'missing' {
            $entry.status = 'missing'
            $entry.applyBlockers = @($entry.applyBlockers) + @('TargetDoesNotExist')
        }
        'reparsePoint' {
            $entry.status = 'reparsePoint'
            $entry.applyBlockers = @($entry.applyBlockers) + @('TargetIsAReparsePoint')
            $errors.Add((New-PlanError 'ReparsePointTargetRejected' ('The target branch is blocked by a reparse point observed during the check at ' + $state.BlockedByPath + '; the branch is refused and no ACL is read through it during the check.') $target.key))
        }
        'notDirectory' {
            $entry.status = 'notDirectory'
            $entry.applyBlockers = @($entry.applyBlockers) + @('TargetIsNotADirectory')
            $errors.Add((New-PlanError 'TargetIsNotADirectory' ('The target branch is blocked by a non-directory path at ' + $state.BlockedByPath + '.') $target.key))
        }
        'unreadable' {
            $entry.status = 'aclReadFailed'
            $entry.applyBlockers = @($entry.applyBlockers) + @('AclCouldNotBeRead')
            $errors.Add((New-PlanError 'AclReadFailed' 'Could not read the ACL of the target.' $target.key))
        }
        'aclReadFailed' {
            $entry.status = 'aclReadFailed'
            $entry.applyBlockers = @($entry.applyBlockers) + @('AclCouldNotBeRead')
            $errors.Add((New-PlanError 'AncestorReadFailed' ('The metadata of a directory on the target branch (' + $state.BlockedByPath + ') could not be read; the branch is blocked.') $target.key))
        }
        'notEvaluable' {
            $entry.status = 'notEvaluable'
            $entry.applyBlockers = @($entry.applyBlockers) + @('TargetStateNotReadable')
            $errors.Add((New-PlanError 'TargetStateNotReadable' 'The target state could not be determined.' $target.key))
        }
        'directory' {
            $acl = Get-TargetAcl -Path $path -Index $index
            if ($null -eq $acl) {
                $entry.status = 'aclReadFailed'
                $entry.applyBlockers = @($entry.applyBlockers) + @('AclCouldNotBeRead')
                $errors.Add((New-PlanError 'AclReadFailed' 'Could not read the ACL of the target.' $target.key))
            } else {
                $verdict = $null
                if ($acl -is [string]) {
                    $verdict = Test-GsAclPolicy -Sddl $acl
                } elseif ($acl -is [System.Security.AccessControl.DirectorySecurity]) {
                    $verdict = Test-GsAclPolicy -Security $acl
                } else {
                    $verdict = Test-GsAclPolicy -Sddl ([string]$acl)
                }
                if ($verdict.Compliant) { $entry.status = 'compliant' } else { $entry.status = 'deviates' }
                $entry.compliant = [bool]$verdict.Compliant
                $entry.ownerSid = $verdict.OwnerSid
                $entry.writers = @($verdict.NonAdminWriters)
                $entry.usersRightsHex = $verdict.UsersRightsHex
                $entry.findings = @($verdict.Findings)
            }
        }
        default {
            $entry.status = 'notEvaluable'
            $entry.applyBlockers = @($entry.applyBlockers) + @('TargetStateNotReadable')
            $errors.Add((New-PlanError 'TargetStateNotReadable' 'The target state could not be determined.' $target.key))
        }
    }

    # Nothing is ever apply-ready in this phase: the blockers above are
    # unconditional, so a compliant SDDL construction never turns into a
    # "safe to apply" claim.
    $entry.applyReady = $false
    $targetEntries.Add($entry)
    $index++
}

$summary = [ordered]@{
    targetsEvaluated     = $targetEntries.Count
    compliantTargets     = @($targetEntries | Where-Object { $_.status -eq 'compliant' }).Count
    deviatingTargets     = @($targetEntries | Where-Object { $_.status -eq 'deviates' }).Count
    missingTargets       = @($targetEntries | Where-Object { $_.status -eq 'missing' }).Count
    notEvaluableTargets  = @($targetEntries | Where-Object { @('reparsePoint', 'notDirectory', 'aclReadFailed', 'notEvaluable') -icontains $_.status }).Count
    applyReadyTargets    = 0
    applyActionAvailable = $false
    note                 = 'Read-only pre-check only: the policy module builds and validates the DACL in memory, there is no apply or harden implementation in this phase, and user-session write migration is unconfirmed, so no target is ever reported as ready to apply.'
}

$result = [ordered]@{
    Success = ($errors.Count -eq 0)
    Data    = [ordered]@{
        StateDir   = $canonicalStateDir
        PolicySddl = $policySddl
        Snapshot   = [ordered]@{
            nature                    = 'read-time snapshot'
            topologyStabilityRequired = $true
            atomicIsolation           = $false
            note                      = 'This plan reflects the state observed during a non-atomic read-only check. The directory topology must stay stable while the check runs; a concurrent junction or ACL change between the metadata walk and the ACL read can invalidate this snapshot. This tool is not an access-control sandbox and not an apply authorization.'
        }
        Simulation = $simulation
        Targets    = $targetEntries.ToArray()
        Summary    = $summary
    }
    Errors  = $errors.ToArray()
}

$masked = Hide-GsPlanInObject -Value $result
Write-GsPlanStdout -Text (ConvertTo-Json -InputObject $masked -Depth 12)
if ($masked.Success) { exit 0 } else { exit 1 }
