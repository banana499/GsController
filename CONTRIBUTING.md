# 贡献指南

GsController 的公开仓库维护产品模块、安装器、测试、文档及客户端验收工具。开始前请阅读 [README](README.md) 的依赖说明和 [安全报告说明](SECURITY.md)。安全问题请按后者处理，不要直接提交包含漏洞细节的公开 issue 或 PR。

## 开发环境与源码约定

- 使用 Windows 和 **Windows PowerShell 5.1**（`powershell.exe`）。PowerShell 7 的 `pwsh` 不能代替 5.1 验证；CI 使用 Windows Server 2022 runner，不能代表 Windows 11 的完整产品验收。
- PowerShell 源文件（`.ps1`、`.psm1`、`.psd1`）保持 ASCII，避免 Windows PowerShell 5.1 对无 BOM 文件的编码差异。中文界面文案放在现有 UTF-8 字符串资源中，例如 `product/gs-tray-strings.zh-CN.json`，通过显式 UTF-8 读取；不要把中文直接写入 PowerShell 源码。测试需要中文样本时可用 Unicode 转义构造。
- 面向用户的界面和新文档使用中文；Markdown 和 JSON 文本使用 UTF-8 无 BOM。代码注释、变量名、测试输出沿用所在文件的风格。无需顺手重写已有英文文档。
- 本仓库不要求额外安装测试框架或从包管理器下载运行时。修改前先阅读相邻模块和夹具测试；新增测试应使用临时目录、合成数据、mock 回调或已有注入点。

## 运行测试

从仓库根目录运行默认安全套件；不需要安装产品或提供真实运行时包：

```bash
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Invoke-All.ps1
```

默认入口发现 `tests/Invoke-*Tests.ps1`，逐个在独立 Windows PowerShell 进程中运行，打印 `PASS`、`SKIP`、`FAIL` 和最终 `Total`。测试失败、异常或超时必须返回非零退出码。提交前至少运行变更涉及的安全套件，记录实际命令、结果与跳过原因；没有运行的检查请明确注明。

可单独运行基础单元测试：

```bash
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Invoke-Stage1Tests.ps1
```

```bash
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Invoke-Stage2Tests.ps1
```

工作流契约的静态检查：

```bash
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Invoke-RepositoryPolicyTests.ps1
```

有宿主副作用的新增套件必须在前 30 行内单独写一行 `# GsTestKind: integration`。默认入口明确跳过 Stage3、Stage12 及带此标记的套件，包括 TV box 集成测试。**不要为了消除 SKIP 而启用集成测试或去掉标记。** `-IncludeIntegration` 属于另行授权的真实环境验收，需要明确操作范围、合适的隔离环境及所需权限，不属于 PR CI。

离线 MSI 夹具套件若检测到可用的 WiX 3 工具，会在临时目录构建或检查合成 MSI；工具不可用时，应输出明确的 SKIP 原因。CI 不自动下载或安装 WiX，不保证每次 runner 都有这些工具。离线夹具检查不执行 MSI 安装或卸载；夹具 MSI 不是可发布产品，不能当作 release artifact。真实安装、升级、卸载仍需单独的隔离环境验收。

## CI 与日志

[Windows 工作流](.github/workflows/windows-tests.yml) 对 push 和 pull request 运行默认安全套件；只请求 `contents: read`，检出后不保留 Git 凭据。不要引入 `pull_request_target`、secret、发布/签名步骤、真实 MSI 安装、任务注册或外部运行时下载。

运行结果可在 GitHub Actions 对应执行记录中查看。`windows-fixture-logs-*` artifact 保留 7 天，只包含该次默认套件的标准输出、标准错误及 runner 生成的失败日志；不收集 `runtime-bundle/`、已安装运行时、宿主数据、原始支持包或整个临时目录。当前 runner 的失败日志对每个输出流最多保存末尾 256 KB，成功套件只保留汇总。执行超时或取消可能使日志收集不完整，应同时查看 Actions 日志。artifact 不包含 MSI 或其他发布文件。

PR 中的代码会执行于 runner，所以夹具本身也必须只含合成数据，不能把真实私钥、证书、设备标识符或敏感日志写入测试输出。添加或改变套件时，评审其是否仍适合默认安全模式。

## 运行时黑盒边界

`runtime-bundle/` 与任何已安装的 runtime helper 都是单独提供的、不透明的外部依赖。不要读取、修改、逆向分析或在此仓库描述其内部实现；不要提交这些文件或 NVIDIA 二进制。产品层可以依据公开契约使用路径、参数、退出码和合成结果进行测试。缺少外部依赖时应清楚报告缺失，不要下载未知二进制来补齐。

构建真实产品所需的运行时与 NVIDIA 组件由操作者自行合法取得。不得改动现有 NVIDIA App 的安装、服务或注册表状态。证书、签名密钥及真实设备配对不属于公共 CI。

## 提交变更

1. 保持改动聚焦，说明触发条件、预期行为以及实际修复；公共讨论与附件必须脱敏。
2. 为行为变化提供有意义的夹具测试；更新相关中文用户说明。不要用仅匹配实现字面文本的断言替代行为测试。仓库策略测试属于静态契约检查，不能代替 GitHub 对工作流的实际执行。
3. 在 PR 中列出运行过的命令、通过/失败/跳过结果、尚未覆盖的真实环境验证。不要将单元测试通过表述为安装、串流或发布已验收。
4. 提交前检查差异与新增文件，确认没有运行时、hostdata、设备 ID、证书、密钥、令牌、日志、转储或敏感支持包。Git 忽略规则不是保密保证。

本仓库自有产品代码采用 **GPL-3.0-only**，完整条款见 [LICENSE](LICENSE)，适用范围与独立运行时交付边界见 [LICENSING.md](LICENSING.md)。该许可不包含“或任何后续版本”的附加授权，也不为第三方运行时或 NVIDIA 组件授予分发权。提交内容应当是你有权提供的内容；保留已有的有效版权、许可与归属声明，不要自行替换许可证。缺少明确许可的外部文件不能因为本仓库公开就被纳入分发。
