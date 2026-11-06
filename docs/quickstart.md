# 从干净克隆开始

本仓库提供 GsController 的产品控制层、生命周期模块、安装器源码及测试。**克隆后可以运行单元测试和只读预检；仅凭仓库不能完成真实串流。** 实际串流还需要合法取得、版本兼容的外部 runtime bundle，以及使用者自备的组件树、适配的主机和客户端。

产品代码采用 **GPL-3.0-only**，完整条款与许可边界见 [LICENSE](../LICENSE) 和 [LICENSING.md](../LICENSING.md)。自有 runtime 计划作为**独立、版本化的公开运行时包**交付；NVIDIA 组件仍须使用者依适用许可合法取得并自备，产品代码的 GPL 不授予这些组件的复制或再分发权。

截至 2026-11-06，运行时包尚无真实公开下载 URL 或已公布的校验值。本页不虚构下载位置，也不把测试夹具当作可用的流媒体实现。公开包的版本契约、合法交付材料、依赖说明及新版本的部署验收仍是发布阻塞；独立打包本身不豁免包内文件的许可与对应源码义务。

## 1. 先检查源码和运行单元测试

使用 **Windows x64 上的 64 位 Windows PowerShell 5.1**，目前记录的验证系统为 Windows 11 x64。PowerShell 7、Windows ARM64、32 位 PowerShell 及非 Windows 不属于本预检的支持环境。以下命令在普通权限终端中逐段执行。把示例路径替换为自己的绝对路径；含空格的路径需保留引号。不需要预先安装 WiX 或准备 runtime。

在已克隆的仓库中设置路径，先运行默认的只读预检：

```powershell
$repo = 'D:\Projects\GsController-Product-Dev'
$preflight = Join-Path $repo 'scripts\Test-GsPrerequisites.ps1'
$r = & $preflight -RepoRoot $repo -Mode Source
$r | ConvertTo-Json -Depth 8
if (-not $r.Success) { throw 'Source prerequisites failed. Stop and resolve Errors first.' }
```

预检只检查环境及明确路径下的文件/目录是否存在，不创建目录、不导入产品模块、不读取外部 helper/DLL/证书内容、不执行任何外部文件，不安装、不下载、不提权，也不修改服务、任务或 ACL。它不会自动查找本机安装目录、私人共享、WiX 或仓库内的 `runtime-bundle/`。

结果约定：

| 字段/状态 | 含义 |
|---|---|
| `Success` | 所选模式的必需项，以及调用者明确提供的外部依赖，均通过元数据检查 |
| `Data.Checks` | 每项的 `Name`、`Status`、`Required`、`Path`、`Message`、`NextStep` |
| `Errors` | 导致失败的结构化错误；常见 `Code` 为 `MissingDependency`、`InvalidPath`、`UnsupportedEnvironment` |
| `Data.NextSteps` | 需要补齐的依赖及下一步，包括可选但真实串流必需的依赖 |
| `Data.MetadataOnly` | 始终为 `true` |
| `Data.RuntimeValidated` / `Data.SecurityValidated` | 始终为 `false`，文件存在不等于验收、安全审核或授权通过 |

`Source` 模式未传 runtime 或组件路径时，会在 `Data.Checks` 中报告 `MissingDependency`，但 `Required=false`，不阻止源码测试。明确传入的路径缺失或结构不完整时会失败。`Source` 模式完全不检查 WiX，传入 `-WixDir` 也不改变这一点。

脚本返回 PowerShell 对象，不会因依赖缺失退出调用者的 PowerShell 会话；必须判断 `Success`，不能用进程退出码替代它。自动化需要退出码时，包装调用并在检查后自行 `exit 1`。`-EnvironmentProbe` 仅用于合成测试，会令 `Data.EnvironmentSimulated=true`；实际预检不要使用该参数。

接着逐项运行以下限定测试，每次退出码非零都停下处理：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo\tests\Invoke-PrerequisiteTests.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Prerequisite tests failed.' }
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo\tests\Invoke-Stage1Tests.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Stage1 tests failed.' }
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo\tests\Invoke-Stage2Tests.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Stage2 tests failed.' }
```

测试会输出 `Summary: N passed, 0 failed`，成功退出码为 0。预检测试用临时合成目录及注入的环境探测，不检查真实 runtime。Stage1/Stage2 使用临时测试数据；Stage2 包含临时目录上的权限与并发场景。以上测试结果不涵盖安装、GPU、驱动、网络、串流或真实客户端验收。`-ExecutionPolicy Bypass` 只作用于所启动的测试进程，不更改系统执行策略。

## 2. 有合法外部依赖时，仍先只读检查

正式发布时，使用者应能从独立运行时包的发布记录取得匹配版本，并将其解包到明确指定的外部目录。该发布记录必须提供下表信息；当前各项均是发布前待填，不能当作已有发行包使用。

| 发布接口 | 当前状态 |
|---|---|
| 运行时包版本、包文件名、支持平台及产品版本范围 | 发布前待填 |
| 可实际获取该版本的公开下载 URL | 发布前待填；目前无真实 URL |
| 绑定该版本归档文件的 SHA-256 校验值及文件清单 | 发布前待填；目前无真实校验值 |
| 包内文件来源、许可声明及适用的对应源码/构建材料 | 发布前待填 |
| 外部依赖说明、干净环境部署和真实串流验收记录 | 发布前待填 |

待真实发布记录齐备后，先核对版本、许可与校验值，再将该版本解包到新的独立目录，并把目录作为 `-RuntimeBundleDir` 传给预检、作为 `-HelperSourceDir` 传给源码 CLI。元数据预检不会代替归档校验或来源审核，也不会自动下载或解包。缺少真实发布信息时，应停在源码测试阶段。

NVIDIA 组件树由使用者单独合法准备，不随独立运行时包自动取得授权。不要从当前机器的系统安装目录猜测路径，也不要复制私人证书、密钥或凭据。公开契约见 [runtime-bundle-contract.md](runtime-bundle-contract.md)；文件名和组件目录的依据为 `src/GsRuntime/GsRuntime.psm1` 的公开布局。以下示例假定你已按上述要求取得两类依赖：

```powershell
$runtime = 'D:\Gs Inputs\Runtime Bundle'
$components = 'D:\Gs Inputs\Components'
$r = & $preflight -RepoRoot $repo -Mode Source `
    -RuntimeBundleDir $runtime -ComponentSourceDir $components
$r | ConvertTo-Json -Depth 8
if (-not $r.Success) { throw 'External prerequisites failed. Stop before deployment.' }
```

这里检查 runtime 目录下的 11 个公开 helper 文件名，以及 `NvStreamerBusHook.dll`、`GsStreamGuard.dll`。组件树检查如下固定路径；不会递归扫描或计算外部内容的哈希：

```text
Components/
  NvContainer/NvContainer.exe
  GSRoot/LocalSystem/NvMessageBusBroadcast.dll.disabled
  GSRoot/LocalSystem/
  GSRoot/NetworkService/
  NvStreamSrv/Plugins/SSAU/
```

即使全部文件存在，预检仍不会验证二进制格式、签名、版本、来源、许可证、helper 所需的 Python/其他依赖或内部配置。请取得供应方的依赖与运行说明；不得以空文件补齐要求。缺少完整、合法的 runtime 时，**到此停止**。

## 3. 从源码部署、检查和启停

源码入口是 `<仓库>\product\gs-product.ps1`，模块在 `<仓库>\src`。已安装产品通常使用入口旁的 `Modules` 和 `bin`，这些默认值不适用于干净源码克隆，因此从源码调用时必须显式传 `-ModuleRoot` 和 `-HelperSourceDir`。

部署目标必须与源码、外部 helper 和组件来源分离。`InstallDir`、`StateDir`、`LogDir` 三者必须互不相同且互不嵌套；`ComponentSourceDir` 与这三个目录也不能相同或嵌套。示例只定义路径，不创建、不部署：

```powershell
$cli = Join-Path $repo 'product\gs-product.ps1'
$instance = @{
    ModuleRoot = Join-Path $repo 'src'
    HelperSourceDir = $runtime
    ComponentSourceDir = $components
    InstallDir = 'D:\Gs Instance\Install'
    StateDir = 'D:\Gs Instance\State'
    LogDir = 'D:\Gs Instance\Logs'
    SupervisorTaskName = ''
}
$instance.CatalogPath = Join-Path $instance.StateDir 'component-catalog.json'
```

这里的 `HelperSourceDir` 是原始外部包来源，**不是已部署的 runtime 路径**。`Start` 实际执行 `StateDir\runtime\bin` 下的已部署 helper。`InstallDir` 是组件部署目标，不能设置为仓库的 `product` 或 `src`。

`Get-RuntimeLayout` 在未传 `ComponentSourceDir` 且 `StateDir\runtime-config.json` 存在时会读取持久化布局。因此本页始终显式传四个布局路径，避免无意选择旧实例。切勿将本例路径替换为生产实例后直接试启动。

以下是供拥有合法兼容依赖的使用者逐段执行的首次部署流程，无需先安装 MSI 或 WiX。普通权限完成前面的预检后，按 [operator-guide.md](operator-guide.md) 在管理员 Windows PowerShell 5.1 中部署和启停；若换了终端，重新定义 `$repo`、`$preflight`、`$runtime`、`$components`、`$cli` 和 `$instance`。新源码版本的真实 Windows VM 安装/升级/卸载验收尚未完成，公开 runtime 包也尚未发布，这些步骤不能当作已完成的发布验收记录。

`SupervisorTaskName = ''` 用于本页这个从未注册自启的新实例：`Stop` 会跳过计划任务调用。`Install` 本身不创建自启任务，也不启动串流。不要用这组参数管理已有自启任务的实例，否则无法暂停其 supervisor；已有实例的维护参照操作指南。

先定义统一的结果检查函数。产品 helper 可能在结果之前输出文本，不能直接把整个输出数组的 `.Success` 当成执行结果。下面选择最后一个带 `Success` 的对象；没有结果、结果失败或调用抛出异常都会终止当前代码块。出现错误后不要继续执行下一段。

```powershell
$ErrorActionPreference = 'Stop'
function Invoke-GsCheckedAction {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('CreateCatalog', 'Install', 'Check', 'Start', 'Status', 'Stop')]
        [string]$Action,
        [Parameter(Mandatory = $true)][hashtable]$Parameters
    )
    $output = @(& $cli -Action $Action @Parameters -ErrorAction Stop)
    $result = $output | Where-Object {
        $null -ne $_ -and $_ -is [pscustomobject] -and
        $null -ne $_.PSObject.Properties['Success']
    } | Select-Object -Last 1
    if ($null -eq $result) { throw "$Action returned no structured result." }
    $result | ConvertTo-Json -Depth 8 | Write-Host
    if ($result.Success -isnot [bool] -or -not $result.Success) {
        throw "$Action failed. Inspect Errors and stop before the next step."
    }
    return $result
}
```

重新运行只读依赖预检。以下部署操作会创建目录、写文件；这里要求三个目标目录尚不存在，避免 `Install` 内部的覆盖行为影响已有实例。确认布局与来源互不嵌套后再执行：

```powershell
$r = & $preflight -RepoRoot $repo -Mode Source `
    -RuntimeBundleDir $runtime -ComponentSourceDir $components
if (-not $r.Success) {
    $r | ConvertTo-Json -Depth 8
    throw 'Prerequisites failed. Do not deploy.'
}
foreach ($target in @($instance.InstallDir, $instance.StateDir, $instance.LogDir)) {
    if (Test-Path -LiteralPath $target) {
        throw "First-use target already exists: $target. Choose a new instance layout."
    }
}
New-Item -ItemType Directory -Path $instance.StateDir -ErrorAction Stop | Out-Null
$catalog = Invoke-GsCheckedAction -Action CreateCatalog -Parameters $instance
```

`CreateCatalog` 读取用户提供的组件并计算所需文件的 SHA-256，写入显式指定的 `CatalogPath`。其父目录必须事先存在，因此先创建 `StateDir`。随后将同一个 catalog 传给 `Install`：

```powershell
$installed = Invoke-GsCheckedAction -Action Install -Parameters $instance
```

当前源码的 `Install` 会复制组件到 `InstallDir`，创建运行布局所需目录（含 `LogDir`），部署外部 helper，并写入 `StateDir\runtime-config.json` 和 `StateDir\runtime-plan.json`。它会读取 helper 并按布局改写公开约定的旧路径；这不属于元数据预检。当前实现不设置目录 ACL、不创建服务或计划任务，也不调用启动 helper。不要把部署成功解释为权限安全验收通过。

本页显式传了 `CatalogPath`，所以必须先成功执行 `CreateCatalog`；`Install` 不会为这个显式路径自动生成 catalog。仅当省略 `CatalogPath` 时，当前 `Install` 才会自动生成默认的 `StateDir\component-catalog.json`。任何一步失败都可能留下部分文件，应检查 `Errors` 后处理，不要盲目覆盖重试或启动。

部署后执行产品只读 `Check`。它会检查布局、读取已部署 helper 检测遗留路径，并因传入了 `CatalogPath` 而重新校验组件计划；它比前面的元数据预检检查更多，但仍不证明端到端串流或安全验收通过。

```powershell
$checked = Invoke-GsCheckedAction -Action Check -Parameters $instance
```

确认 `Check` 成功后，**由操作者明确执行**下面的启动段。它会执行实际 runtime 并产生进程、网络等运行副作用，具体行为以该版本的供应方说明为准；不要将本段接入预检或单元测试。启动前再次检查，以免在中途改了路径或文件后使用旧结果：

```powershell
$checked = Invoke-GsCheckedAction -Action Check -Parameters $instance
$started = Invoke-GsCheckedAction -Action Start -Parameters $instance
```

启动成功返回只说明启动 helper 成功结束。等待 runtime 完成初始化后，可另行读取状态；没有状态文件或状态读取失败时，函数会报告错误，不能当作已就绪：

```powershell
$status = Invoke-GsCheckedAction -Action Status -Parameters $instance
```

状态对象的实际内容及客户端连接结果仍须检查。客户端配对、首次连接和结束串流见 [操作指南的客户端连接](operator-guide.md#客户端连接)。完成使用后，先在客户端正常退出串流，再明确执行停止：

```powershell
$stopped = Invoke-GsCheckedAction -Action Stop -Parameters $instance
```

`Stop` 会写暂停标志并执行已部署停止 helper；本例因 `SupervisorTaskName` 为空而不调用计划任务。停止失败时检查返回的 `Errors`，不要认为进程已停。再次启动前应注意操作指南中的暂停标志说明；当前源码的显式 `Start` 只有在运行时启动成功后才清除新旧两处暂停标志；失败会恢复调用前已有的标志内容。清理或恢复失败会返回结构化错误，详见 [操作指南](operator-guide.md#开机自启与暂停标志)。

源码的新诊断、托盘、生命周期和安装行为与历史 `0.2.0` 已安装产品不完全一致。版本字符串相同也不表示内容相同；记录源码提交、runtime 版本及构建产物。历史实机串流记录只证明当时的组合，不证明未发布的新源码 MSI 已完成安装/升级/卸载验收。

## 4. 仅准备构建 MSI 时才需要 WiX

从 WiX 的正规渠道自行准备 WiX Toolset 3.14，明确指定包含 `heat.exe`、`candle.exe`、`light.exe` 的目录。预检不搜索本机工具目录，也不执行工具以验证版本。

```powershell
$wix = 'D:\Build Tools\WiX 3.14\bin'
$r = & $preflight -RepoRoot $repo -Mode Build `
    -RuntimeBundleDir $runtime -WixDir $wix
$r | ConvertTo-Json -Depth 8
if (-not $r.Success) { throw 'Build prerequisites failed. Stop before building.' }
```

`Build` 必须提供 runtime 和 WiX；组件树不在 MSI 构建输入中，所以没有 `-ComponentSourceDir` 也可以通过构建预检。若显式提供组件路径，则仍检查其结构。

构建本身会写入 `artifacts` 并执行 WiX，不属于只读检查。选择了待构建的真实版本号、确认合法依赖以及干净的构建环境后，操作者可按 [build-tools.md](build-tools.md) 构建；务必显式传入 `-RuntimeBundleDir` 和 `-WixDir`，不要依赖其默认本机路径。构建成功不表示 MSI 可安全安装。新源码产物的干净 VM 安装、升级、卸载及真实客户端验收仍须单独完成。
