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
2. copies the prebuilt runtime bundle into `bin/`;
3. copies every top-level file from `product/`, including CLI, tray, diagnostics and support tools, plus root `LICENSE` and `LICENSING.md` (both required before cleanup);
4. runs `heat.exe`, `candle.exe`, and `light.exe`;
5. writes `artifacts/msi/GsController-<version>.msi`.

The repository does not compile runtime helpers or inspect their source.
`-sreg` is used during harvesting so DLLs are not treated as SelfReg.

## Sample MSI

`scripts/build.ps1` builds the small installer sample from `installer/Product.wxs`
and `installer/sample/`. It is useful for WiX smoke tests and does not include
the product modules.
