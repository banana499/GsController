# GsController 运维手册

本手册描述 **Legacy 旧运行时** 的安装、部署、启停、诊断、恢复、升级与卸载。新增 Sunshine 配置使用独立的 [Sunshine 首次使用流程](sunshine-quickstart.md)，不执行本页的组件部署、自启任务或 PrepareUninstall 操作。术语与路径的完整清单见 [文件与日志位置](file-locations.md)；出问题先查 [故障排查](troubleshooting.md)。

> 约定：下文用 `<安装目录>` 指默认安装目录 `C:\Program Files\Local Development\GsController`，用 `<StateDir>` 指 `%ProgramData%\Local Development\GsController`，用 `<LogDir>` 指 `%ProgramData%\Local Development\GsControllerLogs`，用 `<主机IP>` / `<客户端IP>` 指局域网地址。命令都在 Windows PowerShell 5.1 里运行。

## 系统要求

| 项 | 要求 |
|---|---|
| 主机系统 | Windows 11 x64（在 22631 版本上验证过） |
| PowerShell | Windows PowerShell 5.1（产品自带脚本的运行环境） |
| 安装包 | 由操作者用 `scripts\build-product.ps1` 构建的 MSI（需要 WiX 3.14；构建只在打包机器上做，目标机器只需要 MSI） |
| 运行时包 | 由操作者另行提供的预构建运行时包（黑盒依赖，本产品不包含、不解读其内部） |
| 客户端 | 同一局域网内的 Moonlight 客户端（见[客户端连接](#客户端连接)） |
| 网络 | 主机与客户端在同一 LAN；主机需放行 47989（serverinfo 查询）等 GameStream 端口，见[威胁模型](threat-model.md)的信任边界一节 |

安装、`RegisterAutostart` 和 `UnregisterAutostart` 需要管理员权限；托盘在非提权时每次启停会弹一次 UAC。

## 安装（MSI）

MSI 是按机器（per-machine）安装的，装到 `C:\Program Files\Local Development\GsController`：

```powershell
msiexec /i C:\path\to\GsController-<版本>.msi /qn
```

- MSI 只包含产品层（CLI、托盘、诊断脚本、模块和运行时包的副本）；它不创建计划任务、不写 ProgramData——那些是后面"部署组件"和"开机自启"两步做的事。
- 当前 MSI **未签名**，安装时 Windows 会显示"未知发布者"；签名方案见 [msi-signing.md](msi-signing.md)。
- MSI 使用 WiX `MajorUpgrade`：安装更高版本会就地升级；已装更新版本时再装旧版会被拒绝（提示 "A newer version is already installed."）。

## 部署组件（Install / Check）

MSI 安装完成后，需要把你自己的组件目录和运行时包部署到运行布局里（管理员 PowerShell）：

```powershell
$p = '<安装目录>\gs-product.ps1'
& $p -Action Install -ComponentSourceDir 'D:\path\to\components'
& $p -Action Check
```

- `Install` 需要 `-ComponentSourceDir`（你的组件目录）。它会：生成组件目录并写入 `<StateDir>\component-catalog.json`，把组件树复制进安装目录，把运行时包复制到 `<StateDir>\runtime\bin`，生成运行时计划写入 `<StateDir>\runtime-plan.json`，并写 `<StateDir>\runtime-config.json`。
- `Check` 校验运行布局、运行时包是否完整；带 `-CatalogPath` 时还会按组件目录重新生成计划做一致性校验。部署后、启动前先跑一次 `Check`。
- `Install` 不设置目录 ACL（这是已知缺口，见[威胁模型](threat-model.md)）；`Install` 也不启动任何东西。

## 启动、停止与状态

```powershell
& $p -Action Start
& $p -Action Status
& $p -Action Stop
```

- `Start` / `Stop` 通过以 StateDir 派生的命名互斥体串行化：两个控制器（控制台和托盘，或两个控制台）不会同时驱动同一个运行时。另一个操作正在运行时返回结构化错误 `Busy`，运行时脚本不会执行。`-LockTimeoutSec`（默认 30）是等待锁的秒数，`0` 表示只试一次。
- 结果是输出里**最后一个**带 `Success` 属性的对象：`{ Success; Data; Errors = @({ Code; Message }) }`。`Message` 保持英文；中文界面在托盘和文档里。
- `Status` 在没有状态文件时返回 `NotInstalled`；状态文件存在但读不了时返回 `StatusReadFailed`（通常是权限问题，见[故障排查](troubleshooting.md)）。
- `Stop` 会写暂停标志（见下一节）并停掉自启任务里的 supervisor 周期。

## 托盘

托盘是任务栏通知区的一个图标，镜像产品运行状态，并通过 CLI 做启停。它自己没有任何生命周期逻辑，也不提权自己。

启动（无控制台窗口）：

```text
wscript.exe "<安装目录>\gs-tray.vbs"
```

或直接双击产品目录里的 `gs-tray.vbs`。同一时刻只有一个实例（第二个实例会静默退出）。托盘的界面文字、菜单和气泡是中文（`product\gs-tray-strings.zh-CN.json` 字符串表驱动）。

六个状态（图标颜色）：

| 状态 | 图标 | 含义 |
|---|---|---|
| 已停止 | 灰 | 没有状态文件，或状态为 `stopped`/`paused`/`idle` |
| 正在启动 | 黄 | 挂起的 Start，或状态文件刚写入 `starting`/`launching`/`initializing` |
| 正在停止 | 橙 | 挂起的 Stop，或状态为 `stopping` |
| 就绪 | 绿 | 运行时 ready 且 serverinfo 显示主机空闲 |
| 串流中 | 蓝 | serverinfo 显示有会话（`currentgame` 非 0，或 `_SERVER_BUSY`） |
| 错误 | 红 | 状态文件读不了/无效、过渡状态超过宽限期没完成（正在停止 300 秒、正在启动 120 秒）、或运行时 ready 但 serverinfo 不可达/无效 |

托盘每 2 秒重读一次状态文件；serverinfo 只在状态为 ready/running 时查询（1 秒超时，后台执行，不卡界面）。托盘的实现契约见 [tray-ui.md](tray-ui.md)。

菜单：

| 菜单 | 行为 |
|---|---|
| 启动 / 停止 | 调用 `gs-product.ps1 -Action Start/Stop`；操作挂起时两项都禁用 |
| 状态 | 弹窗显示托盘状态、状态文件路径、最近一次 CLI 结果和托盘日志路径 |
| 恢复卡住的会话 | 只在"串流中"可用；点击后先弹确认框（说明可能中断正在串流的客户端），确认后调用 `-Action Recover` |
| 生成支持包 | 调用同目录的 `gs-support.ps1`，成功后打开 zip 所在目录 |
| 打开日志 | 在资源管理器里打开 `<LogDir>`（不存在则打开托盘日志目录） |
| 退出 | 停止托盘；不会等在途的后台请求 |

**UAC**：托盘以登录用户身份运行，自己不提权。托盘非提权时，每次启动/停止都会通过 `-Verb RunAs` 拉起一个提权的 CLI 子进程，即每次操作弹一次 UAC；取消 UAC（Win32 错误 1223）会记日志并弹气泡，托盘继续运行。托盘本身提权时子进程静默启动。开机自启托盘需要你自己在启动文件夹建快捷方式（见下一节的说明）。

## 开机自启与暂停标志

**自启栈**（管理员）：

```powershell
& $p -Action RegisterAutostart
```

注册计划任务 `GsControllerSupervisor`：以 SYSTEM 身份运行 `<StateDir>\runtime\bin\gs_supervisor.ps1 -Cycle`，命令行带 `-ExecutionPolicy Bypass`；触发器为开机、登录，以及每 5 分钟一次的重复触发。取消自启用 `-Action UnregisterAutostart`（管理员）。

**托盘自启**：产品和托盘都不会替你建启动项。想让托盘开机出现，在 `Win+R` → `shell:startup` 里自己建一个快捷方式，目标就是上面的 `wscript.exe "<安装目录>\gs-tray.vbs"`。

**暂停标志**（两处路径，角色不同）：

- 规范位置（canonical）：`<StateDir>\runtime\state\supervisor_pause.flag`。产品层的 `Stop`（含 `PrepareUninstall` 的停机步骤）写这里——这也是 supervisor 实际读取的位置（见 [remote-client-test.md](remote-client-test.md) 第 5 节）。
- 旧位置（legacy）：`<StateDir>\supervisor_pause.flag`。旧版本产品写这里；现在只保留不覆盖：已存在的旧标志原字节不动、不删除，不存在也不会新建。
- **显式的手动 `Start` 成功 = 恢复自动守护**：运行时启动成功后，产品会同时清除两处的暂停标志；启动失败则保留原有暂停状态（运行时脚本删改过的会按启动前的字节快照恢复），不会静默丢失。清除失败会作为失败返回（`PauseCleanupFailed`），不会假报成功。
- `Recover` 不是恢复守护：它保留调用前已存在的暂停标志（原字节），只清理它自己的停机步骤实际创建的那个标志。
- 例外：如果某次失败运行在原本没有标志的位置留下了标志（例如运行时自己写入的），产品不会替你删它（可能是运行时故意保持暂停）；确认不需要暂停后手动删除存在的那个：

```powershell
Test-Path '<StateDir>\runtime\state\supervisor_pause.flag'
Test-Path '<StateDir>\supervisor_pause.flag'
Remove-Item '<存在的那个路径>' -Force
```

诊断报告的 `hygiene` 段会检查两个路径并报告 `SupervisorPaused`。

## 诊断与支持包

**诊断报告**（只读，不改任何东西，也不需要锁）：

```powershell
& $p -Action Diagnose
```

或者直接运行诊断脚本（输出 JSON）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '<安装目录>\gs-diagnose.ps1' -AsJson
```

- `-Action Diagnose` 在模块导入**之前**处理：模块坏了也能出诊断报告（前提是 `gs-diagnose.ps1` 本身可用；它坏了会返回结构化 `DiagnoseUnavailable`，而不是抛异常）。
- 报告是脱敏的：凭据样式的键值对、Authorization/Cookie 头、Bearer/Basic 令牌、PEM 块、32 字符以上的 base64/hex 串、URL 凭据参数、裸 PIN 值都会替换成 `<redacted>`。日志读取是有界的（默认只读最后 50 行、最多 8 MB、总超时内）。
- `hygiene` 段报告：自启任务状态（`OrphanedSupervisorTask` / `SupervisorTaskMissing`）、暂停标志（`SupervisorPaused`）、脚本目录 ACL（`ScriptDirWritableByNonAdmin`，严重度 high）、状态文件歧义（`StatusFileAmbiguous`）。

**支持包**：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '<安装目录>\gs-support.ps1'
```

把诊断报告和脱敏后的托盘日志尾部打成 zip（默认输出到 `%LOCALAPPDATA%\GsController\support`）。打包前做第二次扫描，发现疑似未脱敏的秘密就报 `RedactionCheckFailed` 且不生成 zip。包里**不会**包含：status.json 原文、运行时包内容、配对数据、证书、Moonlight 设置。内容清单见 support-bundle.md。

## 恢复卡住的会话（Recover）

适用场景：主机状态是 `ready`、serverinfo 的 `currentgame = 1`，但没有客户端连着——一次异常退出后主机卡在"有会话"的状态。

```powershell
& $p -Action Recover
```

前提（全部满足才执行；任一检查跑不了就拒绝——失败即关闭）：

1. 状态文件 `state = ready`；
2. serverinfo 有效（统一有效性规则）且 `currentgame` 恰好为 `1`；
3. 47984/48010 端口上没有 Established 状态的 TCP 连接（47989 永远排除）。

**警告：连接检查只看 TCP。** 串流的视频/音频/输入走 UDP（47998-48000），一个活跃的 Moonlight 会话在 RTSP 建立之后可能根本没有 47984/48010 上的 TCP 连接。所以"没看到 TCP 连接"不等于"没有客户端"——**在你知道没有客户端正在串流时才运行 Recover**，否则它的 Stop/Start 可能打断一个真实会话。

拒绝原因（拒绝时不执行任何 Stop/Start）：

| Reason | 含义 |
|---|---|
| `StatusUnavailable` | 状态文件不存在或读不了/解析不了 |
| `NotReady` | 状态不是 `ready`（或 state 字段不是字符串） |
| `ServerInfoUnavailable` | 请求失败、非 200（重定向不跟随）、或响应体无效/超时/超大 |
| `NoStuckSession` | `currentgame` 存在但不是 1——没有卡住的会话可清 |
| `ClientConnected` | 检测到活跃客户端连接 |
| `ConnectionCheckFailed` | 端口参数非法或 TCP 连接枚举失败 |
| `ClientTrafficDetected` | 出站流量超过空闲阈值，宁可拒绝 |

每条拒绝都带 `Observed`（实际观察到的状态、HTTP 码、currentgame、连接数），排查时把它一起记下来。成功后 `Data` 带 `StopExitCode`、`StartExitCode`。详见 [lifecycle-hardening.md](lifecycle-hardening.md)。

## 升级

1. 先停栈：`& $p -Action Stop`，确认 `-Action Status` 已停。
2. 安装新的 MSI（更高版本会就地升级，`MajorUpgrade`）。
3. 重新部署组件并校验：`-Action Install -ComponentSourceDir ...`，然后 `-Action Check`。
4. 重新注册自启（如果之前注册过）：`-Action RegisterAutostart`。
5. `-Action Start` 并用客户端连一次确认。

升级不会动 `<StateDir>` 和 `<LogDir>`；运行时包更新后用 `-Action Diagnose` 的 `runtimeBundle` 段核对部署文件的哈希。

## 回退

`MajorUpgrade` 拒绝降级安装，所以回退 = 先卸载当前版本，再装旧版 MSI。完整步骤（含从发布档案取旧 MSI、核对哈希、重新部署）见 [release-manifest.md](release-manifest.md)。**第 1、2 步必须在管理员 PowerShell 里运行；先清理自启任务、确认任务已删除，再卸 MSI——顺序不能反。**要点：

1. **（管理员，必须第一步）清理自启任务**：`& $p -Action PrepareUninstall`——它在生命周期锁内先 Stop，再删除计划任务 `GsControllerSupervisor`。0.2.0 还没有 PrepareUninstall 时的等价回退（同样管理员）：`& $p -Action Stop`，然后 `& $p -Action UnregisterAutostart`。
2. **确认任务已删除再继续**：`Get-ScheduledTask -TaskName GsControllerSupervisor` 必须报"找不到"（`NotFound`）；任务还在就回到第 1 步重做（PrepareUninstall 幂等）或用上面的手动回退，确认删干净再进行下一步。
3. **（管理员）卸载当前版本**：

   ```powershell
   msiexec /x <当前版本>
   ```

4. 安装旧版 MSI：

   ```powershell
   msiexec /i <发布档案里的旧版 MSI>
   ```

5. `-Action Install`、`-Action Check`、`-Action Start`，客户端连一次确认。

旧版 MSI 不会自动清理自启任务；当前安装器源码已加入普通完整卸载时的清理接线，但尚未通过真实 VM 验收，且失败不阻断卸载。回退继续按第 1、2 步先清理并确认任务不存在；不能把 MSI 退出成功当作清理成功。新版卸载回滚也可能恢复文件却不恢复已删除的任务，必要时重新 `RegisterAutostart`。详见 [MSI 卸载清理](msi-uninstall-cleanup.md)。

## 卸载

卸载分三步：清理 → 卸 MSI → （可选）手动清数据。**数据默认保留。**旧版 MSI 不删除计划任务；当前安装器源码在普通完整卸载时依次调用默认布局的 `PrepareUninstall` 和固定任务删除兜底，升级移除旧产品时不执行这些动作。该路径只完成离线验证，真实卸载仍待 VM 验收，清理失败不会阻断 MSI。下述显式清理流程仍适用于旧版、回退和需要确认结果的维护操作；自定义 StateDir/LogDir 必须传入该实例的实际路径先行清理。

**第 1 步：清理——管理员 PowerShell（；必须在卸载之前完成）**：

```powershell
& $p -Action PrepareUninstall
```

在生命周期锁内先 Stop，再删除 `-SupervisorTaskName`（默认 `GsControllerSupervisor`）指定的计划任务；只有要删任务时才要求提权，不提权返回 `ElevationRequired` 且什么都不做。停栈失败不会阻止删任务（卸载清理优先：错误保留在结果里，任务仍然删除）。StateDir 和 LogDir 保留。结果 `Data`：`{ Stopped; TaskRemoved; TaskExisted; StateDirKept; LogDirKept }`。命令幂等，可重复执行。

**第 1 步之后、卸 MSI 之前，先确认任务已经删除**：`Get-ScheduledTask -TaskName GsControllerSupervisor` 应报 `NotFound`；任务还在就重跑第 1 步（幂等）或用下面的手动等价操作，确认删干净再继续第 2 步。

如果这一步还不可用（旧版本），手动等价操作（管理员）：

```powershell
& $p -Action Stop
& $p -Action UnregisterAutostart
```

手动路径同样先确认任务已删除（同上），再进入第 2 步。

**第 2 步：卸 MSI**：

```powershell
msiexec /x C:\path\to\GsController-<版本>.msi /qn
```

**第 3 步：确认数据保留。** MSI 只管理 `C:\Program Files\Local Development\GsController` 这个安装目录本身；`<StateDir>`、`<LogDir>` 和组件副本不属于 MSI 的组件，卸载后预期仍在（发布清单注明"未在真实卸载上验证"，卸载后自己确认一眼）。

**手动清理清单**（想彻底清干净时逐项检查）：

| # | 检查项 | 说明 |
|---|---|---|
| 1 | 计划任务 `GsControllerSupervisor` | `Get-ScheduledTask -TaskName GsControllerSupervisor`；还在就 `Unregister-ScheduledTask -TaskName GsControllerSupervisor -Confirm:$false`（管理员）。残留的任务会每 5 分钟把栈拉起来一次 |
| 2 | 安装目录残留 | `Import-GsRuntimeTree` 复制进去的组件树（Broker、bin 等）不是 MSI 管理的文件，卸载后可能残留，确认后删除 |
| 3 | 托盘启动快捷方式 | 如果你在 `shell:startup` 建过，手动删除 |
| 4 | 暂停标志 | 规范位置 `<StateDir>\runtime\state\supervisor_pause.flag` 与旧位置 `<StateDir>\supervisor_pause.flag`，确认后手动删除存在的那个 |
| 5 | StateDir / LogDir | 含三个 JSON 配置、状态文件和全部日志；**确定不再需要**才删，删之前可先打一个支持包（见[诊断与支持包](#诊断与支持包)）留档 |

## 客户端连接

当前产品没有可用于新客户端首次配对的主机端确认入口，公开运行时契约也尚未提供配对调用方式。因此首次安装到首次配对仍是交付阻塞，不能只让用户在 Moonlight 中反复输入或重试 PIN。[remote-client-test.md](remote-client-test.md) 是**已配对客户端**的串流验收指南，不包含完整首次配对流程；所需接口和验收条件见 [首次配对交付条件](first-pairing-readiness.md)。这里只列两类历史已验证/在册的客户端。不要把客户端的配对数据、证书或私钥复制出设备。

- **MacBook 客户端**：Moonlight 6.2.0，支持命令行参数，例如：
  ```bash
  Moonlight stream <主机IP> "Desktop" --4K --fps 60 --bitrate 50000 --display-mode fullscreen --video-codec HEVC --performance-overlay
  ```
- **Android 电视盒客户端**（客厅有线接入的通用 Android TV box）：Moonlight for Android 12.2。**Android 版没有命令行参数**，分辨率/帧率/码率/解码器等设置都要在 Moonlight 设置界面里用遥控器选择，然后把设置页面截图作为证据。设备能力事实（写计划时用）：有线千兆；HEVC/H.264 硬件解码，无 AV1 解码器；电视 EDID 无任何 HDR EOTF；4K60 只在一个 HDMI 口上以 4:2:0 8-bit 支持；音频 PCM 2 声道。兼容性用例见 [compatibility-test-plan.md](compatibility-test-plan.md)，稳定性用例见 [stability-test-plan.md](stability-test-plan.md)。

串流前把主机上的大窗口应用（例如 Claude 桌面版）**最小化**：NVIDIA 会把没最小化的窗口当成"本地正在运行的全屏游戏"，拒绝启动 Desktop，客户端报错误码 526（见[故障排查](troubleshooting.md)）。

正常退出客户端（`Moonlight quit <主机>`；Android 版在应用列表长按 Desktop → "退出串流" → "确定"）后，主机应在 10 秒内回到空闲。串流中按返回键只断开连接，**不**结束主机会话。**不要强杀客户端进程**——强杀会让主机串流进程驻留、主机一直忙（见[故障排查](troubleshooting.md)）。

## 已知限制

- **VBScript 弃用**：托盘靠 `gs-tray.vbs` 隐藏启动。微软已将 VBScript 列为弃用（先转为按需功能，未来版本再移除；社区帖子提到的 2027 年秋时间点不是官方口径）。后续以编译的启动器替代，当前不受影响但已列入后续工作。
- **MSI 未签名**：安装时显示"未知发布者"，SmartScreen 可能提示。签名方案与验收清单见 [msi-signing.md](msi-signing.md)。
- **supervisor 周期不取生命周期锁**：手动 Start/Stop/Recover 之间互斥，但 supervisor 自己的 5 分钟周期在黑盒运行时里，不取这把锁，仍可能与手动操作并发。Stop 路径会先暂停 supervisor 就是为此。
- **Recover 只看 TCP**：可能打断一个真实会话（见[恢复卡住的会话](#恢复卡住的会话recover)的警告）。
- **状态文件优先于 serverinfo**：状态文件不存在时托盘显示已停止，即使 47989 有响应（47989 可能属于主机上另一个串流程序）。
- **`running: true` 不验证进程身份**：PID 可能被复用，诊断报告的组件运行状态只是"存在这个 PID 的进程"。
- **Stop 长达约 140 秒（2026-10-31 现场发现，误报已修复）**：Stop 恢复官方服务后最多等 90 秒官方 serverinfo，本机实测每次都等满，整个 Stop 稳定在 138–142 秒。托盘对"正在停止"状态的过渡宽限期已从 120 秒放宽到 300 秒（与托盘自身等待 CLI 子进程的上限一致），真实的约 140 秒 Stop 全程显示"正在停止"，完成后转"已停止"，不再出现"Stopping did not finish"误报；只有严格超过 300 秒仍未完成，托盘才显示红色"Stopping did not finish"并恢复两个操作。
- **NVIDIA 服务日志写满 4 MB 后停止**：`nvstreamsvcCurrent.log` 到 4,000,000 字节就关闭，之后的会话没有服务端日志，直到服务重启。排查时先看文件末尾是否是 `Log file closed as it went over the size limit`。
- **CLI 输出英文**：按约定只把托盘界面和运维文档做成中文。
- **重定向日志里的中文乱码**：控制台代码页 gb2312 导致的环境问题，不是产品缺陷；见[故障排查](troubleshooting.md)。
- **AllSigned 下跑不了 Start/Stop/supervisor**：运行时辅助脚本在安装时被改写，签名无法存活；自启任务带 `-ExecutionPolicy Bypass`。签名对它们只提供篡改证据，不提供执行策略强制。
- **720p 握手慢**：验收时 `Video stream is` 出现用了 17 秒；等待窗口至少 30 秒，重测用例见 [stability-test-plan.md](stability-test-plan.md)（S6）。
