# 阶段 4：可配置产品运行目录契约

## 范围

本阶段把私有栈的运行目录、组件来源和状态/日志目录从旧的个人目录中分离出来，并提供组件树导入、控制脚本复制与旧根路径重写。它不启动服务、不停止官方服务、不修改 NVIDIA App 文件/服务/注册表，也不宣称已经完成真实串流产品。

## 目录模型

| 名称 | 内容 | 写入者 |
|------|------|--------|
| `InstallDir` | 用户提供的组件树 + 我们复制进 `bin/` 的控制脚本 | 安装/部署时写入，之后视为只读 |
| `ComponentSourceDir` | 用户合法持有的组件副本，只读来源 | 用户 |
| `StateDir` | 生命周期状态、运行配置、暂停标志、运行期私有目录 | 运行时 |
| `LogDir` | 运行日志 | 运行时 |

四个目录必须为绝对路径，彼此不得相同或嵌套；`ComponentSourceDir` 与其它目录重叠会被拒绝。

## 公开函数（GsRuntime 0.1.0）

```powershell
New-GsRuntimeLayout -InstallDir <abs> -StateDir <abs> -LogDir <abs> -ComponentSourceDir <abs>
Read-GsRuntimeConfig -Path <json>
Write-GsRuntimeConfig -Layout <layout> -Path <json>
Test-GsRuntimeLayout -Layout <layout>
New-GsRuntimePlan -Layout <layout> -CatalogPath <json>
Import-GsRuntimeTree -Layout <layout> -ComponentSourceDir <abs> [-Force]
Install-GsRuntimeBundle -Layout <layout> -HelperSourceDir <abs> [-Force]
Test-GsRuntimeBundle -Layout <layout>
```

- `New-GsRuntimeLayout` 只做路径规范化与冲突校验，不创建目录。派生 `BrokerDir`、`PluginsDir`、`BinDir`、`GeneratedConfigPath`、`StatusPath`、`PauseFlagPath`。
- `Read/Write-GsRuntimeConfig` 使用 `schemaVersion: 1`，字段为 `installDir`、`stateDir`、`logDir`、`componentSourceDir`；写入使用同目录临时文件 + 替换。
- `New-GsRuntimePlan` 读取组件目录清单（`schemaVersion: 1`，`components` 数组，每项 `name/role/relativePath/kind/sha256`），要求恰好一个 `launcher`、`broker`、`nvs`、`nss`、`ssau` 角色；文件校验 SHA-256，目录校验类型；拒绝 `..` 逃逸、重复名称、类型不符。生成 broker/nvs/nss/ssau 四个角色计划，broker 期望 `GsMessageBusBroadcast`，SSAU 使用活动控制台会话。
- `Import-GsRuntimeTree` 将用户组件树复制到 `InstallDir`，排除 `GsPrivate`、`logs`、`backup`、`state`；不写入来源。
- `Install-GsRuntimeBundle` 复制十个控制脚本到 `bin/`，把脚本中的旧根 `C:\Tools\NvStreamSrv\GsPrivate` 重写为 `StateDir\runtime`、`C:\Tools\NvStreamSrv` 重写为 `InstallDir`，并写入运行配置。
- `Test-GsRuntimeBundle` 检查十个脚本、配置存在且不再含旧根路径。

## 验证

本仓库中可复现的测试入口：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-RuntimeBundleTests.ps1
```

它覆盖 `Install-GsRuntimeBundle` / `Test-GsRuntimeBundle` 的合成安装与检查：控制脚本与辅助文件（`gs_process_identity.ps1`、`GsStreamGuard.dll`）的逐字节复制、缺失辅助文件的拒绝（复制前拒绝）、已存在文件需 `-Force`、以及 `Test-GsRuntimeBundle` 对缺失 `GsStreamGuard.dll` 的报告。所有测试使用 `%TEMP%` 合成目录，不启动任何真实组件。`New-GsRuntimeLayout`、`Read/Write-GsRuntimeConfig`、`New-GsRuntimePlan`、`Import-GsRuntimeTree` 在本仓库没有专属测试套件。

2026-10-31 曾记录一次"32 项通过，0 失败"的实测（覆盖合法/非法布局、配置往返、组件哈希/类型/逃逸拒绝、角色计划、组件树导入与排除、控制脚本重写和旧路径检测）。那次运行使用的是当时的完整阶段 4 测试套件，该套件不在本仓库中，因此这一数字无法仅凭公开仓库复现；本仓库可复现的部分以上面的 `Invoke-RuntimeBundleTests.ps1` 为准。

## 当前交付边界

- 本页合成测试不执行真实启动/停止。历史版本的现场启动与客户端记录见 [acceptance-evidence.md](acceptance-evidence.md)；它们不证明当前新源码已经完成端到端部署。
- 产品 MSI 构建入口是 `scripts/build-product.ps1`，已打包产品脚本、三个产品模块和外部 bundle；`scripts/build.ps1` 才是阶段 3 的独立示例安装器。当前尚未完成真实公开运行时包的交付及新版 MSI 的干净安装、升级、卸载和客户端回归，见 [路线图](product-roadmap.md) 与 [发布验收](release-readiness.md)。NVIDIA 组件树仍由使用者合法自备，不能将合成示例当发行包。
- 自动更新、签名与完整 GPU/驱动及 HDR 等兼容性覆盖未完成；已经存在的自启与客户端功能及其历史验证范围以当前路线图为准。
- 控制脚本重写只替换根路径字符串；若上游脚本新增其它绝对路径，`Test-GsRuntimeBundle` 会暴露旧根，但不会自动发现其它个人路径。
