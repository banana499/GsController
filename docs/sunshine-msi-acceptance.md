# Sunshine MSI 隔离安装验收（CI）

本文说明 Sunshine 产物（0.3.0 → 0.3.1）的**真实安装验收**如何只在 GitHub
托管的隔离 runner 内执行；本机（开发机）永远只做 Plan，不执行安装。

## 组成

- `.github/workflows/sunshine-msi-acceptance.yml`：独立 workflow，
  `workflow_dispatch` + 同仓库 PR 触发；**fork PR 一律拒绝**（job 级条件 +
  显式步骤双保险）；`permissions: contents: read`；checkout
  `persist-credentials: false`；job 级 `timeout-minutes: 30`。现有
  `windows-tests.yml` 完全不变。
- `tests/Invoke-SunshineInstallAcceptance.ps1`：验收 harness。**默认
  Plan 模式零动作**；只有 `-Execute` 且全部门槛通过才进入真实动作。
- `tests/Invoke-SunshineInstallAcceptanceTests.ps1`：纯单元/Plan 安全
  测试（本机唯一可跑的套件，绝不调用 `-Execute`，连负例也不调用，更不
  伪造 CI 环境变量）。

## 隔离依据与门槛（如实声明）

**真正的隔离依据是固定 GitHub-hosted `windows-2022` runner。** harness
内的环境门槛（`GITHUB_ACTIONS=true`、`RUNNER_ENVIRONMENT=github-hosted`、
`RUNNER_OS=Windows`、64 位 Windows PowerShell 5.1 管理员、所有输入与日志
严格位于 `RUNNER_TEMP` 之下）只是**防误跑的多重闸门**，环境变量可以被
伪造，**不得把它们描述为安全边界**。

workflow 顶部的 WiX ZIP URL 已固定为官方发布地址
（wix3141rtm 的 `wix314-binaries.zip`），SHA256
`6ac824e1642d6f7277d0ed7ea09411a508f6116ba6fae0aa5f2c7daa2ff43d31`
为本次从该官方 URL 下载后计算并固定的值（官方 API 对该资产返回的
digest 为 null，不存在上游公布的哈希，不得表述为上游发布哈希）。
下载只进新的 `RUNNER_TEMP` 目录：先比对 SHA 再 `Expand-Archive`；
构建从 repo 运行、WiX 工具用显式路径，绝不从下载目录运行解释器。
禁止在本 workflow 中下载或运行任何 Sunshine 安装器。

## runner 内验收序列（harness -Execute）

1. 只读 MSI COM 预检（两包）：`ProductName=GsController`、已知
   `UpgradeCode` 一致、`ProductCode` 不同、版本严格递增、**无任何
   CustomAction / ServiceInstall / ServiceControl**（Sunshine MSI 编译
   期已去除旧清理动作）。
2. 冲突拒绝：任何已安装的 GsController 产品 / 已存在的安装目录
   `Program Files\Local Development\GsController` / 已存在的开始菜单
   `GsController.lnk` → 拒绝安装，绝不覆盖。已装产品检测只用只读 MSI
   COM 枚举（`Installer.Products`+`ProductInfo`，等价于
   MsiQueryProductState/MsiEnumRelatedProducts 的精确语义）；**禁止
   Win32_Product WMI 查询**（它会对枚举到的每个产品触发修复）。
3. 安装 0.3.0；核对 stage manifest 全文件 SHA256（workflow 每次构建后
   从 `artifacts\product-stage` 生成）、包内 `gs-install-profile.json`
   （schemaVersion 1、backend=sunshine）、开始菜单快捷方式存在。
4. `MsiGetShortcutTarget` / `MsiGetComponentPath` 核对广告快捷方式解析到
   已安装的 `gs-console.vbs`（ProductCode 与本次安装一致）。
5. 直接启动已安装 `gs-console.ps1`（`-NoBrowser -NoTray`、临时端口、
   `-SessionToken` 内存测试会话；**不显式传 Backend，读包内 profile**），
   验证四个静态路由 200、无会话访问 `/api/sunshine/status` 被拒、带
   会话返回 backend=sunshine 的 JSON、旧 `/api/actions` 被 4xx 拒绝。
   不点 UAC/浏览器，会话 token 只存在于 harness 内存与临时端口。
6. 删除一个本次安装的 payload 文件后 repair（REINSTALL=ALL
   REINSTALLMODE=vomus），核对文件恢复且哈希一致。
7. 升级到 0.3.1：旧 ProductCode 不再安装、新版本/文件/profile/快捷方式
   正确。
8. 卸载本次新 ProductCode：payload 与快捷方式消失；**只记录不删除**
   空目录残留情况。
9. 所有 msiexec 带 `/norestart`、逐次日志、超时（10 分钟）；退出码
   3010 记为 `RebootRequired`——需重启/状态不完整，**不能算全通过**。
10. finally 只清理本次安装的精确 ProductCodes 与本次启动的 console 进程；
    不停其它服务/任务，不删外部目录。

输出：精简 JSON（模式、gate、预检、逐步 verdict、清理记录、overall）
+ 本次全部 msiexec 日志，作为 workflow artifact 上传。

## 本机安全边界

本机只允许运行 `tests\Invoke-SunshineInstallAcceptanceTests.ps1`（纯单元
与 Plan 零动作验证，仅 TEMP GUID 夹具）。本机**不得**以任何理由调用
`-Execute`（包括负例），不得伪造 CI 环境变量试图进入安装路径，不得把
其它已获准目录当临时区。

## 已验收 / 未验收边界

- 本仓库交付时仅完成：harness 纯函数与 Plan 模式的**本地单元验证**。
- **尚未执行**：runner 内的真实构建与 msiexec 安/修/升/卸全流程，以及任何真实 Sunshine 安装/账号/PIN/证书/配对/GPU 检查。WiX URL与哈希已固定，当前缺的是提交分支和运行远端验收的授权。
- 同仓库分支创建PR即可通过 `pull_request` 触发该工作流，不需要先合并；`workflow_dispatch` 的手动入口需工作流已存在于默认分支。本轮不自动合并或发布。
- Windows Server 2022 runner 的生命周期结果不能替代 Windows 11 桌面或串流验收。
