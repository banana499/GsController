# Product Roadmap and Remaining Work

Last updated: 2026-11-07

Source integration and the state-file / tray-timeout fixes are on
`hardening/p0` (committed through `0e545f9`). The new product is not yet
deployed on the validation host. The completed baseline below includes
older releases; it does not certify installation, upgrade or uninstall of
the current hardening build.

## 当前开源准备增量（2026-11-07）

已加入 GPL-3.0-only 许可、贡献和安全报告说明、Windows CI 配置、首次使用依赖预检与快速开始。构建前检查在清理目录前拒绝非法版本、路径重叠及危险 reparse，并将产品许可文件随 MSI 打包。MSI 普通完整卸载接线、双位置暂停契约和 ADB 路径移植性已进入当前工作区；只读 ACL 策略仍不执行权限修改，也不接入 Install。

这些是尚未发布的源码改动。公开运行时包的版本/下载/许可来源、自备组件获取说明、最终产物和新版本的真实安装生命周期及客户端验收仍需完成；详见 [发布验收](release-readiness.md)。下面 Completed 表记录历史版本的完成情况，不能替代本次发布验证。

## Completed

| Area | Status | Evidence |
|---|---|---|
| Product modules and CLI | Done | Stage 1–5 tests |
| MSI build/install/uninstall | Done | 41 product tests |
| Real component deployment + Check | Done | 18 tests |
| Product start / Desktop list | Done | 8/8 tests |
| Autostart supervisor | Done | 11 tests |
| Same-host 1080p/720p/4K | Done | Earlier evidence |
| Second physical client 4K60/1080p/720p | Done | `docs/acceptance-evidence.md` |
| Graceful client quit lifecycle | Done | Host returns AVAILABLE |
| Secure public-certificate pairing | Done | Client cert imported into TrustedPeople |

## Remaining work

### P0 — Release readiness

1. **Integrate the latest runtime bundle fix into the supported release**
   - Status (2026-11-01): the runtime bundle on the validation host was
     fixed again on 2026-10-31/11-01 (nvstreamer injection timing, process
     ownership checks, atomic state-file writes). The product layer now
     requires the two new helpers (`gs_process_identity.ps1`,
     `GsStreamGuard.dll`; `tests/Invoke-RuntimeBundleTests.ps1`). Not done:
     an MSI rebuilt with the real bundle and a clean install.
   - The runtime bundle currently deployed on the validation host contains a
     compatibility fix that is not yet part of the release bundle.
   - Acceptance: publish the matching runtime version and lawful dependency
     instructions, rebuild the MSI, complete the public clean-environment
     procedure in [release-readiness.md](release-readiness.md), and repeat one
     4K60 client session. Historical private validation scripts are not a
     reproducible prerequisite for users of this source tree.
   - Owner note: the runtime bundle is opaque; do not inspect or modify its
     implementation in this repository.

2. **MSI code signing**
   - Sign `GsController-<version>.msi` and the product entry with an
     Authenticode certificate.
   - Acceptance: `signtool verify /pa /v` passes and the publisher identity is
     valid on a clean machine. Record SmartScreen behavior separately:
     signing alone does not guarantee that reputation warnings disappear.

3. **Tray/status UI**
   - Status (2026-11-01): implemented (`product/gs-tray*.ps1`, `gs-tray.vbs`,
     `docs/tray-ui.md`): six states, Chinese UI text from
     `gs-tray-strings.zh-CN.json`, Recover and support-bundle menu items,
     stream balloons. `tests/Invoke-TrayUiTests.ps1` covers the model and
     a hidden smoke run. Open: an interactive smoke test on the host.
   - Minimal tray icon with states: Stopped / Starting / Ready / Streaming /
     Error; menu actions Start, Stop, Status, Open logs, Exit.
   - Acceptance: UI reflects `status.json` within 2 seconds; no console window;
     Start/Stop call the existing product CLI.

4. **Secure pairing wizard**
   - Product-level UI/CLI that explains the PIN flow, imports only the client
     public certificate, verifies the thumbprint, and offers rollback.
   - Acceptance: a new client can pair without manual registry edits; private
     keys are never read, copied, or logged.

### P1 — Compatibility and stability

5. **HDR, AV1, 7.1 surround, gamepad**
   - Status (2026-11-01): plan only. `docs/compatibility-test-plan.md` has
     the CMP-* desktop cases and ten ATV-* Android TV box cases;
     `client/New-CompatibilityEvidence.ps1` creates evidence folders and
     `client/Get-TvBoxCapabilities.ps1` records box capabilities read-only.
     No case has been run.
   - Test matrix: SDR/HDR, H.264/HEVC/AV1, stereo/5.1/7.1, Xbox/DS4/generic
     gamepad.
   - Acceptance: each combination either works with evidence or is explicitly
     documented as unsupported.

6. **Long-run stability and reconnect**
   - Status (2026-11-01): partly done. `tools/gs-soak-monitor.ps1` and
     `docs/stability-test-plan.md` exist. Evidence on the validation host:
     a 30-minute 4K60 HEVC Desktop session to the Android TV box (180
     samples, stable PIDs, QoS 100, 59.8 FPS, streamer private memory
     +0.28 MB/h, host idle 3-4 s after quit); supervisor killed mid-cycle
     10 times without damage; 6 Stop/Start cycles through the CLI. Not
     covered: network interruption, client sleep/wake, display mode
     change, 60-minute sessions.
   - 30–60 minute sessions at 4K60; network interruption; client sleep/wake;
     host display mode change.
   - Acceptance: no orphaned streamer process, host returns to AVAILABLE after
     quit/disconnect, no unbounded memory growth.

7. **GPU / driver matrix**
   - Validate at least one Ada and one older NVIDIA GPU; at least two driver
     branches.
   - Acceptance: documented compatibility table with component hashes and test
     results.

8. **Supervisor vs manual Start race**
   - Status (2026-11-01): partly addressed. Manual Start/Stop/Recover/
     PrepareUninstall hold a per-StateDir mutex; Stop pauses the supervisor
     first. The runtime supervisor now has its own cycle mutex and only
     stops processes it can prove it owns. Stage 8 repeated 10 times has
     not been run.
   - Observed: a manual Start can race the 5-minute supervisor cycle; the
     caller may time out even though the stack is ready.
   - Acceptance: a start lock or supervisor pause during manual start; Stage 8
     repeated 10 times without timeout.

### P2 — Product polish

9. **Installer UX and prerequisites**
   - Detect WiX/runtime bundle, disk space, existing install, and conflicting
     services; offer repair/uninstall/rollback.
   - Acceptance: clean install, upgrade, repair, and uninstall on a fresh VM.

10. **Clean-repo test automation**
    - Status (2026-11-01): done. `tests/Invoke-All.ps1` runs every suite in
      its own process with a timeout; integration suites are skipped unless
      `-IncludeIntegration` is given in an elevated session. Presence of a
      runtime bundle does not enable integration tests automatically.
    - Acceptance: `tests/Invoke-All.ps1` returns a clear pass/skip/fail summary.

11. **Documentation and localization**
    - Status (2026-11-01): mostly done. Chinese operator guide,
      troubleshooting, file and log locations, threat model and stability
      plan; Chinese tray UI. The CLI stays English by decision. Open: a new
      operator walking through install-to-stream with only the docs.
    - Operator guide, troubleshooting, log locations, recovery steps.
    - Acceptance: a new operator can install, start, pair, stream, and stop
      using only the docs.

12. **Security review**
    - Status (2026-11-01): partly done. Threat model in
      `docs/threat-model.md`; diagnostics and support bundle redact and
      rescan for secrets; the `hygiene` section flags writable script
      folders, pause flags and orphaned tasks; `PrepareUninstall` removes
      the supervisor task. Update (2026-11-06): MSI full-uninstall cleanup
      is wired in source and passed 18 offline fixture checks plus two
      independent reviews; real VM uninstall remains unverified. The product
      does not yet apply folder ACLs. See [MSI cleanup](msi-uninstall-cleanup.md).
    - Review file/pipe permissions, token handling, certificate import, log
      redaction, and uninstall cleanup.
    - Acceptance: no private key material in logs or repo; least-privilege
      service accounts; documented threat model.

## Explicit non-goals

- Redistributing NVIDIA binaries or certificates.
- Modifying an existing NVIDIA App installation, services, or registry state.
- Supporting unsupported GPU/driver combinations without evidence.
