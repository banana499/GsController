# GsController Release Manifest and Rollback

Last updated: 2026-11-07. Build default: 0.2.0; no new public release is declared.

This manifest records what a release consists of, what has been verified, and
how to go back to the previous version. Values that are unknown are marked
`not recorded` instead of guessed. This file is part of the repository, so it
must be updated in the same commit that changes a hash.

## Hash provenance

The hashes that count for a release are the SHA-256 values of the files as
**staged by `scripts\build-product.ps1` into `artifacts\product-stage`**.
That staging (every top-level `product\` file, the root `LICENSE` and
`LICENSING.md`, the six files under `Modules\<module>\`, and the runtime
bundle under `bin\`) is exactly what
the WiX harvest turns into the MSI, so a staged hash is what the installed
files contain on disk. They document the reviewed state, not a published
release.

Line endings change hashes. This repository's stored blobs and main checkout
use LF, while worktrees on this machine are checked out with
`core.autocrlf=true` and hold the same files as CRLF, so the same source
file hashes differently between an LF checkout and a CRLF worktree.
**Only hashes taken from the staged build of the release commit count.** A
hash captured from a worktree file is at best a review artifact and is
labeled as such in the table below.

Regenerate every hash from the release commit before publishing.
Preferred, after a build: hash every staged file, top level plus
`Modules\*\*`. The runtime bundle files under `artifacts\product-stage\bin`
are excluded: the bundle is opaque and is recorded separately (see the
runtime bundle section below).

```powershell
# Run from the repository root at the release commit, after
# scripts\build-product.ps1 has run.
$stage = 'artifacts\product-stage'
$staged = @(
    Get-ChildItem -LiteralPath $stage -File
    Get-ChildItem -LiteralPath (Join-Path $stage 'Modules') -Recurse -File
)
foreach ($f in ($staged | Sort-Object -Property FullName)) {
    $h = Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256
    '{0}  {1}' -f $h.Hash.ToLowerInvariant(), $f.FullName
}
```

Fallback without a build: hash every top-level `product\` file plus the six
module files under `src\`. `Get-ChildItem` picks up newly added product
files automatically. Hashes from this fallback still depend on the
checkout's line endings, so treat them as provisional.

```powershell
# Run from the repository root at the release commit.
$files = @(
    Get-ChildItem -LiteralPath 'product' -File
    Get-Item -LiteralPath 'LICENSE', 'LICENSING.md'
    foreach ($module in @('GsControl', 'GsLifecycle', 'GsRuntime')) {
        Get-ChildItem -LiteralPath (Join-Path 'src' $module) -File |
            Where-Object { $_.Extension -in @('.psd1', '.psm1') }
    }
)
foreach ($f in ($files | Sort-Object -Property FullName)) {
    $h = Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256
    '{0}  {1}' -f $h.Hash.ToLowerInvariant(), $f.FullName
}
```

## Product components

| Component | Path | Version | SHA-256 |
|---|---|---|---|
| Product CLI | `product\gs-product.ps1` | n/a (single script) | `1d1a62e73f46139d61dcca4155c3dacaef7d8151a197f097a755335d4edb4caf` |
| Tray host | `product\gs-tray.ps1` | n/a (single script) | `7f9718732fca2bcd2e2065b85cd3c1fd63f56bd356bfc4d63f14da82ebd928da` |
| Tray model | `product\gs-tray-model.ps1` | n/a (single script) | `c6825ea36158f3e1ceee2bab26294591f167235b10a680d78751e2531b5d0b7a` |
| Tray launcher | `product\gs-tray.vbs` | n/a (launcher) | `2f3674739be2f665f4140ac5c21f78a283f38255227184b98bf20ba35dda5543` |
| GsControl manifest | `src\GsControl\GsControl.psd1` | 0.1.0 | `0897953c89fd4ecda9e01d6bb03a381b53642fddfcebe8c0eead9d187d5ab168` |
| GsControl module | `src\GsControl\GsControl.psm1` | 0.1.0 | `c5395d1458185b40bd369bfa1f1df9319a6e6c78779c7df409958d6cb7054b9f` |
| GsLifecycle manifest | `src\GsLifecycle\GsLifecycle.psd1` | 0.2.0 | `4a5c6524433986c0e88e59b1ebac04ef9d9c26b5b2e87bdd9da131b2f4c5cdbc` |
| GsLifecycle module | `src\GsLifecycle\GsLifecycle.psm1` | 0.2.0 | `ca1e2a75d14a8bd315590b8ea5213036d56f885fb2bd03e3a6f47033244bbd7f` |
| GsRuntime manifest | `src\GsRuntime\GsRuntime.psd1` | 0.1.0 | `4691ea0380d013abe94f18e7cb5cb622ef2022081d0f9a61378a88bbed6b9dec` |
| GsRuntime module | `src\GsRuntime\GsRuntime.psm1` | 0.1.0 | `b076a26d2bd6d99f37c4969dfe5d5cd758a6fd5b3160cd40d1bb1f190b696c98` |
| Diagnostics | `product\gs-diagnose.ps1` | n/a (single script) | `c91a2af75a7e143e10d5abb3903b4a2f5354f8bc9d71aa85b319ec9a515ada5a` |
| Support bundle | `product\gs-support.ps1` | n/a (single script) | `437ba36140bd2386c8d6800cff8a5dc2d0dd57d04049926389ba7a78a17a6c13` |
| Tray strings (zh-CN) | `product\gs-tray-strings.zh-CN.json` | n/a (data) | `5907bb99e130c39c08e688e756760066eec9df2663ddca5775a21a7770815102` |

The hashes above use CRLF product/module bytes. The CLI and GsRuntime hashes
were refreshed on 2026-11-07 for the pause contract, normalizing LF source
lines to CRLF; the tray-model hash was refreshed on 2026-11-01 for the
stopping-timeout fix. These are review values, not release hashes: regenerate
every hash from the staged build of the release commit before publishing.
The new GsSecurity module and Get-GsAclPlan tool are repository-only and are
not included in this MSI component table or the build's three-module list.
License text hashes must be recorded from the actual staged copies too.

Module versions are the `ModuleVersion` values in each `.psd1`. The build
(`scripts\build-product.ps1`) stages every top-level file in `product\`, so
`gs-diagnose.ps1`, `gs-support.ps1` and the tray files (`gs-tray.ps1`,
`gs-tray-model.ps1`, `gs-tray.vbs`, `gs-tray-strings.zh-CN.json`) ship
next to `gs-product.ps1` in the MSI.

To confirm what is actually installed on a host, run
`gs-product.ps1 -Action Diagnose`: its `product` section reports the
installed entry hash, module hashes and versions, and (unless skipped) the
`DisplayVersion` of the installed MSI read from the registry.

**Component status semantics.** In the diagnostics report, a component is
reported as `running` when a process with the recorded PID exists. Component
identity is not verified (the process could be anything), and PIDs can be
reused, so `running: true` does not prove the recorded component is the one
running.

## MSI

| Item | Value |
|---|---|
| Version | 0.2.0 (from `README.md`; build default in `scripts\build-product.ps1`) |
| File | `artifacts\msi\GsController-0.2.0.msi` |
| SHA-256 | not recorded |
| Signature | unsigned; see `docs\msi-signing.md` |

Fill the hash after the release build, before archiving:

```powershell
Get-FileHash -LiteralPath .\artifacts\msi\GsController-0.2.0.msi -Algorithm SHA256
```

The MSI's product code is generated per build (`Product Id="*"` in
`installer\GsController.wxs`); record it with the hash if you want
`msiexec /x <product-code>` to work unattended.

## Runtime bundle

| Item | Value |
|---|---|
| Version | not recorded |
| SHA-256 (deployed files) | not recorded |

The runtime bundle is an opaque, separately supplied dependency; this
repository does not contain or inspect it. Fill both values from the host
after deployment, using the diagnostics report:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File gs-diagnose.ps1 -AsJson
```

The `runtimeBundle` section lists every deployed file with size, timestamp
and SHA-256. Keep the bundle that matches a release together with the MSI in
the release archive.

## Verified client

From `docs\acceptance-evidence.md` (2026-10-31):

| Item | Value |
|---|---|
| Client | MacBook Pro (Mac16,8, Apple M4 Pro, 48 GB) |
| Client OS | macOS 15.7.9 (24G830) |
| Moonlight | 6.2.0 |
| Network | Wi-Fi (en0) |
| Passed | 4K60, 1080p60, 720p60 (HEVC, SDR, stereo, no gamepad) |
| Host GPU / driver | not recorded |

Compatibility beyond that baseline (HDR, AV1, 7.1, Xbox / DS4 / generic
gamepad) is defined in `docs\compatibility-test-plan.md`; as of 2026-10-31
every case there is `not covered`. A release whose manifest claims
compatibility must update that matrix first.

## Rollback

`installer\GsController.wxs` uses WiX `MajorUpgrade` with
`DowngradeErrorMessage="A newer version is already installed."`, so an older
MSI cannot be installed over a newer one. Rolling back therefore means
removing the current version first.

1. **Stop** the product so the private stack is down and state files are
   released:
   ```powershell
   & 'C:\Program Files\Local Development\GsController\gs-product.ps1' -Action Stop
   & 'C:\Program Files\Local Development\GsController\gs-product.ps1' -Action Status
   ```
   Before uninstalling, run `-Action PrepareUninstall` with the instance's
   actual paths and verify that the supervisor task is absent. On older
   versions without that action, use `Stop` followed by `UnregisterAutostart`.
   Only a confirmed not-found result establishes task absence; access or RPC
   errors do not. Current MSI source adds best-effort cleanup for default
   layouts, but real uninstall is still unverified. See
   [msi-uninstall-cleanup.md](msi-uninstall-cleanup.md).
2. **Uninstall** the current version:
   ```powershell
   msiexec /x <product-code-or-path-to-current-msi> /qn
   ```
   The installed product code can be read from the
   `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` key whose
   `DisplayName` is `GsController` (the diagnostics report prints it in
   `product.installedMsi.registryKey`).
3. **Install** the previous MSI from the release archive:
   ```powershell
   msiexec /i C:\path\to\release-archive\GsController-<previous-version>.msi /qn
   ```
4. **Redeploy and verify**, as in `README.md`:
   ```powershell
   & 'C:\Program Files\Local Development\GsController\gs-product.ps1' -Action Install -ComponentSourceDir 'D:\path\to\components'
   & 'C:\Program Files\Local Development\GsController\gs-product.ps1' -Action Check
   & 'C:\Program Files\Local Development\GsController\gs-product.ps1' -Action Start
   & 'C:\Program Files\Local Development\GsController\gs-product.ps1' -Action Status
   ```
   Confirm the client can start a session afterwards.

### State and log directories under ProgramData

The MSI installs only `ProgramFiles64Folder\Local Development\GsController`
(see the `Directory` fragment in `installer\GsController.wxs`). It defines no
components, `RemoveFile` or `RemoveFolder` entries for
`%ProgramData%\Local Development\GsController` (StateDir) or
`%ProgramData%\Local Development\GsControllerLogs` (LogDir); those trees are
created by the product at Install/Start time, not by the MSI. As far as the
`.wxs` proves, an uninstall should leave them in place. This is **unverified
on a real uninstall**; check both directories after step 2 before relying on
it. If a rollback must also clear state, back the directories up before
touching them.

### Release archive

Keep, for every published version: the MSI, the matching runtime bundle, and
their SHA-256 hashes as recorded above. Without the previous MSI (or a
recorded product code plus the bundle) a rollback is not possible.
