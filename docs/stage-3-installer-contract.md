# 阶段 3：合成 MSI 安装契约

## 范围

只验证我们自己编写的 `GsControllerSample` 示例程序，不包含或替换任何第三方组件，不安装服务，不修改其他软件配置。它是后续应用安装器的事务模板，不是串流产品本身。

## 标识与目录

- UpgradeCode：`7E2B57E4-77C2-4B65-AE8A-1EE44A2E90A7`，跨小版本不变。
- ProductCode：每次构建生成；升级靠 `MajorUpgrade Schedule="afterInstallInitialize"`。
- 默认程序目录：`C:\Program Files\Local Development\GsControllerSample`。
- MSI 公共目录标识 `INSTALLFOLDER` 可由命令行指定，例如 `INSTALLFOLDER="C:\GsControllerSampleCustom"`。测试包含非默认目录安装与卸载。
- 数据目录：`%ProgramData%\Local Development\GsControllerSample`，不由 MSI 管理，卸载保留。
- MSI 只管理 `Get-SampleInfo.ps1`，没有递归删除操作。

## 构建

见 `build-tools.md`。`scripts/build.ps1 -Version <x.y.z>` 使用 WiX 3.14 生成 x64 MSI，同步更新示例命令报告的版本。构建输入变更后须重新构建，MSI 不提交 git。

## 验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Stage3Tests.ps1
```

真实执行：
1. 清理同名测试应用的既有安装，只读其卸载注册表并调用 `msiexec /x <ProductCode>`。
2. 安装 0.1.0，验证命令输出；重复安装 0.1.0；卸载后验证非默认 `INSTALLFOLDER`。
3. 以公开 `FAILTEST=1` 触发新版本中的测试专用 CustomAction 失败，要求非零退出且 0.1.0 仍可执行。
4. 正常升级 0.1.1，验证版本。
5. 按包内 ProductCode 卸载，检查程序文件移除、用户数据保留。

2026-10-30 实测：`install-0.1.0=0`、`reinstall-0.1.0=0`、注入回滚 `1603` 后 0.1.0 可运行、`upgrade-0.1.1=0`、`uninstall=0`，总入口退出码 0。日志写入 `artifacts/stage3/`，不入库。

## 限制

- 没有产品 UI、签名、自动更新、服务安装、第三方组件导入或运行中迁移。
- `FAILTEST` 只用于此合成示例，不应进入正式产品。
- 测试仅覆盖 x64 单用户本机 MSI，不覆盖多用户、网络位置、组策略、离线镜像。
- PowerShell `Start-Process -ArgumentList` 对 GUID 应使用单个字符串或带引号的数组元素；不能直接把 `{GUID}` 交给 MSYS 参数转换。
