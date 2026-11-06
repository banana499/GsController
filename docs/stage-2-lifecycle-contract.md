# 阶段 2 生命周期契约：GsLifecycle 模块

本文档记录阶段 2 的公开接口、状态机、持久化格式与限制。实现位于 `src/GsLifecycle/`，测试入口为 `tests/Invoke-Stage2Tests.ps1`。运行环境为 Windows PowerShell 5.1，不依赖外部模块。

## 1. 模块

- 清单：`src/GsLifecycle/GsLifecycle.psd1`（ModuleVersion `0.2.0`，PowerShellVersion `5.1`）
- 根模块：`src/GsLifecycle/GsLifecycle.psm1`，加载时导入 `src/GsControl/GsControl.psd1` 以复用 `Resolve-GsPath`。
- 导出函数见第 2 节，其余函数为内部函数，不属于契约。
- 模块不包含任何服务、进程、注册表、驱动或网络操作。所有系统操作由调用方以脚本块注入（第 5 节）。

## 2. 公开函数

所有函数对预期内的问题（配置错误、非法迁移、损坏状态、回调失败（含回调中的 `break`/`continue`/`exit`）、写入失败、锁被占用）不抛异常，返回结构化结果。只有 `Read-GsInstallationConfig` 的 `-Path` 为空或非法时，沿用阶段 1 行为抛出 `System.ArgumentException`。

### Test-GsInstallationConfig

```powershell
Test-GsInstallationConfig [-InstallDir <object>] [-StateDir <object>] [-LogDir <object>]
```

不访问文件系统、不创建目录。返回 `Success`、`Path`（恒为 `$null`）、`Config`（`InstallDir`、`StateDir`、`LogDir`，仅成功时非空）、`Errors`（每项 `Code`、`Field`、`Message`）。

| Code | Field | 触发条件 |
|------|-------|----------|
| `EmptyPath` | `installDir` / `stateDir` / `logDir` | `$null`、空字符串或纯空白 |
| `InvalidType` | 同上 | 不是字符串 |
| `InvalidPath` | 同上 | `Resolve-GsPath` 拒绝（非法字符、`C:foo`、`\foo`、`HKLM:\...` 等） |
| `NotAbsolute` | 同上 | 相对路径（如 `app`、`.\x`、`..`） |
| `SameDirectory` | `a,b` | 两个目录规范化后相同（忽略大小写与结尾分隔符） |
| `NestedDirectory` | `a,b` | 一个目录位于另一个之内（按路径段比较，`C:\a` 与 `C:\a2` 不算嵌套） |

所有错误一次全部列出。路径规范化完全由 `Resolve-GsPath` 完成：同一输入分别以两个不同 `BasePath` 解析，结果一致即为绝对路径。

### Read-GsInstallationConfig

```powershell
Read-GsInstallationConfig [-Path] <string>
```

返回结构与 `Test-GsInstallationConfig` 相同，`Path` 为规范化后的文件路径。文件格式（UTF-8，有无 BOM 均可，允许其他顶层字段）：

```json
{ "schemaVersion": 1, "installDir": "C:\\...", "stateDir": "C:\\...", "logDir": "C:\\..." }
```

额外错误码：`FileNotFound`、`ReadFailed`、`InvalidJson`（空文件或解析失败）、`InvalidType`（根不是对象，Field 为 `''`；`schemaVersion` 非整数）、`MissingField`、`UnsupportedValue`（`schemaVersion` ≠ 1）。

### Get-GsLifecycleTransitionTable

```powershell
Get-GsLifecycleTransitionTable
```

返回迁移表的副本（有序哈希表 `State -> string[]`），修改副本不影响模块。

### Test-GsLifecycleTransition

```powershell
Test-GsLifecycleTransition -From <string> -To <string>
```

纯函数。返回 `Allowed`、`From`、`To`、`Code`（`Ok` / `UnknownState` / `IllegalTransition`）、`Message`。状态名区分大小写。


### Get-GsLifecycleState

```powershell
Get-GsLifecycleState -Config <object>
```

只读，从不写状态文件。返回 `Success`、`Code`（`Ok` / `InvalidConfig` / `StateDirectoryMissing`）、`Source`、`State`（`State`、`ChangedAtUtc`、`Error`）、`Interrupted`、`Path`、`Errors`。

| Source | 含义 | State |
|--------|------|-------|
| `Default` | 状态文件不存在 | `Stopped`，`ChangedAtUtc` 为 `$null` |
| `File` | 文件有效 | 文件中的状态 |
| `Corrupt` | 文件内容无效（第 4.3 节） | `Failed`，错误码 `StateCorrupt` |
| `ReadFailed` | 文件存在但无法读取（被独占锁定、ACL 拒绝读取） | `Failed`，错误码 `StateReadFailed` |

损坏或无法读取的状态一律报告为 `Failed`，不会报告为 `Running`。

`Interrupted`：状态为 `Starting` 或 `Stopping` 时，函数短暂尝试获取状态目录锁以判断是否有调用正在进行：

| 值 | 含义 |
|----|------|
| `$true` | 无人持有锁，且重新读取后仍为 `Starting`/`Stopping`：上一次调用已中断（第 6 节） |
| `$false` | 状态不是 `Starting`/`Stopping`，或锁被持有（调用正在进行） |
| `$null` | 无法探测锁（`AccessDenied` / `LockFailed`） |

`Get-GsLifecycleState` 只报告中断，不修复；修复由下一次 `Start-GsLifecycle` / `Stop-GsLifecycle` 完成。

### Invoke-GsLifecycleTransition（低层接口）

```powershell
Invoke-GsLifecycleTransition -Config <object> -To <string> [-ErrorCode <string>] [-Diagnostics <object>]
```

所有状态写入共用同一套内部逻辑（配置校验 → 状态目录锁 → 读取当前状态，损坏时先持久化 `Failed` → 查表 → 原子写入）。`Invoke-GsLifecycleTransition` 是这套逻辑面向“无需系统操作”的迁移的公开入口：

- 只允许直接写入 `Failed` 和 `Paused`。
- `Starting`、`Running`、`Stopping`、`Stopped` 描述真实系统状态，只能由 `Start-GsLifecycle` / `Stop-GsLifecycle` 在注入操作前后写入。对这四个目标，即使迁移表允许，也返回 `OperationRequired`，不写文件。这样调用方无法绕过 `OperationNotProvided` 伪造 `Running` 或 `Stopped`。
- 检查顺序：非法迁移先返回 `UnknownState` / `IllegalTransition`，合法但需要操作的再返回 `OperationRequired`。
- 不修复中断的 `Starting`/`Stopping`（迁移表允许 `Starting -> Failed`，调用方可以自行用自己的错误码标记失败）。
- 风险：写入 `Failed` 或 `Paused` 只改变记录，不触碰真实系统。调用方须自行保证二者一致。例如，在组件仍运行时把 `Running` 标为 `Failed`，之后的 `Start-GsLifecycle` 会再次调用启动操作。

`-Config` 接受带 `InstallDir`、`StateDir`、`LogDir` 属性的对象或哈希表，每次调用都重新经 `Test-GsInstallationConfig` 校验。`StateDir` 必须已存在，模块不创建目录。

### Start-GsLifecycle

```powershell
Start-GsLifecycle -Config <object> [-StartOperation <scriptblock>]
```

1. 未提供或为 `$null` 时返回 `OperationNotProvided`，不读写状态。
2. 获取锁，读取状态，修复中断状态（第 6 节）。
3. 当前为 `Running` 时返回 `AlreadyRunning`，不调用回调。
4. 当前状态 → `Starting`（须合法，否则返回 `IllegalTransition`，不调用回调），持久化。写入失败返回 `PersistFailed`，`OperationInvoked = $false`。
5. 调用 `StartOperation`（第 5 节）。
   - 失败：→ `Failed`（错误码 `StartOperationFailed`），结果码 `StartOperationFailed`。若 `Failed` 也写不进去，结果码 `PersistFailed`，状态留在 `Starting`，由下次调用按中断恢复。
   - 成功：→ `Running`。若 `Running` 写不进去，尝试写 `Failed`（错误码 `StartPersistFailed`），结果码 `PersistFailed`，`OperationSucceeded = $true`，消息说明组件可能已在运行。若 `Failed` 也写不进去，状态留在 `Starting`。

### Stop-GsLifecycle

```powershell
Stop-GsLifecycle -Config <object> [-StopOperation <scriptblock>]
```

1. 未提供或为 `$null` 时返回 `OperationNotProvided`。
2. 获取锁，读取状态，修复中断状态（第 6 节）。若修复的是残留 `Stopping`（补写 `Stopped`），直接返回 `Ok`，不再调用回调。
3. 当前为 `Stopped`（含状态文件不存在）时返回 `AlreadyStopped`，不调用回调。
4. 当前状态必须能迁移到 `Stopping`（即 `Running` 或 `Failed`），否则返回 `IllegalTransition`，不调用回调。
5. 先调用 `StopOperation`，成功后才持久化 `Stopping`，再持久化 `Stopped`。原因是迁移表没有 `Stopping -> Failed`，若先进入 `Stopping` 再失败，将无法合法地回到 `Failed`。
6. 回调失败：
   - 原状态 `Running`：迁移到 `Failed`（错误码 `StopOperationFailed`，诊断含 `action = Stop`、`reason` 与异常类型）。
   - 原状态 `Failed`：表中无 `Failed -> Failed`，状态保持 `Failed`，原错误记录不变。
   - 两种情况结果均为 `Success = $false`、`Code = StopOperationFailed`、`State.State = Failed`、`OperationSucceeded = $false`、`OperationError` 为回调错误消息。不会报告为已停止。若 `Failed` 写不进去，结果码为 `PersistFailed`，文件仍为 `Running`。
7. 回调成功但写入失败：
   - `Stopping` 写入失败：原状态为 `Running` 时尝试写 `Failed`（错误码 `StopPersistFailed`）；也失败时消息说明“状态文件仍为 Running”。结果码 `PersistFailed`，`OperationSucceeded = $true`。
   - `Stopped` 写入失败：状态留在 `Stopping`，结果码 `PersistFailed`，下次 Start/Stop 补写 `Stopped`。

### 结果对象（Invoke / Start / Stop）

| 字段 | 说明 |
|------|------|
| `Success` | bool |
| `Code` | 见下表 |
| `Message` | 人类可读说明 |
| `From` | 修复中断后、执行迁移前的状态（损坏时为 `Failed`） |
| `To` | 请求的目标状态（Start 为 `Running`，Stop 为 `Stopped`） |
| `State` | 调用结束后的状态记录（`State`、`ChangedAtUtc`、`Error`），失败时为文件中实际保留的状态 |
| `Errors` | 配置错误列表（`InvalidConfig` 时非空） |
| `OperationInvoked` | bool：本次调用是否执行了注入回调 |
| `OperationSucceeded` | `$true` / `$false`：回调成功或失败；`$null`：未执行回调 |
| `OperationError` | 注入回调的错误消息，仅返回给调用方，不持久化 |
| `Recovered` | `$null`，或本次调用修复的中断记录：`From`、`To`、`Code`（`StartInterrupted` / `StopCompleted`）、`InterruptedChangedAtUtc` |

调用方据 `OperationInvoked` 与 `OperationSucceeded` 区分三种 `PersistFailed`：操作未执行（`$false` / `$null`），操作已失败但状态未写入（`$true` / `$false`），操作已成功但状态未写入（`$true` / `$true`）。

| Code | 含义 |
|------|------|
| `Ok` | 成功 |
| `InvalidConfig` | 配置为空或校验失败，`Errors` 列出原因 |
| `StateDirectoryMissing` | 状态目录不存在 |
| `Busy` | 锁文件共享冲突（Win32 错误 32/33）：另一调用正持有锁 |
| `AccessDenied` | 无权限创建或打开锁文件（`UnauthorizedAccessException`），如 StateDir 的 ACL 拒绝创建文件 |
| `LockFailed` | 打开锁文件时的其他错误，消息含异常类型 |
| `UnknownState` | 目标状态不在六个状态内 |
| `IllegalTransition` | 迁移表不允许 |
| `OperationRequired` | 迁移合法，但目标须由 Start/Stop 配合注入操作写入（仅 Invoke 返回） |
| `ErrorCodeRequired` | 迁移到 `Failed` 未提供 `ErrorCode` |
| `InvalidErrorCode` | `ErrorCode` 不匹配 `\A[A-Za-z][A-Za-z0-9_.]{0,63}\z`（区分大小写；末尾换行同样拒绝） |
| `ErrorCodeNotAllowed` | 迁移到非 `Failed` 状态时提供了 `ErrorCode` |
| `PersistFailed` | 写入失败，原文件保持不变（含中断修复失败，消息以 `Interrupted <State> state could not be recovered` 开头） |
| `StateReadFailed` | 状态文件无法读取，不写入任何内容 |
| `OperationNotProvided` | 未注入回调 |
| `AlreadyRunning` / `AlreadyStopped` | 重复启动 / 停止 |
| `StartOperationFailed` / `StopOperationFailed` | 注入回调失败 |

## 3. 状态表

状态：`Stopped`、`Starting`、`Running`、`Stopping`、`Failed`、`Paused`。初始（无状态文件）为 `Stopped`。

| 当前 | 允许的目标 | 写入者 |
|------|-----------|--------|
| `Stopped` | `Starting`、`Paused` | `Starting`：Start；`Paused`：Invoke |
| `Starting` | `Running`、`Failed` | Start（含中断修复）；`Failed` 亦可由 Invoke 写入 |
| `Running` | `Stopping`、`Failed` | `Stopping`：Stop；`Failed`：Start/Stop/Invoke |
| `Stopping` | `Stopped` | Stop（含中断修复，Start 也会补写） |
| `Failed` | `Starting`、`Stopping` | Start / Stop |
| `Paused` | `Starting` | Start |

其余组合（包括任何状态到自身）均为 `IllegalTransition`。

## 4. 持久化

### 4.1 文件

- 状态文件：`<StateDir>\lifecycle-state.json`
- 锁文件：`<StateDir>\lifecycle.lock`。锁是对该文件的独占句柄（`FileShare.None`），而非文件是否存在。释放时只关闭句柄、不删除文件，因此残留的锁文件不阻塞任何调用，也不会出现“删除挂起”被误判为权限错误。
- 损坏备份：`<StateDir>\lifecycle-state.json.corrupt`（仅在修复损坏文件时生成，覆盖旧备份）
- 临时文件：`<StateDir>\lifecycle-state.json.<guid>.tmp`（成功或失败后都会删除）

### 4.2 格式（schemaVersion 1，UTF-8 无 BOM）

```json
{
  "schemaVersion": 1,
  "state": "Failed",
  "changedAtUtc": "2026-10-30T12:00:00.0000000Z",
  "error": {
    "code": "StartOperationFailed",
    "occurredAtUtc": "2026-10-30T12:00:00.0000000Z",
    "diagnostics": { "action": "Start", "reason": "Exception", "exceptionType": "System.Management.Automation.RuntimeException" }
  }
}
```

- 时间为 UTC 往返格式（`o`，以 `Z` 结尾）。
- `error` 在 `Failed` 时必须为对象，其他状态必须为 `null`。离开 `Failed` 时清空。
- 模块自身写入的错误码：`StartOperationFailed`、`StopOperationFailed`、`StartPersistFailed`、`StopPersistFailed`、`StartInterrupted`、`StateCorrupt`。`StateReadFailed` 只出现在读取结果中，不写入。
- 写入方式：在同一目录创建临时文件（`CreateNew`），写入并 `Flush(true)`，然后用 `MoveFileEx`（`MOVEFILE_REPLACE_EXISTING`，目标已存在）或 `File.Move`（目标不存在）替换。不用 `File.Replace`：它先把目标挪到备份名再发布新文件，读者会有一瞬间看不到状态文件。失败时原文件不变，临时文件删除。

### 4.3 损坏判定

以下任一情况视为损坏，读取结果为 `Failed`（`StateCorrupt`，诊断字段 `reason`）：`EmptyFile`、`InvalidJson`、`RootNotObject`、`UnsupportedSchemaVersion`、`UnknownState`（含大小写不符或非字符串）、`InvalidTimestamp`（非 UTC 往返格式）、`MissingError`、`UnexpectedError`（非 `Failed` 却带错误）、`InvalidError`（`Failed` 的错误缺 `code`/`occurredAtUtc`/`diagnostics`，或 `code` 不匹配错误码正则，包括末尾带换行）。

`Get-GsLifecycleState` 只报告，不修改文件。`Invoke-GsLifecycleTransition`、`Start-GsLifecycle`、`Stop-GsLifecycle` 遇到损坏文件时，先把原文件备份为 `.corrupt`，再持久化 `Failed`，然后按 `Failed` 为当前状态继续执行迁移规则。

### 4.4 诊断与敏感数据

- `Diagnostics` 接受哈希表或 PSCustomObject，其他值存为 `{ "value": ... }`。
- 只保留 `null`、字符串、数字、布尔、数组与嵌套对象。其他对象存为 `[unserializable:<类型名>]`，不调用其 `ToString()`。
- 键名匹配 `pass|pwd|secret|token|key|credential|cred|pin|cert|private|auth|cookie|session|sid`（不区分大小写）的值替换为 `[REDACTED]`；`SecureString` 与 `PSCredential` 一律 `[REDACTED]`。
- 限制：嵌套深度 4（超出为 `[depth-limit]`），每层 50 项（超出加 `_truncated`），字符串 1024 字符。
- 注入回调的异常消息不写入状态文件，只记录 `reason` 与异常类型，消息通过结果对象 `OperationError` 返回调用方。

## 5. 依赖接口（注入回调）

```powershell
$operation = { param($Context) ... }
```

- `$Context` 字段：`Action`（`Start` / `Stop`）、`From`（中断修复后的状态）、`InstallDir`、`StateDir`、`LogDir`。
- 调用方式：`ScriptBlock.InvokeWithContext`，在回调作用域内注入 `$ErrorActionPreference = 'Stop'`，错误流合并到输出。调用方自身的 `$ErrorActionPreference` 不被修改。调用经过模块加载时用 `Add-Type` 在内存中编译的 `GsLifecycle.Internal.OperationInvoker`（不写磁盘，不导出），它在 .NET 层捕获 `FlowControlException`。PowerShell 的 `try/catch` 无法捕获该异常，带标签的 `break`/`continue` 也会穿过任何保护循环。
- 失败判定（诊断 `reason`）：
  - `Exception`：回调抛出终止错误。
  - `NonTerminatingError`：回调写出非终止错误。在默认的 Stop 偏好下，它会被提升为终止错误；若回调在本地覆盖了偏好（`$ErrorActionPreference = 'Continue'` 或 `-ErrorAction Continue`），输出中的 `ErrorRecord` 仍判为失败。
  - `ControlFlowEscape`：`break`、`continue`（含带标签形式）或 `exit` 离开了回调脚本块。诊断的 `exceptionType` 为 `System.Management.Automation.BreakException` / `ContinueException` / `ExitException`。控制流不会传到 Start/Stop 的调用方：调用方的循环继续执行，宿主进程不会因回调中的 `exit` 退出，调用照常返回结构化结果。这些语句完全在回调内部的循环或 `switch` 中使用时不受影响。
  - `ReturnedFalse`：输出中包含 `[bool]$false`。
- 不判为失败：回调内部 `try/catch` 已处理的错误，警告、详细信息流，其他输出值，以及原生程序的非零退出码（`$LASTEXITCODE` 不检查，回调须自行判断并 `throw`）。
- 调用时机：`StartOperation` 在 `Starting` 已持久化后调用；`StopOperation` 在任何状态变更之前调用。
- 回调在状态目录锁内执行。回调内对同一 `StateDir` 调用本模块的写入函数会得到 `Busy`；`Get-GsLifecycleState` 可以调用，返回 `Interrupted = $false`。
- 模块不提供默认实现，也不提供超时或取消。

## 6. 中断恢复

只有 Start/Stop 在持有锁期间才会写入 `Starting` 与 `Stopping`。因此，`Start-GsLifecycle` / `Stop-GsLifecycle` 拿到锁后若读到这两个状态，就证明写入它们的调用已经不在运行，即上一次调用中断了（进程崩溃、被终止，或后续写入失败）。修复在同一把锁内、执行本次请求之前完成，两条修复路径都是迁移表中的合法边：

| 残留状态 | 产生原因 | 修复 | `Recovered.Code` | 理由 |
|----------|----------|------|------------------|------|
| `Starting` | 启动回调执行中崩溃；回调结束后 `Running`/`Failed` 写入失败 | `Starting -> Failed`，错误码 `StartInterrupted`，诊断含 `interruptedState`、`interruptedChangedAtUtc` | `StartInterrupted` | 无法确定启动操作是否执行过、是否成功，真实组件状态未知，故记为失败 |
| `Stopping` | `Stopped` 写入失败或在两次写入之间崩溃 | `Stopping -> Stopped` | `StopCompleted` | `Stopping` 只在停止回调成功后写入，缺的只是最后一次写入 |

修复之后：

- `Start-GsLifecycle`：从 `Failed` 或 `Stopped` 正常启动，回调收到的 `From` 为修复后的状态。
- `Stop-GsLifecycle`：修复 `Starting` 后从 `Failed` 正常停止，并调用停止回调，因为组件可能已在运行。修复 `Stopping` 后直接返回 `Ok`，不再调用回调。
- 修复写入失败：返回 `PersistFailed`，不调用回调，文件不变。

停止回调执行中崩溃不会留下 `Stopping`：该状态只在回调成功后写入，文件仍为 `Running`，重试 `Stop-GsLifecycle` 即可。

## 7. 并发限制

- 同一 `StateDir` 的所有写入（Invoke / Start / Stop，含中断修复）用 `lifecycle.lock` 的独占句柄互斥，跨线程、跨进程都有效。拿不到锁立即返回 `Busy`，不等待、不重试。
- 锁的错误分类：只有共享冲突（Win32 32 / 33）才返回 `Busy`；`UnauthorizedAccessException` 返回 `AccessDenied`；其他错误返回 `LockFailed`。
- 进程异常退出后操作系统释放句柄，残留的锁文件不阻塞后续调用。测试用真实子进程在回调内 `[Environment]::Exit` 验证了这一点。
- 中断判定依赖“持有锁即唯一写入者”。若有进程绕过本模块直接写状态文件，判定不成立。
- `Get-GsLifecycleState` 平时不加锁。仅在状态为 `Starting`/`Stopping` 时短暂探测锁，探测期间并发写入方可能得到 `Busy`。由于写入使用原子替换，读者看到的是替换前或替换后的完整文件。替换的瞬间并发打开可能被拒绝（共享冲突 32/33），读取会短暂重试（最多 20 次，约 145 ms），不把这种情况报告成 `ReadFailed`；其他读取错误立即报告 `Failed`。
- 不同 `StateDir` 之间互不协调。网络共享（UNC）上的锁与 `MoveFileEx` 语义未做验证。

## 8. 明确未实现

- 任何真实系统操作（服务、进程、注册表、驱动、防火墙），以及与 GameStream 组件的对接。
- `Paused` 的业务含义；目前只能由 `Invoke-GsLifecycleTransition` 从 `Stopped` 显式进入，没有专用的暂停/恢复函数。
- 回调超时、取消与重试策略；`Busy` 时的等待策略。
- 原生程序退出码的自动判定（回调须自行检查 `$LASTEXITCODE` 并抛出）。
- 中断 `Starting` 时对真实组件状态的探测：模块只记为 `Failed(StartInterrupted)`，是否在运行由调用方或后续 Stop 的回调处理。
- 目录的创建、权限设置与默认位置；日志目录的写入（本阶段只校验 `LogDir`，不写日志）。
- 状态历史与审计记录；`.corrupt` 只保留最近一份。
- `schemaVersion` 1 以外的配置与状态格式及迁移。
- 符号链接、junction 与 8.3 短名造成的实际目录重叠检测（嵌套检查仅基于规范化后的路径字符串）。
- 超过 260 字符的路径（沿用阶段 1 的拒绝行为）。

## 9. 验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Stage1Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Stage2Tests.ps1
```

阶段 2 测试只在 `%TEMP%` 下创建随机命名的合成目录，结束时删除。回调均为模拟脚本块。崩溃与并发测试会启动 `$PSHOME\powershell.exe` 子进程，子进程只导入本模块、操作同一合成目录。ACL 测试只对合成目录与其中的文件添加并移除当前用户的 Deny 规则。写入中途失败的测试通过模块内部的 `$script:TestWriteFault` 注入点模拟，该注入点不导出，正常使用时为 `$null`。全部通过时退出码为 0，任一失败或零个测试执行时退出码为 1。
