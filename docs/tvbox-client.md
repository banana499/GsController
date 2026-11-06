# 电视盒客户端（Android TV 盒）

本文说明第二个测试客户端：客厅的 Android 电视盒。内容包括怎么连接、探测脚本采集什么、证据放在哪里，以及它对兼容性矩阵的影响。文中的设备数值是 2026-10-31 在原验证机上采集的历史记录；证据目录不随公开仓库提供，详见第 5 节。

仓库里不写盒子的 IP 地址、序列号、Android ID、MAC 地址或电视的 EDID 序列号。盒子地址在文档里写作 `<box-ip>:5555`，示例和测试数据用文档保留网段 `192.0.2.10`。探测脚本和集成测试从 `-Device` 参数或环境变量 `GS_TVBOX_DEVICE` 取地址，脚本里没有默认地址。

## 1. 设备概况

| 项 | 值 |
|---|---|
| 型号 | A4091（Amlogic） |
| 系统 | Android 9（SDK 28），用户空间 32 位 `armeabi-v7a` |
| 内存 | 3.9 GB |
| 网络 | `eth0` 有线 1000 Mbps 全双工 |
| 输出 | 电视的 HDMI 3 接口，`2160p60hz`，YCbCr 4:2:0 8bit |
| Moonlight | Android 版 12.2（versionCode 315），包名 `com.limelight` |
| 配对 | 2026-10-31 已由操作者完成，并完成 30 分钟 4K60 HEVC 串流；后续 6 轮 Stop/Start 后的配对持久性尚待现场确认。新配对仍需用户输入 PIN，脚本和自动化不自动配对 |

## 2. 连接

主机通过 ADB 访问盒子，不需要 Mac 桥。主机需要持有已被盒子授权的 ADB 密钥。

```bash
adb connect <box-ip>:5555
```

```bash
adb -s <box-ip>:5555 get-state
```

命令里的 `adb` 需要能被找到：把 `adb.exe` 所在目录放进 PATH，或者用探测脚本的 `-AdbPath` 参数传完整路径（含空格也可以）。集成测试同样接受 `-AdbPath`，省略时按 PATH 解析。

`get-state` 输出 `device` 才算可用；`unauthorized` 或 `offline` 时探测脚本按"不可达"处理，不会去改授权。

在 Git Bash 里执行带 `/sys/...` 路径的 `adb shell` 命令前，先执行 `export MSYS_NO_PATHCONV=1`，否则路径会被改写。PowerShell 里不需要。

**只有协调会话操作盒子。** 同一时间只能有一个会话驱动盒子：发送按键、启动 Moonlight、截图、配对，以及对真盒子运行探测脚本或集成测试，都由协调会话做，其他会话只用假 adb 输出跑单元测试。协调会话正在操作盒子时，不要并发运行任何 adb 命令。

遥控操作时注意：Amlogic 的确认框（例如切换输出分辨率后的确认框）默认焦点在"取消"上，要先按 `KEYCODE_DPAD_RIGHT` 把焦点移到"确定"，再按 `KEYCODE_DPAD_CENTER`。直接按确认键会取消操作。

## 3. 探测脚本

`client/Get-TvBoxCapabilities.ps1`（Windows PowerShell 5.1）。

```powershell
.\client\Get-TvBoxCapabilities.ps1 -Device '<box-ip>:5555' -OutFile "C:\gs-evidence\tvbox-probe-$(Get-Date -Format yyyyMMdd_HHmmss)\probe.json"
```

参数：

| 参数 | 默认值 | 作用 |
|---|---|---|
| `-AdbPath` | 空 | adb.exe 完整路径（含空格也可以）。省略时按 PATH 解析第一个 `adb.exe`；两者都找不到时返回 `AdbNotFound` 错误，不启动任何进程。解析只认真正的 `adb.exe` 文件，别名、函数和 `.bat`/`.cmd` 之类的包装一律忽略，也不会经过 shell |
| `-Device` | 空；省略时读环境变量 `GS_TVBOX_DEVICE` | adb 目标，例如 `<box-ip>:5555`。两者都没有时不运行任何 adb 命令，返回 `NoDevice` 错误 |
| `-OutFile` | 空 | 同时把 JSON 写到这个文件（UTF-8，无 BOM），目录不存在会创建 |
| `-TimeoutSec` | 15 | 每次 adb 调用的超时，超时后结束 adb 进程 |
| `-AdbRunner` | 空 | 测试接口，单元测试用它注入假的 adb 输出 |

退出码：`0` 全部采集成功；`1` 采集完成但有错误；`2` 没有指定设备、adb 不存在或盒子不可达（所有段为 null）。

### 3.1 采集内容

脚本先执行 `adb -s <dev> get-state`，然后只执行下表中的只读命令。脚本内部有命令白名单，白名单外的命令会被拒绝。它不执行 `adb connect`，不安装或卸载应用，不改设置，不写 `/sys`，不发按键，不启动或停止应用。

| JSON 字段 | 命令 |
|---|---|
| `device.model`、`brand`、`boardPlatform`、`androidRelease`、`sdk`、`cpuAbiList` | `getprop` 读 6 个白名单键（`ro.product.model`、`ro.product.brand`、`ro.board.platform`、`ro.build.version.release`、`ro.build.version.sdk`、`ro.product.cpu.abilist`） |
| `device.memTotalKb`、`memAvailableKb` | `cat /proc/meminfo` |
| `hdmi.currentMode` | `cat /sys/class/display/mode` |
| `hdmi.attr` | `cat .../amhdmitx0/attr` |
| `hdmi.curVic`、`colorspace`、`colordepth` | `cat .../amhdmitx0/config` |
| `hdmi.fracRatePolicy` | `cat .../amhdmitx0/frac_rate_policy` |
| `hdmi.surfaceFlingerRefreshHz` | `dumpsys SurfaceFlinger` 的 `refresh-rate` 行 |
| `hdmi.dispCap`、`dcCap` | `cat .../amhdmitx0/disp_cap`、`dc_cap` |
| `hdmi.edidLink`、`edidVics`、`maxTmdsClockMHz`、`scdc` | `cat .../amhdmitx0/edid`，只保留 VIC 列表和 `MaxTMDSClock`、`SCDC`、`LTE_340M_Scramble` 行 |
| `hdr.eotf`、`hdr10PlusSupported` | `cat .../amhdmitx0/hdr_cap` |
| `decoders.list`、`hardwareVideo` | `cat /vendor/etc/media_codecs*.xml`；读不到时用 `dumpsys media.player` |
| `audio.formats` | `cat .../amhdmitx0/aud_cap` |
| `network.operstate`、`speedMbps`、`duplex`、`ipv4` | `cat /sys/class/net/eth0/{operstate,speed,duplex}`、`ip -4 addr show eth0` |
| `moonlight.installed`、`versionName`、`versionCode` | `dumpsys package com.limelight` |

（`.../amhdmitx0` 指 `/sys/class/amhdmitx/amhdmitx0`。）

### 3.2 JSON 结构

顶层字段：`schemaVersion`（固定为 1）、`adbTarget`、`reachable`、`collectedAtUtc`、`flags`、`device`、`hdmi`、`hdr`、`decoders`、`audio`、`network`、`moonlight`、`errors`。

`flags` 汇总派生判断；每个判断在所属段里还有一份 `{ value, rule, source, raw }`，`raw` 保存判断所依据的原始行：

| 判断 | 位置 | 规则 |
|---|---|---|
| `supports4k60` | `hdmi.supports4k60` | `disp_cap`（EDID 模式表）里有 `2160p60hz` 或 `2160p60hz420` |
| `fourK60ColorFormat` | `hdmi.fourK60ColorFormat` | `not-offered`：没有 2160p60；`yuv420-only`：EDID 只有 VIC 353（2160p60 4:2:0）没有 VIC 97，或 `MaxTMDSClock` 低于 594 MHz，或 `SCDC: 0`；`rgb444-capable`：VIC 97、594 MHz 以上且 `SCDC: 1` |
| `supportsHdr` | `hdr.supportsHdr` | `hdr_cap` 里 `SMPTE ST 2084: 1`（HDR10 EOTF）。只有 HLG 时仍为 false，因为 Moonlight Android 的 HDR 开关要求显示器支持 HDR10 |
| `hasAv1Decoder` | `decoders.hasAv1Decoder` | 有类型为 `video/av01` 的硬件解码器（`OMX.google.*`、`c2.android.*`、`*.sw` 算软件解码器） |
| `maxPcmChannels` | `audio.maxPcmChannels` | `aud_cap` 中 PCM 行的最大声道数。Moonlight 输出 PCM，不走 AC-3/DD+ 直通 |

### 3.3 失败和隐私规则

- 某次调用失败、超时、输出为空或无法解析时，对应字段为 `null`，`errors` 里加一条 `{ field, code, command, message }`。`code` 取值：`NoDevice`、`Unreachable`、`AdbNotFound`、`Timeout`、`CommandFailed`、`EmptyOutput`、`ParseError`、`RunnerError`、`ProbeError`。
- 盒子不可达时，除 `schemaVersion`、`adbTarget`、`reachable`、`collectedAtUtc` 外所有段都是 `null`，`errors` 里只有一条 `connection` 错误。
- 判断的输入缺失时，判断值是 `null`，不会当作 `false`。
- `getprop` 只读白名单键，不读 `ro.serialno`、Android ID 或 `/sdcard/.deviceid`。EDID 文本里的厂商、产品名、序列号行不保留。
- 每条 adb 输出在解析前先去掉控制字符（`aud_cap` 里有 NUL 字节），并把像 MAC 地址的串和 12 位以上的十六进制串替换成 `[REDACTED-MAC]` / `[REDACTED-HEX]`。最终 JSON 再整体过滤一次。

## 4. 测试

单元测试，不连盒子，用假 adb 输出：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-TvBoxProbeTests.ps1
```

覆盖：健康盒子、盒子不可达、未授权、`AdbNotFound`（显式路径不存在、干净环境解析不到 adb）、注入 `-AdbRunner` 时完全不做 adb 解析（PATH 里即使有真 adb 也不碰）、显式路径与 PATH 解析（在 `%TEMP%` 用 csc 编译带标记的假 adb.exe，验证默认 runner 真正启动的是假 exe，PATH 里的 `.cmd` 包装被忽略，显式路径含空格也可用）、没有指定设备、从 `GS_TVBOX_DEVICE` 取设备、`-Device` 优先于环境变量、单个调用失败、空输出、解析失败、调用超时（runner 睡眠超过 `-TimeoutSec`）、默认 runner 在超时后结束一个挂住的假 adb.exe、4K60 只有 4:2:0 的 EDID、完整 HDMI 2.0 EDID、旧接口 EDID、HDR EOTF 有和没有、只有 HLG、AV1 硬件解码器有和没有、只有 AV1 软件解码器、编解码器 XML 读不到时改用 `dumpsys media.player`、多声道 PCM、JSON 里不出现序列号和 MAC，以及脚本和测试里没有文档网段以外的 IP、没有写死某个用户目录的 adb 路径。测试数据里的地址都是 `192.0.2.10`。

集成测试，连真实盒子，只由协调会话运行（文件第一行是 `# GsTestKind: integration`）：

```powershell
$env:GS_TVBOX_DEVICE = '<box-ip>:5555'
$env:GS_TVBOX_EXPECT_MODEL = 'A4091'
$env:GS_TVBOX_EXPECT_MODE = '2160p60hz'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-TvBoxIntegrationTests.ps1
```

| 环境变量 | 作用 |
|---|---|
| `GS_TVBOX_DEVICE` | 盒子地址；也可以用 `-Device` 参数传入。不设置时所有测试都是 `SKIP`，退出码 0 |
| `GS_TVBOX_EXPECT_MODEL` | 设置后检查 `device.model` 等于它；不设置时这项 `SKIP` |
| `GS_TVBOX_EXPECT_MODE` | 设置后检查 `hdmi.currentMode` 等于它；不设置时这项 `SKIP` |

默认只检查结构：`schemaVersion` 为 1、盒子可达、没有采集错误、所有判断都有值、JSON 里没有 MAC 或 12 位以上的十六进制串。adb 不存在或盒子不可达时，每项都输出 `SKIP` 和原因，退出码为 0；有失败项时退出码为 1。

通过总测试入口运行：`tests\Invoke-All.ps1` 按文件第一行的标记把这个文件当作集成测试，不加 `-IncludeIntegration` 时直接跳过；加了 `-IncludeIntegration` 还要求在管理员（提升权限）PowerShell 里运行，否则也会跳过。（这是 lifecycle 和 integration 工作区里 `Invoke-All.ps1` 当前的规则，它对所有集成测试一视同仁，跳过提示里写的是"安装 MSI / 注册计划任务"。电视盒集成测试本身不需要管理员权限。）`Invoke-All.ps1` 为每个测试文件单独起一个 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File` 子进程，所以单独运行上面那条命令的效果相同，环境变量会传给子进程。

## 5. 证据

证据放在仓库外的本机目录：`<evidence-root>\tvbox-probe-<yyyyMMdd_HHmmss>\probe.json`（原验证机上用的是 `C:\gs-evidence\`）。

第一次真实采集（目录 `tvbox-probe-20261031_173755`，采集时间 2026-10-31 09:37:55 UTC，退出码 0，`errors` 为空）的主要结果如下。**这是历史本机证据：证据目录保存在原验证机上，不随公开仓库提供，本文数值不代表任何新环境已经验证。**

| 字段 | 值 | 原始依据 |
|---|---|---|
| `device.model` | `A4091` | `getprop ro.product.model` |
| `hdmi.currentMode` | `2160p60hz` | `/sys/class/display/mode` |
| `hdmi.attr` / `curVic` | `420,8bit` / `353` | `attr`、`config` 的 `cur_VIC: 353` |
| `hdmi.fracRatePolicy` | `0` | `frac_rate_policy`（重启后可能恢复为 1，每次测试前要重新读） |
| `hdmi.surfaceFlingerRefreshHz` | `60.000002` | `dumpsys SurfaceFlinger` |
| `flags.supports4k60` | `true` | `disp_cap` 含 `2160p60hz`、`2160p50hz` |
| `flags.fourK60ColorFormat` | `yuv420-only` | EDID VIC 列表有 353 无 97；`MaxTMDSClock1 300 MHz`；`SCDC: 0`；`dc_cap` 的 420 只有 `420,8bit` |
| `flags.supportsHdr` | `false` | `hdr_cap`：`Traditional SDR: 0`、`Traditional HDR: 0`、`SMPTE ST 2084: 0`、`Hybrif Log-Gamma: 0` |
| `flags.hasAv1Decoder` | `false` | `media_codecs*.xml` 的硬件视频解码器只有 HEVC、H.264（avc）、VP9、MPEG-2、MPEG-4、Dolby Vision，没有 `video/av01` |
| `flags.maxPcmChannels` | `2` | `aud_cap`：`PCM, 2 ch, 32/44.1/48 kHz, 16/20/24 bit`（另有 `AC-3, 6 ch`、`Dobly_Digital+, 8 ch`） |
| `network` | `up`，1000 Mbps，`full` | `/sys/class/net/eth0/*` |
| `moonlight` | 已安装，12.2（315） | `dumpsys package com.limelight` |

旧接口（最高 1080p60，4K 只到 30 Hz）的数据只有第 1 节表格里的人工记录，探测脚本没有在旧接口上运行过。切回旧接口属于改设置，要先得到协调会话同意。


## 6. 对兼容性矩阵的影响

电视盒的矩阵行不在本文里定义。它们写在 `docs/compatibility-test-plan.md` 的 "Android TV client matrix" 一节（由协调会话维护），用例 ID 前缀是 `ATV-`，Settings 列以 `ui:` 开头（Moonlight Android 没有命令行，设置都在界面里选）。操作步骤是同一节里的 `P-ANDROID`。MacBook 的 `CMP-*` 行不受影响。

### 6.1 用例和探测证据的对应关系

计划里所有 `ATV-` 行一开始都是 `not covered`。`unsupported`（以及 `pass` / `fail`）由协调会话根据真实证据填写，`Reason` 里引用 `probe.json` 的字段和原始行。下表是按第 5 节那次历史采集给出的依据，供协调会话填表时引用：

| 用例 | 探测依据 | 结论建议 |
|---|---|---|
| `ATV-HDR-01` | `flags.supportsHdr` = false；`hdr_cap`：`SMPTE ST 2084: 0`、`Hybrif Log-Gamma: 0`；4K60 只有 4:2:0 8bit（`fourK60ColorFormat` = `yuv420-only`） | `unsupported`：电视 EDID 不支持任何 HDR EOTF |
| `ATV-AV1-01` | `flags.hasAv1Decoder` = false；`media_codecs*.xml` 没有 `video/av01` 解码器 | `unsupported`：没有 AV1 解码器 |
| `ATV-AV1-02` | 同时满足上面两条 | `unsupported` |
| `ATV-AUD-01`、`ATV-AUD-02` | `flags.maxPcmChannels` = 2；`aud_cap` 里 `PCM, 2 ch`，`AC-3, 6 ch` 和 `Dobly_Digital+, 8 ch` 是码流格式，Moonlight 输出 PCM | 很可能 `unsupported`，需要配对后实测确认 |
| `ATV-BASE-01`、`ATV-H264-01`、`ATV-1080-01`、`ATV-1080-02` | `hdmi.currentMode` = `2160p60hz`；硬件解码器有 `OMX.amlogic.hevc.decoder.awesome` 和 `OMX.amlogic.avc.decoder.awesome` | 可测，配对后由协调会话按 `P-ANDROID` 运行 |
| `ATV-PAD-01` | 探测不涉及手柄；盒子上还没有确认的游戏手柄 | `not covered`，等用户接入手柄 |

HDR 一行的依据是 EDID。Moonlight Android 在显示器不报告 HDR10 时会隐藏 HDR 开关，这一点来自 Moonlight 源码 `StreamSettings.java`，还没有在盒子的设置界面上核对过（核对需要发送按键，只能由协调会话做）。

每次运行用例前，都要按 `P-ANDROID` 重新读一次输出模式和 `frac_rate_policy`，可以直接用探测脚本的 `hdmi.currentMode` 和 `hdmi.fracRatePolicy`。
