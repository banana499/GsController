#requires -Version 5.1
<#
.SYNOPSIS
  Product entry point for the private GameStream controller.

.DESCRIPTION
  Installs the user's own component tree and the controller scripts into a
  portable layout, validates them, and starts/stops the private stack through
  the deployed scripts. It never writes to the NVIDIA App installation and
  never handles third-party binaries that the user has not supplied.

  Start, Stop and Recover serialize through a named cross-process mutex
  derived from the state directory, so two controllers (console, tray UI)
  can never drive the same runtime at the same time. Recover clears a stuck
  GameStream session only when every safety gate passes, and Diagnose shells
  out to gs-diagnose.ps1 for a read-only report; Diagnose is handled before
  the module imports so a broken install can still be diagnosed.
  -Action PrepareUninstall stops the runtime under the same lock and removes
  the named scheduled task (elevation required only when a task will be
  removed; StateDir and LogDir are kept). See docs/lifecycle-hardening.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Check', 'Start', 'Stop', 'Status', 'Recover', 'Diagnose', 'CreateCatalog', 'RegisterAutostart', 'UnregisterAutostart', 'PrepareUninstall')]
    [string]$Action,
    [string]$InstallDir = '',
    [string]$StateDir = (Join-Path $env:ProgramData 'Local Development\GsController'),
    [string]$LogDir = (Join-Path $env:ProgramData 'Local Development\GsControllerLogs'),
    [string]$ComponentSourceDir = '',
    [string]$CatalogPath = '',
    [string]$ModuleRoot = '',
    [string]$HelperSourceDir = '',
    # Seconds to wait for the lifecycle mutex before giving up; 0 = try once.
    [int]$LockTimeoutSec = 30,
    [string]$ServerInfoUri = 'http://127.0.0.1:47989/serverinfo',
    [int]$ServerInfoTimeoutSec = 3,
    [int[]]$ClientPorts = @(47984, 48010),
    # Recover gate 4 (outbound-traffic client check): seconds to sample the
    # host's outbound send rate over operational non-loopback adapters; 0
    # disables the gate. Other processes' traffic can also trip it - when in
    # doubt Recover refuses (prefer safe).
    [int]$TrafficSampleSec = 2,
    # PROVISIONAL: idle-host send-rate threshold in Kbps, well under a tenth
    # of the ~40 Mbps 4K60 stream bitrate.
    [int]$MaxIdleSendKbps = 500,
    # Test seams with production defaults. -SupervisorTaskName '' skips the
    # scheduled-task call entirely (used by every test).
    [int]$StopSettleSec = 2,
    [string]$SupervisorTaskName = 'GsControllerSupervisor',
    [string]$DiagnoseScript = '',
    # Test seam for -Action PrepareUninstall ONLY: forces the elevation
    # decision to "not elevated" (=> ElevationRequired, nothing runs). It can
    # only make the check STRICTER; no input can make a non-elevated process
    # count as elevated.
    [switch]$AssumeNotElevated
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
}
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $env:ProgramData 'Local Development\GsControllerLogs' }
if ([string]::IsNullOrWhiteSpace($ModuleRoot)) { $ModuleRoot = Join-Path $PSScriptRoot 'Modules' }
if ([string]::IsNullOrWhiteSpace($HelperSourceDir)) { $HelperSourceDir = Join-Path $PSScriptRoot 'bin' }

function New-Result([bool]$Success, $Data, [object[]]$Errors) {
    [pscustomobject]@{ Success = $Success; Data = $Data; Errors = @($Errors) }
}
function Write-JsonFile([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Get-RuntimeLayout {
    $configPath = Join-Path $StateDir 'runtime-config.json'
    if ([string]::IsNullOrWhiteSpace($ComponentSourceDir) -and (Test-Path -LiteralPath $configPath)) {
        $read = Read-GsRuntimeConfig -Path $configPath
        if (-not $read.Success) { return $read }
        return $read
    }
    return (New-GsRuntimeLayout -InstallDir $InstallDir -StateDir $StateDir -LogDir $LogDir -ComponentSourceDir $ComponentSourceDir)
}
function Get-GsUnwrappedException {
    # PowerShell wraps direct .NET method exceptions in a
    # MethodInvocationException; unwrap it so callers can classify the real
    # exception type.
    param($Record)
    $ex = $Record.Exception
    while ($null -ne $ex -and $null -ne $ex.InnerException -and (
            $ex -is [System.Management.Automation.MethodInvocationException] -or
            $ex -is [System.Management.Automation.RuntimeException])) {
        $ex = $ex.InnerException
    }
    return $ex
}
function Get-GsLifecycleLockName {
    # Cross-process lifecycle mutex name. It is derived from the state
    # directory so that parallel synthetic test layouts never contend with
    # the installed product (or with each other). The path is fully
    # normalized before hashing: GetFullPath resolves '.' segments (and
    # converts '/' to '\'), trailing separators are trimmed, and casing is
    # normalized, so that different spellings of the same directory map to
    # the same mutex. Note that this normalization changed the derived name
    # versus earlier builds: an old and a new CLI running at the same moment
    # derive different names and would not exclude each other (see
    # docs/lifecycle-hardening.md).
    param([Parameter(Mandatory = $true)][string]$StateDirPath)
    $normalized = [System.IO.Path]::GetFullPath($StateDirPath).Replace('/', '\').TrimEnd('\').ToUpperInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))
    } finally {
        $sha.Dispose()
    }
    $hex = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    return ('Global\GsController.Lifecycle.' + $hex.Substring(0, 16))
}
function New-GsLifecycleMutexSecurity {
    # DACL for the lifecycle mutex. The tray (non-admin), the elevated UAC
    # child and an optionally elevated console must all be able to open the
    # same mutex, so the DACL is set explicitly instead of falling back to
    # the creator's default DACL (which depends on who created the mutex
    # first):
    # - NT AUTHORITY\INTERACTIVE (well-known SID S-1-5-4) and SYSTEM
    #   (S-1-5-18) get Synchronize|Modify, which is exactly what
    #   WaitOne/ReleaseMutex need. INTERACTIVE covers any interactive
    #   session; with over-the-shoulder UAC the elevated child can run as a
    #   different account than the tray, so a plain user SID would not.
    # - BUILTIN\Administrators (S-1-5-32-544) gets FullControl so an
    #   elevated reader can inspect the DACL.
    # Well-known SIDs instead of account names because account names are
    # localized (this host is zh-CN).
    $security = New-Object System.Security.AccessControl.MutexSecurity
    $syncModify = [System.Security.AccessControl.MutexRights]::Synchronize -bor [System.Security.AccessControl.MutexRights]::Modify
    $security.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-4')), $syncModify, [System.Security.AccessControl.AccessControlType]::Allow)))
    $security.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')), $syncModify, [System.Security.AccessControl.AccessControlType]::Allow)))
    $security.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')), [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)))
    return $security
}
function Invoke-WithLifecycleLock {
    # Runs $Body while holding the named lifecycle mutex for the state
    # directory. Returns the structured failure result on lock errors, or
    # whatever $Body returns. The mutex is always released in finally, also
    # when $Body throws.
    param(
        [Parameter(Mandatory = $true)][string]$StateDirPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSec,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $lockName = Get-GsLifecycleLockName -StateDirPath $StateDirPath
    $mutex = $null
    $createdNew = $false
    try {
        # The security descriptor is applied only when this call CREATES the
        # mutex; for an existing name the kernel ignores it. When the mutex
        # already exists with a DACL that denies full access (for example an
        # elevated creator and a non-admin caller), the .NET Framework
        # constructor retries with OpenMutex(MUTEX_MODIFY_STATE |
        # SYNCHRONIZE), so a Synchronize|Modify grant is enough to use a
        # mutex another integrity level created (verified against the .NET
        # Framework reference source; see docs/lifecycle-hardening.md).
        $mutex = New-Object -TypeName 'System.Threading.Mutex' -ArgumentList $false, $lockName, ([ref]$createdNew), (New-GsLifecycleMutexSecurity)
    } catch {
        $ex = Get-GsUnwrappedException $_
        return (New-Result $false $null @([pscustomobject]@{
            Code = 'LockFailed'
            Message = ('Could not open the lifecycle mutex {0}: {1}: {2}' -f $lockName, $ex.GetType().FullName, $ex.Message)
            LockName = $lockName
            ExceptionType = $ex.GetType().FullName
        }))
    }
    $acquired = $false
    $abandoned = $false
    try {
        try {
            if ($TimeoutSec -gt 0) { $acquired = $mutex.WaitOne([System.TimeSpan]::FromSeconds($TimeoutSec)) }
            else { $acquired = $mutex.WaitOne([System.TimeSpan]::Zero) }
        } catch {
            $ex = Get-GsUnwrappedException $_
            if ($ex -is [System.Threading.AbandonedMutexException]) {
                # The previous owner died while holding the mutex. Ownership
                # was granted to us anyway; proceed and flag it.
                $acquired = $true
                $abandoned = $true
            } else {
                return (New-Result $false $null @([pscustomobject]@{
                    Code = 'LockFailed'
                    Message = ('Could not wait on the lifecycle mutex {0}: {1}: {2}' -f $lockName, $ex.GetType().FullName, $ex.Message)
                    LockName = $lockName
                    CreatedNew = $createdNew
                    ExceptionType = $ex.GetType().FullName
                }))
            }
        }
        if (-not $acquired) {
            return (New-Result $false $null @([pscustomobject]@{
                Code = 'Busy'
                Message = ('Another Start/Stop/Recover is in progress for {0}' -f $StateDirPath)
                LockName = $lockName
                CreatedNew = $createdNew
                TimeoutSec = $TimeoutSec
            }))
        }
        return (& $Body $abandoned)
    } finally {
        if ($null -ne $mutex) {
            if ($acquired) {
                try { $mutex.ReleaseMutex() } catch { }
            }
            $mutex.Dispose()
        }
    }
}
function Invoke-GsRuntimeStartCore {
    # Runs the deployed start script. The caller must hold the lifecycle lock.
    # Failures are structured instead of thrown: a missing or throwing script
    # returns Success = $false with Errors[0].Code = 'RuntimeStartFailed';
    # a non-zero script exit returns the same code with ExitCode on the
    # error entry. Data always carries ExitCode ($null when the script
    # threw) and LockAbandoned.
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [bool]$LockAbandoned = $false
    )
    $script = Join-Path $Layout.RuntimeBinDir 'gs_start_with_hook.ps1'
    # A runtime script that ends without `exit` leaves the previous native
    # command's exit code behind; reset it so Success reflects this run.
    $global:LASTEXITCODE = 0
    try {
        if (-not (Test-Path -LiteralPath $script)) { throw "Runtime start script missing: $script" }
        & $script
    } catch {
        $ex = Get-GsUnwrappedException $_
        return (New-Result $false ([pscustomobject]@{ ExitCode = $null; LockAbandoned = $LockAbandoned }) @([pscustomobject]@{
            Code = 'RuntimeStartFailed'
            Message = ('Start failed: {0}' -f $ex.Message)
            ExceptionType = $ex.GetType().FullName
        }))
    }
    if ($LASTEXITCODE -ne 0) {
        return (New-Result $false ([pscustomobject]@{ ExitCode = $LASTEXITCODE; LockAbandoned = $LockAbandoned }) @([pscustomobject]@{
            Code = 'RuntimeStartFailed'
            Message = ('Start failed: the runtime start script exited {0}.' -f $LASTEXITCODE)
            ExitCode = $LASTEXITCODE
        }))
    }
    return (New-Result $true ([pscustomobject]@{ ExitCode = $LASTEXITCODE; LockAbandoned = $LockAbandoned }) @())
}
function Get-GsResultFromOutput {
    # The deployed runtime scripts are black boxes and may write to the
    # output stream, so a core call returns the script output followed by
    # the result object. Pick the last element that is a pscustomobject with
    # a Success property; $null when there is none (treated as a failure by
    # the caller).
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
function Invoke-GsRuntimeStopCore {
    # Pauses the supervisor, settles, then runs the deployed stop script.
    # The caller must hold the lifecycle lock. Failures are structured
    # instead of thrown: a missing or throwing script returns Success =
    # $false with Errors[0].Code = 'RuntimeStopFailed'; a non-zero script
    # exit returns the same code with ExitCode on the error entry. Data
    # always carries ExitCode ($null when the script threw) and
    # LockAbandoned.
    #
    # Pause-flag contract: the pause is written at the CANONICAL location
    # ($Layout.PauseFlagPath = <StateDir>\runtime\state\supervisor_pause.flag,
    # the location the black-box supervisor reads per the public operator
    # docs). The LEGACY location ($Layout.LegacyPauseFlagPath =
    # <StateDir>\supervisor_pause.flag) written by older builds is
    # PRESERVE-ONLY: an existing legacy flag keeps its exact bytes and is
    # never deleted here, and a missing one is NOT created. An existing
    # canonical flag is never overwritten either. Nothing on this path is
    # ever deleted recursively; a pause path that exists but is not a
    # regular file (for example a directory) fails the stop with the
    # structured RuntimeStopFailed BEFORE the stop script runs.
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [int]$StopSettleSec = 2,
        [string]$SupervisorTaskName = 'GsControllerSupervisor',
        [bool]$LockAbandoned = $false,
        # Optional caller-supplied hashtable. When this stop core call
        # CREATES the canonical pause flag, it records that fact into it
        # (key CanonicalCreatedByThisStopCore) AT THE MOMENT of the write,
        # so the ownership record survives any later throw on the same
        # path. Recover uses it to decide what its finally may clean up;
        # callers without a context get a private one.
        [hashtable]$PauseOperationContext = $null
    )
    $script = Join-Path $Layout.RuntimeBinDir 'gs_stop_private.ps1'
    if ($null -eq $PauseOperationContext) { $PauseOperationContext = @{} }
    # Everything from the pre-checks through the script run is inside the
    # guarded region. The script-existence check runs BEFORE any side
    # effect (no pause flag, no directory), and a pause flag that cannot
    # be created or written (or a supervisor task step that fails) must
    # surface as the same structured RuntimeStopFailed - with the stop
    # script never having run - instead of an unhandled throw.
    $global:LASTEXITCODE = 0
    try {
        if (-not (Test-Path -LiteralPath $script)) { throw "Runtime stop script missing: $script" }
        # Both pause positions are validated BEFORE anything is written, so a
        # failed preparation never leaves a half-applied pause behind.
        if ((Test-Path -LiteralPath $Layout.LegacyPauseFlagPath) -and -not (Test-Path -LiteralPath $Layout.LegacyPauseFlagPath -PathType Leaf)) {
            throw ("legacy supervisor pause flag path is not a regular file: {0}" -f $Layout.LegacyPauseFlagPath)
        }
        $pause = $Layout.PauseFlagPath
        $pauseDir = Split-Path -Parent $pause
        if (-not (Test-Path -LiteralPath $pauseDir)) { New-Item -ItemType Directory -Path $pauseDir -Force | Out-Null }
        if (Test-Path -LiteralPath $pause) {
            if (-not (Test-Path -LiteralPath $pause -PathType Leaf)) {
                throw ("supervisor pause flag path is not a regular file: {0}" -f $pause)
            }
            # An existing canonical pause keeps its content: the previous
            # pause stands until an explicit successful Start clears it.
        } else {
            # ATOMIC creation: FileMode.CreateNew fails when the file came
            # into existence between the pre-check and this call - for
            # example written by the supervisor, which does NOT take the
            # product mutex. ONLY the "already exists" failure of the OPEN
            # itself (an IOException carrying Win32 error 80 or 183) counts
            # as the lost race and preserves the existing flag; every other
            # open failure, and every failure AFTER a successful open, is a
            # stop failure.
            $pauseBytes = [System.Text.Encoding]::UTF8.GetBytes(((Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + ' reason=manual_stop' + "`r`n"))
            $pauseStream = $null
            try {
                $pauseStream = [IO.File]::Open($pause, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            } catch {
                # Classify ONLY the open failure: unwrap the .NET wrapper and
                # accept the "already exists" Win32 errors (80 =
                # ERROR_FILE_EXISTS, 183 = ERROR_ALREADY_EXISTS) as the lost
                # race - and only when the path now holds a regular file (a
                # racing swap to a directory is not a pause flag to
                # preserve). Anything else rethrows into the outer
                # structured RuntimeStopFailed.
                $openError = Get-GsUnwrappedException $_
                $alreadyExists = $false
                if ($openError -is [System.IO.IOException]) {
                    $openHResult = $openError.HResult
                    if ($openHResult -eq -2147024816 -or $openHResult -eq -2147024713) { $alreadyExists = $true }
                }
                if ($alreadyExists -and (Test-Path -LiteralPath $pause -PathType Leaf)) {
                    # Lost the creation race: the flag now exists as a
                    # regular file and is NOT ours - preserve it with its
                    # bytes, record nothing, and continue the stop without
                    # writing to it.
                } else {
                    throw
                }
            }
            if ($null -ne $pauseStream) {
                # OWNERSHIP: the open SUCCEEDED, so the canonical pause flag
                # came into existence through THIS call - record it
                # immediately, BEFORE the write, so the record survives every
                # later failure (write, flush, dispose, task stop, script
                # run); a write/flush failure then surfaces as the outer
                # structured RuntimeStopFailed with the flag still owned by
                # this operation. The core never creates a flag at the
                # LEGACY position, so a flag that appears there during the
                # stop - written by the black box or by the supervisor - can
                # never be claimed by this record.
                $PauseOperationContext.CanonicalCreatedByThisStopCore = $true
                try {
                    $pauseStream.Write($pauseBytes, 0, $pauseBytes.Length)
                    $pauseStream.Flush()
                } finally {
                    $pauseStream.Dispose()
                }
            }
        }
        # Legacy position: preserve only. Never written, never overwritten,
        # never deleted here.
        if (-not [string]::IsNullOrWhiteSpace($SupervisorTaskName)) {
            Stop-ScheduledTask -TaskName $SupervisorTaskName -ErrorAction SilentlyContinue
        }
        if ($StopSettleSec -gt 0) { Start-Sleep -Seconds $StopSettleSec }
        & $script
    } catch {
        $ex = Get-GsUnwrappedException $_
        return (New-Result $false ([pscustomobject]@{ ExitCode = $null; LockAbandoned = $LockAbandoned }) @([pscustomobject]@{
            Code = 'RuntimeStopFailed'
            Message = ('Stop failed: {0}' -f $ex.Message)
            ExceptionType = $ex.GetType().FullName
        }))
    }
    if ($LASTEXITCODE -ne 0) {
        return (New-Result $false ([pscustomobject]@{ ExitCode = $LASTEXITCODE; LockAbandoned = $LockAbandoned }) @([pscustomobject]@{
            Code = 'RuntimeStopFailed'
            Message = ('Stop failed: the runtime stop script exited {0}.' -f $LASTEXITCODE)
            ExitCode = $LASTEXITCODE
        }))
    }
    return (New-Result $true ([pscustomobject]@{ ExitCode = $LASTEXITCODE; LockAbandoned = $LockAbandoned }) @())
}
function Get-GsPauseFlagSnapshotEntry {
    # Read-only snapshot of ONE supervisor pause-flag position: whether it
    # exists and, when it does, its exact bytes. A path that exists but is
    # not a regular file (a directory), or a file that cannot be read (a
    # lock, a permission error), THROWS: without the bytes the caller can
    # guarantee neither restore-on-failure nor a safe cleanup, so it must
    # not run the operation at all. Nothing is written and nothing is
    # deleted here.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return ([pscustomobject]@{ Path = $Path; Exists = $false; Bytes = $null; CreatedByThisOperation = $false })
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("supervisor pause flag path is not a regular file: {0}" -f $Path)
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    return ([pscustomobject]@{ Path = $Path; Exists = $true; Bytes = $bytes; CreatedByThisOperation = $false })
}
function Get-GsPauseFlagSnapshot {
    # Snapshot of BOTH pause-flag positions (canonical + legacy), taken
    # BEFORE any side effect of an operation.
    param([Parameter(Mandatory = $true)]$Layout)
    return ([pscustomobject]@{
        Canonical = (Get-GsPauseFlagSnapshotEntry -Path $Layout.PauseFlagPath)
        Legacy    = (Get-GsPauseFlagSnapshotEntry -Path $Layout.LegacyPauseFlagPath)
    })
}
function Test-GsPauseBytesEqual {
    param([AllowNull()][byte[]]$A, [AllowNull()][byte[]]$B)
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}
function Restore-GsPauseFlagEntry {
    # Restores ONE snapshot entry to its pre-operation state. Ownership
    # rules: only a position that EXISTED before the operation is restored -
    # a flag the operation deleted is recreated with the original bytes and
    # a flag whose bytes were changed is rewritten with the original bytes;
    # an unchanged flag is left untouched. A position that did NOT exist
    # before is NEVER deleted here: a pause flag that appeared during the
    # operation may be the runtime deliberately staying paused, and removing
    # it could silently resume the supervisor. Never recursive, and a
    # directory-shaped path is reported as Failed instead of touched.
    # NEVER THROWS: with $ErrorActionPreference = 'Stop' even a metadata
    # probe (Test-Path) can produce a terminating error, so the whole body
    # is guarded and every failure - including one from the metadata checks
    # themselves - becomes the structured Failed outcome the caller appends
    # as a cleanup error.
    param([Parameter(Mandatory = $true)]$Entry)
    try {
        if (-not $Entry.Exists) { return ([pscustomobject]@{ Outcome = 'Untouched'; Path = $Entry.Path; Error = $null }) }
        if (-not (Test-Path -LiteralPath $Entry.Path)) {
            $parent = Split-Path -Parent $Entry.Path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllBytes($Entry.Path, $Entry.Bytes)
            return ([pscustomobject]@{ Outcome = 'Restored'; Path = $Entry.Path; Error = $null })
        }
        if (-not (Test-Path -LiteralPath $Entry.Path -PathType Leaf)) {
            return ([pscustomobject]@{ Outcome = 'Failed'; Path = $Entry.Path; Error = ('pause flag path is not a regular file: {0}' -f $Entry.Path) })
        }
        if (-not (Test-GsPauseBytesEqual -A ([IO.File]::ReadAllBytes($Entry.Path)) -B $Entry.Bytes)) {
            [IO.File]::WriteAllBytes($Entry.Path, $Entry.Bytes)
            return ([pscustomobject]@{ Outcome = 'Restored'; Path = $Entry.Path; Error = $null })
        }
        return ([pscustomobject]@{ Outcome = 'Untouched'; Path = $Entry.Path; Error = $null })
    } catch {
        return ([pscustomobject]@{ Outcome = 'Failed'; Path = $Entry.Path; Error = $_.Exception.Message })
    }
}
function Remove-GsPauseFlagFile {
    # Removes ONE pause-flag position. Only a regular file is removed, never
    # recursively; anything else (missing, a directory-shaped path, a file
    # that survives the removal attempt) is reported so the caller can fail
    # the result instead of reporting success.
    # NEVER THROWS: with $ErrorActionPreference = 'Stop' even a metadata
    # probe (Test-Path) can produce a terminating error, so the whole body
    # is guarded and every failure - including one from the metadata checks
    # themselves - becomes the structured Failed outcome the caller appends
    # as a cleanup error.
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return ([pscustomobject]@{ Outcome = 'Absent'; Path = $Path; Error = $null }) }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return ([pscustomobject]@{ Outcome = 'Failed'; Path = $Path; Error = ('pause flag path is not a regular file: {0}' -f $Path) })
        }
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $Path) {
            return ([pscustomobject]@{ Outcome = 'Failed'; Path = $Path; Error = 'pause flag still exists after the removal attempt' })
        }
        return ([pscustomobject]@{ Outcome = 'Removed'; Path = $Path; Error = $null })
    } catch {
        return ([pscustomobject]@{ Outcome = 'Failed'; Path = $Path; Error = $_.Exception.Message })
    }
}
function Test-GsPrepareUninstallElevation {
    # THE elevation decision for -Action PrepareUninstall, in one function so
    # it can be audited and pinned by tests: the -AssumeNotElevated test seam
    # can ONLY force the not-elevated outcome (when it is set the answer is
    # $false without even consulting the process token). In every other case
    # the real process token decides. No parameter, environment variable or
    # script-scoped variable can make a non-elevated process count as
    # elevated.
    param([switch]$AssumeNotElevated)
    if ($AssumeNotElevated) { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-GsTaskNotFoundOutcome {
    # $true ONLY for the scheduled-task provider's specific "task not found"
    # outcome: the query failed with ERROR_FILE_NOT_FOUND (HRESULT 0x80070002,
    # reported as a CimException whose message carries the hex in every
    # locale, or as the cmdletization framework's keyed-query NotFound
    # marker). EVERYTHING else - a stopped scheduler service, an RPC or
    # communication failure, an access error - is $false, so the caller
    # reports a lookup failure instead of a confirmed absence (fail closed).
    param([AllowNull()]$ErrorRecord)
    if ($null -eq $ErrorRecord) { return $false }
    try {
        $fullyQualified = [string]$ErrorRecord.FullyQualifiedErrorId
        if ($fullyQualified -like '*CmdletizationQuery_NotFound*') { return $true }
    } catch { }
    $ex = $null
    try { $ex = $ErrorRecord.Exception } catch { $ex = $null }
    while ($null -ne $ex) {
        $message = ''
        try { $message = [string]$ex.Message } catch { $message = '' }
        if ($message -match '0x80070002' -or $message -match 'The system cannot find the file specified') { return $true }
        try { $ex = $ex.InnerException } catch { $ex = $null }
    }
    return $false
}
function Invoke-GsTaskRemovalOutcome {
    # The ONE scheduled-task lookup-then-remove decision for
    # -Action PrepareUninstall. $TaskLookup / $TaskRemover are scriptblock
    # seams: production passes NOTHING and gets the real Get-/
    # Unregister-ScheduledTask calls with errors SURFACING; tests pass fakes
    # (the real scheduler is never exercised by a test). Fail closed:
    # - No task named => nothing to look up: TaskRemoved = TaskExisted = $false.
    # - ONLY the provider's specific "task not found" outcome
    #   (Test-GsTaskNotFoundOutcome) means the task is absent:
    #   TaskRemoved = TaskExisted = $false.
    # - ANY other lookup error is rethrown so the caller records
    #   TaskRemovalFailed: a scheduler communication failure can never be
    #   reported as a confirmed absence.
    # - A found task is removed with the remover; TaskRemoved = TaskExisted
    #   = $true.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskName,
        [Parameter(Mandatory = $true)][bool]$WillRemoveTask,
        [scriptblock]$TaskLookup = $null,
        [scriptblock]$TaskRemover = $null
    )
    if (-not $WillRemoveTask) {
        return ([pscustomobject]@{ TaskRemoved = $false; TaskExisted = $false })
    }
    $lookupOp = $TaskLookup
    if ($null -eq $lookupOp) { $lookupOp = { param($Name) Get-ScheduledTask -TaskName $Name -ErrorAction Stop } }
    $removerOp = $TaskRemover
    if ($null -eq $removerOp) { $removerOp = { param($Name) Unregister-ScheduledTask -TaskName $Name -Confirm:$false } }
    $task = $null
    try {
        $found = & $lookupOp $TaskName
        foreach ($item in @($found)) {
            if ($null -ne $item) { $task = $item; break }
        }
    } catch {
        if (Test-GsTaskNotFoundOutcome -ErrorRecord $_) {
            return ([pscustomobject]@{ TaskRemoved = $false; TaskExisted = $false })
        }
        throw ('PrepareUninstall: the scheduled task lookup for {0} failed: {1}' -f $TaskName, $_.Exception.Message)
    }
    if ($null -ne $task) {
        & $removerOp $TaskName | Out-Null
        return ([pscustomobject]@{ TaskRemoved = $true; TaskExisted = $true })
    }
    return ([pscustomobject]@{ TaskRemoved = $false; TaskExisted = $false })
}
function Invoke-GsPrepareUninstallSteps {
    # The one stop-then-remove decision for -Action PrepareUninstall.
    # $StopOp and $RemoveOp are scriptblock seams: production passes the real
    # stop core and the real task remover, tests pass fakes.
    # Rules (fail closed where it matters):
    # - The stop runs first. A stop result whose Data.Skipped is $true means
    #   "stop intentionally skipped (runtime not deployed)": Stopped stays
    #   $false and no error is recorded.
    # - A stop op that THROWS is caught and recorded exactly like a failed
    #   stop (Errors[0].Code = 'RuntimeStopFailed', Stopped = $false); it
    #   never skips the task removal (a task left behind would keep
    #   restarting the stack as SYSTEM after an uninstall).
    # - A failed, result-less or throwing stop does NOT block task removal:
    #   the removal still runs, Success stays $false, Stopped stays $false
    #   and the stop error stays FIRST in Errors.
    # - A throwing remover appends Code 'TaskRemovalFailed' and fails the
    #   result. TaskRemoved/TaskExisted come from the remover.
    param(
        [Parameter(Mandatory = $true)][scriptblock]$StopOp,
        [Parameter(Mandatory = $true)][scriptblock]$RemoveOp,
        [bool]$LockAbandoned = $false
    )
    $stopped = $false
    $stopSkipped = $false
    $failed = $false
    $errors = @()
    $stopOutcome = $null
    $stopThrew = $null
    try {
        $stopOutcome = & $StopOp
    } catch {
        $stopThrew = Get-GsUnwrappedException $_
    }
    $stopResult = $null
    if ($null -eq $stopThrew) { $stopResult = Get-GsResultFromOutput -Output $stopOutcome }
    if ($null -ne $stopThrew) {
        $failed = $true
        $errors = @([pscustomobject]@{
            Code = 'RuntimeStopFailed'
            Message = ('PrepareUninstall: the stop step threw: {0}' -f $stopThrew.Message)
            ExceptionType = $stopThrew.GetType().FullName
        })
    } elseif ($null -eq $stopResult) {
        $failed = $true
        $errors = @([pscustomobject]@{
            Code = 'RuntimeStopFailed'
            Message = 'PrepareUninstall: the stop step returned no structured result.'
        })
    } else {
        $skipped = $false
        if ($null -ne $stopResult.Data -and $stopResult.Data.PSObject.Properties['Skipped']) { $skipped = [bool]$stopResult.Data.Skipped }
        if ($skipped) {
            $stopSkipped = $true
        } elseif ($stopResult.Success) {
            $stopped = $true
        } else {
            $failed = $true
            $stopErrors = @($stopResult.Errors)
            if ($stopErrors.Count -eq 0) {
                $stopErrors = @([pscustomobject]@{
                    Code = 'RuntimeStopFailed'
                    Message = 'PrepareUninstall: the stop step reported failure.'
                })
            }
            $errors = $stopErrors
        }
    }
    $taskRemoved = $false
    $taskExisted = $false
    try {
        $removed = & $RemoveOp
        if ($null -ne $removed) {
            if ($removed.PSObject.Properties['TaskRemoved']) { $taskRemoved = [bool]$removed.TaskRemoved }
            if ($removed.PSObject.Properties['TaskExisted']) { $taskExisted = [bool]$removed.TaskExisted }
        }
    } catch {
        $ex = Get-GsUnwrappedException $_
        $failed = $true
        $errors = @($errors) + @([pscustomobject]@{
            Code = 'TaskRemovalFailed'
            Message = ('PrepareUninstall: removing the scheduled task failed: {0}' -f $ex.Message)
        })
    }
    return (New-Result (-not $failed) ([pscustomobject]@{
        Stopped           = $stopped
        TaskRemoved       = $taskRemoved
        TaskExisted       = $taskExisted
        StateDirKept      = $true
        LogDirKept        = $true
        StopSkippedReason = $(if ($stopSkipped) { 'RuntimeNotDeployed' } else { $null })
    }) $errors)
}
function Get-GsStatusFilePath {
    # The runtime status file location is not fixed. Prefer
    # <StateDir>\runtime\state\status.json (what the runtime writes on the
    # host); fall back to <StateDir>\status.json (the legacy layout path).
    # When both exist, the newer LastWriteTimeUtc wins. Returns $null when
    # neither file exists.
    param([Parameter(Mandatory = $true)]$Layout)
    $candidates = @(
        (Join-Path $Layout.StateDir 'runtime\state\status.json'),
        $Layout.StatusPath
    )
    $found = $null
    $foundWritten = [datetime]::MinValue
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $written = (Get-Item -LiteralPath $candidate).LastWriteTimeUtc
            if ($null -eq $found -or $written -gt $foundWritten) {
                $found = $candidate
                $foundWritten = $written
            }
        }
    }
    return $found
}
function Read-GsServerInfoBody {
    # Reads a response body in chunks until a total deadline measured from
    # the request start. Each chunk is an async ReadAsync bounded by
    # Wait(remaining): a server that trickles bytes - or never completes a
    # chunked body - cannot hold a single read open past the deadline even
    # when the stream's own read-timeout bookkeeping keeps being reset, and
    # the caller's Abort() then tears the socket down independently of the
    # framework's timers. A body over MaxBytes (counted in bytes, before
    # decoding; exactly MaxBytes bytes is still valid) is rejected as well.
    # Returns Body/TimedOut/TooLarge; the caller aborts the request on
    # TimedOut/TooLarge.
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$Clock,
        [Parameter(Mandatory = $true)][long]$DeadlineElapsedMs
    )
    $maxBytes = 64KB
    $buffer = New-Object byte[] 4096
    $stream = $null
    $memory = New-Object System.IO.MemoryStream
    try {
        $stream = $Response.GetResponseStream()
        while ($true) {
            $remainingMs = $DeadlineElapsedMs - $Clock.ElapsedMilliseconds
            if ($remainingMs -le 0) {
                return [pscustomobject]@{ Body = $null; TimedOut = $true; TooLarge = $false }
            }
            $readTask = $stream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait([int][Math]::Min($remainingMs, [int]::MaxValue))) {
                return [pscustomobject]@{ Body = $null; TimedOut = $true; TooLarge = $false }
            }
            # A faulted read (connection reset, abort) propagates to the
            # caller's catch exactly like a synchronous Read would.
            $read = $readTask.GetAwaiter().GetResult()
            if ($read -le 0) { break }
            if (($memory.Length + $read) -gt $maxBytes) {
                return [pscustomobject]@{ Body = $null; TimedOut = $false; TooLarge = $true }
            }
            $memory.Write($buffer, 0, $read)
        }
        return [pscustomobject]@{ Body = [System.Text.Encoding]::UTF8.GetString($memory.ToArray()); TimedOut = $false; TooLarge = $false }
    } finally {
        $memory.Dispose()
        if ($null -ne $stream) { try { $stream.Close() } catch { } }
    }
}
function Get-GsServerInfo {
    # Reads the GameStream HTTP serverinfo endpoint (plain HTTP only; never
    # the HTTPS 47984 endpoint). Returns Http (status code or $null),
    # CurrentGame (trimmed string or $null) and Error ($null on a clean
    # 200). The whole call is bounded by a total deadline of TimeoutSec from
    # the request start: the response is fetched with BeginGetResponse plus
    # a bounded AsyncWaitHandle wait and every body read is a bounded
    # ReadAsync wait, so any overrun aborts the request and reports
    # 'Timeout' without depending on the framework's own timers. Redirects
    # are not followed. A 200 body is validated strictly: a <root> document
    # element, a status_code attribute of 1-10 digits equal to 200, a
    # present non-empty <state>, and a currentgame of 1-10 digits. The
    # Recover gate additionally requires currentgame to be exactly '1'.
    # Never throws.
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSec = 3
    )
    $result = [pscustomobject]@{ Http = $null; CurrentGame = $null; Error = $null }
    $response = $null
    $request = $null
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $deadlineElapsedMs = [Math]::Max(1, $TimeoutSec) * 1000
    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Timeout = [int]$deadlineElapsedMs
        $request.ReadWriteTimeout = [int]$deadlineElapsedMs
        $request.Proxy = $null
        $request.KeepAlive = $false
        # Redirects are not followed: the gate must validate the endpoint
        # the operator pointed at, not wherever it redirects to.
        $request.AllowAutoRedirect = $false
        # Async begin + bounded wait: the wait (and therefore the abort
        # below) belongs to this call, not to the framework's timeout
        # bookkeeping.
        $pending = $request.BeginGetResponse($null, $null)
        $remainingMs = $deadlineElapsedMs - $clock.ElapsedMilliseconds
        if ($remainingMs -le 0 -or -not $pending.AsyncWaitHandle.WaitOne([int][Math]::Min($remainingMs, [int]::MaxValue))) {
            try { $request.Abort() } catch { }
            $result.Error = ('Timeout: serverinfo did not respond within {0}s' -f $TimeoutSec)
            return $result
        }
        $response = $request.EndGetResponse($pending)
        $result.Http = [int]$response.StatusCode
        # The shared validity rule requires HTTP EXACTLY 200, checked BEFORE
        # any body byte is read: a 201 (or any other 2xx that does not throw
        # in EndGetResponse) carrying valid XML must be rejected, not parsed.
        # >=400 and unfollowed redirects throw in EndGetResponse and are
        # handled by the catch below.
        if ($result.Http -ne 200) {
            try { $request.Abort() } catch { }
            $result.Error = ('HTTP status {0}: serverinfo must return exactly 200' -f $result.Http)
            return $result
        }
        $bodyRead = Read-GsServerInfoBody -Response $response -Clock $clock -DeadlineElapsedMs $deadlineElapsedMs
        if ($bodyRead.TimedOut) {
            try { $request.Abort() } catch { }
            $result.Error = ('Timeout: serverinfo body was not complete within {0}s' -f $TimeoutSec)
            return $result
        }
        if ($bodyRead.TooLarge) {
            try { $request.Abort() } catch { }
            $result.Error = 'BodyTooLarge: serverinfo body exceeds 64 KB'
            return $result
        }
        try {
            $xml = [xml]$bodyRead.Body
            $root = $xml.DocumentElement
            if ($null -eq $root -or $root.Name -cne 'root') {
                $result.Error = 'serverinfo response has no <root> root element'
            } else {
                $statusCodeAttribute = $null
                $statusAttribute = $root.Attributes['status_code']
                if ($null -ne $statusAttribute) { $statusCodeAttribute = $statusAttribute.Value }
                if ($null -eq $statusCodeAttribute) {
                    $result.Error = 'serverinfo XML has no numeric status_code attribute'
                } elseif ($statusCodeAttribute -notmatch '^\d{1,10}$') {
                    $result.Error = ('serverinfo XML status_code is not 1-10 digits: {0}' -f $statusCodeAttribute)
                } elseif ([int]$statusCodeAttribute -ne 200) {
                    $result.Error = ('serverinfo XML status_code is {0}, expected 200' -f ([int]$statusCodeAttribute))
                } else {
                    # SelectSingleNode returns the actual child node; the XML
                    # adapter (plain property access) would hand back a string
                    # for a text-only element and .InnerText would be empty.
                    $stateNode = $root.SelectSingleNode('state')
                    if ($null -eq $stateNode) {
                        $result.Error = 'serverinfo response has no state element'
                    } elseif (([string]$stateNode.InnerText).Trim().Length -eq 0) {
                        $result.Error = 'serverinfo state element is empty'
                    } else {
                        $node = $root.SelectSingleNode('currentgame')
                        if ($null -eq $node) {
                            $result.Error = 'serverinfo response has no currentgame element'
                        } else {
                            $currentGame = ([string]$node.InnerText).Trim()
                            if ($currentGame -notmatch '^\d{1,10}$') {
                                $result.Error = ('serverinfo currentgame is not numeric: {0}' -f $currentGame)
                            } else {
                                $result.CurrentGame = $currentGame
                            }
                        }
                    }
                }
            }
        } catch {
            $result.Error = ('serverinfo response is not valid XML: {0}' -f $_.Exception.Message)
        }
        return $result
    } catch {
        $ex = Get-GsUnwrappedException $_
        $webException = $ex -as [System.Net.WebException]
        if ($null -ne $webException -and $null -ne $webException.Response) {
            $httpResponse = $webException.Response -as [System.Net.HttpWebResponse]
            if ($null -ne $httpResponse) {
                $result.Http = [int]$httpResponse.StatusCode
                try { $httpResponse.Close() } catch { }
            }
        }
        $result.Error = ('{0}: {1}' -f $ex.GetType().FullName, $ex.Message)
        return $result
    } finally {
        if ($null -ne $response) { try { $response.Close() } catch { } }
    }
}
function Get-GsActiveClientConnectionCount {
    # Counts TCP connections in the Established state whose LOCAL port is one
    # of the client ports. Port 47989 is always excluded: the tray UI and
    # Diagnose poll it, so it is never a streaming client connection.
    # Invalid ports, or a port set that is empty after excluding 47989,
    # throw so that Recover refuses with ConnectionCheckFailed instead of
    # silently reporting zero connections.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][int[]]$Ports)
    foreach ($port in $Ports) {
        if ($port -lt 1 -or $port -gt 65535) {
            throw ('invalid client port: {0}' -f $port)
        }
    }
    $targets = @($Ports | Where-Object { $_ -ne 47989 })
    if ($targets.Count -eq 0) { throw 'no client ports to check' }
    $properties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $connections = $properties.GetActiveTcpConnections()
    $count = 0
    foreach ($connection in $connections) {
        if ($connection.State -ne [System.Net.NetworkInformation.TcpState]::Established) { continue }
        if ($targets -contains $connection.LocalEndPoint.Port) { $count++ }
    }
    return $count
}
function New-GsRecoverRefusal {
    param([string]$Reason, [string]$Message, $Observed)
    return (New-Result $false $null @([pscustomobject]@{
        Code = 'RecoverRefused'
        Reason = $Reason
        Message = $Message
        Observed = $Observed
    }))
}
function Get-GsOutboundAdapterSnapshot {
    # Read-only snapshot of the IPv4 send counters of every OPERATIONAL,
    # non-loopback adapter: a map of adapter id -> BytesSent. Read-only; it
    # changes nothing on the system.
    $map = @{ }
    foreach ($adapter in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        try {
            if ($adapter.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($adapter.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $stats = $adapter.GetIPv4Statistics()
            $map[[string]$adapter.Id] = [int64]$stats.BytesSent
        } catch { }
    }
    return $map
}
function Get-GsSendKbpsDelta {
    # Pure rate math over two snapshots: per-adapter max(0, after - before) -
    # a counter reset must never produce a negative contribution - summed and
    # converted to Kbps over the sample seconds. Adapters that appear only in
    # the after snapshot have no baseline and count 0.
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After,
        [Parameter(Mandatory = $true)][int]$Seconds
    )
    if ($Seconds -le 0) { throw 'the traffic sample length must be a positive number of seconds' }
    $totalDelta = [int64]0
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key)) { continue }
        $delta = [int64]$After[$key] - [int64]$Before[$key]
        if ($delta -gt 0) { $totalDelta += $delta }
    }
    $kbps = ($totalDelta * 8) / 1000.0 / $Seconds
    return [math]::Round($kbps, 3)
}
function Test-GsClientTrafficGate {
    # Recover gate 4: samples the host's outbound send rate for -SampleSec
    # seconds (0 disables the gate entirely) and reports whether the rate
    # exceeds -MaxIdleSendKbps. -Sampler is a test seam: production uses the
    # real adapter snapshot; tests inject counter sequences and never touch
    # the real adapters.
    param(
        [Parameter(Mandatory = $true)][int]$SampleSec,
        [Parameter(Mandatory = $true)][int]$MaxIdleSendKbps,
        [scriptblock]$Sampler
    )
    if ($SampleSec -le 0) {
        return [pscustomobject]@{ Detected = $false; RateKbps = $null }
    }
    if ($null -eq $Sampler) { $Sampler = { Get-GsOutboundAdapterSnapshot } }
    $before = & $Sampler
    Start-Sleep -Seconds $SampleSec
    $after = & $Sampler
    $rate = Get-GsSendKbpsDelta -Before $before -After $after -Seconds $SampleSec
    return [pscustomobject]@{ Detected = ($rate -gt $MaxIdleSendKbps); RateKbps = $rate }
}
function Invoke-GsLifecycleRecover {
    # Clears a stuck GameStream session: stop core then start core, exactly
    # once each, under one lock acquisition, and only after every safety gate
    # passes. Any gate that cannot run refuses the recovery (fail closed).
    # Pause flags: BOTH positions (canonical + legacy) are snapshotted BEFORE
    # any side effect; an unreadable pause flag (a directory shape, a locked
    # file) refuses the recovery with Reason 'PauseSnapshotFailed' before any
    # runtime script runs. Recover is NOT the operator's resume: after the
    # stop/start, every PRE-EXISTING flag is restored to its original bytes
    # (even when the runtime deleted or modified it), while ONLY the flag
    # THIS recover's stop step actually created is removed - a flag that
    # appeared without the product creating it (for example one the runtime
    # wrote itself) is left alone. Restore/removal failures in the finally
    # (which runs AFTER the result is built) append Code
    # 'RecoverCleanupFailed' and turn a successful result into a failure;
    # existing errors stay first.
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][int]$LockTimeoutSec,
        [Parameter(Mandatory = $true)][string]$ServerInfoUri,
        [Parameter(Mandatory = $true)][int]$ServerInfoTimeoutSec,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int[]]$ClientPorts,
        [Parameter(Mandatory = $true)][int]$StopSettleSec,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SupervisorTaskName,
        [Parameter(Mandatory = $true)][int]$TrafficSampleSec,
        [Parameter(Mandatory = $true)][int]$MaxIdleSendKbps
    )
    return (Invoke-WithLifecycleLock -StateDirPath $Layout.StateDir -TimeoutSec $LockTimeoutSec -Body {
        param([bool]$LockAbandoned)
        $context = @{ Snapshot = $null; StopCore = @{} }
        $result = $null
        try {
            $result = & {
                $observed = [pscustomobject]@{
                    StatusState          = $null
                    StatusPath           = $null
                    ServerInfoHttp       = $null
                    CurrentGame          = $null
                    ActiveConnections    = $null
                    ConnectionCheckScope = 'TcpOnly'
                    SendKbps             = $null
                }

                # --- Gate 1: runtime status (lookup + read + parse) ---
                $status = $null
                try {
                    $statusPath = Get-GsStatusFilePath -Layout $Layout
                    $observed.StatusPath = $statusPath
                    if ([string]::IsNullOrEmpty($statusPath)) {
                        return (New-GsRecoverRefusal -Reason 'StatusUnavailable' -Message ('No runtime status file found under {0}' -f $Layout.StateDir) -Observed $observed)
                    }
                    $status = [IO.File]::ReadAllText($statusPath) | ConvertFrom-Json
                } catch {
                    return (New-GsRecoverRefusal -Reason 'StatusUnavailable' -Message ('Runtime status file could not be read or parsed: {0}' -f $_.Exception.Message) -Observed $observed)
                }
                # The state field must be an actual JSON string: [string]
                # coercion would accept a one-element array, numbers and
                # other shapes that are not the runtime's contract. The root
                # must be an object too; a parsed-but-wrong root (for example
                # a JSON array) is NotReady - the file was found, read and
                # parsed, so it is not StatusUnavailable - with the same
                # type-failure message. No coerced value is reported in
                # Observed.
                $statusState = $null
                if ($null -ne $status -and $status -is [pscustomobject]) {
                    if ($status.PSObject.Properties['state']) {
                        $stateValue = $status.state
                        if ($stateValue -is [string]) { $statusState = $stateValue }
                    }
                }
                $observed.StatusState = $statusState
                if ($null -eq $statusState) {
                    if ($null -ne $status -and -not ($status -is [pscustomobject])) {
                        return (New-GsRecoverRefusal -Reason 'NotReady' -Message 'Runtime status root is not a JSON object; the state field is not a string.' -Observed $observed)
                    }
                    return (New-GsRecoverRefusal -Reason 'NotReady' -Message 'Runtime status state field is not a string (expected a string with value ready).' -Observed $observed)
                }
                if ([string]::IsNullOrWhiteSpace($statusState)) {
                    return (New-GsRecoverRefusal -Reason 'NotReady' -Message 'Runtime status has no usable state field (expected ready).' -Observed $observed)
                }
                if ($statusState -ine 'ready') {
                    return (New-GsRecoverRefusal -Reason 'NotReady' -Message ('Runtime status state is {0}, not ready; refusing to recover.' -f $statusState) -Observed $observed)
                }

                # --- Gate 2: GameStream serverinfo (HTTP 200 + currentgame = 1) ---
                $info = Get-GsServerInfo -Uri $ServerInfoUri -TimeoutSec $ServerInfoTimeoutSec
                $observed.ServerInfoHttp = $info.Http
                $observed.CurrentGame = $info.CurrentGame
                if ($info.Http -ne 200) {
                    $detail = 'request failed'
                    if (-not [string]::IsNullOrEmpty($info.Error)) { $detail = $info.Error }
                    return (New-GsRecoverRefusal -Reason 'ServerInfoUnavailable' -Message ('serverinfo did not return HTTP 200 ({0}).' -f $detail) -Observed $observed)
                }
                if (-not [string]::IsNullOrEmpty($info.Error) -or [string]::IsNullOrEmpty($info.CurrentGame)) {
                    return (New-GsRecoverRefusal -Reason 'ServerInfoUnavailable' -Message ('serverinfo returned HTTP 200 but could not be read: {0}' -f $info.Error) -Observed $observed)
                }
                if ($info.CurrentGame -cne '1') {
                    return (New-GsRecoverRefusal -Reason 'NoStuckSession' -Message ('serverinfo currentgame is {0}; a stuck session (currentgame=1) is required to recover.' -f $info.CurrentGame) -Observed $observed)
                }

                # --- Gate 3: no active client connections ---
                try {
                    $activeConnections = Get-GsActiveClientConnectionCount -Ports $ClientPorts
                    $observed.ActiveConnections = $activeConnections
                } catch {
                    return (New-GsRecoverRefusal -Reason 'ConnectionCheckFailed' -Message ('Active client connection check failed: {0}' -f $_.Exception.Message) -Observed $observed)
                }
                if ($activeConnections -gt 0) {
                    return (New-GsRecoverRefusal -Reason 'ClientConnected' -Message ('{0} active client connection(s) detected; refusing to recover.' -f $activeConnections) -Observed $observed)
                }

                # --- Gate 4: outbound traffic (best-effort live-client check) ---
                # The TCP check above cannot see GameStream's UDP video/audio/
                # input streams, so a short sample of the host's outbound send
                # rate is the last chance to catch a live client before the
                # stop/start. Other processes' traffic can also trip it; when
                # in doubt, refuse (prefer safe).
                if ($TrafficSampleSec -gt 0) {
                    $traffic = Test-GsClientTrafficGate -SampleSec $TrafficSampleSec -MaxIdleSendKbps $MaxIdleSendKbps
                    $observed.SendKbps = $traffic.RateKbps
                    if ($traffic.Detected) {
                        return (New-GsRecoverRefusal -Reason 'ClientTrafficDetected' -Message ('Outbound send rate {0} Kbps exceeds the provisional idle threshold {1} Kbps; refusing to recover in case a client is streaming.' -f $traffic.RateKbps, $MaxIdleSendKbps) -Observed $observed)
                    }
                }

                # --- Gates passed: snapshot the pause flags, then stop core,
                # then start core, exactly once each ---
                # The snapshot is recorded on $context (BEFORE any side
                # effect: the stop step below creates the canonical flag) so
                # the finally outside this scriptblock can restore the
                # pre-Recover state after the result is built.
                try { $context.Snapshot = Get-GsPauseFlagSnapshot -Layout $Layout } catch {
                    return (New-GsRecoverRefusal -Reason 'PauseSnapshotFailed' -Message ('Recover refused before running any runtime script: the supervisor pause flags could not be read: {0}' -f $_.Exception.Message) -Observed $observed)
                }
                $stopExitCode = $null
                $startExitCode = $null
                $stopOutcome = $null
                $stopThrewMessage = $null
                try {
                    $stopOutcome = Invoke-GsRuntimeStopCore -Layout $Layout -StopSettleSec $StopSettleSec -SupervisorTaskName $SupervisorTaskName -LockAbandoned $LockAbandoned -PauseOperationContext $context.StopCore
                } catch {
                    $stopThrewMessage = ('Recover stopped early: the stop step threw: {0}' -f $_.Exception.Message)
                }
                # Ownership record, right after the stop attempt (also when
                # it threw): the stop core recorded, INTO $context.StopCore
                # and at the moment it actually wrote the canonical flag,
                # whether THIS call created it. ONLY such a core-created
                # canonical flag is cleaned up in the finally. The LEGACY
                # position is NEVER claimed by an appearance after the stop:
                # the stop core never creates a legacy flag, so a flag that
                # appears there during the stop was written by the black box
                # or by the supervisor - which does NOT take the product
                # mutex - and removing it could kill a pause this product
                # never owned.
                $context.Snapshot.Canonical.CreatedByThisOperation = [bool]((-not $context.Snapshot.Canonical.Exists) -and $context.StopCore.ContainsKey('CanonicalCreatedByThisStopCore'))
                $context.Snapshot.Legacy.CreatedByThisOperation = $false
                if ($null -ne $stopThrewMessage) {
                    return (New-Result $false ([pscustomobject]@{ LockAbandoned = $LockAbandoned; StopExitCode = $null; StartExitCode = $null; Observed = $observed }) @([pscustomobject]@{
                        Code = 'RecoverStopFailed'
                        Message = $stopThrewMessage
                    }))
                }
                $stopResult = Get-GsResultFromOutput -Output $stopOutcome
                if ($null -eq $stopResult) {
                    return (New-Result $false ([pscustomobject]@{ LockAbandoned = $LockAbandoned; StopExitCode = $null; StartExitCode = $null; Observed = $observed }) @([pscustomobject]@{
                        Code = 'RecoverStopFailed'
                        Message = 'Recover stopped early: the stop step returned no structured result; start was not attempted.'
                    }))
                }
                $stopExitCode = $stopResult.Data.ExitCode
                if (-not $stopResult.Success) {
                    return (New-Result $false ([pscustomobject]@{ LockAbandoned = $LockAbandoned; StopExitCode = $stopExitCode; StartExitCode = $null; Observed = $observed }) @([pscustomobject]@{
                        Code = 'RecoverStopFailed'
                        Message = ('Recover stopped early: the stop step reported failure (exit code {0}); start was not attempted.' -f $stopExitCode)
                    }))
                }
                try {
                    $startOutcome = Invoke-GsRuntimeStartCore -Layout $Layout -LockAbandoned $LockAbandoned
                    $startResult = Get-GsResultFromOutput -Output $startOutcome
                    if ($null -eq $startResult) {
                        return (New-Result $false ([pscustomobject]@{ LockAbandoned = $LockAbandoned; StopExitCode = $stopExitCode; StartExitCode = $null; Observed = $observed }) @([pscustomobject]@{
                            Code = 'RecoverStartFailed'
                            Message = 'Recover: the start step returned no structured result.'
                        }))
                    }
                    $startExitCode = $startResult.Data.ExitCode
                    if (-not $startResult.Success) {
                        return (New-Result $false ([pscustomobject]@{ LockAbandoned = $LockAbandoned; StopExitCode = $stopExitCode; StartExitCode = $startExitCode; Observed = $observed }) @([pscustomobject]@{
                            Code = 'RecoverStartFailed'
                            Message = ('Recover: the start step reported failure (exit code {0}).' -f $startExitCode)
                        }))
                    }
                    return (New-Result $true ([pscustomobject]@{ LockAbandoned = $LockAbandoned; StopExitCode = $stopExitCode; StartExitCode = $startExitCode; Observed = $observed }) @())
                } catch {
                    return (New-Result $false ([pscustomobject]@{ LockAbandoned = $LockAbandoned; StopExitCode = $stopExitCode; StartExitCode = $null; Observed = $observed }) @([pscustomobject]@{
                        Code = 'RecoverStartFailed'
                        Message = ('Recover: the start step threw: {0}' -f $_.Exception.Message)
                    }))
                }
            }
        } finally {
            # Restore the pause flags to their pre-Recover state AFTER the
            # result is built, per position and by ownership:
            # - A position that EXISTED before Recover is restored to its
            #   original bytes, even when the runtime start deleted or
            #   modified it (the snapshot was taken before any side effect);
            #   an unchanged flag is left untouched.
            # - A position that did NOT exist before is cleaned up ONLY when
            #   THIS recover's stop step created the flag
            #   (CreatedByThisOperation). A flag that appeared without the
            #   product creating it - for example one the runtime start wrote
            #   itself - is left alone: it may be the runtime deliberately
            #   staying paused, and Recover is not the operator's resume.
            # A restore/removal failure appends Code 'RecoverCleanupFailed'
            # (existing errors stay first) and turns a successful result into
            # a failure: a stale pause flag would pause the next supervisor
            # cycle, and a lost pre-existing pause would silently resume it -
            # neither may be reported as success.
            $cleanupErrors = @()
            $snapshot = $context.Snapshot
            if ($null -ne $snapshot) {
                foreach ($entry in @($snapshot.Canonical, $snapshot.Legacy)) {
                    if ($entry.Exists) {
                        $restored = Restore-GsPauseFlagEntry -Entry $entry
                        if ($restored.Outcome -eq 'Failed') {
                            $cleanupErrors += @([pscustomobject]@{
                                Code    = 'RecoverCleanupFailed'
                                Action  = 'restore'
                                Message = ('Recover could not restore the supervisor pause flag that existed before the recovery: {0}: {1}' -f $restored.Path, $restored.Error)
                                Path    = $restored.Path
                            })
                        }
                    } elseif ($entry.CreatedByThisOperation) {
                        $removed = Remove-GsPauseFlagFile -Path $entry.Path
                        if ($removed.Outcome -eq 'Failed') {
                            $cleanupErrors += @([pscustomobject]@{
                                Code    = 'RecoverCleanupFailed'
                                Action  = 'remove'
                                Message = ('Recover could not remove the supervisor pause flag it created: {0}: {1}' -f $removed.Path, $removed.Error)
                                Path    = $removed.Path
                            })
                        }
                    }
                }
            }
            foreach ($cleanupError in $cleanupErrors) {
                if ($null -eq $result) {
                    $result = (New-Result $false $null @($cleanupError))
                } else {
                    $result = (New-Result $false $result.Data (@($result.Errors) + @($cleanupError)))
                }
            }
        }
        return $result
    })
}

function Invoke-GsStatusAction {
    # Reads the runtime status for -Action Status. Never takes the lock.
    # Both the status path lookup and the read/parse happen inside the try:
    # a lookup that throws (for example a state directory whose path cannot
    # be probed at all) is the same structured StatusReadFailed as an
    # unreadable or malformed file, never an unhandled throw.
    param([Parameter(Mandatory = $true)]$Layout)
    $statusPath = $null
    try {
        $statusPath = Get-GsStatusFilePath -Layout $Layout
        if ($null -eq $statusPath) {
            return (New-Result $false $null @([pscustomobject]@{ Code = 'NotInstalled'; Message = 'No runtime status file.' }))
        }
        $status = [IO.File]::ReadAllText($statusPath) | ConvertFrom-Json
    } catch {
        return (New-Result $false $null @([pscustomobject]@{
            Code = 'StatusReadFailed'
            Message = ('Runtime status file could not be read or parsed: {0}' -f $_.Exception.Message)
            Path = $statusPath
        }))
    }
    return (New-Result $true $status @())
}

# Diagnose runs BEFORE the module imports: a broken or missing module
# manifest must not stop the one action an operator needs to investigate a
# broken install. It never takes the lock.
if ($Action -eq 'Diagnose') {
    $diagnoseScript = $DiagnoseScript
    if ([string]::IsNullOrWhiteSpace($diagnoseScript)) {
        # $PSScriptRoot is empty in parameter defaults under
        # powershell.exe -File, so resolve the default here in the body.
        $scriptDir = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
        if (-not [string]::IsNullOrWhiteSpace($scriptDir)) { $diagnoseScript = Join-Path $scriptDir 'gs-diagnose.ps1' }
    }
    if ([string]::IsNullOrWhiteSpace($diagnoseScript) -or -not (Test-Path -LiteralPath $diagnoseScript -PathType Leaf)) {
        return (New-Result $false $null @([pscustomobject]@{
            Code = 'DiagnoseUnavailable'
            Message = ('gs-diagnose.ps1 not found at {0}' -f $diagnoseScript)
        }))
    }
    try {
        # A diagnose script that runs native tools inherits their
        # $LASTEXITCODE; reset it so the exit-code check reflects this run.
        $global:LASTEXITCODE = 0
        $report = & $diagnoseScript -InstallDir $InstallDir -StateDir $StateDir -LogDir $LogDir -ServerInfoUri $ServerInfoUri
        $diagnoseExitCode = $global:LASTEXITCODE
        if ($diagnoseExitCode -ne 0) {
            return (New-Result $false $null @([pscustomobject]@{
                Code = 'DiagnoseFailed'
                Message = ('gs-diagnose.ps1 exited {0}.' -f $diagnoseExitCode)
                ExitCode = $diagnoseExitCode
            }))
        }
        # The report must be the LAST output element (the tray reads the
        # last element, so trailing output would be mistaken for it) and
        # must declare schemaVersion 1; anything else is an unexpected
        # report, not a trusted result.
        $reportItems = @($report)
        $reportObject = $null
        if ($reportItems.Count -gt 0 -and $reportItems[$reportItems.Count - 1] -is [pscustomobject]) {
            $reportObject = $reportItems[$reportItems.Count - 1]
        }
        $schemaVersionProperty = $null
        if ($null -ne $reportObject) { $schemaVersionProperty = $reportObject.PSObject.Properties['schemaVersion'] }
        if ($null -eq $schemaVersionProperty -or ([string]$schemaVersionProperty.Value) -ne '1') {
            return (New-Result $false $null @([pscustomobject]@{
                Code = 'DiagnoseFailed'
                Message = 'Unexpected report: gs-diagnose.ps1 must return a report object as the last output element with schemaVersion 1.'
            }))
        }
        return (New-Result $true $reportObject @())
    } catch {
        return (New-Result $false $null @([pscustomobject]@{
            Code = 'DiagnoseFailed'
            Message = ('gs-diagnose.ps1 failed: {0}' -f $_.Exception.Message)
            ExceptionType = $_.Exception.GetType().FullName
        }))
    }
}

foreach ($module in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
    $manifest = Join-Path $ModuleRoot (Join-Path $module ($module + '.psd1'))
    if (-not (Test-Path -LiteralPath $manifest)) { throw "Missing module manifest: $manifest" }
    Import-Module $manifest -Force
}

switch ($Action) {
    'Install' {
        if ([string]::IsNullOrWhiteSpace($ComponentSourceDir)) { throw '-ComponentSourceDir is required for Install' }
        if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
            if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
            $CatalogPath = Join-Path $StateDir 'component-catalog.json'
            $generated = New-GsComponentCatalog -ComponentSourceDir $ComponentSourceDir -CatalogPath $CatalogPath -Force
            if (-not $generated.Success) { return (New-Result $false $null $generated.Errors) }
        }
        $layout = Get-RuntimeLayout
        if (-not $layout.Success) { return (New-Result $false $null $layout.Errors) }
        $tree = Import-GsRuntimeTree -Layout $layout.Layout -ComponentSourceDir $ComponentSourceDir -Force
        if (-not $tree.Success) { return (New-Result $false $null $tree.Errors) }
        $bundle = Install-GsRuntimeBundle -Layout $layout.Layout -HelperSourceDir $HelperSourceDir -Force
        if (-not $bundle.Success) { return (New-Result $false $null $bundle.Errors) }
        $plan = New-GsRuntimePlan -Layout $layout.Layout -CatalogPath $CatalogPath
        if (-not $plan.Success) { return (New-Result $false $null $plan.Errors) }
        Write-JsonFile (Join-Path $StateDir 'runtime-plan.json') $plan.Plan
        return (New-Result $true ([pscustomobject]@{
            InstallDir = $layout.Layout.InstallDir
            StateDir   = $layout.Layout.StateDir
            RuntimeDir = $layout.Layout.RuntimeDir
            Roles      = @($plan.Plan.Roles).Count
        }) @())
    }
    'CreateCatalog' {
        if ([string]::IsNullOrWhiteSpace($ComponentSourceDir)) { throw '-ComponentSourceDir is required for CreateCatalog' }
        if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = Join-Path $StateDir 'component-catalog.json' }
        $generated = New-GsComponentCatalog -ComponentSourceDir $ComponentSourceDir -CatalogPath $CatalogPath -Force
        if (-not $generated.Success) { return (New-Result $false $null $generated.Errors) }
        return (New-Result $true $generated.Plan @())
    }
    'Check' {
        $layout = Get-RuntimeLayout
        if (-not $layout.Success) { return (New-Result $false $null $layout.Errors) }
        $errors = @()
        $layoutCheck = Test-GsRuntimeLayout -Layout $layout.Layout
        if (-not $layoutCheck.Success) { $errors += $layoutCheck.Errors }
        $bundleCheck = Test-GsRuntimeBundle -Layout $layout.Layout
        if (-not $bundleCheck.Success) { $errors += $bundleCheck.Errors }
        if (-not [string]::IsNullOrWhiteSpace($CatalogPath)) {
            $plan = New-GsRuntimePlan -Layout $layout.Layout -CatalogPath $CatalogPath
            if (-not $plan.Success) { $errors += $plan.Errors }
        }
        return (New-Result ($errors.Count -eq 0) ([pscustomobject]@{ RuntimeDir = $layout.Layout.RuntimeDir }) $errors)
    }
    'Start' {
        $layout = Get-RuntimeLayout
        if (-not $layout.Success) { return (New-Result $false $null $layout.Errors) }
        return (Invoke-WithLifecycleLock -StateDirPath $layout.Layout.StateDir -TimeoutSec $LockTimeoutSec -Body {
            param([bool]$LockAbandoned)
            # Explicit manual Start is the operator's resume of the
            # auto-guard. Policy, in one place and under the lock:
            # 1. Snapshot BOTH pause-flag positions BEFORE anything happens.
            #    An unreadable pause flag (a directory shape, a locked file)
            #    refuses the start with PauseSnapshotFailed BEFORE the
            #    runtime start script runs - without the bytes neither
            #    restore-on-failure nor a safe cleanup can be guaranteed.
            # 2. The runtime start script is known to delete an existing
            #    pause flag, so on a FAILED start every PRE-EXISTING flag is
            #    restored from the snapshot with its original bytes
            #    (RuntimeStartFailed stays the first error; a failed restore
            #    appends PauseRestoreFailed). A flag that APPEARED during the
            #    failed start is NOT deleted - it may be the runtime
            #    deliberately staying paused. The flags are never cleared
            #    before the start runs, so no new pause-free start window is
            #    created, and a failed start never silently loses the
            #    previous pause state.
            # 3. On a SUCCESSFUL start the pause flags are cleared at BOTH
            #    positions (canonical + legacy, whoever wrote them); a flag
            #    that cannot be removed fails the result with
            #    PauseCleanupFailed instead of reporting success - a flag
            #    left behind would keep the supervisor paused after an
            #    explicit resume.
            $snapshot = $null
            try { $snapshot = Get-GsPauseFlagSnapshot -Layout $layout.Layout } catch {
                return (New-Result $false ([pscustomobject]@{ ExitCode = $null; LockAbandoned = $LockAbandoned }) @([pscustomobject]@{
                    Code = 'PauseSnapshotFailed'
                    Message = ('Start refused before running the runtime: the supervisor pause flags could not be read: {0}' -f $_.Exception.Message)
                    ExceptionType = $_.Exception.GetType().FullName
                }))
            }
            $startOutcome = Invoke-GsRuntimeStartCore -Layout $layout.Layout -LockAbandoned $LockAbandoned
            # The start core streams the black-box script's output first; the
            # product's structured result is its LAST element with a Success
            # property (exactly what Get-GsResultFromOutput picks). Re-emit
            # EVERYTHING before that element in the original order - INCLUDING
            # any objects the runtime itself emitted: the contract fixes only
            # the LAST Success object as the product result, so a runtime
            # object carrying Success = $true must survive - and then the
            # final result object; the tray parses the LAST element.
            $startItems = @($startOutcome)
            $productResultIndex = -1
            for ($i = $startItems.Count - 1; $i -ge 0; $i--) {
                $item = $startItems[$i]
                if ($null -ne $item -and $item -is [pscustomobject] -and $null -ne $item.PSObject.Properties['Success']) { $productResultIndex = $i; break }
            }
            $emitUpTo = $startItems.Count
            if ($productResultIndex -ge 0) { $emitUpTo = $productResultIndex }
            for ($i = 0; $i -lt $emitUpTo; $i++) {
                if ($null -ne $startItems[$i]) { $startItems[$i] }
            }
            $startResult = Get-GsResultFromOutput -Output $startOutcome
            $startExitCode = $null
            if ($null -ne $startResult -and $null -ne $startResult.Data -and $startResult.Data.PSObject.Properties['ExitCode']) { $startExitCode = $startResult.Data.ExitCode }
            $startData = [pscustomobject]@{ ExitCode = $startExitCode; LockAbandoned = $LockAbandoned }
            if ($null -eq $startResult -or -not $startResult.Success) {
                $startErrors = @()
                if ($null -eq $startResult) {
                    $startErrors = @([pscustomobject]@{ Code = 'RuntimeStartFailed'; Message = 'Start failed: the runtime start script returned no structured result.' })
                } else {
                    $startErrors = @($startResult.Errors)
                    if ($startErrors.Count -eq 0) {
                        $startErrors = @([pscustomobject]@{ Code = 'RuntimeStartFailed'; Message = 'Start failed: the runtime start script reported failure without an error entry.' })
                    }
                }
                $restoreErrors = @()
                foreach ($entry in @($snapshot.Canonical, $snapshot.Legacy)) {
                    $restored = Restore-GsPauseFlagEntry -Entry $entry
                    if ($restored.Outcome -eq 'Failed') {
                        $restoreErrors += @([pscustomobject]@{
                            Code = 'PauseRestoreFailed'
                            Message = ('Start failed and the previous supervisor pause flag at {0} could not be restored: {1}' -f $restored.Path, $restored.Error)
                            Path = $restored.Path
                        })
                    }
                }
                return (New-Result $false $startData (@($startErrors) + $restoreErrors))
            }
            $cleanupErrors = @()
            foreach ($entry in @($snapshot.Canonical, $snapshot.Legacy)) {
                $removed = Remove-GsPauseFlagFile -Path $entry.Path
                if ($removed.Outcome -eq 'Failed') {
                    $cleanupErrors += @([pscustomobject]@{
                        Code = 'PauseCleanupFailed'
                        Message = ('The runtime started but the supervisor pause flag at {0} could not be removed; the supervisor may stay paused: {1}' -f $removed.Path, $removed.Error)
                        Path = $removed.Path
                    })
                }
            }
            if ($cleanupErrors.Count -gt 0) { return (New-Result $false $startData $cleanupErrors) }
            return (New-Result $true $startData @())
        })
    }
    'Stop' {
        $layout = Get-RuntimeLayout
        if (-not $layout.Success) { return (New-Result $false $null $layout.Errors) }
        return (Invoke-WithLifecycleLock -StateDirPath $layout.Layout.StateDir -TimeoutSec $LockTimeoutSec -Body {
            param([bool]$LockAbandoned)
            return (Invoke-GsRuntimeStopCore -Layout $layout.Layout -StopSettleSec $StopSettleSec -SupervisorTaskName $SupervisorTaskName -LockAbandoned $LockAbandoned)
        })
    }
    'Recover' {
        $layout = Get-RuntimeLayout
        if (-not $layout.Success) { return (New-Result $false $null $layout.Errors) }
        return (Invoke-GsLifecycleRecover -Layout $layout.Layout -LockTimeoutSec $LockTimeoutSec -ServerInfoUri $ServerInfoUri -ServerInfoTimeoutSec $ServerInfoTimeoutSec -ClientPorts $ClientPorts -StopSettleSec $StopSettleSec -SupervisorTaskName $SupervisorTaskName -TrafficSampleSec $TrafficSampleSec -MaxIdleSendKbps $MaxIdleSendKbps)
    }
    'Status' {
        $layout = Get-RuntimeLayout
        if (-not $layout.Success) { return (New-Result $false $null $layout.Errors) }
        return (Invoke-GsStatusAction -Layout $layout.Layout)
    }
    'RegisterAutostart' {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin) { throw 'RegisterAutostart requires elevation' }
        $layout = Get-RuntimeLayout
        if (-not $layout.Success) { return (New-Result $false $null $layout.Errors) }
        $supervisor = Join-Path $layout.Layout.RuntimeBinDir 'gs_supervisor.ps1'
        if (-not (Test-Path -LiteralPath $supervisor)) { throw "Runtime supervisor missing: $supervisor" }
        $taskName = 'GsControllerSupervisor'
        $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $supervisor + '" -Cycle')
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $triggers = @(
            (New-ScheduledTaskTrigger -AtStartup),
            (New-ScheduledTaskTrigger -AtLogOn),
            (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5))
        )
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
        $task = Get-ScheduledTask -TaskName $taskName
        return (New-Result $true ([pscustomobject]@{ TaskName = $taskName; State = $task.State; Script = $supervisor }) @())
    }
    'UnregisterAutostart' {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin) { throw 'UnregisterAutostart requires elevation' }
        $taskName = 'GsControllerSupervisor'
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
        return (New-Result $true ([pscustomobject]@{ TaskName = $taskName; Removed = [bool]$task }) @())
    }
    'PrepareUninstall' {
        # Uninstall preparation, fail closed:
        # 1. Decide first whether a task will be removed at all
        #    (-SupervisorTaskName non-empty). Only then ask whether we are
        #    elevated; if not (or the -AssumeNotElevated seam is set), return
        #    ElevationRequired and run NOTHING - no layout read, no lock, no
        #    stop, no task query.
        # 2. Under the lifecycle lock: stop the runtime (reusing the same stop
        #    core as -Action Stop) unless the runtime is not deployed
        #    (gs_stop_private.ps1 missing from the layout's RuntimeBinDir) -
        #    then the stop is skipped and recorded (StopSkippedReason).
        # 3. Remove the named task when one was named (Invoke-GsTaskRemovalOutcome):
        #    only the provider's specific "task not found" outcome is a
        #    confirmed absence (TaskRemoved = TaskExisted = $false); any other
        #    lookup error is a TaskRemovalFailed failure, never a silent pass.
        # StateDir, LogDir and the pause flags are never deleted here.
        $willRemoveTask = -not [string]::IsNullOrWhiteSpace($SupervisorTaskName)
        if ($willRemoveTask) {
            if (-not (Test-GsPrepareUninstallElevation -AssumeNotElevated:$AssumeNotElevated)) {
                return (New-Result $false $null @([pscustomobject]@{
                    Code = 'ElevationRequired'
                    Message = ('PrepareUninstall requires elevation because the scheduled task {0} would be removed; nothing was run.' -f $SupervisorTaskName)
                    TaskName = $SupervisorTaskName
                }))
            }
        }
        $layout = Get-RuntimeLayout
        if (-not $layout.Success) { return (New-Result $false $null $layout.Errors) }
        $stopScriptPath = Join-Path $layout.Layout.RuntimeBinDir 'gs_stop_private.ps1'
        $runtimeDeployed = (Test-Path -LiteralPath $stopScriptPath -PathType Leaf)
        return (Invoke-WithLifecycleLock -StateDirPath $layout.Layout.StateDir -TimeoutSec $LockTimeoutSec -Body {
            param([bool]$LockAbandoned)
            $stopOp = {
                if (-not $runtimeDeployed) {
                    return (New-Result $true ([pscustomobject]@{ ExitCode = $null; LockAbandoned = $LockAbandoned; Skipped = $true }) @())
                }
                return (Invoke-GsRuntimeStopCore -Layout $layout.Layout -StopSettleSec $StopSettleSec -SupervisorTaskName $SupervisorTaskName -LockAbandoned $LockAbandoned)
            }
            $removeOp = {
                # The lookup/removal decision lives in one function with
                # injectable seams: only the provider's specific "not found"
                # outcome counts as absent; any other lookup error surfaces
                # as TaskRemovalFailed (never as a confirmed absence).
                Invoke-GsTaskRemovalOutcome -TaskName $SupervisorTaskName -WillRemoveTask:$willRemoveTask
            }
            return (Invoke-GsPrepareUninstallSteps -StopOp $stopOp -RemoveOp $removeOp -LockAbandoned $LockAbandoned)
        })
    }
}
