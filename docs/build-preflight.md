# 构建前检查（build preflight）

`scripts/build-product.ps1` 在任何删除或创建操作之前，会对全部输入做一次可验证的预检。预检逻辑位于 `scripts/GsBuildPreflight.ps1`（被构建脚本 dot-source），测试位于 `tests/Invoke-BuildPreflightTests.ps1`。

## 背景与目标

构建脚本每次运行会递归删除两个工作目录（`artifacts\product-stage` 与 `artifacts\wix\product`），并向输出目录写入 MSI。这带来两类真实风险：

1. **非法 MSI 版本**：Windows Installer 的 ProductVersion 有严格数值范围（major 0-255、minor 0-255、build 0-65535）。旧版脚本只检查 `数字.数字.数字` 的形状，`999.0.0` 这类越界版本会一路走到 WiX 编译阶段，失败信息无结构、难以定位。
2. **路径重叠破坏输入**：如果用户把 runtime bundle、WiX 工具目录或输出目录指到与 stage / wixbuild / 源码重叠的位置，每次运行开头的递归删除会直接销毁输入。

预检在上述任何破坏性动作发生前一次性完成全部检查，任一违规即中止（exit 非 0），此时没有任何文件被删除或创建。

## 检查项

### 版本（VersionInvalid）

`Test-GsMsiVersionString`：恰好三段、纯数字，major/minor 0-255、build 0-65535；允许前导零（`01.02.03`）。正则锚用 `\A`/`\z`（.NET 的 `$` 允许末尾换行，`'1.2.3'+LF` 曾因此通过），每段用 `[uint64]::TryParse` 配 `NumberStyles.None`（仅数字，不容空白/符号）解析，超长数字得到干净的结构化拒绝，不会出现溢出异常。不接受空白、正负号、末尾换行或其他字符。

### 完整性检查（保留既有行为）

以下既有检查原样保留，且都在预检之前或由预检统一在删除前执行：WiX 三个工具（heat/candle/light）存在、runtime bundle 目录存在且非空（只按文件名枚举，忽略 `README.md` 与 `manifest.example.json`）、`product\gs-product.ps1` 与 `installer\GsController.wxs` 存在、三个模块（GsControl/GsLifecycle/GsRuntime）的 psd1 与 psm1 存在。模块列表维持现有 3 个，不依赖尚未存在的其他模块。

### 许可文件随 MSI 分发

GPL 分发要求产品附带许可声明：仓库根的 `LICENSE` 与 `LICENSING.md` 是必需输入（缺失即 `Missing input` 失败，发生在任何删除之前），构建时原样复制到 staging 根目录，随 MSI 打包。二者是产品侧文本，与 runtime bundle（保持不透明）无关。

### 输入保护集（含 installer 与 scripts）

受物理保护的输入集合为：RuntimeBundleDir、WixDir、product 目录、installer 目录、scripts 目录（含本脚本与预检 helper）以及三个模块目录，全部从仓库根派生。任一输入目录若经 junction 等别名指向工作目录（如 `installer` → `artifacts\product-stage` 且目标含 wxs，或 `scripts` → `artifacts\wix\product`），现有存在性检查仍会通过，但物理重叠矩阵会在删除前拒绝并保留哨兵内容。

### 输出目录（OutputNotADirectory）

`-OutputDirectory` 若指向一个已存在的文件，报结构化错误。

### 路径重叠（PathOverlap）

所有用户可指定路径先经过 `Resolve-GsPhysicalPath` 解析为物理路径，再参与重叠判定：

- **输入互斥**：RuntimeBundleDir、WixDir、product、installer、scripts 目录与各模块目录两两不得重叠（相等、祖先、子孙都算重叠）。
- **输入 vs 工作目录**：上述输入与 `artifacts\product-stage`、`artifacts\wix\product` 双向不得重叠——工作目录每次运行都被递归删除，重叠即输入被毁。
- **工作目录互斥**：StageDir 与 WixBuildDir 的物理路径不得重叠。二者词法上恒不相交，一旦物理重叠只可能是别名（如 junction），构建先删除 wixbuild 再删除/重删 stage 时会破坏刚 staged 的内容。
- **写/删路径禁含 reparse 组件（WritePathReparse）**：StageDir、WixBuildDir 以及仓库根以下的 OutputDirectory，其词法路径自仓库根以下任一组件（如 `artifacts`、`artifacts\wix`、`artifacts\product-stage` 本身）若是 junction/符号链接，一律拒绝。原因：这些路径是递归删除/写入目标，只要根以下无 reparse 组件，物理位置就等于词法位置，绝不会把仓库其他内容（installer、scripts、tests、.git 等）别名进删除范围。因此把 `artifacts` 用 junction 迁移到其他盘的做法不再被允许；仓库根之外的正常外部 OutputDirectory 不受此规则限制。
- **输出 vs 全部**：OutputDirectory 与所有输入路径、两个工作目录双向不得重叠。

默认 `artifacts\msi` 与正常的外部输出目录不受影响；预检不会创建输出目录（构建模式仍按原逻辑创建）。

### 物理路径解析

`Resolve-GsPhysicalPath` 逐组件走查路径：

- 存在的组件重写为提供程序返回的 FullName（展开 8.3 短名，得到磁盘真实大小写）；
- junction 与目录符号链接替换为链接目标后重新走查（目标内部的再解析会继续展开），拒绝经由重解析点伪装的重叠；
- 词法归一化（`ConvertTo-GsCanonicalLexical`）：相对路径以仓库根为基准、统一分隔符、折叠 `.`/`..`、去尾分隔符、解开 `\\?\` 与 `\\?\UNC\` 前缀；
- 大小写比较为 OrdinalIgnoreCase，且按组件边界判定（`a\bcd` 不与 `a\abc` 重叠）；
- 无法安全解析的情况明确拒绝而非猜测放行：重解析环等在尝试上限（32 次）内未收敛即抛错。

预检只读取目录元数据（存在性、链接类型），不读取任何文件内容，不执行 bundle 中的文件，不签名，不创建或删除任何东西。

## 用法

```text
# 只做预检，通过即退出（exit 0），不做 staging、不调用 WiX、不创建目录
powershell -File scripts\build-product.ps1 -PreflightOnly -RuntimeBundleDir <目录> -WixDir <目录> [-OutputDirectory <目录>] [-Version x.y.z]

# 正常构建：预检内联在删除动作之前执行
powershell -File scripts\build-product.ps1 -Version 0.2.0 -RuntimeBundleDir <目录> -WixDir <目录> [-OutputDirectory <目录>]
```

## 输出与退出码

- 通过：逐行输出 `PREFLIGHT [PASS] version=...` 与每个解析后路径的 `PREFLIGHT [PASS] <键> -> <物理路径>`，随后是既有构建输出；`-PreflightOnly` 时以 `PREFLIGHT OK: all checks passed; stopping before staging (-PreflightOnly).` 结束，exit 0。
- 失败：逐行输出 `PREFLIGHT [FAIL] <Code>: <消息>`（Code 为 `VersionInvalid`、`OutputNotADirectory`、`PathOverlap`、`WritePathReparse`），再抛出 `Build preflight failed with N violation(s); nothing was deleted.`，exit 非 0。

## 测试

`tests/Invoke-BuildPreflightTests.ps1`（Windows PowerShell 5.1）：

```text
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-BuildPreflightTests.ps1
```

全部在 %TEMP% 下的合成仓库运行，不触碰真实 runtime-bundle、不在主仓库默认路径上跑构建脚本、不运行 msiexec、不做证书/凭据操作，也不运行 Invoke-All / Stage3 / Stage12 / TvBox 套件。覆盖：

- 纯函数单测：版本范围与畸形输入（含超长数字不抛异常、末尾 LF/CRLF/制表符/前导换行拒绝）、词法归一化、重叠判定（含组件边界、盘符根）、物理解析（junction 首尾与中间、8.3 短名、缺失尾段、重解析环明确报错、幂等）、reparse 组件走查（严格在边界之下才报告）。
- 脚本级用例（子进程运行真实构建脚本）：`-PreflightOnly` 通过且不创建任何目录；非法版本（含 `1.2.99999999999999999999`）在删除前失败且无溢出异常；精确/祖先/子孙重叠、大小写、尾分隔符、相对 `..`、junction 绕过全部被拒，且预置哨兵文件内容保持不变；stage 为指向 installer 的 junction、wixbuild 为指向 scripts 的 junction、`artifacts` 本身为 junction 均以 `WritePathReparse` 拒绝且对应目录哨兵不变（回归：修复前 stage→installer junction 会被预检误放行，全模式下随后递归删除将销毁 installer）；`installer` 目录为指向 stage 的 junction（目标含 wxs 哨兵）被输入保护拒绝、`scripts` 目录为指向 wixbuild 的 junction 同样被拒（回归：修复前两者均被预检误放行）；仓库根之外带 junction 祖先的外部输出目录仍正常通过；两工作目录经 junction 物理别名被 `PathOverlap` 拒绝；假 WiX 工具（csc 编译，位于 %TEMP%）下完整管线走通、staging 与输出到位、LICENSE/LICENSING.md 逐字节一致、输入哨兵不变；缺失 LICENSE 或 LICENSING.md 在清理前失败且 stage 哨兵保留；junction 重叠在完整模式下同样删除前失败。
- 基线对照（旧代码证据）：用 `git show <baseline>:scripts/build-product.ps1` 取回修改前脚本，在独立合成仓库复现两个旧缺陷——`999.0.0` 被接受并"构建成功"、junction 重叠导致输入哨兵被销毁。默认基线为 `0e545f9`，可用 `-BaselineCommit` 覆盖；git 不可用时对应用例记为跳过。

环境要求：Windows PowerShell 5.1；.NET Framework 的 csc（用于编译假 WiX 工具，缺失时相关用例自动跳过）；git（仅基线对照用例需要）。

## 未覆盖范围

本改动不包含也不声称完成：真实 WiX 工具链构建、真实 MSI 产物验证、msiexec 安装/卸载、代码签名、安装器交互 UX，以及真实 runtime-bundle 的内容校验。构建脚本对 bundle 内容保持不透明（原样复制），预检亦不读取其内容。

## 涉及文件

- `scripts/GsBuildPreflight.ps1`（新增）：预检函数库。
- `scripts/build-product.ps1`（修改）：新增 `-PreflightOnly`；`Version` 改由预检做范围校验；在删除动作之前调用预检并输出 PASS/FAIL 列表。既有完整性检查与消息保持不变。
- `tests/Invoke-BuildPreflightTests.ps1`（新增）：上述测试。
