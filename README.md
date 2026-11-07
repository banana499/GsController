# GsController Product Development

This repository contains the **product, installer, lifecycle, and acceptance**
layer for GsController: an installable Windows controller for a private
GameStream-compatible streaming stack.

It intentionally does **not** contain:

- runtime helper implementations or streamer helper binaries;
- NVIDIA binaries, certificates, keys, logs, or dumps;
- analysis artifacts, runtime implementation notes, or analysis scripts.

The runtime bundle is an **opaque, separately supplied dependency**. Treat it
as a black box: do not read, modify, or document its internals in this
repository.

## 首次使用与开源交付状态

自有产品代码采用 **GPL-3.0-only**，见 [LICENSE](LICENSE) 和
[许可与独立运行时说明](LICENSING.md)。从源码开始请阅读
[快速开始](docs/quickstart.md)，贡献与测试流程见
[CONTRIBUTING.md](CONTRIBUTING.md)，安全报告见 [SECURITY.md](SECURITY.md)。

克隆后可以运行源码测试与只读依赖预检。Legacy 路线仍依赖独立运行时包和
合法自备的 NVIDIA 组件，其公开交付材料尚未齐备。新增 Sunshine 路线使用
可公开获取的官方 Sunshine 安装包，无需这些旧依赖；新版本 MSI 的干净环境
安装生命周期和首次配对串流均尚未验收。
产品源码预览已于 2026-11-07 [公开发布](https://github.com/banana499/GsController/releases/tag/source-preview-2026-11-07)，绑定提交 `0f0da04`；该版本 Windows CI 为 17 套件通过、3 套真实集成跳过、0 失败，匿名下载及文件哈希已核验。完整可串流发行仍待完成，夹具 MSI 不能作为可串流发行包。
具体完成条件见 [开源发布验收](docs/release-readiness.md)。

## Sunshine 新用户路线（开发中）

新增配置使用官方 Sunshine 负责串流、账号与 PIN 配对，GsController 提供本地引导和只读检查。这条路线无需本项目旧运行时包或自备 NVIDIA 组件树；Sunshine 由用户独立安装，控制台不接收密码或 PIN。源码入口为 `Start-GsController-Sunshine.cmd`，构建使用 `-RuntimeProfile Sunshine`。后端 42 项、前端 14 项检查通过，旧接口 59 项回归通过；两种 MSI 配置的离线构建及表检查通过，真实安装、配对与串流仍未验收。具体流程、官方版本记录和边界见 [Sunshine 首次使用](docs/sunshine-quickstart.md)。本功能未包含在已发布的源码预览中。

安装生命周期的下一道检查是 [Sunshine MSI 隔离验收](docs/sunshine-msi-acceptance.md)：在 GitHub 托管的 Windows runner 内安装、修复、升级和卸载控制器，默认本地调用只生成计划。该流程不会安装 Sunshine 或处理配对凭据，结果也不能替代 Windows 11 桌面和 GPU 串流验收。

## 本地控制台（开发分支）

双击根目录 `Start-GsController.cmd`，可打开中文本地控制台：总览、设置、连接指南和诊断。它与原托盘并存，使用现有产品接口；保存偏好与执行部署分开，目录变更和部署需先停止串流。

仅体验界面时，可用 `product/gs-console.ps1 -Demo`。演示模式不调用真实运行时或系统任务。详细启动方式、权限和边界见 [本地控制台](docs/local-console.md)。此分支新增界面尚未作为新的公开发行版发布。

## Architecture

| Module | Responsibility |
|---|---|
| `src/GsControl` | Path resolution, manifest/catalog validation, shared result types |
| `src/GsLifecycle` | State machine for install/start/stop/rollback |
| `src/GsRuntime` | Layout, component plan, catalog generation, bundle deployment |
| `product/gs-product.ps1` | User-facing CLI: Install / Check / Start / Stop / Status / Recover / Diagnose / CreateCatalog / RegisterAutostart / UnregisterAutostart / PrepareUninstall. Start, Stop, Recover and PrepareUninstall hold a per-StateDir lifecycle mutex |
| `product/gs-diagnose.ps1` | Read-only diagnostics report: hashes, runtime config, status file, serverinfo, PID files, redacted log tails, and a `hygiene` section (supervisor task, pause flags, script-folder ACL allowlist, status-file ambiguity). Imports no product module |
| `product/gs-support.ps1` | Support bundle: runs the diagnose report with a deadline, rescans the decoded report for secrets, and zips it with redacted tray log tails |
| `product/gs-tray.ps1`, `gs-tray-model.ps1`, `gs-tray.vbs`, `gs-tray-strings.zh-CN.json` | Notification-area tray with six states (Stopped / Starting / Stopping / Ready / Streaming / Error), Chinese UI text from the string table, Start / Stop / Recover / support-bundle menu items and stream balloons |
| `product/gs-console.ps1`, `gs-console-action.ps1`, `gs-console.vbs`, `gs-console.html/css/js`, `gs-console-strings.zh-CN.json` | Local Chinese web console with overview, settings, connection guidance and limited diagnostics; loopback API and fixed CLI actions; `Start-GsController.cmd` is the source entry |
| `tools/gs-soak-monitor.ps1` | Soak tool: Monitor mode samples status, serverinfo, PIDs and memory; Cycle mode runs repeated Stop/Start (plan only unless `-Execute`) |
| `src/GsSecurity`, `tools/Get-GsAclPlan.ps1` | Repository-only in-memory ACL policy and read-only preflight. Never applies permissions or reports apply-ready; not wired into Install or the MSI. See [ACL policy](docs/acl-policy.md) |
| `installer/GsController.wxs` | WiX 3.14 per-machine MSI; `scripts/build-product.ps1` stages every top-level `product/` file next to `gs-product.ps1` |
| `tests/` | `Invoke-All.ps1` runs every `Invoke-*Tests.ps1` suite in its own process. Integration suites (Stage 3, Stage 12, TV box) are skipped unless `-IncludeIntegration` is given in an elevated session |
| `client/` | Moonlight acceptance harness, compatibility evidence skeleton, read-only Android TV box probe |

Feature references: lifecycle lock, Recover, Diagnose and PrepareUninstall in
[docs/lifecycle-hardening.md](docs/lifecycle-hardening.md); the tray in
[docs/tray-ui.md](docs/tray-ui.md); the support bundle in
[docs/support-bundle.md](docs/support-bundle.md); release hashes and
rollback in [docs/release-manifest.md](docs/release-manifest.md); the
compatibility matrix in
[docs/compatibility-test-plan.md](docs/compatibility-test-plan.md).

Operator documentation (Chinese):
[operator guide](docs/operator-guide.md),
[troubleshooting](docs/troubleshooting.md),
[file and log locations](docs/file-locations.md),
[threat model](docs/threat-model.md),
[stability test plan](docs/stability-test-plan.md),
[TV box client](docs/tvbox-client.md).

## Prerequisites

- Windows 11 x64 (historically validated on 22631), with 64-bit Windows PowerShell 5.1
- For source tests: no runtime bundle or WiX is required
- For MSI builds: WiX 3.14 (`heat.exe`, `candle.exe`, `light.exe`) and a lawfully supplied compatible runtime bundle
- For deployment/streaming: that runtime bundle, a separately prepared lawful NVIDIA component tree, a supported GPU/driver and a Moonlight client
- Recorded client versions: Moonlight 6.2.0 on macOS and Moonlight 12.2 on Android; broader versions remain unverified

## Build the MSI

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-product.ps1 `
  -Version 0.2.0 `
  -RuntimeBundleDir 'D:\path\to\prebuilt-runtime-bundle' `
  -WixDir 'D:\Build Tools\WiX 3.14\bin'
```

The bundle's files are copied verbatim into the MSI `bin/` directory. The
repository does not compile or inspect them.

## Install and operate

```powershell
msiexec /i .\artifacts\msi\GsController-0.2.0.msi /qn
$p = 'C:\Program Files\Local Development\GsController\gs-product.ps1'
& $p -Action Install -ComponentSourceDir 'D:\path\to\components'
& $p -Action Check
& $p -Action Start
& $p -Action Status
& $p -Action Diagnose      # read-only report; does not take the lifecycle lock
& $p -Action Stop
```

- Start, Stop, Recover and PrepareUninstall serialize through a
  per-StateDir mutex. A second call waits up to `-LockTimeoutSec`
  (default 30) and then returns `Errors[0].Code = 'Busy'`. Status, Check
  and Diagnose never wait for the lock.
- `-Action Recover` clears a stuck session with one Stop and one Start. It
  acts only when the status file says `ready`, serverinfo answers with
  `currentgame = 1`, no TCP client is connected on 47984/48010 and no
  outbound client traffic is measured; otherwise it returns
  `RecoverRefused` with a `Reason` and runs nothing.
- Before uninstalling older packages or a custom StateDir deployment, run
  `-Action PrepareUninstall` with that instance's paths in an elevated
  session. The current MSI source adds this action plus fixed-task deletion
  for ordinary full uninstall; upgrades preserve the task. Cleanup is best
  effort and must be verified afterward. Real uninstall remains untested;
  see [MSI cleanup](docs/msi-uninstall-cleanup.md).
- Support bundle: `& 'C:\Program Files\Local Development\GsController\gs-support.ps1'`.
- Tray: `wscript.exe "C:\Program Files\Local Development\GsController\gs-tray.vbs"`.
  It does not start at logon by itself.
- Before streaming, minimize large windows on the host: NVIDIA treats a
  non-minimized window as a running fullscreen game and refuses Desktop
  with error 526.
- Tests: `powershell -ExecutionPolicy Bypass -File .\tests\Invoke-All.ps1`
  prints one PASS/SKIP/FAIL line per suite and
  `Total: X passed, Y skipped, Z failed`.

## Current acceptance status

- Source integration: `night/integration` was merged into `hardening/p0` on
  2026-11-01. The later state-file fix passed Stage2 226/0, the full runner
  11 passed / 3 skipped / 0 failed, and cross-branch checks 30/0. The tray
  stop-timeout fix (`0e545f9`) then passed TrayUi 151/0 and Docs 31/0; a full
  run was not repeated after that fix. These are separate validation runs.
- Delivery check (2026-11-06): the installed product still lacks the new
  diagnostics, support-bundle and tray files; its CLI and lifecycle/runtime
  modules differ from source. A release MSI with the real runtime bundle,
  deployment of the new product, and interactive acceptance remain open.
- Historical integrated night build (2026-11-01): `tests/Invoke-All.ps1`
  reports `Total: 11 passed, 3 skipped, 0 failed` (CompatibilityPlan 50,
  Diagnose 103, Docs 31, LifecycleHardening 80 with 2 skips, RuntimeBundle 5,
  StabilityTool 24, Stage1 38, Stage2 224, Support 36, TrayUi 144,
  TvBoxProbe 40; Stage3, Stage12 and TvBoxIntegration skipped). A test build
  with a 3-file fake runtime bundle contains 16 files: 7 product files,
  6 module files, 3 bundle files.
- Android TV box (Moonlight 12.2, wired): 30-minute 4K60 HEVC Desktop
  session, 180/180 samples healthy, host QoS 100, 59.8 FPS, host idle 3-4 s
  after quit. See `docs/stability-test-plan.md`.
- The figures below predate the merge; recount the MSI files after the first
  release build with the real bundle.
- Product MSI: 18 files, 41 product tests passed.
- Real component deployment and Check: 18 tests passed.
- Product start: 8/8 passed.
- Autostart: 11 tests passed.
- Second physical client (MacBook Pro M4 Pro, Moonlight 6.2.0, Wi-Fi):
  - 4K60: `/launch 200`, `3840x2160x60`, client 60.20 FPS, 15 ms, 0.10% network drop.
  - 1080p60: `/launch 200`, `1920x1080x60`, client 60.48 FPS, 44 ms, 0.00% drop.
  - 720p60: `/launch 200`, `1280x720x60`, client 62.64 FPS, 42 ms, 0.00% drop.
- Host Qos during 4K60: Q-score 100, RTD 0 ms, 60.00 FPS, 40 Mbps.

See `docs/acceptance-evidence.md` and `docs/product-roadmap.md`.

Historical real deployment/start/stream results used a separate private
validation environment; those scripts and raw host evidence are not part of this
clone. The public repository contains fixture suites and explicitly gated
installation/device tests. Default fixture tests do not require the runtime
bundle. New releases must also complete the public
[clean-environment acceptance procedure](docs/release-readiness.md).

## Repository layout

```text
src/            product modules
product/        product CLI, diagnostics, support bundle, tray UI
tools/          soak monitor
installer/      WiX MSI definition
tests/          acceptance tests
client/         Moonlight client harness, compatibility evidence, TV box probe
docs/           product contracts, acceptance, roadmap
runtime-bundle/ place the prebuilt runtime bundle here (not committed)
scripts/        build scripts
```

## Security and legal

- The operator must supply the runtime bundle and any NVIDIA components under
  their own license. This repository does not redistribute them.
- Do not commit certificates, private keys, tokens, logs, or dumps.
- The product must not modify an existing NVIDIA App installation, services,
  or registry state.

## AI contributor rule

If you are an AI agent working in this repository: **do not inspect or modify
`runtime-bundle/` or any installed runtime helper**. Treat the runtime as an
opaque dependency. Work only on the product modules, installer, tests, docs,
and client harness in this repository.
