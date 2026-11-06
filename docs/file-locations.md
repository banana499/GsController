# 文件与日志位置

更新时间：2026-10-31。排查时的速查表：产品侧的全部路径，以及 Moonlight 客户端日志在哪里。行为依据与更多背景见 [operator-guide.md](operator-guide.md)。

> 约定：`<安装目录>` = `C:\Program Files\Local Development\GsController`（MSI 安装位置）；`<StateDir>` = `%ProgramData%\Local Development\GsController`；`<LogDir>` = `%ProgramData%\Local Development\GsControllerLogs`。这些都是默认值，CLI/诊断/托盘都有对应参数可覆盖（`-InstallDir` / `-StateDir` / `-LogDir` / `-TrayLogDir`）。

## 安装目录

MSI 只安装这个目录（per-machine）：

| 路径 | 内容 |
|---|---|
| `<安装目录>\gs-product.ps1` | 产品 CLI（Install/Check/Start/Stop/Status/Recover/Diagnose/CreateCatalog/RegisterAutostart/UnregisterAutostart/PrepareUninstall） |
| `<安装目录>\gs-diagnose.ps1` | 只读诊断脚本（可独立运行） |
| `<安装目录>\gs-support.ps1` | 支持包脚本 |
| `<安装目录>\gs-tray.ps1` / `gs-tray-model.ps1` / `gs-tray.vbs` | 托盘宿主 / 状态模型 / 隐藏启动器 |
| `<安装目录>\gs-tray-strings.zh-CN.json` | 托盘中文字符串表 |
| `<安装目录>\Modules\GsControl\|GsLifecycle\|GsRuntime\` | 产品模块（`.psd1` + `.psm1`） |
| `<安装目录>\bin\` | MSI 打包进去的运行时包副本（黑盒，原样复制） |
| `<安装目录>\Broker\`（及 `Broker\plugins`、`Broker\logs`、`Broker\bin`） | `Install` 从组件源目录复制进来的组件树——**不是 MSI 管理的文件**，卸载后可能残留 |

## StateDir（状态目录）

产品在 `<StateDir>` 下创建并读写（MSI 不管这个目录）：

| 路径 | 说明 |
|---|---|
| `<StateDir>\runtime-config.json` | 三个 JSON 配置之一：布局配置（installDir/stateDir/logDir/componentSourceDir），`Install` 时写入，后续操作从这里读布局 |
| `<StateDir>\component-catalog.json` | 组件目录清单，`Install`/`CreateCatalog` 生成 |
| `<StateDir>\runtime-plan.json` | 运行时计划（角色与组件），`Install` 时生成 |
| `<StateDir>\status.json`（候选 2） | 运行时状态文件的候选路径之一，见下 |
| `<StateDir>\supervisor_pause.flag`（旧位置） | 暂停标志的旧位置：旧版本产品写这里；现在只保留不覆盖、不新建，见下 |
| `<StateDir>\lifecycle.lock` | 生命周期互斥的伴生锁文件。Start/Stop/Recover 的互斥靠命名互斥体，进程异常退出后操作系统释放句柄，**残留的锁文件不会阻塞后续调用**；不要手工删除正在使用中的锁文件 |
| `<StateDir>\runtime\` | 运行时目录 |
| `<StateDir>\runtime\bin\` | `Install` 部署的运行时辅助脚本（`gs_supervisor.ps1`、启停脚本等，黑盒）；自启任务从这里以 SYSTEM 身份运行 supervisor |
| `<StateDir>\runtime\bin\_supervisor.log` | supervisor 自己写的日志（黑盒）；诊断报告只读它的尾部并脱敏 |
| `<StateDir>\runtime\state\status.json`（候选 1） | 运行时状态文件的候选路径之一 |
| `<StateDir>\runtime\state\supervisor_pause.flag`（规范位置） | 暂停标志的规范位置：产品层 `Stop`/`PrepareUninstall` 写这里，supervisor 读这里，见下 |

**两条候选路径与已知的不一致**（盘点发现 1.3-6）：

- 状态文件：产品层（托盘、`-Action Status`、Recover、诊断）按 `<StateDir>\runtime\state\status.json` → `<StateDir>\status.json` 的顺序查找；两个都存在时取"最近写入"的那个。两者并存会让诊断报告 `hygiene` 段给出 `StatusFileAmbiguous`。
- 暂停标志：两处路径角色不同。`<StateDir>\runtime\state\supervisor_pause.flag` 是规范位置（`GsRuntime.psm1` 的 `PauseFlagPath`）：产品层 `Stop`（含 `PrepareUninstall` 的停机步骤）写这里，supervisor 实际读这里（[remote-client-test.md](remote-client-test.md) 第 5 节）。`<StateDir>\supervisor_pause.flag` 是旧位置（`LegacyPauseFlagPath`）：只保留不覆盖、不新建。显式的手动 `Start` 成功会同时清除两处（= 恢复自动守护）；`Start` 失败保留并按字节快照恢复原有暂停；`Recover` 保留调用前已存在的暂停、只清理它自己停机步骤创建的标志。详见 [operator-guide.md](operator-guide.md) 的"开机自启与暂停标志"和 [lifecycle-hardening.md](lifecycle-hardening.md) 的"The supervisor pause flag contract"一节。

## 日志

| 路径 | 说明 |
|---|---|
| `<LogDir>` | 产品日志目录（`Install`/运行时写；托盘"打开日志"菜单打开的就是它） |
| `<StateDir>\runtime\bin\_supervisor.log` | supervisor 日志（见上） |
| 串流器 Qos 日志 | 主机串流进程自己的日志（取证过滤方式见 [remote-client-test.md](remote-client-test.md) 第 3 节） |

诊断报告读取日志的方式是有界的：只读尾部（默认 50 行、最多 8 MB、总超时内），读的过程中逐行脱敏。

## 托盘日志与结果文件

| 路径 | 说明 |
|---|---|
| `%LOCALAPPDATA%\GsController\tray\tray.log` | 托盘日志：状态变化、CLI 启动/结果、被取消的 UAC、全部异常。到 1 MB 轮转为 `tray.log.1` |
| `%LOCALAPPDATA%\GsController\tray\results\<guid>.json` | CLI 结果文件：托盘拉起的 CLI 子进程把结果写在这里，托盘读一次后删除；残留文件在托盘启动时清理 |
| `%LOCALAPPDATA%\GsController\support\` | 支持包输出目录（默认值） |

## 支持包输出

`gs-support.ps1`默认输出到 `%LOCALAPPDATA%\GsController\support`，可用 `-OutputDir` 覆盖（必须是仓库外的绝对路径）。zip 内容与不收集清单见 support-bundle.md。

## 证据目录

验收/兼容性/稳定性证据都放在**仓库外**（工具会拒绝仓库内的证据目录）：本机 `C:\gs-evidence\` 或 NAS 共享，与 [acceptance-evidence.md](acceptance-evidence.md) 的记录一致。命名约定：

```text
<证据根>\compat-<用例ID>-<yyyyMMdd_HHmmss>\      兼容性（compatibility-test-plan.md）
<证据根>\stability-<用例ID>-<yyyyMMdd_HHmmss>\   稳定性（stability-test-plan.md）
```

长测工具 `tools\gs-soak-monitor.ps1`在 `-OutputDir` 里写 `samples.csv`、`events.jsonl`、`summary.json`。

## Moonlight 客户端日志

| 客户端 | 位置 |
|---|---|
| Windows | `%TEMP%\Moonlight-*.log` |
| macOS | 系统临时目录 `/tmp`，文件名 `Moonlight-<unix 时间戳>.log`（与 compatibility-test-plan.md 里"系统临时目录"的写法一致） |
| Linux（Flatpak/Snap 包） | 不落文件，输出到终端 |
| Android（电视盒） | `logcat` 过滤 `com.limelight` 只取相关行；**不要**把整份系统日志放进证据或仓库 |

注意：客户端日志里可能包含本次会话的 `rikey`（短期会话密钥）。复制给证据目录之外的任何人之前，把它替换成 `<redacted>`。任何情况下都不要收集或复制配对数据、证书和私钥。
