# Lifecycle hardening: lock, Recover, Diagnose

Last updated: 2026-10-31

This document describes the hardening added to `product/gs-product.ps1`:
a cross-process mutex around Start / Stop / Recover, the `-Action Recover`
clear-stuck-session flow (including the outbound-traffic gate), the
`-Action Diagnose` wrapper, `-Action PrepareUninstall`, the public output
protocol of those actions, the `tools/gs-soak-monitor.ps1` long-run
stability tool, and the `tests/Invoke-All.ps1` runner. The
runtime itself remains an opaque dependency; nothing here inspects or
changes it.

## Cross-process lifecycle mutex

Start, Stop and Recover serialize through a named system mutex so that two
controllers (a console call and the tray UI, or two consoles) can never run
the runtime scripts for the same state directory at the same time.

### Mutex name (normalized path hashing)

- Mutex name: `Global\GsController.Lifecycle.` + the first 16 hex characters
  of the SHA-256 of the normalized StateDir path. The hex digest is
  lowercase; the path itself is normalized to uppercase before hashing.
- Normalization (function `Get-GsLifecycleLockName`):
  `[IO.Path]::GetFullPath` first (resolves `.` segments and converts `/` to
  `\`), then any remaining `/` are replaced with `\`, trailing separators
  are trimmed, and the result is uppercased. `C:\Gs\State`,
  `C:\Gs\.\State`, `c:/gs/state` and `C:\Gs\State\` therefore all map to the
  same mutex; two different directories still get different mutexes.
- Compatibility note: this normalization changed the derived name compared
  with earlier builds (which only lowercased and trimmed). An old CLI and a
  new CLI running at the same moment derive different names for the same
  state directory and would NOT exclude each other. Deploy old and new
  builds side by side only while a single controller drives the runtime.

### Mutex DACL

The mutex is created with an explicit DACL (function
`New-GsLifecycleMutexSecurity`, applied through the four-argument
`System.Threading.Mutex(bool initiallyOwned, string name, out bool
createdNew, MutexSecurity)` constructor), because the tray (non-admin),
the elevated UAC child and an optionally elevated console must all be able
to open the same mutex regardless of who created it first:

| Identity (well-known SID) | Rights |
|---|---|
| NT AUTHORITY\INTERACTIVE (`S-1-5-4`) | Synchronize, Modify |
| SYSTEM (`S-1-5-18`) | Synchronize, Modify |
| BUILTIN\Administrators (`S-1-5-32-544`) | FullControl |

- Synchronize + Modify is exactly what `WaitOne`/`ReleaseMutex` need.
  FullControl for Administrators lets an elevated reader inspect the DACL
  (READ_CONTROL).
- Well-known SIDs are used instead of account names because account names
  are localized on non-English hosts (this one is zh-CN).
- INTERACTIVE rather than a specific user SID: with over-the-shoulder UAC
  the elevated child can run as a different account than the tray; every
  interactive session carries the INTERACTIVE SID.
- Verified (not assumed): when the mutex already exists and the caller's
  `CreateMutex` fails with ERROR_ACCESS_DENIED, the .NET Framework
  constructor retries with `OpenMutex(MUTEX_MODIFY_STATE | SYNCHRONIZE)`
  - see `CreateMutexHandle` in mscorlib's mutex.cs ("If a mutex with the
  name already exists, OS will try to open it with FullAccess. It might
  fail if we don't have enough access. In that case, we try to open the
  mutex will modify and synchronize access."), confirmed in the
  microsoft/referencesource source. That is why a Synchronize|Modify grant
  is sufficient for a waiter/releaser.
- Verified: per the CreateMutex documentation, the security descriptor is
  applied only when the object is created ("If the lpMutexAttributes
  parameter is not NULL, it determines whether the handle can be
  inherited, but its security-descriptor member is ignored" for an
  existing name), and an existing-name CreateMutex requests
  MUTEX_ALL_ACCESS.
- Assumed (test skipped, see below): that the kernel's mandatory
  integrity policy does not additionally deny a medium-integrity process
  the reduced open on a mutex created by an elevated process. The tests
  read the DACL back and assert the three rules exactly (both from the
  in-process `MutexSecurity` and, elevation-gated, via
  `OpenExisting(name, MutexRights.ReadPermissions)` + `GetAccessControl()`
  on a mutex a real `gs-product` child created while holding the lock),
  but no automated test on this machine can create a real medium-integrity
  process: `runas /trustlevel:0x20000` requires the Secondary Logon
  (seclogon) service and it is stopped here, and the test harness never
  starts services. Both creation orders (elevated creates / medium opens,
  medium creates / elevated opens) are implemented as elevation-gated
  tests that SKIP with that observed reason.

`UnauthorizedAccessException` (or any other open/wait error) still returns
a structured `Errors[0].Code = 'LockFailed'` entry with the exception type
in `Message` and `ExceptionType`; nothing throws unhandled. The `Busy` and
wait-`LockFailed` error entries additionally carry an additive
`CreatedNew` field (whether this call created the mutex). It is not added
to the success `Data` objects: no caller consumes it today and it would
have to be threaded through every Start/Stop/Recover result path.

### Lock semantics (unchanged in this round)

- `-LockTimeoutSec` (int, default 30) is how long a call waits for the
  mutex. `0` means a single try with no wait.
- On timeout the call returns `Success = $false` with
  `Errors[0].Code = 'Busy'`, `Message` =
  `"Another Start/Stop/Recover is in progress for <StateDir>"`, plus
  `LockName` and `TimeoutSec`. The runtime scripts do not run. Callers
  that need to react programmatically should key on the error code `Busy`.
- `AbandonedMutexException` (the previous owner died while holding the
  mutex) means the wait succeeded and we own the mutex: the call proceeds
  and `Data.LockAbandoned = $true` reports it.
- The mutex is always released in a `finally` (also when the runtime script
  throws), then disposed.
- Status, Check and Diagnose never take the lock; reading state must stay
  possible while an operation runs. Install, CreateCatalog,
  RegisterAutostart and UnregisterAutostart are unchanged.

Not covered: the supervisor's own scheduled cycle does not take this mutex.
The supervisor runs inside the runtime bundle, which is a black box, so the
manual-Start-versus-supervisor race from roadmap item 8 is only partly
addressed: manual Start/Stop/Recover calls are mutually exclusive now, but a
supervisor cycle can still run concurrently with them. The stop path still
pauses the supervisor first (the pause flag plus a scheduled-task stop) for
the same reason; the pause flag remains a one-directional hint, not a
synchronisation primitive (see "The supervisor pause flag contract" below).

## Public output protocol for Start / Stop / Recover

The success stream may carry runtime-script output (the deployed scripts
are black boxes and may write to the output stream). The result object is
the LAST element of the output that is an object with a `Success`
property; the tray parses the last element. The test
`Start with script output keeps the result object as the last output
element` (tests/Invoke-LifecycleHardeningTests.ps1) pins this contract.
`-Action Diagnose` uses a stricter variant: the report must be the LAST
output element and must declare `schemaVersion = 1` (see Diagnose below).

## Start / Stop: structured failures

Start and Stop never throw past the action boundary. A missing or throwing
runtime script returns `Success = $false` with
`Errors[0].Code = 'RuntimeStartFailed'` / `'RuntimeStopFailed'` and the
exception message (`ExceptionType` included); a non-zero script exit
returns the same code with `ExitCode` on the error entry. `Data` always
carries `ExitCode` (`$null` when the script threw) and `LockAbandoned`.
`$global:LASTEXITCODE` is reset to 0 before the script runs, so Success
and ExitCode always reflect the current run even when a script ends
without `exit`.

On the stop path the whole preparation runs inside the same guarded
region as the script call: the stop script's own existence is checked
BEFORE any side effect, and validating both pause-flag positions,
creating the canonical pause flag's parent directory, writing the
canonical `supervisor_pause.flag` (only when absent) and
`Stop-ScheduledTask` all map to `RuntimeStopFailed` (with
`ExitCode = $null` and the stop script never having run) when they
fail, instead of throwing past the action boundary. A failed
preparation never leaves a half-applied pause behind.

## The supervisor pause flag contract

The supervisor pause flag exists at TWO locations with distinct roles:

- CANONICAL: `<StateDir>\runtime\state\supervisor_pause.flag`
  (`GsRuntime.psm1` `PauseFlagPath`) - the location the black-box
  supervisor reads according to the public operator documentation
  (docs/remote-client-test.md, section 5). Stop and PrepareUninstall
  write here.
- LEGACY: `<StateDir>\supervisor_pause.flag`
  (`LegacyPauseFlagPath`) - where older product builds wrote the flag.
  It is PRESERVE-ONLY for Stop and Recover: an existing legacy flag
  keeps its exact bytes and is never overwritten or deleted by the
  stop path, and a missing one is not created.

Stop (and PrepareUninstall, which reuses the same stop core):

- The stop script's existence is checked before any side effect; a
  missing script is the structured `RuntimeStopFailed` with
  `ExitCode = $null` and no pause flag, no directory and no script run.
- Both pause positions are validated BEFORE anything is written, so a
  failed preparation never leaves a half-applied pause behind. The
  canonical flag is written only when absent; an existing canonical
  flag keeps its bytes. A pause path that exists but is not a regular
  file (for example a directory) fails the stop with the structured
  `RuntimeStopFailed` before the stop script runs; nothing on these
  paths is ever deleted recursively.
- The flag Stop writes stays until an explicit successful Start clears
  it; Stop and PrepareUninstall never clean it up themselves.

Start (an explicit manual Start IS the operator's resume of the
auto-guard):

- Both positions are snapshotted (existence + exact bytes) BEFORE the
  start runs. An unreadable pause flag - a directory shape, a file
  locked by another process, a permission error - refuses the start
  with Code `PauseSnapshotFailed` BEFORE the runtime start script runs:
  without the bytes neither a restore-on-failure nor a safe cleanup can
  be guaranteed. No new start window is created: the flags are never
  cleared before the start.
- On SUCCESS both positions are cleared (whoever wrote them). A flag
  that cannot be removed fails the result with Code `PauseCleanupFailed`
  (with the flag `Path`) instead of reporting success - a flag left
  behind would keep the supervisor paused after an explicit resume.
- On FAILURE only the PRE-EXISTING positions are restored with their
  original bytes (the runtime start script is known to delete an
  existing pause flag); `RuntimeStartFailed` stays the first error and
  a failed restore appends `PauseRestoreFailed`. A flag that APPEARED
  during the failed start is NOT deleted: it may be the runtime
  deliberately staying paused, and removing it could silently resume
  the supervisor. A failed start never silently loses the previous
  pause state.

Recover is NOT the operator's resume:

- Both positions are snapshotted after the safety gates pass and BEFORE
  any side effect; an unreadable pause flag refuses the recovery with
  Reason `PauseSnapshotFailed` before any runtime script runs.
- After the stop/start, every PRE-EXISTING flag is restored to its
  original bytes - even when the runtime deleted or modified it.
  Exactly one flag is removed: the canonical one THIS recover's stop
  step actually created - the stop core records the creation into the
  recover's operation context AT THE MOMENT it writes the flag, and
  that record survives every failure path inside the core. The LEGACY
  position is never claimed: the stop core never creates a legacy
  flag, so a flag that appears there during the stop was written by
  the black box or by the supervisor (which does NOT take the product
  mutex), and it stays.
- A restore/removal failure in the `finally` appends Code
  `RecoverCleanupFailed` (with `Action` = `restore`/`remove` and the
  flag `Path`; existing errors stay first) and turns a successful
  result into a failure: a stale pause flag would pause the next
  supervisor cycle, and a lost pre-existing pause would silently resume
  it - neither may be reported as success.

Limitations: the pause flag is a one-directional hint, not a
synchronisation primitive. It does not make the supervisor cycle take
the lifecycle mutex, so it remains only a partial answer to the
manual-Start-versus-supervisor race (see "Not covered" above); the
supervisor reads the flag only at the times its black-box cycle logic
chooses. The canonical location is derived from the public operator
documentation, not from the black box's source; if a future runtime
bundle reads a different location, the write path must follow it.

Regression coverage: tests/Invoke-PauseContractTests.ps1 pins the
contract on both positions, the snapshot/restore/cleanup error codes,
the directory-shaped and locked-file edges and the ownership rule;
tests/Invoke-LifecycleHardeningTests.ps1 keeps the end-to-end
Recover/PrepareUninstall coverage.

## Recover

`-Action Recover` clears a stuck GameStream session: the host status says
`ready`, the broker still reports a session (`currentgame = 1`), but no
client is connected. It runs at most one Stop and at most one Start, in that
order, inside a single lock acquisition. No retry: if Stop fails, Start is
not attempted.

Preconditions (all must hold; any check that cannot run refuses the
recovery - fail closed):

1. The runtime status file reports `state = ready` (case-insensitive). The
   status file is looked up in this order:
   `<StateDir>\runtime\state\status.json` first, then
   `<StateDir>\status.json`; when both exist the one with the newer
   `LastWriteTimeUtc` wins. `-Action Status` uses the same lookup. The
   lookup, the read and the JSON parse all happen inside the gate's `try`:
   any failure (missing file, unreadable, malformed) is a
   `StatusUnavailable` refusal, never an unhandled throw.
   The parsed root must be a JSON object and `state` must be a JSON
   string before the `ready` comparison runs: `[string]` coercion would
   quietly accept shapes such as `{"state":["ready"]}` (a one-element
   array), `{"state":5}` or `{"state":{"x":1}}`. Anything else is a
   `NotReady` refusal whose message contains `state field is not a
   string`, and `Observed.StatusState` stays `$null` (no coerced value is
   reported). A parsed-but-wrong root - a JSON array or scalar instead of
   an object - is also `NotReady` (not `StatusUnavailable`): the file was
   found, read and parsed, so the failure is the state field's type, not
   the file's availability.
2. `serverinfo` (plain HTTP only, never the HTTPS 47984 endpoint) returns
   HTTP 200 whose body passes the unified validity rule below and carries
   a `currentgame` of exactly `1`.
   Parameters: `-ServerInfoUri` (default
   `http://127.0.0.1:47989/serverinfo`), `-ServerInfoTimeoutSec`
   (default 3).
3. Zero active client connections: TCP connections in the Established state
   whose local port is in `-ClientPorts` (default 47984, 48010). Port 47989
   is always excluded because the tray UI and Diagnose poll it.
   Connections are enumerated with
   `IPGlobalProperties.GetActiveTcpConnections()` (read-only, no CIM).
4. Outbound-traffic check (new; `-TrafficSampleSec`, default 2; `0`
   disables): when enabled, the host's IPv4 send counters
   (`GetIPv4Statistics().BytesSent`) are sampled over every OPERATIONAL,
   non-loopback adapter, `-TrafficSampleSec` seconds are waited, and the
   counters are sampled again. The rate is the sum of the per-adapter
   `max(0, after - before)` deltas (a counter reset or an adapter that only
   appears in the second snapshot contributes zero), converted to Kbps. A
   rate above `-MaxIdleSendKbps` (default 500, PROVISIONAL - deliberately
   well under a tenth of the ~40 Mbps 4K60 stream bitrate) refuses the
   recovery with reason `ClientTrafficDetected`; the observed rate is
   reported in `Observed.SendKbps` (additive field, `$null` when the gate is
   disabled). The rate function and the gate are separate functions
   (`Get-GsSendKbpsDelta`, `Test-GsClientTrafficGate`); the gate takes an
   optional `-Sampler` scriptblock so automated tests inject counter
   sequences and never touch the real adapters.

Warning - the TCP gate only sees TCP (`Observed.ConnectionCheckScope
= 'TcpOnly'` on every Recover result). GameStream video, audio and
input/control traffic travels over UDP (the 47998-48000 range), and after
the RTSP setup an active Moonlight session may hold no Established TCP
connection on 47984 or 48010 at all. Zero observed TCP connections means
"no client observed over TCP", not "no client confirmed". The
outbound-traffic gate narrows this blind spot (a streaming client moves
megabits per second outbound), but it is still best-effort: other
processes' uploads can also exceed the threshold. When in doubt Recover
refuses - a false refusal wastes one operator attempt, a false recovery
interrupts a live session. Run Recover only when the operator knows that no
client is currently streaming.

On refusal the call returns `Success = $false` with one
`Errors[0]` entry: `Code = 'RecoverRefused'`, a `Reason`, a `Message`, and
`Observed = @{ StatusState; StatusPath; ServerInfoHttp; CurrentGame;
ActiveConnections; ConnectionCheckScope; SendKbps }` (fields that could not
be observed are `$null`; `SendKbps` is `$null` whenever the outbound-traffic
gate is disabled). No stop or start script runs on refusal.

| Reason | Meaning |
|---|---|
| `StatusUnavailable` | No status file, or it cannot be read/parsed |
| `NotReady` | Status has no usable `state`, or `state` is not `ready` |
| `ServerInfoUnavailable` | Request failed, non-200 (including a redirect, which is not followed), or a 200 body that fails the unified validity rule (no `<root>`, status_code not 1-10 digits or not 200, missing or empty `<state>`, a currentgame that is missing or not 1-10 digits, an oversized body, or a body that did not arrive within the deadline) |
| `NoStuckSession` | `currentgame` is present but not `1` (nothing stuck to clear) |
| `ClientConnected` | One or more active client connections were detected |
| `ConnectionCheckFailed` | The port set is invalid (port outside 1-65535), or the remaining check set is empty after excluding 47989 (`no client ports to check`), or the TCP connection enumeration itself failed |
| `ClientTrafficDetected` | The outbound send rate sampled over `-TrafficSampleSec` exceeded `-MaxIdleSendKbps`; recovery was refused in case a client is streaming (the gate is skipped entirely when `-TrafficSampleSec` is 0) |

Invalid ports and a port set that is empty after dropping 47989 are
refusals, never a silent "0 connections": `Get-GsActiveClientConnectionCount`
throws and the gate turns it into `ConnectionCheckFailed`. Validation
happens after the per-port range check and before the 47989 exclusion.

On success `Data` carries `LockAbandoned`, `StopExitCode`,
`StartExitCode` and the `Observed` values. If the Stop step fails the
result is `Success = $false` with `Errors[0].Code = 'RecoverStopFailed'`
(and `RecoverStartFailed` if the start step fails after a successful stop).

Pause-flag handling: BOTH pause-flag positions are snapshotted before
any side effect, every pre-existing flag is restored to its original
bytes after the stop/start (even when the runtime deleted or modified
it), and only the canonical flag this recover's stop step actually
created is removed - Recover is not the operator's resume. The full
contract, including the `PauseSnapshotFailed` refusal and the
`RecoverCleanupFailed` cleanup errors, is specified in "The supervisor
pause flag contract" above.

### serverinfo: one validity rule, enforced in Get-GsServerInfo

A 200 response is valid only when ALL of the following hold; the first
failure becomes the `Error` of `Get-GsServerInfo` and a Recover
`ServerInfoUnavailable` refusal:

- the HTTP status is exactly 200; redirects are NOT followed
  (`$request.AllowAutoRedirect = $false`), so a 302 is reported with
  `Http = 302` and refused - the gate validates the endpoint the operator
  pointed at, not wherever it redirects. The status is checked BEFORE any
  body byte is read, so a 201 (or any other 2xx that does not throw in
  `EndGetResponse`) carrying otherwise valid XML is rejected, never
  parsed - this holds for BOTH readers, the product's
  `Get-GsServerInfo` and the soak tool's `Get-GsSoakServerInfo`;
- the body is at most 65536 bytes, counted in bytes BEFORE UTF-8 decoding
  (a multibyte body over the byte cap but under 65536 characters is
  refused as `BodyTooLarge`); exactly 65536 bytes is still valid (the cap
  is inclusive);
- the document element is named exactly `root`;
- the `status_code` attribute matches `^\d{1,10}$` and equals 200;
- a `<state>` element is present and non-empty after Trim;
- a `<currentgame>` element is present and matches `^\d{1,10}$` after
  Trim (the Recover gate then still requires exactly `1`).

### serverinfo deadline and async abort

`Get-GsServerInfo` is bounded by a TOTAL deadline of
`-ServerInfoTimeoutSec` measured from the request start (a stopwatch).
The response is fetched with `BeginGetResponse` plus a bounded
`AsyncWaitHandle.WaitOne(remaining)` and every body chunk is a
`ReadAsync(...).Wait(remaining)`: on any wait timeout the request is
aborted (`$request.Abort()`) - an abort independent of the framework's
own timeout bookkeeping, which a server that trickles chunk-extension
bytes can keep resetting - and the result carries `Error` beginning with
`'Timeout'`. Responses and streams are closed in `finally`. A body over
the byte cap aborts the request with `'BodyTooLarge: serverinfo body
exceeds 64 KB'`. Recover refuses both with `ServerInfoUnavailable`; the
lock is released afterwards.

## Diagnose

`-Action Diagnose` shells out to `product/gs-diagnose.ps1` for a read-only
report and never takes the lock:

- `-DiagnoseScript` overrides the script path; the default is
  `gs-diagnose.ps1` next to `gs-product.ps1`, resolved in the script body
  because PowerShell 5.1 leaves `$PSScriptRoot` empty in parameter defaults
  under `powershell.exe -File`.
- Missing file: `Success = $false`, `Errors[0].Code =
  'DiagnoseUnavailable'`, `Message = "gs-diagnose.ps1 not found at <path>"`.
  No report is fabricated.
- A script that exits non-zero: `DiagnoseFailed` with `ExitCode` on the
  error entry. `$global:LASTEXITCODE` is reset to 0 right before the script
  runs so the check reflects this run.
- A script that throws: `DiagnoseFailed` with the exception message.
- A script that succeeds must return the report as the LAST output element,
  an object declaring `schemaVersion = 1`. Anything else (no output, a
  plain string, an object without `schemaVersion 1`, trailing non-object
  output) is `DiagnoseFailed` with an "Unexpected report" message - a
  malformed report is never returned as `Data`.

Diagnose is handled BEFORE the module imports (right after the parameter
defaults and the function definitions): the `foreach` loop that imports
GsControl, GsLifecycle and GsRuntime runs only after the Diagnose action
has returned. A broken or missing module manifest therefore cannot stop
the one action an operator needs to investigate a broken install - with
a working `gs-diagnose.ps1` (or an explicit `-DiagnoseScript`), Diagnose
returns its report even when every product module fails to import, and
with no diagnose script at all it returns the structured
`DiagnoseUnavailable` result instead of throwing. All other actions
still require the modules and keep failing at the import when they are
broken.

## Status

`-Action Status` keeps `Code = 'NotInstalled'` when no status file exists.
When a status file exists but cannot be read or parsed, it now returns
`Success = $false` with `Errors[0].Code = 'StatusReadFailed'` and the
`Path` instead of throwing. The status path lookup itself
(`Get-GsStatusFilePath`, moved into the action's `try`) is covered by the
same structured error when it throws. There is no deterministic
real-layout way to make that lookup throw: `Test-Path` returns `$false`
without throwing both for a candidate whose parent is an existing file
and for a candidate longer than 260 characters, and illegal path
characters are already rejected earlier, when the runtime config is
loaded - so that path is tested on the AST-extracted
`Invoke-GsStatusAction` function with a layout that carries an illegal
path character directly.

## Test seams

All new knobs are ordinary parameters with production defaults, so tests
can run without elevation-sensitive side effects:

- `-StopSettleSec` (default 2): the settle sleep inside Stop.
- `-SupervisorTaskName` (default `GsControllerSupervisor`): the scheduled
  task stopped by Stop and removed by PrepareUninstall. An empty string
  skips the `Stop-ScheduledTask` call entirely; every automated test passes
  `''` (the single PrepareUninstall exception passes a unique
  `GsCoordTest-<guid>` name that cannot exist, together with the seam below).
- `-LockTimeoutSec`, `-ServerInfoUri`, `-ServerInfoTimeoutSec`,
  `-ClientPorts`, `-DiagnoseScript` as described above.
- `-AssumeNotElevated` (switch, PrepareUninstall only): forces the elevation
  decision to "not elevated" so the ElevationRequired path is testable from
  an elevated session. The seam can only make the check STRICTER: when set,
  `Test-GsPrepareUninstallElevation` returns `$false` without consulting the
  process token; in every other case the real token decides. No parameter,
  environment variable or script-scoped variable can make a non-elevated
  process count as elevated (pinned by a test that also checks the AST: the
  only constant the decision function returns is `$false`, and the only
  source of `$true` is the `IsInRole` token check).
- `-TrafficSampleSec` (default 2, `0` disables) and `-MaxIdleSendKbps`
  (default 500, provisional): the Recover outbound-traffic gate. Automated
  tests always pass `-TrafficSampleSec 0` (a real sample would make the
  tests depend on the host's live network traffic); the rate math and the
  gate logic are tested on injected counter sequences instead.

## PrepareUninstall

`-Action PrepareUninstall` prepares an uninstall: stop the runtime, remove
the auto-start scheduled task, keep all data. The order is fail closed:

1. Decide first whether a task will be removed at all
   (`-SupervisorTaskName` non-empty). Only when one will be removed is
   elevation required: `Test-GsPrepareUninstallElevation` (one function, so
   the seam is auditable) consults the real process token, unless
   `-AssumeNotElevated` forces the not-elevated outcome. Not elevated =>
   `Success = $false`, `Errors[0].Code = 'ElevationRequired'` (with
   `TaskName`) and NOTHING runs - no layout read, no lock, no stop, no task
   query.
2. `Get-RuntimeLayout` as Start/Stop do, then the lifecycle lock
   (`-LockTimeoutSec`); a lock timeout is the usual `Busy` refusal and
   nothing runs.
3. Inside the lock, the stop-then-remove decision runs in one function,
   `Invoke-GsPrepareUninstallSteps`, which takes the stop and the task
   remover as scriptblock parameters (production passes the real stop core
   `Invoke-GsRuntimeStopCore` and the real task remover; tests pass fakes):
   - "Deployed" means `gs_stop_private.ps1` exists in the layout's
     `RuntimeBinDir` (exactly what the stop needs). Not deployed => the stop
     is SKIPPED and recorded as
     `Data.StopSkippedReason = 'RuntimeNotDeployed'` (additive sixth Data
     field) with `Stopped = $false`; nothing else changes.
   - A failed, result-less or THROWING stop does NOT block task removal - a
     task left behind would keep restarting the stack as SYSTEM after an
     uninstall: a stop op that throws is caught by
     `Invoke-GsPrepareUninstallSteps` and recorded exactly like a failed
     stop (`Errors[0].Code = 'RuntimeStopFailed'` with the exception
     message and `ExceptionType`, `Stopped = $false`), and the removal
     still runs; `Success` stays `$false` and the stop error stays FIRST
     in `Errors`.
   - Task removal goes through one lookup-then-remove decision function,
     `Invoke-GsTaskRemovalOutcome`, whose `-TaskLookup` / `-TaskRemover`
     scriptblock seams default to the real
     `Get-ScheduledTask -ErrorAction Stop` /
     `Unregister-ScheduledTask -Confirm:$false` calls (tests pass fakes;
     the real scheduler is never exercised by a test). Errors SURFACE -
     only the scheduled-task provider's specific "task not found" outcome
     (classified by `Test-GsTaskNotFoundOutcome`: a `CimException` carrying
     `ERROR_FILE_NOT_FOUND` / HRESULT `0x80070002`, or the cmdletization
     framework's `CmdletizationQuery_NotFound` marker) is a confirmed
     absence (`TaskRemoved = TaskExisted = $false`). ANY other lookup
     error - a stopped scheduler service, an RPC or communication failure,
     an access error - is rethrown and appends `Errors[]` entry
     `Code = 'TaskRemovalFailed'` and fails the result; a lookup failure
     can never be reported as a confirmed absence. A found task is removed
     (`TaskRemoved = TaskExisted = $true`); a throwing remover appends the
     same `TaskRemovalFailed` code.
4. StateDir, LogDir and the supervisor pause flags are never deleted:
   `Data.StateDirKept` and `Data.LogDirKept` are always `$true`.

Result `Data`: `{ Stopped; TaskRemoved; TaskExisted; StateDirKept;
LogDirKept; StopSkippedReason }` (the first five are the K5 contract;
`StopSkippedReason` is additive and `$null` unless the stop was skipped).

Not verified tonight: the real `Unregister-ScheduledTask` path. Automated
tests never touch scheduled tasks (the one non-empty-name test uses a unique
`GsCoordTest-<guid>` name plus the `-AssumeNotElevated` seam, so no task
cmdlet can run), so the real task-removal path must be verified by the
operator in a VM: run elevated
`gs-product.ps1 -Action PrepareUninstall -SupervisorTaskName GsControllerSupervisor`
and confirm the task is gone, then `msiexec /x`, then that StateDir and
LogDir are still present. The manual fallback if PrepareUninstall is not
available remains `gs-product.ps1 -Action UnregisterAutostart`.

## Soak monitor tool: tools/gs-soak-monitor.ps1

The long-run stability tool for roadmap item 6 (read-only sampling; it never
starts or stops the runtime in Monitor mode). Docs batch D's
`stability-test-plan.md` cites its example commands; the thresholds' default
values are PROVISIONAL and should be re-tuned after the first real machine
runs.

- `-Mode Monitor` (default): samples every `-IntervalSec` (default 10) the
  runtime status file (both candidates, newest write wins - the same rule as
  the tray), the serverinfo endpoint (own bounded reader enforcing the same
  shared validity rule, 2 s timeout, async wait + Abort), the four role
  processes via `<StateDir>\<role>_pid.json` for broker/nvs/nss/ssau (the
  tolerant PID formats of gs-diagnose) and any `-WatchProcessNames`
  (PID, working set, private bytes, handle count, start time).
  Writes `samples.csv` (row by row, flushed; both outputs are opened
  `FileShare.ReadWrite` so they can be tailed while the run is in progress),
  `events.jsonl` (StateChange, PidChange, WatchProcessSetChange,
  CurrentGameChange, ServerInfoError, Orphan = status says stopped but a
  PID-file process is alive, AvailableAfterQuit, Cycle) and `summary.json`
  in a `finally` block, so Ctrl+C still leaves a summary.
- summary.json fields: `verdict`, `verdictReasons`,
  `memorySlopeMBPerHour` (least-squares slope of the summed tracked private
  bytes), `pidChanges`, `streamTransitions`, `secondsToAvailableAfterQuit`,
  `quitTimeouts` (additive: how many quits never became free within the
  cap), `orphans`, `serverInfoErrors`, `cycleResults`. The summary is
  written in a `finally` that also FINALIZES what an interrupted run
  already finished: the accumulated cycle results and, for Monitor mode,
  the memory slope and the worst quit delay from the accumulators - a
  Ctrl+C mid-run no longer drops completed cycles or observed regression
  data from summary.json.
- "Available after quit" uses the tray's Ready rule: after the first sample
  where a valid currentgame goes non-zero -> 0, serverinfo is probed at
  1 s START-TO-START (the next probe is scheduled one second after the
  previous probe STARTED, not after it finished) until it is valid with
  currentgame 0 AND a `<state>` that does not end in `_SERVER_BUSY` (an
  idle host reports something like `..._SERVER_FREE`), capped at
  `-MaxSecondsToAvailableAfterQuit + 5` s (default threshold 10,
  provisional). EVERY quit outcome is recorded in events.jsonl:
  `AvailableAfterQuit` with the measured delay on success,
  `AvailableAfterQuitTimeout` with the waited time when the cap is reached.
  The summary scalar `secondsToAvailableAfterQuit` is the WORST successful
  delay across the run (a later fast quit cannot hide an earlier
  over-threshold one); a quit that never becomes free increments
  `quitTimeouts` and FAILS the verdict (it can no longer leave the metric
  null and the verdict green).
- `-Mode Cycle`: drives `-ProductPath` through `-Count` (default 10)
  Stop -> Start cycles, waiting each cycle for status ready AND serverinfo
  passing the same shared Ready rule (`Test-GsSoakHostFree`: valid,
  currentgame `0`, state not ending in `_SERVER_BUSY`) - a serverinfo with
  `currentgame = 1` or a `*_SERVER_BUSY` state is not cycle-ready
  (`-CycleReadyTimeoutSec`, default 120), recording
  Success/Code/duration per cycle. WITHOUT `-Execute` it only prints the
  plan and runs nothing. Each product action runs in a hidden child
  powershell.exe (the tray's result-file pattern) with a hard deadline
  (`-ActionTimeoutSec`, default 300); on timeout the child is killed, the
  cycle records `ActionTimeout`, cycling stops, and summary.json is still
  written. The owned action child is killed on EVERY exit path
  (`Stop-GsSoakOwnedProcess` in the action runner's `finally`): a pipeline
  stop (Ctrl+C) while a hanging action is running no longer leaves the
  child alive without its deadline monitor; the kill is awaited with a
  bounded wait and the Process object is disposed. The child's result
  selection takes the LAST output element that has a `Success` property,
  of ANY type (a PowerShell class instance with `Success` is as valid as a
  pscustomobject). A failed Stop ends that cycle without a Start (like
  Recover); other failures do not stop the remaining cycles.
- Verdicts fail on: memory slope above `-MaxMemorySlopeMBPerHour` (default
  50, provisional), PID changes above `-MaxPidChanges` (default 5,
  provisional), any orphan, any quit timeout (see above), an observed
  `secondsToAvailableAfterQuit` above `-MaxSecondsToAvailableAfterQuit`
  (default 10, provisional), any failed cycle, or zero samples. serverinfo
  errors alone do not fail the verdict (environmental).
- `-OutputDir` is mandatory and must be an absolute path OUTSIDE this
  repository (same guard as `client/New-CompatibilityEvidence.ps1`).
  Before the containment compare, reparse points (junctions / directory
  symlinks) along the EXISTING portion of both paths are resolved
  (`Get-GsSoakReparseResolvedPath`): a `%TEMP%` junction targeting this
  repository is lexically outside but physically inside, so the output
  path is rewritten onto the junction target (deepest existing reparse
  ancestor first, bounded hops for nested junctions) and the compare runs
  on the resolved paths - for the tool's directory and for the repository
  root alike. A reparse point whose target cannot be established is
  rejected instead of guessed. The samples.csv `elapsedSec` column is the
  elapsed seconds rounded to 3 decimals.

Example commands (stable; cited verbatim by the docs batch):

    tools\gs-soak-monitor.ps1 -Mode Monitor -DurationMin 30 -IntervalSec 10 -OutputDir C:\gs-evidence\soak
    tools\gs-soak-monitor.ps1 -Mode Monitor -DurationMin 60 -OutputDir C:\gs-evidence\soak -WatchProcessNames powershell
    tools\gs-soak-monitor.ps1 -Mode Cycle -Count 10 -OutputDir C:\gs-evidence\soak
    tools\gs-soak-monitor.ps1 -Mode Cycle -Count 10 -Execute -OutputDir C:\gs-evidence\soak

Tests: tests/Invoke-StabilityToolTests.ps1 (OutputDir guard including
junction-into-repo reparse resolution, plan-only, Cycle
success/Busy/non-zero-exit/ReadyTimeout/ActionTimeout against a fake
product script, cycle readiness under the shared Ready rule, child result
selection across types, quit-outcome tracking (worst delay wins, timeout
fails the verdict, 1 s start-to-start probes), the interrupted-Cycle
summary finalization, slope regression, owned-child kill and PID parser
via AST extraction, and Monitor end-to-end runs with loopback serverinfo
fakes and fake role processes whose PIDs the suite owns).

## Test runner: tests/Invoke-All.ps1

`tests/Invoke-All.ps1` discovers every `Invoke-*Tests.ps1` in a tests
folder and runs each in its own `powershell.exe -NoProfile` child process
(wrapped in `cmd.exe` so the output is captured to temp files) with a
per-test timeout
(`-TestTimeoutSec`, int, validated 1-86400, default 900).

- `-TestsDir <dir>` points the discovery at another folder (default: the
  folder of Invoke-All.ps1 itself, resolved in the script body because
  `$PSScriptRoot` is empty in parameter defaults under
  `powershell.exe -File`). Fixture-based runner tests use this.
- `-Name <substring>` filters by file name. With `-Exact`, `-Name` must
  equal the full file name (`Invoke-PassTests.ps1`) or the base name
  (`Invoke-PassTests`); without it, 'Stage1' would also select
  'Invoke-Stage12Tests.ps1'.
- A test file is an integration test when it is `Invoke-Stage3Tests.ps1`
  or `Invoke-Stage12Tests.ps1`, or when one of its first 30 lines is
  exactly `# GsTestKind: integration`. New suites can opt in with that
  marker line; they do not need to edit the runner.
- Integration tests print `SKIP` with a reason unless
  `-IncludeIntegration` is given, and even then `SKIP` when the session is
  not elevated (they install a real MSI / register a real scheduled task).
- A child that exits non-zero is a FAIL regardless of its Summary line.
  A child that exits 0 while its own `Summary:` line reports failures is
  also a FAIL (`summary reports failures`) - the Summary line is the test
  suites' contract.
- Timeout handling: on timeout the child's whole process tree is killed
  with `taskkill /PID <id> /T /F`, run as a separate Process and awaited
  with a bounded `WaitForExit(10000)`; the taskkill exit code is
  recorded. A taskkill that is itself still running after 10 s is killed
  and the test is marked `KillFailed`. Then the child is awaited with a
  bounded `WaitForExit(10000)`.
  `timed out after Ns (child killed)` is only printed once the kill is
  confirmed. If the child still has not exited, the test is marked
  `FAIL ... :: KillFailed (pid N survived taskkill /T /F ...)` and the
  runner does not block on it.
- Captured output: each child runs as
  `cmd.exe /d /c ""powershell.exe" -NoProfile -ExecutionPolicy Bypass
  -File "<test>" > "<temp>.out" 2> "<temp>.err""`, so the output lives in
  temp FILES and no pipe has to be drained - a detached grandchild that
  survives the kill cannot block the runner on a read, and the exit code
  still comes from the powershell test process through cmd. Only the
  last 256 KB of each file are read back (opened with `FileShare
  ReadWrite|Delete`, so the read works even while a surviving descendant
  still holds the file open), both for the `Summary:`/FAIL parsing and
  for the saved full-output log. The temp files are deleted afterwards;
  a delete that fails because a survivor still holds the file is
  reported as `     child output file kept: <path>` so the file can be
  removed once the survivor is gone. The Process is disposed in a
  `finally`.
- Everything from starting a suite's child to writing its log is guarded
  by try/catch: a process-start or log-write failure is a FAIL for that
  suite alone and the final Total line still prints.
- Per test it prints PASS/SKIP/FAIL, the file, the child exit code, its
  `Summary:` line and the duration; on FAIL it also prints the child's
  `FAIL` lines and writes the full output to a temp log.
- Final line: `Total: X passed, Y skipped, Z failed`. Exit code 1 only when
  something failed or no test file was found; skips alone exit 0.

Not covered (Job Object): the runner does not put the child in a Win32 Job
Object with KILL_ON_JOB_CLOSE, which would guarantee the whole descendant
tree dies together. It was skipped deliberately: the assignment happens
after the child has started, so a grandchild spawned in that window is
missed (the race the grandchild fixture actually exercises), nested-job
behavior depends on the caller already being inside a job, and the Add-Type
P/Invoke surface is disproportionate to the bounded-wait fallback above,
which already guarantees the runner cannot hang.

Not covered (cross-integrity): the mutex DACL's behavior across integrity
levels is implemented as elevation-gated tests (both creation orders,
file-based signaling, hard deadlines, kill only by recorded PID), but on
this build they SKIP because `runas /trustlevel:0x20000` needs the
Secondary Logon (seclogon) service and it is stopped; the harness never
starts services.
