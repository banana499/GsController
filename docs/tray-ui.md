# Tray / Status UI

Last updated: 2026-11-01 (stopping transition grace period 300 s; the pending finish decision reports an available result or exit before the wait cap)

A minimal notification-area icon that mirrors the product runtime state and
offers Start / Stop through the existing product CLI (`gs-product.ps1`). It
is plain PowerShell + Windows Forms: no compiled EXE, no console window, no
services, no scheduled tasks of its own. The tray contains no lifecycle
logic of its own - every Start/Stop/Recover goes through the CLI, which owns
the lifecycle lock (`Busy` is returned only while another Start/Stop/Recover
holds that lock - never simply because the stack is running). The tray
shows six states: the five the product spec describes (Stopped, Starting,
Ready, Streaming, Error) plus a sixth, **Stopping** (orange icon), so that
a status of `stopping` - or a pending Stop - never shows the Stopped icon
with Start enabled while the runtime is on its way down.

界面文字为中文（K4）：所有菜单、提示、气泡和状态对话框的文字都来自外部字符串表
`product/gs-tray-strings.zh-CN.json`；表缺失或无效时回退到内置英文表并写日志。
托盘日志（tray.log）保留英文状态名和详情。

## Files

| File | Purpose |
|---|---|
| `product/gs-tray.ps1` | WinForms NotifyIcon host (run with `-STA`) |
| `product/gs-tray-model.ps1` | Dot-sourceable model: status file resolution/read, serverinfo fetch/parse, state mapping, child command builder, result parser, string table, menu/balloon/notification helpers (no WinForms types) |
| `product/gs-tray-strings.zh-CN.json` | Chinese string table (UTF-8 **without BOM**; a BOM-prefixed file is accepted by stripping the BOM) |
| `product/gs-tray.vbs` | Launcher: runs the tray hidden, without a console window |
| `tests/Invoke-TrayUiTests.ps1` | Unit tests (no admin, no real tray, loopback only) |

All three `product/gs-tray*` files are expected to be installed next to
`gs-product.ps1` in the product folder (default
`C:\Program Files\Local Development\GsController`).

## Starting the tray

```text
wscript.exe "C:\Program Files\Local Development\GsController\gs-tray.vbs"
```

(or double-click `gs-tray.vbs` in the product folder). The `.vbs` runs:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "<folder of the .vbs>\gs-tray.ps1"
```

with window style 0 and `bWaitOnReturn = False`, so no console window ever
appears. Only one instance runs at a time (named mutex
`Local\GsController.Tray`); a second start exits silently.

### Optional: start the tray at logon

Create a shortcut yourself in your Startup folder (`Win+R` -> `shell:startup`)
with this target:

```text
wscript.exe "C:\Program Files\Local Development\GsController\gs-tray.vbs"
```

The product and the tray never create Startup shortcuts themselves.

### Tray parameters (for smoke runs; defaults are automatic)

| Parameter | Default | Meaning |
|---|---|---|
| `-ProductPath` | `gs-product.ps1` next to `gs-tray.ps1` | CLI to call for Start/Stop |
| `-StateDir` | `%ProgramData%\Local Development\GsController` | Where the status file is looked up |
| `-LogDir` | `%ProgramData%\Local Development\GsControllerLogs` | Folder opened by "Open logs" |
| `-ServerInfoUri` | `http://127.0.0.1:47989/serverinfo` | Plain HTTP only, never HTTPS 47984 |
| `-PollMs` | `2000` | Poll interval in milliseconds |
| `-TrayLogDir` | `%LOCALAPPDATA%\GsController\tray` | Tray log and CLI result files |
| `-ExitAfterSec` | `0` (run until Exit) | Auto-exit, for smoke runs only |

## Menu（菜单）

| 菜单项 | 行为 | 何时可用 |
|---|---|---|
| 启动 | 隐藏子进程 `powershell.exe` 运行 `gs-product.ps1 -Action Start` | 状态行允许 Start 时；有待完成操作时禁用 |
| 停止 | 隐藏子进程运行 `-Action Stop` | 状态行允许 Stop 时；有待完成操作时禁用 |
| 状态 | 状态对话框（中文标签）：托盘状态、详情、待执行操作、状态文件路径（存在/缺失）、状态错误码、上次 CLI 结果、托盘日志路径 | 始终可用 |
| 恢复卡住的会话 | 先弹确认框（会中断正在串流的客户端），确认后运行 `-Action Recover` | 仅"串流中"状态且没有待完成操作时可用 |
| 生成支持包 | 以普通（不提权）隐藏子进程运行同目录的 `gs-support.ps1`，读取 K1 结果；成功后打开资源管理器并定位 zip。托盘本身以管理员运行时：不启动任何子进程，直接弹出固定原因的支持包失败气泡 | 没有待完成操作时始终可用（与运行时状态无关） |
| 打开日志 | 打开 `-LogDir`（不存在则打开托盘日志目录） | 始终可用 |
| 退出 | 停止后台抓取（只发停止信号，从不等待），释放图标，结束消息循环 | 始终可用 |

规则由模型层的纯函数 `Get-GsTrayMenuEnabled` 决定：任何待完成操作（Start/Stop/Recover/
生成支持包）会把四项全部禁用；Recover 只在 Streaming（串流中）行启用——恢复会中断正在串流的客户端。

## UAC behavior for Start / Stop / Recover

- If the tray itself runs **elevated**, the CLI child starts hidden and
  silently.
- If the tray runs **non-elevated**, each Start/Stop/Recover launches the
  child with `-Verb RunAs`, so Windows shows one UAC prompt per action.
  Cancelling the prompt (Win32 error 1223) is logged and shown as a balloon;
  the tray keeps running.
- The tray never elevates itself. The **support bundle is different**: it
  runs as a plain hidden child (never `-Verb RunAs`), so a non-elevated
  tray produces a non-elevated support child. If the tray itself runs
  elevated, the support item launches **nothing**: the child would inherit
  the tray's elevation, so the tray shows the fixed support-failure balloon
  (`support.elevatedRefused`, Chinese UI text, English log line) and no
  attempt is made to obtain a non-elevated token. The elevation check is an
  injectable function (`$script:IsTrayElevated` in the host, probing
  `Test-GsTrayElevated`); the both-branches decision lives in the model
  (`Resolve-GsTraySupportLaunch`).

CLI results arrive via a result file
`%LOCALAPPDATA%\GsController\tray\results\<guid>.json`; the child writes the
serialized CLI object there (or `{Success=$false; Errors=@({Code='CliException'})}`
if the CLI throws). The write is best effort: if it fails, the missing or
invalid file is reported as `NoResult`. The tray reads the file once and
deletes it; leftover result files are removed at tray startup. A `Busy`
result shows the balloon "Another lifecycle operation is running." The
child's `Process` object is disposed as soon as the decision is made (result
read or wait cap expired). The finish decision checks the outcome before the
clock: an available result file or a known-exited child is reported as the
real result even when the wait cap has already expired - only a child with
no result and no known exit is cut off by the cap. If the child has not
finished after 300 seconds the tray stops waiting and unlocks the menus; the
child keeps the lifecycle lock, so later calls get `Busy` from the CLI
itself.

## Permissions

The host has tightened ProgramData ACLs. The tray runs as the logged-on user
and never changes any ACL. If the user cannot read `status.json`, the tray
shows **Error** ("Status file unreadable") and Start remains available;
running Start from an elevated prompt is the intended recovery. The child CLI
launched through UAC runs elevated and can read/write what the product needs.

## Chinese string table（中文字符串表，K4）

- 文件：`product/gs-tray-strings.zh-CN.json`，扁平的 JSON 对象（键 -> 文本），UTF-8 **无 BOM**。
  读取方式是 `[IO.File]::ReadAllText(path, [Text.Encoding]::UTF8)`。
- **BOM 决定**：文件开头若带 UTF-8 BOM（U+FEFF），会被剥掉后照常接受（记事本"带 BOM 的 UTF-8"保存
  也能用），绝不会因此崩溃或回退。
- 模型层函数（皆不抛异常）：
  - `Get-GsTrayStrings -Path`：加载并校验字符串表，返回 `{ Source; Path; FallbackReason; Strings; KeyCount }`。
    以下任一问题都回退到内置英文表并记录原因：没有路径、文件缺失、读不出、为空、JSON 无效、不是 JSON
    对象、某个值不是非空字符串、缺键、多键、某个键的占位符个数与英文表不一致。资源上限（第 4 轮加固）：
    文件大于 64 KB（65536 字节）在**读取/解析之前**直接拒绝；任何值最长 512 字符；占位符必须是纯 `{N}`
    （花括号内只有数字——`{0,999999}` 这类对齐子句、`{0:X}` 这类格式子句和多余花括号都拒绝），且每个
    占位符索引必须小于该键期望的占位符个数。这样格式化永远不可能在 UI 线程上分配无上界的输出。
  - `Format-GsTrayText -Strings -Key -Arguments`：按 `{0}`/`{1}` 占位符格式化；键不存在回退英文；格式化
    出错重试英文模板，再不行返回原模板，最后返回键名本身。
  - `Get-GsTrayStateName -Strings -State`：状态显示名翻译（未知状态原样返回）。
  - `Get-GsTrayDetailText -Strings -StateRow`：翻译状态行的 DetailKey/DetailArgs，并**在翻译之后**按 63
    字符上限截断（`NotifyIcon.Text` 的限制按字符数计）。
- 状态行（`New-GsTrayStateRow`）新增 `DetailKey` 和 `DetailArgs`：界面层负责翻译；英文 `Detail` 保留，
  用于 tray.log 和 CLI 诊断（例如未知状态行的 DetailKey 是 `detail.unknownState`，DetailArgs 携带原始值）。
- 内置英文表（`Get-GsTrayBuiltinStrings`）与中文表键完全一致、每个键的占位符个数一致，两者都由
  `Get-GsTrayStrings` 校验、由单元测试断言。
- 托盘启动时加载字符串表并写一行日志：`Strings: zh-CN table loaded (N keys).`，或
  `Strings: falling back to built-in English table: <原因>`。
- 状态名对照：已停止、正在启动、正在停止、就绪、串流中、错误。

## Recover（恢复卡住的会话，K3）

`-Action Recover` 只在"串流中"（Streaming）且没有待完成操作时可点。点击后先弹确认框
（MessageBox Yes/No，警告图标），明确说明：如果客户端正在串流，此操作会中断它；确认后才通过隐藏子进程
调用 CLI。取消则只写日志、不做任何事。

结果气泡（全部中文，来自字符串表）：

| CLI 结果 | 气泡 |
|---|---|
| Success | 卡住的会话已恢复。 |
| `Code='RecoverRefused'` + `Reason='StatusUnavailable'` | 无法读取状态文件，恢复已拒绝 |
| `Reason='NotReady'` | 运行时未处于就绪状态，恢复已拒绝 |
| `Reason='ServerInfoUnavailable'` | 无法获取有效的 serverinfo，恢复已拒绝 |
| `Reason='NoStuckSession'` | 没有检测到卡住的会话（currentgame 不是 1），无需恢复 |
| `Reason='ClientConnected'` | 检测到客户端连接；为避免中断串流，已取消恢复 |
| `Reason='ConnectionCheckFailed'` | 客户端连接检查失败，恢复已拒绝 |
| `Reason='ClientTrafficDetected'`（为 C5 预留） | 检测到客户端流量；为避免中断串流，已取消恢复 |
| 未知 Reason（或空 Reason） | 恢复被拒绝（未知原因）：\<原始 Reason\>（空 Reason 时显示原始 Code） |
| `Code='Busy'` | 另一个生命周期操作正在进行。 |
| `RecoverStopFailed` / `RecoverStartFailed` / `RecoverCleanupFailed` | 各自的"恢复失败：…"气泡 |
| 其他未知 Code | "{0} 失败（{1}）。"，显示原始 Code |

结果解析器（`Read-GsTrayCommandResult`）新增了附加字段 `Reason`（`Errors[0].Reason` 为字符串时给出，
否则为空字符串）——拒绝原因靠它传给映射函数。未知的原因或代码只显示原文，托盘永不崩溃。

## Support bundle（生成支持包，K1/K3）

- 菜单项运行**同目录**的 `gs-support.ps1`：普通隐藏子进程 `powershell.exe`（`-EncodedCommand`），
  **从不**走 UAC/-Verb RunAs（支持包是只读诊断）。
- **托盘本身提权（管理员运行）**：不启动任何子进程。托盘写英文日志
  `Support bundle refused: ElevatedTray - the tray process itself is elevated and the support bundle never runs elevated (K3).`
  并弹出固定原因的失败气泡（`support.elevatedRefused`，中文）；托盘不会尝试获取非提权令牌。
  提权检查是可注入的（宿主里的 `$script:IsTrayElevated`，探测 `Test-GsTrayElevated`），分支判定在模型层
  （`Resolve-GsTraySupportLaunch`），两个分支都有单元测试。
- 传入 `-InstallDir`（托盘所在目录）、`-StateDir`、`-LogDir`、`-TrayLogDir`、`-ServerInfoUri`。
- 子进程捕获 gs-support.ps1 的全部输出，取**最后一个 `schemaVersion -eq 1` 的元素**写入结果文件（与 CLI
  结果文件同一模式；没有合格的元素则合成 `Success=$false, Code='NoSchemaResult'`；脚本抛异常则是
  `Code='CliException'`；子进程永远 exit 0）。
- 结果成功（`Success=$true` 且有 `ZipPath`）：用 `explorer.exe /select,"<zip>"` 打开资源管理器并定位文件，
  气泡"支持包已生成：\<zip\>"。
- 结果失败：按 K1 错误码映射中文气泡——`DiagnoseUnavailable`、`DiagnoseFailed`、`RedactionCheckFailed`、
  `OutputDirInvalid`、`ZipFailed`、托盘提权拒绝（`support.elevatedRefused`）；`NoResult`（没有可用结果文件）
  有自己的气泡；未知错误码显示原文。失败结果的错误码缺失（`Errors[0]` 没有可用的字符串 `Code`）时按
  `NoResult` 处理（显示"没有可用的结果"气泡），绝不会误显示空代码对应的成功气泡。
- 脚本缺失：`Test-Path` 检查后直接气泡"支持包工具未安装"，不启动子进程。
- 结果文件解析（`Read-GsTraySupportResult`）：缺失/为空/JSON 无效/`Success` 不是布尔值/`schemaVersion`
  不是 1，都报告 `Code='NoResult'`。

## Notifications and supervisor pause（通知与自动守护暂停提示，B3）

- `Get-GsTrayNotification -Strings -Confirmed -Previous -Current [-Paused] [-PausedSuffix]` 是纯函数：
  只有当新状态连续两次轮询一致（`Current -eq Previous`）并不同于上一次**确认**的状态时才算切换；
  就绪 -> 串流中提示"串流已开始"，串流中 -> 就绪提示"串流已结束"，其他转换、首轮轮询、单次轮询的抖动
  一律不提示。
- 两个暂停标志路径 `<StateDir>\supervisor_pause.flag` 或 `<StateDir>\runtime\state\supervisor_pause.flag`
  任意一个存在时（`Test-GsTrayPauseFlag`，只用 `Test-Path`，从不删除标志）：
  - 气泡文字追加"（自动守护已暂停）"；
  - 悬停提示（tooltip）= 字符串表前缀（`GsController：`）+ 翻译后的详情（+ 暂停后缀）。预算分配
  （第 4 轮加固）：**前缀和暂停后缀先预留**，详情截断到剩余空间，总长 ≤ 63 字符；暂停时后缀始终保留，
  不会因为长详情占满预算而被整体截掉。托盘启动时的初始 tooltip 也走同一个合成函数
  （`Get-GsTrayTooltipText`），不会绕过 63 字符上限。

## State mapping

The tray polls the status file every 2 seconds. Candidates, in order:
`<StateDir>\runtime\state\status.json`, then `<StateDir>\status.json`; use
whichever exists, and when both exist the newer `LastWriteTimeUtc` wins.
Only the `state` field is read; the file's contents are never logged.

While an action is pending both menu items are disabled: a pending Start
shows the state `Starting` with detail `Starting...`, and a pending Stop
shows the state `Stopping` with detail `Stopping...` whatever the status
file says. A status value of `stopping` maps to the same Stopping state -
only `stopped`/`paused`/`idle` map to Stopped.

A transition status is only trusted while its status file is fresh. If the
status state is `stopping` (or `starting`/`launching`/`initializing`) and
the file has not been written for longer than the transition's grace
period, the transition counts as dead: the tray shows **Error** with detail
`Stopping did not finish` / `Starting did not finish` and re-enables both
actions, instead of locking both menu items forever. The grace period is
300 seconds for `stopping` - the same cap as the tray's own pending-action
wait, because a real official-service Stop measured 138-142 seconds (see
troubleshooting.md) - and 120 seconds for the starting/launching/
initializing family. Exactly at the grace period the transition is still
fresh - only files strictly older than that count as stale. A pending
Start/Stop still overrides as below.

| Status file | serverinfo (only fetched when ready/running) | Tray state | Detail | CanStart | CanStop |
|---|---|---|---|---|---|
| pending Start | any | Starting | `Starting...` | no | no |
| pending Stop | any | Stopping | `Stopping...` | no | no |
| missing | not fetched | Stopped | `Stopped (no status file)` | yes | no |
| unreadable | not fetched | Error | `Status file unreadable` | yes | yes |
| invalid JSON / no state field | not fetched | Error | `Status file invalid` / `Status file has no state field` | yes | yes |
| `state` not a string (number/bool/array/object) | not fetched | Error | `Status file has no valid state field` | yes | yes |
| `ready` or `running` | HTTP 200, valid body, protocol 200, `currentgame` non-empty and not `0` | Streaming | `Streaming` | no | yes |
| `ready` or `running` | HTTP 200, valid body, protocol 200, state ends `_SERVER_BUSY` | Streaming | `Streaming` | no | yes |
| `ready` or `running` | HTTP 200, valid body, protocol 200, no game, `_SERVER_FREE` | Ready | `Ready` | no | yes |
| `ready` or `running` | unreachable, timed out, or non-200 HTTP | Error | `runtime ready but serverinfo unreachable` | yes | yes |
| `ready` or `running` | HTTP 200 but body invalid (not XML, wrong root name, missing/empty fields, non-digit `currentgame`, missing/over-long/non-200 `status_code`, truncated/oversized body) | Error | `runtime ready but serverinfo invalid` | yes | yes |
| `starting` / `launching` / `initializing`, file fresh (at most 120 s old) | not fetched | Starting | `Starting...` | no | yes |
| `starting` / `launching` / `initializing`, file older than 120 s | not fetched | Error | `Starting did not finish` | yes | yes |
| `stopped` / `paused` / `idle` | not fetched | Stopped | `Stopped` | yes | no |
| `stopping`, file fresh (at most 300 s old) | not fetched | Stopping | `Stopping...` | no | no |
| `stopping`, file older than 300 s | not fetched | Error | `Stopping did not finish` | yes | yes |
| `failed` / `error` | not fetched | Error | `Runtime reports failed` / `Runtime reports error` | yes | yes |
| anything else | not fetched | Error | `unknown state <value>` | yes | yes |

All comparisons are case-insensitive; details are truncated to the 63
character tooltip limit. Error rows enable both actions: the tray cannot know
the real runtime state after an error, Start covers the common recovery, and
Stop covers the case where the streamer is up but hung (ready yet unreachable
or invalid). `Busy` appears only when another Start/Stop/Recover already
holds the CLI's lifecycle lock - not merely because the stack is running.
Icon colors: Stopped gray, Starting yellow, Stopping orange, Ready green,
Streaming blue, Error red.

## serverinfo validity

`serverinfo` counts only when **all** of the following hold - the same
unified rule is applied by the XML parser and the fetch:

- The HTTP transport status is **exactly 200**; redirects are never followed
  (`AllowAutoRedirect` stays `$false`), so a 302 is reported with status 302
  and never becomes Ready - its `Location` target is not contacted.
- The body parses as XML whose **root element is named exactly `root`**
  (case-sensitive: `<foo>` or `<ROOT>` is invalid).
- The root's `status_code` attribute matches `^[0-9]{1,10}$` **and equals
  200** (any other value - including 503 - fails; the parsed value is still
  reported as `ProtocolStatus`).
- The `<state>` element exists with non-empty trimmed content.
- The `<currentgame>` element exists whose trimmed content matches
  `^[0-9]{1,10}$` (so at most ten digits; ` 1 ` is valid and read as `1`).

The body is read as raw bytes and **capped at 65536 bytes counted before
decoding** (exactly 65536 bytes is still valid), then decoded as UTF-8 - a
multibyte body can be far over the byte cap while staying far under 65536
characters, which is why the cap counts bytes.

The fetch never blocks on a misbehaving server. The response phase waits
through `BeginGetResponse` plus `AsyncWaitHandle.WaitOne(remaining)` and the
body read awaits every chunk through `stream.ReadAsync(...).Wait(remaining)`;
on any wait timeout the request is aborted (`HttpWebRequest.Abort`) and the
result is HTTP status 0 with `ParseOk=$false` and a timeout `ParseError`
(`serverinfo request timed out` / `serverinfo read timed out`). The fetch is
therefore hard-bounded to about the fetch timeout per phase (connect, read),
no matter whether the server never answers, trickles bytes, or stops
mid-body. Anything else maps to `runtime ready but serverinfo invalid`
(HTTP 200) or `runtime ready but serverinfo unreachable` (no answer or
non-200 HTTP).

## Polling

- Every 2 seconds (`-PollMs`) the tray re-reads the status file from disk -
  nothing is cached, so a changed status file is reflected within one tick
  (the roadmap's 2-second acceptance).
- `serverinfo` is fetched only when the status file says `ready`/`running`,
  with a 1 second timeout (default); when the status is down/stopped there
  is no HTTP call at all. The fetch never runs on the UI thread: each poll
  tick harvests the previous background fetch (at most one in flight, on a
  background runspace) and starts a new one, and a completed result older
  than 6 seconds counts as missing (i.e. "unreachable").
- The fetch is hard-bounded per phase by the async waits described under
  serverinfo validity: a server that never answers, trickles bytes, or
  stops mid-body is aborted at the fetch timeout instead of hanging the
  background engine.
- On Exit (and when the message loop stops for any reason) the tray never
  waits for an in-flight fetch: the background engine is only signalled to
  stop (`BeginStop` without waiting) and the fetch aborts itself at its own
  timeout, so the tray always exits promptly.

## Logs

| What | Where |
|---|---|
| Tray log | `%LOCALAPPDATA%\GsController\tray\tray.log` (rotated to `tray.log.1` at 1 MB); every state change, CLI/support launch/result, cancelled UAC prompt, declined Recover confirmation, transition notification, the string-table load/fallback line (`Strings: ...`), and every exception (timer tick, menu handler, `Application.ThreadException`, `AppDomain.UnhandledException`) is logged; no raw exception dialogs are shown |
| CLI result files | `%LOCALAPPDATA%\GsController\tray\results\<guid>.json`, deleted after reading |
| Product logs | `%ProgramData%\Local Development\GsControllerLogs` (opened by "Open logs") |

## Known limits

- The status file stays authoritative: a missing status file shows Stopped
  even if `serverinfo` answers, because port 47989 may belong to another
  streamer on the host.
- The `serverinfo` fetch runs on a background runspace (never the UI
  thread) and is hard-bounded to about the fetch timeout per phase by the
  async waits plus `HttpWebRequest.Abort`; on tray exit an in-flight fetch
  is only signalled to stop, never waited on, and when the runtime is not
  ready/running there is no HTTP call.
- Only `ready` is documented for `status.json`'s `state` field. Other values
  are mapped best-effort (`starting`/`launching`/`initializing`,
  `stopping`, `stopped`/`paused`/`idle`, `failed`/`error`) and anything
  unknown shows Error with `unknown state <value>`.
- `Streaming` relies entirely on `serverinfo` (`currentgame` or a
  `_SERVER_BUSY` state); there is no other session signal. If the streamer
  port is blocked locally or the answer is malformed, a ready runtime shows
  Error ("runtime ready but serverinfo unreachable" or "...invalid").
- The tray shows state only while it runs; it does not restore itself after
  reboot unless you add the Startup shortcut yourself (command above).
- Status updates stop while a Start/Stop child runs (menus disabled, state
  `Starting`/`Stopping`); they resume from fresh disk reads when the child
  exits.
