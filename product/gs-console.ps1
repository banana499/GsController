#requires -Version 5.1
<#
.SYNOPSIS
  Local web console host for GsController: a loopback-only HTTP server
  (PowerShell 5.1 HttpListener) that serves the fixed static console assets
  and a small JSON API over the existing gs-product.ps1 CLI.

.DESCRIPTION
  Security contract (LOCAL-CONSOLE-CONTRACT.md + coordinator clarifications):

  - Binds ONLY the two exact same-machine loopback prefixes
    http://127.0.0.1:<port>/ and http://localhost:<port>/ (default 47991).
    No URL ACL and no
    firewall rule is ever created; a listener that cannot start fails with a
    clear message and a nonzero exit code (2 = a console is already running
    on that port, 3 = listener permission/other failure). Startup and
    listener failures keep their stderr lines and exit codes; the interactive
    launcher additionally passes -ShowStartupErrors, which shows ONE fixed
    localized MessageBox per failure (no exception text, no session data);
    automation and -NoTray never show a dialog.
  - Every request is verified against the actual RemoteEndPoint: non-loopback
    peers are rejected, IPv4-mapped IPv6 (::ffff:127.0.0.1) is normalized to
    plain IPv4 first. The Host header must be one of the two exact
    same-machine loopback aliases, 127.0.0.1:<port> or localhost:<port>;
    Origin must be the matching http:// form. Wildcard/+ /LAN prefixes are
    never registered.
  - A cryptographic random per-start session secret (live mode) is handed to
    the browser ONLY through the #session=<token> URL fragment of the launch
    URL (browser auto-open or the optional tray Open menu). The token is
    never written to any file or log and never returned by any endpoint.
    Token comparison is a fixed-length byte fold (constant-time shape,
    .NET Framework 4.x compatible - no CryptographicOperations API).
  - All /api routes require the X-Gs-Session header (401 otherwise).
    Mutating (POST) requests additionally require the exact same-loopback
    Origin header (403 otherwise). Unknown routes/methods: 404. JSON bodies
    are capped at 16 KiB and read with a hard deadline; unknown or missing
    fields and wrong types are rejected field by field.
  - Static assets are a FIXED name map (/, /gs-console.css, /gs-console.js)
    served from -StaticDir (default: this script's directory). There is no
    path-to-file translation, so no traversal or arbitrary file read exists.
    The HTML has __GS_MODE__ substituted with demo|live. Every response
    carries Cache-Control no-store, X-Content-Type-Options nosniff,
    Referrer-Policy no-referrer; static responses also carry
    Content-Security-Policy "default-src 'self'; frame-ancestors 'none'".
  - Sunshine backend (-Backend Sunshine, or a build-generated
    gs-install-profile.json next to this script with backend 'sunshine')
    is an EXTERNAL-runtime guide mode. Sunshine itself owns installation,
    accounts, PIN pairing and streaming; this console only points the user
    at the official pages and reports read-only detection. It serves a
    fixed FOUR-entry static map (/, /gs-sunshine.js, /gs-console.css,
    /gs-sunshine.css) and exactly one API route, GET /api/sunshine/status
    (session required, same loopback/Host/Origin rules). Every legacy API
    route (/api/state, /api/settings, /api/actions, /api/jobs,
    /api/demo/scenario) is a 404 and the legacy CLI, the GsRuntime module,
    the prefs file and the jobs root are never touched. The status is
    detection ONLY: the official default install location (file metadata)
    and one local TCP connect to 127.0.0.1:47990 with a hard 1 s timeout -
    no HTTP, no TLS handling, no credentials, and never a claim that
    pairing or streaming is working. Demo Sunshine returns a fixed
    synthetic snapshot and never probes.
  - Demo mode (starting with -Demo) uses the fixed token 'gs-console-demo',
    never reads the real machine configuration, never spawns any process,
    and never calls the live action handler. Its configuration lives in a
    newly created TEMP directory. POST /api/demo/scenario exists only in
    demo mode (404 in live mode); demo mode is immutable over HTTP.
  - Long actions run gs-product.ps1 through the fixed -File helper
    gs-console-action.ps1 with a server-generated JSON request file and a
    server-generated result file path. Browser input can never choose a
    command, script or path. Stop gets the existing 300 s budget; a job
    that passes its deadline is reported truthfully as failed (code
    'Timeout') - the result file is always checked FIRST, so completion
    wins over the deadline - and a deadline itself ends ONLY the console's
    own wrapper process (the helper hosting the inline CLI call, ended with
    a single Process.Kill and its exit confirmed before the failure is
    reported). A failure before the helper process exists (the request write
    or the process start) completes the registered job as a truthful
    'LaunchFailed' failure immediately, so the console is never Busy on a
    process-less job. No process tree is ever killed and the runtime
    processes the helper started keep running.
  - CLI raw output is never exposed. Only the LAST structured Success
    object is selected; the Web sees a fixed per-action allowlist: browse
    {selectedPath}, check {ready, checks[]}, diagnose {generatedAt,
    checks[], summary}, deploy {configured}, lifecycle/autostart {}. The
    full support bundle (gs-support.ps1) is never invoked from this
    (normally elevated) server.
  - Saving console preferences writes ONLY the console prefs file (atomic
    temp+rename). It never deploys, moves files, registers tasks or touches
    the existing runtime-config.json (which is READ once in live mode to
    initialize the known layout). Start/Stop/Recover readiness depends on
    the deployed runtime metadata (runtime\bin marker + status file), never
    on the presence of the redeployment-only component/helper source dirs.
  - The optional tray (-NoTray skips it) offers only Open (re-opens the
    in-memory launch URL) and Exit (refused while an action is running).
    Exiting the console never stops the runtime.

  No log file is written by this server at all; there is nothing to leak.

  Launcher parameters (trusted startup inputs; the browser can never set
  these): -Port, -Demo, -Backend, -NoBrowser, -NoTray, -ConfigPath
  (explicit prefs path for tests; ignored by the Sunshine backend),
  -ProductPath, -ModuleRoot, -StaticDir, -StateDir (default state dir
  override used by tests so no real machine layout is read), -ProfilePath
  (test seam: explicit gs-install-profile.json path instead of the
  sibling default), -ServerInfoUri, -ExitAfterSec (forced auto-exit for
  smoke runs), -DefineOnly (define functions and exit; used by the test
  suite).

  User-facing Chinese text lives in gs-console-strings.zh-CN.json next to
  this script; this source stays ASCII. API messages are English.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 47991,
    [switch]$Demo,
    # Backend selection. Explicit Legacy/Sunshine wins; when empty, the
    # build-generated gs-install-profile.json next to this script decides
    # (schemaVersion 1, backend 'legacy'|'sunshine'). A MISSING profile
    # defaults to Legacy for compatibility with old callers; a PRESENT but
    # INVALID profile fails startup - never a silent fallback. Its content
    # is bounded-read and parsed, never executed.
    [ValidateSet('Legacy', 'Sunshine', '')]
    [string]$Backend = '',
    # Test seam: explicit install-profile path instead of the sibling
    # gs-install-profile.json default (trusted startup input).
    [string]$ProfilePath = '',
    [switch]$NoBrowser,
    [switch]$NoTray,
    # Test seam: define all functions, initialize nothing, exit immediately.
    [switch]$DefineOnly,
    # Explicit console preferences JSON path (test seam; default is a
    # console-owned location under LocalApplicationData, or a fresh TEMP
    # directory in demo mode).
    [string]$ConfigPath = '',
    # Trusted startup inputs. The default live product path is the sibling
    # gs-product.ps1; module root defaults to sibling Modules or ..\src.
    [string]$ProductPath = '',
    [string]$ModuleRoot = '',
    [string]$StaticDir = '',
    # Trusted default state directory override (tests pass a TEMP path so
    # the real machine state layout is never read).
    [string]$StateDir = '',
    [string]$ServerInfoUri = 'http://127.0.0.1:47989/serverinfo',
    # Trusted startup session-secret override (TEST/DEV SEAM ONLY). When
    # empty, a cryptographic random per-start secret is generated and is
    # handed to the browser only through the #session launch-URL fragment.
    # An explicit value here never reaches any file or log on the server
    # side; production launches never pass it.
    [string]$SessionToken = '',
    # Interactive launcher seam: the VBS passes -ShowStartupErrors so a
    # failed start also shows one fixed-text MessageBox. Automation never
    # passes it and -NoTray suppresses it; stderr lines and exit codes are
    # identical either way and the dialog never shows exception text.
    [switch]$ShowStartupErrors = $false,
    # Forced auto-exit after N seconds. Test/smoke seam only: it exits even
    # while a job is running (the user-facing tray Exit refuses instead).
    [int]$ExitAfterSec = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Script-level state (initialized for every invocation, including -DefineOnly)
# ---------------------------------------------------------------------------
$script:ConsoleScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ConsoleScriptRoot)) {
    $script:ConsoleScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
# Reuse the tray model's PURE helpers (status-file read, state mapping,
# menu enable rules, pending-action decision, elevation probe). That file
# has no lifecycle logic and no UI types; nothing else of the tray is used.
. (Join-Path $script:ConsoleScriptRoot 'gs-tray-model.ps1')
# Optional pure library: Legacy builds do not require the Sunshine assets.
# Sunshine startup below requires the helper before serving its API.
$sunshineProbeLibrary = Join-Path $script:ConsoleScriptRoot 'gs-sunshine.ps1'
if (Test-Path -LiteralPath $sunshineProbeLibrary -PathType Leaf) {
    . $sunshineProbeLibrary
}
$script:Mode = 'live'
if ($Demo) { $script:Mode = 'demo' }
# NOTE: there is deliberately NO '$script:Backend = ...' initializer here,
# for the same reason as $SessionToken below: with -File the parameter and
# the $script: variable share storage, and an initializer would wipe a
# bound -Backend value. Resolve-GsConsoleStartup always assigns it exactly
# once (DefineOnly/test sessions read the bound parameter directly).
$script:DemoToken = 'gs-console-demo'
$script:BodyMaxBytes = 16384
$script:StaticFileMaxBytes = 1048576
$script:RequestReadTimeoutMs = 5000
$script:ServerInfoTimeoutMs = 1000
# Long-action budgets in seconds. Start and Stop keep the SAME 300 s cap
# the tray already uses for its pending-action wait (the 120 s state
# freshness grace is NOT a process timeout); recover bounds a full
# stop-plus-start. Completion always wins over the deadline.
$script:JobBudgetSec = @{
    start              = 300
    stop               = 300
    recover            = 420
    check              = 60
    deploy             = 600
    diagnose           = 120
    'autostart-enable'  = 60
    'autostart-disable' = 60
    browse             = 300
}
$script:JobHistoryLimit = 20

# NOTE: there is deliberately NO '$script:SessionToken = ""' initializer
# here: for a script run with -File the parameter and the $script: variable
# are the SAME storage, and an initializer would wipe a bound -SessionToken
# value. Resolve-GsConsoleStartup always assigns it exactly once.

$script:LaunchUrl = ''
$script:Listener = $null
$script:StopEvent = $null
$script:Notify = $null
$script:Prefs = $null
$script:ConfigFilePath = ''
$script:JobsRoot = ''
$script:ProductPathResolved = ''
$script:ModuleRootResolved = ''
$script:StaticDirResolved = ''
$script:ServerInfoUriResolved = $ServerInfoUri
$script:StateDirDefault = ''
$script:CurrentJob = $null
$script:JobHistory = New-Object System.Collections.Generic.List[object]
$script:LastCompleted = $null
$script:DemoScenario = 'stopped'
$script:DemoAutostart = 'disabled'
$script:LiveAutostartHint = 'unknown'
$script:GsRuntimeAvailable = $false
$script:InstallProfilePathResolved = ''

# ---------------------------------------------------------------------------
# Small helpers: strings, tokens, loopback checks, bounded reads
# ---------------------------------------------------------------------------

function Get-GsConsoleBuiltinStrings {
    # English fallback table (mirrors the tray's builtin-strings pattern).
    return @{
        'tooltip.prefix'       = 'GsController local console'
        'tray.open'            = 'Open console'
        'tray.exit'            = 'Exit'
        'balloon.busy'         = 'An action is running; exit is unavailable right now.'
        'tray.listenerDenied'  = 'Cannot listen on 127.0.0.1; restart with administrator rights.'
        'tray.alreadyRunning'  = 'The console is already running; use its tray Open menu to reopen the page.'
        'state.needsSetup'     = 'Needs setup'
        'state.stopped'        = 'Stopped'
        'state.starting'       = 'Starting'
        'state.stopping'       = 'Stopping'
        'state.ready'          = 'Ready'
        'state.streaming'      = 'Streaming'
        'state.error'          = 'Error'
        'state.unknown'        = 'Unknown'
        'startup.busy'         = 'GsController console is already running; reopen the page from its tray icon.'
        'startup.listenerFailed' = 'Cannot listen on 127.0.0.1; close the program using the port or retry as administrator.'
        'startup.startupFailed'  = 'GsController console did not start: check that program files are complete and the configuration directory is writable, then retry.'
        'startup.unsupported'    = 'GsController console requires 64-bit Windows with 64-bit Windows PowerShell 5.1.'
    }
}

$script:ConsoleStringsCache = $null

function Get-GsConsoleStrings {
    # Loads gs-console-strings.zh-CN.json (UTF-8, BOM tolerated) with the
    # same resource bounds as the tray table: 64 KiB file cap, 512 char
    # value cap, string keys only. Falls back to the builtin English table.
    if ($null -ne $script:ConsoleStringsCache) { return $script:ConsoleStringsCache }
    $builtin = Get-GsConsoleBuiltinStrings
    $table = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($key in $builtin.Keys) { $table[$key] = [string]$builtin[$key] }
    $path = Join-Path $script:ConsoleScriptRoot 'gs-console-strings.zh-CN.json'
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $info = Get-Item -LiteralPath $path
            if ($info.Length -le 65536) {
                $text = [IO.File]::ReadAllText($path)
                if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
                $json = $text | ConvertFrom-Json
                if ($null -ne $json -and $json -is [pscustomobject]) {
                    foreach ($prop in $json.PSObject.Properties) {
                        if ($prop.Value -is [string] -and $prop.Value.Length -le 512) {
                            $table[[string]$prop.Name] = [string]$prop.Value
                        }
                    }
                }
            }
        }
    } catch { }
    $script:ConsoleStringsCache = $table
    return $table
}

function Get-GsConsoleStateLabel {
    # Chinese display label for a console state name; unknown states come
    # back unchanged (never empty).
    param([Parameter(Mandatory = $true)][string]$State)
    $table = Get-GsConsoleStrings
    $key = 'state.' + $State.ToLowerInvariant()
    if ($table.ContainsKey($key)) { return $table[$key] }
    return $State
}

function Test-GsConsoleTokenEqual {
    # Constant-length secret comparison for .NET Framework 4.x: XOR-fold
    # over the longer length (missing bytes count as zero) and fold the
    # length difference into the same accumulator. No early exit.
    param([AllowEmptyString()][string]$Provided, [AllowEmptyString()][string]$Expected)
    $a = [Text.Encoding]::UTF8.GetBytes($Provided)
    $b = [Text.Encoding]::UTF8.GetBytes($Expected)
    $fold = [uint32]($a.Length -bxor $b.Length)
    $max = [Math]::Max($a.Length, $b.Length)
    for ($i = 0; $i -lt $max; $i++) {
        $byteA = 0; if ($i -lt $a.Length) { $byteA = [int]$a[$i] }
        $byteB = 0; if ($i -lt $b.Length) { $byteB = [int]$b[$i] }
        $fold = $fold -bor [uint32]($byteA -bxor $byteB)
    }
    return ($fold -eq 0)
}

function Get-GsConsoleNormalizedIpv4Bytes {
    # Returns the 4 plain IPv4 bytes for an address, normalizing an
    # IPv4-mapped IPv6 address (::ffff:a.b.c.d) manually so no 4.6+-only
    # API is required. Returns $null for non-IPv4 (after normalization).
    param([Parameter(Mandatory = $true)][System.Net.IPAddress]$Address)
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $Address.GetAddressBytes()
    }
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        $bytes = $Address.GetAddressBytes()
        if ($bytes.Length -ne 16) { return $null }
        $mapped = $true
        for ($i = 0; $i -lt 10; $i++) { if ($bytes[$i] -ne 0) { $mapped = $false; break } }
        if ($mapped -and ($bytes[10] -ne 0xFF -or $bytes[11] -ne 0xFF)) { $mapped = $false }
        if ($mapped) {
            return @($bytes[12], $bytes[13], $bytes[14], $bytes[15])
        }
    }
    return $null
}

function Test-GsConsoleLoopbackEndPoint {
    # The server binds ONLY 127.0.0.1, so the normalized peer address must
    # be exactly 127.0.0.1 (::1 is accepted defensively). A Host header
    # alone is not a network boundary.
    param([AllowNull()]$EndPoint)
    if ($null -eq $EndPoint) { return $false }
    try {
        $bytes = Get-GsConsoleNormalizedIpv4Bytes -Address $EndPoint.Address
        if ($null -eq $bytes) {
            # Unmapped IPv6: localhost may resolve to ::1, so the native IPv6
            # loopback form is accepted (IsLoopback covers any spelling).
            try { return [System.Net.IPAddress]::IsLoopback($EndPoint.Address) } catch { return $false }
        }
        return ($bytes[0] -eq 127 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0 -and $bytes[3] -eq 1)
    } catch { return $false }
}

function Read-GsConsoleBoundedStream {
    # Reads a stream as raw bytes with a total cap and a hard deadline that
    # is independent of the peer: every chunk is awaited with
    # task.Wait(remaining) against a Stopwatch, and on a wait timeout
    # -Request.Abort() is called. Same shape as the tray's bounded body
    # reader. Returns { Complete; Bytes; StopReason }.
    param(
        [Parameter(Mandatory = $true)]$Stream,
        [int]$MaxBytes = 16384,
        [int]$TimeoutMs = 5000,
        $Request = $null
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $memory = New-Object System.IO.MemoryStream
    try {
        $buffer = New-Object byte[] 4096
        $total = 0
        while ($true) {
            $remaining = $TimeoutMs - [int]$watch.ElapsedMilliseconds
            if ($remaining -le 0) {
                return @{ Complete = $false; Bytes = $null; StopReason = 'deadline' }
            }
            $task = $null
            try { $task = $Stream.ReadAsync($buffer, 0, $buffer.Length) } catch {
                return @{ Complete = $false; Bytes = $null; StopReason = 'read' }
            }
            if (-not $task.Wait($remaining)) {
                try { if ($null -ne $Request) { $Request.Abort() } } catch { }
                return @{ Complete = $false; Bytes = $null; StopReason = 'timeout' }
            }
            $read = 0
            try { $read = $task.Result } catch {
                return @{ Complete = $false; Bytes = $null; StopReason = 'read' }
            }
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt $MaxBytes) {
                return @{ Complete = $false; Bytes = $null; StopReason = 'cap' }
            }
            $memory.Write($buffer, 0, $read)
        }
        return @{ Complete = $true; Bytes = $memory.ToArray(); StopReason = '' }
    } finally {
        try { $memory.Dispose() } catch { }
    }
}

function Read-GsConsoleBoundedTextFile {
    # Reads a text file with a byte cap; returns $null when the file is
    # missing, unreadable or oversized. Never throws.
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaxBytes = 65536)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $info = Get-Item -LiteralPath $Path
        if ($info.Length -gt $MaxBytes) { return $null }
        return [IO.File]::ReadAllText($Path)
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# Console preferences (settings)
# ---------------------------------------------------------------------------

function Get-GsConsoleDefaultSettings {
    # Console-owned defaults, separate from the runtime's runtime-config.json.
    $stateDir = $script:StateDirDefault
    if ([string]::IsNullOrWhiteSpace($stateDir)) {
        $stateDir = Join-Path $env:ProgramData 'Local Development\GsController'
    }
    $installDir = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'Local Development\GsController'
    $logDir = Join-Path $env:ProgramData 'Local Development\GsControllerLogs'
    if ($script:Mode -eq 'demo') {
        $demoBase = ''
        if (-not [string]::IsNullOrWhiteSpace($script:ConfigFilePath)) { $demoBase = Split-Path -Parent $script:ConfigFilePath }
        if ([string]::IsNullOrWhiteSpace($demoBase)) { $demoBase = Join-Path ([IO.Path]::GetTempPath()) 'gs-console-demo-default' }
        $installDir = Join-Path $demoBase 'install'
        $logDir = Join-Path $demoBase 'logs'
        if ([string]::IsNullOrWhiteSpace($script:StateDirDefault)) { $stateDir = Join-Path $demoBase 'state' }
    } elseif (-not [string]::IsNullOrWhiteSpace($script:ProductPathResolved)) {
        $productDir = Split-Path -Parent $script:ProductPathResolved
        # Installed products carry sibling Modules. A source checkout must
        # never use its own product source directory as the deploy target.
        if (Test-Path -LiteralPath (Join-Path $productDir 'Modules') -PathType Container) { $installDir = $productDir }
    }
    return @{
        displayName         = 'This PC'
        installDir          = $installDir
        stateDir            = $stateDir
        logDir              = $logDir
        componentSourceDir  = ''
        helperSourceDir     = ''
        pollIntervalSec     = 2
    }
}

function Get-GsConsoleSettingsKeyOrder {
    return @('displayName', 'installDir', 'stateDir', 'logDir', 'componentSourceDir', 'helperSourceDir', 'pollIntervalSec')
}

function Read-GsConsolePrefs {
    # Loads { schemaVersion, revision, settings } from the console prefs
    # file. Any problem falls back to the defaults at revision 1. In live
    # mode, when no prefs exist yet, an existing runtime-config.json MAY be
    # READ once to initialize the known layout; it is never written here.
    $defaults = Get-GsConsoleDefaultSettings
    $prefs = @{ Revision = 1; Settings = $defaults }
    if (-not [string]::IsNullOrWhiteSpace($script:ConfigFilePath)) {
        $text = Read-GsConsoleBoundedTextFile -Path $script:ConfigFilePath -MaxBytes 65536
        if ($null -ne $text) {
            try {
                $doc = $text | ConvertFrom-Json
                $revOk = ($null -ne $doc -and $doc -is [pscustomobject] -and
                    $doc.PSObject.Properties['schemaVersion'] -and ([string]$doc.schemaVersion) -eq '1' -and
                    $doc.PSObject.Properties['revision'] -and $doc.revision -is [int])
                if ($revOk) {
                    $loaded = ConvertFrom-GsConsolePrefsSettings -Doc $doc
                    if ($null -ne $loaded) { $prefs = @{ Revision = [int]$doc.revision; Settings = $loaded } }
                }
            } catch { }
        }
    }
    if ($prefs.Revision -le 1 -and -not $Demo) {
        # First run in live mode: adopt the known layout from the runtime
        # config when one exists (READ only; saved prefs still never touch it).
        $adopted = Get-GsConsoleRuntimeConfigInit -Defaults $defaults
        if ($null -ne $adopted) { $prefs.Settings = $adopted }
    }
    return $prefs
}

function ConvertFrom-GsConsolePrefsSettings {
    # Rebuilds a normalized settings hashtable from a saved prefs document.
    # Returns $null when anything is off (the caller falls back to defaults).
    param([Parameter(Mandatory = $true)]$Doc)
    try {
        $settingsProp = $Doc.PSObject.Properties['settings']
        if ($null -eq $settingsProp -or $null -eq $settingsProp.Value -or $settingsProp.Value -isnot [pscustomobject]) { return $null }
        $obj = $settingsProp.Value
        foreach ($name in (Get-GsConsoleSettingsKeyOrder)) {
            if (-not $obj.PSObject.Properties[$name]) { return $null }
        }
        $interval = $obj.pollIntervalSec
        if (-not ($interval -is [int] -or $interval -is [long])) { return $null }
        if (([long]$interval) -lt 1 -or ([long]$interval) -gt 10) { return $null }
        $settings = @{}
        $settings.displayName = [string]$obj.displayName
        foreach ($name in @('installDir', 'stateDir', 'logDir', 'componentSourceDir', 'helperSourceDir')) {
            $value = $obj.$name
            if ($null -eq $value -or $value -isnot [string]) { return $null }
            $settings.$name = $value
        }
        $settings.pollIntervalSec = [int]$interval
        # Reload applies the FULL path policy again (absolute local drive,
        # no system/network roots, no overlap, no reparse on the existing
        # ancestor chain): a directory that was plain at save time must not
        # silently follow a link created afterwards. A since-deleted target
        # still passes (nothing to walk) and simply stays not-ready.
        $checked = Test-GsConsoleSettingsValues -Settings $settings
        if (-not $checked.Ok) { return $null }
        return $checked.Settings
    } catch { return $null }
}

function Get-GsConsoleRuntimeConfigInit {
    # Reads <stateDir>\runtime-config.json to initialize the known layout
    # (READ only; saved prefs still never touch it). Primary path is the
    # GsRuntime module's Read-GsRuntimeConfig; a TOLERANT fallback covers
    # configs whose componentSourceDir is empty (normal for existing
    # installs - an empty source dir is a redeployment input, never a
    # reason to refuse control of a deployed runtime). Only the three
    # target dirs are path-policy checked in the fallback; every failure
    # returns $null and the caller keeps the defaults.
    param([Parameter(Mandatory = $true)]$Defaults)
    if (-not [string]::IsNullOrWhiteSpace($Defaults.stateDir)) {
        $configPath = Join-Path $Defaults.stateDir 'runtime-config.json'
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            if ($script:GsRuntimeAvailable) {
                try {
                    $read = Read-GsRuntimeConfig -Path $configPath
                    if ($read.Success) {
                        $layout = $read.Layout
                        $adopted = @{}
                        foreach ($key in $Defaults.Keys) { $adopted.$key = $Defaults.$key }
                        $adopted.installDir = [string]$layout.InstallDir
                        $adopted.stateDir = [string]$layout.StateDir
                        $adopted.logDir = [string]$layout.LogDir
                        if (-not [string]::IsNullOrWhiteSpace([string]$layout.ComponentSourceDir)) {
                            $adopted.componentSourceDir = [string]$layout.ComponentSourceDir
                        }
                        return $adopted
                    }
                } catch { }
            }
            # Tolerant fallback (schemaVersion 1 + the four known keys).
            $text = Read-GsConsoleBoundedTextFile -Path $configPath -MaxBytes 65536
            if ($null -ne $text) {
                try {
                    $doc = $text | ConvertFrom-Json
                    if ($doc -is [pscustomobject] -and $doc.PSObject.Properties['schemaVersion'] -and ([string]$doc.schemaVersion) -eq '1') {
                        $values = @{}
                        $ok = $true
                        foreach ($name in @('installDir', 'stateDir', 'logDir', 'componentSourceDir')) {
                            $prop = $doc.PSObject.Properties[$name]
                            if ($null -eq $prop -or $prop.Value -isnot [string]) { $ok = $false; break }
                            $values.$name = [string]$prop.Value
                        }
                        if ($ok) {
                            $adopted = @{}
                            foreach ($key in $Defaults.Keys) { $adopted.$key = $Defaults.$key }
                            foreach ($name in @('installDir', 'stateDir', 'logDir')) {
                                $checked = Test-GsConsoleDirectoryPath -Value $values.$name
                                if (-not $checked.Ok) { return $null }
                                $adopted.$name = $checked.Path
                            }
                            $adopted.componentSourceDir = $values.componentSourceDir
                            return $adopted
                        }
                    }
                } catch { }
            }
        }
    }
    return $null
}

function Save-GsConsolePrefs {
    # Atomically writes the console prefs (temp file + rename next to the
    # target). Only the console prefs file is ever written.
    param(
        [Parameter(Mandatory = $true)][int]$Revision,
        [Parameter(Mandatory = $true)]$Settings
    )
    $parent = Split-Path -Parent $script:ConfigFilePath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $ordered = [ordered]@{ }
    foreach ($name in (Get-GsConsoleSettingsKeyOrder)) {
        if ($name -eq 'pollIntervalSec') { $ordered.$name = [int]$Settings.$name }
        else { $ordered.$name = [string]$Settings.$name }
    }
    $doc = [ordered]@{
        schemaVersion = 1
        revision      = $Revision
        settings      = $ordered
    }
    $tmp = $script:ConfigFilePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $script:ConfigFilePath -Force
}

function Get-GsConsoleComparablePath {
    # Mirrors the GsRuntime module's comparable-path helper (trim trailing
    # separators, case-insensitive) for local overlap checks.
    param([AllowEmptyString()][string]$Path)
    return $Path.TrimEnd('\', '/').ToLowerInvariant()
}

function Test-GsConsolePathInside {
    # Mirrors the GsRuntime module's containment helper: $true when
    # $Candidate equals $Parent or lives beneath it.
    param([AllowEmptyString()][string]$Candidate, [AllowEmptyString()][string]$Parent)
    $c = Get-GsConsoleComparablePath $Candidate
    $p = Get-GsConsoleComparablePath $Parent
    if ([string]::IsNullOrEmpty($p)) { return $false }
    if ($c -eq $p) { return $true }
    return $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-GsConsoleLongPath {
    # Expands 8.3 short-name segments of an EXISTING path to their long
    # form (GetLongPathName); returns $null when the path does not exist,
    # the API is unavailable, or the buffer is too small. '~' is never
    # rejected for its own sake: TEMP-style short names must still compare
    # equal to their long spellings.
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not ('GsConsole.Native.LongPath' -as [type])) {
            Add-Type -Namespace GsConsole.Native -Name LongPath -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint GetLongPathName(string lpszShortPath, System.Text.StringBuilder lpszLongPath, uint cchBuffer);
'@
        }
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $buffer = New-Object System.Text.StringBuilder 520
        $length = [GsConsole.Native.LongPath]::GetLongPathName($Path, $buffer, 520)
        if ($length -gt 0 -and $length -le 520) { return $buffer.ToString() }
    } catch { }
    return $null
}

function Test-GsConsoleDirectoryPath {
    # Console path policy for settings fields (deploy-time target checks are
    # separate). Returns { Ok; Path; Code } where Code is an error code or ''.
    # Local absolute filesystem directories only: drive-letter rooted, LOCAL
    # drive kind (network/mapped drives are refused conservatively), no
    # drive or system roots, nothing under the Windows directory, and no
    # reparse point anywhere on the existing ancestor chain (no traversal
    # through links/junctions - including after a save, because loading a
    # saved prefs file re-runs this full policy). Existing ancestors are
    # expanded to their long names before any comparison, so a short-name
    # (8.3) spelling can never smuggle a path past the overlap checks.
    param([AllowEmptyString()][string]$Value, [string]$Field)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{ Ok = $false; Path = ''; Code = 'EmptyPath' }
    }
    $trimmed = $Value.Trim()
    if ($trimmed.Length -gt 240) { return @{ Ok = $false; Path = ''; Code = 'TooLong' } }
    if ($trimmed -notmatch '^[A-Za-z]:\\') { return @{ Ok = $false; Path = ''; Code = 'NotAbsolutePath' } }
    if ($trimmed.IndexOf(':', 2) -ge 0) { return @{ Ok = $false; Path = ''; Code = 'InvalidPathSyntax' } }
    $resolved = $null
    try { $resolved = [IO.Path]::GetFullPath($trimmed) } catch {
        return @{ Ok = $false; Path = ''; Code = 'InvalidPathSyntax' }
    }
    if (-not ($resolved -match '^[A-Za-z]:\\')) { return @{ Ok = $false; Path = ''; Code = 'NotAbsolutePath' } }
    if ($resolved.Length -le 3) { return @{ Ok = $false; Path = ''; Code = 'DriveRoot' } }
    # Long-name expansion over the deepest EXISTING ancestor; the
    # nonexistent tail keeps its spelling (it is created only by an
    # explicit deployment later).
    $probe = $resolved.TrimEnd('\')
    while ($true) {
        $longProbe = Get-GsConsoleLongPath -Path $probe
        if ($null -ne $longProbe) {
            $resolved = $longProbe + $resolved.Substring($probe.Length)
            break
        }
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrEmpty($parent) -or ($parent -eq $probe) -or ($probe.Length -le 3)) { break }
        $probe = $parent
    }
    # Drive kind: the target must live on a LOCAL fixed (or RAM) drive.
    # Network/mapped, removable-unknown, missing or undeterminable drives
    # are refused conservatively - a mapped letter is not a local disk.
    try {
        $drive = New-Object System.IO.DriveInfo(([IO.Path]::GetPathRoot($resolved)))
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -and $drive.DriveType -ne [System.IO.DriveType]::Ram) {
            return @{ Ok = $false; Path = ''; Code = 'NotLocalDrive' }
        }
    } catch {
        return @{ Ok = $false; Path = ''; Code = 'NotLocalDrive' }
    }
    $windowsDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    if (-not [string]::IsNullOrEmpty($windowsDir)) {
        if ((Get-GsConsoleComparablePath $resolved) -eq (Get-GsConsoleComparablePath $windowsDir) -or
            (Test-GsConsolePathInside -Candidate $resolved -Parent $windowsDir)) {
            return @{ Ok = $false; Path = ''; Code = 'SystemPath' }
        }
    }
    # Walk every existing ancestor (including the final component) and
    # refuse any reparse point on the way.
    try {
        $probe = $resolved.TrimEnd('\')
        $root = ([IO.Path]::GetPathRoot($probe)).TrimEnd('\')
        while ($probe -and (Get-GsConsoleComparablePath $probe) -ne (Get-GsConsoleComparablePath $root)) {
            if (Test-Path -LiteralPath $probe) {
                $item = Get-Item -LiteralPath $probe -Force
                if (([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return @{ Ok = $false; Path = ''; Code = 'ReparsePath' }
                }
            }
            $parent = Split-Path -Parent $probe
            if ($parent -eq $probe) { break }
            $probe = $parent
        }
    } catch {
        return @{ Ok = $false; Path = ''; Code = 'InvalidPathSyntax' }
    }
    return @{ Ok = $true; Path = $resolved; Code = '' }
}

function Test-GsConsoleSettingsValues {
    # Validates and normalizes a settings hashtable. Exact key set, exact
    # types, bounded displayName and pollIntervalSec, and the FULL directory
    # policy for every path - on save AND on every reload of a saved prefs
    # file (so a path that later turns into a junction or a mapped drive is
    # rejected instead of followed). Returns { Ok; Settings; Errors } where
    # Errors carry { field, code } entries (field names are dot-joined
    # paths).
    param(
        [Parameter(Mandatory = $true)]$Settings
    )
    $errors = New-Object System.Collections.Generic.List[object]
    $normalized = @{}

    $displayName = $Settings.displayName
    if ($null -eq $displayName -or $displayName -isnot [string]) {
        $errors.Add(@{ field = 'settings.displayName'; code = 'InvalidType' })
        $displayName = ''
    }
    $displayName = $displayName.Trim()
    if ($displayName.Length -lt 1 -or $displayName.Length -gt 60) {
        $errors.Add(@{ field = 'settings.displayName'; code = 'InvalidValue' })
        if ($displayName.Length -gt 60) { $displayName = $displayName.Substring(0, 60) }
    }
    $normalized.displayName = $displayName

    $interval = $Settings.pollIntervalSec
    if ($null -eq $interval -or -not ($interval -is [int] -or $interval -is [long])) {
        $errors.Add(@{ field = 'settings.pollIntervalSec'; code = 'InvalidType' })
        $interval = 2
    }
    if (([long]$interval) -lt 1 -or ([long]$interval) -gt 10) {
        $errors.Add(@{ field = 'settings.pollIntervalSec'; code = 'InvalidValue' })
        $interval = 2
    }
    $normalized.pollIntervalSec = [int]$interval

    foreach ($name in @('installDir', 'stateDir', 'logDir', 'componentSourceDir', 'helperSourceDir')) {
        $value = $Settings.$name
        if ($null -eq $value -or $value -isnot [string]) {
            $errors.Add(@{ field = ('settings.' + $name); code = 'InvalidType' })
            $value = ''
        }
        $value = $value.Trim()
        if ($value -eq '') {
            if ($name -in @('installDir', 'stateDir', 'logDir')) {
                $errors.Add(@{ field = ('settings.' + $name); code = 'EmptyPath' })
            }
            $normalized.$name = ''
            continue
        }
        $checked = Test-GsConsoleDirectoryPath -Value $value -Field $name
        if (-not $checked.Ok) {
            $errors.Add(@{ field = ('settings.' + $name); code = $checked.Code })
            $normalized.$name = $value
        } else {
            $normalized.$name = $checked.Path
        }
    }

    if ($errors.Count -eq 0) {
        # The three targets must be pairwise disjoint (never equal, never
        # nested); source/helper dirs must not overlap any target. Sources
        # may overlap each other. Semantics mirror the GsRuntime layout
        # checks (SameDirectory / NestedDirectory).
        $targets = @(@('installDir', $normalized.installDir), @('stateDir', $normalized.stateDir), @('logDir', $normalized.logDir))
        for ($i = 0; $i -lt $targets.Count; $i++) {
            for ($j = $i + 1; $j -lt $targets.Count; $j++) {
                if ((Get-GsConsoleComparablePath $targets[$i][1]) -eq (Get-GsConsoleComparablePath $targets[$j][1])) {
                    $errors.Add(@{ field = ('settings.' + $targets[$i][0] + ',' + $targets[$j][0]); code = 'SameDirectory' })
                } elseif ((Test-GsConsolePathInside $targets[$i][1] $targets[$j][1]) -or
                    (Test-GsConsolePathInside $targets[$j][1] $targets[$i][1])) {
                    $errors.Add(@{ field = ('settings.' + $targets[$i][0] + ',' + $targets[$j][0]); code = 'NestedDirectory' })
                }
            }
        }
        if ($errors.Count -eq 0) {
            foreach ($sourceName in @('componentSourceDir', 'helperSourceDir')) {
                $source = $normalized.$sourceName
                if ($source -eq '') { continue }
                foreach ($target in $targets) {
                    if ((Get-GsConsoleComparablePath $source) -eq (Get-GsConsoleComparablePath $target[1]) -or
                        (Test-GsConsolePathInside $source $target[1]) -or
                        (Test-GsConsolePathInside $target[1] $source)) {
                        $errors.Add(@{ field = ('settings.' + $sourceName + ',' + $target[0]); code = 'OverlappingPath' })
                    }
                }
            }
        }
    }
    return @{ Ok = ($errors.Count -eq 0); Settings = $normalized; Errors = $errors.ToArray() }
}

# ---------------------------------------------------------------------------
# Envelope + response plumbing
# ---------------------------------------------------------------------------

function New-GsConsoleErrorPayload {
    param([Parameter(Mandatory = $true)][string]$Code, [string]$Message, [object[]]$Fields = @())
    $fieldList = @()
    foreach ($f in $Fields) { $fieldList += $f }
    return [ordered]@{
        ok    = $false
        error = [ordered]@{ code = $Code; message = $Message; fields = $fieldList }
    }
}

function Write-GsConsoleJson {
    param($Context, [int]$StatusCode, $Payload)
    $json = $Payload | ConvertTo-Json -Depth 8
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $response = $Context.Response
    try {
        $response.StatusCode = $StatusCode
        $response.ContentType = 'application/json; charset=utf-8'
        $response.Headers['Cache-Control'] = 'no-store'
        $response.Headers['X-Content-Type-Options'] = 'nosniff'
        $response.Headers['Referrer-Policy'] = 'no-referrer'
        $response.ContentLength64 = $bytes.Length
        $stream = $response.OutputStream
        if ([string]$Context.Request.HttpMethod -ne 'HEAD') {
            $stream.Write($bytes, 0, $bytes.Length)
        }
        $stream.Close()
    } catch [System.Net.HttpListenerException] { } catch [System.ObjectDisposedException] { }
}

function Write-GsConsoleStatic {
    # Serves one of the fixed static names (legacy: three entries;
    # Sunshine: the four gs-sunshine entries). No path-to-file
    # translation exists anywhere, so traversal is impossible by
    # construction. Missing/oversized files fail closed with 404.
    param($Context, [string]$Kind)
    $response = $Context.Response
    $fileName = switch ($Kind) {
        'html' { 'gs-console.html' }
        'css' { 'gs-console.css' }
        'js' { 'gs-console.js' }
        'sunshine-html' { 'gs-sunshine.html' }
        'sunshine-css' { 'gs-sunshine.css' }
        'sunshine-js' { 'gs-sunshine.js' }
        default { $null }
    }
    $contentType = switch ($Kind) {
        'html' { 'text/html; charset=utf-8' }
        'css' { 'text/css; charset=utf-8' }
        'js' { 'text/javascript; charset=utf-8' }
        'sunshine-html' { 'text/html; charset=utf-8' }
        'sunshine-css' { 'text/css; charset=utf-8' }
        'sunshine-js' { 'text/javascript; charset=utf-8' }
        default { 'application/octet-stream' }
    }
    if ($null -eq $fileName) { Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown path.'); return }
    $bytes = $null
    try {
        $path = Join-Path $script:StaticDirResolved $fileName
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $info = Get-Item -LiteralPath $path
            if ($info.Length -le $script:StaticFileMaxBytes) {
                $bytes = [IO.File]::ReadAllBytes($path)
                if ($Kind -eq 'html' -or $Kind -eq 'sunshine-html') {
                    $text = [Text.Encoding]::UTF8.GetString($bytes)
                    $text = $text.Replace('__GS_MODE__', $script:Mode)
                    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
                }
            }
        }
    } catch { $bytes = $null }
    if ($null -eq $bytes) {
        Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Console asset is not installed in this tree.')
        return
    }
    try {
        $response.StatusCode = 200
        $response.ContentType = $contentType
        $response.Headers['Cache-Control'] = 'no-store'
        $response.Headers['X-Content-Type-Options'] = 'nosniff'
        $response.Headers['Referrer-Policy'] = 'no-referrer'
        $response.Headers['Content-Security-Policy'] = "default-src 'self'; frame-ancestors 'none'"
        $response.ContentLength64 = $bytes.Length
        $stream = $response.OutputStream
        if ([string]$Context.Request.HttpMethod -ne 'HEAD') {
            $stream.Write($bytes, 0, $bytes.Length)
        }
        $stream.Close()
    } catch [System.Net.HttpListenerException] { } catch [System.ObjectDisposedException] { }
}

# ---------------------------------------------------------------------------
# Request prechecks: remote peer, Host, session token, Origin, body
# ---------------------------------------------------------------------------

function Test-GsConsoleHostAllowed {
    # Exactly two loopback aliases are allowed (same-machine names only,
    # never a wildcard or LAN form): 127.0.0.1:<port> and localhost:<port>.
    param($Request, [Parameter(Mandatory = $true)][int]$Port)
    $hostHeader = ''
    try { $hostHeader = [string]$Request.Headers['Host'] } catch { }
    if ([string]::Equals($hostHeader, ('127.0.0.1:' + $Port), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ([string]::Equals($hostHeader, ('localhost:' + $Port), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Test-GsConsoleOriginAllowed {
    # GET APIs may omit Origin; mutating (POST) requests require an exact
    # same-loopback Origin: http://127.0.0.1:<port> or http://localhost:<port>.
    param(
        $Request,
        [Parameter(Mandatory = $true)][int]$Port,
        [switch]$RequireOrigin
    )
    $origin = ''
    try { $origin = [string]$Request.Headers['Origin'] } catch { }
    if ($origin -eq '') { return (-not [bool]$RequireOrigin) }
    if ([string]::Equals($origin, ('http://127.0.0.1:' + $Port), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ([string]::Equals($origin, ('http://localhost:' + $Port), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Read-GsConsoleJsonObject {
    # Reads and parses a bounded JSON object body. Returns
    # { Ok; Object; HttpStatus; Code; Message; Fields }.
    param($Request)
    $length = -1
    try { $length = [int]$Request.ContentLength64 } catch { $length = -1 }
    if ($length -lt 0) {
        return @{ Ok = $false; HttpStatus = 400; Code = 'LengthRequired'; Message = 'A Content-Length is required.'; Fields = @() }
    }
    if ($length -gt $script:BodyMaxBytes) {
        return @{ Ok = $false; HttpStatus = 413; Code = 'BodyTooLarge'; Message = 'The request body exceeds 16384 bytes.'; Fields = @() }
    }
    $bounded = Read-GsConsoleBoundedStream -Stream $Request.InputStream -MaxBytes $script:BodyMaxBytes `
        -TimeoutMs $script:RequestReadTimeoutMs -Request $Request
    if (-not $bounded.Complete) {
        $code = 'BodyReadFailed'
        if ($bounded.StopReason -eq 'cap') { $code = 'BodyTooLarge' }
        $message = 'The request body could not be read in full.'
        if ($code -eq 'BodyTooLarge') { $message = 'The request body exceeds 16384 bytes.' }
        return @{ Ok = $false; HttpStatus = 413; Code = $code; Message = $message; Fields = @() }
    }
    if ($bounded.Bytes.Length -eq 0) {
        return @{ Ok = $false; HttpStatus = 400; Code = 'EmptyBody'; Message = 'A JSON object body is required.'; Fields = @() }
    }
    $text = [Text.Encoding]::UTF8.GetString($bounded.Bytes)
    $obj = $null
    try { $obj = $text | ConvertFrom-Json } catch {
        return @{ Ok = $false; HttpStatus = 400; Code = 'InvalidJson'; Message = 'The request body is not valid JSON.'; Fields = @() }
    }
    if ($null -eq $obj -or $obj -isnot [pscustomobject]) {
        return @{ Ok = $false; HttpStatus = 400; Code = 'InvalidType'; Message = 'The JSON root must be an object.'; Fields = @() }
    }
    return @{ Ok = $true; Object = $obj; HttpStatus = 0; Code = ''; Message = ''; Fields = @() }
}

function Get-GsConsoleStringProperty {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    if ($prop.Value -isnot [string]) { return $null }
    return $prop.Value
}

# ---------------------------------------------------------------------------
# Job management (single in-flight job; child-process helper in live mode)
# ---------------------------------------------------------------------------

function Test-GsConsoleJobActive {
    return ($null -ne $script:CurrentJob -and $script:CurrentJob.Status -eq 'running')
}

function New-GsConsoleJobId {
    return ([guid]::NewGuid().ToString('N'))
}

function Start-GsConsoleJobRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][int]$BudgetSec
    )
    $id = New-GsConsoleJobId
    $now = (Get-Date).ToUniversalTime()
    $job = @{
        Id          = $id
        Action      = $Action
        Status      = 'running'
        StartedAtUtc = $now
        FinishedAtUtc = $null
        Success     = $null
        Code        = ''
        Result      = $null
        BudgetSec   = $BudgetSec
        Process     = $null
        RequestPath = ''
        ResultPath  = ''
        Demo        = ($script:Mode -eq 'demo')
        DemoFinishAfterSec = 0
        DemoOutcome = $null
    }
    if (-not $job.Demo) {
        $jobDir = Join-Path $script:JobsRoot $id
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
        $job.RequestPath = Join-Path $jobDir 'request.json'
        $job.ResultPath = Join-Path $jobDir 'result.json'
    }
    $script:CurrentJob = $job
    return $job
}

function Get-GsConsolePendingDoneDecision {
    # Pure deadline decision, reusing the tray's semantics: a usable result
    # file (or a known process exit) wins FIRST; only a result-less job
    # strictly past its budget reports TimedOut. Nothing is ever killed.
    param($ResultParsed, $HasExited, $ProcessAlive, [double]$ElapsedSec, [int]$TimeoutSec)
    return (Test-GsTrayPendingDone -ResultParsed $ResultParsed -HasExited $HasExited `
        -ProcessAlive $ProcessAlive -ElapsedSec $ElapsedSec -TimeoutSec $TimeoutSec)
}

function Read-GsConsoleActionResultFile {
    # Parses the helper's result file. Strict JSON boolean Success is
    # required (a string 'true' is NOT a usable outcome). Returns a shape
    # compatible with the tray's pending decision: { Success; Code; Reason;
    # Data; Usable } where Usable=$false means NoResult (keep waiting).
    param([AllowEmptyString()][string]$Path)
    $noResult = [pscustomobject]@{ Success = $false; Code = 'NoResult'; Reason = ''; Data = $null; Usable = $false }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $noResult }
    $text = Read-GsConsoleBoundedTextFile -Path $Path -MaxBytes 1048576
    if ($null -eq $text) { return $noResult }
    if ([string]::IsNullOrWhiteSpace($text)) { return $noResult }
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json } catch { return $noResult }
    if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) { return $noResult }
    if (-not $parsed.PSObject.Properties['success']) { return $noResult }
    if (-not ($parsed.success -is [bool])) { return $noResult }
    $code = ''
    $reason = ''
    if ($parsed.PSObject.Properties['code'] -and $parsed.code -is [string]) { $code = [string]$parsed.code }
    if ($parsed.PSObject.Properties['reason'] -and $parsed.reason -is [string]) { $reason = [string]$parsed.reason }
    $data = $null
    if ($parsed.PSObject.Properties['data']) { $data = $parsed.data }
    return [pscustomobject]@{ Success = [bool]$parsed.success; Code = $code; Reason = $reason; Data = $data; Usable = $true }
}

function Get-GsConsoleDiagnoseSummary {
    # Projects the REAL gs-diagnose report (Data of the CLI result) into the
    # contract's sanitized shape: { generatedAt, checks: [{id,label,status,
    # code,message}], summary: {passed,warnings,failed} }. Real input shape:
    # errors[] = {section, code, message} per report section, and findings
    # live under hygiene.findings[] = {code, severity, message, path}.
    # IDs are the stable categories; raw codes travel in the code field;
    # severity maps to passed/warning/failed/unknown (a 'high' severity is
    # never copied verbatim as a status); report messages and paths are
    # NEVER forwarded (truncation is not sanitization). A section error
    # means the area could not be inspected -> status 'unknown'.
    param($ReportData)
    $checks = @()
    $passed = 0; $warnings = 0; $failed = 0
    $sections = $null
    $findings = $null
    if ($null -ne $ReportData -and $ReportData -is [pscustomobject]) {
        if ($ReportData.PSObject.Properties['errors'] -and $null -ne $ReportData.errors) { $sections = @($ReportData.errors) }
        if ($ReportData.PSObject.Properties['hygiene'] -and $null -ne $ReportData.hygiene -and
            $ReportData.hygiene -is [pscustomobject] -and $ReportData.hygiene.PSObject.Properties['findings'] -and
            $null -ne $ReportData.hygiene.findings) {
            $findings = @($ReportData.hygiene.findings)
        }
    }
    $byCategory = @{}
    if ($null -ne $sections) {
        foreach ($sectionError in $sections) {
            if ($null -eq $sectionError -or $sectionError -isnot [pscustomobject]) { continue }
            $code = ''
            $section = ''
            if ($sectionError.PSObject.Properties['code'] -and $sectionError.code -is [string]) { $code = [string]$sectionError.code }
            if ($sectionError.PSObject.Properties['section'] -and $sectionError.section -is [string]) { $section = [string]$sectionError.section }
            if ($code.Length -gt 64) { $code = $code.Substring(0, 64) }
            $category = Get-GsConsoleCheckCategory -Raw $section
            if (-not $byCategory.ContainsKey($category)) {
                $byCategory[$category] = @{ status = 'unknown'; code = $code }
            } else {
                $byCategory[$category].status = Merge-GsConsoleCheckStatus -Current $byCategory[$category].status -Next 'unknown'
                if ([string]::IsNullOrEmpty($byCategory[$category].code)) { $byCategory[$category].code = $code }
            }
        }
    }
    if ($null -ne $findings) {
        foreach ($finding in $findings) {
            if ($null -eq $finding -or $finding -isnot [pscustomobject]) { continue }
            $code = ''
            $severity = ''
            if ($finding.PSObject.Properties['code'] -and $finding.code -is [string]) { $code = [string]$finding.code }
            if ($code.Length -gt 64) { $code = $code.Substring(0, 64) }
            if ($finding.PSObject.Properties['severity'] -and $finding.severity -is [string]) { $severity = ([string]$finding.severity).ToLowerInvariant() }
            $status = 'unknown'
            if ($severity -in @('high', 'error', 'failed')) { $status = 'failed' }
            elseif ($severity -eq 'warning') { $status = 'warning' }
            elseif ($severity -in @('info', 'ok', 'passed')) { $status = 'passed' }
            $category = 'runtime'
            if ($code -in @('SupervisorTaskMissing', 'OrphanedSupervisorTask', 'SupervisorTaskStateUnexpected')) { $category = 'autostart' }
            elseif ($code -in @('ScriptDirWritableByNonAdmin', 'AclUnavailable', 'AclNotProtected')) { $category = 'permissions' }
            elseif ($code -in @('SupervisorPaused', 'StatusFileAmbiguous')) { $category = 'status' }
            if (-not $byCategory.ContainsKey($category)) {
                $byCategory[$category] = @{ status = $status; code = $code }
            } else {
                $byCategory[$category].status = Merge-GsConsoleCheckStatus -Current $byCategory[$category].status -Next $status
                if ([string]::IsNullOrEmpty($byCategory[$category].code)) { $byCategory[$category].code = $code }
            }
        }
    }
    if ($byCategory.Count -eq 0) {
        if ($null -eq $ReportData) {
            $checks += [ordered]@{ id = 'runtime'; label = (Get-GsConsoleStatusLabel 'runtime'); status = 'failed'; code = 'NoReport'; message = 'No structured diagnose report was available.' }
            $failed = 1
        } else {
            # A clean report with no section errors and no findings.
            $checks += [ordered]@{ id = 'runtime'; label = (Get-GsConsoleStatusLabel 'runtime'); status = 'passed'; code = ''; message = '' }
            $passed = 1
        }
    } else {
        $count = 0
        foreach ($category in $byCategory.Keys) {
            $status = [string]$byCategory[$category].status
            if ($status -eq 'failed') { $failed++ }
            elseif ($status -eq 'warning') { $warnings++ }
            elseif ($status -eq 'passed') { $passed++ }
            if ($count -lt 50) {
                $checks += [ordered]@{ id = $category; label = (Get-GsConsoleStatusLabel $category); status = $status; code = $byCategory[$category].code; message = '' }
                $count++
            }
        }
    }
    return [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        checks      = $checks
        summary     = [ordered]@{ passed = $passed; warnings = $warnings; failed = $failed }
    }
}

function Get-GsConsoleCheckCategory {
    # Stable check-item categories shared by the Web DTO. Raw error codes
    # travel in the code field, never as the id.
    param([AllowEmptyString()][string]$Raw)
    $key = ([string]$Raw).ToLowerInvariant()
    if ($key -in @('installdir', 'statedir', 'logdir', 'componentsourcedir', 'helpersourcedir', 'path', 'catalogpath', 'paths')) { return 'paths' }
    if ($key -in @('component', 'components', 'helper', 'catalog', 'bundle')) { return 'components' }
    if ($key -in @('permission', 'permissions', 'acl')) { return 'permissions' }
    if ($key -in @('deployment', 'install', 'runtimeconfig')) { return 'deployment' }
    if ($key -in @('status')) { return 'status' }
    if ($key -in @('serverinfo')) { return 'serverinfo' }
    if ($key -in @('autostart', 'task', 'supervisortask')) { return 'autostart' }
    return 'runtime'
}

function Get-GsConsoleStatusLabel {
    # Fixed English category labels (the frontend renders Chinese hints; the
    # API keeps short stable English labels).
    param([Parameter(Mandatory = $true)][string]$Category)
    switch ($Category) {
        'runtime' { return 'Runtime' }
        'components' { return 'Components' }
        'deployment' { return 'Deployment' }
        'permissions' { return 'Permissions' }
        'status' { return 'Status' }
        'serverinfo' { return 'Server info' }
        'paths' { return 'Paths' }
        'autostart' { return 'Autostart' }
        default { return 'Runtime' }
    }
}

function Merge-GsConsoleCheckStatus {
    # Worst-status fold: failed > warning > unknown > passed.
    param([AllowEmptyString()][string]$Current, [Parameter(Mandatory = $true)][string]$Next)
    $rank = @{ failed = 3; warning = 2; unknown = 1; passed = 0 }
    $currentRank = 0
    if ($rank.ContainsKey([string]$Current)) { $currentRank = [int]$rank[[string]$Current] }
    $nextRank = 0
    if ($rank.ContainsKey($Next)) { $nextRank = [int]$rank[$Next] }
    if ($nextRank -ge $currentRank) { return $Next }
    return $Current
}

function Get-GsConsoleCheckSummary {
    # Projects a CLI Check result into { ready, checks: [{id,label,status,
    # code,message}] }. The helper reduced CLI errors to structured {code,
    # field} entries; ids are stable categories (paths/runtime/components/
    # ...) aggregated by worst status, the raw error code travels in code,
    # and message stays empty - no exception text ever flows here.
    param([Parameter(Mandatory = $true)][bool]$Ready, $Data)
    $checks = @()
    if ($Ready) {
        $checks += [ordered]@{ id = 'runtime'; label = (Get-GsConsoleStatusLabel 'runtime'); status = 'passed'; code = ''; message = '' }
        return [ordered]@{ ready = $true; checks = $checks }
    }
    $entries = @()
    if ($null -ne $Data -and $Data -is [pscustomobject] -and $Data.PSObject.Properties['errors'] -and $null -ne $Data.errors) {
        $entries = @($Data.errors)
    }
    if ($entries.Count -eq 0) {
        $checks += [ordered]@{ id = 'runtime'; label = (Get-GsConsoleStatusLabel 'runtime'); status = 'failed'; code = 'CheckFailed'; message = '' }
        return [ordered]@{ ready = $false; checks = $checks }
    }
    $byCategory = @{}
    foreach ($entry in $entries) {
        if ($null -eq $entry -or $entry -isnot [pscustomobject]) { continue }
        $code = ''
        $field = ''
        if ($entry.PSObject.Properties['code'] -and $entry.code -is [string]) { $code = [string]$entry.code }
        if ($entry.PSObject.Properties['field'] -and $entry.field -is [string]) { $field = [string]$entry.field }
        if ($code.Length -gt 64) { $code = $code.Substring(0, 64) }
        $category = Get-GsConsoleCheckCategory -Raw $field
        if (-not $byCategory.ContainsKey($category)) {
            $byCategory[$category] = @{ status = 'failed'; code = $code }
        } else {
            $byCategory[$category].status = Merge-GsConsoleCheckStatus -Current $byCategory[$category].status -Next 'failed'
            if ([string]::IsNullOrEmpty($byCategory[$category].code)) { $byCategory[$category].code = $code }
        }
    }
    foreach ($category in $byCategory.Keys) {
        $checks += [ordered]@{ id = $category; label = (Get-GsConsoleStatusLabel $category); status = $byCategory[$category].status; code = $byCategory[$category].code; message = '' }
    }
    return [ordered]@{ ready = $false; checks = $checks }
}

function ConvertTo-GsConsoleActionResult {
    # The only place job results are projected for the Web. Per-action
    # allowlists (coordinator clarification): browse {selectedPath},
    # check {ready,checks}, diagnose {generatedAt,checks,summary},
    # deploy {configured}; lifecycle/autostart use {}. success/code stay
    # top-level on the job DTO; no raw CLI payload ever passes through.
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][bool]$Success,
        [AllowEmptyString()][string]$Code,
        $Data
    )
    switch ($Action) {
        'browse' {
            $selected = $null
            if ($Success -and $null -ne $Data -and $Data -is [pscustomobject] -and $Data.PSObject.Properties['selectedPath']) {
                if ($Data.selectedPath -is [string]) {
                    $selected = [string]$Data.selectedPath
                    if ($selected.Length -gt 240) { $selected = $null }
                }
            }
            return [ordered]@{ selectedPath = $selected }
        }
        'check' {
            return (Get-GsConsoleCheckSummary -Ready $Success -Data $Data)
        }
        'diagnose' {
            return (Get-GsConsoleDiagnoseSummary -ReportData $Data)
        }
        'deploy' {
            return [ordered]@{ configured = $Success }
        }
        default {
            return [ordered]@{ }
        }
    }
}

function Complete-GsConsoleJob {
    param($Job, [bool]$Success, [string]$Code, [string]$Reason, $Data)
    $Job.Status = $(if ($Success) { 'succeeded' } else { 'failed' })
    $Job.Success = [bool]$Success
    $Job.Code = $Code
    if ([string]::IsNullOrEmpty($Job.Code)) { $Job.Code = $(if ($Success) { 'Ok' } else { 'Failed' }) }
    $Job.Reason = $Reason
    $Job.FinishedAtUtc = (Get-Date).ToUniversalTime()
    $Job.Result = ConvertTo-GsConsoleActionResult -Action $Job.Action -Success $Success -Code $Job.Code -Data $Data
    $script:LastCompleted = $Job
    $script:JobHistory.Add($Job)
    while ($script:JobHistory.Count -gt $script:JobHistoryLimit) { $script:JobHistory.RemoveAt(0) }
    if ($script:CurrentJob -eq $Job) { $script:CurrentJob = $null }
    # Live-only side effects on completion: an autostart job result is the
    # only honest autostart hint (no task query is ever performed).
    if (-not $Job.Demo -and $Job.Action -eq 'autostart-enable' -and $Success) { $script:LiveAutostartHint = 'enabled' }
    if (-not $Job.Demo -and $Job.Action -eq 'autostart-disable' -and $Success) { $script:LiveAutostartHint = 'disabled' }
    if ($Job.Demo -and $Job.Action -eq 'autostart-enable' -and $Success) { $script:DemoAutostart = 'enabled' }
    if ($Job.Demo -and $Job.Action -eq 'autostart-disable' -and $Success) { $script:DemoAutostart = 'disabled' }
    if ($Job.Demo -and $Success) {
        # Demo transitions: the simulated job moves the fixture scenario.
        switch ($Job.Action) {
            'start' { $script:DemoScenario = 'ready' }
            'stop' { $script:DemoScenario = 'stopped' }
            'recover' { $script:DemoScenario = 'ready' }
            'deploy' { $script:DemoScenario = 'stopped' }
            default { }
        }
    }
}

function Update-GsConsoleJobPoll {
    # Lazy completion check, invoked before state/jobs reads and on each
    # server loop tick. Completion beats the deadline; nothing is killed.
    if (-not (Test-GsConsoleJobActive)) { return }
    $job = $script:CurrentJob
    $now = (Get-Date).ToUniversalTime()
    $elapsed = ($now - $job.StartedAtUtc).TotalSeconds
    if ($job.Demo) {
        if ($elapsed -ge $job.DemoFinishAfterSec) {
            $outcome = $job.DemoOutcome
            Complete-GsConsoleJob -Job $job -Success $outcome.Success -Code $outcome.Code -Reason '' -Data $outcome.Data
        }
        return
    }
    $parsed = Read-GsConsoleActionResultFile -Path $job.ResultPath
    $hasExited = $null
    $processAlive = $null
    if ($null -ne $job.Process) {
        try { $hasExited = [bool]$job.Process.HasExited } catch { $hasExited = $null }
        if ($hasExited -ne $true) {
            try {
                $still = Get-Process -Id $job.Process.Id -ErrorAction SilentlyContinue
                $processAlive = ($null -ne $still)
            } catch { $processAlive = $null }
        }
    }
    $decision = Get-GsConsolePendingDoneDecision -ResultParsed ([pscustomobject]@{ Code = $(if ($parsed.Usable) { 'Done' } else { 'NoResult' }) }) `
        -HasExited $hasExited -ProcessAlive $processAlive -ElapsedSec $elapsed -TimeoutSec $job.BudgetSec
    if ($decision -eq 'Done') {
        if ($parsed.Usable) {
            Complete-GsConsoleJob -Job $job -Success $parsed.Success -Code $parsed.Code -Reason $parsed.Reason -Data $parsed.Data
        } elseif ($hasExited -eq $true -or $processAlive -eq $false) {
            # Process exited without a usable result file: truthful failure.
            Complete-GsConsoleJob -Job $job -Success $false -Code 'NoResult' -Reason '' -Data $null
        }
        return
    }
    if ($decision -eq 'TimedOut') {
        # Past the budget with no result: end OUR OWN wrapper process (the
        # helper, which hosts the inline CLI call) and CONFIRM its exit
        # before reporting. Process.Kill() terminates exactly this process
        # - never a tree, never the runtime children it started. While the
        # wrapper exit is not confirmed, the job stays in flight (Busy);
        # the truthful Timeout failure is only recorded once nothing of
        # ours is still running. If even the kill is refused, the next
        # poll retries and the eventual natural exit completes the job.
        $confirmedExit = $false
        try {
            if ($null -ne $job.Process) {
                $job.Process.Kill()
                if ($job.Process.WaitForExit(10000)) { $confirmedExit = $true }
            }
        } catch { $confirmedExit = $false }
        if ($confirmedExit) {
            Complete-GsConsoleJob -Job $job -Success $false -Code 'Timeout' -Reason '' -Data $null
        }
    }
}

function Get-GsConsoleJobDto {
    param($Job)
    $result = $Job.Result
    if ($null -eq $result) { $result = [ordered]@{ } }
    return [ordered]@{
        id         = [string]$Job.Id
        action     = [string]$Job.Action
        status     = [string]$Job.Status
        startedAt  = $Job.StartedAtUtc.ToString('o')
        finishedAt = $(if ($null -ne $Job.FinishedAtUtc) { $Job.FinishedAtUtc.ToString('o') } else { $null })
        success    = $Job.Success
        code       = [string]$Job.Code
        result     = $result
    }
}

function Find-GsConsoleJobById {
    param([Parameter(Mandatory = $true)][string]$Id)
    if ($null -ne $script:CurrentJob -and $script:CurrentJob.Id -eq $Id) { return $script:CurrentJob }
    foreach ($job in $script:JobHistory) { if ($job.Id -eq $Id) { return $job } }
    if ($null -ne $script:LastCompleted -and $script:LastCompleted.Id -eq $Id) { return $script:LastCompleted }
    return $null
}

# ---------------------------------------------------------------------------
# Live action launch (fixed -File helper, server-generated request JSON)
# ---------------------------------------------------------------------------

function New-GsConsoleActionRequest {
    # Builds the server-generated request JSON document for the helper.
    # Every path here comes from validated console settings or trusted
    # startup parameters - never from an HTTP request.
    param([Parameter(Mandatory = $true)][string]$Action)
    $settings = $script:Prefs.Settings
    $catalogPath = ''
    if ($Action -eq 'deploy') {
        $catalogPath = Join-Path $settings.stateDir 'component-catalog.json'
    }
    $diagnoseScript = Join-Path (Split-Path -Parent $script:ProductPathResolved) 'gs-diagnose.ps1'
    if (-not (Test-Path -LiteralPath $diagnoseScript -PathType Leaf)) { $diagnoseScript = '' }
    return [ordered]@{
        schemaVersion      = 1
        action             = $Action
        productPath        = [string]$script:ProductPathResolved
        moduleRoot         = [string]$script:ModuleRootResolved
        installDir         = [string]$settings.installDir
        stateDir           = [string]$settings.stateDir
        logDir             = [string]$settings.logDir
        componentSourceDir = [string]$settings.componentSourceDir
        helperSourceDir    = [string]$settings.helperSourceDir
        catalogPath        = [string]$catalogPath
        diagnoseScript     = [string]$diagnoseScript
        serverInfoUri      = [string]$script:ServerInfoUriResolved
    }
}

function Test-GsConsoleDeployTargets {
    # Deploy-time target policy: fresh (nonexistent) targets are fine; an
    # EXISTING target must look product-owned or empty, never an unrelated
    # directory with arbitrary content. Read-only probing only.
    $settings = $script:Prefs.Settings
    $errors = New-Object System.Collections.Generic.List[object]
    $install = $settings.installDir
    if ($install -ne '') {
        if (Test-Path -LiteralPath $install) {
            if (-not (Test-Path -LiteralPath (Join-Path $install 'gs-product.ps1') -PathType Leaf)) {
                $errors.Add(@{ field = 'settings.installDir'; code = 'TargetNotAllowed' })
            }
        }
    }
    $state = $settings.stateDir
    if ($state -ne '') {
        if (Test-Path -LiteralPath $state) {
            $recognized = $false
            foreach ($marker in @('runtime-config.json', 'runtime', 'component-catalog.json')) {
                if (Test-Path -LiteralPath (Join-Path $state $marker)) { $recognized = $true; break }
            }
            if (-not $recognized) {
                try {
                    $children = @(Get-ChildItem -LiteralPath $state -Force -ErrorAction SilentlyContinue)
                    if ($children.Count -eq 0) { $recognized = $true }
                } catch { }
            }
            if (-not $recognized) { $errors.Add(@{ field = 'settings.stateDir'; code = 'TargetNotAllowed' }) }
        }
    }
    $log = $settings.logDir
    if ($log -ne '') {
        if (Test-Path -LiteralPath $log) {
            try {
                $children = @(Get-ChildItem -LiteralPath $log -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.log(\.\d+)?$' })
                if ($children.Count -ne 0) { $errors.Add(@{ field = 'settings.logDir'; code = 'TargetNotAllowed' }) }
            } catch {
                $errors.Add(@{ field = 'settings.logDir'; code = 'TargetNotAllowed' })
            }
        }
    }
    # Preserve the list across the pipeline boundary: a bare empty array
    # would unroll to $null and callers do .Count on it.
    return , $errors.ToArray()
}

function Start-GsConsoleLiveAction {
    # Spawns the fixed -File helper with server-generated request/result
    # paths and returns the created job. The helper never receives
    # browser-controlled input of any kind. A failure AFTER the job is
    # registered (the request write or the process start) completes the
    # registered job as a truthful 'LaunchFailed' failure and returns $null:
    # the console must never stay Busy on a running job that owns no
    # process. (The poll's timeout path is untouched: a job that DID get a
    # process keeps waiting for a confirmed exit, and a null-Process timeout
    # is never reported as exited.)
    param([Parameter(Mandatory = $true)][string]$Action)
    $request = New-GsConsoleActionRequest -Action $Action
    $job = Start-GsConsoleJobRecord -Action $Action -BudgetSec $script:JobBudgetSec[$Action]
    try {
        $requestJson = $request | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($job.RequestPath, $requestJson, (New-Object Text.UTF8Encoding($false)))
        $isBrowse = ($Action -eq 'browse')
        $helperPath = Join-Path $script:ConsoleScriptRoot 'gs-console-action.ps1'
        # Explicit system powershell.exe path and -STA; PATH is never trusted.
        $childArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA'
        $childArgs += ' -File "' + $helperPath + '"'
        if ($isBrowse) { $childArgs += ' -PickFolder' }
        $childArgs += ' -RequestFile "' + $job.RequestPath + '" -ResultFile "' + $job.ResultPath + '"'
        $job.Process = Start-Process -FilePath (Resolve-GsConsoleSystemPowerShell) -ArgumentList $childArgs -WindowStyle Hidden -PassThru
    } catch {
        Complete-GsConsoleJob -Job $job -Success $false -Code 'LaunchFailed' -Reason '' -Data $null
        return $null
    }
    return $job
}

function Start-GsConsoleDemoAction {
    # Demo jobs simulate short transitions with no real APIs, processes or
    # tasks. The demo handler is structurally separate from the live one:
    # no process is spawned and no CLI path is consulted, ever.
    param([Parameter(Mandatory = $true)][string]$Action)
    $job = Start-GsConsoleJobRecord -Action $Action -BudgetSec $script:JobBudgetSec[$Action]
    # 0.8 s simulated transition: long enough that a client observing
    # 'running' can also observe Busy isolation, short enough for previews.
    $job.DemoFinishAfterSec = 0.8
    $outcome = @{ Success = $true; Code = 'Ok'; Data = $null }
    switch ($Action) {
        'check' {
            $outcome.Data = [pscustomobject]@{ findings = @() }
            $outcome.Code = 'Ok'
        }
        'diagnose' {
            # Demo emits a REAL-shaped empty report (section errors list +
            # hygiene findings list): a clean run with nothing to report.
            $outcome.Data = [pscustomobject]@{
                schemaVersion = 1
                errors        = @()
                hygiene       = [pscustomobject]@{ findings = @() }
            }
        }
        'browse' {
            # Documented fake demo path; no dialog is ever opened in demo.
            $outcome.Data = [pscustomobject]@{ selectedPath = 'C:\GsConsoleDemo\components' }
        }
        'deploy' { $outcome.Data = $null }
        default { }
    }
    $job.DemoOutcome = $outcome
    return $job
}

# ---------------------------------------------------------------------------
# State DTO
# ---------------------------------------------------------------------------

function Get-GsConsoleLocalAddresses {
    # Read-only local private IPv4 metadata (interface addresses only; no
    # MACs, no device identifiers). Capped at 8 entries. The provider seam
    # is for in-process fixtures; the HTTP API cannot supply it.
    param([AllowNull()][scriptblock]$InterfaceProvider = $null)
    $result = @()
    try {
        $interfaces = if ($null -ne $InterfaceProvider) { & $InterfaceProvider } else {
            [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        }
        foreach ($nic in $interfaces) {
            if ($result.Count -ge 8) { break }
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            foreach ($addr in $nic.GetIPProperties().UnicastAddresses) {
                if ($result.Count -ge 8) { break }
                if ($addr.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $bytes = Get-GsConsoleNormalizedIpv4Bytes -Address $addr.Address
                if ($null -eq $bytes) { continue }
                if ($bytes[0] -eq 127) { continue }
                $text = ('{0}.{1}.{2}.{3}' -f $bytes[0], $bytes[1], $bytes[2], $bytes[3])
                if ($result -notcontains $text) { $result += $text }
            }
        }
    } catch { }
    return ,$result
}

function Test-GsConsoleDeployedMarker {
    # The same deployment marker the CLI's PrepareUninstall uses:
    # <stateDir>\runtime\bin\gs_stop_private.ps1. Read-only Test-Path only.
    param([AllowEmptyString()][string]$StateDir)
    if ([string]::IsNullOrWhiteSpace($StateDir)) { return $false }
    try {
        return (Test-Path -LiteralPath (Join-Path $StateDir 'runtime\bin\gs_stop_private.ps1') -PathType Leaf)
    } catch { return $false }
}

function Get-GsConsoleStateNameFromRow {
    # Maps a tray row state (or the synthetic NeedsSetup row) to the exact
    # console state name from the contract (case matters: 'needsSetup').
    param([Parameter(Mandatory = $true)][string]$RowState)
    switch ($RowState) {
        'NeedsSetup' { return 'needsSetup' }
        'Stopped' { return 'stopped' }
        'Starting' { return 'starting' }
        'Stopping' { return 'stopping' }
        'Ready' { return 'ready' }
        'Streaming' { return 'streaming' }
        'Error' { return 'error' }
        default { return 'unknown' }
    }
}

function Get-GsConsoleCapabilities {
    # Capabilities from the pure tray menu rules plus fixed setup actions.
    # Start/Stop/Recover depend ONLY on the runtime state row - never on
    # the redeployment-only source dirs. Deploy additionally requires a
    # component source dir AND an inactive runtime, so the UI cannot show a
    # deployable console while the API would answer RuntimeActive (the API
    # guard remains the final enforcement either way).
    param(
        $StateRow,
        [bool]$IsElevated,
        [AllowEmptyString()][string]$RuntimeState = ''
    )
    $pending = ''
    if ((Test-GsConsoleJobActive) -and $null -ne $script:CurrentJob) {
        $action = [string]$script:CurrentJob.Action
        if ($action -eq 'start') { $pending = 'Start' }
        elseif ($action -eq 'stop') { $pending = 'Stop' }
        elseif ($action -eq 'recover') { $pending = 'Recover' }
    }
    $start = $false; $stop = $false; $recover = $false
    if ($null -ne $StateRow) {
        $start = [bool](Get-GsTrayMenuEnabled -StateRow $StateRow -PendingAction $pending -MenuItem 'Start')
        $stop = [bool](Get-GsTrayMenuEnabled -StateRow $StateRow -PendingAction $pending -MenuItem 'Stop')
        $recover = [bool](Get-GsTrayMenuEnabled -StateRow $StateRow -PendingAction $pending -MenuItem 'Recover')
    }
    $componentsReady = (-not [string]::IsNullOrWhiteSpace([string]$script:Prefs.Settings.componentSourceDir))
    # Mirror of the retargeting guard: only an explicitly stopped (or
    # undeployed) runtime may be deployed onto; error/unknown stay
    # conservatively non-deployable.
    $layoutChangeAllowed = ($RuntimeState -in @('stopped', 'needsSetup'))
    return [ordered]@{
        start     = $start
        stop      = $stop
        recover   = $recover
        check     = $true
        deploy    = ($componentsReady -and $layoutChangeAllowed)
        diagnose  = $true
        browse    = $true
        autostart = [bool]$IsElevated
    }
}

function Test-GsConsoleRuntimeActive {
    # Retargeting guard: layout changes and deployments are allowed ONLY
    # when the runtime is EXPLICITLY stopped or undeployed (needsSetup).
    # Everything else - ready/streaming/starting/stopping, and also
    # error/unknown - refuses (409 RuntimeActive): a ready instance whose
    # serverinfo is unreachable maps to Error, so Error must never be read
    # as "stopped". A job in flight refuses too. displayName, poll interval
    # and the redeployment-only source dirs stay editable in every state.
    if (Test-GsConsoleJobActive) { return $true }
    if ($script:Mode -eq 'demo') {
        return ($script:DemoScenario -notin @('stopped', 'needsSetup'))
    }
    $mapped = Get-GsConsoleLiveMappedState
    return ($mapped.State -notin @('stopped', 'needsSetup'))
}

function Get-GsConsoleLiveMappedState {
    # Live state: read-only status-file read through the tray model, an
    # optional bounded serverinfo fetch (only for ready/running-family
    # statuses), and the deployed-runtime marker. Missing status is NOT
    # proof of ready; a deployed runtime without a status file shows
    # stopped (not needsSetup). No Check/Diagnose is invoked automatically.
    # Returns { State; Row; Deployed }: State is the mapped console state
    # name (shared with the retargeting guard), Row the tray row the DTO
    # decorates.
    $settings = $script:Prefs.Settings
    $stateDir = [string]$settings.stateDir
    $deployed = Test-GsConsoleDeployedMarker -StateDir $stateDir
    $row = $null
    if (-not $deployed) {
        $row = [pscustomobject]@{ State = 'NeedsSetup'; Detail = 'Runtime is not deployed'; CanStart = $false; CanStop = $false; DetailKey = ''; DetailArgs = @() }
    } else {
        $statusInfo = Get-GsTrayStatusInfo -StateDir $stateDir
        $serverInfo = $null
        $rawState = ''
        if ($null -ne $statusInfo -and $statusInfo.State -is [string]) { $rawState = $statusInfo.State.Trim().ToLowerInvariant() }
        if ($rawState -eq 'ready' -or $rawState -eq 'running') {
            try { $serverInfo = Get-GsTrayServerInfo -Uri $script:ServerInfoUriResolved -TimeoutMs $script:ServerInfoTimeoutMs } catch { $serverInfo = $null }
        }
        $row = Get-GsTrayUnderlyingState -StatusInfo $statusInfo -ServerInfo $serverInfo
    }
    return @{
        State    = (Get-GsConsoleStateNameFromRow -RowState ([string]$row.State))
        Row      = $row
        Deployed = [bool]$deployed
    }
}

function Get-GsConsoleLiveStateDto {
    # Live state DTO: the mapped state comes from Get-GsConsoleLiveMappedState
    # (shared with the retargeting guard); this function only attaches the
    # allowlisted fields around it.
    $settings = $script:Prefs.Settings
    $mapped = Get-GsConsoleLiveMappedState
    $row = $mapped.Row
    $consoleState = $mapped.State
    $deployed = $mapped.Deployed
    $elevated = $false
    try { $elevated = [bool](Test-GsTrayElevated) } catch { $elevated = $true }
    $capabilities = Get-GsConsoleCapabilities -StateRow $row -IsElevated $elevated -RuntimeState $consoleState
    $runtimeStatus = 'unknown'
    if ($null -ne $script:LastCompleted -and $script:LastCompleted.Action -eq 'check') {
        $runtimeStatus = $(if ([bool]$script:LastCompleted.Success) { 'ready' } else { 'missing' })
    }
    $componentsStatus = 'missing'
    if (-not [string]::IsNullOrWhiteSpace([string]$settings.componentSourceDir)) { $componentsStatus = 'ready' }
    $deploymentStatus = 'missing'
    if ($deployed) { $deploymentStatus = 'ready' }
    $permissionsStatus = 'unknown'
    if ($elevated) { $permissionsStatus = 'ready' } else { $permissionsStatus = 'warning' }
    return [ordered]@{
        mode             = 'live'
        version          = 'local-console-preview'
        displayName      = [string]$settings.displayName
        state            = $consoleState
        stateLabel       = (Get-GsConsoleStateLabel -State $consoleState)
        message          = [string]$row.Detail
        updatedAt        = (Get-Date).ToUniversalTime().ToString('o')
        isElevated       = [bool]$elevated
        addresses        = (Get-GsConsoleLocalAddresses)
        prerequisites    = @(
            [ordered]@{ id = 'runtime'; status = $runtimeStatus; code = ''; message = '' },
            [ordered]@{ id = 'components'; status = $componentsStatus; code = ''; message = '' },
            [ordered]@{ id = 'deployment'; status = $deploymentStatus; code = ''; message = '' },
            [ordered]@{ id = 'permissions'; status = $permissionsStatus; code = ''; message = '' }
        )
        capabilities     = $capabilities
        autostart        = [string]$script:LiveAutostartHint
        operation        = $null
        lastResult       = $null
        settingsRevision = [int]$script:Prefs.Revision
    }
}

function Get-GsConsoleDemoStateDto {
    # Demo fixture state: obviously synthetic, driven by the scenario.
    $scenario = $script:DemoScenario
    $row = $null
    switch ($scenario) {
        'needsSetup' { $row = [pscustomobject]@{ State = 'NeedsSetup'; Detail = 'Demo fixture: needs setup'; CanStart = $false; CanStop = $false; DetailKey = ''; DetailArgs = @() } }
        'stopped' { $row = [pscustomobject]@{ State = 'Stopped'; Detail = 'Demo fixture: stopped'; CanStart = $true; CanStop = $false; DetailKey = ''; DetailArgs = @() } }
        'ready' { $row = [pscustomobject]@{ State = 'Ready'; Detail = 'Demo fixture: ready'; CanStart = $false; CanStop = $true; DetailKey = ''; DetailArgs = @() } }
        'streaming' { $row = [pscustomobject]@{ State = 'Streaming'; Detail = 'Demo fixture: streaming'; CanStart = $false; CanStop = $true; DetailKey = ''; DetailArgs = @() } }
        'error' { $row = [pscustomobject]@{ State = 'Error'; Detail = 'Demo fixture: error'; CanStart = $true; CanStop = $true; DetailKey = ''; DetailArgs = @() } }
        default { $row = [pscustomobject]@{ State = 'Error'; Detail = 'Demo fixture: unknown scenario'; CanStart = $false; CanStop = $false; DetailKey = ''; DetailArgs = @() } }
    }
    $capabilities = Get-GsConsoleCapabilities -StateRow $row -IsElevated $false -RuntimeState (Get-GsConsoleStateNameFromRow -RowState ([string]$row.State))
    return [ordered]@{
        mode             = 'demo'
        version          = 'local-console-preview'
        displayName      = [string]$script:Prefs.Settings.displayName
        state            = (Get-GsConsoleStateNameFromRow -RowState ([string]$row.State))
        stateLabel       = (Get-GsConsoleStateLabel -State (Get-GsConsoleStateNameFromRow -RowState ([string]$row.State)))
        message          = [string]$row.Detail
        updatedAt        = (Get-Date).ToUniversalTime().ToString('o')
        isElevated       = $false
        addresses        = @('192.0.2.10')
        prerequisites    = @(
            [ordered]@{ id = 'runtime'; status = 'unknown'; code = ''; message = '' },
            [ordered]@{ id = 'components'; status = $($(if ([string]::IsNullOrWhiteSpace([string]$script:Prefs.Settings.componentSourceDir)) { 'missing' } else { 'ready' })); code = ''; message = '' },
            [ordered]@{ id = 'deployment'; status = $($(if ($script:DemoScenario -eq 'needsSetup') { 'missing' } else { 'ready' })); code = ''; message = '' },
            [ordered]@{ id = 'permissions'; status = 'unknown'; code = ''; message = '' }
        )
        capabilities     = $capabilities
        autostart        = [string]$script:DemoAutostart
        operation        = $null
        lastResult       = $null
        settingsRevision = [int]$script:Prefs.Revision
    }
}

function Add-GsConsoleOperationFields {
    # Attaches the in-flight operation and the last completed result to a
    # state DTO (top-level, allowlisted fields only).
    param($Dto)
    if ((Test-GsConsoleJobActive) -and $null -ne $script:CurrentJob) {
        $Dto.operation = [ordered]@{
            id        = [string]$script:CurrentJob.Id
            action    = [string]$script:CurrentJob.Action
            status    = 'running'
            startedAt = $script:CurrentJob.StartedAtUtc.ToString('o')
        }
    } else {
        $Dto.operation = $null
    }
    if ($null -ne $script:LastCompleted) {
        $Dto.lastResult = [ordered]@{
            id          = [string]$script:LastCompleted.Id
            action      = [string]$script:LastCompleted.Action
            success     = $script:LastCompleted.Success
            code        = [string]$script:LastCompleted.Code
            finishedAt  = $(if ($null -ne $script:LastCompleted.FinishedAtUtc) { $script:LastCompleted.FinishedAtUtc.ToString('o') } else { $null })
        }
    } else {
        $Dto.lastResult = $null
    }
}

# ---------------------------------------------------------------------------
# API route handlers
# ---------------------------------------------------------------------------

function Invoke-GsConsoleApiState {
    param($Context)
    Update-GsConsoleJobPoll
    if ($script:Mode -eq 'demo') { $dto = Get-GsConsoleDemoStateDto } else { $dto = Get-GsConsoleLiveStateDto }
    Add-GsConsoleOperationFields -Dto $dto
    Write-GsConsoleJson $Context 200 ([ordered]@{ ok = $true; data = $dto })
}

function Invoke-GsConsoleApiSettingsGet {
    param($Context)
    $settings = [ordered]@{ }
    foreach ($name in (Get-GsConsoleSettingsKeyOrder)) {
        if ($name -eq 'pollIntervalSec') { $settings.$name = [int]$script:Prefs.Settings.$name }
        else { $settings.$name = [string]$script:Prefs.Settings.$name }
    }
    Write-GsConsoleJson $Context 200 ([ordered]@{
        ok       = $true
        data     = [ordered]@{ revision = [int]$script:Prefs.Revision; settings = $settings }
    })
}

function Invoke-GsConsoleApiSettingsPost {
    param($Context, $Body)
    # Busy first (contract: saves during a pending job return Busy), then
    # revision, then full validation, then atomic save. Saving NEVER
    # deploys, moves files or touches runtime-config.json.
    if (Test-GsConsoleJobActive) {
        Write-GsConsoleJson $Context 409 (New-GsConsoleErrorPayload 'Busy' 'An action is running; settings are locked.' )
        return
    }
    foreach ($name in @('revision', 'settings')) {
        if (-not $Body.PSObject.Properties[$name]) {
            Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'MissingField' ("Missing field: " + $name) @(@{ field = $name; code = 'MissingField' }))
            return
        }
    }
    foreach ($prop in $Body.PSObject.Properties) {
        if ($prop.Name -notin @('revision', 'settings')) {
            Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'UnknownField' ("Unknown field: " + $prop.Name) @(@{ field = $prop.Name; code = 'UnknownField' }))
            return
        }
    }
    if (-not ($Body.revision -is [int] -or $Body.revision -is [long])) {
        Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'InvalidType' 'revision must be an integer.' @(@{ field = 'revision'; code = 'InvalidType' }))
        return
    }
    if ([long]$Body.revision -ne [long]$script:Prefs.Revision) {
        Write-GsConsoleJson $Context 409 (New-GsConsoleErrorPayload 'RevisionConflict' 'The settings were changed by someone else; reload and retry.')
        return
    }
    $settingsObj = $Body.settings
    if ($null -eq $settingsObj -or $settingsObj -isnot [pscustomobject]) {
        Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'InvalidType' 'settings must be an object.' @(@{ field = 'settings'; code = 'InvalidType' }))
        return
    }
    $allowed = Get-GsConsoleSettingsKeyOrder
    foreach ($prop in $settingsObj.PSObject.Properties) {
        if ($prop.Name -notin $allowed) {
            Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'UnknownField' ("Unknown settings key: " + $prop.Name) @(@{ field = ('settings.' + $prop.Name); code = 'UnknownField' }))
            return
        }
    }
    foreach ($name in $allowed) {
        if (-not $settingsObj.PSObject.Properties[$name]) {
            Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'MissingField' ("Missing settings key: " + $name) @(@{ field = ('settings.' + $name); code = 'MissingField' }))
            return
        }
    }
    $candidate = @{}
    foreach ($name in $allowed) { $candidate.$name = $settingsObj.$name }
    $checked = Test-GsConsoleSettingsValues -Settings $candidate
    if (-not $checked.Ok) {
        Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'InvalidInput' 'One or more settings values were rejected.' $checked.Errors)
        return
    }
    # Layout-change guard: while the runtime is active, the three target
    # directories must not change (a save must never silently retarget a
    # running instance). displayName/pollIntervalSec/source dirs stay
    # editable; only stopped/needsSetup allow target changes.
    $retargeting = $false
    foreach ($name in @('installDir', 'stateDir', 'logDir')) {
        if ((Get-GsConsoleComparablePath ([string]$checked.Settings.$name)) -ne (Get-GsConsoleComparablePath ([string]$script:Prefs.Settings.$name))) {
            $retargeting = $true
            break
        }
    }
    if ($retargeting -and (Test-GsConsoleRuntimeActive)) {
        Write-GsConsoleJson $Context 409 (New-GsConsoleErrorPayload 'RuntimeActive' 'The runtime is active; stop it before changing the target directories.')
        return
    }
    $newRevision = $script:Prefs.Revision + 1
    Save-GsConsolePrefs -Revision $newRevision -Settings $checked.Settings
    $script:Prefs = @{ Revision = $newRevision; Settings = $checked.Settings }
    $settings = [ordered]@{ }
    foreach ($name in (Get-GsConsoleSettingsKeyOrder)) {
        if ($name -eq 'pollIntervalSec') { $settings.$name = [int]$checked.Settings.$name }
        else { $settings.$name = [string]$checked.Settings.$name }
    }
    Write-GsConsoleJson $Context 200 ([ordered]@{
        ok   = $true
        data = [ordered]@{ revision = $newRevision; settings = $settings }
    })
}

function Invoke-GsConsoleApiActions {
    param($Context, $Body)
    Update-GsConsoleJobPoll
    $allowedActions = @('start', 'stop', 'recover', 'check', 'deploy', 'diagnose', 'autostart-enable', 'autostart-disable', 'browse')
    foreach ($name in @('action', 'revision')) {
        if (-not $Body.PSObject.Properties[$name]) {
            Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'MissingField' ("Missing field: " + $name) @(@{ field = $name; code = 'MissingField' }))
            return
        }
    }
    foreach ($prop in $Body.PSObject.Properties) {
        if ($prop.Name -notin @('action', 'revision', 'confirm', 'field')) {
            Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'UnknownField' ("Unknown field: " + $prop.Name) @(@{ field = $prop.Name; code = 'UnknownField' }))
            return
        }
    }
    $action = Get-GsConsoleStringProperty -Object $Body -Name 'action'
    if ($null -eq $action -or $action -notin $allowedActions) {
        Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'UnknownAction' 'The requested action is not in the allowlist.' @(@{ field = 'action'; code = 'UnknownAction' }))
        return
    }
    if (-not ($Body.revision -is [int] -or $Body.revision -is [long])) {
        Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'InvalidType' 'revision must be an integer.' @(@{ field = 'revision'; code = 'InvalidType' }))
        return
    }
    if ([long]$Body.revision -ne [long]$script:Prefs.Revision) {
        Write-GsConsoleJson $Context 409 (New-GsConsoleErrorPayload 'RevisionConflict' 'The settings changed; reload and retry.')
        return
    }
    # Action authorization is enforced HERE, independently of any disabled
    # frontend button. Confirm must be a strict JSON true where required.
    $needConfirm = @('stop', 'recover', 'deploy', 'autostart-enable', 'autostart-disable')
    $confirm = $false
    if ($Body.PSObject.Properties['confirm']) {
        if ($Body.confirm -is [bool]) { $confirm = [bool]$Body.confirm }
    }
    if ($action -in $needConfirm -and -not $confirm) {
        Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'ConfirmRequired' 'This action requires confirm=true.' @(@{ field = 'confirm'; code = 'ConfirmRequired' }))
        return
    }
    if ($action -eq 'browse') {
        $field = Get-GsConsoleStringProperty -Object $Body -Name 'field'
        if ($null -eq $field -or $field -notin @('componentSourceDir', 'helperSourceDir')) {
            Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'InvalidValue' 'browse requires field componentSourceDir or helperSourceDir.' @(@{ field = 'field'; code = 'InvalidValue' }))
            return
        }
    }
    if (($action -in @('autostart-enable', 'autostart-disable')) -and $script:Mode -eq 'live') {
        # Live autostart is an explicit elevated capability (demo simulates
        # it without any elevation requirement).
        $elevated = $false
        try { $elevated = [bool](Test-GsTrayElevated) } catch { $elevated = $true }
        if (-not $elevated) {
            Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'ElevationRequired' 'Autostart changes require an elevated console.')
            return
        }
    }
    if (Test-GsConsoleJobActive) {
        Write-GsConsoleJson $Context 409 (New-GsConsoleErrorPayload 'Busy' 'Another action is running.')
        return
    }
    $job = $null
    if ($script:Mode -eq 'demo') {
        # Demo never reaches the live action handler (structurally separate).
        if ($action -eq 'deploy' -and (Test-GsConsoleRuntimeActive)) {
            # Demo simulates the live constraint: a deployment cannot target
            # a running instance.
            Write-GsConsoleJson $Context 409 (New-GsConsoleErrorPayload 'RuntimeActive' 'The runtime is active; stop it before deploying a new layout.')
            return
        }
        $job = Start-GsConsoleDemoAction -Action $action
    } else {
        if ($action -eq 'deploy') {
            if (Test-GsConsoleRuntimeActive) {
                Write-GsConsoleJson $Context 409 (New-GsConsoleErrorPayload 'RuntimeActive' 'The runtime is active; stop it before deploying a new layout.')
                return
            }
            $settings = $script:Prefs.Settings
            if ([string]::IsNullOrWhiteSpace([string]$settings.componentSourceDir)) {
                Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'MissingInput' 'componentSourceDir is required before a deployment.' @(@{ field = 'field'; code = 'MissingInput' }))
                return
            }
            $targetErrors = Test-GsConsoleDeployTargets
            if ($targetErrors.Count -gt 0) {
                Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'TargetNotAllowed' 'An existing target directory does not look product-owned; deployment was refused.' $targetErrors)
                return
            }
        }
        $job = Start-GsConsoleLiveAction -Action $action
        if ($null -eq $job) {
            # The registered job was already completed as 'LaunchFailed';
            # answer with the matching failure envelope instead of 202.
            Write-GsConsoleJson $Context 500 (New-GsConsoleErrorPayload 'LaunchFailed' 'The action could not be started; it is recorded as a failed job.')
            return
        }
    }
    Write-GsConsoleJson $Context 202 ([ordered]@{
        ok   = $true
        data = [ordered]@{ id = [string]$job.Id; action = [string]$job.Action; status = 'running' }
    })
}

function Invoke-GsConsoleApiJob {
    param($Context, [string]$JobId)
    Update-GsConsoleJobPoll
    if ($JobId -notmatch '^[0-9a-f]{32}$') {
        Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown job.')
        return
    }
    $job = Find-GsConsoleJobById -Id $JobId
    if ($null -eq $job) {
        Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown job.')
        return
    }
    Write-GsConsoleJson $Context 200 ([ordered]@{ ok = $true; data = (Get-GsConsoleJobDto -Job $job) })
}

function Invoke-GsConsoleApiDemoScenario {
    param($Context, $Body)
    if ($script:Mode -ne 'demo') {
        Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown path.')
        return
    }
    if (Test-GsConsoleJobActive) {
        Write-GsConsoleJson $Context 409 (New-GsConsoleErrorPayload 'Busy' 'An action is running.')
        return
    }
    foreach ($prop in $Body.PSObject.Properties) {
        if ($prop.Name -ne 'scenario') {
            Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'UnknownField' ("Unknown field: " + $prop.Name) @(@{ field = $prop.Name; code = 'UnknownField' }))
            return
        }
    }
    $scenario = Get-GsConsoleStringProperty -Object $Body -Name 'scenario'
    if ($null -eq $scenario -or $scenario -notin @('stopped', 'needsSetup', 'ready', 'streaming', 'error')) {
        Write-GsConsoleJson $Context 400 (New-GsConsoleErrorPayload 'InvalidValue' 'scenario must be one of stopped, needsSetup, ready, streaming, error.' @(@{ field = 'scenario'; code = 'InvalidValue' }))
        return
    }
    $script:DemoScenario = $scenario
    Write-GsConsoleJson $Context 200 ([ordered]@{ ok = $true; data = [ordered]@{ scenario = $scenario } })
}

# ---------------------------------------------------------------------------
# Sunshine backend: install profile, read-only status, isolated routing
# ---------------------------------------------------------------------------

function Read-GsConsoleInstallProfile {
    # Bounded read of the build-generated gs-install-profile.json. Returns
    # @{ Found; Backend ('legacy'|'sunshine'|$null); Error }. A MISSING
    # file is not an error (Legacy default for old callers); any PRESENT
    # but invalid content sets Error and must fail startup - never a
    # silent fallback. The content is parsed only, never executed; unknown
    # fields are rejected (schemaVersion 1 carries exactly two fields).
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
            return @{ Found = $false; Backend = $null; Error = '' }
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)) {
            return @{ Found = $true; Backend = $null; Error = 'ProfileNotFile' }
        }
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $read = Read-GsConsoleBoundedStream -Stream $stream -MaxBytes 4096 -TimeoutMs 1000
        } finally { $stream.Dispose() }
        if (-not $read.Complete) {
            $code = if ($read.StopReason -eq 'cap') { 'ProfileFileOversized' } else { 'ProfileUnreadable' }
            return @{ Found = $true; Backend = $null; Error = $code }
        }
        $decoder = New-Object Text.UTF8Encoding($false, $true)
        $text = $decoder.GetString($read.Bytes).TrimStart([char]0xFEFF)
        $doc = $text | ConvertFrom-Json -ErrorAction Stop
        # NOTE: '-is [pscustomobject]' is true for arrays too (the accelerator
        # is PSObject and everything is one), so the exact type name decides.
        if ($null -eq $doc -or $doc.GetType().Name -ne 'PSCustomObject') {
            return @{ Found = $true; Backend = $null; Error = 'ProfileShapeInvalid' }
        }
        foreach ($prop in $doc.PSObject.Properties) {
            if ($prop.Name -notin @('schemaVersion', 'backend')) {
                return @{ Found = $true; Backend = $null; Error = 'ProfileUnknownField' }
            }
        }
        $schemaOk = $false
        if ($doc.PSObject.Properties['schemaVersion']) {
            $schemaValue = $doc.schemaVersion
            if ($schemaValue -is [int] -or $schemaValue -is [long]) { $schemaOk = ($schemaValue -eq 1) }
        }
        if (-not $schemaOk) {
            return @{ Found = $true; Backend = $null; Error = 'ProfileSchemaVersionInvalid' }
        }
        if (-not $doc.PSObject.Properties['backend']) {
            return @{ Found = $true; Backend = $null; Error = 'ProfileBackendMissing' }
        }
        $backendValue = $doc.backend
        if ($backendValue -isnot [string]) {
            return @{ Found = $true; Backend = $null; Error = 'ProfileBackendInvalid' }
        }
        if ($backendValue -ceq 'sunshine') { return @{ Found = $true; Backend = 'sunshine'; Error = '' } }
        if ($backendValue -ceq 'legacy') { return @{ Found = $true; Backend = 'legacy'; Error = '' } }
        return @{ Found = $true; Backend = $null; Error = 'ProfileBackendInvalid' }
    } catch {
        return @{ Found = $true; Backend = $null; Error = 'ProfileUnreadable' }
    }
}

function Resolve-GsConsoleBackend {
    # Explicit -Backend wins (case-insensitive); otherwise the install
    # profile decides; a missing profile defaults to Legacy. A present but
    # INVALID profile throws - the caller reports the startup failure.
    param(
        [AllowEmptyString()][string]$RequestedBackend,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )
    if (-not [string]::IsNullOrWhiteSpace($RequestedBackend)) {
        if ([string]::Equals($RequestedBackend, 'Legacy', [StringComparison]::OrdinalIgnoreCase)) { return 'Legacy' }
        if ([string]::Equals($RequestedBackend, 'Sunshine', [StringComparison]::OrdinalIgnoreCase)) { return 'Sunshine' }
        throw ('Unknown backend requested: ' + $RequestedBackend)
    }
    $installProfile = Read-GsConsoleInstallProfile -Path $ProfilePath
    if (-not [string]::IsNullOrEmpty($installProfile.Error)) {
        throw ('The install profile is invalid (' + $installProfile.Error + '): ' + $ProfilePath)
    }
    if ($installProfile.Backend -eq 'sunshine') { return 'Sunshine' }
    return 'Legacy'
}

function New-GsConsoleSunshineStatusDto {
    # The fixed read-only status shape (SUNSHINE-BACKEND-CONTRACT.md).
    # installed / managementPortOpen pass the probe result through
    # unchanged, INCLUDING $null (unknown): null is never rewritten into a
    # definite answer. No pairing/streaming claim exists anywhere.
    param(
        $Snapshot,
        [Parameter(Mandatory = $true)][ValidateSet('live', 'demo')][string]$Mode,
        [Parameter(Mandatory = $true)][datetime]$ObservedAtUtc
    )
    return [ordered]@{
        backend            = 'sunshine'
        mode               = [string]$Mode
        observedAt         = $ObservedAtUtc.ToUniversalTime().ToString('o')
        installed          = $Snapshot.Installed
        managementPortOpen = $Snapshot.ManagementPortOpen
        pairingStatus      = 'notChecked'
        streamingStatus    = 'notChecked'
        managementUrl      = 'https://localhost:47990'
        downloadUrl        = 'https://github.com/LizardByte/Sunshine/releases/latest'
        clientUrl          = 'https://moonlight-stream.org'
    }
}

function Invoke-GsConsoleApiSunshineStatus {
    # GET /api/sunshine/status. Live mode runs the real read-only probes;
    # demo mode returns a fixed synthetic snapshot and must NEVER call a
    # probe. Detection is never paired with any claim of pairing or
    # streaming success - those stay 'notChecked' forever.
    param($Context)
    $snapshot = $null
    if ($script:Mode -eq 'demo') {
        $snapshot = @{ Installed = $true; InstalledPath = ''; ManagementPortOpen = $true }
    } else {
        $snapshot = Get-GsSunshineProbeSnapshot
    }
    $dto = New-GsConsoleSunshineStatusDto -Snapshot $snapshot -Mode $script:Mode -ObservedAtUtc (Get-Date)
    Write-GsConsoleJson $Context 200 ([ordered]@{ ok = $true; data = $dto })
}

function Invoke-GsConsoleSunshineRequest {
    # Sunshine routing: a fixed four-entry static map and exactly one API
    # route. Session and Origin rules are identical to legacy; every other
    # API path or method is a 404 and never reaches legacy handlers, the
    # legacy CLI, the runtime module, prefs or jobs state.
    param($Context, [Parameter(Mandatory = $true)][string]$RawPath, [Parameter(Mandatory = $true)][string]$Method)
    $isApi = $RawPath.StartsWith('/api/', [StringComparison]::Ordinal)
    if (-not $isApi) {
        if ($Method -notin @('GET', 'HEAD')) {
            Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown path.')
            return
        }
        switch ($RawPath) {
            '/' { Write-GsConsoleStatic $Context 'sunshine-html' }
            '/gs-sunshine.js' { Write-GsConsoleStatic $Context 'sunshine-js' }
            '/gs-console.css' { Write-GsConsoleStatic $Context 'css' }
            '/gs-sunshine.css' { Write-GsConsoleStatic $Context 'sunshine-css' }
            default { Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown path.') }
        }
        return
    }
    $provided = ''
    try { $provided = [string]$Context.Request.Headers['X-Gs-Session'] } catch { }
    if (-not (Test-GsConsoleTokenEqual -Provided $provided -Expected $script:SessionToken)) {
        Write-GsConsoleJson $Context 401 (New-GsConsoleErrorPayload 'Unauthorized' 'A valid X-Gs-Session header is required.')
        return
    }
    if (-not (Test-GsConsoleOriginAllowed -Request $Context.Request -Port $script:Port -RequireOrigin:($Method -eq 'POST'))) {
        Write-GsConsoleJson $Context 403 (New-GsConsoleErrorPayload 'ForbiddenOrigin' 'The Origin header must be the same-loopback console origin.')
        return
    }
    if ($RawPath -eq '/api/sunshine/status' -and $Method -eq 'GET') {
        Invoke-GsConsoleApiSunshineStatus -Context $Context
        return
    }
    Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown path or method.')
}

# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------

function Invoke-GsConsoleRequest {
    # One request, one handler. Never throws outward; unexpected failures
    # become a generic 500 envelope with no exception text.
    param($Context)
    try {
        $request = $Context.Request
        $rawPath = [string]$request.Url.AbsolutePath
        $method = ([string]$request.HttpMethod).ToUpperInvariant()

        # 1. Network boundary: the actual remote peer must be loopback.
        if (-not (Test-GsConsoleLoopbackEndPoint -EndPoint $request.RemoteEndPoint)) {
            Write-GsConsoleJson $Context 403 (New-GsConsoleErrorPayload 'ForbiddenRemote' 'Only loopback clients may connect.')
            return
        }
        # 2. Exact loopback Host.
        if (-not (Test-GsConsoleHostAllowed -Request $request -Port $script:Port)) {
            Write-GsConsoleJson $Context 403 (New-GsConsoleErrorPayload 'ForbiddenHost' 'The Host header must be the loopback console address.')
            return
        }

        # Sunshine backend: fully isolated routing. The loopback/Host
        # boundary and the static/API split above are shared; everything
        # below this branch is legacy-only.
        if ($script:Backend -eq 'Sunshine') {
            Invoke-GsConsoleSunshineRequest -Context $Context -RawPath $rawPath -Method $method
            return
        }

        $isApi = $rawPath.StartsWith('/api/', [StringComparison]::Ordinal)
        if (-not $isApi) {
            # Fixed static map; HEAD returns the same headers without a body.
            if ($method -notin @('GET', 'HEAD')) {
                Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown path.')
                return
            }
            switch ($rawPath) {
                '/' { Write-GsConsoleStatic $Context 'html' }
                '/gs-console.css' { Write-GsConsoleStatic $Context 'css' }
                '/gs-console.js' { Write-GsConsoleStatic $Context 'js' }
                default { Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown path.') }
            }
            return
        }

        # 3. Session token for every API route, including reads.
        $provided = ''
        try { $provided = [string]$request.Headers['X-Gs-Session'] } catch { }
        if (-not (Test-GsConsoleTokenEqual -Provided $provided -Expected $script:SessionToken)) {
            Write-GsConsoleJson $Context 401 (New-GsConsoleErrorPayload 'Unauthorized' 'A valid X-Gs-Session header is required.')
            return
        }

        # 4. Origin: POST requires an exact same-loopback Origin; GET APIs
        #    may omit it, but an explicitly wrong (cross-origin or null)
        #    Origin is rejected on every API route.
        if (-not (Test-GsConsoleOriginAllowed -Request $request -Port $script:Port -RequireOrigin:($method -eq 'POST'))) {
            Write-GsConsoleJson $Context 403 (New-GsConsoleErrorPayload 'ForbiddenOrigin' 'The Origin header must be the same-loopback console origin.')
            return
        }

        $apiPath = $rawPath.Substring(5)
        # 5. Route + method.
        if ($apiPath -eq 'state' -and $method -eq 'GET') { Invoke-GsConsoleApiState -Context $Context; return }
        if ($apiPath -eq 'settings' -and $method -eq 'GET') { Invoke-GsConsoleApiSettingsGet -Context $Context; return }
        if ($apiPath -eq 'settings' -and $method -eq 'POST') {
            $body = Read-GsConsoleJsonObject -Request $request
            if (-not $body.Ok) { Write-GsConsoleJson $Context $body.HttpStatus (New-GsConsoleErrorPayload $body.Code $body.Message $body.Fields); return }
            Invoke-GsConsoleApiSettingsPost -Context $Context -Body $body.Object
            return
        }
        if ($apiPath -eq 'actions' -and $method -eq 'POST') {
            $body = Read-GsConsoleJsonObject -Request $request
            if (-not $body.Ok) { Write-GsConsoleJson $Context $body.HttpStatus (New-GsConsoleErrorPayload $body.Code $body.Message $body.Fields); return }
            Invoke-GsConsoleApiActions -Context $Context -Body $body.Object
            return
        }
        if ($apiPath -eq 'demo/scenario' -and $method -eq 'POST') {
            $body = Read-GsConsoleJsonObject -Request $request
            if (-not $body.Ok) { Write-GsConsoleJson $Context $body.HttpStatus (New-GsConsoleErrorPayload $body.Code $body.Message $body.Fields); return }
            Invoke-GsConsoleApiDemoScenario -Context $Context -Body $body.Object
            return
        }
        if ($apiPath.StartsWith('jobs/', [StringComparison]::Ordinal) -and $method -eq 'GET') {
            $jobId = $apiPath.Substring(5)
            Invoke-GsConsoleApiJob -Context $Context -JobId $jobId
            return
        }
        Write-GsConsoleJson $Context 404 (New-GsConsoleErrorPayload 'NotFound' 'Unknown path or method.')
    } catch {
        # One diagnostic line on stderr (no request content, no secrets):
        # the only trace an unexpected handler failure leaves anywhere.
        try { [Console]::Error.WriteLine(('CONSOLE-REQUEST-FAILED: ' + $_.Exception.GetType().Name)) } catch { }
        try { Write-GsConsoleJson $Context 500 (New-GsConsoleErrorPayload 'InternalError' 'The request could not be processed.') } catch { }
    }
}

# ---------------------------------------------------------------------------
# Startup, listener, main loop, optional tray
# ---------------------------------------------------------------------------

function Show-GsConsoleMessageBox {
    # UI adapter for one startup-failure dialog. Tests replace this function
    # (DefineOnly) to capture the requested text; production shows a single
    # fixed-text MessageBox with the product name as the caption. The text
    # is a fixed localized string - never exception text, never session data.
    param([Parameter(Mandatory = $true)][string]$Text)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($Text, (Get-GsConsoleString 'tooltip.prefix'),
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    } catch { }
}

function Show-GsConsoleStartupFailure {
    # Single reporting point for every startup/listener failure path: the
    # stderr line is written exactly as before and the CALLER keeps the
    # original exit code. With -ShowStartupErrors (interactive launcher) and
    # a tray (not -NoTray), one additional fixed-text MessageBox is shown;
    # automation and -NoTray never see a dialog.
    param(
        [Parameter(Mandatory = $true)][string]$StdErrLine,
        [Parameter(Mandatory = $true)][string]$StringKey
    )
    try { [Console]::Error.WriteLine($StdErrLine) } catch { }
    if ($ShowStartupErrors -and -not $NoTray) {
        Show-GsConsoleMessageBox -Text (Get-GsConsoleString $StringKey)
    }
}

function Test-GsConsoleSupportedEnvironment {
    # Product support matrix for the console server: 64-bit Windows, 64-bit
    # Windows PowerShell 5.1 Desktop edition. Anything else fails clearly -
    # no silent downgrade, no system changes.
    if ([Environment]::Is64BitOperatingSystem -ne $true) { return 'Requires64BitWindows' }
    if ([Environment]::Is64BitProcess -ne $true) { return 'Requires64BitPowerShell' }
    if ($PSVersionTable.PSVersion.Major -ne 5) { return 'RequiresPowerShell51' }
    if ($PSVersionTable.PSVersion.Minor -lt 1) { return 'RequiresPowerShell51' }
    if ($PSVersionTable.PSObject.Properties['PSEdition'] -and $PSVersionTable.PSEdition -ne 'Desktop') { return 'RequiresPowerShellDesktop' }
    return ''
}

function Resolve-GsConsoleSystemPowerShell {
    # Explicit system Windows PowerShell path (64-bit System32 location;
    # this process is verified 64-bit above, so no SysWOW64 redirection
    # applies). The launcher never relies on PATH.
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Resolve-GsConsoleStartup {
    # Resolves the trusted startup inputs. Fails with a clear message when
    # the backend selection or the live product entry cannot be resolved.
    # Explicit parameters win over defaults; empty parameters fall back to
    # the documented defaults. The Sunshine backend skips every legacy
    # resolution (product CLI, module, prefs, jobs) entirely.
    if ([string]::IsNullOrWhiteSpace($script:StaticDirResolved) -and -not [string]::IsNullOrWhiteSpace($StaticDir)) {
        $script:StaticDirResolved = $StaticDir
    }
    if ([string]::IsNullOrWhiteSpace($script:StaticDirResolved)) {
        $script:StaticDirResolved = $script:ConsoleScriptRoot
    }
    # Backend selection happens FIRST: the Sunshine backend never resolves,
    # reads or creates any legacy runtime, prefs or jobs state. A missing
    # profile file defaults to Legacy; a present but invalid profile fails
    # startup right here (exit 4 via the caller).
    $script:InstallProfilePathResolved = $ProfilePath
    if ([string]::IsNullOrWhiteSpace($script:InstallProfilePathResolved)) {
        $script:InstallProfilePathResolved = (Join-Path $script:ConsoleScriptRoot 'gs-install-profile.json')
    }
    $script:Backend = Resolve-GsConsoleBackend -RequestedBackend $Backend -ProfilePath $script:InstallProfilePathResolved
    if ($script:Backend -eq 'Sunshine') {
        if (-not (Test-Path -LiteralPath (Join-Path $script:ConsoleScriptRoot 'gs-sunshine.ps1') -PathType Leaf)) {
            throw 'The Sunshine probe helper is missing from the product directory.'
        }
        # External-runtime guide mode: no legacy product CLI, no GsRuntime
        # import, no legacy prefs file or directory, no jobs root. Only the
        # static dir and the session secret are needed, so nothing on disk
        # is created or read for session state at all.
        $script:ProductPathResolved = ''
        $script:ModuleRootResolved = ''
        $script:StateDirDefault = ''
        $script:ConfigFilePath = ''
        $script:JobsRoot = ''
        $script:GsRuntimeAvailable = $false
        $script:Prefs = $null
    } else {
        if (-not [string]::IsNullOrWhiteSpace($ProductPath)) {
            $script:ProductPathResolved = $ProductPath
        }
        if ([string]::IsNullOrWhiteSpace($script:ProductPathResolved)) {
            $script:ProductPathResolved = Join-Path $script:ConsoleScriptRoot 'gs-product.ps1'
        }
        if (-not [string]::IsNullOrWhiteSpace($ModuleRoot)) {
            $script:ModuleRootResolved = $ModuleRoot
        }
        if ([string]::IsNullOrWhiteSpace($script:ModuleRootResolved)) {
            $siblingModules = Join-Path $script:ConsoleScriptRoot 'Modules'
            if (Test-Path -LiteralPath $siblingModules -PathType Container) {
                $script:ModuleRootResolved = $siblingModules
            } else {
                $script:ModuleRootResolved = Join-Path (Split-Path -Parent $script:ConsoleScriptRoot) 'src'
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
            $script:StateDirDefault = $StateDir
        }
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
            $script:ConfigFilePath = $ConfigPath
        }
        if ([string]::IsNullOrWhiteSpace($script:ConfigFilePath)) {
            if ($script:Mode -eq 'demo') {
                # Demo config lives in a newly created TEMP directory.
                $demoRoot = Join-Path ([IO.Path]::GetTempPath()) ('gs-console-demo-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $demoRoot -Force | Out-Null
                $script:ConfigFilePath = Join-Path $demoRoot 'console-prefs.json'
            } else {
                $consoleDir = Join-Path $env:LOCALAPPDATA 'GsController\console'
                New-Item -ItemType Directory -Path $consoleDir -Force | Out-Null
                $script:ConfigFilePath = Join-Path $consoleDir 'console-prefs.json'
            }
        } else {
            $parent = Split-Path -Parent $script:ConfigFilePath
            if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
        }
        if ($script:Mode -eq 'demo' -and [string]::IsNullOrWhiteSpace($script:StateDirDefault)) {
            # Demo settings defaults stay inside the demo TEMP area (unless an
            # explicit -StateDir was provided); the real machine layout is never
            # probed in demo mode.
            $script:StateDirDefault = Join-Path (Split-Path -Parent $script:ConfigFilePath) 'state'
        }
        $script:JobsRoot = Join-Path (Split-Path -Parent $script:ConfigFilePath) 'jobs'
        if (-not (Test-Path -LiteralPath $script:JobsRoot)) { New-Item -ItemType Directory -Path $script:JobsRoot -Force | Out-Null }
        if ($script:Mode -eq 'live') {
            if (-not (Test-Path -LiteralPath $script:ProductPathResolved -PathType Leaf)) {
                throw ("The product CLI was not found: " + $script:ProductPathResolved)
            }
            # Optional GsRuntime import (used only to READ the runtime config
            # once for layout initialization; the CLI imports its own modules).
            $manifest = Join-Path $script:ModuleRootResolved 'GsRuntime\GsRuntime.psd1'
            if (Test-Path -LiteralPath $manifest -PathType Leaf) {
                try { Import-Module $manifest -Force; $script:GsRuntimeAvailable = $true } catch { $script:GsRuntimeAvailable = $false }
            }
        } else {
            # Demo never reads the real machine configuration.
            $script:GsRuntimeAvailable = $false
        }
        $script:Prefs = Read-GsConsolePrefs
    }
    if ($script:Mode -eq 'demo') {
        $script:SessionToken = $script:DemoToken
    } elseif (-not [string]::IsNullOrWhiteSpace($SessionToken)) {
        # Trusted startup override (test/dev seam, see the param comment).
        $script:SessionToken = [string]$SessionToken
    } else {
        $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
        try {
            $bytes = New-Object byte[] 32
            $rng.GetBytes($bytes)
        } finally { $rng.Dispose() }
        $hex = ''
        foreach ($b in $bytes) { $hex += $b.ToString('x2') }
        $script:SessionToken = $hex
    }
    $script:LaunchUrl = ('http://127.0.0.1:' + $script:Port + '/#session=' + $script:SessionToken)
}

function Test-GsConsolePortInUse {
    param([Parameter(Mandatory = $true)][int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync('127.0.0.1', $Port)
            if ($task.Wait(500) -and $client.Connected) { return $true }
        } finally { try { $client.Close() } catch { } }
    } catch { }
    return $false
}

function Start-GsConsoleListener {
    # Binds the fixed loopback prefix. Never registers a URL ACL or touches
    # the firewall; failures are classified and reported clearly.
    $listener = New-Object System.Net.HttpListener
    # The two exact same-machine loopback aliases ONLY - never a wildcard,
    # '+' or LAN prefix. The RemoteEndPoint loopback check remains the
    # network boundary; the prefixes only let both loopback spellings in.
    $listener.Prefixes.Add(('http://127.0.0.1:' + $script:Port + '/'))
    $listener.Prefixes.Add(('http://localhost:' + $script:Port + '/'))
    try {
        $listener.Start()
    } catch {
        if (Test-GsConsolePortInUse -Port $script:Port) {
            Show-GsConsoleStartupFailure -StdErrLine ('CONSOLE-LISTENER-BUSY: ' + (Get-GsConsoleString 'tray.alreadyRunning')) -StringKey 'startup.busy'
            exit 2
        }
        Show-GsConsoleStartupFailure -StdErrLine ('CONSOLE-LISTENER-FAILED: ' + (Get-GsConsoleString 'tray.listenerDenied')) -StringKey 'startup.listenerFailed'
        exit 3
    }
    $script:Listener = $listener
}

function Get-GsConsoleString {
    param([Parameter(Mandatory = $true)][string]$Key)
    $table = Get-GsConsoleStrings
    if ($table.ContainsKey($Key)) { return $table[$Key] }
    return $Key
}

function Invoke-GsConsoleTrayOpen {
    try { Start-Process $script:LaunchUrl | Out-Null } catch { }
}

function Invoke-GsConsoleTrayExit {
    # User-facing Exit: refused while an action is running. Exiting the
    # console never stops the runtime.
    if (Test-GsConsoleJobActive) {
        Show-GsConsoleTrayBalloon -Text (Get-GsConsoleString 'balloon.busy')
        return
    }
    try { $script:StopEvent.Set() } catch { }
}

function Show-GsConsoleTrayBalloon {
    param([Parameter(Mandatory = $true)][string]$Text)
    try {
        $script:Notify.ShowBalloonTip(4000, (Get-GsConsoleString 'tooltip.prefix'), $Text, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
}

function New-GsConsoleTray {
    # Minimal tray icon: Open (re-opens the in-memory launch URL) and Exit.
    # The launch URL (with its #session fragment) exists in memory only.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Application
    $prefix = Get-GsConsoleString 'tooltip.prefix'
    if ($prefix.Length -gt 63) { $prefix = $prefix.Substring(0, 63) }
    $notify.Text = $prefix
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $openItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-GsConsoleString 'tray.open')
    $openItem.add_Click({ Invoke-GsConsoleTrayOpen })
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem (Get-GsConsoleString 'tray.exit')
    $exitItem.add_Click({ Invoke-GsConsoleTrayExit })
    [void]$menu.Items.Add($openItem)
    [void]$menu.Items.Add($exitItem)
    $notify.ContextMenuStrip = $menu
    $notify.Visible = $true
    $script:Notify = $notify
}

function Remove-GsConsoleTray {
    try {
        if ($null -ne $script:Notify) {
            $script:Notify.Visible = $false
            $script:Notify.Dispose()
            $script:Notify = $null
        }
    } catch { }
}

function Invoke-GsConsoleServerLoop {
    # Single-threaded loop with ONE persistent BeginGetContext at a time:
    # a completed context is ended and a fresh one is armed immediately.
    # (Abandoning pending BeginGetContext calls would strand requests in
    # the listener queue: an arriving request completes the OLDEST pending
    # operation, whose wait handle nobody is watching any more.) The tray
    # message loop is pumped via DoEvents on the same thread; job polls are
    # lazy and cheap.
    $startUtc = (Get-Date).ToUniversalTime()
    $async = $null
    try { $async = $script:Listener.BeginGetContext($null, $null) } catch { return }
    while ($true) {
        if ($script:StopEvent.WaitOne(0)) { break }
        if ($null -ne $script:Notify) {
            try { [System.Windows.Forms.Application]::DoEvents() } catch { }
        }
        if ($script:ExitAfterSec -gt 0) {
            $elapsed = ((Get-Date).ToUniversalTime() - $startUtc).TotalSeconds
            if ($elapsed -ge $script:ExitAfterSec) { break }
        }
        $handles = @($async.AsyncWaitHandle, $script:StopEvent)
        $signaled = [System.Threading.WaitHandle]::WaitAny($handles, 200)
        if ($signaled -eq 0) {
            $context = $null
            try { $context = $script:Listener.EndGetContext($async) } catch { $context = $null }
            $async = $null
            try { $async = $script:Listener.BeginGetContext($null, $null) } catch { break }
            if ($null -ne $context) { Invoke-GsConsoleRequest -Context $context }
        }
        Update-GsConsoleJobPoll
    }
}

function Invoke-GsConsoleMain {
    $unsupported = Test-GsConsoleSupportedEnvironment
    if ($unsupported -ne '') {
        Show-GsConsoleStartupFailure -StdErrLine ('CONSOLE-UNSUPPORTED: 64-bit Windows with 64-bit Windows PowerShell 5.1 Desktop is required (check code: ' + $unsupported + ').') -StringKey 'startup.unsupported'
        exit 5
    }
    try {
        Resolve-GsConsoleStartup
    } catch {
        Show-GsConsoleStartupFailure -StdErrLine ('CONSOLE-STARTUP-FAILED: ' + $_.Exception.Message) -StringKey 'startup.startupFailed'
        exit 4
    }
    $script:StopEvent = New-Object System.Threading.EventWaitHandle -ArgumentList @($false, [System.Threading.EventResetMode]::ManualReset)
    Start-GsConsoleListener
    if (-not $NoTray) { New-GsConsoleTray }
    if (-not $NoBrowser) {
        try { Start-Process $script:LaunchUrl | Out-Null } catch { }
    }
    try {
        Invoke-GsConsoleServerLoop
    } finally {
        try { if ($null -ne $script:Listener) { $script:Listener.Stop(); $script:Listener.Close() } } catch { }
        Remove-GsConsoleTray
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Entry point: -DefineOnly (test seam) defines the functions and returns.
# ---------------------------------------------------------------------------
# DefineOnly sessions get safe defaults so pure helpers (capability rules,
# settings validation, DTO projection) are exercisable without a listener.
if ($null -eq $script:Prefs) { $script:Prefs = @{ Revision = 1; Settings = (Get-GsConsoleDefaultSettings) } }
if (-not $DefineOnly) { Invoke-GsConsoleMain }
