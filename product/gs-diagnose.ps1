#requires -Version 5.1
<#
.SYNOPSIS
  Read-only diagnostics report for the GsController product and its runtime
  layout.

.DESCRIPTION
  Collects the product entry hash and module versions, the runtime
  configuration, the runtime status file, the streamer serverinfo response,
  component PID files, runtime bundle file listings and the supervisor log
  tail into a single report.

  The script imports no product modules (it must work when they are broken).
  It writes nothing, starts and stops nothing, and never prints the contents
  of runtime bundle files: only names, sizes, timestamps and SHA-256 hashes.

  Every section carries its own data and an errors array; missing or broken
  inputs are reported, never thrown. The exit code is 0 even when sections
  fail. Only invalid parameter usage throws (a non-http -ServerInfoUri, an
  out-of-range -TimeoutSec, -LogTailLines or -LogScanMaxBytes, or paths with
  illegal characters). Each section collector additionally runs under a
  guard: an unexpected exception becomes a SectionFailed error in that
  section and the report is still produced with exit code 0.

  Components. A component is reported as running when a process with the
  PID recorded in its PID file exists. The identity of that process is not
  verified (it could be any process), and operating systems reuse PIDs, so
  running=true does not prove the recorded component is the one running.

  Paths. -InstallDir, -StateDir, -LogDir and -ModuleRoot are normalized
  once with [System.IO.Path]::GetFullPath before use; nothing is probed for
  existence at that point, so paths on drives that are not present are
  reported as missing data instead of failing the run. Relative parameters
  resolve against the process current directory ([Environment]::
  CurrentDirectory), not the PowerShell location ($PWD). Every derived path
  is built with [System.IO.Path]::Combine.

  Redaction. In log lines and free-text fields (status fields, error
  messages), values of key=value / "key": "value" pairs whose key looks
  like a credential are replaced with <redacted>. A credential key may sit
  inside a longer key with _ . - separators or a prefix (access_token,
  refresh_token, client_secret, x-api-key, sessionid, passwd, rikeyid,
  private_key, ...) but never fires inside an ordinary word (pinball,
  spinning, opinion, certainly). Separators: = , : , and the quoted JSON
  forms "key": , \"key\": and 'key': . Values: a quoted string (honoring
  \" escapes), a JSON array (the whole balanced [...] found by a bracket
  scanner that honors quotes and \" escapes, nests up to 32 levels and
  scans at most 4096 characters; when no matching ] exists within the cap,
  or the depth is exceeded, the rest of the line is redacted), or a bare
  run up to , ; & whitespace or end.
  Header forms (Authorization, Proxy-Authorization, X-Api-Key, Cookie,
  Set-Cookie) are matched anywhere in a line, not only at its start; a
  name preceded by a letter, digit, '_' or '-' is a longer word
  (xauthorization, my-cookie), not a header. When the name is directly
  preceded by a quote, the value runs to the first UNESCAPED closing
  quote of the same kind (\" and \' escapes do not close it) and
  the closing quote plus the rest of the line are kept; otherwise the
  value runs to the end of the line. Auth-scheme words (Bearer, Basic,
  Digest, Negotiate, NTLM) keep the scheme word and replace a following
  token when it looks like a credential: Bearer always redacts 8+
  characters of [A-Za-z0-9._~+/=-], Basic 8+ characters of the base64
  alphabet [A-Za-z0-9+/=], and Digest, Negotiate and NTLM 16+ token
  characters, so prose like "basic setup done" is untouched. A line that
  ends with a credential key + separator and no value ("token=",
  "password:", YAML "password:") masks the next non-empty line entirely;
  an empty line in between does not clear that state, and in log lines
  it carries across lines like the PEM state.
  URL query and fragment parameters whose name is a credential (token=,
  sig=, access_token=, ...; sig and signature count as credential names
  here) redact the parameter value. Bare "PIN 1234" / "pin: 1234" forms
  are redacted; "spinning=1234" and "pinball=1234" are left alone.
  PEM blocks from -----BEGIN through -----END are replaced with
  <redacted>, including blocks that span several lines; markers are
  processed in their text order within a line, any line containing a
  marker is fully masked, a line whose last marker is BEGIN leaves the
  scan inside the block, and a BEGIN without a matching END masks
  everything to the end of the input. In log lines only, base64/hex runs
  of 32 or more characters are replaced as well; free text keeps long hex
  paths intact. The report's own computed SHA-256 fields are never
  redacted.

  Supervisor log reading. -LogTailLines 0 never opens the file at all.
  Otherwise the log is opened with FileShare ReadWrite|Delete (writers and
  renames keep working), read only up to the file length captured at open,
  at most -LogScanMaxBytes bytes counted from the end of the file (default:
  the last 8 MB) and at most -TimeoutSec seconds in total. Lines stream
  through a ring buffer of the last -LogTailLines lines and are redacted
  while reading, with the PEM state and the pending multi-line credential
  state kept across lines. PEM markers are scanned in every raw chunk of a
  line, including the part beyond the raw per-line cap (a marker split
  across chunk boundaries is still found through a small overlap), so a
  marker past the cap still opens or closes its block. Any line longer
  than the raw cap is emitted as <redacted: long line truncated>. When the
  scan starts mid-file, the partial line at the boundary is skipped to the
  next newline and the PEM state is unknown: everything is masked until the
  first -----END marker. Each line is assembled in bounded chunks (a
  newline-free megabyte-long line is never held whole). The section
  reports truncated, scannedBytes, incomplete and unterminatedPem.

  serverinfo. The section is ok only for HTTP 200 with an XML body whose
  root element is `root` (case-sensitive), a numeric status_code attribute
  of 200, a non-empty <state> after trimming and an all-digit
  <currentgame> after trimming (the value reported is the trimmed digits);
  anything else yields a specific error code (UnexpectedStatus, EmptyBody,
  InvalidXml, UnexpectedRoot, ProtocolStatus, MissingField, InvalidField,
  Timeout, BodyTooLarge, RequestFailed, ReadFailed) while the raw HTTP
  status is still reported. Auto-redirect is disabled and only plain
  http:// is accepted. The body is read in bounded chunks with a 64 KB cap
  counted on the raw bytes before decoding, under a total deadline of
  -TimeoutSec measured from request start; both the response wait and each
  chunk read use async I/O with waits bounded by the remaining time, and
  on overrun the request is aborted and Timeout or BodyTooLarge is
  reported.
  serverInfo.uri is a display URI: userinfo removed, query and fragment
  dropped, so credentials passed in the URL never reach the report.

  Status file candidates, in order: <StateDir>\runtime\state\status.json,
  then <StateDir>\status.json. When both exist the one with the newer
  LastWriteTimeUtc is used; on a tie the first candidate is used. The path
  used is reported. Only whitelisted fields are read (state; runId|run_id;
  lastError|last_error|error); the file is never dumped as a whole.

  Hygiene. The hygiene section runs additional read-only checks. The
  scheduled task named by -SupervisorTaskName is probed read-only (an
  empty name skips the query): a task without gs-product.ps1 in the
  install dir is OrphanedSupervisorTask, a missing task is
  SupervisorTaskMissing. Both supervisor pause flag candidates
  (<StateDir>\supervisor_pause.flag and
  <StateDir>\runtime\state\supervisor_pause.flag) are checked; a present
  flag is SupervisorPaused, reported with its last write time and its
  first line (redacted, at most 200 characters). The ACLs of
  <StateDir>\runtime and <StateDir>\runtime\bin are read read-only with
  Get-Acl (-SkipAclCheck skips the read): an Allow ACE that grants a write
  right (write data, append data, write EA, delete child, write
  attributes, delete, write DACL, write owner, generic all, generic
  write) to a SID outside the administrative allowlist (SYSTEM
  S-1-5-18, Administrators S-1-5-32-544, TrustedInstaller
  S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464), or an
  owner outside that allowlist, is ScriptDirWritableByNonAdmin (severity
  high). Inherit-only CREATOR OWNER (S-1-3-0) ACEs are ignored; deny ACEs
  are never grants. Both status candidates existing at once is
  StatusFileAmbiguous. Every finding is {code, severity, message, path};
  SIDs are classified by SID string only, never account names, so the
  result is locale-independent. Machine-local SIDs
  (S-1-5-21-a-b-c-RID) are masked to S-1-5-21-*-RID everywhere: while
  the ACL section is built AND in a final pass over every emitted string
  of the finished report (pause flag first lines, log lines, paths,
  error messages included). ACL read and parse failures are reported
  with fixed messages that never carry the raw exception text. The
  report contains no raw SDDL. -SupervisorTaskInfo and
  -ScriptDirAclSddl are documented TEST SEAMS: when bound, they replace
  the real task query and the real ACL read with injected values
  (-SupervisorTaskInfo: an object with State and Actions[].Execute, or
  $null for "task not found"; -ScriptDirAclSddl: one SDDL string per
  checked directory, in order runtime, runtime\bin).

  Extra logs. -ExtraLogPath names additional log files (for example tray
  logs) that are read through the same bounded, redacting reader as the
  supervisor log; each becomes an entry of the extraLogs[] section with
  the same fields as the supervisorLog section.

  Host. The host section collects read-only facts for the release
  manifest: GPU name, driver version and driver date from
  Win32_VideoController and the OS caption, version and build from
  Win32_OperatingSystem (read-only CIM queries). Every lookup failure
  becomes a HostLookupFailed section error; the report is still produced.
  -SkipHostCheck skips the lookups (skipped = true). -HostGpuQuery and
  -HostOsQuery are documented TEST SEAMS: scriptblocks that replace the
  live CIM queries; each returns what the live query would return, or
  throws to exercise the error path.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File gs-diagnose.ps1 -AsJson
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [string]$StateDir = ([System.IO.Path]::Combine($env:ProgramData, 'Local Development\GsController')),
    [string]$LogDir = ([System.IO.Path]::Combine($env:ProgramData, 'Local Development\GsControllerLogs')),
    [string]$ServerInfoUri = 'http://127.0.0.1:47989/serverinfo',
    [ValidateRange(1, 120)][int]$TimeoutSec = 3,
    [ValidateRange(0, 100000)][int]$LogTailLines = 50,
    # Maximum number of bytes of the supervisor log to scan, counted from
    # the end of the file. Tests use small values; the default covers the
    # last 8 MB.
    [ValidateRange(1024, 268435456)][int]$LogScanMaxBytes = 8388608,
    [switch]$AsJson,
    # Optional override for the module directory; default is
    # <InstallDir>\Modules. A repository checkout passes its src directory.
    [string]$ModuleRoot = '',
    # Skips the read-only registry lookup of the installed MSI so that tests
    # and machines without the product do not depend on real registry state.
    [switch]$SkipInstalledProductLookup,
    # Scheduled task name probed read-only by the hygiene section. An empty
    # string skips the task query entirely.
    [string]$SupervisorTaskName = 'GsControllerSupervisor',
    # TEST SEAM, never used in production: when this parameter is bound, its
    # value replaces the Get-ScheduledTask result ($null means "task not
    # found"). Expected shape: an object with State (string) and Actions (an
    # array of objects with Execute and Arguments), or $null.
    [object]$SupervisorTaskInfo,
    # Skips the read-only Get-Acl read of the hygiene ACL check;
    # scriptDirAcl entries then report skipped = true. Used by tests and by
    # bundle generators whose output leaves the machine. No ACL is ever
    # modified.
    [switch]$SkipAclCheck,
    # TEST SEAM, never used in production: when bound, exactly one SDDL
    # string per checked directory (order: <StateDir>\runtime, then
    # <StateDir>\runtime\bin) replaces the live Get-Acl read.
    [string[]]$ScriptDirAclSddl,
    # Additional log files (for example tray logs) read through the same
    # bounded, redacting reader as the supervisor log and reported in the
    # extraLogs[] section. In-process callers pass a real string[]. On a
    # command line (powershell.exe -File), which cannot pass arrays, the
    # files are separated by '|' - a character that is illegal in Windows
    # paths - and each element is split on it.
    [string[]]$ExtraLogPath,
    # TEST SEAMS for the read-only host section: when bound, they replace
    # the live CIM queries (Win32_VideoController / Win32_OperatingSystem).
    # Each must return the objects the live query would return, or throw
    # to exercise the error path.
    [scriptblock]$HostGpuQuery,
    [scriptblock]$HostOsQuery,
    # Skips the host section lookups entirely (the section then reports
    # skipped = true). Used by tests whose diagnose child runs via
    # powershell.exe -File, where the scriptblock seams cannot be passed.
    [switch]$SkipHostCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Default resolution. Done in the body, not in param defaults: PS 5.1 leaves
# $PSScriptRoot empty in param-block defaults under powershell.exe -File.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
}
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    throw (New-Object System.ArgumentException('InstallDir could not be resolved; pass it explicitly.', 'InstallDir'))
}
if ([string]::IsNullOrWhiteSpace($StateDir)) { $StateDir = [System.IO.Path]::Combine($env:ProgramData, 'Local Development\GsController') }
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = [System.IO.Path]::Combine($env:ProgramData, 'Local Development\GsControllerLogs') }
if ([string]::IsNullOrWhiteSpace($ModuleRoot)) { $ModuleRoot = [System.IO.Path]::Combine($InstallDir, 'Modules') }

function Resolve-SafeFullPath {
    # Normalizes one root path once, up front. No existence check: a path on
    # a drive that is not present is fine here and reported later as missing
    # data. Invalid characters (or another unusable path format) become the
    # documented parameter error, a System.ArgumentException. Relative paths
    # resolve against the process current directory,
    # [Environment]::CurrentDirectory.
    param([string]$Value, [string]$ParameterName)
    try {
        return [System.IO.Path]::GetFullPath($Value)
    } catch {
        throw (New-Object System.ArgumentException(('Parameter -' + $ParameterName + ' is not a usable path: ' + $_.Exception.Message), $ParameterName))
    }
}
$InstallDir = Resolve-SafeFullPath -Value $InstallDir -ParameterName 'InstallDir'
$StateDir = Resolve-SafeFullPath -Value $StateDir -ParameterName 'StateDir'
$LogDir = Resolve-SafeFullPath -Value $LogDir -ParameterName 'LogDir'
$ModuleRoot = Resolve-SafeFullPath -Value $ModuleRoot -ParameterName 'ModuleRoot'

# Plain HTTP only, per the serverinfo contract; never HTTPS on 47984.
$serverUri = $null
if (-not [System.Uri]::TryCreate($ServerInfoUri, [System.UriKind]::Absolute, [ref]$serverUri) -or $serverUri.Scheme -ne 'http') {
    throw (New-Object System.ArgumentException('ServerInfoUri must be an absolute http:// URI (plain HTTP only).', 'ServerInfoUri'))
}

# ---------------------------------------------------------------------------
# Redaction helpers
# ---------------------------------------------------------------------------
$script:RedactedPlaceholder = '<redacted>'
# base64/hex runs of 32+ characters inside a line. Log lines only: applied
# to free text it would corrupt ordinary long hex paths.
$script:LongTokenPattern = '[A-Za-z0-9+/=]{32,}'
# A PEM marker anywhere in a line. The BEGIN/END kind is captured so the
# state after the line follows the LAST marker in text order.
$script:PemMarkerPattern = '(?i)-----\s*(?<kind>BEGIN|END)[ A-Z0-9]*-----'
# Credential key core: credential words may sit inside a longer key with
# _ . - separators or a prefix (access_token, refresh_token, client_secret,
# x-api-key, sessionid, rikeyid, private_key, ...) but never inside an
# ordinary word (pinball, spinning, opinion, certainly).
$script:CredentialKeyCore = '(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_.-])*(?:token|secret|password|passwd|pwd|apikey|api[_-]?key|auth|authorization|bearer|cookie|session(?:id)?|sid|rikey(?:id)?|private[_-]?key|privatekey|pin|cert(?:ificate)?|credential)s?(?:[_.-][A-Za-z0-9]+)*(?![A-Za-z0-9])'
# key=value / "key": "value" / \"key\": \"value\" / 'key': 'value'. The key
# group keeps the key, its closing quote and the separator so the redacted
# output keeps the surrounding shape. Value alternatives: a quoted string
# (honoring \" escapes), or a bare run up to , ; & whitespace, a quote, or
# end. Array values ([...]) are NOT matched here: they are redacted by the
# balanced-bracket scanner below, which runs just before this pattern. A
# quote never belongs to a bare value: the header rule's quoted form leaves
# the closing quote in place and this rule must not swallow it when it
# re-runs over the header rule's output.
$script:SensitivePairPattern = ('(?i)(?<key>' + $script:CredentialKeyCore + '(?<kq>"|\\"|'')?[ \t]*[:=][ \t]*)' +
    '(?:"(?:[^"\\]|\\.)*"|\\"(?:[^"\\]|\\.)*\\"|''(?:[^''\\]|\\.)*''|[^\s,;&|''"]+)')
# Array-valued credential pairs: the same key shape followed by '['. The
# value is redacted with a balanced-bracket scanner (quotes and \" escapes
# are honored, nesting depth limited to 32, at most 4096 characters
# scanned) so nested arrays are redacted whole; when no matching ] exists
# within the cap, or the depth limit is exceeded, the rest of the line is
# redacted.
$script:SensitiveArrayKeyPattern =
    ('(?i)(?<key>' + $script:CredentialKeyCore + '(?<kq>"|\\"|'')?[ \t]*[:=][ \t]*)\[')
$script:ArrayScanMaxChars = 4096
$script:ArrayMaxDepth = 32
# Header form (Authorization, Proxy-Authorization, X-Api-Key, Cookie,
# Set-Cookie), anywhere in a line: everything after the colon is replaced
# with <redacted>. A name glued to a longer word (xauthorization,
# my-cookie) is not a header: the name must not be preceded by a letter,
# digit, '_' or '-' (the pair rule may still apply to such words). When
# the name is directly preceded by a quote, the value runs to the first
# UNESCAPED closing quote of the same kind (\" and \' escapes do not close
# it), and the closing quote plus the rest of the line are kept; otherwise
# the value runs to the end of the line. The quoted alternative is tried
# first; both share the <hdr> group and the replacement re-emits the
# opening quote via <hq>.
$script:HeaderNameCore = '(?:Proxy[-_]?Authorization|Authorization|X[-_]?Api[-_]?Key|Cookie|Set-Cookie)'
$script:SensitiveHeaderPattern =
    ('(?i)(?:(?<hq>[''"])(?<hdr>' + $script:HeaderNameCore + '\s*:)[ \t]*(?:(?!\k<hq>)[^\\]|\\.)*' +
        '|(?<![A-Za-z0-9_-])(?<hdr>' + $script:HeaderNameCore + '\s*:)[ \t]*[^\r\n]*)')
# Auth-scheme words (Bearer, Basic, Digest, Negotiate, NTLM) anywhere in a
# line: the scheme word is kept and the token after it is replaced. The
# token must look like a credential rather than prose, with a per-scheme
# minimum: Bearer always redacts a token of 8+ characters drawn from
# [A-Za-z0-9._~+/=-], Basic a token of 8+ characters of the base64 alphabet
# [A-Za-z0-9+/=], and Digest, Negotiate and NTLM a token of 16+ characters.
# An optional opening quote before the token is consumed; a closing quote
# is not part of the token characters and is left in place. This rule runs
# before the pair rule so a scheme token behind a credential key
# ("x-api-key: Bearer <token>") cannot leave the token as a fragment.
$script:SensitiveAuthSchemePattern =
    ('(?i)\b(?:' +
        '(?<scheme>Bearer)\s+[''"]?(?=[A-Za-z0-9._~+/=-]{8})[A-Za-z0-9._~+/=-]+' +
        '|(?<scheme>Basic)\s+[''"]?(?=[A-Za-z0-9+/=]{8})[A-Za-z0-9+/=]+' +
        '|(?<scheme>Digest|Negotiate|NTLM)\s+[''"]?(?=[A-Za-z0-9._~+/=-]{16})[A-Za-z0-9._~+/=-]+)')
# URL query/fragment parameter with a credential name (sig/signature count
# as credential names here); the value runs to &, #, whitespace or end.
$script:UrlCredParamPattern = ('(?i)(?<prefix>[?&#])(?<key>(?:[A-Za-z0-9]+[_.-])*(?:token|secret|password|passwd|pwd|apikey|api[_-]?key|auth|authorization|bearer|cookie|session(?:id)?|sid|rikey(?:id)?|private[_-]?key|privatekey|pin|cert(?:ificate)?|credential|sig(?:nature)?)s?(?:[_.-][A-Za-z0-9]+)*(?![A-Za-z0-9])=)[^\s&#]*')
# Bare credential word followed by whitespace and a value ("PIN 1234").
$script:SensitiveBareWordPattern = '(?i)(?<key>(?<![A-Za-z0-9])(?:pin|password|passwd|pwd|passcode|passphrase|secret|token)s?(?![A-Za-z0-9])[ \t]+)[^\s,;&|]+'
# A line that ends with a credential key + separator and no value
# ("token=", "password:", '"secret": ', YAML "password:") masks the NEXT
# non-empty line entirely; an empty or whitespace-only line in between
# does not clear the state.
$script:CredentialTailPattern =
    ('(?i)(?<key>' + $script:CredentialKeyCore + '(?<kq>"|\\"|'')?[ \t]*[:=][ \t]*)$')
# Emitted instead of the content of any log line that exceeded the raw
# per-line cap (its PEM markers are still found in the raw chunks).
$script:LongLinePlaceholder = '<redacted: long line truncated>'

function New-DiagError {
    param([string]$Code, [string]$Message)
    [pscustomobject]@{ code = $Code; message = (ConvertTo-RedactedText $Message) }
}

function Find-BalancedBracketEnd {
    # Index of the ']' matching the '[' at $OpenIndex in $Text, or -1 when
    # there is no matching ']' within ArrayScanMaxChars or the nesting depth
    # exceeds ArrayMaxDepth. Quotes are honored: a bracket inside a quoted
    # run does not count, \" and \' do not close a quoted run, and an
    # escaped quote outside a quoted run does not open one (the escaped
    # JSON forms written into logs).
    param([string]$Text, [int]$OpenIndex)
    $limit = $OpenIndex + $script:ArrayScanMaxChars
    if ($limit -gt $Text.Length) { $limit = $Text.Length }
    $depth = 0
    $inQuote = $false
    $quoteChar = [char]0
    for ($i = $OpenIndex; $i -lt $limit; $i++) {
        $c = $Text[$i]
        if ($c -eq '\') { $i++; continue }
        if ($inQuote) {
            if ($c -eq $quoteChar) { $inQuote = $false; $quoteChar = [char]0 }
            continue
        }
        if ($c -eq '"') { $inQuote = $true; $quoteChar = '"'; continue }
        if ($c -eq "'") { $inQuote = $true; $quoteChar = "'"; continue }
        if ($c -eq '[') {
            $depth++
            if ($depth -gt $script:ArrayMaxDepth) { return -1 }
            continue
        }
        if ($c -eq ']') {
            $depth--
            if ($depth -le 0) { return $i }
            continue
        }
    }
    return -1
}

function ConvertTo-RedactedArrayValues {
    # Redacts every credential-key [...] value with the balanced-bracket
    # scanner, keeping all text outside the matches.
    param([AllowNull()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $Line }
    $found = [System.Text.RegularExpressions.Regex]::Matches($Line, $script:SensitiveArrayKeyPattern)
    if ($found.Count -eq 0) { return $Line }
    $out = New-Object System.Text.StringBuilder
    $copied = 0
    foreach ($m in $found) {
        if ($m.Index -lt $copied) { continue }
        $openIndex = $m.Index + $m.Length - 1
        $end = Find-BalancedBracketEnd -Text $Line -OpenIndex $openIndex
        $null = $out.Append($Line.Substring($copied, $m.Index - $copied))
        $null = $out.Append($m.Groups['key'].Value)
        $null = $out.Append($script:RedactedPlaceholder)
        if ($end -ge 0) { $copied = $end + 1 }
        else { $copied = $Line.Length }
    }
    $null = $out.Append($Line.Substring($copied))
    return $out.ToString()
}

function ConvertTo-RedactedLineCore {
    # Redacts ONE line and advances the PEM state and the pending multi-line
    # credential state. $InPem (by ref) is $true while inside a PEM block.
    # Any line containing a PEM marker is fully masked; the state after the
    # line follows the last marker in text order, so
    # "-----END X----- -----BEGIN Y-----" stays inside a block. $PendingKey
    # (by ref) is $true after a line that ended with a credential key +
    # separator and no value; the next non-empty line is then masked
    # entirely. Empty lines keep the pending state. The long base64/hex
    # rule applies only with -IncludeLongTokens (log lines); free text
    # keeps long hex paths.
    param([AllowNull()][string]$Line, [ref]$InPem, [ref]$PendingKey, [switch]$IncludeLongTokens)
    $text = [string]$Line
    $markers = [System.Text.RegularExpressions.Regex]::Matches($text, $script:PemMarkerPattern)
    if ($markers.Count -gt 0) {
        $InPem.Value = ($markers[$markers.Count - 1].Groups['kind'].Value -ieq 'BEGIN')
        return $script:RedactedPlaceholder
    }
    if ($InPem.Value) { return $script:RedactedPlaceholder }
    if ($PendingKey.Value -and ($text.Trim().Length -gt 0)) {
        # The previous line ended with a credential key + separator and no
        # value: mask this line whole and consume the pending state.
        $PendingKey.Value = $false
        return $script:RedactedPlaceholder
    }
    # Order: the header rule first (it consumes the whole value, up to the
    # first unescaped matching quote or to the end of the line), then the
    # auth-scheme rule (so a scheme token cannot survive as a fragment
    # behind a credential key), then the URL parameter rule, the balanced
    # array scanner, the pair and bare-word rules on what is left of the
    # line.
    $result = [System.Text.RegularExpressions.Regex]::Replace($text, $script:SensitiveHeaderPattern, ('${hq}${hdr} ' + $script:RedactedPlaceholder))
    $result = [System.Text.RegularExpressions.Regex]::Replace($result, $script:SensitiveAuthSchemePattern, ('${scheme} ' + $script:RedactedPlaceholder))
    $result = [System.Text.RegularExpressions.Regex]::Replace($result, $script:UrlCredParamPattern, ('${prefix}${key}' + $script:RedactedPlaceholder))
    $result = ConvertTo-RedactedArrayValues -Line $result
    $result = [System.Text.RegularExpressions.Regex]::Replace($result, $script:SensitivePairPattern, ('${key}' + $script:RedactedPlaceholder))
    $result = [System.Text.RegularExpressions.Regex]::Replace($result, $script:SensitiveBareWordPattern, ('${key}' + $script:RedactedPlaceholder))
    if ($IncludeLongTokens) {
        $result = [System.Text.RegularExpressions.Regex]::Replace($result, $script:LongTokenPattern, $script:RedactedPlaceholder)
    }
    # Only a non-empty line can end with a key + separator; empty lines
    # leave the pending state untouched.
    if ($text.Trim().Length -gt 0) {
        $PendingKey.Value = ($text.TrimEnd() -match $script:CredentialTailPattern)
    }
    return $result
}

function ConvertTo-RedactedText {
    # Free-text redaction. Multi-line text (status/lastError strings can
    # contain newlines) goes through the same stateful per-line logic as log
    # lines; an unterminated BEGIN masks to the end of the text and a line
    # ending with a credential key + separator masks the next non-empty
    # line. The base64/hex long-token rule is log-line only
    # (-IncludeLongTokens).
    param([AllowNull()][string]$Text, [switch]$IncludeLongTokens)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $parts = [System.Text.RegularExpressions.Regex]::Split($Text, '\r\n|\n|\r')
    $inPem = $false
    $pendingKey = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($part in $parts) {
        $out.Add((ConvertTo-RedactedLineCore -Line $part ([ref]$inPem) ([ref]$pendingKey) -IncludeLongTokens:$IncludeLongTokens))
    }
    return [string]::Join("`n", $out.ToArray())
}

function ConvertTo-RedactedLines {
    # Redacts an array of lines while keeping the line count stable, tracking
    # PEM blocks and the pending multi-line credential state from the first
    # line so a block opened before the tail window still redacts the body
    # lines inside the window.
    param([AllowNull()][string[]]$Lines, [int]$MaxLineLength = 2048)
    $out = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Lines) { return $out.ToArray() }
    $inPem = $false
    $pendingKey = $false
    foreach ($line in $Lines) {
        $redacted = ConvertTo-RedactedLineCore -Line ([string]$line) ([ref]$inPem) ([ref]$pendingKey) -IncludeLongTokens
        if ($redacted.Length -gt $MaxLineLength) { $redacted = $redacted.Substring(0, $MaxLineLength) }
        $out.Add($redacted)
    }
    return $out.ToArray()
}

function ConvertTo-BoundedText {
    param($Value, [int]$MaxLength = 512)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ($text.Length -le $MaxLength) { return $text }
    return $text.Substring(0, $MaxLength)
}

function ConvertTo-SafeText {
    # Redact first, then truncate: a truncated secret must never survive
    # because a rule boundary fell outside the cut.
    param($Value, [int]$MaxLength = 512)
    if ($null -eq $Value) { return $null }
    return (ConvertTo-BoundedText (ConvertTo-RedactedText ([string]$Value)) $MaxLength)
}

function ConvertTo-DisplayUri {
    # Display form of the request URI: userinfo removed, query and fragment
    # dropped, so credentials passed in the URL never reach the report.
    param([System.Uri]$Uri)
    return ($Uri.Scheme + '://' + $Uri.Authority + $Uri.AbsolutePath)
}

# ---------------------------------------------------------------------------
# Filesystem helpers. All of them catch anything a broken path or a locked
# file can raise and report it through the caller's error list instead.
# ---------------------------------------------------------------------------
function Test-SafeLeaf {
    param([string]$Path)
    try { return (Test-Path -LiteralPath $Path -PathType Leaf) } catch { return $false }
}

function Test-SafeContainer {
    param([string]$Path)
    try { return (Test-Path -LiteralPath $Path -PathType Container) } catch { return $false }
}

function Get-SafeFileSha256 {
    param([string]$Path)
    try {
        return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    } catch { return $null }
}

function Get-SafeLastWriteUtc {
    # Returns a DateTime, or $null when the file does not exist or the path
    # cannot be probed.
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc
    } catch { return $null }
}

function Read-SafeFileText {
    param([string]$Path)
    try { return [System.IO.File]::ReadAllText($Path) } catch { return $null }
}

function Get-JsonScalar {
    # First present property among $Names on a parsed JSON object, coerced to
    # a redacted, bounded string. $null when absent or not an object.
    param($Object, [string[]]$Names)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { return $null }
    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($null -ne $prop) { return (ConvertTo-SafeText $prop.Value) }
    }
    return $null
}

function Invoke-GuardedSection {
    # Runs one section collector. An unexpected exception becomes a
    # SectionFailed error in a minimal section object; the report keeps its
    # shape and the run still exits 0.
    param([string]$SectionName, [scriptblock]$Collector)
    try {
        return (& $Collector)
    } catch {
        return [ordered]@{
            ok     = $false
            errors = @((New-DiagError 'SectionFailed' ('Section ' + $SectionName + ' failed unexpectedly: ' + $_.Exception.Message)))
        }
    }
}

# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------
function Get-ProductSection {
    param([string]$InstallDirPath, [string]$ModulesRoot, [bool]$SkipMsiLookup)

    $errors = New-Object System.Collections.Generic.List[object]
    $entryPath = [System.IO.Path]::Combine($InstallDirPath, 'gs-product.ps1')
    $entrySha = $null
    if (Test-SafeLeaf $entryPath) {
        $entrySha = Get-SafeFileSha256 $entryPath
        if ($null -eq $entrySha) { $errors.Add((New-DiagError 'HashFailed' "Could not compute SHA-256 for gs-product.ps1 ($entryPath).")) }
    } else {
        $errors.Add((New-DiagError 'FileNotFound' "gs-product.ps1 not found: $entryPath"))
    }

    $modules = New-Object System.Collections.Generic.List[object]
    foreach ($moduleName in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
        $psd1Path = [System.IO.Path]::Combine([System.IO.Path]::Combine($ModulesRoot, $moduleName), ($moduleName + '.psd1'))
        $psm1Path = [System.IO.Path]::Combine([System.IO.Path]::Combine($ModulesRoot, $moduleName), ($moduleName + '.psm1'))
        $version = $null
        $psd1Sha = $null
        $psm1Sha = $null
        if (Test-SafeLeaf $psd1Path) {
            $psd1Sha = Get-SafeFileSha256 $psd1Path
            if ($null -eq $psd1Sha) { $errors.Add((New-DiagError 'HashFailed' "Could not compute SHA-256 for $psd1Path.")) }
            $data = $null
            try { $data = Import-PowerShellDataFile -LiteralPath $psd1Path -ErrorAction Stop } catch { $data = $null }
            if ($null -ne $data -and $data -is [hashtable] -and $data.ContainsKey('ModuleVersion')) {
                $version = ConvertTo-SafeText ([string]$data['ModuleVersion']) 64
            } else {
                $errors.Add((New-DiagError 'ManifestReadFailed' "ModuleVersion not readable from manifest: $psd1Path"))
            }
        } else {
            $errors.Add((New-DiagError 'FileNotFound' "Module manifest not found: $psd1Path"))
        }
        if (Test-SafeLeaf $psm1Path) {
            $psm1Sha = Get-SafeFileSha256 $psm1Path
            if ($null -eq $psm1Sha) { $errors.Add((New-DiagError 'HashFailed' "Could not compute SHA-256 for $psm1Path.")) }
        } else {
            $errors.Add((New-DiagError 'FileNotFound' "Module script not found: $psm1Path"))
        }
        $modules.Add([pscustomobject]@{
            name       = $moduleName
            version    = $version
            psd1Path   = $psd1Path
            psd1Sha256 = $psd1Sha
            psm1Path   = $psm1Path
            psm1Sha256 = $psm1Sha
        })
    }

    # Installed MSI lookup: read-only registry query, skipped on request.
    $msi = [ordered]@{
        lookupSkipped  = $SkipMsiLookup
        found          = $false
        displayName    = $null
        displayVersion = $null
        registryKey    = $null
    }
    if (-not $SkipMsiLookup) {
        try {
            $uninstallPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            if (Test-Path -LiteralPath $uninstallPath) {
                foreach ($key in @(Get-ChildItem -LiteralPath $uninstallPath -ErrorAction Stop)) {
                    $props = $null
                    try { $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }
                    if ($null -eq $props) { continue }
                    $nameProp = $props.PSObject.Properties['DisplayName']
                    if ($null -eq $nameProp -or [string]$nameProp.Value -ne 'GsController') { continue }
                    $msi.found = $true
                    $msi.displayName = ConvertTo-SafeText ([string]$nameProp.Value) 128
                    $msi.registryKey = ConvertTo-SafeText ([string]$key.Name) 256
                    $versionProp = $props.PSObject.Properties['DisplayVersion']
                    if ($null -ne $versionProp) { $msi.displayVersion = ConvertTo-SafeText ([string]$versionProp.Value) 64 }
                    break
                }
            }
        } catch {
            $errors.Add((New-DiagError 'RegistryLookupFailed' "Installed product lookup failed: $($_.Exception.Message)"))
        }
    }

    return [ordered]@{
        ok                = ($errors.Count -eq 0)
        errors            = $errors.ToArray()
        installDir        = $InstallDirPath
        moduleRoot        = $ModulesRoot
        productEntryPath  = $entryPath
        productEntrySha256 = $entrySha
        modules           = $modules.ToArray()
        installedMsi      = [pscustomobject]$msi
    }
}

function Get-RuntimeConfigSection {
    param([string]$StateDirectory)

    $errors = New-Object System.Collections.Generic.List[object]
    $configPath = [System.IO.Path]::Combine($StateDirectory, 'runtime-config.json')
    $exists = Test-SafeLeaf $configPath
    $schemaVersion = $null
    $installDir = $null
    $stateDirValue = $null
    $logDirValue = $null
    $componentSourceDir = $null
    if ($exists) {
        $text = Read-SafeFileText $configPath
        if ($null -eq $text) {
            $errors.Add((New-DiagError 'ReadFailed' "Could not read runtime config: $configPath"))
        } else {
            $doc = $null
            try { $doc = $text | ConvertFrom-Json } catch { $doc = $null }
            if ($null -eq $doc -or $doc -isnot [pscustomobject]) {
                $errors.Add((New-DiagError 'InvalidJson' 'runtime-config.json is not a JSON object.'))
            } else {
                $schemaVersion = Get-JsonScalar $doc @('schemaVersion')
                $installDir = Get-JsonScalar $doc @('installDir')
                $stateDirValue = Get-JsonScalar $doc @('stateDir')
                $logDirValue = Get-JsonScalar $doc @('logDir')
                $componentSourceDir = Get-JsonScalar $doc @('componentSourceDir')
                foreach ($field in @(
                        @('schemaVersion', $schemaVersion),
                        @('installDir', $installDir),
                        @('stateDir', $stateDirValue),
                        @('logDir', $logDirValue),
                        @('componentSourceDir', $componentSourceDir))) {
                    if ($null -eq $field[1]) { $errors.Add((New-DiagError 'MissingField' "runtime-config.json is missing $($field[0]).")) }
                }
            }
        }
    } else {
        $errors.Add((New-DiagError 'FileNotFound' "Runtime config not found: $configPath"))
    }

    return [ordered]@{
        ok                 = ($errors.Count -eq 0)
        errors             = $errors.ToArray()
        path               = $configPath
        exists             = [bool]$exists
        schemaVersion      = $schemaVersion
        installDir         = $installDir
        stateDir           = $stateDirValue
        logDir             = $logDirValue
        componentSourceDir = $componentSourceDir
    }
}

function Get-StatusSection {
    param([string]$StateDirectory)

    $errors = New-Object System.Collections.Generic.List[object]
    $candidateA = [System.IO.Path]::Combine($StateDirectory, 'runtime\state\status.json')
    $candidateB = [System.IO.Path]::Combine($StateDirectory, 'status.json')
    $aTime = Get-SafeLastWriteUtc $candidateA
    $bTime = Get-SafeLastWriteUtc $candidateB
    $aExists = $null -ne $aTime
    $bExists = $null -ne $bTime

    $usedPath = $null
    $usedTime = $null
    if ($aExists -and $bExists) {
        # Newer file wins; on an exact tie prefer the documented primary.
        if ($bTime -gt $aTime) { $usedPath = $candidateB; $usedTime = $bTime }
        else { $usedPath = $candidateA; $usedTime = $aTime }
    } elseif ($aExists) {
        $usedPath = $candidateA; $usedTime = $aTime
    } elseif ($bExists) {
        $usedPath = $candidateB; $usedTime = $bTime
    } else {
        $usedPath = $candidateA
        $errors.Add((New-DiagError 'FileNotFound' "No runtime status file found (checked $candidateA and $candidateB)."))
    }

    $state = $null
    $runId = $null
    $lastError = $null
    if ($null -ne $usedTime) {
        $text = Read-SafeFileText $usedPath
        if ($null -eq $text) {
            $errors.Add((New-DiagError 'ReadFailed' "Could not read status file: $usedPath"))
        } else {
            $doc = $null
            try { $doc = $text | ConvertFrom-Json } catch { $doc = $null }
            if ($null -eq $doc -or $doc -isnot [pscustomobject]) {
                $errors.Add((New-DiagError 'InvalidJson' "Status file is not a JSON object: $usedPath"))
            } else {
                # Whitelisted fields only; the file is never dumped as a whole.
                $state = Get-JsonScalar $doc @('state')
                $runId = Get-JsonScalar $doc @('runId', 'run_id')
                $lastError = Get-JsonScalar $doc @('lastError', 'last_error', 'error')
            }
        }
    }

    $candidates = @(
        [pscustomobject]@{
            path             = $candidateA
            exists           = [bool]$aExists
            lastWriteTimeUtc = $(if ($null -ne $aTime) { $aTime.ToString('o') } else { $null })
        },
        [pscustomobject]@{
            path             = $candidateB
            exists           = [bool]$bExists
            lastWriteTimeUtc = $(if ($null -ne $bTime) { $bTime.ToString('o') } else { $null })
        }
    )

    return [ordered]@{
        ok               = ($errors.Count -eq 0)
        errors           = $errors.ToArray()
        path             = $usedPath
        exists           = [bool]($null -ne $usedTime)
        lastWriteTimeUtc = $(if ($null -ne $usedTime) { $usedTime.ToString('o') } else { $null })
        state            = $state
        runId            = $runId
        lastError        = $lastError
        candidates       = $candidates
    }
}

function Get-ServerInfoSection {
    param([System.Uri]$Uri, [int]$TimeoutSeconds)

    $errors = New-Object System.Collections.Generic.List[object]
    $httpStatus = $null
    $state = $null
    $currentGame = $null
    $errorText = $null
    $body = $null
    $stream = $null
    $displayUri = ConvertTo-DisplayUri $Uri
    $maxBodyBytes = 65536
    $chunkSize = 16384
    $timeoutMs = $TimeoutSeconds * 1000
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $request = $null
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'GET'
        # No $request.Timeout here: the internal timer would race the bounded
        # waits below at the same deadline and reclassify late-completing
        # failures as timeouts. ReadWriteTimeout still bounds stream-level
        # stalls.
        $request.ReadWriteTimeout = $timeoutMs
        $request.AllowAutoRedirect = $false
        $request.KeepAlive = $false
        $request.Proxy = $null
        # Independent abort, phase 1: wait for the response on the async
        # handle, bounded by the time remaining. On overrun the request is
        # aborted and Timeout is reported, whatever the server is doing.
        $requestTimedOut = $false
        $asyncResponse = $request.BeginGetResponse($null, $null)
        $remainingMs = $timeoutMs - [int]$sw.ElapsedMilliseconds
        if ($remainingMs -le 0) {
            $requestTimedOut = $true
        } else {
            # A short grace after the deadline absorbs a completion that
            # lands between polls on a loaded machine (for example a
            # loopback refusal delivered late); the total budget stays
            # within TimeoutSec + 1.5s.
            $signaled = $asyncResponse.AsyncWaitHandle.WaitOne($remainingMs)
            if (-not $signaled) {
                $graceEnd = [DateTime]::UtcNow.AddMilliseconds(500)
                while (-not $signaled -and [DateTime]::UtcNow -lt $graceEnd) {
                    $signaled = $asyncResponse.AsyncWaitHandle.WaitOne(50)
                }
            }
            if (-not $signaled) {
                $requestTimedOut = $true
            } else {
                try {
                    $response = $request.EndGetResponse($asyncResponse)
                } catch [System.Net.WebException] {
                    $webResponse = $_.Exception.Response
                    if ($null -ne $webResponse) {
                        try { $httpStatus = [int]$webResponse.StatusCode } catch { $httpStatus = $null }
                        try { $webResponse.Close() } catch { }
                    }
                    if ($null -ne $httpStatus) {
                        # A protocol-level error response (e.g. 503): never a 200.
                        $errorText = ('serverinfo returned HTTP ' + $httpStatus + ', expected 200.')
                        $errors.Add((New-DiagError 'UnexpectedStatus' $errorText))
                    } else {
                        # Unreachable host, refused connections and request timeouts
                        # all land here: a section error, never a throw.
                        $errorText = [string]$_.Exception.Message
                        $errors.Add((New-DiagError 'RequestFailed' (ConvertTo-BoundedText $errorText 512)))
                    }
                }
            }
        }
        if ($requestTimedOut) {
            $errorText = 'serverinfo response timed out before the headers were complete.'
            $errors.Add((New-DiagError 'Timeout' $errorText))
        }
        if ($null -ne $response) {
            try { $httpStatus = [int]$response.StatusCode } catch { $httpStatus = $null }
            if ($httpStatus -ne 200) {
                $errorText = ('serverinfo returned HTTP ' + $httpStatus + ', expected 200.')
                $errors.Add((New-DiagError 'UnexpectedStatus' $errorText))
                try { $response.Close() } catch { }
                $response = $null
            } else {
                # Bounded incremental read: at most 64 KB of raw bytes
                # (counted before decoding) and never past the total deadline
                # measured from request start. Each chunk read waits on the
                # async read for the remaining time only; on overrun the
                # request is aborted so no connection lingers.
                $chunks = New-Object System.Collections.Generic.List[byte]
                $buffer = New-Object byte[] $chunkSize
                $stream = $null
                $readFailed = $null
                try { $stream = $response.GetResponseStream() } catch { $readFailed = $_.Exception.Message }
                if ($null -ne $stream) {
                    while ($true) {
                        $remainingMs = $timeoutMs - [int]$sw.ElapsedMilliseconds
                        if ($remainingMs -le 0) {
                            $errorText = 'serverinfo response timed out before the body was complete.'
                            $errors.Add((New-DiagError 'Timeout' $errorText))
                            break
                        }
                        if ($chunks.Count -gt $maxBodyBytes) {
                            $errorText = 'serverinfo response body exceeded 64 KB.'
                            $errors.Add((New-DiagError 'BodyTooLarge' $errorText))
                            break
                        }
                        $want = [int][Math]::Min($chunkSize, ($maxBodyBytes + 1 - $chunks.Count))
                        $read = 0
                        $readTimedOut = $false
                        try {
                            $readTask = $stream.ReadAsync($buffer, 0, $want)
                            if (-not $readTask.Wait($remainingMs)) {
                                $readTimedOut = $true
                            } else {
                                $read = $readTask.Result
                            }
                        } catch {
                            $inner = $_.Exception
                            if ($inner -is [System.AggregateException] -and $inner.InnerExceptions.Count -gt 0) { $inner = $inner.InnerExceptions[0] }
                            $readFailed = $inner.Message
                            break
                        }
                        if ($readTimedOut) {
                            try { $request.Abort() } catch { }
                            # Observe the still-pending (now faulted) read so
                            # its failure is not unobserved.
                            try { $null = $readTask.Result } catch { }
                            $errorText = 'serverinfo response timed out before the body was complete.'
                            $errors.Add((New-DiagError 'Timeout' $errorText))
                            break
                        }
                        if ($read -le 0) { break }
                        for ($b = 0; $b -lt $read; $b++) { $chunks.Add($buffer[$b]) }
                    }
                }
                if ($null -ne $readFailed) {
                    $errorText = ('serverinfo body read failed: ' + (ConvertTo-BoundedText [string]$readFailed 256))
                    $errors.Add((New-DiagError 'ReadFailed' $errorText))
                }
                if ($null -eq $errorText) {
                    if ($chunks.Count -gt 0) {
                        $body = [System.Text.Encoding]::UTF8.GetString($chunks.ToArray())
                    } else {
                        $body = ''
                    }
                }
            }
        }
    } catch {
        $errorText = [string]$_.Exception.Message
        $errors.Add((New-DiagError 'RequestFailed' (ConvertTo-BoundedText $errorText 512)))
    } finally {
        # Whatever happened: abort a request with a reported error so no
        # connection lingers, and close the response and its stream.
        if ($null -ne $errorText) { try { $request.Abort() } catch { } }
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
        if ($null -ne $response) { try { $response.Close() } catch { } }
    }

    if ($null -ne $body) {
        $trimmedBody = $body.Trim()
        if ($trimmedBody.Length -eq 0) {
            $errors.Add((New-DiagError 'EmptyBody' 'serverinfo returned an empty body.'))
        } else {
            $xml = $null
            try { $xml = [xml]$trimmedBody } catch { $xml = $null }
            if ($null -eq $xml -or $null -eq $xml.DocumentElement) {
                $errors.Add((New-DiagError 'InvalidXml' 'serverinfo response is not valid XML.'))
            } elseif ([string]$xml.DocumentElement.Name -cne 'root') {
                # Case-sensitive: the root element must be exactly 'root'.
                $errors.Add((New-DiagError 'UnexpectedRoot' ('serverinfo XML root element is ' + [string]$xml.DocumentElement.Name + ', expected root.')))
            } else {
                $root = $xml.DocumentElement
                $statusCodeText = [string]$root.GetAttribute('status_code')
                if ($statusCodeText.Length -eq 0) {
                    $errors.Add((New-DiagError 'MissingField' 'serverinfo XML has no status_code attribute.'))
                } elseif (($statusCodeText -notmatch '^\d{1,10}$') -or ([int]$statusCodeText -ne 200)) {
                    $errors.Add((New-DiagError 'ProtocolStatus' ('serverinfo status_code is ' + $statusCodeText + ', expected 200.')))
                }
                $stateNode = $root.SelectSingleNode('state')
                if ($null -eq $stateNode) {
                    $errors.Add((New-DiagError 'MissingField' 'serverinfo XML has no <state> element.'))
                } else {
                    $stateText = ([string]$stateNode.InnerText).Trim()
                    if ($stateText.Length -eq 0) {
                        # Empty after trimming: a whitespace-only state is invalid.
                        $errors.Add((New-DiagError 'InvalidField' 'serverinfo <state> element is empty.'))
                    } else {
                        $state = ConvertTo-SafeText $stateText
                    }
                }
                $gameNode = $root.SelectSingleNode('currentgame')
                if ($null -eq $gameNode) {
                    $errors.Add((New-DiagError 'MissingField' 'serverinfo XML has no <currentgame> element.'))
                } else {
                    # Validity and the reported value both use the trimmed
                    # digits.
                    $gameText = ([string]$gameNode.InnerText).Trim()
                    if ($gameText -match '^\d{1,10}$') {
                        $currentGame = $gameText
                    } else {
                        $errors.Add((New-DiagError 'InvalidField' 'serverinfo <currentgame> is not all digits.'))
                    }
                }
            }
        }
    }
    # The stopwatch stops after parsing, so elapsedMs covers request, read
    # and parse.
    $sw.Stop()

    return [ordered]@{
        ok          = ($errors.Count -eq 0)
        errors      = $errors.ToArray()
        uri         = $displayUri
        httpStatus  = $httpStatus
        state       = $state
        currentgame = $currentGame
        elapsedMs   = [int]$sw.ElapsedMilliseconds
        error       = $(if ($null -ne $errorText) { ConvertTo-SafeText $errorText } else { $null })
    }
}

function Get-ComponentsSection {
    param([string]$StateDirectory)

    $errors = New-Object System.Collections.Generic.List[object]
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('broker', 'nvs', 'nss', 'ssau')) {
        $pidFilePath = [System.IO.Path]::Combine($StateDirectory, ($name + '_pid.json'))
        $exists = Test-SafeLeaf $pidFilePath
        # NOTE: $pid is a reserved automatic variable; use $procId.
        $procId = $null
        $running = $false
        $processName = $null
        $processStartTimeUtc = $null
        if ($exists) {
            $text = Read-SafeFileText $pidFilePath
            if ($null -eq $text) {
                $errors.Add((New-DiagError 'ReadFailed' "Could not read PID file: $pidFilePath"))
            } else {
                $trimmed = $text.Trim()
                $rawPid = $null
                if ($trimmed -match '^\d{1,10}$') {
                    # Tolerated format 1: a plain integer.
                    $rawPid = $trimmed
                } else {
                    # Tolerated format 2: JSON with pid/Pid/processId/ProcessId.
                    $doc = $null
                    try { $doc = $trimmed | ConvertFrom-Json } catch { $doc = $null }
                    if ($doc -is [pscustomobject]) {
                        foreach ($propName in @('pid', 'processId')) {
                            $prop = $doc.PSObject.Properties[$propName]
                            if ($null -ne $prop) { $rawPid = [string]$prop.Value; break }
                        }
                    } elseif ($null -ne $doc) {
                        # Quoted number, e.g. "1234".
                        $rawPid = [string]$doc
                    }
                }
                if ($null -ne $rawPid) {
                    $parsed = [int64]0
                    if ([int64]::TryParse($rawPid, [ref]$parsed) -and $parsed -ge 0) { $procId = $parsed }
                }
                if ($null -eq $procId) {
                    $errors.Add((New-DiagError 'MalformedPidFile' "PID file is malformed: $pidFilePath"))
                }
            }
        }
        if ($null -ne $procId) {
            $proc = $null
            try { $proc = Get-Process -Id $procId -ErrorAction Stop } catch { $proc = $null }
            if ($null -ne $proc) {
                # running means a process with the recorded PID exists; the
                # identity of the process is not verified and PIDs can be
                # reused (documented in the header and the release manifest).
                $running = $true
                try { $processName = ConvertTo-SafeText ([string]$proc.ProcessName) 128 } catch { $processName = $null }
                try { $processStartTimeUtc = $proc.StartTime.ToUniversalTime().ToString('o') } catch { $processStartTimeUtc = $null }
            }
        }
        $items.Add([pscustomobject]@{
            name                = $name
            pidFilePath         = $pidFilePath
            exists              = [bool]$exists
            pid                 = $procId
            running             = [bool]$running
            processName         = $processName
            processStartTimeUtc = $processStartTimeUtc
        })
    }

    return [ordered]@{
        ok     = ($errors.Count -eq 0)
        errors = $errors.ToArray()
        items  = $items.ToArray()
    }
}

function Get-RuntimeBundleSection {
    param([string]$InstallDirPath, [string]$StateDirectory)

    $errors = New-Object System.Collections.Generic.List[object]
    $directories = New-Object System.Collections.Generic.List[object]
    # Top level only, names and hashes only; *.log files are skipped.
    $targets = @(
        @{ label = 'installBin';  path = [System.IO.Path]::Combine($InstallDirPath, 'bin') },
        @{ label = 'runtimeBin';  path = [System.IO.Path]::Combine($StateDirectory, 'runtime\bin') },
        @{ label = 'runtimeRoot'; path = [System.IO.Path]::Combine($StateDirectory, 'runtime') }
    )
    foreach ($target in $targets) {
        $available = Test-SafeContainer $target.path
        $files = New-Object System.Collections.Generic.List[object]
        $fileCount = 0
        if ($available) {
            $children = $null
            try { $children = @(Get-ChildItem -LiteralPath $target.path -File -Force -ErrorAction Stop | Sort-Object -Property Name) } catch { $children = $null }
            if ($null -eq $children) {
                $errors.Add((New-DiagError 'EnumerationFailed' "Could not enumerate directory: $($target.path)"))
            } else {
                foreach ($file in $children) {
                    if ($file.Name -like '*.log') { continue }
                    $fileCount++
                    $sha = Get-SafeFileSha256 $file.FullName
                    if ($null -eq $sha) {
                        $errors.Add((New-DiagError 'HashFailed' "Could not compute SHA-256: $($file.FullName)"))
                    }
                    $files.Add([pscustomobject]@{
                        name             = $file.Name
                        sizeBytes        = [int64]$file.Length
                        lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
                        sha256           = $sha
                    })
                }
            }
        } else {
            $errors.Add((New-DiagError 'DirectoryMissing' "Directory not found: $($target.path)"))
        }
        $directories.Add([pscustomobject]@{
            label     = $target.label
            path      = $target.path
            available = [bool]$available
            fileCount = $fileCount
            files     = $files.ToArray()
        })
    }

    return [ordered]@{
        ok          = ($errors.Count -eq 0)
        errors      = $errors.ToArray()
        directories = $directories.ToArray()
    }
}

function Add-CappedChars {
    # Appends Buffer[Start..Start+Count) to the line builder while the line
    # is shorter than Cap; characters beyond the cap are dropped without
    # being held, and the line still terminates normally. $Overflowed (by
    # ref) is set when any character was dropped.
    param([System.Text.StringBuilder]$Builder, [ref]$CurrentLength, [char[]]$Buffer, [int]$Start, [int]$Count, [int]$Cap, [ref]$Overflowed)
    if ($Count -le 0) { return }
    $room = $Cap - $CurrentLength.Value
    if ($room -le 0) {
        $Overflowed.Value = $true
        return
    }
    $take = $Count
    if ($take -gt $room) {
        $take = $room
        $Overflowed.Value = $true
    }
    $null = $Builder.Append($Buffer, $Start, $take)
    $CurrentLength.Value += $take
}

function Update-PemScanState {
    # Scans one raw segment of the current log line for PEM markers, in
    # order, and updates $InPem (by ref) from the last marker found. This
    # runs on every raw chunk of a line, INCLUDING the part beyond the raw
    # per-line cap that is dropped from the builder, so a marker past the
    # cap still opens or closes the block. $ScanTail (by ref) keeps a small
    # trailing overlap between segments so a marker split across chunk
    # boundaries is still detected; the tail is cleared at line boundaries.
    param([string]$Segment, [ref]$InPem, [ref]$ScanTail, [int]$OverlapChars = 256)
    if ($Segment.Length -gt 0) { $ScanTail.Value = ($ScanTail.Value + $Segment) }
    if ($ScanTail.Value.Length -eq 0) { return }
    $markers = [System.Text.RegularExpressions.Regex]::Matches($ScanTail.Value, $script:PemMarkerPattern)
    if ($markers.Count -gt 0) {
        $InPem.Value = ($markers[$markers.Count - 1].Groups['kind'].Value -ieq 'BEGIN')
    }
    if ($ScanTail.Value.Length -gt $OverlapChars) {
        $ScanTail.Value = $ScanTail.Value.Substring($ScanTail.Value.Length - $OverlapChars)
    }
}

function Read-SupervisorLogTail {
    # Streams the supervisor log through a bounded ring buffer, redacting
    # each line while reading with persistent PEM state and pending
    # multi-line credential state. The file is opened with FileShare
    # ReadWrite|Delete, read only up to the length captured at open, at
    # most ScanMaxBytes bytes counted from the end of the file, and at most
    # TimeoutMilliseconds in total. Lines are assembled in bounded chunks so
    # a newline-free line is never held whole; PEM markers are scanned in
    # every raw chunk of a line (a marker beyond the raw line cap or split
    # across chunk boundaries is still found), and any line that exceeded
    # the raw cap is emitted as <redacted: long line truncated>. When the
    # scan starts mid-file, the partial line at the boundary is skipped to
    # the next newline and the PEM state is unknown: everything is masked
    # until the first -----END marker.
    param(
        [string]$LogFilePath,
        [int]$TailLines,
        [int]$TimeoutMilliseconds,
        [int]$ScanMaxBytes,
        [int]$RawLineCap = 4096,
        [int]$MaxLineLength = 2048
    )

    $errors = New-Object System.Collections.Generic.List[object]
    $truncated = $false
    $incomplete = $false
    $unterminatedPem = $false
    $scannedBytes = [int64]0
    $ring = New-Object 'System.Collections.Generic.Queue[string]'
    $inPem = $false
    $pendingKey = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    # The whole read and redaction runs inside this try: any failure becomes
    # a ReadFailed error, never a throw.
    try {
        # FileShare ReadWrite|Delete: the runtime keeps the log open for
        # writing, and renaming the file while it is being read must not
        # fail with a sharing violation.
        $stream = [System.IO.File]::Open($LogFilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $capturedLength = $stream.Length
            $startOffset = $capturedLength - [int64]$ScanMaxBytes
            $skippingToNewline = $false
            if ($startOffset -gt 0) {
                $truncated = $true
                $stream.Seek($startOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
                $skippingToNewline = $true
                # PEM state unknown mid-file: mask until the first END.
                $inPem = $true
            }

            $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
            $byteBuffer = New-Object byte[] 16384
            $charBuffer = New-Object char[] 16384
            $lineBuilder = New-Object System.Text.StringBuilder
            $lineLength = 0
            $lineOverflowed = $false
            $pemScanTail = ''
            $lastWasCR = $false

            while ($true) {
                if ($sw.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                    $incomplete = $true
                    $truncated = $true
                    $errors.Add((New-DiagError 'Timeout' ('Supervisor log scan stopped after the ' + ($TimeoutMilliseconds / 1000) + 's deadline.')))
                    break
                }
                $remaining = $capturedLength - $stream.Position
                if ($remaining -le 0) { break }
                $toRead = [int][Math]::Min($byteBuffer.Length, $remaining)
                $read = $stream.Read($byteBuffer, 0, $toRead)
                if ($read -le 0) { break }
                $scannedBytes += $read
                $charCount = $decoder.GetChars($byteBuffer, 0, $read, $charBuffer, 0)
                if ($charCount -le 0) { continue }
                $idx = 0
                if ($lastWasCR) {
                    # A CR ended the previous chunk; an LF here completes the
                    # CRLF pair and is consumed silently.
                    if ($charBuffer[0] -eq "`n") { $idx = 1 }
                    $lastWasCR = $false
                }
                while ($idx -lt $charCount) {
                    if ($skippingToNewline) {
                        $nl = [Array]::IndexOf($charBuffer, [char]"`n", $idx, ($charCount - $idx))
                        if ($nl -lt 0) { $idx = $charCount; continue }
                        $idx = $nl + 1
                        $skippingToNewline = $false
                        continue
                    }
                    $nl = [Array]::IndexOf($charBuffer, [char]"`n", $idx, ($charCount - $idx))
                    $cr = [Array]::IndexOf($charBuffer, [char]"`r", $idx, ($charCount - $idx))
                    if (($nl -lt 0) -and ($cr -lt 0)) {
                        Add-CappedChars -Builder $lineBuilder -CurrentLength ([ref]$lineLength) -Buffer $charBuffer -Start $idx -Count ($charCount - $idx) -Cap $RawLineCap -Overflowed ([ref]$lineOverflowed)
                        Update-PemScanState -Segment ([string]::new($charBuffer, $idx, ($charCount - $idx))) -InPem ([ref]$inPem) -ScanTail ([ref]$pemScanTail)
                        $idx = $charCount
                        continue
                    }
                    if ($cr -ge 0 -and (($nl -lt 0) -or ($cr -lt $nl))) {
                        # Terminator is the CR at $cr (lone CR, or CR whose LF
                        # follows later in this chunk or in the next one).
                        Add-CappedChars -Builder $lineBuilder -CurrentLength ([ref]$lineLength) -Buffer $charBuffer -Start $idx -Count ($cr - $idx) -Cap $RawLineCap -Overflowed ([ref]$lineOverflowed)
                        Update-PemScanState -Segment ([string]::new($charBuffer, $idx, ($cr - $idx))) -InPem ([ref]$inPem) -ScanTail ([ref]$pemScanTail)
                        if ($cr -eq ($charCount - 1)) {
                            $lastWasCR = $true
                            $idx = $charCount
                        } elseif ($charBuffer[$cr + 1] -eq "`n") {
                            $idx = $cr + 2
                        } else {
                            $idx = $cr + 1
                        }
                    } else {
                        Add-CappedChars -Builder $lineBuilder -CurrentLength ([ref]$lineLength) -Buffer $charBuffer -Start $idx -Count ($nl - $idx) -Cap $RawLineCap -Overflowed ([ref]$lineOverflowed)
                        Update-PemScanState -Segment ([string]::new($charBuffer, $idx, ($nl - $idx))) -InPem ([ref]$inPem) -ScanTail ([ref]$pemScanTail)
                        $idx = $nl + 1
                    }
                    $redacted = $script:LongLinePlaceholder
                    if (-not $lineOverflowed) {
                        $redacted = ConvertTo-RedactedLineCore -Line $lineBuilder.ToString() ([ref]$inPem) ([ref]$pendingKey) -IncludeLongTokens
                        if ($redacted.Length -gt $MaxLineLength) { $redacted = $redacted.Substring(0, $MaxLineLength) }
                    }
                    $ring.Enqueue($redacted)
                    while ($ring.Count -gt $TailLines) { $null = $ring.Dequeue() }
                    $null = $lineBuilder.Clear()
                    $lineLength = 0
                    $lineOverflowed = $false
                    $pemScanTail = ''
                }
            }
            # Flush the decoder and emit a final line without a terminator.
            $tailChars = $decoder.GetChars($byteBuffer, 0, 0, $charBuffer, 0, $true)
            if ($tailChars -gt 0) {
                Add-CappedChars -Builder $lineBuilder -CurrentLength ([ref]$lineLength) -Buffer $charBuffer -Start 0 -Count $tailChars -Cap $RawLineCap -Overflowed ([ref]$lineOverflowed)
                Update-PemScanState -Segment ([string]::new($charBuffer, 0, $tailChars)) -InPem ([ref]$inPem) -ScanTail ([ref]$pemScanTail)
            }
            if ($lineBuilder.Length -gt 0) {
                $redacted = $script:LongLinePlaceholder
                if (-not $lineOverflowed) {
                    $redacted = ConvertTo-RedactedLineCore -Line $lineBuilder.ToString() ([ref]$inPem) ([ref]$pendingKey) -IncludeLongTokens
                    if ($redacted.Length -gt $MaxLineLength) { $redacted = $redacted.Substring(0, $MaxLineLength) }
                }
                $ring.Enqueue($redacted)
                while ($ring.Count -gt $TailLines) { $null = $ring.Dequeue() }
            }
            $unterminatedPem = [bool]$inPem
        } finally {
            $stream.Dispose()
        }
    } catch {
        $errors.Add((New-DiagError 'ReadFailed' ('Could not read supervisor log: ' + $LogFilePath + ' (' + $_.Exception.GetType().Name + ')')))
    }
    $sw.Stop()

    return [pscustomobject]@{
        Lines           = $ring.ToArray()
        Errors          = $errors.ToArray()
        Truncated       = [bool]$truncated
        Incomplete      = [bool]$incomplete
        UnterminatedPem = [bool]$unterminatedPem
        ScannedBytes    = $scannedBytes
    }
}

function Get-SupervisorLogSection {
    param([string]$StateDirectory, [int]$TailLines, [int]$TimeoutSeconds, [int]$ScanMaxBytes)

    $errors = New-Object System.Collections.Generic.List[object]
    $logPath = [System.IO.Path]::Combine($StateDirectory, 'runtime\bin\_supervisor.log')
    $exists = Test-SafeLeaf $logPath
    $tail = @()
    $truncated = $false
    $incomplete = $false
    $unterminatedPem = $false
    $scannedBytes = [int64]0
    if (-not $exists) {
        $errors.Add((New-DiagError 'FileNotFound' "Supervisor log not found: $logPath"))
    } elseif ($TailLines -gt 0) {
        # -LogTailLines 0 never opens the file at all.
        $read = Read-SupervisorLogTail -LogFilePath $logPath -TailLines $TailLines -TimeoutMilliseconds ($TimeoutSeconds * 1000) -ScanMaxBytes $ScanMaxBytes
        $tail = @($read.Lines)
        $truncated = $read.Truncated
        $incomplete = $read.Incomplete
        $unterminatedPem = $read.UnterminatedPem
        $scannedBytes = $read.ScannedBytes
        foreach ($readError in @($read.Errors)) { $errors.Add($readError) }
    }

    return [ordered]@{
        ok              = ($errors.Count -eq 0)
        errors          = $errors.ToArray()
        path            = $logPath
        exists          = [bool]$exists
        requestedLines  = $TailLines
        returnedLines   = $tail.Count
        truncated       = [bool]$truncated
        scannedBytes    = $scannedBytes
        incomplete      = [bool]$incomplete
        unterminatedPem = [bool]$unterminatedPem
        lines           = $tail
    }
}

function Get-ExtraLogEntries {
    # Reads each named log through the same bounded, redacting reader as
    # the supervisor log and returns one entry per path, shaped like the
    # supervisorLog section. A missing file is an entry-level error, never
    # a thrown exception. Command-line callers pass the paths '|'-joined
    # inside one string (powershell.exe -File cannot pass arrays); every
    # element is split on '|' first.
    param([string[]]$Paths, [int]$TailLines, [int]$TimeoutSeconds, [int]$ScanMaxBytes)

    $resolvedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($rawPath in @($Paths)) {
        if ([string]::IsNullOrEmpty($rawPath)) { continue }
        foreach ($part in ($rawPath -split '\|')) {
            if ([string]::IsNullOrEmpty($part)) { continue }
            $resolvedPaths.Add($part)
        }
    }

    $logs = New-Object System.Collections.Generic.List[object]
    foreach ($logPath in $resolvedPaths) {
        $errors = New-Object System.Collections.Generic.List[object]
        $exists = Test-SafeLeaf $logPath
        $tail = @()
        $truncated = $false
        $incomplete = $false
        $unterminatedPem = $false
        $scannedBytes = [int64]0
        if (-not $exists) {
            $errors.Add((New-DiagError 'FileNotFound' "Extra log not found: $logPath"))
        } elseif ($TailLines -gt 0) {
            $read = Read-SupervisorLogTail -LogFilePath $logPath -TailLines $TailLines -TimeoutMilliseconds ($TimeoutSeconds * 1000) -ScanMaxBytes $ScanMaxBytes
            $tail = @($read.Lines)
            $truncated = $read.Truncated
            $incomplete = $read.Incomplete
            $unterminatedPem = $read.UnterminatedPem
            $scannedBytes = $read.ScannedBytes
            foreach ($readError in @($read.Errors)) { $errors.Add($readError) }
        }
        $logs.Add([ordered]@{
            ok              = ($errors.Count -eq 0)
            errors          = $errors.ToArray()
            path            = $logPath
            exists          = [bool]$exists
            requestedLines  = $TailLines
            returnedLines   = $tail.Count
            truncated       = [bool]$truncated
            scannedBytes    = $scannedBytes
            incomplete      = [bool]$incomplete
            unterminatedPem = [bool]$unterminatedPem
            lines           = $tail
        })
    }
    return $logs.ToArray()
}

# ---------------------------------------------------------------------------
# Hygiene (night batch A). The ACL decision is a pure function over one
# SDDL string: no disk access, no account names, locale-independent.
# ---------------------------------------------------------------------------
function Test-GsSddlWritableByNonAdmin {
    # PURE and self-contained (tests AST-extract and run it standalone):
    # parses one SDDL string into an in-memory DirectorySecurity and
    # returns
    #   Protected : the DACL protected flag (the P control flag)
    #   OwnerSid  : raw owner SID string, $null when the SDDL has no owner
    #   Writers   : Allow ACEs granting a write right to a SID outside the
    #               administrative allowlist, as { sid; mask } with the
    #               per-SID write bits OR-merged
    # Write right bits: 0x2 write data, 0x4 append data, 0x10 write EA,
    # 0x40 delete child, 0x100 write attributes, 0x10000 delete,
    # 0x40000 write DACL, 0x80000 write owner, 0x10000000 generic all,
    # 0x40000000 generic write. Allowlist: SYSTEM (S-1-5-18),
    # Administrators (S-1-5-32-544) and TrustedInstaller
    # (S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464).
    # Inherit-only CREATOR OWNER (S-1-3-0) ACEs are ignored; deny ACEs are
    # never grants. Throws on an unparseable SDDL. SIDs are compared as
    # SID strings only, never account names.
    param([string]$Sddl)
    $allowedSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $creatorOwnerSid = 'S-1-3-0'
    $writeBits = @(
        [int64]0x2, [int64]0x4, [int64]0x10, [int64]0x40, [int64]0x100,
        [int64]0x10000, [int64]0x40000, [int64]0x80000,
        [int64]0x10000000, [int64]0x40000000)
    $writeMaskAll = [int64]0
    foreach ($bit in $writeBits) { $writeMaskAll = $writeMaskAll -bor $bit }

    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetSecurityDescriptorSddlForm($Sddl)
    $writers = New-Object System.Collections.Generic.List[object]
    $rules = $security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = [string]$rule.IdentityReference
        if ($sid -ieq $creatorOwnerSid -and
            (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0)) { continue }
        if ($allowedSids -icontains $sid) { continue }
        # FileSystemRights is the PowerShell-exposed raw access mask of the
        # rule (the adapter does not surface AccessMask); its numeric value
        # is the ACE's raw mask, generic bits included.
        $granted = ([int64]$rule.FileSystemRights) -band $writeMaskAll
        if ($granted -eq [int64]0) { continue }
        $existing = $null
        foreach ($writer in $writers) {
            if ([string]$writer.sid -ieq $sid) { $existing = $writer; break }
        }
        if ($null -ne $existing) { $existing.mask = ($existing.mask -bor $granted) }
        else { $writers.Add([pscustomobject]@{ sid = $sid; mask = $granted }) }
    }
    $ownerSid = $null
    try {
        $owner = $security.GetOwner([System.Security.Principal.SecurityIdentifier])
        if ($null -ne $owner) { $ownerSid = [string]$owner }
    } catch { $ownerSid = $null }
    return [pscustomobject]@{
        Protected = [bool]$security.AreAccessRulesProtected
        OwnerSid  = $ownerSid
        Writers   = $writers.ToArray()
    }
}

function Hide-GsMachineSid {
    # Masks machine-local account SIDs (S-1-5-21-a-b-c-RID) to
    # S-1-5-21-*-RID so reports stay share-safe; well-known SIDs do not
    # match the pattern and stay as they are.
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [System.Text.RegularExpressions.Regex]::Replace($Text, 'S-1-5-21-\d+-\d+-\d+-(\d+)', 'S-1-5-21-*-$1')
}

function Hide-GsMachineSidInObject {
    # Final-pass masking: rebuilds the object graph with Hide-GsMachineSid
    # applied to EVERY string, so a machine-local SID cannot survive in
    # any emitted field (pause flag first lines, log lines, paths, error
    # messages), not only in the ACL owner/writer fields. Property order
    # and the report shape are preserved; non-string scalars (numbers,
    # booleans, timestamps) pass through unchanged.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Hide-GsMachineSid $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{ }
        foreach ($key in @($Value.Keys)) { $out[$key] = Hide-GsMachineSidInObject -Value $Value[$key] }
        return $out
    }
    if ($Value -is [pscustomobject]) {
        $out = [ordered]@{ }
        foreach ($prop in @($Value.PSObject.Properties)) { $out[$prop.Name] = Hide-GsMachineSidInObject -Value $prop.Value }
        return [pscustomobject]$out
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($element in @($Value)) { $out.Add((Hide-GsMachineSidInObject -Value $element)) }
        # The comma operator keeps PowerShell from unrolling the array into
        # the function's output pipeline: a 1-element array would otherwise
        # come back as its single element and an empty array as nothing.
        return ,($out.ToArray())
    }
    return $Value
}

function Get-SafeFlagFirstLine {
    # First line of a small flag file, read through a bounded, share-
    # tolerant open (at most 8192 bytes), or $null when unreadable.
    # Redaction and truncation happen in the caller.
    param([string]$Path)
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $buffer = New-Object byte[] 8192
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { return '' }
            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            $newline = $text.IndexOfAny([char[]]@("`r", "`n"))
            if ($newline -ge 0) { $text = $text.Substring(0, $newline) }
            return $text
        } finally { $stream.Dispose() }
    } catch { return $null }
}

function Get-SafeIsoText {
    # Best-effort ISO-8601 (round-trip) text of a DateTime-like value; any
    # other value becomes redacted, bounded text; $null stays $null.
    param($Value, [int]$MaxLength = 64)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    } catch { }
    return (ConvertTo-SafeText ([string]$Value) $MaxLength)
}

function Get-HostSection {
    # Read-only host facts for the release manifest: GPU name, driver
    # version and driver date (Win32_VideoController) and the OS caption,
    # version and build (Win32_OperatingSystem). Every lookup failure
    # becomes a section error, never a throw. The scriptblock parameters
    # are test seams; production uses the live read-only CIM queries.
    param(
        [bool]$GpuQueryInjected,
        $GpuQuery,
        [bool]$OsQueryInjected,
        $OsQuery,
        [bool]$SkipHost
    )

    $errors = New-Object System.Collections.Generic.List[object]
    $gpus = New-Object System.Collections.Generic.List[object]
    $os = $null

    if ($SkipHost) {
        return [ordered]@{
            ok      = $true
            errors  = @()
            skipped = $true
            gpus    = @()
            os      = $null
        }
    }

    try {
        $controllers = $null
        if ($GpuQueryInjected) {
            $controllers = @(& $GpuQuery)
        } else {
            $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        }
        foreach ($controller in $controllers) {
            if ($null -eq $controller) { continue }
            $nameProp = $controller.PSObject.Properties['Name']
            $driverVersionProp = $controller.PSObject.Properties['DriverVersion']
            $driverDateProp = $controller.PSObject.Properties['DriverDate']
            $gpus.Add([pscustomobject]@{
                name          = $(if ($null -ne $nameProp) { ConvertTo-SafeText ([string]$nameProp.Value) 256 } else { $null })
                driverVersion = $(if ($null -ne $driverVersionProp) { ConvertTo-SafeText ([string]$driverVersionProp.Value) 128 } else { $null })
                driverDate    = $(if ($null -ne $driverDateProp) { Get-SafeIsoText $driverDateProp.Value } else { $null })
            })
        }
    } catch {
        $errors.Add((New-DiagError 'HostLookupFailed' ('Could not query the video controllers: ' + $_.Exception.Message)))
    }

    try {
        $operatingSystem = $null
        if ($OsQueryInjected) {
            $operatingSystem = & $OsQuery
        } else {
            $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        }
        if ($null -ne $operatingSystem) {
            $captionProp = $operatingSystem.PSObject.Properties['Caption']
            $versionProp = $operatingSystem.PSObject.Properties['Version']
            $buildProp = $operatingSystem.PSObject.Properties['BuildNumber']
            $os = [pscustomobject]@{
                caption = $(if ($null -ne $captionProp) { ConvertTo-SafeText ([string]$captionProp.Value) 256 } else { $null })
                version = $(if ($null -ne $versionProp) { ConvertTo-SafeText ([string]$versionProp.Value) 64 } else { $null })
                build   = $(if ($null -ne $buildProp) { ConvertTo-SafeText ([string]$buildProp.Value) 64 } else { $null })
            }
        }
    } catch {
        $errors.Add((New-DiagError 'HostLookupFailed' ('Could not query the operating system: ' + $_.Exception.Message)))
    }

    return [ordered]@{
        ok      = ($errors.Count -eq 0)
        errors  = $errors.ToArray()
        skipped = $false
        gpus    = $gpus.ToArray()
        os      = $os
    }
}

function Get-HygieneSection {
    # Read-only hygiene checks: the supervisor scheduled task, the two
    # pause flag candidates, the script directory ACLs and the status file
    # ambiguity. Nothing is ever written, modified or deleted.
    param(
        [string]$InstallDirPath,
        [string]$StateDirectory,
        [string]$TaskName,
        [bool]$TaskInfoInjected,
        $TaskInfo,
        [bool]$SkipAcl,
        [bool]$AclSddlInjected,
        [string[]]$AclSddl
    )

    $errors = New-Object System.Collections.Generic.List[object]
    $findings = New-Object System.Collections.Generic.List[object]
    $allowedSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')

    # --- supervisor task (read-only query or injected test seam) ---
    $taskQueried = $false
    $taskExists = $null
    $taskState = $null
    $taskActionPath = $null
    $displayName = ConvertTo-SafeText $TaskName 256
    if ($TaskInfoInjected) {
        $taskQueried = $true
        if ($null -ne $TaskInfo) {
            $taskExists = $true
            $stateProp = $TaskInfo.PSObject.Properties['State']
            if ($null -ne $stateProp) { $taskState = ConvertTo-SafeText ([string]$stateProp.Value) 64 }
            $actionsProp = $TaskInfo.PSObject.Properties['Actions']
            if ($null -ne $actionsProp) {
                # StrictMode 3.0 forbids indexing beyond the array bounds,
                # so an empty Actions list is checked before indexing.
                $actionList = @($actionsProp.Value)
                $firstAction = $null
                if ($actionList.Count -gt 0) { $firstAction = $actionList[0] }
                if ($null -ne $firstAction) {
                    $executeProp = $firstAction.PSObject.Properties['Execute']
                    if ($null -ne $executeProp) { $taskActionPath = ConvertTo-SafeText ([string]$executeProp.Value) 512 }
                }
            }
        } else {
            $taskExists = $false
        }
    } elseif (-not [string]::IsNullOrEmpty($TaskName)) {
        $taskQueried = $true
        $task = $null
        try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { $task = $null }
        if ($null -ne $task) {
            $taskExists = $true
            try { $taskState = ConvertTo-SafeText ([string]$task.State) 64 } catch { $taskState = $null }
            try {
                $taskActionList = @($task.Actions)
                $firstAction = $null
                if ($taskActionList.Count -gt 0) { $firstAction = $taskActionList[0] }
                if ($null -ne $firstAction) { $taskActionPath = ConvertTo-SafeText ([string]$firstAction.Execute) 512 }
            } catch { $taskActionPath = $null }
        } else {
            $taskExists = $false
        }
    }

    $entryPath = [System.IO.Path]::Combine($InstallDirPath, 'gs-product.ps1')
    if ($taskQueried -and $taskExists -and -not (Test-SafeLeaf $entryPath)) {
        $findings.Add([pscustomobject]@{
            code     = 'OrphanedSupervisorTask'
            severity = 'warning'
            message  = (ConvertTo-RedactedText ('Scheduled task ' + $displayName + ' exists but the product entry was not found at ' + $entryPath + '; the task may keep restarting a removed product.'))
            path     = $entryPath
        })
    }
    if ($taskQueried -and ($taskExists -eq $false)) {
        $findings.Add([pscustomobject]@{
            code     = 'SupervisorTaskMissing'
            severity = 'info'
            message  = (ConvertTo-RedactedText ('Scheduled task ' + $displayName + ' was not found; supervisor autostart is not registered.'))
            path     = $displayName
        })
    }

    # --- supervisor pause flags (both candidates) ---
    $pauseFlags = New-Object System.Collections.Generic.List[object]
    foreach ($flagPath in @(
            [System.IO.Path]::Combine($StateDirectory, 'supervisor_pause.flag'),
            [System.IO.Path]::Combine($StateDirectory, 'runtime\state\supervisor_pause.flag'))) {
        $flagTime = Get-SafeLastWriteUtc $flagPath
        $flagExists = ($null -ne $flagTime)
        $firstLine = $null
        if ($flagExists) {
            $rawLine = Get-SafeFlagFirstLine $flagPath
            if ($null -ne $rawLine) { $firstLine = ConvertTo-SafeText $rawLine 200 }
            $findings.Add([pscustomobject]@{
                code     = 'SupervisorPaused'
                severity = 'warning'
                message  = (ConvertTo-RedactedText ('Supervisor pause flag present at ' + $flagPath + ' (last write ' + $flagTime.ToString('o') + '); automatic recovery stays paused until it is removed.'))
                path     = $flagPath
            })
        }
        $pauseFlags.Add([pscustomobject]@{
            path             = $flagPath
            exists           = [bool]$flagExists
            lastWriteTimeUtc = $(if ($null -ne $flagTime) { $flagTime.ToString('o') } else { $null })
            firstLine        = $firstLine
        })
    }

    # --- script directory ACLs: <StateDir>\runtime, then <StateDir>\runtime\bin ---
    $scriptDirAcl = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt 2; $i++) {
        $dirPath = [System.IO.Path]::Combine($StateDirectory, $(if ($i -eq 0) { 'runtime' } else { 'runtime\bin' }))
        $entry = [pscustomobject]@{
            path      = $dirPath
            skipped   = [bool]$SkipAcl
            available = $null
            protected = $null
            ownerSid  = $null
            writers   = @()
        }
        if ($SkipAcl) {
            $scriptDirAcl.Add($entry)
            continue
        }
        $sddl = $null
        if ($AclSddlInjected) {
            if ($i -lt @($AclSddl).Count) {
                $sddl = @($AclSddl)[$i]
                $entry.available = $true
            } else {
                $errors.Add((New-DiagError 'AclReadFailed' ('No injected SDDL was provided for ' + $dirPath + '.')))
            }
        } else {
            if (Test-SafeContainer $dirPath) {
                $entry.available = $true
                try {
                    $acl = Get-Acl -LiteralPath $dirPath -ErrorAction Stop
                    $sddl = $acl.Sddl
                } catch {
                    # A fixed message without the raw exception text: ACL
                    # error wording is not a privacy boundary (it can name
                    # accounts or carry descriptor details).
                    $entry.available = $false
                    $errors.Add((New-DiagError 'AclReadFailed' ('Could not read the ACL of ' + $dirPath + '.')))
                }
            } else {
                $entry.available = $false
                $errors.Add((New-DiagError 'DirectoryMissing' ('Directory not found: ' + $dirPath)))
            }
        }
        if ($null -ne $sddl) {
            try {
                $verdict = Test-GsSddlWritableByNonAdmin -Sddl $sddl
                $entry.protected = [bool]$verdict.Protected
                $entry.ownerSid = $(if ($null -ne $verdict.OwnerSid) { Hide-GsMachineSid ([string]$verdict.OwnerSid) } else { $null })
                $writerList = New-Object System.Collections.Generic.List[object]
                foreach ($writer in @($verdict.Writers)) {
                    $maskedSid = Hide-GsMachineSid ([string]$writer.sid)
                    $rightsHex = ('0x{0:x}' -f [int64]$writer.mask)
                    $writerList.Add([pscustomobject]@{ sid = $maskedSid; rightsHex = $rightsHex })
                    $findings.Add([pscustomobject]@{
                        code     = 'ScriptDirWritableByNonAdmin'
                        severity = 'high'
                        message  = (ConvertTo-RedactedText ('Directory ' + $dirPath + ' grants write rights (' + $rightsHex + ') to SID ' + $maskedSid + '; scripts there run as SYSTEM.'))
                        path     = $dirPath
                    })
                }
                $entry.writers = $writerList.ToArray()
                if (($null -ne $verdict.OwnerSid) -and (-not ($allowedSids -icontains ([string]$verdict.OwnerSid)))) {
                    $maskedOwner = Hide-GsMachineSid ([string]$verdict.OwnerSid)
                    $findings.Add([pscustomobject]@{
                        code     = 'ScriptDirWritableByNonAdmin'
                        severity = 'high'
                        message  = (ConvertTo-RedactedText ('Directory ' + $dirPath + ' is owned by SID ' + $maskedOwner + ', which is outside the administrative allowlist and can rewrite the ACL.'))
                        path     = $dirPath
                    })
                }
            } catch {
                # Fixed message, no raw exception text (the same privacy
                # rule as AclReadFailed above).
                $errors.Add((New-DiagError 'AclParseFailed' ('Could not evaluate the SDDL of ' + $dirPath + '.')))
            }
        }
        $scriptDirAcl.Add($entry)
    }

    # --- status file ambiguity ---
    $statusA = [System.IO.Path]::Combine($StateDirectory, 'runtime\state\status.json')
    $statusB = [System.IO.Path]::Combine($StateDirectory, 'status.json')
    if ((Test-SafeLeaf $statusA) -and (Test-SafeLeaf $statusB)) {
        $findings.Add([pscustomobject]@{
            code     = 'StatusFileAmbiguous'
            severity = 'warning'
            message  = (ConvertTo-RedactedText ('Both status file candidates exist (' + $statusA + ' and ' + $statusB + '); the newest one wins, which may not be the file the runtime writes.'))
            path     = $statusA
        })
    }

    return [ordered]@{
        ok             = ($errors.Count -eq 0)
        errors         = $errors.ToArray()
        supervisorTask = [pscustomobject]@{
            name       = $displayName
            skipped    = (-not $taskQueried)
            exists     = $taskExists
            state      = $taskState
            actionPath = $taskActionPath
        }
        pauseFlags     = $pauseFlags.ToArray()
        scriptDirAcl   = $scriptDirAcl.ToArray()
        findings       = $findings.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')

$productSection = [pscustomobject](Invoke-GuardedSection 'product' { Get-ProductSection -InstallDirPath $InstallDir -ModulesRoot $ModuleRoot -SkipMsiLookup ([bool]$SkipInstalledProductLookup) })
$runtimeConfigSection = [pscustomobject](Invoke-GuardedSection 'runtimeConfig' { Get-RuntimeConfigSection -StateDirectory $StateDir })
$statusSection = [pscustomobject](Invoke-GuardedSection 'status' { Get-StatusSection -StateDirectory $StateDir })
$serverInfoSection = [pscustomobject](Invoke-GuardedSection 'serverInfo' { Get-ServerInfoSection -Uri $serverUri -TimeoutSeconds $TimeoutSec })
$componentsSection = [pscustomobject](Invoke-GuardedSection 'components' { Get-ComponentsSection -StateDirectory $StateDir })
$runtimeBundleSection = [pscustomobject](Invoke-GuardedSection 'runtimeBundle' { Get-RuntimeBundleSection -InstallDirPath $InstallDir -StateDirectory $StateDir })
$supervisorLogSection = [pscustomobject](Invoke-GuardedSection 'supervisorLog' { Get-SupervisorLogSection -StateDirectory $StateDir -TailLines $LogTailLines -TimeoutSeconds $TimeoutSec -ScanMaxBytes $LogScanMaxBytes })
# Capture the test-seam binding flags BEFORE the guarded section: a
# scriptblock invoked from a function resolves $PSBoundParameters
# dynamically against the FUNCTION, not this script.
$taskInfoInjected = $PSBoundParameters.ContainsKey('SupervisorTaskInfo')
$aclSddlInjected = $PSBoundParameters.ContainsKey('ScriptDirAclSddl')
$hostGpuQueryInjected = $PSBoundParameters.ContainsKey('HostGpuQuery')
$hostOsQueryInjected = $PSBoundParameters.ContainsKey('HostOsQuery')
$hygieneSection = [pscustomobject](Invoke-GuardedSection 'hygiene' { Get-HygieneSection -InstallDirPath $InstallDir -StateDirectory $StateDir -TaskName $SupervisorTaskName -TaskInfoInjected $taskInfoInjected -TaskInfo $SupervisorTaskInfo -SkipAcl ([bool]$SkipAclCheck) -AclSddlInjected $aclSddlInjected -AclSddl $ScriptDirAclSddl })
$hostSection = [pscustomobject](Invoke-GuardedSection 'host' { Get-HostSection -GpuQueryInjected $hostGpuQueryInjected -GpuQuery $HostGpuQuery -OsQueryInjected $hostOsQueryInjected -OsQuery $HostOsQuery -SkipHost ([bool]$SkipHostCheck) })

$extraLogEntries = @()
try {
    $extraLogEntries = @(Get-ExtraLogEntries -Paths $ExtraLogPath -TailLines $LogTailLines -TimeoutSeconds $TimeoutSec -ScanMaxBytes $LogScanMaxBytes)
} catch {
    # An unexpected extraLogs failure keeps the report shape: one minimal
    # entry with a SectionFailed error.
    $extraLogEntries = @([pscustomobject]@{
        ok              = $false
        errors          = @((New-DiagError 'SectionFailed' ('extraLogs failed unexpectedly: ' + $_.Exception.Message)))
        path            = $null
        exists          = $false
        requestedLines  = $LogTailLines
        returnedLines   = 0
        truncated       = $false
        scannedBytes    = [int64]0
        incomplete      = $false
        unterminatedPem = $false
        lines           = @()
    })
}

$sectionMap = [ordered]@{
    product       = $productSection
    runtimeConfig = $runtimeConfigSection
    status        = $statusSection
    serverInfo    = $serverInfoSection
    components    = $componentsSection
    runtimeBundle = $runtimeBundleSection
    supervisorLog = $supervisorLogSection
    hygiene       = $hygieneSection
    host          = $hostSection
}
$topErrors = New-Object System.Collections.Generic.List[object]
foreach ($sectionName in $sectionMap.Keys) {
    foreach ($sectionError in @($sectionMap[$sectionName].errors)) {
        $topErrors.Add([pscustomobject]@{
            section = $sectionName
            code    = [string]$sectionError.code
            message = [string]$sectionError.message
        })
    }
}
# extraLogs is an array of per-log entries; their errors aggregate under
# the section label extraLogs.
foreach ($extraEntry in $extraLogEntries) {
    foreach ($sectionError in @($extraEntry.errors)) {
        $topErrors.Add([pscustomobject]@{
            section = 'extraLogs'
            code    = [string]$sectionError.code
            message = [string]$sectionError.message
        })
    }
}

$report = [pscustomobject]@{
    schemaVersion     = 1
    generatedAtUtc    = $generatedAtUtc
    computerName      = [System.Environment]::MachineName
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    paths             = [pscustomobject]@{
        installDir = $InstallDir
        stateDir   = $StateDir
        logDir     = $LogDir
        moduleRoot = $ModuleRoot
    }
    product           = $sectionMap.product
    runtimeConfig     = $sectionMap.runtimeConfig
    status            = $sectionMap.status
    serverInfo        = $sectionMap.serverInfo
    components        = $sectionMap.components
    runtimeBundle     = $sectionMap.runtimeBundle
    supervisorLog     = $sectionMap.supervisorLog
    hygiene           = $sectionMap.hygiene
    host              = $sectionMap.host
    extraLogs         = $extraLogEntries
    errors            = $topErrors.ToArray()
}

# Final privacy pass after classification: mask machine-local SIDs in
# EVERY emitted string of the report (pause flag first lines, log lines,
# paths, error messages), not only the ACL owner/writer fields that were
# masked while the sections were built.
$report = Hide-GsMachineSidInObject $report

if ($AsJson) {
    Write-Output ($report | ConvertTo-Json -Depth 8)
} else {
    Write-Output $report
}
exit 0
