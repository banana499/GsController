# Sunshine 模式：首次安装到配对

本页对应新增的 Sunshine 开发配置，尚未包含在已发布的 `source-preview-2026-11-07` 中。代码与打包检查完成后仍需独立 Windows 环境验证真实安装、配对和串流，不能把本页步骤当作已经完成的实机验收记录。

## 两个程序各负责什么

GsController 提供本地引导、只读检查和官方管理页面入口。Sunshine 负责串流服务、主机设置、账号初始化及 PIN 配对。此模式不需要本项目旧运行时包，也不需要按旧布局准备 NVIDIA 组件树；Sunshine 使用其官方发行版，不包含在 GsController MSI 内。

旧运行时与 Sunshine 使用部分相同的串流端口。迁移已有主机前，先按原产品流程停止旧串流服务；不要让两套主机服务同时占用这些端口。GsController 不会自动停止、卸载或迁移另一套运行时。

## 1. 取得正确的安装包

使用 Windows 11 x64 和适配的显卡驱动。GsController 的 Sunshine 配置包安装后，在开始菜单选择 **GsController**；源码方式使用根目录 `Start-GsController-Sunshine.cmd`。原 `Start-GsController.cmd` 保留旧运行时入口，不作为本页的启动方式。

页面中的官方 Sunshine 链接用于取得 Windows x64 安装包。不要把本项目旧运行时文件放到 Sunshine 目录，也不要用第三方拼装包替代官方发行。

2026-11-07 核对的官方发行元数据如下，数据来自 GitHub 官方仓库 Release API；已独立下载该精确版本并验证文件大小与 SHA-256 一致，未执行安装：

| 项目 | 官方记录 |
|---|---|
| 版本 | `v2026.914.233613` |
| 发布时间 | 2026-09-15 |
| 状态 | 正式上游发行，非 prerelease；不代表本项目已实机验收 |
| Windows x64 文件 | `Sunshine-Windows-AMD64-installer.msi` |
| 文件大小 | 33,710,080 字节 |
| SHA-256（上游公布） | `1d7fed8beecd5889dc7ff14cf9f42d6d38f37c3066c13c6c2a5f4e91847e0ccf` |

[该版本的官方发布页](https://github.com/LizardByte/Sunshine/releases/tag/v2026.914.233613) · [官方安装包](https://github.com/LizardByte/Sunshine/releases/download/v2026.914.233613/Sunshine-Windows-AMD64-installer.msi) · [官方使用说明](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html)

如果下载的是此精确版本，可以在普通 PowerShell 中核对下载文件的 SHA-256；把路径替换为实际下载位置：

```powershell
Get-FileHash -LiteralPath 'C:\path\to\Sunshine-Windows-AMD64-installer.msi' -Algorithm SHA256
```

哈希匹配仅说明下载字节与公布记录一致，不能替代系统要求、安装授权或真实串流测试。采用其他版本时，应核对该版本自己的官方记录，不能沿用上表的哈希。

安装 Sunshine 时按官方安装器提示操作。它可能请求管理员权限并安装其服务或网络规则；这些操作由用户明确启动官方安装器完成，GsController 不会替你自动执行。已装相同版本时遵循上游的升级/修复说明，不重复覆盖现有配置。

## 2. 打开 Sunshine 管理页面

在 GsController 中选择“打开 Sunshine 管理页面”，目标固定为本机 `https://localhost:47990`。首次运行时，在 **Sunshine 自己的页面** 创建用户名和密码。GsController 不收集、不保存这些凭据，也不会代为登录。

Sunshine 使用自签名证书，浏览器可能显示证书提示。先确认地址确实是本机 `localhost:47990`，按官方使用说明核对；GsController 不会关闭浏览器安全检查或替你信任证书。若安装使用了自定义管理端口，请按 Sunshine 的配置和官方文档手动访问，本版引导固定检查默认端口。

页面中的“程序文件存在”只表示默认位置的文件元数据检查成功。“管理端口可连接”只表示本机 TCP 连接成功，**不验证监听程序身份，也不等于已经配对或串流就绪**。自定义安装位置可能无法被自动检测；仍可按实际配置打开官方页面。检查显示未知时，不应把它当作通过或认定软件不存在。

## 3. 在 Moonlight 中配对并连接

1. 在客户端通过 [Moonlight 官方网站](https://moonlight-stream.org) 安装适合该设备的版本，确认客户端与主机网络互通。
2. 在 Moonlight 添加主机；如果没有自动发现，可使用主机的实际局域网地址手动添加。
3. Moonlight 显示 PIN 后，打开 **Sunshine 管理页面的 PIN 页面**，输入客户端显示的 PIN 并按上游界面确认；根据提示填写设备名称。
4. 只有 Sunshine 返回配对成功，才继续在 Moonlight 中选择 Desktop 或已配置的应用。不要把 GsController 的文件/端口检查当作配对成功。
5. 首次从客户端支持的基础分辨率、帧率和编码开始，确认画面、声音和输入正常，再逐步提高设置。
6. 使用 Moonlight 的正常退出方式结束会话，随后验证可再次连接。分辨率、码率等客户端参数在 Moonlight 设置中调整。

PIN、密码和客户端私钥都不要提交到 GsController、日志、截图或问题报告。配对失败、取消、过期或移除客户端，使用 Sunshine 官方管理页面处理；本版 GsController 不提供配对凭据导入、批量清理或自动重试。

## 维护与卸载

Sunshine 的启动、自启、停止、升级和卸载按其官方说明完成。GsController 的 Sunshine 模式不会调用旧运行时的 Start/Stop/Deploy 或旧 supervisor 任务。

退出 GsController 只关闭引导控制台；卸载其 Sunshine 配置包不应删除 Sunshine 服务、账号、配对状态或旧运行时任务。Sunshine 由它自己的安装器独立管理。该卸载隔离需要通过 MSI 数据库检查和后续真实安装生命周期验收分别证明。

## 开发者构建

从包含本功能的源码版本构建，提供实际 WiX 3.14 目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-product.ps1 -Version 0.3.0 -RuntimeProfile Sunshine -WixDir 'C:\path\to\wix314'
```

Sunshine 配置不传 `-RuntimeBundleDir`，不读取或打包本项目旧运行时。构建将配置写入 `gs-install-profile.json`，开始菜单通过已安装入口读取它；旧配置继续使用 `-RuntimeProfile Legacy` 与匹配的合法运行时包。`Bypass` 仅作用于该进程，仍须遵守组织策略。

## 验收状态

源码层已通过 Sunshine 后端 42 项、前端 14 项与旧接口 59 项检查；双配置的真实 WiX 夹具编译和只读 MSI 表检查通过。最终仍需要同一 GsController MSI、Sunshine 版本和 Windows 环境上的安装、账号初始化、全新客户端配对、实际串流、正常退出及独立卸载证据。当前环境没有执行这些真实系统操作；前端模拟、TCP 探针或 MSI 表检查都不能替代它们。
