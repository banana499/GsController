# Runtime Bundle Contract

The runtime bundle is a separately supplied, opaque dependency. This document
defines the interface the product layer relies on; it does not describe the
bundle's implementation.

## Inputs

- Directory: any path passed as `-RuntimeBundleDir` to
  `scripts/build-product.ps1`.
- The directory must contain at least one non-documentation file.
- The build copies every non-documentation file into the MSI `bin/` directory.

## Required behavior

The bundle must provide:

1. **Start/stop helpers** used by `gs-product.ps1` to start and stop the
   streaming stack.
2. **Supervisor helper** used by the autostart task.
3. **Streamer helper DLL** copied into `bin/`.
4. Any runtime configuration files required by those helpers.

The authoritative list of helper filenames is in
`src/GsRuntime/GsRuntime.psm1` (`$script:BundleHelpers`). Keep the bundle and
that list in sync when releasing a new runtime version.

## Build-time validation

`scripts/build-product.ps1` checks:

- the bundle directory exists;
- it contains at least one non-documentation file;
- WiX tools are present;
- product modules, product entry, build helper and the root `LICENSE` / `LICENSING.md` inputs exist;
- the version fits MSI ProductVersion limits;
- source, staging and output paths pass the overlap and reparse checks described
  in [build-preflight.md](build-preflight.md).

`-PreflightOnly` performs the input checks and exits before staging or WiX
execution. It does not inspect helper contents or validate runtime behavior.

It does **not** validate helper behavior. The historical Stage 7/8 validation
scripts are not included in this public source tree and are not a prerequisite
that a new user can run from this clone. Complete the published clean-environment
procedure in [release-readiness.md](release-readiness.md), using the matching
runtime supplier's deployment and behavioral acceptance instructions.

## Versioning

Record the runtime version in the independent runtime package's public release
manifest. No `runtime-bundle/manifest.example.json` is supplied by this repository.
The product MSI version and runtime version are independent; record both, the
supported version range, the real download URL, archive SHA-256, file list and
licensing/source materials in the release notes. See [LICENSING.md](../LICENSING.md).
The public runtime release is still pending; a fixture bundle is not a release.

## Security

- Do not commit the bundle to this repository.
- Do not include private keys, tokens, certificates, logs, or dumps.
- The bundle is executed with the privileges required by the product; review
  its permissions before release.
