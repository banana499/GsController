# 威胁模型

更新时间：2026-10-31。范围：产品层（CLI、托盘、诊断/支持包、安装与自启）及其与运行时包的边界。运行时包本身是操作者提供的黑盒，其内部不在本模型内。本文只描述现状与计划中的缓解，不改变任何行为。

## 范围与假设

- 假设主机是家庭 LAN 内的单用户 Windows 11 机器；管理员与日常用户是同一个人（zh-CN 系统）。
- 假设 LAN 内没有恶意主机；但同网段的普通设备可能被攻破，所以 LAN 入站端口仍列为信任边界。
- 产品代码全部是 PowerShell 脚本 + 一个 WiX MSI；没有服务、没有自写驱动。
- 运行时包在构建时被**原样复制**进 MSI（不审计内容），部署到 `<StateDir>\runtime\bin` 后以 SYSTEM 权限运行——这是本模型里权限最高、可见性最低的部分。

## 资产

| 资产 | 说明 | 在哪里 |
|---|---|---|
| 受信任的客户端配对/证书数据 | 决定谁能发起串流 | 运行时管理（黑盒位置）；产品从不读写 |
| 私钥与证书 | 绝不入仓、绝不复制；本文档不给出任何读取指引 | 客户端/主机各自持有 |
| 会话密钥（如客户端日志里的 `rikey`） | 短期有效，但泄露给同网段攻击者意味着可插手会话 | 客户端日志 |
| 状态文件与三个 JSON 配置 | `status.json`（两个候选路径）、`runtime-config.json`、`component-catalog.json`、`runtime-plan.json`；被篡改会误导托盘/CLI 的判断 | `<StateDir>`（见 [file-locations.md](file-locations.md)） |
| SYSTEM 计划任务及其脚本目录 | `GsControllerSupervisor` 以 SYSTEM 运行 `<StateDir>\runtime\bin\gs_supervisor.ps1`（带 `-ExecutionPolicy Bypass`）；**能写这个目录的人能以 SYSTEM 执行代码** | `<StateDir>\runtime\bin` |
| 托盘日志 | 含状态变化与异常文本；脱敏前可能带敏感片段 | `%LOCALAPPDATA%\GsController\tray` |

## 信任边界

| 边界 | 流量/转换 | 说明 |
|---|---|---|
| LAN → 主机 | TCP 47984（HTTPS/配对面）、47989（明文 HTTP serverinfo）、48010（RTSP）；UDP 47998–48000（视频/音频/控制） | 明文 47989 是最大的暴露面；由运行时监听（黑盒），产品层只读它 |
| 普通用户 → SYSTEM | 计划任务以 SYSTEM 运行脚本目录里的脚本 | 文件系统权限就是这道边界；产品目前**不**设置目录 ACL（见威胁 1） |
| 托盘（非提权）→ 提权 CLI | 每次 Start/Stop 经 UAC（`-Verb RunAs`）拉起提权子进程 | 提权子进程继承管理员权限；取消 UAC 只是放弃该次操作 |
| 提权 CLI → 托盘（结果回传） | 提权 CLI 子进程把结果 JSON 写到 `%LOCALAPPDATA%\GsController\tray\results\<guid>.json`，非提权托盘读取后删除 | 该目录在用户配置文件下，本机任何用户态进程都可写；伪造/陈旧的结果文件可从这里进入托盘显示，见威胁 10 |
| 操作者 → 产品 | 运行时包在构建/部署时被原样信任 | 供应链边界：包内任意代码最终以 SYSTEM 运行 |

## 威胁、现有缓解与缺口

| # | 威胁 | 现有缓解 | 缺口 / 残留风险 |
|---|---|---|---|
| 1 | 可写的脚本目录 → SYSTEM 任意代码执行：能写 `<StateDir>\runtime\bin` 的非管理员可以替换自启任务执行的脚本，任务最多 5 分钟后就会以 SYSTEM、带 `-ExecutionPolicy Bypass` 运行它——一次写入等于持久的 SYSTEM 代码执行。即使写权限授给的是某个具体用户账号（包括管理员自己的账号），也按风险处理：非提权令牌仍携带该账号身份；目录所有者同理（所有者可以改写 DACL）。干净机器上 ProgramData 默认允许普通用户在子目录创建文件，继承链会把这条能力带进 `runtime\bin` | 诊断 `hygiene` 段只读检测：按 SID 判定而非账号名，对 `runtime` 和 `runtime\bin`，任何把写权限授予 SYSTEM/Administrators/TrustedInstaller 之外主体的 Allow ACE、以及这三者之外的所有者，都报 `ScriptDirWritableByNonAdmin`（严重度 high） | `Install` 仍不设置 ACL（阶段 2 契约明确未实现），检测不改状态。收紧 ACL 排到以后（N8），且必须先审计并迁移用户会话对这些目录的写入，否则可能弄坏运行中的组件 |
| 2 | StateDir 可写 → 配置与状态欺骗：能写 StateDir 的非管理员可以改 `runtime-config.json`、`status.json`、暂停标志，误导托盘、CLI 与 Recover 的判断（状态欺骗、拒绝服务）；配置里的路径若被提权进程使用，还可能进一步影响加载路径 | 读取失败显式化（`StatusReadFailed`/`NotInstalled`）；`hygiene` 段报告状态文件歧义与暂停标志 | 目前没有针对 StateDir 写权限的专门检测；ACL 收紧按阶段做（先 `runtime\bin`，后 StateDir），见威胁 1 |
| 3 | 卸载后残留计划任务：MSI 无自定义操作，从"应用和功能"直接 `msiexec /x` 之后 `GsControllerSupervisor` 仍在——一个持久的 SYSTEM 执行入口，每 5 分钟从 StateDir 拉起一次栈，而用户以为产品已经卸载 | 运维手册把"提权 `-Action PrepareUninstall` → `msiexec /x`"定为标准卸载路径（；停栈失败也不阻止删任务——卸载清理优先）；旧版本用 `-Action UnregisterAutostart` | 在 MSI 自定义操作落地（N7，先过干净虚拟机验证 N6）之前，卸载是否清理干净完全取决于操作者是否走了手册路径 |
| 4 | 日志泄露：诊断报告/托盘日志/支持包带走凭据（令牌、PEM、PIN、`rikey`、长 base64/hex） | 诊断读取全程脱敏（key=value、Authorization/Cookie 头、Bearer/Basic/Digest 令牌、URL 凭据参数、裸 PIN、PEM 块、32+ 字符 base64/hex、跨行规则），读取有界（尾部、字节上限、超时）；支持包打包前对全部文本条目做第二次高风险模式扫描，命中即 `RedactionCheckFailed` 且不生成 zip | 脱敏是启发式，新格式可能漏；二次检查只覆盖支持包，不覆盖其他导出途径（手工复制日志）。发现漏报要同时补两处 |
| 5 | 生命周期互斥体被抢先创建 → 拒绝服务：低权限进程先创建同名互斥体并设置苛刻 DACL，之后的 Start/Stop/Recover 打不开锁 | 锁用显式 DACL（INTERACTIVE/SYSTEM 得 Synchronize+Modify，Administrators 得 FullControl），创建失败返回结构化 `LockFailed` 而非崩溃 | 若攻击者抢先创建并拒绝授予，操作仍会被挡（拒绝服务，非提权）；产品把错误如实报告。可接受的残留风险 |
| 6 | 伪造 serverinfo（47989 明文 HTTP）：本机任意程序可在 47989 上扮演串流器，让托盘显示就绪/串流中，或让 Recover 的前提失真 | 统一有效性规则（根元素 `root`、`status_code` 200、非空 `<state>`、数字 `currentgame`、64 KB 字节上限、总超时、不跟随重定向）；托盘以状态文件优先：状态文件不存在就显示已停止，不管 47989 有没有应答 | `ready` 状态下托盘的"串流中/就绪"区分完全依赖 47989（已知限制）；Recover 前提 2 也依赖它。操作者须把"托盘说没人在串流"当作必要条件而非充分条件，Recover 前自己确认 |
| 7 | 未签名：MSI 与脚本均未签名，"未知发布者"，SmartScreen 可能拦截 | 签名方案与验收清单已成文（[msi-signing.md](msi-signing.md)）：证书由操作者提供，构建在暂存后、`heat.exe` 前签脚本，`light.exe` 后签 MSI | 当前完全没有签名；自签名等效于没签（SmartScreen 口径）。签名落地前，MSI 只应从可信渠道获取并核对发布清单哈希 |
| 8 | `-ExecutionPolicy Bypass`：自启任务与托盘启动器都以 Bypass 运行脚本 | 原因是结构性的：运行时辅助脚本在安装时被改写（改路径），任何签名都无法存活，`AllSigned` 下 Start/Stop/supervisor 本来就跑不了 | Bypass 下签名只提供篡改证据（`Get-AuthenticodeSignature`），不提供执行策略强制；脚本目录权限（威胁 1）才是真正的防线 |
| 9 | 新旧 CLI 并存互斥失效：互斥体名的路径规范化规则变过，旧版 CLI 与新版 CLI 同时运行时派生不同名字，互不排斥 | 已在文档中记录；部署约束：同一 StateDir 同一时刻只用一个控制器 | 并存部署期间的窗口；单控制器使用时无影响 |
| 10 | 托盘结果目录（用户可写）→ 伪造/陈旧结果欺骗托盘：`%LOCALAPPDATA%\GsController\tray\results` 里的文件可被本机任意用户态进程在托盘读取之前伪造或替换（把失败伪装成成功、注入误导性错误码）；托盘长期未运行时残留的陈旧结果文件也会在下次显示中冒充最近一次操作。另外，提权 CLI 写结果文件时对**已存在的同名文件或符号链接（链接跟随）**的处理尚未评估——预置的链接可能让提权写入端把结果写到别处 | 结果文件名含每次随机生成的 GUID，难以精确抢占；托盘把结果文件读一次即删，托盘启动时清理残留文件；CLI 只写自己生成的固定目录与文件名 | 结果目录本身用户可写，伪造/陈旧结果无法从根上防御（与威胁 2 同类的用户可写状态欺骗面）；提权写入端的链接跟随与预置文件行为未评估，列为已知缺口，待后续加固批次评估 |

残余风险（记录在案、暂不处理）：

- 管理员/操作者账号被攻破：ACL 与签名都无法防御，属于信任边界假设（见"范围与假设"）。
- MSI 自定义操作落地后的回滚窗口：任务已删、卸载又整体回滚 → 自启丢失；N7 落地时需要在发布说明中给出重新注册自启的命令。
- 运行时包不可审计：只能约束它的输入（脚本路径、目录 ACL、配置完整性），无法审计其内部行为。

## 不在范围内

- 运行时包内部：进程模型、监听端口的实现质量、串流协议本身的加固——黑盒，不可审计。
- 配对协议与证书管理（含安全配对向导）：明确排除，等操作者在场并授权后单独做；届时以本文的资产清单为输入。
- 主机加固基线（防火墙策略、账号策略、BitLocker 等）：属整机运维，与产品无直接耦合。
