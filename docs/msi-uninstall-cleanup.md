# MSI 卸载清理：PrepareUninstall 接线与固定任务兜底

状态：**已实现源码与离线验证；真实安装/修复/升级/卸载尚未验收**（没有虚拟机，本机禁止真实 MSI 安装/卸载与真实任务操作）。VM 验收是发布阻塞项，见文末"未验收清单"。

本页的 PrepareUninstall 和固定任务清理只适用于 **Legacy 配置**。`-RuntimeProfile Sunshine` 在编译时移除这两个动作及其调度；卸载该配置的 GsController 不调用旧运行时，也不管理外部 Sunshine。两种配置都需要分别做真实安装生命周期验收。Sunshine 使用步骤见 [Sunshine 首次使用](sunshine-quickstart.md)。

公开接口依据：[生命周期与 PrepareUninstall 契约](lifecycle-hardening.md)。本页完整记录接线、失败边界与验收要求，不依赖未随仓库提供的内部设计记录。

## 目的

产品用计划任务（固定名 `GsControllerSupervisor`）实现 SYSTEM 自启。MSI 卸载只删文件，不认识计划任务：如果不做清理，任务会在卸载后继续拉起已删除的运行时。本改动把已实现的 `gs-product.ps1 -Action PrepareUninstall`（优雅停栈 + 删任务，`docs/lifecycle-hardening.md`）接入 MSI 完整卸载路径，并加一个不依赖任何状态目录的 `schtasks` 兜底。

## 机制（installer/GsController.wxs）

两个 CustomAction，均**声明在 `<Product>` 内**（WiX3 中放在 Fragment 里的 CustomAction 若无显式引用不会链接；本测试断言 Fragment 内无 CustomAction，`GsController.wxs` 第 10-14 行注释同样记录了这一点）：

| Id | 工作目录（Directory） | 命令（ExeCommand） |
|---|---|---|
| `GsPrepareUninstall` | `INSTALLFOLDER` | `"[WindowsFolder]System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "[INSTALLFOLDER]gs-product.ps1" -Action PrepareUninstall` |
| `GsRemoveSupervisorTask` | `SystemFolder` | `"[WindowsFolder]System32\schtasks.exe" /Delete /TN "GsControllerSupervisor" /F` |

共同属性与语义：

- `Execute="deferred"`：在执行序列（脚本阶段）运行，拥有提升上下文；不在 UI 序列运行，静默卸载同样执行。
- `Impersonate="no"`：以安装服务上下文（perMachine 下即 SYSTEM）运行，满足 CLI 的管理员检查与任务删除权限。
- `Return="ignore"`：清理失败不阻断 MSI 卸载——卸载不应因任务不存在或运行时已损坏而失败。
- 显式系统路径：PowerShell 与 `schtasks.exe` 都用 `[WindowsFolder]System32\...` 绝对路径，不依赖 PATH 搜索。命令用 `-File` + 带引号的 `[INSTALLFOLDER]gs-product.ps1` 引用已部署脚本，**不使用 `-Command` 字符串拼接**；实际展开路径和进程位数在 VM 验收中确认。
- 执行顺序（`InstallExecuteSequence`）：`InstallInitialize` < `GsPrepareUninstall` < `GsRemoveSupervisorTask` < `RemoveFiles`。先停栈、再兜底删任务、最后删文件（`gs-product.ps1` 在 `RemoveFiles` 之前仍在磁盘上）。
- 条件（两个动作相同）：`REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE`。
- `SystemFolder` 标准目录在 Fragment 的 `TARGETDIR` 下显式声明：`Directory="SystemFolder"` 引用需要目录表里有对应行，否则 `light.exe` 报 `LGHT0094` 未解析引用（本轮实测踩到并修复）。

### 条件语义

| 场景 | REMOVE | UPGRADINGPRODUCTCODE | 清理动作 |
|---|---|---|---|
| 全新安装 | 未定义 | 未定义 | 不执行 |
| 修复（`msiexec /f` / ARP 修复） | 未定义 | 未定义 | 不执行 |
| 修改功能 | 特性列表（如 `Main`） | 未定义 | 不执行 |
| 普通卸载 | `ALL` | 未定义 | **执行** |
| 主版本升级（旧产品被 `RemoveExistingProducts` 移除） | `ALL` | 新产品 ProductCode | 不执行（任务保留，新版本沿用同一任务名与路径） |

`UPGRADINGPRODUCTCODE` 由 Windows Installer 在 `RemoveExistingProducts` 移除旧产品时自动设置到旧产品的卸载会话，无需旧包声明属性。

## 失败与可观察性边界（重要，不是成功证明）

- `Return="ignore"` 意味着：CA 失败仅被记录，不影响卸载完成；**同时**也意味着没有"卸载清理成功"的强信号。
- `gs-product.ps1 -Action PrepareUninstall` 返回结构化结果对象，**不保证**把 `Success=$false` 映射为非零进程退出码；普通 EXE CA 的 PowerShell 进程退出码因此**不是**停栈或删任务成功的证明。
- EXE CA 的 stdout/stderr 不会被完整可靠地写入 MSI 日志；**不能声称完整 CLI 错误已进入 MSI 日志**。
- 本接线能可靠观察到的只有：msiexec 详细日志（`msiexec /x ... /l*v uninstall.log`）中两个 CA 是否被调度、其进程退出码、动作顺序。
- **真实卸载后必须查询任务调度器确认任务已消失**，例如管理员执行 `schtasks /Query /TN GsControllerSupervisor`。仅明确的“任务不存在”表示删除成功；拒绝访问、RPC 或调度器错误不能当作任务不存在。也可用 `Get-ScheduledTask` 核对同一结果。

## 兜底与自定义 StateDir 边界

- MSI 路径以**默认参数**调用 CLI：默认 `StateDir = C:\ProgramData\Local Development\GsController`、`LogDir = C:\ProgramData\Local Development\GsControllerLogs`。MSI CA 不传 `-StateDir`/`-LogDir`（测试断言命令里没有这两个参数）。
- **使用自定义 `-StateDir`/`-LogDir` 部署的 operator 必须在 MSI 卸载前手动运行** `gs-product.ps1 -Action PrepareUninstall -StateDir <自定义路径>`：MSI 兜底删的只是固定名任务，停栈走的是默认布局；自定义布局的运行时进程不在本接线的保证范围内。
- 固定任务名 `GsControllerSupervisor` 与 `gs-product.ps1` 中 `$SupervisorTaskName` 参数默认值及 `UnregisterAutostart` 分支的字面量必须一致；`Invoke-MsiCleanupTests.ps1` 对三处做一致性断言。
- 本接线**只删除产品自己的固定名任务**，不终止用户外部计划任务；"终止用户外部任务"与"感知自定义 runtime 路径"都不是已验收功能。

## 用户数据与 ACL

- 不删除 `StateDir`、`LogDir`、配置、配对材料或日志（PrepareUninstall 契约：结果 `Data.StateDirKept/LogDirKept` 恒为真）。
- 两个 CA 都不触碰 ACL（无 icacls、无 `MsiLockPermissionsEx`）；目录权限是安全设计缺口 B 的独立工作。

## 安装形态说明

MSI 安装本身**不创建**计划任务；任务由 `gs-product.ps1 -Action RegisterAutostart`（CLI 安装流程）创建。因此：

- 只装 MSI、从未注册任务 → 卸载时两个 CA 幂等无事可做：CLI 返回 `TaskRemoved=False`（不算失败），`schtasks /F` 报"任务不存在"也被 `Return="ignore"` 吸收。
- CLI 安装过任务、之后用 MSI 卸载 → 本接线覆盖：停栈 + 删任务 + 兜底。

## 回滚窗口

两个 CA 之后若执行序列还有动作失败导致卸载回滚：任务已被删、文件被恢复——产品在但自启没了。恢复方法：`gs-product.ps1 -Action RegisterAutostart`。`Return="ignore"` 只能避免 CA 自己触发回滚，不能消除"后续动作失败"的窗口；这一点必须写进发布说明。

## 工作目录与可执行文件

`Directory="SystemFolder"` 仅指定兜底动作的工作目录；它不是可执行文件搜索路径。[Microsoft 的 SystemFolder 定义](https://learn.microsoft.com/en-us/windows/win32/msi/systemfolder)说明，该属性在 64 位 Windows 上可能指向 SysWOW64，不能仅凭 x64 包把它称为 64 位系统目录。可执行文件由上表中的绝对 `System32` 路径指定；最终实际进程位数与展开路径仍应在真实 VM 卸载验收中核对。

## 验证（全部离线）

`tests/Invoke-MsiCleanupTests.ps1`（可被 `Invoke-All.ps1` 安全自动发现；不调用任何其他测试套件）：

1. **结构层**：解析真实 `installer/GsController.wxs`，断言两动作在 Product 内、deferred/no-impersonate/ignore、显式系统路径与 `-File`（无 `-Command`/`-EncodedCommand`）、任务名三处一致、条件与顺序正确、不触碰用户数据与 ACL。
2. **条件层**：用小型离线求值器对从 wxs 解析出的**真实条件串**做 5 场景求值（安装/修复/修改=假，普通卸载=真，升级旧产品卸载=假）；求值器遇到超出语法的子句会抛错，避免静默通过。
3. **构建层**：在 `%TEMP%` 造假产品（假 `gs-product.ps1`、假模块、假 bin 文件；**不读真实 runtime-bundle**），用与 `scripts/build-product.ps1` 完全相同的 heat/candle/light 参数编译出一次性 MSI，再用 WindowsInstaller COM **只读**打开（`OpenDatabase(mode 0)`，绝不调用 ConfigureProduct/InstallProduct、不用模式 1），断言 CustomAction 表（Type=3170=34+64+1024+2048、Source 列、Target 列全文）、InstallExecuteSequence（条件列、相对 InstallInitialize/RemoveExistingProducts/RemoveFiles 的顺序）、InstallUISequence 无这两个动作、Upgrade 表是固定 UpgradeCode。

本轮运行结果：**18 passed, 0 failed, 0 skipped**（WiX 位于默认 `C:\Tools\GsBuild\wix314`）。WiX 缺失时仅构建层显式 SKIP（打印原因），结构/条件层永不跳过；构建或数据库读取失败一律 FAIL，不做静默降级。测试不运行 msiexec，不注册/删除/停止任何真实任务、服务、注册表或 ACL，只写自己 `%TEMP%` 夹具目录并在结束时删除。

## 未验收清单（VM 验收阻塞，发布前必须完成）

1. 真实安装 + `RegisterAutostart` 后 `msiexec /x /l*v`：verbose 日志确认 `GsPrepareUninstall`、`GsRemoveSupervisorTask` 依次执行；卸载后 `schtasks /Query /TN GsControllerSupervisor` 确认任务消失；`StateDir`/`LogDir` 仍在。
2. 真实升级（装旧版 → 注册任务 → 装新版）：旧产品卸载段无这两个 CA 的执行记录，任务在新版本下继续存在。
3. 真实修复（`msiexec /f`）：无清理动作执行。
4. 任务不存在时的静默卸载：卸载成功完成，无 CA 引发的失败。
5. 自定义 StateDir 部署 + 手动 `PrepareUninstall -StateDir` 的操作路径走通（文档化流程，不由 MSI 保证停栈）。
