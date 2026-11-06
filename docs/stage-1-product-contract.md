# 阶段 1 产品契约：GsControl 模块基础

本文档记录阶段 1 的公开接口与目录约定。实现位于 `src/GsControl/`，测试入口为 `tests/Invoke-Stage1Tests.ps1`。运行环境为 Windows PowerShell 5.1，不依赖外部模块或 Python。

## 1. 模块

- 清单：`src/GsControl/GsControl.psd1`（ModuleVersion `0.1.0`，PowerShellVersion `5.1`）
- 根模块：`src/GsControl/GsControl.psm1`
- 导出函数：`Resolve-GsPath`、`Read-GsManifest`。其余函数为模块内部函数，不属于契约。

## 2. 公开函数

### Resolve-GsPath

```powershell
Resolve-GsPath [-Path] <string> [-BasePath <string>]
```

- 返回 `[string]`：经 `[System.IO.Path]::GetFullPath` 规范化的绝对路径（折叠 `.` 与 `..`）。
- 接受的绝对路径形式：`X:\...`（或 `X:/...`）与 UNC `\\server\share\...`。不含盘符、不以 `\` 或 `/` 开头的路径视为相对路径。其余形式按下表拒绝。
- `Path` 为绝对路径时忽略 `BasePath`。
- `Path` 为相对路径时：
  - 未提供 `BasePath`：基于当前 PowerShell FileSystem 位置（`Get-Location -PSProvider FileSystem`）解析，不使用 .NET 进程当前目录。
  - `BasePath` 为绝对路径：直接用 `[System.IO.Path]::Combine` 拼接，不要求该驱动器或目录存在。
  - `BasePath` 为相对路径：先基于当前 PowerShell FileSystem 位置解析，再拼接 `Path`。
- 路径拼接只使用 `[System.IO.Path]::Combine`，不经过 `Join-Path` 或 PowerShell 驱动器。函数不访问文件系统，不检查路径是否存在，不创建目录。
- 以下输入抛出 `System.ArgumentException`（异常类型精确为该类型，不是包装异常）：

| 输入 | ParamName |
|------|-----------|
| `Path` 为 `$null`、空字符串或纯空白 | `Path` |
| `Path` 含非法字符（`<` `>` `\|` `"` `*` `?` 及控制字符，因此 `\\?\` 前缀也被拒绝） | `Path` |
| `Path` 在盘符前缀以外含 `:`（如 `C:\a:b`、`HKLM:\x`） | `Path` |
| `Path` 为盘符相对形式（`C:foo`）或根相对形式（`\foo`） | `Path` |
| `GetFullPath` 无法规范化（如超过 260 字符） | `Path` |
| 显式传入的 `BasePath` 为空字符串或纯空白 | `BasePath` |
| `BasePath` 含非法字符、为盘符相对或根相对形式、为非文件系统路径（如 `HKLM:\SOFTWARE`） | `BasePath` |

### Read-GsManifest

```powershell
Read-GsManifest [-Path] <string>
```

- 路径先经 `Resolve-GsPath` 处理。空路径或非法路径会抛出 `System.ArgumentException`（ParamName = `Path`），不返回结果对象。
- 内容问题（文件不存在、JSON 错误、字段不符）不抛异常，统一返回结果对象：

| 字段 | 类型 | 说明 |
|------|------|------|
| `Success` | bool | `Errors` 为空时为 `$true` |
| `Path` | string | 规范化后的绝对路径 |
| `Manifest` | PSCustomObject 或 `$null` | 仅在 `Success` 为 `$true` 时返回解析结果 |
| `Errors` | object[] | 每项包含 `Code`、`Field`、`Message` |

错误码：

| Code | Field | 触发条件 |
|------|-------|----------|
| `FileNotFound` | `''` | 文件不存在 |
| `ReadFailed` | `''` | 文件存在但读取失败（如被其他进程独占锁定） |
| `InvalidJson` | `''` | 文件为空或 JSON 无法解析 |
| `InvalidType` | `''` | JSON 根节点不是对象 |
| `MissingField` | `schemaVersion` / `components` | 必填字段缺失 |
| `InvalidType` | `schemaVersion` | 不是整数 |
| `UnsupportedValue` | `schemaVersion` | 不等于 1 |
| `InvalidType` | `components` | 不是 JSON 数组 |
| `UnsupportedValue` | `components` | 数组非空（阶段 1 只接受空数组） |

同一文件的多个字段错误会全部列出。

## 3. 清单格式（schemaVersion 1）

```json
{
  "schemaVersion": 1,
  "components": []
}
```

- 文件按 UTF-8 读取（有无 BOM 均可）。
- 允许出现其他顶层字段，阶段 1 不校验也不使用它们。
- `components` 元素的结构留待后续阶段定义。

## 4. 安装目录与状态目录契约

以下是约定，阶段 1 代码尚未读取、创建或写入这些目录：

- 安装目录：存放组件程序文件，安装后视为只读。所有路径在使用前须经 `Resolve-GsPath` 规范化为绝对路径。
- 状态目录：存放运行时状态、日志与清单副本，与安装目录分离，卸载或升级安装目录时不得删除。
- 两个目录的具体默认位置、权限与覆盖方式（参数或环境变量）在后续阶段确定，确定前任何代码不得硬编码这些位置。

## 5. 明确未实现

- 组件定义、下载、校验、安装、卸载与升级。
- 安装目录与状态目录的默认位置、创建与权限设置。
- `schemaVersion` 1 以外的版本与迁移。
- 超过 260 字符的长路径与 `\\?\` 前缀路径（当前作为 ArgumentException 拒绝）。
- 系统信息采集、服务、注册表、防火墙等任何系统配置操作。
- `scripts/` 下的历史实验代码未改动，也未接入本模块。

## 6. 验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Stage1Tests.ps1
```

全部通过时退出码为 0，任一失败或零个测试执行时退出码为 1。
