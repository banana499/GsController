# 支持包（gs-support.ps1）

支持包把诊断报告和已脱敏的托盘日志打包成一个 zip 文件，方便自己排查或发给别人。整个过程只读：不修改任何产品状态，不改动计划任务、注册表、ACL 或防火墙。

## 如何运行

在安装目录（`gs-support.ps1` 与 `gs-product.ps1`、`gs-diagnose.ps1` 同目录）执行：

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File gs-support.ps1
```

参数（全部可选）：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-OutputDir` | `%LOCALAPPDATA%\GsController\support` | zip 的输出目录。必须是绝对路径，且不能在安装目录内 |
| `-InstallDir` | 脚本所在目录 | 产品安装目录 |
| `-StateDir` | 由 gs-diagnose.ps1 决定 | 转发给诊断脚本 |
| `-LogDir` | 由 gs-diagnose.ps1 决定 | 转发给诊断脚本 |
| `-TrayLogDir` | `%LOCALAPPDATA%\GsController\tray` | 托盘日志目录；取其中 `tray.log` 与 `tray.log.1` 的脱敏尾部 |
| `-ServerInfoUri` | 由 gs-diagnose.ps1 决定 | 转发给诊断脚本 |
| `-DiagnoseScript` | 同目录的 `gs-diagnose.ps1` | 诊断脚本路径 |
| `-SkipInstalledProductLookup` | 关 | 转发给诊断脚本，跳过已安装 MSI 的注册表只读查询 |
| `-SupervisorTaskName` | `GsControllerSupervisor` | 转发给诊断脚本；传空串 `''` 跳过计划任务查询（自动化测试用） |
| `-SkipHostCheck` | 关 | 转发给诊断脚本，跳过主机信息的只读 CIM 查询（自动化测试用，避免触碰真实 CIM） |
| `-DiagnoseTimeoutSec` | `180` | 诊断子进程的硬性期限（秒），同时覆盖进程退出与两根输出管道的排空；超时会把整棵子进程树一起终止（自动化测试用小值） |

脚本不导入任何产品模块，模块损坏时也能运行。hygiene 段的目录 ACL 只读检查没有跳过开关，始终是支持包的一部分（每个转发参数都不含 `-SkipAclCheck`）。诊断子进程的每个参数都按 Windows 原生规则编码（引号前和引号结尾的反斜杠翻倍），带空格或以反斜杠结尾的路径原样到达子进程。最后一个输出元素是结果对象：

```text
schemaVersion = 1
Success       = True/False
ZipPath       = 生成的 zip 路径（失败时为空）
Entries       = 三个条目的名称、SHA-256 与大小
Errors        = 失败原因数组，每项 { code; message }
```

退出码：成功 `0`，失败 `1`。错误码：

| 错误码 | 含义 |
|---|---|
| `OutputDirInvalid` | 输出目录是相对路径、在安装目录内、与安装目录相同、是个文件，或无法创建 |
| `DiagnoseUnavailable` | 找不到 gs-diagnose.ps1 |
| `DiagnoseFailed` | 诊断子进程超时（整棵子进程树被终止）、退出码非 0（只报告退出码，绝不把子进程 stderr 原文带进结果）、输出不是 JSON 或 schemaVersion 不是 1 |
| `RedactionCheckFailed` | 二次检查发现了疑似未脱敏的机密，不生成 zip（失败即关闭） |
| `ZipFailed` | 写 zip 或改名失败 |
| `SupportFailed` | 脚本内部出现意外异常（例如某个路径落在不存在的盘符上、子进程启动失败）时的兜底结果：固定英文消息，退出码 1 |

## zip 放在哪里

成功时 zip 位于 `-OutputDir` 下，文件名形如：

```text
%LOCALAPPDATA%\GsController\support\GsController-support-20261031-223000-123.zip
```

文件名带毫秒时间戳，连续两次运行会得到不同的文件。zip 先写入临时名再改名。

## 包含什么

| 条目 | 内容 |
|---|---|
| `diagnose.json` | `gs-diagnose.ps1 -AsJson` 的完整报告原文（产品文件哈希、运行时配置、状态文件白名单字段、serverinfo、组件 PID、运行时包文件名与哈希、supervisor 日志脱敏尾部、hygiene 卫生检查、托盘日志脱敏尾部） |
| `extra-logs.json` | 报告里的 `extraLogs[]`：`tray.log` 和 `tray.log.1` 的尾部（默认各 50 行），与 supervisor 日志走同一套有界读取与脱敏 |
| `manifest.json` | 生成时间（UTC）、产品版本，以及 `diagnose.json`、`extra-logs.json` 的 SHA-256 与字节数（清单自身无法为自己做哈希，对应行为空） |

托盘日志的脱敏只由 `gs-diagnose.ps1` 的 `-ExtraLogPath` 参数完成，复用 supervisor 日志现有的有界读取和脱敏逻辑，全仓库只有一份脱敏实现。脱敏覆盖：口令/令牌/密钥类键值对、Authorization/Cookie 等头、Bearer/Basic 等凭据令牌、PEM 块、PIN、URL 里的凭据参数、日志行里的长 base64/hex 串等。

打包前对每个条目做一次二次检查：扫描走的是**解码后的 JSON 字符串**（报告对象图本身，而不是序列化文本，转义形式藏不住机密）。凭据类规则（口令/令牌键值对、Authorization/Cookie 等头、Bearer/Basic 令牌、PEM 块、PIN、URL 凭据参数）作用于全部自由文本；长 base64/hex 串规则只作用于状态字段（state、runId、lastError）与日志行，不作用于路径元数据等其他字段。已验证的元数据予以豁免：sha256/hash 类字段里的 SHA-256 哈希值（字段名以 sha256/hash 结尾且值恰为 64 位十六进制）、路径类字段（path/dir/uri/root 结尾）、ACL 的 sid 字段（打码后的机器本地 SID 或已知 SID 形式）；因此状态文本或日志行里裸的 64 位十六进制串（植入配对密钥的形态）仍会被长串规则拒绝。任何一条命中就返回 `RedactionCheckFailed` 并且不生成 zip；错误信息只包含条目名、字段路径、行号和模式名，不会回显疑似机密本身。

`hygiene` 段的目录 ACL 检查（`ScriptDirWritableByNonAdmin`）在本机执行只读 `Get-Acl`，报告里的机器本地 SID（`S-1-5-21-a-b-c-RID`）会被打码成 `S-1-5-21-*-RID`——不仅在 ACL 字段，而是在整份报告生成后的最后一遍全字符串打码（暂停标志首行、日志行、路径、错误消息都覆盖）；已知 SID（SYSTEM、Administrators、TrustedInstaller 等）保持原样，报告不含原始 SDDL，ACL 读取/解析失败只报固定英文消息（不携带原始异常文本），因此支持包可以安全外发。

## 不包含什么

- `status.json` 原文（只有白名单字段：state、runId、lastError，且经过脱敏）
- 运行时包文件的内容（只有文件名、大小、时间戳和 SHA-256）
- 配对数据、证书、私钥
- Moonlight 客户端设置
- 除 `tray.log`、`tray.log.1` 之外的任何日志；`diagnose.json` 内的 supervisor 日志也只有脱敏后的尾部

## 常见问题

- **提示 `DiagnoseUnavailable`**：安装目录里没有 `gs-diagnose.ps1`。用 `-DiagnoseScript` 指到正确位置。
- **提示 `DiagnoseFailed` 且退出码非 0**：多为参数写错（例如 `-ServerInfoUri` 不是 http 绝对地址），support 的错误消息只含退出码；要看具体错误，直接运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File gs-diagnose.ps1 -AsJson`，其 stderr 会带原始异常。
- **提示 `SupportFailed`**：脚本内部意外异常的兜底（固定英文消息，不带异常细节）；检查各路径参数（尤其是是否落在不存在的盘符上）后重试。
- **想看计划任务是否残留**：看 `diagnose.json` 里 `hygiene.supervisorTask` 与 `hygiene.findings` 中的 `OrphanedSupervisorTask`；暂停的自动恢复看 `SupervisorPaused`。
