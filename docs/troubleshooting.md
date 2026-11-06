# 故障排查

更新时间：2026-11-01。按"现象 → 检查 → 处理"组织。通用准备：先跑一次只读诊断（`& $p -Action Diagnose`，模块坏了也能出报告），把路径速查表 [file-locations.md](file-locations.md) 放在手边。命令行里 CLI 的结果对象是输出中最后一个带 `Success` 属性的对象；`Message` 是英文，错误码含义见各条目。

## 排查表

| 现象 | 检查 | 处理 |
|---|---|---|
| 托盘红色（错误），提示"runtime ready but serverinfo unreachable" | 状态文件是 ready/running，但 `http://127.0.0.1:47989/serverinfo` 没有应答或非 200。手动访问一次确认；看状态文件确认运行时确实起来了 | 刚启动的话等启动完成（过渡状态最长信任：正在启动 120 秒、正在停止 300 秒，超过按"过渡未完成"处理）；仍然不可达就 `Stop` → `Start` 重来一次，再不行跑 `Diagnose` 看 serverinfo 段的详细错误码（Timeout / RequestFailed 等） |
| 托盘红色（错误），提示"runtime ready but serverinfo invalid" | 返回了 200 但内容不过统一有效性规则（根元素不是 `root`、`status_code` 不是 200、缺 `<state>`/`<currentgame>`、超过 64 KB、超时）。注意：47989 上可能跑着主机上另一个程序 | 用 `netstat -ano \| findstr :47989` 看是谁在监听 47989；串流程序没起来时先 `-Action Start`。托盘以状态文件为准：状态文件不存在时显示"已停止"，即使 47989 有应答 |
| `Busy`（CLI 或托盘气泡"另一个生命周期操作正在运行"） | 另一个 Start/Stop/Recover 正持有生命周期锁（托盘子进程最长等 300 秒）。`-Action Status` 不取锁，可以随时查 | 等当前操作结束。互斥靠命名互斥体，持有者异常退出后系统会释放，不需要手动清理；`lifecycle.lock` 文件残留**不会**导致持续 Busy |
| Recover 拒绝：`StatusUnavailable` | 状态文件缺失、读不了或解析失败（拒绝时带 `Observed.StatusPath`） | 跑 `-Action Status` 看返回码（`NotInstalled` = 没部署；`StatusReadFailed` = 权限，见下）；没部署就重新 `-Action Install`。两个候选路径都检查（见 [file-locations.md](file-locations.md)） |
| Recover 拒绝：`NotReady` | 状态不是 `ready`（或 state 字段不是字符串） | 先 `-Action Start` 把栈拉起来，确认 `-Action Status` 是 ready 后再 Recover。消息里含 `state field is not a string` 说明状态文件内容形状不对，看一眼文件本身 |
| Recover 拒绝：`ServerInfoUnavailable` | 请求失败 / 非 200（重定向不跟随）/ 响应体无效、超时（默认 3 秒）或超 64 KB | 手动访问 `http://127.0.0.1:47989/serverinfo` 确认内容有 `<root status_code="200">`、非空 `<state>`、数字 `<currentgame>`；主机忙时稍等再试；必要时用 `-ServerInfoUri` / `-ServerInfoTimeoutSec` 调整 |
| Recover 拒绝：`NoStuckSession` | `currentgame` 不是 1：没有卡住的会话 | 如果 `currentgame` 是某个应用 ID，可能是一个真实会话——按"主机一直忙"一条处理，不要强行 Recover |
| Recover 拒绝：`ClientConnected` | 47984/48010 上有 Established TCP 连接 | 让客户端正常退出（`Moonlight quit <主机>`），确认 Moonlight 显示主机"可用"后再 Recover |
| Recover 拒绝：`ConnectionCheckFailed` | `-ClientPorts` 里有非法端口，或排除 47989 后端口集为空，或 TCP 连接枚举失败 | 检查命令行的 `-ClientPorts` 参数（默认 47984、48010）；枚举失败通常是系统瞬时问题，重试 |
| Recover 拒绝：`ClientTrafficDetected` | Recover 前的出站流量采样超过空闲阈值 | 这是有意设计（宁可拒绝，偏向安全）：主机上其他程序的流量（上传、备份、更新）也会触发。停掉大流量程序后重试；确认没有客户端串流后仍被拦的，记录 `Observed` 并人工评估 |
| `StatusReadFailed`（`-Action Status` 或托盘"Status file unreadable"） | 状态文件存在但当前用户读不了（权限问题；产品从不改 ACL，本机 ACL 是手工收紧的） | 用管理员 PowerShell 读一次确认；托盘场景的预期恢复路径是从提权的环境跑 Start。不要为读状态文件放宽 StateDir 的 ACL（见 [threat-model.md](threat-model.md)） |
| 强杀客户端后主机一直忙 | 强杀会让串流进程驻留、主机停在"有会话"状态——这是已知现象，不是产品缺陷 | 优先预防：永远正常退出客户端。已经卡住时：确认没有客户端在串流（看客户端、看 47984/48010 连接），然后按[恢复卡住的会话](operator-guide.md#恢复卡住的会话recover)运行 `-Action Recover`；注意它只看 TCP，可能打断真实会话 |
| 客户端报"连接错误"，错误码 526（"Cannot launch the game as it's been started locally"） | 主机上有一个非最小化的窗口被 NVIDIA 判定为"本地正在全屏运行的游戏"。2026-10-31 实测：Claude 桌面窗口只要没最小化（哪怕没最大化、只是超出屏幕边界）就会触发，主机服务日志写 `Failed to launch app as other game: "<程序>" is already running in fullscreen` | 串流前把主机上的大窗口应用最小化，再在客户端重新点 Desktop。不是运行时故障，不需要 Stop/Start |
| 串流中按了返回键，盒子回到应用列表，但主机一直是"串流中"（serverinfo `currentgame = 1`、BUSY） | Moonlight 的返回键只**断开**连接，不结束主机会话；Desktop 卡片上会显示播放图标 | 在客户端长按 Desktop → "退出串流" → "确定"（Android 版），或 `Moonlight quit <主机>`（命令行版）。实测主机 3–4 秒内回到空闲 |
| Stop 要 2 分多钟（2026-10-31 现场发现，误报已修复） | Stop 恢复官方服务后，要等官方 serverinfo 返回 200，最多 90 秒；本机每次都等满 90 秒才放弃（官方服务刚启动时不应答），整个 Stop 稳定在 138–142 秒。旧托盘对所有过渡统一用 120 秒超时，导致 Stop 结束前短暂出现红色"Stopping did not finish"误报 | 已修复：托盘对"正在停止"状态的宽限期为 300 秒（与托盘等待 CLI 子进程的上限一致），整个 Stop 期间保持"正在停止"，完成后转"已停止"。等 Stop 返回再操作，用 `-Action Status` 或日志确认已停（`runtime\logs\stop_*.log` 最后一行 `DONE: official service mode`）；若严格超过 300 秒仍未完成，托盘才显示红色"Stopping did not finish"并恢复两个操作供手动处理 |
| 自动守护一直处于暂停（Stop→Start 之后 supervisor 不再自动恢复） | 显式的手动 `Start` 成功会清除两处暂停标志（规范位置 `<StateDir>\runtime\state\supervisor_pause.flag`、旧位置 `<StateDir>\supervisor_pause.flag`），清除失败会返回 `PauseCleanupFailed` 而不是假报成功；守护仍未恢复多半是有产品不删的残留标志（例如失败运行中运行时自己写入的、或旧版本留下的） | 先看诊断报告 `hygiene` 段的 `SupervisorPaused`（两个路径都检查），确认运行时状态正常后手动删除存在的标志文件；`Start` 失败会保留并按快照恢复原有暂停（错误码 `PauseSnapshotFailed`/`PauseRestoreFailed` 里的 `Path` 指出问题标志） |
| 720p 握手慢（客户端日志里 `Video stream is` 很久才出现） | 验收时 720p 用了 17 秒（20 秒窗口差点截到） | 等待窗口至少给 30 秒再判定失败；按 [stability-test-plan.md](stability-test-plan.md) 的 S6 用 30 秒窗口重测并记录延迟基线 |
| 重定向的日志文件里中文是乱码 | 控制台代码页是 gb2312：`[Console]::OutputEncoding` 与文件编码不一致导致，环境问题而非产品缺陷 | 读文件时显式按 UTF-8 读（`[IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)`）；需要重定向时先 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`。产品自身写的文件（托盘日志、JSON 结果）都是 UTF-8（无 BOM），不受影响 |
| 重启后托盘不见了 | 产品和托盘都不会自己建启动项；托盘只在有人启动时存在 | 按 [operator-guide.md](operator-guide.md) 的"开机自启与暂停标志"，在 `shell:startup` 里手动建 `wscript.exe "<安装目录>\gs-tray.vbs"` 快捷方式 |
| 卸载后栈还在每 5 分钟被拉起来 | 旧版 MSI 没有任务清理接线；新版接线也可能因权限、运行时损坏或自定义布局未完成清理，MSI 退出成功不能证明任务已删除。查询任务调度器，只有明确 NotFound 才能当作不存在，访问/RPC 错误不能算成功 | 卸载前先 `-Action PrepareUninstall`或 `-Action UnregisterAutostart`；已经卸载完的就手动 `Unregister-ScheduledTask -TaskName GsControllerSupervisor -Confirm:$false`（管理员），见 [operator-guide.md](operator-guide.md) 的手动清理清单 |
