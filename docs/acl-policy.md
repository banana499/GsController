# ACL 策略模块（只读）

对应 `artifacts/security/security-design.md` 的 4.2（目标 ACL）、4.4（应用步骤提案）、4.7（本机偏差与分阶段）。本模块把该设计推进为可复用、只读、夹具可验的策略代码，是后续 `Harden`/`Install` 接线的基础。

**当前定位（务必阅读）**

- 本阶段**没有 Apply/Harden 写 ACL 能力**：模块与工具中不存在 `Set-Acl`/`SetAccessControl` 或任何隐式写权限行为。
- `GsSecurity` 模块**尚未自动接入**产品 `Install` 动作；主协调者后续处理打包与接线。
- 只读预检（`Get-GsAclPlan.ps1`）**不是完整权限加固**：它只回答“当前状态与目标策略差多少、还欠哪些前置确认”，不改变任何权限。
- 所有目标目录的 `applyReady` 恒为 `false`（见下文 blockers），因为用户会话写入迁移尚未确认；SDDL 构造正确不代表可以安全 Apply。
- 安全设计的 N8（权限加固）**不因本模块而关闭**：实际应用、运行时写入迁移、虚拟机实测都未完成。

## 1. 策略定义

对 `StateDir`、`StateDir\runtime`、`StateDir\runtime\bin` 应用同一套目标策略：

| 主体 | 权限 | 继承 |
|---|---|---|
| `NT AUTHORITY\SYSTEM`（S-1-5-18） | FullControl | OI + CI |
| `BUILTIN\Administrators`（S-1-5-32-544） | FullControl | OI + CI |
| `BUILTIN\Users`（S-1-5-32-545） | ReadAndExecute + Synchronize（原始掩码 0x1200a9） | OI + CI |
| 其他主体 | 无 | — |

- 关闭继承（`SetAccessRuleProtection($true, $false)`），不保留从父目录继承的任何 ACE。
- 所有者：`BUILTIN\Administrators`（默认）或 `SYSTEM`；绝不留给非管理员（所有者可改 DACL，权限高于 DACL 未显式授予的部分）。组固定为 `SYSTEM`。
- 目标 SDDL 的两种规范形态（语义等价，验证时不做文本比较）：
  - API 构建形态：`O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)`
  - 设计文档形态：`O:BAG:SYD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)`
- `0x1200a9` = `ReadAndExecute + Synchronize`。注意 .NET 枚举 `ReadAndExecute` 本身是 0x200a9，**不含** Synchronize，构建时必须显式 `-bor Synchronize`。

### 合规判定（语义比较，全部保守）

合规要求同时满足以下全部条件；任何一条不满足都判不合规：

1. DACL 受保护（P），且没有继承 ACE。
2. 所有者是 S-1-5-18 或 S-1-5-32-544（缺所有者也判不合规）。
3. 不存在任何**非管理员主体的 allow ACE 带写权限位**（写位集合与 `gs-diagnose.ps1` 的 `Test-GsSddlWritableByNonAdmin` 一致：0x2、0x4、0x10、0x40、0x100、0x10000、0x40000、0x80000、0x10000000、0x40000000；通用写 0x40000000 也算写）。
4. **不存在任何 deny ACE**（保守：不做“deny 抵消 allow 后合规”的推理，deny 对任何主体出现都是偏差）。
5. SYSTEM 与 Administrators 的 FullControl（原始掩码 0x1f01ff 或 GenericAll 0x10000000）必须来自**标准形态**的 allow ACE：作用于对象本身（非 inherit-only）、完整 OI+CI、无 NoPropagateInherit。inherit-only / no-propagate / 缺 OI 或 CI 的目标 SID ACE 保守判偏差（`NonStandardAceShape`），不做访问检查器模拟。
6. Users 的 allow 权限（按标准形态 ACE 的 SID OR 合并）**恰好等于** 0x1200a9；通用权限形态（GR/GE 等）不接受，直接判偏差。
7. 除上述三个 SID 外不存在其他 allow ACE——**额外只读 ACE 也是偏差**（目标策略是“其他主体无”）。
8. CREATOR OWNER（S-1-3-0）**不再豁免**：即使当前所有者是 Administrators，CO 或任何其他额外主体的 allow ACE 也判偏差（带写位为 `NonAdminWriteAce`，否则 `UnexpectedAllowAce`）；所有者合规性仍由第 2 条单独强制。

实现细节：ACE 顺序、SDDL 写法差异（`P` 与 `PAI`、ACE 排列）不影响判定；SID 全程按 SID 字符串比较，**不解析账户名**（离线可用，且用户名不可能泄漏）；机器本地 SID（S-1-5-21-a-b-c-RID）在输出前统一脱敏为 `S-1-5-21-*-RID`。SDDL 解析失败不抛异常，而是返回带 `SddlParseFailed` 发现项的不合规结论（“不可评估”按“不合规”处理）。

## 2. 模块 API（`src/GsSecurity/GsSecurity.psd1`）

只导出两个函数：

### `New-GsAclPolicy`（内存构建目标策略）

```powershell
$policy = New-GsAclPolicy                       # owner = BUILTIN\Administrators
$policy = New-GsAclPolicy -OwnerSid 'S-1-5-18'  # owner = SYSTEM
$sddl    = $policy.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::All)
```

返回 `DirectorySecurity`。纯内存，不触盘；`-OwnerSid` 只接受 `S-1-5-32-544` / `S-1-5-18`，其他值在参数校验层拒绝。

### `Test-GsAclPolicy`（语义合规判定）

```powershell
$verdict = Test-GsAclPolicy -Sddl $someSddl                  # 或 -Security $someDirectorySecurity（二选一）
$verdict.Compliant; $verdict.Findings | Format-Table Code, Severity, Message
```

`-Sddl` 与 `-Security` 必须恰好给一个。返回对象字段：

| 字段 | 含义 |
|---|---|
| `Compliant` | 是否完全合规（Findings 为空） |
| `Protected` / `HasInheritedAces` | 受保护标志 / 是否含继承 ACE |
| `OwnerSid` | 所有者 SID（已脱敏；无所有者为 `$null`） |
| `OwnerCompliant` | 所有者是否在允许清单内 |
| `DenyAceCount` | deny ACE 数量 |
| `UsersRightsHex` | Users allow 权限 OR 合并后的十六进制（无则为 `$null`） |
| `AdminGrantsComplete` / `UsersRightsComplete` | 第 5、6 条是否满足 |
| `NonAdminWriters` | `@({ sid, rightsHex })`，非管理员写主体（已脱敏） |
| `Findings` | `@({ code, severity, message })`，message 为英文 |

Finding 代码：`SddlParseFailed`、`InheritanceNotProtected`、`InheritedAcesPresent`、`OwnerMissing`、`OwnerOutsideAllowlist`、`NonAdminWriteAce`、`DenyAcePresent`、`NonStandardAceShape`、`RequiredGrantMissing`、`UsersRightsMissing`、`UsersRightsUnexpected`、`UnexpectedAllowAce`（severity：`high` = 削弱安全性的偏差，`medium` = 与目标状态不符）。

## 3. 只读预检工具（`tools/Get-GsAclPlan.ps1`）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Get-GsAclPlan.ps1 `
    -StateDir "$env:ProgramData\Local Development\GsController"
```

- `-StateDir` 必填，必须是**绝对且规范**的路径；相对路径、`..`/`.` 段、非原生分隔符一律拒绝（错误码 `StateDirMustBeAbsolute` / `StateDirMustBeCanonical` / `StateDirNotResolvable`），不做静默归一化。
- 只读元数据：对每个候选目标（`<StateDir>`、`<StateDir>\runtime`、`<StateDir>\runtime\bin`）**逐级检查其祖先链**（从驱动器根到目标本身），每个唯一路径本次运行内至多一次 `Get-Item` 属性读取（结果跨目标缓存共享）；目标整条链干净时至多一次 `Get-Acl`。不枚举目录内容、不读文件内容、不读运行时文件/日志、不读 runtime-bundle、不读 LogDir、不访问任何凭据材料。
- 支路阻断：祖先链**任意一级**是 reparse point（含 StateDir 的祖先 junction）且**在检查期间被观察到**，即拒绝该支路并计 `ReparsePointTargetRejected`，检查期间不穿过 junction/symlink 读取 ACL（静态拒绝保留，但见下方快照限制）；祖先缺失 → 目标按 `missing` 处理；祖先元数据读取失败（明确 not-found 以外的任何错误）→ 结构化失败 `AncestorReadFailed`，不会误判为 `missing`。
- reparse point（junction/符号链接）目标**拒绝评估**：标记 `reparsePoint` 并计入 Errors（`ReparsePointTargetRejected`）。
- 输出单行 JSON：`{ Success, Data: { StateDir, PolicySddl, Simulation, Targets[], Summary }, Errors[] }`；消息英文；机器 SID 与用户主目录路径前缀在最终输出统一脱敏（`S-1-5-21-*-RID`、`<UserProfile>`）。
- 模拟标记：只要绑定了任何测试 seam（**包括模拟错误返回的注入**），`Data.Simulation.TestSeamsUsed` 即为 `true`，`Data.Simulation.Seams` 列出 seam 名称（`GetItemReader`/`ItemState`/`AclSddl`）；带 seam 的输出不得作为实机证据。
- 快照性质（`Data.Snapshot`）：输出是**读时快照**，`atomicIsolation=false`、`topologyStabilityRequired=true`。要求检查期间目录拓扑稳定；**不保证抵抗**检查与 ACL 读取之间的并发目录替换（本阶段不做原生句柄/权限实现）；reparse 拒绝只覆盖检查时观察到的状态，不是原子保证。**本工具不是访问控制沙箱，也不是 Apply 授权**——`applyReady` 恒为 false。
- JSON 契约：数组**始终**序列化为数组（空为 `[]`、单元素也是 `[ ... ]`）——工具使用内置 `ConvertTo-Json -InputObject -Depth 12`，脱敏层对数组返回做了防解卷保护（逗号包裹），因此空/单元素数组不会塌缩。内置序列化器会把 `<`/`>`/`&` 等 HTML 敏感字符转义为 `\uXXXX`（例如脱敏占位符在原始 JSON 文本中显示为反斜杠转义形式 `\` + `u003cUserProfile` + `\` + `u003e`，`ConvertFrom-Json` 解析后还原为 `<UserProfile>`）。字段大小写：目标条目键为小写（`target`/`path`/`status`/`compliant`/`ownerSid`/`writers`/`usersRightsHex`/`findings`/`applyReady`/`applyBlockers`），嵌套 finding 对象沿用模块的 `Code`/`Severity`/`Message`，`writers` 元素为 `sid`/`rightsHex`。
- 退出码：`0` = 计划完整产出（即使目标有偏差/缺失）；`1` = 参数非法或目标被拒绝（`Success=false`）。

### 每目标状态

| status | 含义 |
|---|---|
| `compliant` | DACL 语义合规（**仍然不可 Apply**，见 blockers） |
| `deviates` | DACL 与目标策略有偏差（findings 内含具体偏差） |
| `missing` | 目录尚不存在（由 Install 创建后的安装流程负责） |
| `reparsePoint` | 是 reparse point，已拒绝评估（计 Errors） |
| `notDirectory` | 路径存在但不是目录（计 Errors） |
| `aclReadFailed` | ACL 读取失败（计 Errors） |

### blockers：为什么永远不可 Apply

每个目标的 `applyReady` 恒为 `false`，`applyBlockers` 至少包含一条未确认的依赖：

| 目标 | blocker | 原因（security-design.md 4.2/4.7） |
|---|---|---|
| `stateDir` | `StateRootWritesNotConfirmed` | 阶段 2：`runtime-config.json`、`status.json`、pause flag 必须先确认只由提权进程/SYSTEM 写入 |
| `runtime` | `RuntimeStateUserWritesNotConfirmed` | `runtime\state` 需要用户会话写入（`hook_watchers.json`），迁移确认前不能收紧 |
| `runtimeBin` | `UserSessionLogMigrationNotConfirmed` | `_watch_inject_auto.log`/`.err` 等用户会话日志必须先迁走或确认只由 SYSTEM 写 |
| 任意 | `TargetDoesNotExist` / `TargetIsAReparsePoint` / `TargetIsNotADirectory` / `AclCouldNotBeRead` | 目标状态本身不可硬化 |

`Summary.applyActionAvailable` 恒为 `false`，note 说明本阶段没有 apply/harden 实现。**不因 SDDL 构造正确就声称可安全 Apply。**

### 测试 seam（仅测试/诊断用）

- `-GetItemReader <scriptblock>`：绑定后替代真实的逐级元数据读取；契约——收到一个路径，明确 not-found 返回 `$null`，否则返回带 `.Attributes` 的对象，**读取失败必须抛异常**（异常 = 结构化失败，绝不静默当作 missing）。测试可用它注入 reparse/错误状态并记录读取路径计数。
- `-ItemState <stateDir>,<runtime>,<runtimeBin>`：绑定后整支路替代真实祖先链遍历，值可以是 `missing` / `reparsePoint` / `notDirectory`（兼容别名 `file`，内部归一化）/ `directory` / `unreadable`（不足 3 个报 `ItemStateSeamTooShort`）。
- `-AclSddl <sddl1>,<sddl2>,<sddl3>`：绑定后每目标用给定 SDDL 在内存中替代真实 `Get-Acl`（空串模拟读取失败）。

这三个 seam 与 `gs-diagnose.ps1` 的 TEST SEAM 惯例一致，是只读的模拟输入，不是写路径；绑定任何 seam 都会置位 `Data.Simulation.TestSeamsUsed`。

## 4. 安全边界承诺

- 全内存：策略构建与验证只使用内存中的 `DirectorySecurity`/SDDL；不访问证书、私钥、凭据。
- 只读：不存在 `Set-Acl`、`SetAccessControl`、`AddAccessRule` 落盘路径；工具只做逐级祖先链 `Get-Item` 元数据读取与显式目标 `Get-Acl`。
- 不递归读取运行时文件/日志；不读 runtime-bundle 或运行时仓库；reparse/逃逸路径拒绝评估。
- 结果不含原始机器 SID、用户名；消息英文，文档中文。
- **快照与并发限制**：输出为读时快照，要求检查期间目录拓扑稳定；不保证抵抗并发替换（见第 3 节 `Data.Snapshot`），不是访问控制沙箱或 Apply 授权；真实 Apply 与运行时写入迁移仍属未来工作。

## 5. 测试

`tests/Invoke-AclPolicyTests.ps1`：全部内存 ACL/SDDL + 注入 seam；真实文件系统夹具仅 `%TEMP%` 下的普通目录（`New-Item` 创建，无任何 Set-Acl/真实系统更改）。覆盖：

- 合规策略（API 构建、设计文档字面 SDDL、ACE 重排——证明语义比较而非文本比较）；
- 宽松继承（未保护 DACL）、非管理员 owner、缺 owner、机器 SID owner 的脱敏；
- 未知 SID 写 ACE、通用写位、Users FullControl（写位）；
- deny 影响（deny on Users、deny on SYSTEM 都保守判不合规）；
- 额外只读 ACE 的策略一致性（判偏差）；
- 缺失授权、Users 掩码不精确、无效 SDDL（不抛异常）、`-Sddl`/`-Security` 互斥；
- ACE 形态：缺 OI/CI 的 Users ACE、inherit-only（OICIIO）与 no-propagate（OICINP）的 SYSTEM ACE、部分继承标志均判 `NonStandardAceShape` 且不满足授权要求；CREATOR OWNER 的写/只读 ACE 均判偏差；
- 工具：缺失目录（never apply-ready）、合规 seam + 真实 `%TEMP%` 目录（compliant 但仍被 blockers 挡住）、偏差、reparse/文件/读失败（模拟 seam）、非规范路径/相对路径/seam 长度拒绝、输出脱敏（无机器 SID/用户名/profile 路径）；
- 工具祖先链：真实 %TEMP% junction 作为祖先时整条支路被拒且不穿 junction 读 ACL；注入 `-GetItemReader` 记录读取路径，证明读取只发生在 StateDir 祖先链内且路径缓存共享（无越界读取）；只有明确 not-found 才算 `missing`，其他读取错误是结构化失败（`AncestorReadFailed`）；
- 输出契约：`Data.Simulation.TestSeamsUsed` 在任何 seam 绑定（含错误返回注入）时置位、无 seam 时为 false；`Errors`/`findings`/`writers`/`applyBlockers` 在 0/1/多元素下均解析为稳定数组。

## 6. 未完成事项（不属于本模块）

1. **实际应用**：设计文档 4.4 提的 `Set-GsProtectedDirectoryAcl`（GsRuntime）尚未实现——需要真实 `Set-Acl`，须用户明确批准后另行推进。
2. **Install/Harden 接线**：模块未接入 `Install`/`Harden` 动作，由主协调者后续处理打包与失败条件（4.4 第 2、4 步、4.7 阶段 4）。
3. **运行时写入迁移**：`runtime\state` 的 `hook_watchers.json` 与 `runtime\bin` 的用户会话日志迁移未确认，故全部目标 `applyReady=false`。
4. **虚拟机实测**：干净机器默认 ACL 链（4.2 推理链、7.2）需 VM 验证；MSI `PermissionEx` 兜底（4.3）未做。
5. `LogDir` 与 `StateDir` 根目录的进一步评估（4.2/4.7 阶段 2、3）。

因此 N8 不因本模块关闭；本模块只是“ACL 预检基础”。
