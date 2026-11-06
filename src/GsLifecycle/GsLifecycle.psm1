Set-StrictMode -Version Latest

# Stage 1 path normalization is reused, never re-implemented.
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'GsControl\GsControl.psd1') -ErrorAction Stop

$script:ConfigSchemaVersion = 1
$script:StateSchemaVersion  = 1
$script:StateFileName       = 'lifecycle-state.json'
$script:LockFileName        = 'lifecycle.lock'
$script:CorruptBackupSuffix = '.corrupt'

$script:States = @('Stopped', 'Starting', 'Running', 'Stopping', 'Failed', 'Paused')
$script:TestWriteFault = $null

# PowerShell try/catch cannot stop break/continue/exit: FlowControlException
# is not catchable from script, and labeled break/continue pass through any
# guard loop. This in-memory helper catches them at the .NET level so an
# injected operation can never unwind through Start/Stop to the caller.
if (-not ('GsLifecycle.Internal.OperationInvoker' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System.Collections.ObjectModel;
using System.Management.Automation;
namespace GsLifecycle.Internal {
    public sealed class OperationRun {
        public Collection<PSObject> Output;
        public string FlowControl;
    }
    public static class OperationInvoker {
        public static OperationRun Run(ScriptBlock wrapper, object[] args) {
            var run = new OperationRun();
            try {
                run.Output = wrapper.Invoke(args);
            } catch (FlowControlException e) {
                run.FlowControl = e.GetType().FullName;
                run.Output = new Collection<PSObject>();
            }
            return run;
        }
    }
}
'@
}

# Defined at module scope so it runs in the module's session state. The inner
# block merges the error stream (2>&1) into the output.
$script:OperationWrapper = {
    param($op, $v, $c)
    & { param($op, $v, $c) $op.InvokeWithContext($null, $v, @(, $c)) } $op $v $c 2>&1
}

# The only legal transitions. Anything else is rejected.
$script:Transitions = [ordered]@{
    Stopped  = @('Starting', 'Paused')
    Starting = @('Running', 'Failed')
    Running  = @('Stopping', 'Failed')
    Stopping = @('Stopped')
    Failed   = @('Starting', 'Stopping')
    Paused   = @('Starting')
}

# \A and \z: '$' would also accept a trailing newline.
$script:ErrorCodePattern      = '\A[A-Za-z][A-Za-z0-9_.]{0,63}\z'

# Targets that claim something about the real system. They may only be
# written by Start-GsLifecycle / Stop-GsLifecycle around an injected
# operation, never directly through Invoke-GsLifecycleTransition.
$script:OperationTargets = @('Starting', 'Running', 'Stopping', 'Stopped')
$script:SensitiveKeyPattern   = '(?i)(pass(word|wd|phrase)?|pwd|secret|token|key|credential|cred|pin|cert|private|auth|cookie|session|sid)'
$script:MaxDiagnosticDepth    = 4
$script:MaxDiagnosticEntries  = 50
$script:MaxDiagnosticString   = 1024

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

function New-GsError {
    param([string]$Code, [string]$Field, [string]$Message)
    [pscustomobject]@{ Code = $Code; Field = $Field; Message = $Message }
}

function Get-GsUtcNow {
    return [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-GsUtcTimestamp {
    param($Value)
    if (-not ($Value -is [string])) { return $false }
    $parsed = [DateTime]::MinValue
    return [DateTime]::TryParseExact($Value, 'o', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -and $parsed.Kind -eq [DateTimeKind]::Utc
}

function Test-GsHasProperty {
    param($Object, [string]$Name)
    return (@($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

# ---------------------------------------------------------------------------
# InstallationConfig
# ---------------------------------------------------------------------------

function Resolve-GsConfigDirectory {
    # Returns @{ Path = <normalized or $null>; Error = <error or $null> }.
    param($Value, [string]$Field)

    if ($null -eq $Value) {
        return @{ Path = $null; Error = (New-GsError 'EmptyPath' $Field "$Field must not be null.") }
    }
    if (-not ($Value -is [string])) {
        return @{ Path = $null; Error = (New-GsError 'InvalidType' $Field "$Field must be a string.") }
    }
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{ Path = $null; Error = (New-GsError 'EmptyPath' $Field "$Field must not be empty or whitespace.") }
    }
    try {
        # An absolute path ignores BasePath, so two different bases give the
        # same result only for absolute input. This classifies without
        # duplicating the stage-1 path rules.
        $a = Resolve-GsPath -Path $Value -BasePath 'C:\GsAbsCheckA'
        $b = Resolve-GsPath -Path $Value -BasePath 'D:\GsAbsCheckB'
    } catch [System.ArgumentException] {
        return @{ Path = $null; Error = (New-GsError 'InvalidPath' $Field "$Field is not a valid path: $($_.Exception.Message)") }
    }
    if (-not [string]::Equals($a, $b, [StringComparison]::Ordinal)) {
        return @{ Path = $null; Error = (New-GsError 'NotAbsolute' $Field "$Field must be an absolute path: '$Value'.") }
    }
    return @{ Path = $a; Error = $null }
}

function Get-GsComparablePath {
    param([string]$Path)
    return $Path.TrimEnd([char[]]@('\', '/'))
}

function Test-GsPathContains {
    # True when $Child equals $Parent or lies below it (case-insensitive).
    param([string]$Parent, [string]$Child)
    $p = Get-GsComparablePath $Parent
    $c = Get-GsComparablePath $Child
    if ([string]::Equals($p, $c, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
}

function New-GsConfigResult {
    param([string]$Path, $Config, [object[]]$Errors)
    $errs = @($Errors)
    [pscustomobject]@{
        Success = ($errs.Count -eq 0)
        Path    = $Path
        Config  = $(if ($errs.Count -eq 0) { $Config } else { $null })
        Errors  = $errs
    }
}

function Test-GsInstallationConfig {
    <#
    .SYNOPSIS
        Validates installation, state and log directories. Pure; touches no file system.
    .OUTPUTS
        PSCustomObject: Success, Path ($null), Config (InstallDir, StateDir, LogDir), Errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()]$InstallDir,
        [Parameter()][AllowNull()][AllowEmptyString()]$StateDir,
        [Parameter()][AllowNull()][AllowEmptyString()]$LogDir
    )

    $errors = New-Object System.Collections.Generic.List[object]
    $fields = [ordered]@{ installDir = $InstallDir; stateDir = $StateDir; logDir = $LogDir }
    $resolved = [ordered]@{}
    foreach ($name in $fields.Keys) {
        $r = Resolve-GsConfigDirectory -Value $fields[$name] -Field $name
        if ($null -ne $r.Error) { $errors.Add($r.Error) } else { $resolved[$name] = $r.Path }
    }

    $names = @($resolved.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        for ($j = $i + 1; $j -lt $names.Count; $j++) {
            $x = $names[$i]; $y = $names[$j]
            $px = $resolved[$x]; $py = $resolved[$y]
            if ([string]::Equals((Get-GsComparablePath $px), (Get-GsComparablePath $py), [StringComparison]::OrdinalIgnoreCase)) {
                $errors.Add((New-GsError 'SameDirectory' "$x,$y" "$x and $y must be different directories: '$px'."))
            } elseif (Test-GsPathContains -Parent $px -Child $py) {
                $errors.Add((New-GsError 'NestedDirectory' "$x,$y" "$y '$py' must not be inside $x '$px'."))
            } elseif (Test-GsPathContains -Parent $py -Child $px) {
                $errors.Add((New-GsError 'NestedDirectory' "$x,$y" "$x '$px' must not be inside $y '$py'."))
            }
        }
    }

    $config = $null
    if ($errors.Count -eq 0) {
        $config = [pscustomobject]@{
            InstallDir = $resolved['installDir']
            StateDir   = $resolved['stateDir']
            LogDir     = $resolved['logDir']
        }
    }
    return New-GsConfigResult -Path $null -Config $config -Errors $errors.ToArray()
}

function Read-GsInstallationConfig {
    <#
    .SYNOPSIS
        Reads and validates an InstallationConfig JSON file (schemaVersion 1).
    .DESCRIPTION
        Content problems never throw; they are returned in Errors. An empty or
        illegal Path throws System.ArgumentException (from Resolve-GsPath).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()][AllowEmptyString()]
        [string]$Path
    )

    $fullPath = Resolve-GsPath -Path $Path

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return New-GsConfigResult $fullPath $null @(New-GsError 'FileNotFound' '' "Config file not found: $fullPath")
    }
    try {
        $text = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    } catch {
        return New-GsConfigResult $fullPath $null @(New-GsError 'ReadFailed' '' $_.Exception.Message)
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        return New-GsConfigResult $fullPath $null @(New-GsError 'InvalidJson' '' 'Config file is empty.')
    }
    try {
        $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    } catch {
        return New-GsConfigResult $fullPath $null @(New-GsError 'InvalidJson' '' $_.Exception.Message)
    }
    if (-not ($data -is [System.Management.Automation.PSCustomObject])) {
        return New-GsConfigResult $fullPath $null @(New-GsError 'InvalidType' '' 'Config root must be a JSON object.')
    }

    $errors = New-Object System.Collections.Generic.List[object]
    if (-not (Test-GsHasProperty $data 'schemaVersion')) {
        $errors.Add((New-GsError 'MissingField' 'schemaVersion' 'Required field schemaVersion is missing.'))
    } else {
        $sv = $data.schemaVersion
        if (-not ($sv -is [int] -or $sv -is [long])) {
            $errors.Add((New-GsError 'InvalidType' 'schemaVersion' 'schemaVersion must be an integer.'))
        } elseif ($sv -ne $script:ConfigSchemaVersion) {
            $errors.Add((New-GsError 'UnsupportedValue' 'schemaVersion' "schemaVersion $sv is not supported; expected $script:ConfigSchemaVersion."))
        }
    }

    $values = @{}
    $missing = $false
    foreach ($name in @('installDir', 'stateDir', 'logDir')) {
        if (-not (Test-GsHasProperty $data $name)) {
            $errors.Add((New-GsError 'MissingField' $name "Required field $name is missing."))
            $missing = $true
        } else {
            $values[$name] = $data.$name
        }
    }

    $config = $null
    if (-not $missing) {
        $check = Test-GsInstallationConfig -InstallDir $values['installDir'] -StateDir $values['stateDir'] -LogDir $values['logDir']
        foreach ($e in $check.Errors) { $errors.Add($e) }
        $config = $check.Config
    }
    return New-GsConfigResult -Path $fullPath -Config $config -Errors $errors.ToArray()
}

# ---------------------------------------------------------------------------
# State machine (pure)
# ---------------------------------------------------------------------------

function Get-GsLifecycleTransitionTable {
    <#
    .SYNOPSIS
        Returns a copy of the legal transition table: ordered hashtable State -> string[].
    #>
    [CmdletBinding()]
    param()
    $copy = [ordered]@{}
    foreach ($k in $script:Transitions.Keys) { $copy[$k] = @($script:Transitions[$k]) }
    return $copy
}

function Test-GsLifecycleTransition {
    <#
    .SYNOPSIS
        Checks one transition against the table. Pure; never throws.
    .OUTPUTS
        PSCustomObject: Allowed, From, To, Code (Ok | UnknownState | IllegalTransition), Message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$From,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$To
    )
    $code = 'Ok'; $msg = "$From -> $To is allowed."
    $fromKnown = $script:States -ccontains $From
    $toKnown = $script:States -ccontains $To
    if (-not $fromKnown -or -not $toKnown) {
        $code = 'UnknownState'
        $msg = "Unknown state: '$(if (-not $fromKnown) { $From } else { $To })'. Known states: $($script:States -join ', ')."
    } elseif (-not ($script:Transitions[$From] -ccontains $To)) {
        $code = 'IllegalTransition'
        $msg = "$From -> $To is not a legal transition. Allowed from ${From}: $($script:Transitions[$From] -join ', ')."
    }
    [pscustomobject]@{ Allowed = ($code -eq 'Ok'); From = $From; To = $To; Code = $code; Message = $msg }
}

# ---------------------------------------------------------------------------
# Diagnostics sanitization
# ---------------------------------------------------------------------------

function ConvertTo-GsSafeValue {
    param($Value, [int]$Depth)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Value.Length -gt $script:MaxDiagnosticString) { return $Value.Substring(0, $script:MaxDiagnosticString) + '...[truncated]' }
        return $Value
    }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [int16] -or $Value -is [byte] -or $Value -is [single]) {
        return $Value
    }
    if ($Value -is [System.Security.SecureString] -or $Value -is [System.Management.Automation.PSCredential]) {
        return '[REDACTED]'
    }
    if ($Depth -ge $script:MaxDiagnosticDepth) { return '[depth-limit]' }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) {
        return (ConvertTo-GsSafeDiagnostics -Value $Value -Depth ($Depth + 1))
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            if ($list.Count -ge $script:MaxDiagnosticEntries) { $list.Add('[truncated]'); break }
            $list.Add((ConvertTo-GsSafeValue -Value $item -Depth ($Depth + 1)))
        }
        return , $list.ToArray()
    }
    return "[unserializable:$($Value.GetType().FullName)]"
}

function ConvertTo-GsSafeDiagnostics {
    # Returns an ordered hashtable containing only JSON-safe values. Keys that
    # look sensitive have their values replaced with '[REDACTED]'.
    param($Value, [int]$Depth = 0)
    $out = [ordered]@{}
    if ($null -eq $Value) { return $out }
    $pairs = @()
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = @($Value.Keys | ForEach-Object { , @([string]$_, $Value[$_]) })
    } elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = @($Value.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) })
    } else {
        $out['value'] = ConvertTo-GsSafeValue -Value $Value -Depth $Depth
        return $out
    }
    foreach ($pair in $pairs) {
        if ($out.Count -ge $script:MaxDiagnosticEntries) { $out['_truncated'] = $true; break }
        $key = [string]$pair[0]
        if ($key -match $script:SensitiveKeyPattern) {
            $out[$key] = '[REDACTED]'
        } else {
            $out[$key] = ConvertTo-GsSafeValue -Value $pair[1] -Depth $Depth
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

function New-GsStateRecord {
    param([string]$State, [string]$ChangedAtUtc, $ErrorInfo)
    [pscustomobject]@{ State = $State; ChangedAtUtc = $ChangedAtUtc; Error = $ErrorInfo }
}

function New-GsErrorInfo {
    param([string]$Code, [string]$OccurredAtUtc, $Diagnostics)
    [pscustomobject]@{ Code = $Code; OccurredAtUtc = $OccurredAtUtc; Diagnostics = (ConvertTo-GsSafeDiagnostics -Value $Diagnostics) }
}

function Get-GsStateFilePath {
    param([string]$StateDir)
    return [System.IO.Path]::Combine($StateDir, $script:StateFileName)
}

function Read-GsStateFile {
    # Returns @{ Kind = Default|File|Corrupt|ReadFailed; Record; Reason }.
    # Corrupt and ReadFailed always yield a Failed record, never Running.
    param([string]$StatePath)

    $now = Get-GsUtcNow
    if (-not [System.IO.File]::Exists($StatePath)) {
        return @{ Kind = 'Default'; Record = (New-GsStateRecord 'Stopped' $null $null); Reason = $null }
    }
    # A replace holds the target for a moment, so a concurrent open can be
    # denied with a sharing violation. That is not a read failure: retry
    # briefly before reporting one. Any other error fails at once.
    $text = $null
    for ($attempt = 1; ; $attempt++) {
        try {
            $text = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8)
            break
        } catch {
            $ex = Get-GsInnerException $_.Exception
            $win32 = $ex.HResult -band 0xFFFF
            $transient = ($ex -is [System.IO.IOException]) -and
                (($win32 -eq $script:ErrorSharingViolation) -or ($win32 -eq $script:ErrorLockViolation))
            if ($transient -and $attempt -lt 20) {
                Start-Sleep -Milliseconds ([Math]::Min(10, $attempt))
                continue
            }
            $err = New-GsErrorInfo 'StateReadFailed' $now @{ exceptionType = $ex.GetType().FullName }
            return @{ Kind = 'ReadFailed'; Record = (New-GsStateRecord 'Failed' $now $err); Reason = $ex.Message }
        }
    }

    $reason = $null
    $data = $null
    if ([string]::IsNullOrWhiteSpace($text)) {
        $reason = 'EmptyFile'
    } else {
        try { $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch { $reason = 'InvalidJson' }
    }
    if ($null -eq $reason -and -not ($data -is [System.Management.Automation.PSCustomObject])) { $reason = 'RootNotObject' }
    if ($null -eq $reason) {
        if (-not (Test-GsHasProperty $data 'schemaVersion') -or -not ($data.schemaVersion -is [int] -or $data.schemaVersion -is [long]) -or
            $data.schemaVersion -ne $script:StateSchemaVersion) {
            $reason = 'UnsupportedSchemaVersion'
        } elseif (-not (Test-GsHasProperty $data 'state') -or -not ($data.state -is [string]) -or -not ($script:States -ccontains $data.state)) {
            $reason = 'UnknownState'
        } elseif (-not (Test-GsHasProperty $data 'changedAtUtc') -or -not (Test-GsUtcTimestamp $data.changedAtUtc)) {
            $reason = 'InvalidTimestamp'
        } elseif (-not (Test-GsHasProperty $data 'error')) {
            $reason = 'MissingError'
        } elseif ($data.state -ceq 'Failed') {
            $e = $data.error
            if (-not ($e -is [System.Management.Automation.PSCustomObject]) -or
                -not (Test-GsHasProperty $e 'code') -or -not ($e.code -is [string]) -or $e.code -cnotmatch $script:ErrorCodePattern -or
                -not (Test-GsHasProperty $e 'occurredAtUtc') -or -not (Test-GsUtcTimestamp $e.occurredAtUtc) -or
                -not (Test-GsHasProperty $e 'diagnostics') -or -not ($e.diagnostics -is [System.Management.Automation.PSCustomObject])) {
                $reason = 'InvalidError'
            }
        } elseif ($null -ne $data.error) {
            $reason = 'UnexpectedError'
        }
    }

    if ($null -ne $reason) {
        $err = New-GsErrorInfo 'StateCorrupt' $now @{ reason = $reason }
        return @{ Kind = 'Corrupt'; Record = (New-GsStateRecord 'Failed' $now $err); Reason = $reason }
    }

    $errInfo = $null
    if ($data.state -ceq 'Failed') {
        $errInfo = [pscustomobject]@{
            Code          = $data.error.code
            OccurredAtUtc = $data.error.occurredAtUtc
            Diagnostics   = (ConvertTo-GsSafeDiagnostics -Value $data.error.diagnostics)
        }
    }
    return @{ Kind = 'File'; Record = (New-GsStateRecord $data.state $data.changedAtUtc $errInfo); Reason = $null }
}

function Set-GsStateFileAtomic {
    # Publishes $TempPath as $Path in a single rename.
    #
    # File.Replace is not atomic from a reader's point of view: it moves the
    # target to the backup name first, so a concurrent read can find no file
    # for a moment (measured on this host: 390 of 3171 reads over 200 writes).
    # MoveFileEx replaces the target in one step and never leaves it missing
    # (same measurement: 0 of 3154). Both files live in the same directory, so
    # the rename never degrades into a copy.
    #
    # A sharing violation is retried: a reader may hold the target open
    # without FILE_SHARE_DELETE. Access denied is only retried while the
    # target is not read-only, so a read-only state file fails immediately
    # instead of burning the whole budget.
    param([string]$TempPath, [string]$Path)

    if (-not ('GsLifecycle.NativeFile' -as [type])) {
        Add-Type -Namespace GsLifecycle -Name NativeFile -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string existing, string target, int flags);
'@
    }

    $readOnly = $false
    try {
        $attrs = [System.IO.File]::GetAttributes($Path)
        $readOnly = (($attrs -band [System.IO.FileAttributes]::ReadOnly) -ne 0)
    } catch { $readOnly = $false }

    for ($i = 1; $i -le 40; $i++) {
        # 1 = MOVEFILE_REPLACE_EXISTING, 2 = MOVEFILE_COPY_ALLOWED.
        if ([GsLifecycle.NativeFile]::MoveFileEx($TempPath, $Path, 3)) { return }
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $retryable = ($err -eq 32) -or (($err -eq 5) -and (-not $readOnly))
        if ((-not $retryable) -or ($i -eq 40)) {
            throw (New-Object System.ComponentModel.Win32Exception($err, "State file could not be replaced: $Path"))
        }
        Start-Sleep -Milliseconds ([Math]::Min(50, 5 * $i))
    }
}

function Write-GsStateFile {
    # Writes to a temp file in the same directory, flushes it to disk, then
    # atomically replaces the target. Throws on failure; the target is left
    # unchanged and the temp file is removed.
    param([string]$StatePath, $Record, [switch]$BackupExisting)

    # Internal fault-injection seam for tests (not exported, $null in normal use).
    if ($null -ne $script:TestWriteFault) { & $script:TestWriteFault $Record }

    $errorJson = $null
    if ($null -ne $Record.Error) {
        $errorJson = [ordered]@{
            code          = $Record.Error.Code
            occurredAtUtc = $Record.Error.OccurredAtUtc
            diagnostics   = $Record.Error.Diagnostics
        }
    }
    $doc = [ordered]@{
        schemaVersion = $script:StateSchemaVersion
        state         = $Record.State
        changedAtUtc  = $Record.ChangedAtUtc
        error         = $errorJson
    }
    $json = ConvertTo-Json -InputObject $doc -Depth ($script:MaxDiagnosticDepth + 6)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)

    $dir = [System.IO.Path]::GetDirectoryName($StatePath)
    $tmp = [System.IO.Path]::Combine($dir, $script:StateFileName + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $fs = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush($true)
        } finally {
            $fs.Dispose()
        }
        if ([System.IO.File]::Exists($StatePath)) {
            if ($BackupExisting) {
                # A copy, not the moved-away original: the target has to stay
                # in place until the rename, so a reader never sees it missing.
                [System.IO.File]::Copy($StatePath, ($StatePath + $script:CorruptBackupSuffix), $true)
            }
            Set-GsStateFileAtomic -TempPath $tmp -Path $StatePath
        } else {
            [System.IO.File]::Move($tmp, $StatePath)
        }
    } finally {
        if ([System.IO.File]::Exists($tmp)) {
            try { [System.IO.File]::Delete($tmp) } catch { Write-Verbose "Could not remove temp file $tmp" }
        }
    }
}

function Get-GsInnerException {
    # PowerShell wraps .NET constructor/method exceptions in MethodInvocationException.
    param([System.Exception]$Exception)
    $e = $Exception
    while ($e -is [System.Management.Automation.MethodInvocationException] -and $null -ne $e.InnerException) {
        $e = $e.InnerException
    }
    return $e
}

$script:ErrorSharingViolation = 32
$script:ErrorLockViolation    = 33

function Enter-GsStateLock {
    # Exclusive, cross-process lock for one state directory. The lock is the
    # open handle (FileShare.None), not the file's existence: lifecycle.lock
    # is left in place on release, so a stale file never blocks anyone and no
    # delete-pending race can be mistaken for a permission error.
    # Returns @{ Stream; Code; Message }. Code is:
    #   Ok           - Stream holds the lock
    #   Busy         - sharing violation: another handle holds the lock
    #   AccessDenied - the lock file cannot be created or opened (permissions)
    #   LockFailed   - any other error
    param([string]$StateDir)
    $lockPath = [System.IO.Path]::Combine($StateDir, $script:LockFileName)
    try {
        $fs = New-Object System.IO.FileStream($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        return @{ Stream = $fs; Code = 'Ok'; Message = $null }
    } catch {
        $ex = Get-GsInnerException $_.Exception
        if ($ex -is [System.UnauthorizedAccessException]) {
            return @{ Stream = $null; Code = 'AccessDenied'; Message = "Access denied to lock file '$lockPath': $($ex.Message)" }
        }
        if ($ex -is [System.IO.IOException]) {
            $win32 = $ex.HResult -band 0xFFFF
            if ($win32 -eq $script:ErrorSharingViolation -or $win32 -eq $script:ErrorLockViolation) {
                return @{ Stream = $null; Code = 'Busy'; Message = 'Another lifecycle operation holds the state lock.' }
            }
        }
        return @{ Stream = $null; Code = 'LockFailed'; Message = "Lock file '$lockPath' could not be opened: $($ex.GetType().FullName): $($ex.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Result objects and context
# ---------------------------------------------------------------------------

function New-GsLifecycleResult {
    param(
        [bool]$Success, [string]$Code, [string]$Message,
        [string]$From, [string]$To, $State,
        [object[]]$Errors = @(), [string]$OperationError = $null,
        [bool]$OperationInvoked = $false, $OperationSucceeded = $null, $Recovered = $null
    )
    [pscustomobject]@{
        Success            = $Success
        Code               = $Code
        Message            = $Message
        From               = $From
        To                 = $To
        State              = $State
        Errors             = @($Errors)
        OperationInvoked   = $OperationInvoked
        OperationSucceeded = $OperationSucceeded
        OperationError     = $OperationError
        Recovered          = $Recovered
    }
}

function Resolve-GsLifecycleContext {
    # Validates the config object and the state directory.
    # Returns @{ Config; StatePath; Failure (result object or $null) }.
    param($Config)
    $fail = {
        param($code, $msg, $errs)
        @{ Config = $null; StatePath = $null; Failure = (New-GsLifecycleResult -Success $false -Code $code -Message $msg -Errors $errs) }
    }
    if ($null -eq $Config) { return (& $fail 'InvalidConfig' 'Config must not be null.' @()) }
    $props = @{}
    foreach ($n in @('InstallDir', 'StateDir', 'LogDir')) {
        if ($Config -is [System.Collections.IDictionary]) {
            $props[$n] = $(if ($Config.Contains($n)) { $Config[$n] } else { $null })
        } elseif (Test-GsHasProperty $Config $n) {
            $props[$n] = $Config.$n
        } else {
            $props[$n] = $null
        }
    }
    $check = Test-GsInstallationConfig -InstallDir $props['InstallDir'] -StateDir $props['StateDir'] -LogDir $props['LogDir']
    if (-not $check.Success) { return (& $fail 'InvalidConfig' 'Installation config is invalid.' $check.Errors) }
    if (-not [System.IO.Directory]::Exists($check.Config.StateDir)) {
        return (& $fail 'StateDirectoryMissing' "State directory does not exist: $($check.Config.StateDir)" @())
    }
    return @{ Config = $check.Config; StatePath = (Get-GsStateFilePath $check.Config.StateDir); Failure = $null }
}

function New-GsLockFailureResult {
    param($Lock, [string]$To)
    return (New-GsLifecycleResult -Success $false -Code $Lock.Code -Message $Lock.Message -To $To)
}

# ---------------------------------------------------------------------------
# Core transition (caller must hold the state lock)
# ---------------------------------------------------------------------------

function Read-GsCurrentUnderLock {
    # Reads current state. A corrupt file is replaced by a persisted Failed
    # record (old file kept as *.corrupt). Returns @{ Record; Failure }.
    param([string]$StatePath)
    $read = Read-GsStateFile -StatePath $StatePath
    if ($read.Kind -eq 'ReadFailed') {
        return @{ Record = $read.Record; Failure = (New-GsLifecycleResult -Success $false -Code 'StateReadFailed' `
                    -Message "State file could not be read: $($read.Reason)" -From 'Failed' -State $read.Record) }
    }
    if ($read.Kind -eq 'Corrupt') {
        try {
            Write-GsStateFile -StatePath $StatePath -Record $read.Record -BackupExisting
        } catch {
            return @{ Record = $read.Record; Failure = (New-GsLifecycleResult -Success $false -Code 'PersistFailed' `
                        -Message "State file is corrupt ($($read.Reason)) and Failed could not be persisted: $($_.Exception.Message)" `
                        -From 'Failed' -State $read.Record) }
        }
    }
    return @{ Record = $read.Record; Failure = $null }
}

function Invoke-GsTransitionCore {
    param(
        [string]$StatePath, $Current, [string]$To,
        [string]$ErrorCode, $Diagnostics
    )
    $from = $Current.State
    $check = Test-GsLifecycleTransition -From $from -To $To
    if (-not $check.Allowed) {
        return (New-GsLifecycleResult -Success $false -Code $check.Code -Message $check.Message -From $from -To $To -State $Current)
    }

    $now = Get-GsUtcNow
    $errInfo = $null
    if ($To -ceq 'Failed') {
        if ([string]::IsNullOrEmpty($ErrorCode)) {
            return (New-GsLifecycleResult -Success $false -Code 'ErrorCodeRequired' -Message 'Transition to Failed requires ErrorCode.' -From $from -To $To -State $Current)
        }
        if ($ErrorCode -cnotmatch $script:ErrorCodePattern) {
            return (New-GsLifecycleResult -Success $false -Code 'InvalidErrorCode' -Message "ErrorCode must match $script:ErrorCodePattern." -From $from -To $To -State $Current)
        }
        $errInfo = New-GsErrorInfo $ErrorCode $now $Diagnostics
    } elseif (-not [string]::IsNullOrEmpty($ErrorCode)) {
        return (New-GsLifecycleResult -Success $false -Code 'ErrorCodeNotAllowed' -Message 'ErrorCode is only allowed when transitioning to Failed.' -From $from -To $To -State $Current)
    }

    $next = New-GsStateRecord $To $now $errInfo
    try {
        Write-GsStateFile -StatePath $StatePath -Record $next
    } catch {
        return (New-GsLifecycleResult -Success $false -Code 'PersistFailed' -Message "State could not be persisted: $($_.Exception.Message)" -From $from -To $To -State $Current)
    }
    return (New-GsLifecycleResult -Success $true -Code 'Ok' -Message "$from -> $To" -From $from -To $To -State $next)
}

function Repair-GsInterruptedState {
    # Called by Start/Stop while holding the lock. Holding the lock proves no
    # live caller owns the operation, so a persisted Starting or Stopping is
    # the residue of an interrupted call (crash or failed write):
    #   Starting -> Failed  (StartInterrupted). The start operation may or may
    #               not have run, so the real system state is unknown.
    #   Stopping -> Stopped (StopCompleted). Stopping is only persisted after
    #               the stop operation succeeded, so only the final write was lost.
    # Both are legal table edges. Returns @{ Record; Recovered; Failure }.
    param([string]$StatePath, $Current)
    $state = $Current.State
    if ($state -cne 'Starting' -and $state -cne 'Stopping') {
        return @{ Record = $Current; Recovered = $null; Failure = $null }
    }
    if ($state -ceq 'Starting') {
        $r = Invoke-GsTransitionCore -StatePath $StatePath -Current $Current -To 'Failed' -ErrorCode 'StartInterrupted' `
            -Diagnostics ([ordered]@{ interruptedState = 'Starting'; interruptedChangedAtUtc = $Current.ChangedAtUtc })
        $code = 'StartInterrupted'
    } else {
        $r = Invoke-GsTransitionCore -StatePath $StatePath -Current $Current -To 'Stopped'
        $code = 'StopCompleted'
    }
    if (-not $r.Success) {
        $r.Message = "Interrupted $state state could not be recovered: $($r.Message)"
        return @{ Record = $Current; Recovered = $null; Failure = $r }
    }
    $recovered = [pscustomobject]@{ From = $state; To = $r.State.State; Code = $code; InterruptedChangedAtUtc = $Current.ChangedAtUtc }
    return @{ Record = $r.State; Recovered = $recovered; Failure = $null }
}

function Invoke-GsOperation {
    # Runs an injected script block with ErrorActionPreference = Stop in its
    # scope and stderr/error records merged into its output.
    # Returns @{ Ok; Reason; ExceptionType; Message }. Failure is:
    #   Exception        - the block threw (terminating error)
    #   NonTerminatingError - a non-terminating error was written (promoted
    #                      by Stop, or emitted despite a local override)
    #   ControlFlowEscape - break/continue (labeled or not) or exit left the block
    #   ReturnedFalse    - the output contains [bool]$false
    param([scriptblock]$Operation, $Context)
    $vars = New-Object 'System.Collections.Generic.List[psvariable]'
    $vars.Add((New-Object System.Management.Automation.PSVariable('ErrorActionPreference', [System.Management.Automation.ActionPreference]::Stop)))
    try {
        $run = [GsLifecycle.Internal.OperationInvoker]::Run($script:OperationWrapper, @($Operation, $vars, $Context))
    } catch {
        $ex = Get-GsInnerException $_.Exception
        if ($ex -is [System.Management.Automation.ActionPreferenceStopException]) {
            $type = $ex.GetType().FullName
            if ($null -ne $ex.ErrorRecord -and $null -ne $ex.ErrorRecord.Exception) { $type = $ex.ErrorRecord.Exception.GetType().FullName }
            return @{ Ok = $false; Reason = 'NonTerminatingError'; ExceptionType = $type; Message = $ex.Message }
        }
        return @{ Ok = $false; Reason = 'Exception'; ExceptionType = $ex.GetType().FullName; Message = $ex.Message }
    }
    if ($null -ne $run.FlowControl) {
        return @{ Ok = $false; Reason = 'ControlFlowEscape'; ExceptionType = $run.FlowControl
            Message = "Operation left its script block through a control-flow statement ($($run.FlowControl)); break, continue and exit are not allowed in operations." }
    }
    $out = @($run.Output)
    foreach ($o in $out) {
        if ($o -is [System.Management.Automation.ErrorRecord]) {
            $type = $(if ($null -ne $o.Exception) { $o.Exception.GetType().FullName } else { $null })
            return @{ Ok = $false; Reason = 'NonTerminatingError'; ExceptionType = $type; Message = "Operation wrote an error: $($o.ToString())" }
        }
    }
    foreach ($o in $out) {
        if ($o -is [bool] -and -not $o) {
            return @{ Ok = $false; Reason = 'ReturnedFalse'; ExceptionType = $null; Message = 'Operation returned $false.' }
        }
    }
    return @{ Ok = $true; Reason = $null; ExceptionType = $null; Message = $null }
}

function New-GsOperationContext {
    param($Config, [string]$From, [string]$Action)
    [pscustomobject]@{
        Action     = $Action
        From       = $From
        InstallDir = $Config.InstallDir
        StateDir   = $Config.StateDir
        LogDir     = $Config.LogDir
    }
}

function Get-GsOperationDiagnostics {
    param($OpResult, [string]$Action)
    $d = [ordered]@{ action = $Action; reason = $OpResult.Reason }
    if ($null -ne $OpResult.ExceptionType) { $d['exceptionType'] = $OpResult.ExceptionType }
    return $d
}

# ---------------------------------------------------------------------------
# Public lifecycle entry points
# ---------------------------------------------------------------------------

function Get-GsLifecycleState {
    <#
    .SYNOPSIS
        Reads the persisted lifecycle state without modifying it.
    .OUTPUTS
        PSCustomObject: Success, Code (Ok | InvalidConfig | StateDirectoryMissing),
        Source (Default | File | Corrupt | ReadFailed), State (State, ChangedAtUtc, Error),
        Interrupted, Path, Errors.
        Corrupt or unreadable files report State Failed, never Running.
        Interrupted is $true for Starting/Stopping when no caller holds the
        lock, $false when a caller holds it or the state is not transient,
        $null when the lock could not be probed (e.g. access denied).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Config)

    $ctx = Resolve-GsLifecycleContext -Config $Config
    if ($null -ne $ctx.Failure) {
        return [pscustomobject]@{ Success = $false; Code = $ctx.Failure.Code; Source = $null; State = $null; Interrupted = $null; Path = $null; Errors = $ctx.Failure.Errors }
    }
    $read = Read-GsStateFile -StatePath $ctx.StatePath
    $interrupted = $false
    if ($read.Record.State -ceq 'Starting' -or $read.Record.State -ceq 'Stopping') {
        $lock = Enter-GsStateLock -StateDir $ctx.Config.StateDir
        if ($lock.Code -eq 'Ok') {
            $lock.Stream.Dispose()
            # Re-read: a writer may have finished between the read and the probe.
            $read = Read-GsStateFile -StatePath $ctx.StatePath
            $interrupted = ($read.Record.State -ceq 'Starting' -or $read.Record.State -ceq 'Stopping')
        } elseif ($lock.Code -ne 'Busy') {
            $interrupted = $null
        }
    }
    return [pscustomobject]@{ Success = $true; Code = 'Ok'; Source = $read.Kind; State = $read.Record; Interrupted = $interrupted; Path = $ctx.StatePath; Errors = @() }
}

function Invoke-GsLifecycleTransition {
    <#
    .SYNOPSIS
        Low-level validated entry point for transitions that need no system operation.
    .DESCRIPTION
        Takes the per-state-directory lock, reads the current state (a corrupt
        file is first persisted as Failed), checks the transition table, then
        writes the new state atomically.
        Only Failed and Paused may be targeted directly. Starting, Running,
        Stopping and Stopped describe the real system and are written only by
        Start-GsLifecycle / Stop-GsLifecycle around an injected operation; a
        legal transition to them here returns OperationRequired.
        This function does not repair interrupted Starting/Stopping states.
        Never throws for expected problems.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Config,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$To,
        [Parameter()][string]$ErrorCode,
        [Parameter()]$Diagnostics
    )

    $ctx = Resolve-GsLifecycleContext -Config $Config
    if ($null -ne $ctx.Failure) { $ctx.Failure.To = $To; return $ctx.Failure }

    $lock = Enter-GsStateLock -StateDir $ctx.Config.StateDir
    if ($lock.Code -ne 'Ok') { return (New-GsLockFailureResult $lock $To) }
    try {
        $cur = Read-GsCurrentUnderLock -StatePath $ctx.StatePath
        if ($null -ne $cur.Failure) { $cur.Failure.To = $To; return $cur.Failure }
        $check = Test-GsLifecycleTransition -From $cur.Record.State -To $To
        if (-not $check.Allowed) {
            return (New-GsLifecycleResult -Success $false -Code $check.Code -Message $check.Message -From $cur.Record.State -To $To -State $cur.Record)
        }
        if ($script:OperationTargets -ccontains $To) {
            $verb = $(if ($To -ceq 'Starting' -or $To -ceq 'Running') { 'Start-GsLifecycle' } else { 'Stop-GsLifecycle' })
            return (New-GsLifecycleResult -Success $false -Code 'OperationRequired' `
                    -Message "$($cur.Record.State) -> $To requires a system operation; use $verb with an injected operation." `
                    -From $cur.Record.State -To $To -State $cur.Record)
        }
        return (Invoke-GsTransitionCore -StatePath $ctx.StatePath -Current $cur.Record -To $To -ErrorCode $ErrorCode -Diagnostics $Diagnostics)
    } finally {
        $lock.Stream.Dispose()
    }
}

function Start-GsLifecycle {
    <#
    .SYNOPSIS
        Stopped|Paused|Failed -> Starting -> Running (or Failed), using an injected start operation.
    .PARAMETER StartOperation
        Required. Invoked with one context argument (Action, From, InstallDir,
        StateDir, LogDir) and ErrorActionPreference = Stop. Throwing, writing
        an error record or emitting $false means failure. There is no built-in
        default operation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Config,
        [Parameter()][AllowNull()][scriptblock]$StartOperation
    )

    if ($null -eq $StartOperation) {
        return (New-GsLifecycleResult -Success $false -Code 'OperationNotProvided' -Message 'StartOperation was not injected; refusing to start.' -To 'Running')
    }
    $ctx = Resolve-GsLifecycleContext -Config $Config
    if ($null -ne $ctx.Failure) { $ctx.Failure.To = 'Running'; return $ctx.Failure }

    $lock = Enter-GsStateLock -StateDir $ctx.Config.StateDir
    if ($lock.Code -ne 'Ok') { return (New-GsLockFailureResult $lock 'Running') }
    try {
        $cur = Read-GsCurrentUnderLock -StatePath $ctx.StatePath
        if ($null -ne $cur.Failure) { $cur.Failure.To = 'Running'; return $cur.Failure }
        $rep = Repair-GsInterruptedState -StatePath $ctx.StatePath -Current $cur.Record
        if ($null -ne $rep.Failure) { $rep.Failure.To = 'Running'; return $rep.Failure }
        $recovered = $rep.Recovered
        $from = $rep.Record.State

        if ($from -ceq 'Running') {
            return (New-GsLifecycleResult -Success $false -Code 'AlreadyRunning' -Message 'Lifecycle is already Running.' `
                    -From $from -To 'Running' -State $rep.Record -Recovered $recovered)
        }

        $r1 = Invoke-GsTransitionCore -StatePath $ctx.StatePath -Current $rep.Record -To 'Starting'
        if (-not $r1.Success) { $r1.From = $from; $r1.To = 'Running'; $r1.Recovered = $recovered; return $r1 }

        $op = Invoke-GsOperation -Operation $StartOperation -Context (New-GsOperationContext $ctx.Config $from 'Start')
        if (-not $op.Ok) {
            $r2 = Invoke-GsTransitionCore -StatePath $ctx.StatePath -Current $r1.State -To 'Failed' -ErrorCode 'StartOperationFailed' `
                -Diagnostics (Get-GsOperationDiagnostics $op 'Start')
            $code = 'StartOperationFailed'
            $msg = "Start operation failed: $($op.Message)"
            if (-not $r2.Success) {
                $code = 'PersistFailed'
                $msg += " Failed could not be persisted ($($r2.Message)); the state remains Starting and the next Start/Stop call recovers it as StartInterrupted."
            }
            return (New-GsLifecycleResult -Success $false -Code $code -Message $msg -From $from -To 'Running' -State $r2.State `
                    -OperationInvoked $true -OperationSucceeded $false -OperationError $op.Message -Recovered $recovered)
        }

        $r3 = Invoke-GsTransitionCore -StatePath $ctx.StatePath -Current $r1.State -To 'Running'
        if ($r3.Success) {
            $r3.From = $from; $r3.OperationInvoked = $true; $r3.OperationSucceeded = $true; $r3.Recovered = $recovered
            return $r3
        }

        # The operation succeeded but Running was not persisted. Never leave
        # the caller believing nothing happened: try to record Failed, and
        # report OperationSucceeded so the caller knows the component may run.
        $rf = Invoke-GsTransitionCore -StatePath $ctx.StatePath -Current $r1.State -To 'Failed' -ErrorCode 'StartPersistFailed' `
            -Diagnostics ([ordered]@{ action = 'Start'; reason = 'RunningNotPersisted' })
        $msg = "Start operation succeeded but Running could not be persisted ($($r3.Message)); the component may be running."
        if ($rf.Success) {
            $msg += ' State recorded as Failed (StartPersistFailed).'
        } else {
            $msg += ' Failed could not be persisted either; the state remains Starting and the next Start/Stop call recovers it as StartInterrupted.'
        }
        return (New-GsLifecycleResult -Success $false -Code 'PersistFailed' -Message $msg -From $from -To 'Running' -State $rf.State `
                -OperationInvoked $true -OperationSucceeded $true -Recovered $recovered)
    } finally {
        $lock.Stream.Dispose()
    }
}

function Stop-GsLifecycle {
    <#
    .SYNOPSIS
        Running|Failed -> Stopping -> Stopped, using an injected stop callback.
    .DESCRIPTION
        The stop callback runs before Stopping is persisted, because the table
        has no Stopping -> Failed edge. On callback failure the state becomes
        (or stays) Failed and the result is StopOperationFailed; it is never
        reported as Stopped. A residual Stopping (stop already succeeded, final
        write lost) is completed to Stopped without calling the callback.
    .PARAMETER StopOperation
        Required. Same contract as Start-GsLifecycle's StartOperation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Config,
        [Parameter()][AllowNull()][scriptblock]$StopOperation
    )

    if ($null -eq $StopOperation) {
        return (New-GsLifecycleResult -Success $false -Code 'OperationNotProvided' -Message 'StopOperation was not injected; refusing to stop.' -To 'Stopped')
    }
    $ctx = Resolve-GsLifecycleContext -Config $Config
    if ($null -ne $ctx.Failure) { $ctx.Failure.To = 'Stopped'; return $ctx.Failure }

    $lock = Enter-GsStateLock -StateDir $ctx.Config.StateDir
    if ($lock.Code -ne 'Ok') { return (New-GsLockFailureResult $lock 'Stopped') }
    try {
        $cur = Read-GsCurrentUnderLock -StatePath $ctx.StatePath
        if ($null -ne $cur.Failure) { $cur.Failure.To = 'Stopped'; return $cur.Failure }
        $rep = Repair-GsInterruptedState -StatePath $ctx.StatePath -Current $cur.Record
        if ($null -ne $rep.Failure) { $rep.Failure.To = 'Stopped'; return $rep.Failure }
        $recovered = $rep.Recovered
        $from = $rep.Record.State

        if ($null -ne $recovered -and $recovered.Code -eq 'StopCompleted') {
            return (New-GsLifecycleResult -Success $true -Code 'Ok' -Message 'Interrupted stop completed: Stopping -> Stopped.' `
                    -From 'Stopping' -To 'Stopped' -State $rep.Record -Recovered $recovered)
        }
        if ($from -ceq 'Stopped') {
            return (New-GsLifecycleResult -Success $false -Code 'AlreadyStopped' -Message 'Lifecycle is already Stopped.' `
                    -From $from -To 'Stopped' -State $rep.Record -Recovered $recovered)
        }
        $check = Test-GsLifecycleTransition -From $from -To 'Stopping'
        if (-not $check.Allowed) {
            return (New-GsLifecycleResult -Success $false -Code $check.Code -Message $check.Message -From $from -To 'Stopped' `
                    -State $rep.Record -Recovered $recovered)
        }

        $op = Invoke-GsOperation -Operation $StopOperation -Context (New-GsOperationContext $ctx.Config $from 'Stop')
        if (-not $op.Ok) {
            # Running -> Failed is a legal edge. A Failed state has no
            # Failed -> Failed edge, so it is kept unchanged (with its original
            # error record) and the stop failure is reported in the result only.
            $code = 'StopOperationFailed'
            $state = $rep.Record
            if ($from -ceq 'Running') {
                $rf = Invoke-GsTransitionCore -StatePath $ctx.StatePath -Current $rep.Record -To 'Failed' -ErrorCode 'StopOperationFailed' `
                    -Diagnostics (Get-GsOperationDiagnostics $op 'Stop')
                if ($rf.Success) { $state = $rf.State } else { $code = 'PersistFailed' }
            }
            return (New-GsLifecycleResult -Success $false -Code $code -Message "Stop operation failed: $($op.Message)" `
                    -From $from -To 'Stopped' -State $state -OperationInvoked $true -OperationSucceeded $false `
                    -OperationError $op.Message -Recovered $recovered)
        }

        $r1 = Invoke-GsTransitionCore -StatePath $ctx.StatePath -Current $rep.Record -To 'Stopping'
        if (-not $r1.Success) {
            # The component was stopped but nothing recorded it. Leaving Running
            # would be false, so record Failed when the table allows it.
            $state = $rep.Record
            $msg = "Stop operation succeeded but Stopping could not be persisted ($($r1.Message)); the component may be stopped."
            if ($from -ceq 'Running') {
                $rf = Invoke-GsTransitionCore -StatePath $ctx.StatePath -Current $rep.Record -To 'Failed' -ErrorCode 'StopPersistFailed' `
                    -Diagnostics ([ordered]@{ action = 'Stop'; reason = 'StoppingNotPersisted' })
                if ($rf.Success) { $state = $rf.State; $msg += ' State recorded as Failed (StopPersistFailed).' }
                else { $msg += ' Failed could not be persisted either; the state file still says Running.' }
            }
            return (New-GsLifecycleResult -Success $false -Code 'PersistFailed' -Message $msg -From $from -To 'Stopped' -State $state `
                    -OperationInvoked $true -OperationSucceeded $true -Recovered $recovered)
        }
        $r2 = Invoke-GsTransitionCore -StatePath $ctx.StatePath -Current $r1.State -To 'Stopped'
        $r2.From = $from; $r2.OperationInvoked = $true; $r2.OperationSucceeded = $true; $r2.Recovered = $recovered
        if (-not $r2.Success) {
            $r2.Message = "Stop operation succeeded but Stopped could not be persisted ($($r2.Message)); the state remains Stopping and the next Start/Stop call completes it."
        }
        return $r2
    } finally {
        $lock.Stream.Dispose()
    }
}

Export-ModuleMember -Function Read-GsInstallationConfig, Test-GsInstallationConfig, Get-GsLifecycleTransitionTable,
    Test-GsLifecycleTransition, Get-GsLifecycleState, Invoke-GsLifecycleTransition, Start-GsLifecycle, Stop-GsLifecycle
