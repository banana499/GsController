# MSI and Product Code Signing

Last updated: 2026-10-31

Roadmap item: P0 #2 in `docs/product-roadmap.md`.

## 1. Status

- **Not signed.** `GsController-<version>.msi` and every file inside it are
  unsigned.
- **No certificate has been supplied.** Nothing in this repository signs,
  timestamps, or verifies anything yet.
- This document is the plan. The commands below use placeholders
  (`<thumbprint>`, `<timestamp-url>`, `<version>`) and have not been run
  against a real certificate. No signing output is reproduced here.

Tooling present on the build host (checked by file existence only):

| Tool | Path |
|---|---|
| SignTool x64 (SDK 10.0.22621.0, file version 10.0.22621.1778) | `C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe` |
| SignTool x86 | `C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x86\signtool.exe` |
| `Set-AuthenticodeSignature` / `Get-AuthenticodeSignature` | Windows PowerShell 5.1, built in |

## 2. Required certificate

**Type.** An Authenticode code-signing certificate from a publicly trusted CA,
with the Code Signing EKU `1.3.6.1.5.5.7.3.3`. SignTool requires this EKU by
default. A self-signed certificate is only suitable for local tests: Microsoft
documents that SmartScreen treats it the same as no signature, and scripts
signed with it do not run on other machines under `AllSigned`.

**OV vs EV.** Microsoft's current SmartScreen guidance:

- Files signed with a valid OV or EV certificate show the verified publisher
  name, but can still be flagged as "unrecognized" until reputation
  accumulates.
- EV no longer bypasses SmartScreen or grants reputation on day one. Microsoft
  states EV may matter for enterprise procurement, but not for SmartScreen.
- Reputation is tied to the file hash and the signing identity. Keeping the
  same certificate across releases lets reputation carry over.

The practical consequence for the roadmap acceptance: signing removes
"Unknown publisher", but it does not guarantee that the first downloads show no
SmartScreen prompt at all.

**Key storage.** Since 2023-06-01 the CA/Browser Forum Code Signing Baseline
Requirements (§6.2.7.4) require CAs to ensure the subscriber's private key is
generated, stored and used in a suitable hardware crypto module, for OV as
well as EV. DigiCert describes this as FIPS 140-2 Level 2, Common Criteria
EAL 4+, or equivalent, and no longer supports browser-generated keys. In
practice the options are:

- a hardware token (USB) supplied by the CA or an existing supported token;
- an HSM operated by the publisher;
- a cloud signing service. One example is Microsoft Azure **Artifact Signing**
  (formerly Trusted Signing), which keeps keys in FIPS 140-3 Level 3 HSMs,
  requires identity validation, issues short-lived certificates (3 days), and
  plugs into SignTool through a `/dlib` client library. It is mentioned here as
  an option, not a recommendation.

A publicly trusted code-signing certificate therefore normally does not come as
an exportable `.pfx`. Plan for signing by thumbprint from the certificate store
(token or HSM via its CSP/KSP) or through a cloud signing client.

**Who supplies it.** The user/operator. The build never creates, imports or
exports certificates.

**Never commit it.** `.gitignore` already excludes `*.pfx`, `*.p12`, `*.cer`,
`*.crt`, `*.key` and `*.pem` (and `*.json`, which also covers a cloud-signing
`metadata.json`). Do not put PFX passwords or token PINs on command lines, in
scripts, or in logs.

## 3. What to sign, and in what order

| Order | Files | When | Tool |
|---|---|---|---|
| 1 | `gs-tray.exe` (planned; when present) | right after `scripts/build-tray.ps1` produces it, before `heat.exe` | `signtool sign` |
| 2 | Staged product scripts: `gs-product.ps1`, `gs-tray-action.ps1` (planned; when present), `Modules\*\*.psm1`, `Modules\*\*.psd1` | after staging in `artifacts\product-stage`, before `heat.exe` | `Set-AuthenticodeSignature` |
| 3 | `artifacts\msi\GsController-<version>.msi` | after `light.exe`, last | `signtool sign` |

**Not signed by the product build:** everything under the stage's `bin\`. These
are runtime bundle files, copied verbatim from `-RuntimeBundleDir`. They are
opaque third-party/operator content. If they need signatures, the operator
signs them separately, before handing the bundle to the build.

**Sign the staged copies, not `src/` or `product/`.** A signature is a comment
block appended to the script text. Signing the sources would put signature
blocks into the repository, and any later edit would invalidate them.

**Why the order matters.**

- `light.exe` reads the staged files when it links. It records their sizes
  (and hashes for unversioned files such as `.ps1`) and compresses them into
  the embedded cabinet (`MediaTemplate EmbedCab="yes"`). A file signed after
  that point is not the file inside the MSI. Signing before `heat.exe` is the
  simplest rule that guarantees the harvested, linked and installed bytes are
  the signed bytes.
- The MSI signature covers the whole package, including the embedded cabinet.
  Any change to the MSI after signing invalidates it. Signing the MSI must be
  the last step.
- `build-product.ps1` deletes and recreates `artifacts\product-stage` on every
  run. Steps 1 and 2 must therefore run inside the same build run, between
  staging and `heat.exe`.

Microsoft's guidance for a fully covered installation also requires internal
(or signed external) cabinets and only custom actions stored within the
package. The current `installer/GsController.wxs` embeds its cabinet and
defines no custom actions.

## 4. Commands (placeholders only)

```powershell
$signtool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe'
$tsUrl    = '<timestamp-url>'   # RFC 3161 URL published by the CA or signing service
$thumb    = '<thumbprint>'      # SHA-1 thumbprint of the code-signing certificate
$stage    = '<repo>\artifacts\product-stage'
```

### 4.1 `gs-tray.exe` (planned; when present)

```powershell
& $signtool sign /fd SHA256 /tr $tsUrl /td SHA256 /sha1 $thumb /d "GsController Tray" "$stage\gs-tray.exe"
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed: $LASTEXITCODE" }
```

- `/fd SHA256` and `/td SHA256` are mandatory in current SDK SignTool builds.
  Microsoft recommends SHA256.
- `/tr` + `/td` request an RFC 3161 timestamp. Do not combine `/tr` with the
  legacy `/t`.
- SignTool documents a failed timestamp request as a warning, and exit code
  `2` as "completed with warnings". The `-ne 0` check treats that as failure.
  This was inferred from the documentation, not tested.
- Add `/sm` if the certificate is in the machine store rather than the user
  store.
- Cloud signing (Artifact Signing) replaces `/sha1 $thumb` with
  `/dlib "<path>\Azure.CodeSigning.Dlib.dll" /dmdf "<path>\metadata.json"`.

### 4.2 Product PowerShell files

```powershell
$cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumb"
$files = @(Join-Path $stage 'gs-product.ps1')
$tray  = Join-Path $stage 'gs-tray-action.ps1'           # planned; when present
if (Test-Path -LiteralPath $tray) { $files += $tray }
$files += @(Get-ChildItem -LiteralPath (Join-Path $stage 'Modules') -Recurse -File |
            Where-Object { $_.Extension -in '.psm1', '.psd1' }).FullName

foreach ($f in $files) {
    $sig = Set-AuthenticodeSignature -LiteralPath $f -Certificate $cert `
        -HashAlgorithm SHA256 -TimestampServer $tsUrl -IncludeChain NotRoot
    if ($sig.Status -ne 'Valid') { throw "Signing failed: $f ($($sig.StatusMessage))" }
    if ($null -eq $sig.TimeStamperCertificate) { throw "No timestamp: $f" }
}
```

- `-HashAlgorithm` defaults to SHA1 in Windows PowerShell 5.1. Always pass
  `SHA256`.
- `-TimestampServer` must be an `http://` URL.
- `bin\` is deliberately not in the list.
- PowerShell before 7.2 requires signed scripts to be ASCII or UTF-8 without
  BOM. The current product scripts and modules are pure ASCII. Keep them that
  way.
- With a cloud signing service the private key is not in the local store, so
  `Set-AuthenticodeSignature` cannot use it directly. Use the service's
  documented PowerShell integration instead (Artifact Signing publishes an
  `ArtifactSigning` module).

### 4.3 MSI (after `light.exe`)

```powershell
$msi = '<repo>\artifacts\msi\GsController-<version>.msi'
& $signtool sign /fd SHA256 /tr $tsUrl /td SHA256 /sha1 $thumb /d "GsController" $msi
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed: $LASTEXITCODE" }
```

`/d` sets the signed-content description. It is commonly reported that the
UAC prompt shows this value as the program name for an MSI, and a temporary
file name without it. That behavior is not confirmed in Microsoft
documentation.

### 4.4 Verify

```powershell
foreach ($f in @($msi, "$stage\gs-tray.exe")) {
    & $signtool verify /pa /v /tw $f
    if ($LASTEXITCODE -ne 0) { throw "signtool verify failed ($LASTEXITCODE): $f" }
}
```

- `/pa` uses the Default Authentication Verification Policy. Without it,
  SignTool uses the Windows Driver Verification Policy, which is the wrong
  policy for ordinary Authenticode-signed applications.
- `/tw` warns if a signature has no timestamp. Accept only exit code `0`
  (`1` = failed, `2` = completed with warnings).
- `verify` checks the primary signature only. Add `/all` if a file ever carries
  more than one signature.

PowerShell check, usable for the staged scripts, the MSI, the EXE, or the
installed directory:

```powershell
Get-ChildItem -LiteralPath '<dir>' -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.exe', '.msi' } |
    ForEach-Object { Get-AuthenticodeSignature -LiteralPath $_.FullName } |
    Select-Object Path, Status,
        @{ n = 'Signer';      e = { $_.SignerCertificate.Subject } },
        @{ n = 'Thumbprint';  e = { $_.SignerCertificate.Thumbprint } },
        @{ n = 'Timestamped'; e = { $null -ne $_.TimeStamperCertificate } }
```

Required per file: `Status` is `Valid`, `Thumbprint` equals the expected
certificate, `Timestamped` is `True`. `Valid` alone does not identify the
publisher. Other values mean: `NotSigned`, `HashMismatch` (modified after
signing), `NotTrusted` (chain does not reach a trusted root), `UnknownError`.

## 5. Proposed build integration (not implemented)

Implement this only after the user supplies a certificate, and test it against
that certificate. Until then the build stays unsigned and says so.

Preferred shape: optional parameters on `scripts/build-product.ps1`, because
signing must happen between staging and `heat.exe` inside one run.

```text
-SignThumbprint <sha1>   enables signing; absent = current unsigned behavior
-TimestampUrl   <url>    required when -SignThumbprint is given
-SignToolPath   <path>   optional; default = SDK x64 signtool.exe
```

Behavior:

1. Without `-SignThumbprint`: build exactly as today and print
   `MSI is unsigned`.
2. With `-SignThumbprint` but no `-TimestampUrl`: fail before staging.
3. Resolve the certificate by exact thumbprint. Fail if it is missing,
   expired, lacks EKU `1.3.6.1.5.5.7.3.3`, or has no usable private key.
4. After staging: sign `gs-tray.exe` (if present) and the product scripts
   (section 4.1 and 4.2). Verify each. Any failure throws.
5. Run `heat`/`candle`/`light` to a temporary MSI name.
6. Sign the MSI, run `signtool verify /pa /v /tw`, and only on exit code `0`
   rename it to `GsController-<version>.msi`. A failed signing run must not
   leave an unsigned file under the release name (fail closed).
7. Never read or log PFX passwords or token PINs. Never touch `bin\`.

Alternative: a separate `scripts/sign-product.ps1` with `-Phase Stage` and
`-Phase Msi`, called by `build-product.ps1` at the two points above. A
standalone script run after the build could only sign the MSI, not the files
inside it.

Cloud signing would replace `-SignThumbprint` with dlib and metadata paths. The
parameter design should leave room for that, but the choice depends on which
route the user takes.

Tests to add at that point: the unsigned build is unchanged; a signed build
passes section 4.4; altering one staged byte after signing makes the build
fail.

Also consider aligning `Manufacturer="Local Development"` in
`installer/GsController.wxs` with the certificate's organization name.
SmartScreen and UAC show the certificate subject as the publisher;
Programs and Features shows `Manufacturer`. Mismatched names look suspicious.

## 6. Acceptance checklist

- [ ] `signtool verify /pa /v` exits `0` for `GsController-<version>.msi`.
- [ ] `signtool verify /pa /v` exits `0` for `gs-tray.exe` (once it exists).
- [ ] A timestamp is present on every signature (`/tw` gives no warning;
      `TimeStamperCertificate` is not null).
- [ ] After a clean install, `Get-AuthenticodeSignature` reports `Valid` with
      the expected thumbprint for every product script in
      `C:\Program Files\Local Development\GsController`: `gs-product.ps1`,
      `gs-tray-action.ps1` (when present), and `Modules\*\*.psm1|psd1`.
- [ ] Clean-VM download test. Download the MSI through a browser so it carries
      Mark-of-the-Web (check with `Get-Item <msi> -Stream Zone.Identifier`;
      `curl.exe` and `Invoke-WebRequest` may not set it). Opening it shows the
      publisher name, not "Unknown publisher", in SmartScreen and in the UAC
      prompt. An "unrecognized app" SmartScreen prompt may still appear until
      reputation builds; with OV or EV this is expected and does not fail the
      check.
- [ ] On a test machine that trusts the publisher (publisher certificate in
      Trusted Publishers, or "Always run" chosen once):
      `powershell.exe -NoProfile -ExecutionPolicy AllSigned -File "C:\Program Files\Local Development\GsController\gs-product.ps1" -Action Status`
      runs without a signature or execution-policy error. `Status` loads all
      three module manifests and modules, so this exercises every product
      script except the tray action. A Group Policy execution policy
      overrides `-ExecutionPolicy`; run the check on a machine without one.

## 7. Not covered / risks

- **No certificate.** Nothing can be signed or verified until the user
  supplies one. All of sections 4 to 6 are untested.
- **SmartScreen reputation** builds over time and download volume. Microsoft
  gives no threshold ("several weeks and hundreds of clean installs" is their
  rough estimate). Changing certificates resets the publisher signal. On
  Windows 11, Smart App Control may block files without positive reputation.
- **Timestamp server availability.** SignTool documents that a failed
  timestamp request only produces a warning; the file is still signed. The
  build must check for the timestamp and treat its absence as failure. Without a timestamp the signature becomes
  invalid when the certificate expires; for 3-day cloud certificates this is
  critical.
- **Any file change requires re-signing.** A rebuilt EXE, any edited script, or
  any post-processing of the MSI (for example an administrative install, which
  Microsoft documents removes the signature) invalidates the signature.
- **Signed scripts break if their text changes after signing.** Line-ending
  conversion, re-encoding, or a build step that rewrites a staged script all
  cause `HashMismatch`. The current build copies product scripts unchanged.
- **Runtime helper scripts are rewritten at install.** `Install-GsRuntimeBundle`
  in `src/GsRuntime/GsRuntime.psm1` replaces legacy paths in the bundle's
  helper scripts as it copies them into the runtime directory. Any signature
  the operator puts on those scripts will not survive deployment. `Start`,
  `Stop` and the supervisor therefore cannot run under `AllSigned` today; this
  is outside the product-signing scope.
- **Signing does not enforce execution policy.** The autostart task already
  launches the supervisor with `-ExecutionPolicy Bypass`. For paths launched
  that way, signatures give tamper evidence via `Get-AuthenticodeSignature`,
  not enforcement.
- **Unconfirmed points.** Whether Windows PowerShell 5.1's
  `-TimestampServer` uses RFC 3161 or the legacy Authenticode timestamp
  protocol is not documented; verify the result with `TimeStamperCertificate`.
  The exact §6.2.7.4 wording of the CA/B Forum requirements was not retrieved
  (only its summary table); the FIPS/Common Criteria levels above come from
  DigiCert. Artifact Signing eligibility by country or organization type was
  not checked.

## Sources

- Microsoft, SignTool: <https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool>
- Microsoft, Use SignTool to sign a file: <https://learn.microsoft.com/en-us/windows/win32/seccrypto/using-signtool-to-sign-a-file>
- Microsoft, Set-AuthenticodeSignature (PowerShell 5.1): <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-authenticodesignature?view=powershell-5.1>
- Microsoft, about_Signing (PowerShell 5.1): <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_signing?view=powershell-5.1>
- Microsoft, about_Execution_Policies (PowerShell 5.1): <https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1>
- Microsoft, Signature class: <https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.signature>
- Microsoft, SignatureStatus enum: <https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.signaturestatus>
- Microsoft, SmartScreen reputation for Windows app developers: <https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation>
- Microsoft, Digital Signatures and Windows Installer: <https://learn.microsoft.com/en-us/windows/win32/msi/digital-signatures-and-windows-installer>
- Microsoft, Authoring a Fully Verified Signed Installation: <https://learn.microsoft.com/en-us/windows/win32/msi/authoring-a-fully-verified-signed-installation>
- Microsoft, What is Artifact Signing: <https://learn.microsoft.com/en-us/azure/artifact-signing/overview>
- Microsoft, Set up signing integrations to use Artifact Signing: <https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-signing-integrations>
- CA/Browser Forum, Code Signing Baseline Requirements: <https://cabforum.org/working-groups/code-signing/requirements/>
- DigiCert, New private key storage requirement for standard code signing certificates: <https://knowledge.digicert.com/general-information/new-private-key-storage-requirement-for-standard-code-signing-certificates-november-2022>
