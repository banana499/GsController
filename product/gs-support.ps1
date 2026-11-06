#requires -Version 5.1
<#
.SYNOPSIS
  One-click support bundle for GsController (contract K1).

.DESCRIPTION
  Runs the sibling gs-diagnose.ps1 (-AsJson), then packs the report plus
  redacted tray log tails into a single zip:

    diagnose.json    the raw JSON report emitted by gs-diagnose.ps1
    extra-logs.json  the report's extraLogs[] (bounded, redacted tails of
                     <TrayLogDir>\tray.log and tray.log.1)
    manifest.json    schemaVersion, generation time, product version and
                     the SHA-256 and size of each entry (the manifest
                     cannot hash itself; its own row has null values)

  The LAST output element is
    { schemaVersion = 1; Success; ZipPath; Entries; Errors } with
  Errors an array of { code; message }. Exit code 0 on success, 1 on
  failure. Error codes: DiagnoseUnavailable, DiagnoseFailed,
  RedactionCheckFailed, OutputDirInvalid, ZipFailed, SupportFailed.

  The script imports no product modules (it must work when they are
  broken) and implements no redaction of its own: all log redaction
  happens inside gs-diagnose.ps1, whose -ExtraLogPath parameter reuses the
  existing bounded, redacting log reader for the tray logs. Before
  zipping, every entry is scanned a second time by walking the DECODED
  report object graph (never the serialized JSON text, whose escaping hid
  credentials). Every decoded string is checked with the credential
  patterns; a credential-named field is additionally checked in its
  "name": "value" form; and the long base64/hex run rule applies to
  status free text (state, runId, lastError) and log lines only - never
  to path metadata or other fields. Validated metadata is exempt:
  SHA-256 hash values in hash-named fields (field name ending in
  sha256/hash, the value exactly 64 hex characters), values of path-named
  fields, and ACL sid fields in masked machine-local or well-known SID
  form - a bare 64-hex run in status text or a log line is rejected. A hit
  reports RedactionCheckFailed and produces NO zip (fail closed); the
  message names the entry, the field path, the line and the pattern,
  never the matched text.

  The bundle never contains raw status.json, runtime bundle file
  contents, pairing data, certificates or Moonlight settings: those are
  not collected at all, and diagnose.json itself only ever contains the
  report gs-diagnose.ps1 produced.

  Parameters. Exactly contract K1 (-OutputDir default
  %LOCALAPPDATA%\GsController\support; -InstallDir default this script's
  folder; -StateDir, -LogDir and -ServerInfoUri forwarded to
  gs-diagnose.ps1 only when non-empty; -TrayLogDir default
  %LOCALAPPDATA%\GsController\tray; -DiagnoseScript default the sibling
  gs-diagnose.ps1; -SkipInstalledProductLookup forwarded) plus three
  documented extras:
    -SupervisorTaskName  forwarded to gs-diagnose.ps1 for the hygiene
                         section's read-only scheduled task query
                         (default GsControllerSupervisor). Automated
                         tests pass '' so they never query the real task.
    -SkipHostCheck       forwarded to gs-diagnose.ps1 so automated tests
                         never hit the live read-only CIM queries of the
                         host section. Production runs (without the
                         switch) collect the host facts.
    -DiagnoseTimeoutSec  hard deadline, in seconds, that covers the
                         diagnose child's process exit AND the drain of
                         both output pipes (default 180). The child is
                         started inside a job object, so on expiry the
                         whole child tree is terminated - a grandchild
                         that inherited a pipe handle cannot outlive the
                         deadline. Automated tests pass a small value;
                         production callers omit it.
  There is deliberately NO switch to skip the hygiene ACL check: the
  read-only ACL assessment is always part of a support bundle (contract
  K2). The diagnose child runs with every argument encoded by the
  Windows native rules (backslashes before a quote and at the end of a
  quoted argument are doubled), so paths with spaces and trailing
  backslashes arrive intact. Any unexpected exception (an unmapped drive
  letter in a path, a process-start failure, ...) is caught by an outer
  boundary that returns the contract result object with the fixed
  English SupportFailed message and exits 1. The DiagnoseFailed error
  for a nonzero child exit carries the exit code only - raw child
  stderr never reaches the public result.

  -OutputDir must be an absolute path outside the install dir; a
  relative path, a path inside -InstallDir, or a path that exists as a
  file is rejected with OutputDirInvalid. The zip is written to a temp
  name and then renamed.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File gs-support.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir = ([System.IO.Path]::Combine($env:LOCALAPPDATA, 'GsController', 'support')),
    [string]$InstallDir = '',
    [string]$StateDir = '',
    [string]$LogDir = '',
    [string]$TrayLogDir = ([System.IO.Path]::Combine($env:LOCALAPPDATA, 'GsController', 'tray')),
    [string]$ServerInfoUri = '',
    [string]$DiagnoseScript = '',
    [switch]$SkipInstalledProductLookup,
    [string]$SupervisorTaskName = 'GsControllerSupervisor',
    # Forwarded to gs-diagnose.ps1: automated tests pass it so they never
    # hit the live read-only CIM queries of the host section.
    [switch]$SkipHostCheck,
    # Hard deadline (seconds) for the diagnose child, covering the process
    # exit AND the drain of both pipes. Documented test extra; production
    # callers omit it.
    [ValidateRange(5, 3600)][int]$DiagnoseTimeoutSec = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { Add-Type -AssemblyName System.IO.Compression | Out-Null } catch { }
try { Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null } catch { }

# Job object support: the diagnose child is placed in a job with
# KILL_ON_JOB_CLOSE so that on a deadline overrun the WHOLE child tree is
# terminated - including grandchildren that inherited a pipe handle and
# would otherwise hold a drain open after their parent already exited.
if (-not ('GsSupportChildJob' -as [type])) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class GsSupportChildJob
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetInformationJobObject(IntPtr hJob, int jobObjectInfoClass, ref JOBOBJECT_BASIC_LIMIT_INFORMATION jobObjectInfo, int cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateJobObject(IntPtr hJob, int uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    public const int JobObjectBasicLimitInformationClass = 2;
    public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
}
"@
    } catch { }
}

function Get-SupportProperty {
    # Safe property read for parsed JSON; $null when absent. The script
    # runs under Set-StrictMode, so direct property access on a report
    # that lacks a property would throw.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-SupportProductVersion {
    # Best-effort product version from the diagnose report: the installed
    # MSI display version, else the GsControl module version, else
    # 'unknown'.
    param($Report)
    $product = Get-SupportProperty $Report 'product'
    $msi = Get-SupportProperty $product 'installedMsi'
    $displayVersion = Get-SupportProperty $msi 'displayVersion'
    if (-not [string]::IsNullOrWhiteSpace([string]$displayVersion)) { return [string]$displayVersion }
    $modules = Get-SupportProperty $product 'modules'
    foreach ($module in @($modules)) {
        if ([string](Get-SupportProperty $module 'name') -eq 'GsControl') {
            $version = Get-SupportProperty $module 'version'
            if (-not [string]::IsNullOrWhiteSpace([string]$version)) { return [string]$version }
        }
    }
    return 'unknown'
}

function ConvertTo-SupportWindowsArgument {
    # Encodes one argument with the Windows native command-line rules:
    # arguments containing whitespace or a quote are wrapped in quotes,
    # backslashes that PRECEDE a quote are doubled (together with the
    # quote's own escape backslash), and the trailing backslashes of a
    # quoted argument are doubled before the closing quote - otherwise
    # "C:\Gs State\" would escape its own closing quote. Plain tokens
    # without whitespace or quotes are returned unquoted and untouched.
    # Backslashes are buffered, not appended as they are scanned: only
    # then is the count right when they must be doubled at a quote or at
    # the closing quote.
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $needsQuotes = (($Value.Length -eq 0) -or ($Value.IndexOfAny([char[]]@(' ', "`t", '"')) -ge 0))
    $builder = New-Object System.Text.StringBuilder
    if ($needsQuotes) { $null = $builder.Append('"') }
    $pendingBackslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $pendingBackslashes++
            continue
        }
        if ($character -eq '"') {
            # All pending backslashes are doubled plus one escape for the
            # quote itself.
            $null = $builder.Append('\', (2 * $pendingBackslashes + 1))
            $null = $builder.Append('"')
            $pendingBackslashes = 0
            continue
        }
        if ($pendingBackslashes -gt 0) {
            # Backslashes not followed by a quote are literal.
            $null = $builder.Append('\', $pendingBackslashes)
            $pendingBackslashes = 0
        }
        $null = $builder.Append($character)
    }
    if ($needsQuotes) {
        # Trailing backslashes are doubled before the closing quote.
        $null = $builder.Append('\', (2 * $pendingBackslashes))
        $null = $builder.Append('"')
    } elseif ($pendingBackslashes -gt 0) {
        $null = $builder.Append('\', $pendingBackslashes)
    }
    return $builder.ToString()
}

function Invoke-SupportKillProcessTree {
    # Kills one process and every descendant (the diagnose child plus, for
    # example, a sleeping grandchild that inherited the stdout handle).
    # taskkill /T /F walks the tree; a direct Stop-Process is the fallback.
    param([int]$ProcessId)
    try {
        $taskkill = Join-Path ([System.Environment]::SystemDirectory) 'taskkill.exe'
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $taskkill
        $startInfo.Arguments = ('/PID ' + $ProcessId + ' /T /F')
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $killer = [System.Diagnostics.Process]::Start($startInfo)
        try { $null = $killer.WaitForExit(5000) } finally { $killer.Dispose() }
    } catch {
        try { Get-Process -Id $ProcessId -ErrorAction Stop | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Invoke-SupportDiagnose {
    # Runs the diagnose script in a child powershell.exe under ONE hard
    # deadline that covers the process exit AND the drain of both pipes:
    # a descendant that inherits the child's stdout can hold a pipe open
    # after the child has exited, so waiting only for the process would
    # still hang. On expiry the whole child tree is killed and the
    # streams are disposed. Arguments are encoded with the Windows native
    # rules, including the diagnose path.
    param([string]$DiagnosePath, [string[]]$ArgumentList, [int]$TimeoutSeconds = 180)

    $exe = Join-Path $PSHOME 'powershell.exe'
    $argText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-SupportWindowsArgument $DiagnosePath)
    foreach ($token in @($ArgumentList)) {
        $argText = $argText + ' ' + (ConvertTo-SupportWindowsArgument ([string]$token))
    }
    $proc = New-Object System.Diagnostics.Process
    $outTask = $null
    $errTask = $null
    $timedOut = $false
    $exitCode = $null
    $jobHandle = [IntPtr]::Zero
    try {
        $proc.StartInfo.FileName = $exe
        $proc.StartInfo.Arguments = $argText
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $null = $proc.Start()
        # Own the whole child tree: the child joins a job whose every
        # descendant inherits membership, so one TerminateJobObject kills
        # the tree even if the direct child has already exited while a
        # grandchild keeps a pipe handle open.
        try {
            $jobHandle = [GsSupportChildJob]::CreateJobObject([IntPtr]::Zero, $null)
            if ($jobHandle -ne [IntPtr]::Zero) {
                $limits = New-Object GsSupportChildJob+JOBOBJECT_BASIC_LIMIT_INFORMATION
                $limits.LimitFlags = [GsSupportChildJob]::JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                $limitsSize = [System.Runtime.InteropServices.Marshal]::SizeOf($limits)
                $null = [GsSupportChildJob]::SetInformationJobObject($jobHandle, [GsSupportChildJob]::JobObjectBasicLimitInformationClass, [ref]$limits, $limitsSize)
                $null = [GsSupportChildJob]::AssignProcessToJobObject($jobHandle, $proc.Handle)
            }
        } catch {
            $jobHandle = [IntPtr]::Zero
        }
        # Drain both pipes asynchronously from the start: waiting for exit
        # before reading would deadlock once the child fills a pipe buffer.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        if (-not $proc.WaitForExit([Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds))) {
            $timedOut = $true
        } else {
            $exitCode = $proc.ExitCode
            # The deadline also bounds the pipe drains: a surviving
            # descendant holding a pipe handle may keep a read pending
            # forever after the child itself has exited.
            $remainingMs = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $outDone = $false
            try { $outDone = $outTask.Wait($remainingMs) } catch { $outDone = $true }
            $remainingMs = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $errDone = $false
            try { $errDone = $errTask.Wait($remainingMs) } catch { $errDone = $true }
            if (-not ($outDone -and $errDone)) { $timedOut = $true }
        }
        if ($timedOut) {
            if ($jobHandle -ne [IntPtr]::Zero) {
                try { $null = [GsSupportChildJob]::TerminateJobObject($jobHandle, 1) } catch { }
            }
            # Best effort for anything that escaped the job (the taskkill
            # tree walk is a no-op when the direct child already exited).
            try { Invoke-SupportKillProcessTree -ProcessId $proc.Id } catch { }
        }
        # Read whatever the pipes delivered. After the tree is killed every
        # pipe writer is gone, so the tasks complete within a short grace;
        # anything still pending is abandoned and disposed below.
        $stdout = ''
        $stderrText = ''
        try { $null = $outTask.Wait(3000) } catch { }
        if ($outTask.IsCompleted) { try { $stdout = [string]$outTask.Result } catch { $stdout = '' } }
        try { $null = $errTask.Wait(3000) } catch { }
        if ($errTask.IsCompleted) { try { $stderrText = [string]$errTask.Result } catch { $stderrText = '' } }
        return @{ TimedOut = $timedOut; ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderrText }
    } finally {
        if ($timedOut) {
            if ($jobHandle -ne [IntPtr]::Zero) {
                try { $null = [GsSupportChildJob]::TerminateJobObject($jobHandle, 1) } catch { }
            }
            try { Invoke-SupportKillProcessTree -ProcessId $proc.Id } catch { }
        }
        if ($jobHandle -ne [IntPtr]::Zero) {
            try { $null = [GsSupportChildJob]::CloseHandle($jobHandle) } catch { }
        }
        try { if ($null -ne $proc.StandardOutput) { $proc.StandardOutput.Dispose() } } catch { }
        try { if ($null -ne $proc.StandardError) { $proc.StandardError.Dispose() } } catch { }
        $proc.Dispose()
    }
}

function Get-SupportCredentialPatterns {
    # The credential-pattern table for the second pass. Every value pattern
    # requires a NON-placeholder value, so correctly redacted content
    # ('token=<redacted>', 'Authorization: <redacted>', 'PIN <redacted>',
    # ...) passes. The long base64/hex run rule is NOT part of this table:
    # it is applied only to status free text and log lines (see
    # Add-SupportSecretScanHits).
    $keyCore = '(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_.-])*(?:token|secret|password|passwd|pwd|apikey|api[_-]?key|auth|authorization|bearer|cookie|session(?:id)?|sid|rikey(?:id)?|private[_-]?key|privatekey|pin|cert(?:ificate)?|credential)s?(?:[_.-][A-Za-z0-9]+)*(?![A-Za-z0-9])'
    return [ordered]@{
        'pem-marker'      = '-----\s*BEGIN'
        'scheme-token'    = '(?i)\b(?:Bearer|Basic)[ \t]+["'']?(?!<redacted>)[A-Za-z0-9._~+/=-]{8,}'
        'scheme-token-16' = '(?i)\b(?:Digest|Negotiate|NTLM)[ \t]+["'']?(?!<redacted>)[A-Za-z0-9._~+/=-]{16,}'
        'header-form'     = '(?i)(?<![A-Za-z0-9_-])(?:Proxy[-_]?Authorization|Authorization|X[-_]?Api[-_]?Key|Cookie|Set-Cookie)[ \t]*:[ \t]*(?!<redacted>)\S'
        'credential-pair' = ('(?i)' + $keyCore + '[''\"]?[ \t]*[:=][ \t]*[''\"]?(?!<redacted>)[^\s''\",;&]{4,}')
        'bare-word'       = '(?i)(?<![A-Za-z0-9])(?:pin|password|passwd|pwd|passcode|passphrase|secret|token)s?[ \t]+(?!<redacted>)[^\s'',;&]{3,}'
        'url-param'       = '(?i)[?&#](?:[a-z0-9]+[_.-])*(?:token|secret|password|passwd|pwd|apikey|api[_-]?key|auth|authorization|bearer|cookie|session(?:id)?|sid|rikey(?:id)?|pin|credential|sig(?:nature)?)s?(?:[_.-][a-z0-9]+)*=(?!<redacted>)[^\s&#]{4,}'
    }
}

$script:SupportCredentialPatterns = Get-SupportCredentialPatterns
$script:SupportPairPattern = $script:SupportCredentialPatterns['credential-pair']
$script:SupportLongRunPattern = '[A-Za-z0-9+/=]{32,}'

function Test-SupportIsMetadataValue {
    # Validated metadata is exempt from the secret scan: a SHA-256 hash
    # value in a HASH-NAMED field (field name ending in sha256/hash; the
    # value itself must still be exactly 64 hex characters - a bare 64-hex
    # run in status text or a log line is a planted-key shape and stays
    # scanned), a value in a path-named field (path, dir, uri, root), and
    # a SID stored in an ACL sid field (masked machine-local or well-known
    # SID form).
    param([string]$FieldName, [string]$Value)
    if (($Value -match '^[0-9a-fA-F]{64}$') -and ($FieldName -match '(?i)(sha256|hash)$')) { return $true }
    if ($FieldName -match '(?i)(path|dir|uri|root)$') { return $true }
    if (($FieldName -match '(?i)^(owner)?sid$') -and ($Value -match '^S-1-[0-9*]+(-[0-9*]+)*$')) { return $true }
    return $false
}

function Add-SupportPatternHits {
    # Runs one pattern table over a text line by line and appends
    # { entry; field; line; pattern } hits. The matched text is NEVER
    # included.
    param([string]$Text, $Patterns, [string]$EntryName, [string]$FieldPath, $Hits)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $lines = [System.Text.RegularExpressions.Regex]::Split($Text, '\r\n|\n|\r')
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        foreach ($name in $Patterns.Keys) {
            if ([System.Text.RegularExpressions.Regex]::IsMatch($line, [string]$Patterns[$name], [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                $Hits.Add([pscustomobject]@{ entry = $EntryName; field = $FieldPath; line = $lineNumber; pattern = $name })
            }
        }
    }
}

function Add-SupportSecretScanHits {
    # Depth-first walk over the DECODED report object graph - never the
    # serialized JSON text, whose escaping let escaped credential pairs
    # slip through. Every decoded string is scanned with the credential
    # patterns; a credential-named field is additionally scanned in its
    # "name": "value" form so the key context is preserved. The long
    # base64/hex run rule applies ONLY to status free text (state, runId,
    # lastError) and to log lines (elements of a lines[] array) - never to
    # path metadata or other fields. Validated metadata (hash values,
    # path-named fields, ACL SID fields) is exempt.
    param($Node, [string]$EntryName, [string]$FieldName, [string]$FieldPath, [bool]$InStatus, [bool]$InLines, $Hits)

    if ($null -eq $Node) { return }
    if ($Node -is [string]) {
        $value = [string]$Node
        if ($value.Length -eq 0) { return }
        if (Test-SupportIsMetadataValue -FieldName $FieldName -Value $value) { return }
        Add-SupportPatternHits -Text $value -Patterns $script:SupportCredentialPatterns -EntryName $EntryName -FieldPath $FieldPath -Hits $Hits
        if ($FieldName.Length -gt 0) {
            # The same string in its serialized key:value form, so a
            # credential-named report field is caught exactly like the old
            # serialized scan caught it.
            Add-SupportPatternHits -Text ('"' + $FieldName + '": "' + $value + '"') -Patterns ([ordered]@{ 'credential-pair' = $script:SupportPairPattern }) -EntryName $EntryName -FieldPath $FieldPath -Hits $Hits
        }
        $longRunApplies = $InLines -or ($InStatus -and ($FieldName -match '(?i)^(state|runId|run_id|lastError|last_error|error)$'))
        if ($longRunApplies) {
            Add-SupportPatternHits -Text $value -Patterns ([ordered]@{ 'long-run' = $script:SupportLongRunPattern }) -EntryName $EntryName -FieldPath $FieldPath -Hits $Hits
        }
        return
    }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) {
            $childPath = $(if ($FieldPath.Length -gt 0) { $FieldPath + '.' + [string]$key } else { [string]$key })
            $childStatus = $InStatus -or ([string]$key -eq 'status')
            Add-SupportSecretScanHits -Node $Node[$key] -EntryName $EntryName -FieldName ([string]$key) -FieldPath $childPath -InStatus $childStatus -InLines $InLines -Hits $Hits
        }
        return
    }
    if ($Node -is [pscustomobject]) {
        foreach ($prop in @($Node.PSObject.Properties)) {
            $childPath = $(if ($FieldPath.Length -gt 0) { $FieldPath + '.' + $prop.Name } else { $prop.Name })
            $childStatus = $InStatus -or ($prop.Name -eq 'status')
            Add-SupportSecretScanHits -Node $prop.Value -EntryName $EntryName -FieldName $prop.Name -FieldPath $childPath -InStatus $childStatus -InLines $InLines -Hits $Hits
        }
        return
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $index = 0
        foreach ($element in @($Node)) {
            $elementPath = $FieldPath + '[' + $index + ']'
            Add-SupportSecretScanHits -Node $element -EntryName $EntryName -FieldName $FieldName -FieldPath $elementPath -InStatus $InStatus -InLines ($InLines -or ($FieldName -ieq 'lines')) -Hits $Hits
            $index++
        }
        return
    }
    # Any other scalar (number, boolean, datetime) carries no text.
    return
}

function Write-SupportZipBytes {
    # Writes name -> byte[] entries into a NEW zip file. The caller writes
    # to a temp path and renames after success.
    param([string]$ZipPath, [System.Collections.Specialized.OrderedDictionary]$EntriesByName)
    $stream = $null
    $zip = $null
    try {
        $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($name in $EntriesByName.Keys) {
            $bytes = $EntriesByName[$name]
            $entry = $zip.CreateEntry($name)
            $entryStream = $entry.Open()
            try { $entryStream.Write($bytes, 0, $bytes.Length) } finally { $entryStream.Dispose() }
        }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Invoke-SupportBundle {
    # The whole pipeline. Returns { Success; ZipPath; Entries; Errors }.
    param(
        [string]$BundleOutputDir,
        [string]$BundleInstallDir,
        [string]$BundleStateDir,
        [string]$BundleLogDir,
        [string]$BundleTrayLogDir,
        [string]$BundleServerInfoUri,
        [string]$BundleDiagnoseScript,
        [bool]$BundleSkipInstalledProductLookup,
        [string]$BundleSupervisorTaskName,
        [bool]$BundleSkipHostCheck,
        [int]$BundleDiagnoseTimeoutSeconds,
        [string]$BundleScriptRoot
    )

    $errors = New-Object System.Collections.Generic.List[object]
    $zipFinal = $null
    $entriesOut = @()

    # ---- 1. InstallDir and OutputDir resolution and validation ----
    if ([string]::IsNullOrWhiteSpace($BundleInstallDir)) { $BundleInstallDir = $BundleScriptRoot }
    $installFull = $null
    if (-not [string]::IsNullOrWhiteSpace($BundleInstallDir)) {
        try { $installFull = [System.IO.Path]::GetFullPath($BundleInstallDir) } catch { $installFull = $null }
    }

    $outputFull = $null
    if ([string]::IsNullOrWhiteSpace($BundleOutputDir)) {
        $errors.Add([pscustomobject]@{ code = 'OutputDirInvalid'; message = 'OutputDir is empty.' })
    } elseif (-not [System.IO.Path]::IsPathRooted($BundleOutputDir)) {
        $errors.Add([pscustomobject]@{ code = 'OutputDirInvalid'; message = 'OutputDir must be an absolute path; a relative path was given.' })
    } else {
        try { $outputFull = [System.IO.Path]::GetFullPath($BundleOutputDir) } catch {
            $errors.Add([pscustomobject]@{ code = 'OutputDirInvalid'; message = ('OutputDir is not a usable path: ' + $_.Exception.Message) })
        }
    }
    if ($null -ne $outputFull) {
        if ($null -ne $installFull) {
            $installPrefix = $installFull
            if (-not $installPrefix.EndsWith('\')) { $installPrefix = $installPrefix + '\' }
            $outputPrefix = $outputFull
            if (-not $outputPrefix.EndsWith('\')) { $outputPrefix = $outputPrefix + '\' }
            if ($outputFull -ieq $installFull) {
                $errors.Add([pscustomobject]@{ code = 'OutputDirInvalid'; message = 'OutputDir must not be the install dir.' })
            } elseif ($outputPrefix.StartsWith($installPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $errors.Add([pscustomobject]@{ code = 'OutputDirInvalid'; message = 'OutputDir must not be inside the install dir.' })
            }
        }
        if ($errors.Count -eq 0) {
            if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
                $errors.Add([pscustomobject]@{ code = 'OutputDirInvalid'; message = 'OutputDir exists as a file, not a directory.' })
            } elseif (-not (Test-Path -LiteralPath $outputFull -PathType Container)) {
                try { New-Item -ItemType Directory -Path $outputFull -Force | Out-Null } catch {
                    $errors.Add([pscustomobject]@{ code = 'OutputDirInvalid'; message = ('OutputDir could not be created: ' + $_.Exception.Message) })
                }
            }
        }
    }
    if ($errors.Count -gt 0) {
        return @{ Success = $false; ZipPath = $null; Entries = @(); Errors = $errors.ToArray() }
    }

    # ---- 2. Locate the diagnose script ----
    $diagnosePath = $BundleDiagnoseScript
    if ([string]::IsNullOrWhiteSpace($diagnosePath)) { $diagnosePath = Join-Path $BundleScriptRoot 'gs-diagnose.ps1' }
    if (-not (Test-Path -LiteralPath $diagnosePath -PathType Leaf)) {
        $errors.Add([pscustomobject]@{ code = 'DiagnoseUnavailable'; message = ('gs-diagnose.ps1 was not found at ' + $diagnosePath + '.') })
        return @{ Success = $false; ZipPath = $null; Entries = @(); Errors = $errors.ToArray() }
    }

    # ---- 3. Build arguments and run the diagnose child ----
    # Every token is passed RAW and encoded once, inside
    # Invoke-SupportDiagnose, by the Windows native rules - never quoted
    # by hand here (a hand-quoted trailing backslash would escape its own
    # closing quote).
    $diagnoseArgs = @('-AsJson')
    $diagnoseArgs += @('-InstallDir', $installFull)
    if (-not [string]::IsNullOrWhiteSpace($BundleStateDir)) { $diagnoseArgs += @('-StateDir', $BundleStateDir) }
    if (-not [string]::IsNullOrWhiteSpace($BundleLogDir)) { $diagnoseArgs += @('-LogDir', $BundleLogDir) }
    if (-not [string]::IsNullOrWhiteSpace($BundleServerInfoUri)) { $diagnoseArgs += @('-ServerInfoUri', $BundleServerInfoUri) }
    if ($BundleSkipInstalledProductLookup) { $diagnoseArgs += '-SkipInstalledProductLookup' }
    if ($BundleSkipHostCheck) { $diagnoseArgs += '-SkipHostCheck' }
    $diagnoseArgs += @('-SupervisorTaskName', $BundleSupervisorTaskName)

    $extraLogPaths = @()
    if (-not [string]::IsNullOrWhiteSpace($BundleTrayLogDir)) {
        foreach ($logName in @('tray.log', 'tray.log.1')) {
            $candidate = Join-Path $BundleTrayLogDir $logName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $extraLogPaths += $candidate }
        }
    }
    if ($extraLogPaths.Count -gt 0) {
        # powershell.exe -File cannot pass an array argument, so the paths
        # are '|'-joined into one value; gs-diagnose.ps1 splits on '|' ('|'
        # is illegal in Windows paths).
        $diagnoseArgs += @('-ExtraLogPath', ($extraLogPaths -join '|'))
    }

    Write-Verbose ('Running diagnose: ' + $diagnosePath)
    $child = Invoke-SupportDiagnose -DiagnosePath $diagnosePath -ArgumentList $diagnoseArgs -TimeoutSeconds $BundleDiagnoseTimeoutSeconds

    $report = $null
    if ($child.TimedOut) {
        $errors.Add([pscustomobject]@{ code = 'DiagnoseFailed'; message = ('The diagnose child exceeded its ' + $BundleDiagnoseTimeoutSeconds + 's deadline and was killed.') })
    } elseif ($child.ExitCode -ne 0) {
        # Fixed English message plus the exit code only: raw child stderr
        # never reaches the public result (it can contain anything the
        # child printed, secrets included).
        $errors.Add([pscustomobject]@{ code = 'DiagnoseFailed'; message = ('The diagnose child exited with code ' + $child.ExitCode + '.') })
    } else {
        $stdoutText = [string]$child.StdOut
        if ([string]::IsNullOrWhiteSpace($stdoutText)) {
            $errors.Add([pscustomobject]@{ code = 'DiagnoseFailed'; message = 'The diagnose child produced no output.' })
        } else {
            try { $report = $stdoutText.Trim() | ConvertFrom-Json } catch { $report = $null }
            if ($null -eq $report) {
                $errors.Add([pscustomobject]@{ code = 'DiagnoseFailed'; message = 'The diagnose output is not valid JSON.' })
            } else {
                $schemaValue = [string](Get-SupportProperty $report 'schemaVersion')
                if ($schemaValue -ne '1') {
                    $errors.Add([pscustomobject]@{ code = 'DiagnoseFailed'; message = ('The diagnose report schemaVersion is ' + $schemaValue + ', expected 1.') })
                }
            }
        }
    }
    if ($errors.Count -gt 0) {
        return @{ Success = $false; ZipPath = $null; Entries = @(); Errors = $errors.ToArray() }
    }

    # ---- 4. Build the entry texts ----
    $diagnoseJsonText = [string]$child.StdOut.Trim()
    $extraLogsValue = Get-SupportProperty $report 'extraLogs'
    if ($null -eq $extraLogsValue -or (@($extraLogsValue).Count -eq 0)) {
        # The empty entry is exactly '[]'; PS 5.1 ConvertTo-Json would
        # render an empty array as a padded multi-line form.
        $extraJsonText = '[]'
    } else {
        $extraJsonText = [string](ConvertTo-Json -InputObject @($extraLogsValue) -Depth 8)
    }
    $generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $productVersion = Get-SupportProductVersion $report

    # ---- 5. Second pass over the DECODED entries (fail closed) ----
    # The scan walks the decoded report object graph, not the serialized
    # JSON text: JSON escaping hid escaped credential pairs from the old
    # serialized scan.
    $allHits = New-Object System.Collections.Generic.List[object]
    Add-SupportSecretScanHits -Node $report -EntryName 'diagnose.json' -FieldName '' -FieldPath '' -InStatus $false -InLines $false -Hits $allHits
    if ($null -ne $extraLogsValue) {
        Add-SupportSecretScanHits -Node @($extraLogsValue) -EntryName 'extra-logs.json' -FieldName 'extraLogs' -FieldPath '' -InStatus $false -InLines $false -Hits $allHits
    }

    # ---- 6. Manifest (hashes over the exact bytes that are zipped) ----
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $diagnoseBytes = $utf8NoBom.GetBytes($diagnoseJsonText)
    $extraBytes = $utf8NoBom.GetBytes($extraJsonText)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $diagnoseHash = ([System.BitConverter]::ToString($sha256.ComputeHash($diagnoseBytes))).Replace('-', '').ToLowerInvariant()
        $extraHash = ([System.BitConverter]::ToString($sha256.ComputeHash($extraBytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha256.Dispose() }
    $manifestEntries = New-Object System.Collections.Generic.List[object]
    $manifestEntries.Add([pscustomobject]@{ name = 'diagnose.json'; sha256 = $diagnoseHash; sizeBytes = [int64]$diagnoseBytes.Length })
    $manifestEntries.Add([pscustomobject]@{ name = 'extra-logs.json'; sha256 = $extraHash; sizeBytes = [int64]$extraBytes.Length })
    # The manifest cannot hash itself; its own row stays null.
    $manifestEntries.Add([pscustomobject]@{ name = 'manifest.json'; sha256 = $null; sizeBytes = $null })
    $manifestObject = [pscustomobject]@{
        schemaVersion  = 1
        generatedAtUtc = $generatedAtUtc
        productVersion = $productVersion
        entries        = $manifestEntries.ToArray()
    }
    $manifestText = [string](ConvertTo-Json -InputObject $manifestObject -Depth 6)
    $manifestBytes = $utf8NoBom.GetBytes($manifestText)

    Add-SupportSecretScanHits -Node $manifestObject -EntryName 'manifest.json' -FieldName '' -FieldPath '' -InStatus $false -InLines $false -Hits $allHits

    if ($allHits.Count -gt 0) {
        $first = $allHits[0]
        $summary = ('RedactionCheckFailed: ' + $first.entry + ' field ' + $first.field + ' line ' + $first.line + ' matched pattern ' + $first.pattern)
        if ($allHits.Count -gt 1) { $summary = $summary + (' (and ' + ($allHits.Count - 1) + ' more hit(s))') }
        $errors.Add([pscustomobject]@{ code = 'RedactionCheckFailed'; message = $summary })
        return @{ Success = $false; ZipPath = $null; Entries = @(); Errors = $errors.ToArray() }
    }

    # ---- 7. Zip to a temp name, then rename ----
    $zipFinal = Join-Path $outputFull ('GsController-support-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.zip')
    $suffix = 1
    while (Test-Path -LiteralPath $zipFinal) {
        $zipFinal = Join-Path $outputFull ('GsController-support-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + $suffix + '.zip')
        $suffix++
    }
    $zipTmp = $zipFinal + '.tmp'
    $entriesByName = New-Object System.Collections.Specialized.OrderedDictionary
    $entriesByName['diagnose.json'] = $diagnoseBytes
    $entriesByName['extra-logs.json'] = $extraBytes
    $entriesByName['manifest.json'] = $manifestBytes
    try {
        Write-SupportZipBytes -ZipPath $zipTmp -EntriesByName $entriesByName
        [System.IO.File]::Move($zipTmp, $zipFinal)
    } catch {
        if (Test-Path -LiteralPath $zipTmp) { try { Remove-Item -LiteralPath $zipTmp -Force } catch { } }
        $errors.Add([pscustomobject]@{ code = 'ZipFailed'; message = ('Could not write the zip archive: ' + $_.Exception.Message) })
        return @{ Success = $false; ZipPath = $null; Entries = @(); Errors = $errors.ToArray() }
    }

    foreach ($entry in $manifestEntries.ToArray()) {
        if ($entry.name -eq 'manifest.json') {
            $entriesOut += [pscustomobject]@{ name = 'manifest.json'; sha256 = $null; sizeBytes = $null }
        } else {
            $entriesOut += $entry
        }
    }
    return @{ Success = $true; ZipPath = $zipFinal; Entries = $entriesOut; Errors = @() }
}

# ---------------------------------------------------------------------------
# Main. The LAST output element is the result object; exit 0 on success,
# 1 on failure.
# ---------------------------------------------------------------------------
$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

$bundleResult = $null
try {
    $bundleResult = Invoke-SupportBundle `
        -BundleOutputDir $OutputDir `
        -BundleInstallDir $InstallDir `
        -BundleStateDir $StateDir `
        -BundleLogDir $LogDir `
        -BundleTrayLogDir $TrayLogDir `
        -BundleServerInfoUri $ServerInfoUri `
        -BundleDiagnoseScript $DiagnoseScript `
        -BundleSkipInstalledProductLookup ([bool]$SkipInstalledProductLookup) `
        -BundleSupervisorTaskName $SupervisorTaskName `
        -BundleSkipHostCheck ([bool]$SkipHostCheck) `
        -BundleDiagnoseTimeoutSeconds $DiagnoseTimeoutSec `
        -BundleScriptRoot $scriptRoot
} catch {
    # Outer exception boundary: any unexpected throw (for example a
    # TrayLogDir on an unmapped drive letter, or a process-start failure)
    # still returns the contract result object, with a fixed English
    # message that carries no exception details, and exits 1.
    $bundleResult = @{
        Success = $false
        ZipPath = $null
        Entries = @()
        Errors  = @([pscustomobject]@{ code = 'SupportFailed'; message = 'The support bundle failed unexpectedly.' })
    }
}

Write-Output ([pscustomobject]@{
    schemaVersion = 1
    Success       = ([bool]$bundleResult.Success)
    ZipPath       = $bundleResult.ZipPath
    Entries       = @($bundleResult.Entries)
    Errors        = @($bundleResult.Errors)
})

if ($bundleResult.Success) { exit 0 }
exit 1
