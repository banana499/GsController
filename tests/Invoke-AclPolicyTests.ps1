#Requires -Version 5.1
<#
.SYNOPSIS
    Tests for the read-only ACL policy module (src/GsSecurity) and the
    read-only pre-check tool (tools/Get-GsAclPlan.ps1). Everything ACL
    related is in memory: SDDL strings and injected reader seams. The only
    real filesystem fixtures are plain directories under %TEMP% (created
    with New-Item); no Set-Acl, no ACL change, no admin, no real product
    state, no runtime bundle. Exits 0 only when every test passes and at
    least one ran; exits 1 otherwise.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleManifest = Join-Path $repoRoot 'src\GsSecurity\GsSecurity.psd1'
$toolPath = Join-Path $repoRoot 'tools\Get-GsAclPlan.ps1'

Import-Module $moduleManifest -Force -ErrorAction Stop

$script:Passed = 0
$script:Failed = 0

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

function Assert-Throws {
    param([scriptblock]$Body, [string]$MessagePattern, [string]$Message)
    $caught = $null
    try { & $Body } catch { $caught = $_ }
    if ($null -eq $caught) { throw "Assertion failed: expected an exception: $Message" }
    if (-not [string]::IsNullOrEmpty($MessagePattern) -and ($caught.Exception.Message -notmatch $MessagePattern)) {
        throw "Assertion failed: $Message (exception message '$($caught.Exception.Message)' did not match '$MessagePattern')"
    }
}

function Assert-HasFinding {
    param($Verdict, [string]$Code, [string]$Message)
    $codes = @($Verdict.Findings | ForEach-Object { $_.Code })
    if (-not ($codes -icontains $Code)) {
        throw "Assertion failed: expected finding code $Code :: $Message (got: $($codes -join ','))"
    }
}

# Runs the plan tool in a child powershell.exe with a hard deadline so a
# regression fails the suite instead of hanging it. Uses -Command (not
# -File) because the AclSddl/ItemState seams are string arrays and -File
# does not split comma-joined tokens into arrays.
function Invoke-PlanTool {
    param([string]$ToolArguments)
    $exe = Join-Path $PSHOME 'powershell.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& ''' + $toolPath + ''' ' + $ToolArguments + '"')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while ((-not $process.HasExited) -and ([DateTime]::UtcNow -lt $deadline)) { Start-Sleep -Milliseconds 100 }
    if (-not $process.HasExited) {
        try { $process.Kill() } catch { }
        throw 'Get-GsAclPlan.ps1 exceeded the 90 second deadline'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function ConvertFrom-PlanJson {
    param([string]$StdOut)
    if ([string]::IsNullOrWhiteSpace($StdOut)) { throw 'The plan tool produced no stdout JSON.' }
    return (ConvertFrom-Json $StdOut)
}

# ---------------------------------------------------------------------------
# Shared SDDL material
# ---------------------------------------------------------------------------
# Target SDDL from artifacts/security/security-design.md section 4.2.
$designLiteralSddl = 'O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
# ACE order swapped: textually different from the design literal, but the
# same policy. Semantic comparison must accept it.
$reorderedSddl = 'O:BAG:SYD:P(A;OICI;0x1200a9;;;BU)(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)'
$canonicalPolicy = New-GsAclPolicy
$canonicalPolicySddl = $canonicalPolicy.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)

$tempRoot = [System.IO.Path]::GetTempPath()
$workRoot = Join-Path $tempRoot ('GsAclPolicy_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot | Out-Null

try {

    # -----------------------------------------------------------------------
    # Module: exports
    # -----------------------------------------------------------------------
    Invoke-Test 'module exports exactly New-GsAclPolicy and Test-GsAclPolicy' {
        $exported = @(Get-Command -Module GsSecurity | ForEach-Object { $_.Name } | Sort-Object)
        Assert-Equal 2 $exported.Count 'export count'
        Assert-Equal 'New-GsAclPolicy' $exported[0] 'first export'
        Assert-Equal 'Test-GsAclPolicy' $exported[1] 'second export'
    }

    # -----------------------------------------------------------------------
    # Module: policy construction (in memory only)
    # -----------------------------------------------------------------------
    Invoke-Test 'policy builds a protected DACL with the exact target rules' {
        $policy = New-GsAclPolicy
        Assert-True $policy.AreAccessRulesProtected 'DACL must be protected'
        $rules = @($policy.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        Assert-Equal 3 $rules.Count 'rule count'
        $oiCi = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $bySid = @{}
        foreach ($rule in $rules) {
            $bySid[[string]$rule.IdentityReference] = $rule
            Assert-Equal 'Allow' ([string]$rule.AccessControlType) 'rule type'
            Assert-True ($rule.InheritanceFlags -eq $oiCi) 'rules must be OI+CI'
            Assert-True ($rule.PropagationFlags -eq [System.Security.AccessControl.PropagationFlags]::None) 'rules must not be inherit-only'
            Assert-True (-not $rule.IsInherited) 'rules must be explicit'
        }
        Assert-Equal '0x1f01ff' ('0x{0:x}' -f [int64]$bySid['S-1-5-18'].FileSystemRights) 'SYSTEM mask'
        Assert-Equal '0x1f01ff' ('0x{0:x}' -f [int64]$bySid['S-1-5-32-544'].FileSystemRights) 'Administrators mask'
        Assert-Equal '0x1200a9' ('0x{0:x}' -f [int64]$bySid['S-1-5-32-545'].FileSystemRights) 'Users mask'
        Assert-Equal 'S-1-5-32-544' ([string]$policy.GetOwner([System.Security.Principal.SecurityIdentifier])) 'default owner'
        Assert-Equal 'S-1-5-18' ([string]$policy.GetGroup([System.Security.Principal.SecurityIdentifier])) 'group'
    }

    Invoke-Test 'policy supports SYSTEM as owner' {
        $policy = New-GsAclPolicy -OwnerSid 'S-1-5-18'
        Assert-Equal 'S-1-5-18' ([string]$policy.GetOwner([System.Security.Principal.SecurityIdentifier])) 'owner'
        $verdict = Test-GsAclPolicy -Security $policy
        Assert-True $verdict.Compliant 'SYSTEM-owned policy must be compliant'
        Assert-True $verdict.OwnerCompliant 'owner compliant flag'
    }

    Invoke-Test 'policy rejects owner SIDs outside the allowlist' {
        Assert-Throws { New-GsAclPolicy -OwnerSid 'S-1-5-11' } 'OwnerSid' 'ValidateSet must reject non-admin owners'
    }

    # -----------------------------------------------------------------------
    # Module: semantic compliance
    # -----------------------------------------------------------------------
    Invoke-Test 'canonical and design-literal SDDL are both compliant' {
        foreach ($sddl in @($canonicalPolicySddl, $designLiteralSddl)) {
            $verdict = Test-GsAclPolicy -Sddl $sddl
            if (-not $verdict.Compliant) {
                throw ("Assertion failed: SDDL must be compliant: " + $sddl + " findings: " + (@($verdict.Findings | ForEach-Object { $_.Code }) -join ','))
            }
            Assert-True $verdict.Protected 'protected'
            Assert-True (-not $verdict.HasInheritedAces) 'no inherited ACEs'
            Assert-True $verdict.OwnerCompliant 'owner compliant'
            Assert-True $verdict.AdminGrantsComplete 'admin grants'
            Assert-True $verdict.UsersRightsComplete 'users rights'
            Assert-Equal '0x1200a9' $verdict.UsersRightsHex 'users rights hex'
            Assert-Equal 0 $verdict.DenyAceCount 'deny count'
        }
    }

    Invoke-Test 'reordered ACEs are compliant (semantic, not textual, comparison)' {
        $verdict = Test-GsAclPolicy -Sddl $reorderedSddl
        Assert-True $verdict.Compliant 'reordered but equivalent SDDL must be compliant'
    }

    Invoke-Test 'unprotected DACL (loose inheritance) is non-compliant' {
        $unprotectedSddl = 'O:BAG:SYD:(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
        $verdict = Test-GsAclPolicy -Sddl $unprotectedSddl
        Assert-True (-not $verdict.Compliant) 'unprotected DACL must fail'
        Assert-True (-not $verdict.Protected) 'protected flag must be false'
        Assert-HasFinding $verdict 'InheritanceNotProtected' 'loose inheritance'
    }

    Invoke-Test 'non-admin owner is non-compliant' {
        $sddl = 'O:S-1-5-11G:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
        $verdict = Test-GsAclPolicy -Sddl $sddl
        Assert-True (-not $verdict.Compliant) 'non-admin owner must fail'
        Assert-True (-not $verdict.OwnerCompliant) 'owner compliant flag'
        Assert-HasFinding $verdict 'OwnerOutsideAllowlist' 'non-admin owner'
    }

    Invoke-Test 'missing owner is non-compliant' {
        $sddl = 'G:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
        $verdict = Test-GsAclPolicy -Sddl $sddl
        Assert-True (-not $verdict.Compliant) 'missing owner must fail'
        Assert-HasFinding $verdict 'OwnerMissing' 'missing owner'
    }

    Invoke-Test 'machine-local owner SID is masked in the verdict' {
        $sddl = 'O:S-1-5-21-1004336348-3244382588-2953262690-1001G:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
        $verdict = Test-GsAclPolicy -Sddl $sddl
        Assert-True (-not $verdict.Compliant) 'machine account owner must fail the owner check'
        Assert-Equal 'S-1-5-21-*-1001' $verdict.OwnerSid 'masked owner SID'
        $asJson = ConvertTo-Json $verdict -Depth 5
        Assert-True ($asJson -notmatch 'S-1-5-21-\d+-\d+-\d+-\d+') 'no raw machine SID may appear in the verdict'
    }

    Invoke-Test 'unknown SID with write rights is non-compliant' {
        $sddl = $designLiteralSddl + '(A;OICI;0x1301bf;;;AU)'
        $verdict = Test-GsAclPolicy -Sddl $sddl
        Assert-True (-not $verdict.Compliant) 'extra write ACE must fail'
        Assert-HasFinding $verdict 'NonAdminWriteAce' 'authenticated users write'
        Assert-Equal 1 @($verdict.NonAdminWriters).Count 'writer count'
        Assert-Equal 'S-1-5-11' $verdict.NonAdminWriters[0].sid 'writer sid'
        # The raw Modify mask 0x1301bf is normalized by the .NET SDDL parser
        # for directory ACEs; the write-bit subset that survives is 0x10116.
        Assert-Equal '0x10116' $verdict.NonAdminWriters[0].rightsHex 'writer rights'
    }

    Invoke-Test 'generic write bit counts as a write right' {
        $sddl = $designLiteralSddl + '(A;OICI;0x40000000;;;AU)'
        $verdict = Test-GsAclPolicy -Sddl $sddl
        Assert-True (-not $verdict.Compliant) 'generic write must fail'
        Assert-HasFinding $verdict 'NonAdminWriteAce' 'generic write'
        Assert-Equal '0x40000000' $verdict.NonAdminWriters[0].rightsHex 'writer rights'
    }

    Invoke-Test 'deny ACEs are conservative violations (any principal)' {
        $denyUsers = $designLiteralSddl + '(D;OICI;FR;;;BU)'
        $verdict = Test-GsAclPolicy -Sddl $denyUsers
        Assert-True (-not $verdict.Compliant) 'deny on Users must fail'
        Assert-HasFinding $verdict 'DenyAcePresent' 'deny on Users'
        Assert-Equal 1 $verdict.DenyAceCount 'deny count'

        # Even a deny on an administrative principal is never reasoned into
        # compliance; conservative means: any deny is a deviation.
        $denySystem = $designLiteralSddl + '(D;OICI;FA;;;S-1-5-18)'
        $verdict2 = Test-GsAclPolicy -Sddl $denySystem
        Assert-True (-not $verdict2.Compliant) 'deny on SYSTEM must fail'
        Assert-HasFinding $verdict2 'DenyAcePresent' 'deny on SYSTEM'
    }

    Invoke-Test 'extra read-only allow ACE is a policy deviation' {
        $sddl = $designLiteralSddl + '(A;OICI;FR;;;AU)'
        $verdict = Test-GsAclPolicy -Sddl $sddl
        Assert-True (-not $verdict.Compliant) 'extra read-only ACE must fail the strict target'
        Assert-HasFinding $verdict 'UnexpectedAllowAce' 'extra read-only'
        Assert-Equal 0 @($verdict.NonAdminWriters).Count 'not a writer'
    }

    Invoke-Test 'ACE without OI/CI on a target SID is a non-standard deviation' {
        # Regression (review): a Users grant without inheritance flags used
        # to be accepted; the target form requires plain OI+CI.
        $sddl = 'O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1200a9;;;BU)'
        $verdict = Test-GsAclPolicy -Sddl $sddl
        Assert-True (-not $verdict.Compliant) 'missing OI/CI must fail'
        Assert-HasFinding $verdict 'NonStandardAceShape' 'no OI/CI'
        Assert-HasFinding $verdict 'UsersRightsMissing' 'no standard Users grant'
        Assert-True (-not $verdict.UsersRightsComplete) 'users rights flag'
    }

    Invoke-Test 'inherit-only and no-propagate grants do not satisfy admin requirements' {
        # Regression (review): an inherit-only SYSTEM ACE used to count as a
        # valid FullControl grant although it grants nothing on the object.
        $inheritOnly = 'O:BAG:SYD:P(A;OICIIO;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
        $verdict = Test-GsAclPolicy -Sddl $inheritOnly
        Assert-True (-not $verdict.Compliant) 'inherit-only SYSTEM grant must fail'
        Assert-True (-not $verdict.AdminGrantsComplete) 'admin grants flag'
        Assert-HasFinding $verdict 'RequiredGrantMissing' 'inherit-only'
        Assert-HasFinding $verdict 'NonStandardAceShape' 'inherit-only shape'

        $noPropagate = 'O:BAG:SYD:P(A;OICINP;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
        $verdict2 = Test-GsAclPolicy -Sddl $noPropagate
        Assert-True (-not $verdict2.Compliant) 'no-propagate SYSTEM grant must fail'
        Assert-True (-not $verdict2.AdminGrantsComplete) 'admin grants flag'
        Assert-HasFinding $verdict2 'NonStandardAceShape' 'no-propagate shape'
    }

    Invoke-Test 'creator owner ACEs are deviations, not ignored' {
        # Regression (review): CREATOR OWNER used to be ignored whenever the
        # owner happened to be administrative; the target policy grants
        # nothing to any other principal.
        $writeCreator = $designLiteralSddl + '(A;OICI;FA;;;S-1-3-0)'
        $verdict = Test-GsAclPolicy -Sddl $writeCreator
        Assert-True (-not $verdict.Compliant) 'creator owner full control must fail'
        Assert-HasFinding $verdict 'NonAdminWriteAce' 'creator owner write'
        Assert-Equal 'S-1-3-0' $verdict.NonAdminWriters[0].sid 'creator owner sid'

        $readOnlyCreator = $designLiteralSddl + '(A;OICI;FR;;;S-1-3-0)'
        $verdict2 = Test-GsAclPolicy -Sddl $readOnlyCreator
        Assert-True (-not $verdict2.Compliant) 'creator owner read ACE must fail'
        Assert-HasFinding $verdict2 'UnexpectedAllowAce' 'creator owner read'
    }

    Invoke-Test 'missing grants are reported' {
        $sddl = 'O:BAG:SYD:P(A;OICI;FA;;;SY)'
        $verdict = Test-GsAclPolicy -Sddl $sddl
        Assert-True (-not $verdict.Compliant) 'incomplete grants must fail'
        Assert-True (-not $verdict.AdminGrantsComplete) 'admin grants flag'
        Assert-HasFinding $verdict 'RequiredGrantMissing' 'missing Administrators grant'
        Assert-HasFinding $verdict 'UsersRightsMissing' 'missing Users grant'
    }

    Invoke-Test 'Users mask must match 0x1200a9 exactly' {
        # Read without ExecuteFile (0x120089) is not the target mask.
        $shortMask = 'O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x120089;;;BU)'
        $verdict = Test-GsAclPolicy -Sddl $shortMask
        Assert-True (-not $verdict.Compliant) 'wrong Users mask must fail'
        Assert-HasFinding $verdict 'UsersRightsUnexpected' 'short Users mask'
        Assert-True (-not $verdict.UsersRightsComplete) 'users rights flag'

        # FullControl for Users carries write bits: a high-severity finding.
        $fullUsers = 'O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;BU)'
        $verdict2 = Test-GsAclPolicy -Sddl $fullUsers
        Assert-True (-not $verdict2.Compliant) 'Users FullControl must fail'
        Assert-HasFinding $verdict2 'NonAdminWriteAce' 'Users write'
    }

    Invoke-Test 'invalid SDDL yields SddlParseFailed instead of throwing' {
        $verdict = Test-GsAclPolicy -Sddl 'O:BAG:SYD:P(GARBAGE'
        Assert-True (-not $verdict.Compliant) 'unparseable SDDL must be non-compliant'
        Assert-HasFinding $verdict 'SddlParseFailed' 'parse failure'
        Assert-True (-not $verdict.OwnerCompliant) 'no owner can be trusted'
    }

    Invoke-Test 'exactly one of -Sddl or -Security is required' {
        Assert-Throws { Test-GsAclPolicy } 'exactly one' 'no arguments'
        Assert-Throws { Test-GsAclPolicy -Sddl $designLiteralSddl -Security $canonicalPolicy } 'exactly one' 'both arguments'
    }

    # -----------------------------------------------------------------------
    # Tool: read-only pre-check (child process, %TEMP% fixtures)
    # -----------------------------------------------------------------------
    Invoke-Test 'missing StateDir reports missing targets and never apply-ready' {
        $target = Join-Path $workRoot 'not-created'
        $result = Invoke-PlanTool ('-StateDir ''' + $target + '''')
        Assert-Equal 0 $result.ExitCode 'missing targets are a clean plan, not an error'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-True $plan.Success 'success flag'
        Assert-Equal 3 @($plan.Data.Targets).Count 'target count'
        foreach ($entry in @($plan.Data.Targets)) {
            Assert-Equal 'missing' $entry.status ('status for ' + $entry.target)
            Assert-True (-not $entry.applyReady) ('applyReady must be false for ' + $entry.target)
        }
        Assert-True (@($plan.Data.Targets[0].applyBlockers) -icontains 'StateRootWritesNotConfirmed') 'stateDir blocker'
        Assert-True (@($plan.Data.Targets[1].applyBlockers) -icontains 'RuntimeStateUserWritesNotConfirmed') 'runtime blocker'
        Assert-True (@($plan.Data.Targets[2].applyBlockers) -icontains 'UserSessionLogMigrationNotConfirmed') 'runtimeBin blocker'
        Assert-Equal 0 $plan.Data.Summary.applyReadyTargets 'summary applyReadyTargets'
        Assert-True (-not $plan.Data.Summary.applyActionAvailable) 'applyActionAvailable'
        Assert-True (-not $plan.Data.Simulation.TestSeamsUsed) 'no seams, no simulation marker'
        Assert-Equal 0 @($plan.Data.Simulation.Seams).Count 'empty seam list'
        Assert-True (-not $plan.Data.Snapshot.atomicIsolation) 'snapshot declares no atomic isolation'
        Assert-True $plan.Data.Snapshot.topologyStabilityRequired 'snapshot requires topology stability'
        Assert-True ($plan.Data.Snapshot.note -match 'not an access-control sandbox') 'snapshot disclaimer present'
    }

    Invoke-Test 'Data.PolicySddl parses to the compliant target policy' {
        $target = Join-Path $workRoot 'policy-sddl'
        $result = Invoke-PlanTool ('-StateDir ''' + $target + '''')
        $plan = ConvertFrom-PlanJson $result.StdOut
        $verdict = Test-GsAclPolicy -Sddl $plan.Data.PolicySddl
        Assert-True $verdict.Compliant 'emitted policy SDDL must be compliant'
    }

    Invoke-Test 'existing plain directories with compliant ACL seam stay blocked (never apply-ready)' {
        $state = Join-Path $workRoot 'state-a'
        New-Item -ItemType Directory -Path (Join-Path $state 'runtime\bin') -Force | Out-Null
        $seam = "'" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $result = Invoke-PlanTool ('-StateDir ''' + $state + ''' -AclSddl ' + $seam)
        Assert-Equal 0 $result.ExitCode 'compliant targets are a clean plan'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-True $plan.Success 'success flag'
        foreach ($entry in @($plan.Data.Targets)) {
            Assert-Equal 'compliant' $entry.status ('status for ' + $entry.target)
            Assert-True (-not $entry.applyReady) ('a compliant SDDL must never become apply-ready: ' + $entry.target)
        }
        Assert-True (@($plan.Data.Targets[2].applyBlockers) -icontains 'UserSessionLogMigrationNotConfirmed') 'runtimeBin still blocked by log migration'
    }

    Invoke-Test 'deviating target is reported while compliant targets stay blocked' {
        $state = Join-Path $workRoot 'state-b'
        New-Item -ItemType Directory -Path (Join-Path $state 'runtime\bin') -Force | Out-Null
        $unprotected = 'O:BAG:SYD:(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
        $seam = "'" + $unprotected + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $result = Invoke-PlanTool ('-StateDir ''' + $state + ''' -AclSddl ' + $seam)
        Assert-Equal 0 $result.ExitCode 'deviations are data, not errors'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-True $plan.Success 'success flag'
        Assert-Equal 'deviates' $plan.Data.Targets[0].status 'stateDir status'
        Assert-Equal 'compliant' $plan.Data.Targets[1].status 'runtime status'
        Assert-Equal 'compliant' $plan.Data.Targets[2].status 'runtimeBin status'
        Assert-Equal 1 $plan.Data.Summary.deviatingTargets 'deviating count'
        Assert-Equal 0 $plan.Data.Summary.applyReadyTargets 'nothing is apply-ready'
    }

    Invoke-Test 'reparse point targets are refused (simulated seam)' {
        $state = Join-Path $workRoot 'state-c'
        $seam = "'" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $result = Invoke-PlanTool ('-StateDir ''' + $state + ''' -ItemState directory,reparsePoint,directory -AclSddl ' + $seam)
        Assert-Equal 1 $result.ExitCode 'reparse target must fail the run'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-True (-not $plan.Success) 'success flag'
        Assert-Equal 'reparsePoint' $plan.Data.Targets[1].status 'runtime status'
        Assert-Equal 'compliant' $plan.Data.Targets[2].status 'runtimeBin still evaluated'
        $errorCodes = @($plan.Errors | ForEach-Object { $_.Code })
        Assert-True ($errorCodes -icontains 'ReparsePointTargetRejected') 'reparse error code'
        Assert-True (-not $plan.Data.Targets[1].applyReady) 'reparse target not apply-ready'
    }

    Invoke-Test 'a file where a directory is expected is refused (simulated seam)' {
        $state = Join-Path $workRoot 'state-d'
        $seam = "'" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $result = Invoke-PlanTool ('-StateDir ''' + $state + ''' -ItemState file,directory,directory -AclSddl ' + $seam)
        Assert-Equal 1 $result.ExitCode 'not-a-directory must fail the run'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-Equal 'notDirectory' $plan.Data.Targets[0].status 'stateDir status'
        $errorCodes = @($plan.Errors | ForEach-Object { $_.Code })
        Assert-True ($errorCodes -icontains 'TargetIsNotADirectory') 'error code'
    }

    Invoke-Test 'unreadable ACL is reported (simulated seam)' {
        $state = Join-Path $workRoot 'state-e'
        $seam = "'" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $result = Invoke-PlanTool ('-StateDir ''' + $state + ''' -ItemState directory,unreadable,directory -AclSddl ' + $seam)
        Assert-Equal 1 $result.ExitCode 'unreadable ACL must fail the run'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-Equal 'aclReadFailed' $plan.Data.Targets[1].status 'runtime status'
        $errorCodes = @($plan.Errors | ForEach-Object { $_.Code })
        Assert-True ($errorCodes -icontains 'AclReadFailed') 'error code'
    }

    Invoke-Test 'non-canonical StateDir is rejected (.. escape)' {
        $target = Join-Path $workRoot ('x\..\y')
        $result = Invoke-PlanTool ('-StateDir ''' + $target + '''')
        Assert-Equal 1 $result.ExitCode 'must fail'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-True (-not $plan.Success) 'success flag'
        $errorCodes = @($plan.Errors | ForEach-Object { $_.Code })
        Assert-True ($errorCodes -icontains 'StateDirMustBeCanonical') 'canonical error code'
    }

    Invoke-Test 'relative StateDir is rejected' {
        $result = Invoke-PlanTool '-StateDir relative\state'
        Assert-Equal 1 $result.ExitCode 'must fail'
        $plan = ConvertFrom-PlanJson $result.StdOut
        $errorCodes = @($plan.Errors | ForEach-Object { $_.Code })
        Assert-True ($errorCodes -icontains 'StateDirMustBeAbsolute') 'absolute error code'
    }

    Invoke-Test 'ItemState seam shorter than three targets is rejected' {
        $result = Invoke-PlanTool ('-StateDir ''' + $workRoot + ''' -ItemState directory')
        Assert-Equal 1 $result.ExitCode 'must fail'
        $plan = ConvertFrom-PlanJson $result.StdOut
        $errorCodes = @($plan.Errors | ForEach-Object { $_.Code })
        Assert-True ($errorCodes -icontains 'ItemStateSeamTooShort') 'seam length error code'
        # The argument-error exit must keep the Simulation marker so a seam
        # driven error output can never pass as real-machine evidence.
        Assert-True $plan.Data.Simulation.TestSeamsUsed 'simulation marker on the error exit'
        Assert-True (@($plan.Data.Simulation.Seams) -icontains 'ItemState') 'seam name listed on the error exit'
    }

    Invoke-Test 'a junction ancestor blocks the whole branch without reading ACLs through it' {
        # Real filesystem fixture: one junction in %TEMP%. The walk must stop
        # at the junction level and never issue an ACL read behind it.
        $base = Join-Path $workRoot 'junc-base'
        $real = Join-Path $base 'real'
        New-Item -ItemType Directory -Path $real -Force | Out-Null
        $junction = Join-Path $base 'link'
        try {
            New-Item -ItemType Junction -Path $junction -Value $real -ErrorAction Stop | Out-Null
        } catch {
            cmd /c mklink /J "$junction" "$real" | Out-Null
        }
        try {
            $stateDir = Join-Path $junction 'state'
            $result = Invoke-PlanTool ('-StateDir ''' + $stateDir + '''')
            Assert-Equal 1 $result.ExitCode 'junction ancestor must fail the run'
            $plan = ConvertFrom-PlanJson $result.StdOut
            Assert-True (-not $plan.Success) 'success flag'
            Assert-Equal 3 @($plan.Errors).Count 'one refused error per target'
            foreach ($entry in @($plan.Data.Targets)) {
                Assert-Equal 'reparsePoint' $entry.status ('status for ' + $entry.target)
                Assert-True (-not $entry.applyReady) ('applyReady for ' + $entry.target)
            }
            $errorCodes = @($plan.Errors | ForEach-Object { $_.Code })
            Assert-True ($errorCodes -icontains 'ReparsePointTargetRejected') 'reparse error code'
            Assert-True (-not $plan.Data.Simulation.TestSeamsUsed) 'a real-metadata run is not marked as simulation'
        } finally {
            if (Test-Path -LiteralPath $junction) { [System.IO.Directory]::Delete($junction, $false) }
        }
    }

    Invoke-Test 'injected metadata reader proves reads stay inside the StateDir chain' {
        # Every metadata read goes through the injected reader, which logs
        # the path. The logged set must equal exactly the expected ancestor
        # chains (shared cache: each unique path read once, nothing beyond
        # the three targets, nothing outside the chain).
        $state = Join-Path $workRoot 'probe-state'
        $readLog = Join-Path $workRoot 'read-log.txt'
        $seam = "'" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $toolArgs = '-StateDir ''' + $state + ''' -GetItemReader { param($p) Add-Content -LiteralPath ''' + $readLog + ''' -Value $p; return [pscustomobject]@{ Attributes = ([System.IO.FileAttributes]::Directory) } } -AclSddl ' + $seam
        $result = Invoke-PlanTool $toolArgs
        Assert-Equal 0 $result.ExitCode 'virtual clean chain is a clean plan'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-True $plan.Success 'success flag'
        foreach ($entry in @($plan.Data.Targets)) { Assert-Equal 'compliant' $entry.status ('status for ' + $entry.target) }
        Assert-True $plan.Data.Simulation.TestSeamsUsed 'simulation must be marked'
        Assert-True (@($plan.Data.Simulation.Seams) -icontains 'GetItemReader') 'GetItemReader seam listed'
        Assert-True (@($plan.Data.Simulation.Seams) -icontains 'AclSddl') 'AclSddl seam listed'

        $logged = @(Get-Content -LiteralPath $readLog -ErrorAction SilentlyContinue | ForEach-Object { $_.TrimEnd('\') })
        $expected = New-Object System.Collections.Generic.List[string]
        $current = [System.IO.Path]::GetFullPath($state)
        while ($true) {
            $expected.Add($current.TrimEnd('\'))
            $parent = [System.IO.Path]::GetDirectoryName($current)
            if ([string]::IsNullOrEmpty($parent) -or ($parent -eq $current)) { break }
            $current = $parent
        }
        $expected.Add((Join-Path $state 'runtime').TrimEnd('\'))
        $expected.Add((Join-Path $state 'runtime\bin').TrimEnd('\'))
        $expectedSorted = @($expected | Sort-Object -Unique)
        Assert-Equal $expectedSorted.Count $logged.Count 'read count must equal the unique expected paths'
        # Set equality (not a prefix check): the chain legitimately includes
        # ancestors above %TEMP% (drive root, user profile, ...); what matters
        # is that no path outside these chains and nothing deeper is read.
        $loggedSorted = @($logged | Sort-Object -Unique)
        Assert-Equal ($expectedSorted -join '|') ($loggedSorted -join '|') 'read set must equal the expected chain set exactly'
    }

    Invoke-Test 'only a clear not-found is missing; other metadata errors are structured failures' {
        $state = Join-Path $workRoot 'err-state'
        $throwing = '{ param($p) throw (New-Object System.InvalidOperationException ''simulated metadata failure'') }'
        $result = Invoke-PlanTool ('-StateDir ''' + $state + ''' -GetItemReader ' + $throwing)
        Assert-Equal 1 $result.ExitCode 'structured failure must fail the run'
        $plan = ConvertFrom-PlanJson $result.StdOut
        foreach ($entry in @($plan.Data.Targets)) {
            Assert-Equal 'aclReadFailed' $entry.status ('status for ' + $entry.target)
            Assert-True (-not $entry.applyReady) ('applyReady for ' + $entry.target)
        }
        $errorCodes = @($plan.Errors | ForEach-Object { $_.Code })
        Assert-True ($errorCodes -icontains 'AncestorReadFailed') 'ancestor read failure code'
        Assert-True $plan.Data.Simulation.TestSeamsUsed 'simulation must be marked for error injections too'

        $nullReader = '{ param($p) $null }'
        $result2 = Invoke-PlanTool ('-StateDir ''' + $state + ''' -GetItemReader ' + $nullReader)
        Assert-Equal 0 $result2.ExitCode 'clear not-found is a clean missing plan'
        $plan2 = ConvertFrom-PlanJson $result2.StdOut
        foreach ($entry in @($plan2.Data.Targets)) {
            Assert-Equal 'missing' $entry.status ('status for ' + $entry.target)
        }
        Assert-Equal 0 @($plan2.Errors).Count 'no errors for missing'
    }

    Invoke-Test 'JSON arrays stay arrays for empty and single elements' {
        $target = Join-Path $workRoot 'not-created-2'
        $result = Invoke-PlanTool ('-StateDir ''' + $target + '''')
        Assert-True ($result.StdOut -match '"Errors":\s+\[') 'Errors must serialize as an array'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-Equal 0 @($plan.Errors).Count 'zero errors parsed as an array'
        Assert-Equal 0 @($plan.Data.Targets[0].findings).Count 'zero findings parsed as an array'
        Assert-Equal 2 @($plan.Data.Targets[0].applyBlockers).Count 'single-element-added blockers parsed as an array'
        Assert-Equal 0 @($plan.Data.Simulation.Seams).Count 'empty seam list parsed as an array'
        Assert-True (-not $plan.Data.Simulation.TestSeamsUsed) 'no seams used'
    }

    Invoke-Test 'JSON arrays stay arrays for multiple elements' {
        $state = Join-Path $workRoot 'state-g'
        New-Item -ItemType Directory -Path (Join-Path $state 'runtime\bin') -Force | Out-Null
        $twoWriters = 'O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;OICI;0x1301bf;;;AU)(A;OICI;0x40000000;;;S-1-1-0)'
        $seam = "'" + $twoWriters + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $result = Invoke-PlanTool ('-StateDir ''' + $state + ''' -AclSddl ' + $seam)
        Assert-Equal 0 $result.ExitCode 'deviations are data, not errors'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-Equal 2 @($plan.Data.Targets[0].writers).Count 'two writers parsed as an array'
        Assert-Equal 2 @($plan.Data.Targets[0].findings).Count 'two findings parsed as an array'
        Assert-True ($result.StdOut -match '"writers":\s+\[') 'writers serialized as an array'
    }

    Invoke-Test 'built-in serializer escapes quote, backslash, newline and CJK for roundtrip' {
        # Samples use codepoints so the test source stays pure ASCII.
        $backslash = [string][char]92
        $sample = [ordered]@{
            quote     = 'a' + [char]34 + 'b'
            slash     = 'c' + $backslash + 'd'
            newline   = 'e' + [char]10 + 'f'
            cjk       = [string][char]0x4E2D + [char]0x6587
        }
        $json = ConvertTo-Json -InputObject $sample -Depth 8 -Compress
        Assert-True ($json.Contains('a' + $backslash + [char]34 + 'b')) 'quote must be escaped'
        Assert-True ($json.Contains('c' + $backslash + $backslash + 'd')) 'backslash must be escaped'
        Assert-True ($json.Contains('e' + $backslash + 'n' + 'f')) 'newline must be escaped'
        # PS 5.1 ConvertTo-Json keeps CJK as raw characters (it escapes
        # HTML-sensitive ASCII like < > as \uXXXX, not CJK); roundtrip still
        # restores the exact string.
        Assert-True ($json.Contains([string][char]0x4E2D + [char]0x6587)) 'CJK characters are preserved in the JSON text'
        $roundtrip = ConvertFrom-Json $json
        Assert-Equal ('a' + [char]34 + 'b') $roundtrip.quote 'quote roundtrip'
        Assert-Equal ('c' + $backslash + 'd') $roundtrip.slash 'backslash roundtrip'
        Assert-Equal ('e' + [char]10 + 'f') $roundtrip.newline 'newline roundtrip'
        Assert-Equal ([string][char]0x4E2D + [char]0x6587) $roundtrip.cjk 'CJK roundtrip'
    }

    Invoke-Test 'a real file at StateDir is reported as notDirectory' {
        # Real %TEMP% fixture: a plain (empty) file where the state dir root
        # would be. Regression: the state function reported 'notDirectory'
        # while the switch only matched 'file', so this used to fall through
        # to 'notEvaluable'.
        $filePath = Join-Path $workRoot 'plain-file-state'
        New-Item -ItemType File -Path $filePath -Force | Out-Null
        $result = Invoke-PlanTool ('-StateDir ''' + $filePath + '''')
        Assert-Equal 1 $result.ExitCode 'not-a-directory must fail the run'
        $plan = ConvertFrom-PlanJson $result.StdOut
        foreach ($entry in @($plan.Data.Targets)) {
            Assert-Equal 'notDirectory' $entry.status ('status for ' + $entry.target)
            Assert-True (-not $entry.applyReady) ('applyReady for ' + $entry.target)
        }
        $errorCodes = @($plan.Errors | ForEach-Object { $_.Code })
        Assert-True ($errorCodes -icontains 'TargetIsNotADirectory') 'error code'
    }

    Invoke-Test 'profile path masking is case-insensitive (synthetic, no real reads)' {
        # Synthetic case-variant of the profile path: swap the case of every
        # letter. The metadata reader seam means NOTHING on disk is touched
        # (no real profile reads), yet the case-variant path still flows
        # through redaction.
        $profilePath = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        $swapped = -join ($profilePath.ToCharArray() | ForEach-Object {
            if ([char]::IsUpper($_)) { [char]::ToLower($_) } elseif ([char]::IsLower($_)) { [char]::ToUpper($_) } else { $_ }
        })
        $state = Join-Path $swapped ('AppData\Local\Temp\GsAclCase_' + [guid]::NewGuid().ToString('N'))
        $seam = "'" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $toolArgs = '-StateDir ''' + $state + ''' -GetItemReader { param($p) return [pscustomobject]@{ Attributes = ([System.IO.FileAttributes]::Directory) } } -AclSddl ' + $seam
        $result = Invoke-PlanTool $toolArgs
        Assert-Equal 0 $result.ExitCode 'virtual clean chain is a clean plan'
        # The built-in serializer escapes '<'/'>' as </>, so the
        # masking marker appears escaped in the raw text and as literal
        # '<UserProfile>' after parsing.
        Assert-True ($result.StdOut.Contains([char]92 + 'u003cUserProfile' + [char]92 + 'u003e')) 'case-variant profile path is masked (escaped marker in raw output)'
        Assert-True ($result.StdOut -notmatch [regex]::Escape($env:UserName)) 'no account name in any casing may leak'
        Assert-True ($result.StdOut -notmatch 'users\\') 'no case variant of the Users path component may leak'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-True ($plan.Data.StateDir.StartsWith('<UserProfile>')) 'masked StateDir in data'
        Assert-True ($plan.Data.StateDir -notmatch 'users\\') 'parsed path has no Users component left'
    }

    Invoke-Test 'CJK path characters survive the emitted JSON and roundtrip' {
        # A fixture directory name with CJK characters (codepoints, ASCII
        # test source): the built-in serializer keeps them as characters in
        # the JSON text and ConvertFrom-Json restores them.
        $cjkName = [string][char]0x4E2D + [char]0x6587
        $state = Join-Path $workRoot ($cjkName + '-state')
        New-Item -ItemType Directory -Path (Join-Path $state 'runtime\bin') -Force | Out-Null
        $seam = "'" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $result = Invoke-PlanTool ('-StateDir ''' + $state + ''' -AclSddl ' + $seam)
        Assert-Equal 0 $result.ExitCode 'clean plan'
        Assert-True ($result.StdOut.Contains($cjkName)) 'raw output carries the CJK characters'
        Assert-True ($result.StdOut.Contains([char]92 + [char]92)) 'raw output escapes path separators as double backslashes'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-True ($plan.Data.Targets[0].path.Contains([char]0x4E2D)) 'roundtrip restores the CJK characters'
    }

    Invoke-Test 'plan output leaks neither machine SIDs nor the account name nor the profile path' {
        $state = Join-Path $workRoot 'state-f'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $machineOwnerSddl = 'O:S-1-5-21-1004336348-3244382588-2953262690-1001G:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)'
        $seam = "'" + $machineOwnerSddl + "','" + $canonicalPolicySddl + "','" + $canonicalPolicySddl + "'"
        $result = Invoke-PlanTool ('-StateDir ''' + $state + ''' -AclSddl ' + $seam)
        Assert-True ($result.StdOut -notmatch 'S-1-5-21-\d+-\d+-\d+-\d+') 'no raw machine SID anywhere in the output'
        Assert-True ($result.StdOut -match 'S-1-5-21-\*-\d+') 'machine SID is masked in the output'
        $accountName = [Environment]::UserName
        if (-not [string]::IsNullOrEmpty($accountName)) {
            Assert-True ($result.StdOut -notlike ('*' + $accountName + '*')) 'no account name in the output'
        }
        $profilePath = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        Assert-True ($result.StdOut -notlike ('*' + $profilePath + '*')) 'no raw profile path in the output'
        $plan = ConvertFrom-PlanJson $result.StdOut
        Assert-Equal 'S-1-5-21-*-1001' $plan.Data.Targets[0].ownerSid 'masked owner in data'
    }

} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ('Summary: ' + $script:Passed + ' passed, ' + $script:Failed + ' failed')
if ($script:Failed -gt 0 -or $script:Passed -eq 0) { exit 1 }
exit 0
