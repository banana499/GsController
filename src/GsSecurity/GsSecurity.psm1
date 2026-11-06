Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# GsSecurity: read-only ACL policy build and validation for GsController
# state directories.
#
# Scope (security-design.md 4.2 / 4.4 / 4.7):
#   - New-GsAclPolicy builds the target DACL purely in memory (a
#     DirectorySecurity object); it never touches the disk and there is no
#     Set-Acl / SetAccessRule / apply path anywhere in this module.
#   - Test-GsAclPolicy checks a candidate DACL (SDDL string or
#     DirectorySecurity) against the target policy SEMANTICALLY: the raw
#     SDDL text is never compared. All SID comparisons use SID strings only;
#     account names are never resolved, so the module works offline and no
#     usernames can leak.
#   - Any output that could carry a machine-local SID (S-1-5-21-...) is
#     masked to S-1-5-21-*-<RID> before it leaves the module (the same
#     masking rule as the product diagnose tool).
#
# Conservative rules (fail closed):
#   - Every deny ACE is a deviation. Deny ACEs are never reasoned about as
#     "canceling" an allow so that the result would become compliant.
#   - Any allow ACE with write bits for a non-administrative SID is a
#     violation, even if other ACEs look restrictive.
#   - Extra allow ACEs (read-only ones included) for principals outside the
#     target policy are deviations; CREATOR OWNER (S-1-3-0) is NOT exempt
#     even when the current owner is administrative.
#   - Required grants (SYSTEM/Administrators FullControl, Users
#     ReadAndExecute+Synchronize) must be a STANDARD allow ACE: one that
#     applies to the object itself (not inherit-only) and propagates fully
#     (ObjectInherit + ContainerInherit, no NoPropagateInherit). Inherit-only,
#     no-propagate or partial-inheritance ACEs on target SIDs are reported as
#     NonStandardAceShape deviations; the module refuses such forms instead
#     of modeling them with a full access-check emulation.
#
# This phase has no apply/harden capability by design. Real Set-Acl usage
# is a future, separately approved change (security-design.md 4.4).
# ---------------------------------------------------------------------------

$script:AdminOwnerSids = @('S-1-5-18', 'S-1-5-32-544')
$script:UsersSid = 'S-1-5-32-545'

# Write-right bits used by the product diagnose tool (Test-GsSddlWritableByNonAdmin):
# 0x2 write data, 0x4 append data, 0x10 write EA, 0x40 delete child,
# 0x100 write attributes, 0x10000 delete, 0x40000 write DACL,
# 0x80000 write owner, 0x10000000 generic all, 0x40000000 generic write.
$script:WriteBits = @(
    [int64]0x2, [int64]0x4, [int64]0x10, [int64]0x40, [int64]0x100,
    [int64]0x10000, [int64]0x40000, [int64]0x80000,
    [int64]0x10000000, [int64]0x40000000)
$script:WriteMaskAll = [int64]0
foreach ($bit in $script:WriteBits) { $script:WriteMaskAll = $script:WriteMaskAll -bor $bit }

# Full control for directories (FILE_ALL_ACCESSS-equivalent raw mask) and
# the generic-all bit, which maps to full control at access-check time.
$script:FullControlMask = [int64]0x1F01FF
$script:GenericAllMask = [int64]0x10000000
# ReadAndExecute (0x200a9) does NOT include Synchronize; the target Users
# mask is 0x1200a9 = ReadAndExecute + Synchronize (security-design.md 4.2).
$script:UsersTargetMask = [int64]0x1200A9

function Hide-GsSecuritySidText {
    # Masks machine-local account SIDs (S-1-5-21-a-b-c-RID) to
    # S-1-5-21-*-RID so nothing machine-specific leaves the module.
    # Well-known SIDs do not match the pattern and pass through.
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [System.Text.RegularExpressions.Regex]::Replace($Text, 'S-1-5-21-\d+-\d+-\d+-(\d+)', 'S-1-5-21-*-$1')
}

function Get-GsSecurityNormalizedMask {
    # FileSystemRights is an Int32-based enum, so masks with the high bit
    # set (e.g. generic read, 0x80000000) come back negative. Normalizes to
    # the unsigned 32-bit value as Int64 so masks compare correctly.
    param($Rule)
    $raw = [int]$Rule.FileSystemRights
    if ($raw -lt 0) { return ([int64]$raw + 4294967296) }
    return [int64]$raw
}

function New-GsSecurityFinding {
    param([string]$Code, [string]$Severity, [string]$Message)
    [pscustomobject]@{ Code = $Code; Severity = $Severity; Message = $Message }
}

function New-GsSecurityVerdict {
    # Single constructor for the verdict shape so the parse-failure path and
    # the analysis path cannot drift apart.
    param(
        [bool]$Compliant,
        [bool]$Protected,
        [bool]$HasInheritedAces,
        [AllowNull()][string]$OwnerSid,
        [bool]$OwnerCompliant,
        [int]$DenyAceCount,
        [AllowNull()][string]$UsersRightsHex,
        [bool]$AdminGrantsComplete,
        [bool]$UsersRightsComplete,
        [object[]]$NonAdminWriters,
        [object[]]$Findings
    )
    [pscustomobject]@{
        Compliant            = $Compliant
        Protected            = $Protected
        HasInheritedAces     = $HasInheritedAces
        OwnerSid             = $OwnerSid
        OwnerCompliant       = $OwnerCompliant
        DenyAceCount         = $DenyAceCount
        UsersRightsHex       = $UsersRightsHex
        AdminGrantsComplete  = $AdminGrantsComplete
        UsersRightsComplete  = $UsersRightsComplete
        NonAdminWriters      = @($NonAdminWriters)
        Findings             = @($Findings)
    }
}

function New-GsAclPolicy {
    <#
    .SYNOPSIS
        Builds the target directory ACL policy purely in memory.

    .DESCRIPTION
        Returns a DirectorySecurity that mirrors the target state from
        artifacts/security/security-design.md section 4.2:
          - DACL protected, no inherited ACEs (SetAccessRuleProtection(true, false));
          - SYSTEM (S-1-5-18) and BUILTIN\Administrators (S-1-5-32-544)
            FullControl with ObjectInherit + ContainerInherit;
          - BUILTIN\Users (S-1-5-32-545) ReadAndExecute + Synchronize
            (raw mask 0x1200a9) with ObjectInherit + ContainerInherit;
          - owner BUILTIN\Administrators by default (SYSTEM optional);
            the owner is never left to a non-administrative principal.
        The group is set to SYSTEM so the canonical SDDL form matches the
        design (O:...G:SYD:P...).

        The function performs no disk access and does not apply the policy
        anywhere; callers use GetSecurityDescriptorSddlForm on the result
        if they need the SDDL text. Applying the policy (Set-Acl) is out of
        scope for this module.

    .PARAMETER OwnerSid
        'S-1-5-32-544' (BUILTIN\Administrators, default) or 'S-1-5-18'
        (SYSTEM). Any other value is rejected.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('S-1-5-32-544', 'S-1-5-18')]
        [string]$OwnerSid = 'S-1-5-32-544'
    )

    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetOwner([System.Security.Principal.SecurityIdentifier]::new($OwnerSid))
    $security.SetGroup([System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
    $security.SetAccessRuleProtection($true, $false)

    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($adminSid in $script:AdminOwnerSids) {
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                ([System.Security.Principal.SecurityIdentifier]::new($adminSid)),
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance, $propagation, $allow))
    }
    $usersRights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [System.Security.AccessControl.FileSystemRights]::Synchronize
    $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            ([System.Security.Principal.SecurityIdentifier]::new($script:UsersSid)),
            $usersRights, $inheritance, $propagation, $allow))
    return $security
}

function Test-GsAclPolicy {
    <#
    .SYNOPSIS
        Semantically validates a DACL against the target ACL policy.

    .DESCRIPTION
        Pure, in-memory evaluation of one security descriptor (an SDDL
        string or a DirectorySecurity). Never touches the disk and never
        resolves SIDs to account names. The verdict is semantic: ACE order,
        SDDL spelling (P vs PAI), and ACE grouping do not matter; only the
        effective rule set does.

        Compliance requires ALL of:
          - the DACL is protected and contains no inherited ACEs;
          - the owner is SYSTEM or BUILTIN\Administrators (a missing owner
            is a violation);
          - no allow ACE grants any write right to a non-administrative SID;
          - no deny ACE exists at all (conservative: deny is never reasoned
            into compliance);
          - SYSTEM and BUILTIN\Administrators have FullControl (raw 0x1f01ff
            or GenericAll 0x10000000) granted by a STANDARD allow ACE - one
            that applies to the object itself (not inherit-only) and has
            full ObjectInherit + ContainerInherit without NoPropagateInherit;
          - BUILTIN\Users allow rights, from standard ACEs, OR-merge to
            exactly 0x1200a9 (ReadAndExecute + Synchronize);
          - no allow ACE exists for any other principal - CREATOR OWNER
            (S-1-3-0) included, regardless of the current owner. Allow ACEs
            on the target SIDs that use inherit-only, no-propagate or
            partial-inheritance flags are conservative deviations
            (NonStandardAceShape) instead of being modeled by an access
            checker.

        A descriptor whose SDDL cannot be parsed yields a non-compliant
        verdict with a single SddlParseFailed finding instead of throwing,
        so callers can treat "not evaluable" as "not compliant".

        All machine-local SIDs are masked (S-1-5-21-*-RID) in the returned
        verdict, including inside finding messages.

    .PARAMETER Sddl
        The SDDL string to evaluate. Mutually exclusive with -Security.

    .PARAMETER Security
        The DirectorySecurity to evaluate. Mutually exclusive with -Sddl.

    .OUTPUTS
        PSCustomObject with:
          Compliant, Protected, HasInheritedAces, OwnerSid (masked or null),
          OwnerCompliant, DenyAceCount, UsersRightsHex (string or null),
          AdminGrantsComplete, UsersRightsComplete,
          NonAdminWriters (array of { sid, rightsHex }, SIDs masked),
          Findings (array of { code, severity, message }; English messages).
    #>
    [CmdletBinding()]
    param(
        [string]$Sddl,
        [System.Security.AccessControl.DirectorySecurity]$Security
    )

    $hasSddl = (-not [string]::IsNullOrEmpty($Sddl))
    $hasSecurity = $PSBoundParameters.ContainsKey('Security')
    if ($hasSddl -eq $hasSecurity) {
        throw 'Specify exactly one of -Sddl or -Security.'
    }

    $findings = New-Object System.Collections.Generic.List[object]

    # Local name is $descriptor (NOT $security): a local would collide with
    # the case-insensitive $Security parameter and wipe it.
    $descriptor = $null
    if ($hasSddl) {
        $descriptor = New-Object System.Security.AccessControl.DirectorySecurity
        try {
            $descriptor.SetSecurityDescriptorSddlForm($Sddl)
        } catch {
            # Fixed message only; never surface the raw exception (it can
            # echo parts of the input).
            $findings.Add((New-GsSecurityFinding 'SddlParseFailed' 'high' 'The SDDL string could not be parsed as a directory security descriptor; the descriptor is treated as non-compliant.'))
            return (New-GsSecurityVerdict -Compliant:$false -Protected:$false -HasInheritedAces:$false `
                    -OwnerSid $null -OwnerCompliant:$false -DenyAceCount 0 -UsersRightsHex $null `
                    -AdminGrantsComplete:$false -UsersRightsComplete:$false `
                    -NonAdminWriters @() -Findings $findings.ToArray())
        }
    } else {
        $descriptor = $Security
    }

    $protected = [bool]$descriptor.AreAccessRulesProtected
    $rulesAll = @($descriptor.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    $rulesExplicit = @($descriptor.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
    $hasInherited = ($rulesAll.Count -ne $rulesExplicit.Count)
    if (-not $protected) {
        $findings.Add((New-GsSecurityFinding 'InheritanceNotProtected' 'high' 'The DACL is not protected, so inherited ACEs from parent directories flow into the directory.'))
    }
    if ($hasInherited) {
        $findings.Add((New-GsSecurityFinding 'InheritedAcesPresent' 'high' 'The DACL contains inherited ACEs; the target policy allows explicit ACEs only.'))
    }

    $ownerSid = $null
    try {
        $owner = $descriptor.GetOwner([System.Security.Principal.SecurityIdentifier])
        if ($null -ne $owner) { $ownerSid = [string]$owner }
    } catch { $ownerSid = $null }

    $ownerCompliant = $false
    if ([string]::IsNullOrEmpty($ownerSid)) {
        $findings.Add((New-GsSecurityFinding 'OwnerMissing' 'high' 'The security descriptor has no owner; the target policy requires the owner to be SYSTEM or BUILTIN\Administrators.'))
    } elseif ($script:AdminOwnerSids -icontains $ownerSid) {
        $ownerCompliant = $true
    } else {
        $maskedOwner = Hide-GsSecuritySidText $ownerSid
        $findings.Add((New-GsSecurityFinding 'OwnerOutsideAllowlist' 'high' ('The owner SID ' + $maskedOwner + ' is outside the administrative owner allowlist (SYSTEM or Administrators) and can rewrite the DACL.')))
    }

    # Per-ACE shape check plus per-SID mask merge. Deny ACEs are counted,
    # never merged. A "standard" allow ACE applies to the object itself
    # (not inherit-only) and propagates fully (OI + CI, no no-propagate);
    # only standard ACEs on the target SIDs can satisfy the grants. ACEs on
    # non-target SIDs - CREATOR OWNER included - are deviations regardless
    # of the current owner.
    $denyCount = 0
    $targetSids = @('S-1-5-18', 'S-1-5-32-544', $script:UsersSid)
    $standardMasks = @{}
    $allMasks = @{}
    foreach ($rule in $rulesAll) {
        if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
            $denyCount++
            continue
        }
        $sid = [string]$rule.IdentityReference
        $mask = Get-GsSecurityNormalizedMask $rule
        if ($allMasks.ContainsKey($sid)) { $allMasks[$sid] = $allMasks[$sid] -bor $mask }
        else { $allMasks[$sid] = $mask }
        if (-not ($targetSids -icontains $sid)) { continue }
        $inheritOnly = (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0)
        $noPropagate = (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::NoPropagateInherit) -ne 0)
        $objectInherit = (($rule.InheritanceFlags -band [System.Security.AccessControl.InheritanceFlags]::ObjectInherit) -ne 0)
        $containerInherit = (($rule.InheritanceFlags -band [System.Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0)
        if ($inheritOnly -or $noPropagate -or (-not $objectInherit) -or (-not $containerInherit)) {
            $findings.Add((New-GsSecurityFinding 'NonStandardAceShape' 'medium' ('An allow ACE for the target SID ' + $sid + ' has a non-standard shape (inherit-only, no-propagate or partial OI/CI flags); the target policy requires plain OI+CI ACEs that apply to the object itself, and such ACEs are conservatively refused.')))
            continue
        }
        if ($standardMasks.ContainsKey($sid)) { $standardMasks[$sid] = $standardMasks[$sid] -bor $mask }
        else { $standardMasks[$sid] = $mask }
    }
    if ($denyCount -gt 0) {
        $findings.Add((New-GsSecurityFinding 'DenyAcePresent' 'high' ('The DACL contains ' + $denyCount + ' deny ACE(s); deny ACEs are not part of the target policy and are evaluated conservatively as a deviation.')))
    }

    $writers = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $allMasks.GetEnumerator()) {
        $sid = $entry.Key
        if ($targetSids -icontains $sid) { continue }
        $mask = [int64]$entry.Value
        $writePart = $mask -band $script:WriteMaskAll
        $maskedSid = Hide-GsSecuritySidText $sid
        if ($writePart -ne [int64]0) {
            $writers.Add([pscustomobject]@{ sid = $maskedSid; rightsHex = ('0x{0:x}' -f $writePart) })
            $findings.Add((New-GsSecurityFinding 'NonAdminWriteAce' 'high' ('An allow ACE grants write rights (0x{0:x}) to the non-administrative SID {1}; the target policy grants no rights to any principal other than SYSTEM, Administrators and read+execute to Users.' -f $writePart, $maskedSid)))
        } else {
            $findings.Add((New-GsSecurityFinding 'UnexpectedAllowAce' 'medium' ('An allow ACE grants rights (0x{0:x}) to the SID {1}, which is not part of the target policy; extra read-only ACEs are also deviations.' -f $mask, $maskedSid)))
        }
    }

    $systemMask = [int64]0
    if ($standardMasks.ContainsKey('S-1-5-18')) { $systemMask = [int64]$standardMasks['S-1-5-18'] }
    $adminMask = [int64]0
    if ($standardMasks.ContainsKey('S-1-5-32-544')) { $adminMask = [int64]$standardMasks['S-1-5-32-544'] }
    $usersMask = [int64]0
    if ($standardMasks.ContainsKey($script:UsersSid)) { $usersMask = [int64]$standardMasks[$script:UsersSid] }

    $systemOk = ((($systemMask -band $script:FullControlMask) -eq $script:FullControlMask) -or
        (($systemMask -band $script:GenericAllMask) -eq $script:GenericAllMask))
    $adminOk = ((($adminMask -band $script:FullControlMask) -eq $script:FullControlMask) -or
        (($adminMask -band $script:GenericAllMask) -eq $script:GenericAllMask))
    if (-not $systemOk) {
        $findings.Add((New-GsSecurityFinding 'RequiredGrantMissing' 'medium' 'SYSTEM (S-1-5-18) does not have an explicit allow ACE with FullControl (or GenericAll) in the standard OI+CI form that applies to the object itself.'))
    }
    if (-not $adminOk) {
        $findings.Add((New-GsSecurityFinding 'RequiredGrantMissing' 'medium' 'BUILTIN\Administrators (S-1-5-32-544) does not have an explicit allow ACE with FullControl (or GenericAll) in the standard OI+CI form that applies to the object itself.'))
    }

    $usersAnyMask = [int64]0
    if ($allMasks.ContainsKey($script:UsersSid)) { $usersAnyMask = [int64]$allMasks[$script:UsersSid] }
    $usersWritePart = $usersAnyMask -band $script:WriteMaskAll
    if ($usersWritePart -ne [int64]0) {
        $findings.Add((New-GsSecurityFinding 'NonAdminWriteAce' 'high' ('An allow ACE grants write rights (0x{0:x}) to BUILTIN\Users (S-1-5-32-545); the target policy grants Users read and execute only.' -f $usersWritePart)))
        $writers.Add([pscustomobject]@{ sid = $script:UsersSid; rightsHex = ('0x{0:x}' -f $usersWritePart) })
    }

    $usersOk = ($usersMask -eq $script:UsersTargetMask)
    $usersHex = $null
    if ($usersMask -gt [int64]0) { $usersHex = ('0x{0:x}' -f $usersMask) }
    if ($usersMask -eq [int64]0) {
        $findings.Add((New-GsSecurityFinding 'UsersRightsMissing' 'medium' 'BUILTIN\Users (S-1-5-32-545) has no standard allow ACE; the target policy requires ReadAndExecute + Synchronize (0x1200a9) as a plain OI+CI ACE.'))
    } elseif (-not $usersOk) {
        $findings.Add((New-GsSecurityFinding 'UsersRightsUnexpected' 'medium' ('The BUILTIN\Users allow rights (OR-merged 0x{0:x}) do not match the target mask 0x1200a9 (ReadAndExecute + Synchronize) exactly; generic-right forms are not accepted.' -f $usersMask)))
    }

    return (New-GsSecurityVerdict `
            -Compliant:($findings.Count -eq 0) `
            -Protected:$protected -HasInheritedAces:$hasInherited `
            -OwnerSid (Hide-GsSecuritySidText $ownerSid) -OwnerCompliant:$ownerCompliant `
            -DenyAceCount $denyCount -UsersRightsHex $usersHex `
            -AdminGrantsComplete:($systemOk -and $adminOk) -UsersRightsComplete:$usersOk `
            -NonAdminWriters $writers.ToArray() -Findings $findings.ToArray())
}

Export-ModuleMember -Function @('New-GsAclPolicy', 'Test-GsAclPolicy')
