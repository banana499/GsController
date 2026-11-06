# 稳定性测试计划：长时间运行与重连

日期：2026-10-31。对应路线图第 6 项与第 8 项的验收。格式与 [compatibility-test-plan.md](compatibility-test-plan.md)一致：用例、步骤、通过标准、证据；没有跑过的用例一律 `not covered`，有证据才改状态。

监控工具是 `tools\gs-soak-monitor.ps1`（参数以契约 K6 为准）。`-OutputDir` 必须在仓库外（工具会拒绝仓库内路径），每次运行写 `samples.csv`、`events.jsonl`、`summary.json`。

## 范围

- 长时间会话（30–60 分钟 4K60）与期间的内存、进程、会话状态采样。
- 网络中断与恢复（无线断开、有线拔线）。
- 客户端睡眠/唤醒后的会话恢复。
- 主机显示模式切换期间的会话表现。
- Start/Stop 循环 10 次（路线图第 8 项：验收"连续 10 次没有超时"）。
- 720p 用更长窗口重测（来自 [acceptance-evidence.md](acceptance-evidence.md) 的备注：那次握手 17 秒才出现 `Video stream is`）。

不在范围：HDR/AV1/环绕声/手柄（兼容性计划）、其他 GPU 与驱动（路线图第 7 项）、配对流程本身。

## 基线客户端

| 项 | MacBook 客户端 | 电视盒客户端 |
|---|---|---|
| 描述 | MacBook Pro，Wi-Fi 接入 | 有线千兆接入的 Android TV 盒（通用描述） |
| Moonlight | 6.2.0（支持命令行参数） | for Android 12.2（**无命令行参数**，设置在应用界面里选择并截图记录） |
| 解码能力 | HEVC（含 4K60 实测基线） | HEVC/H.264 硬件解码；无 AV1 解码器 |
| 显示 | 内置屏 | 电视 EDID 无任何 HDR EOTF；仅一个 HDMI 口支持 4K60，且只有 4:2:0 8-bit |
| 音频 | 立体声 | PCM 2 声道 |
| 网络 | Wi-Fi（S2 用关 Wi-Fi 制造中断） | 有线千兆（S2 用拔网线制造中断） |

用例 ID 前缀区分客户端：`STB-…-MAC` / `STB-…-TV`。电视盒已于 2026-10-31 完成手动配对；每次测试前仍应确认配对有效。需要重新配对时，由操作者按 [remote-client-test.md](remote-client-test.md) 完成，自动化不尝试配对。

2026-10-31 夜间已有 30 分钟电视盒 4K60 HEVC 串流记录：180 次采样正常、59.8 FPS，退出后 3–4 秒回空闲；另有 10 次强杀 supervisor 和 6 轮 CLI Stop/Start 成功记录，见 [路线图](product-roadmap.md)。这些结果不替代下表要求的 60 分钟窗口、正式 10 次 Cycle 和完整证据集，因此矩阵行继续保留 `not covered`，直到逐项验收。

## 状态

| 状态 | 含义 |
|---|---|
| `pass` | 通过标准全部满足，证据路径已填 |
| `fail` | 前提满足、用例已跑、至少一条通过标准不满足；`原因` 写明失败项 |
| `unsupported` | 因客户端/主机/协议的能力原因不可能通过（须写明依据） |
| `not covered` | 未测试。所有行的初始状态 |

## 用例矩阵

监控命令统一为（`<证据目录>` 由通用步骤 P-STB-COMMON 创建；`$soak` = `tools\gs-soak-monitor.ps1` 的路径）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $soak -Mode Monitor -DurationMin <分钟> -IntervalSec <秒> -OutputDir <证据目录>
```

S5 循环模式由操作者以管理员身份运行：`-Mode Cycle -Count 10 -Execute`（不带 `-Execute` 只打印计划，不执行）。

| ID | 场景 | 客户端与设置 | 前提 | 步骤与监控命令 | 通过标准 | 证据要求 | 状态 | 证据路径 | 原因 |
|---|---|---|---|---|---|---|---|---|---|
| STB-S1-MAC | 4K60 持续 30–60 分钟 | MacBook，HEVC 4K60 50 Mbps（命令行参数同兼容性基线） | 主机 Ready；配对完成 | P-STB-COMMON；监控 `-Mode Monitor -DurationMin 60 -IntervalSec 10` | 通用标准全满足；期间无断流 | 通用证据 + 性能叠加层截图（窗口中段与结束前各一张） | not covered |  |  |
| STB-S1-TV | 4K60 持续 30–60 分钟 | 电视盒，HDMI 4K60（4:2:0 8-bit），HEVC，叠加层开启 | 主机 Ready；电视盒已配对 | P-STB-COMMON；监控 `-Mode Monitor -DurationMin 60 -IntervalSec 10` | 通用标准全满足；期间无断流；叠加层解码帧率不低于 57 FPS | 通用证据 + 叠加层截图（遥控操作，截图存设置页与性能页） | not covered |  |  |
| STB-S2-MAC | 无线中断：Wi-Fi 关闭 10 秒与 60 秒各一次 | MacBook，4K60 HEVC | 主机 Ready；会话进行中 | P-STB-COMMON；监控 `-Mode Monitor -DurationMin 15 -IntervalSec 5`；第 5 分钟关 Wi-Fi 10 秒后开，第 10 分钟关 60 秒后开 | 10 秒中断后会话自动恢复或客户端明确提示重连；60 秒中断后客户端能重新连接；无孤儿进程；主机最终回 Ready | 通用证据 + 两次中断的时间点记录（record.md） | not covered |  |  |
| STB-S2-TV | 有线中断：拔网线 10 秒与 60 秒各一次 | 电视盒（有线，故 S2 用拔线而不是关 Wi-Fi），4K60 HEVC | 主机 Ready；电视盒已配对 | P-STB-COMMON；监控 `-Mode Monitor -DurationMin 15 -IntervalSec 5`；第 5 分钟拔线 10 秒后插回，第 10 分钟拔 60 秒后插回 | 同 STB-S2-MAC | 同 STB-S2-MAC | not covered |  |  |
| STB-S3-MAC | 客户端睡眠后唤醒 | MacBook，4K60 HEVC | 主机 Ready；会话进行中 | P-STB-COMMON；监控 `-Mode Monitor -DurationMin 20 -IntervalSec 5`；第 5 分钟合盖睡眠 60 秒后唤醒 | 唤醒后会话恢复或干净终止；无孤儿进程；主机在客户端退出后 10 秒内回空闲 | 通用证据 + 睡眠/唤醒时间点 | not covered |  |  |
| STB-S3-TV | 客户端待机后唤醒 | 电视盒，4K60 HEVC；若设备无待机能力则记 `unsupported` 并写依据 | 主机 Ready；电视盒已配对 | P-STB-COMMON；监控 `-Mode Monitor -DurationMin 20 -IntervalSec 5`；第 5 分钟待机 60 秒后唤醒 | 同 STB-S3-MAC | 同 STB-S3-MAC | not covered |  |  |
| STB-S4-MAC | 主机切换显示模式 | MacBook，会话进行中（1080p60 起） | 主机 Ready；会话进行中 | P-STB-COMMON；监控 `-Mode Monitor -DurationMin 20 -IntervalSec 5`；会话第 5 分钟在主机上切换一次显示模式（如 2160p↔1080p），观察会话反应 | 会话不崩溃或干净重连；主机无残留进程；结束无 Busy/超时 | 通用证据 + 切换前后叠加层截图 | not covered |  |  |
| STB-S4-TV | 主机切换显示模式 | 电视盒，1080p60 起 | 同 STB-S4-MAC | 同 STB-S4-MAC | 同 STB-S4-MAC | 同 STB-S4-MAC | not covered |  |  |
| STB-S5-MAC | Start/Stop 循环 10 次（路线图第 8 项） | 循环本身无客户端；循环结束后由 MacBook 发起一次会话验证 | 操作者本人在场，管理员 PowerShell | 操作者以管理员运行监控 `-Mode Cycle -Count 10 -Execute`；结束后按 P-STB-COMMON 从 MacBook 连一次 | `summary.json` 的 `cycleResults` 10 次全部成功；无 Busy、无超时；随后客户端能正常连接并退出 | 证据目录里的 `summary.json`、`events.jsonl` + 会话验证的通用证据 | not covered |  |  |
| STB-S5-TV | Start/Stop 循环 10 次 | 循环本身无客户端；循环结束后由电视盒发起一次会话验证 | 同 STB-S5-MAC；电视盒已配对 | 同 STB-S5-MAC；验证会话从电视盒发起（遥控操作，叠加层确认帧率） | 同 STB-S5-MAC | 同 STB-S5-MAC | not covered |  |  |
| STB-S6-MAC | 720p 重测（30 秒窗口） | MacBook，720p60 HEVC（命令行参数同兼容性基线，分辨率换 720p） | 主机 Ready；配对完成 | P-STB-COMMON；监控 `-Mode Monitor -DurationMin 10 -IntervalSec 5`；客户端日志等待窗口给满 30 秒 | `Video stream is` 在 30 秒内出现；记录握手用时作为延迟基线；通用标准满足 | 通用证据 + 握手用时记录 | not covered |  |  |
| STB-S6-TV | 720p 重测（30 秒窗口） | 电视盒，720p60 HEVC，界面里设置 | 主机 Ready；电视盒已配对 | 同 STB-S6-MAC | 同 STB-S6-MAC | 同 STB-S6-MAC | not covered |  |  |

更新一行的方法：改 `状态`，`证据路径` 填用例证据目录，`fail`/`unsupported` 在 `原因` 写依据（电视盒的能力结论引用其设置截图与系统探测证据）。

## 步骤：P-STB-COMMON

1. 建证据目录（仓库外）：
   ```powershell
   $dir = 'C:\gs-evidence\stability-<用例ID>-' + (Get-Date -Format 'yyyyMMdd_HHmmss')
   New-Item -ItemType Directory -Path $dir | Out-Null
   ```
2. 主机：`& $p -Action Start`，确认 `-Action Status` 就绪，把输出存为 `host-status-before.txt`。
3. 启动监控（上表里的命令，`-OutputDir` 指向证据目录）；确认 `samples.csv` 在增长。
4. 客户端发起会话（MacBook 用命令行，电视盒在应用界面里操作）；记录发起时间。
5. 按用例行执行场景动作（中断/睡眠/切换/循环）。
6. 客户端正常退出（`Moonlight quit <主机>` 或界面退出；**不要强杀**），记录退出时间；从 `summary.json` 读 `secondsToAvailableAfterQuit`。
7. 停止监控，保存 `samples.csv`、`events.jsonl`、`summary.json`；主机：`& $p -Action Status` 存为 `host-status-after.txt`；必要时跑一次 `-Action Diagnose` 存为 `diagnose.json`。
8. 填 `record.md`（时间点、观察、截图清单），更新矩阵行。

## 通过标准（通用）

以下以 `summary.json` 字段为准（字段名以契约 K6 为准；阈值全部是**暂定**值，第一次真实跑完后调整）：

- **无孤儿进程**：`events.jsonl` 中"状态已停止但记录的 PID 还活着"的事件数为 0（`pidChanges` 只记录，不单独判失败）。
- **主机及时释放**：客户端正常退出后 `secondsToAvailableAfterQuit` ≤ 10 秒。
- **内存斜率**：`memorySlopeMBPerHour` ≤ 50 MB/小时（暂定阈值；S1 的 60 分钟窗口是主要数据来源）。
- **无 Busy 或超时**：整个窗口内没有 `Busy` 事件，S5 的 `cycleResults` 无失败、无超时；工具的最终 `verdict` 不是失败。
- 任一标准不满足即 `fail`，把字段值和对应时间点写进 `原因`。

## 证据目录

与验收证据同根（`C:\gs-evidence` 或 NAS 共享），仓库外：

```text
<证据根>\stability-<用例ID>-<yyyyMMdd_HHmmss>\
  record.md                 时间点与观察，操作者填写
  samples.csv               监控采样
  events.jsonl              状态/PID/会话/孤儿事件
  summary.json              结论字段（verdict、斜率、secondsToAvailableAfterQuit、cycleResults…）
  host-status-before.txt    会话前的产品 Status 输出
  host-status-after.txt     结束后的产品 Status 输出
  diagnose.json             需要时的诊断报告
  overlay-*.png             客户端性能叠加层截图
```

证据里不放入配对数据、证书、密钥；客户端日志如带会话密钥，复制前替换为 `<redacted>`。
