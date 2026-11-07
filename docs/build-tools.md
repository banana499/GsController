# Build Tools

Validated on Windows 11 x64 with WiX Toolset 3.14.

## Required tools

| Tool | Purpose |
|---|---|
| PowerShell 5.1 | Build and test scripts |
| WiX 3.14 `heat.exe` | Harvest staged product files |
| WiX 3.14 `candle.exe` | Compile WiX source |
| WiX 3.14 `light.exe` | Link the MSI |

The historical local default is `C:\Tools\GsBuild\wix314`; new checkouts should
pass their actual WiX directory with `-WixDir`. Download WiX from its official
project distribution and verify its provenance before executing it. The source
repository does not install build tools automatically.

Start with [quickstart.md](quickstart.md) for the metadata-only prerequisites
check. Runtime version, provenance and licensing are separate release requirements;
see [release-readiness.md](release-readiness.md).

## Build

### Sunshine profile

This profile packages the GsController guide and local read-only checks. Sunshine
is obtained and installed separately from its official release; no private runtime
bundle or NVIDIA component tree is needed to build this profile.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-product.ps1 `
  -Version 0.3.0 `
  -RuntimeProfile Sunshine `
  -WixDir 'D:\Build Tools\WiX 3.14\bin'
```

The output is `GsController-Sunshine-<version>.msi`. Do not supply
`-RuntimeBundleDir` with this profile. The installed Start Menu entry opens the
Sunshine guide through the generated `gs-install-profile.json`. This MSI excludes
the Legacy uninstall cleanup actions; Sunshine and its pairing state remain
managed by its own installer. See [sunshine-quickstart.md](sunshine-quickstart.md).

### Legacy profile (default)

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-product.ps1 `
  -Version 0.2.0 `
  -RuntimeBundleDir 'D:\path\to\prebuilt-runtime-bundle' `
  -WixDir 'D:\Build Tools\WiX 3.14\bin'
```

The script first checks MSI version bounds and source/work/output path overlaps
before it creates or removes build directories. Use `-PreflightOnly` with the
same explicit inputs to check them without staging or invoking WiX; see
[build-preflight.md](build-preflight.md). These checks do not establish runtime
compatibility or replace installation acceptance.

The script:

1. stages `src/GsControl`, `src/GsLifecycle`, `src/GsRuntime`;
2. for Legacy, checks all 13 public runtime filenames and copies the prebuilt bundle into `bin/`; Sunshine omits this input and directory;
3. copies every top-level file from `product/`, including CLI, tray, local console, diagnostics and support tools, plus root `LICENSE` and `LICENSING.md`; the license files and all seven console files are required before cleanup;
4. generates `gs-install-profile.json`, then runs `heat.exe` with the controlled Start Menu shortcut transform, `candle.exe`, and `light.exe`;
5. writes `artifacts/msi/GsController-<version>.msi` for Legacy or `GsController-Sunshine-<version>.msi` for Sunshine.

The required console files are `gs-console.ps1`, `gs-console-action.ps1`,
`gs-console.vbs`, `gs-console.html`, `gs-console.css`, `gs-console.js` and
`gs-console-strings.zh-CN.json`. The existing `gs-tray-model.ps1` is also
required because the console loads it during startup. A missing file (or a
directory in its place) rejects both a full build and `-PreflightOnly` before
existing build directories are touched. The metadata-only Build prerequisite
check requires the same console inputs; Source mode keeps its CLI-only scope. The installed entry is `gs-console.vbs` next to `gs-product.ps1`;
the root `Start-GsController.cmd` is only the source-checkout entry.

Sunshine additionally requires `gs-sunshine.ps1`, `gs-sunshine.html`,
`gs-sunshine.js` and `gs-sunshine.css`. The generated profile cannot be replaced
by a same-named product source file.

`tests/Invoke-ConsolePackagingTests.ps1` uses synthetic inputs and fake WiX tools
under TEMP to check early rejection and staging. Its fake MSI is not an
installable artifact. `tests/Invoke-ConsoleShortcutMsiTests.ps1` separately uses
real WiX and read-only MSI database queries to check both profiles, the advertised
Start Menu shortcut and removal of Legacy cleanup from the Sunshine profile.
Neither suite runs an installer or verifies a real installed shortcut.

The repository does not compile runtime helpers or inspect their source.
`-sreg` is used during harvesting so DLLs are not treated as SelfReg.

## Sample MSI

`scripts/build.ps1` builds the small installer sample from `installer/Product.wxs`
and `installer/sample/`. It is useful for WiX smoke tests and does not include
the product modules.
