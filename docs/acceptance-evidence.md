# Acceptance Evidence — Second Physical Client

Date: 2026-10-31

These are historical results from the original validation host and network.
The evidence directories are local to the original machine and are not
provided with the public repository; nothing here has been re-verified on a
new environment.

## Client

| Item | Value |
|---|---|
| Device | MacBook Pro (Mac16,8, Apple M4 Pro, 48 GB) |
| OS | macOS 15.7.9 (24G830) |
| Moonlight | 6.2.0 |
| Network | Wi-Fi (en0) |
| Host | `<host-name>` / `<host-ip>` (fill in; the original values are withheld from the public repository) |
| Codec | HEVC |

## Results

| Resolution | Launch | Video stream | Client receive/decode FPS | Render FPS | Network latency | Network drop | Host after quit |
|---|---|---|---|---|---|---|---|
| 4K | 200 / 3840x2160@60 | 3840x2160x60 | 60.20 / 60.20 | 59.88 | 15 ms | 0.10% | AVAILABLE |
| 1080p | 200 / 1920x1080@60 | 1920x1080x60 | 60.48 / 60.48 | 58.01 | 44 ms | 0.00% | AVAILABLE |
| 720p | 200 / 1280x720@60 | 1280x720x60 | 62.64 / 62.64 | 56.67 | 42 ms | 0.00% | AVAILABLE |

4K60 host Qos (from the host streamer log):

- Frame Number 301 → 3001
- Client Q-score 100
- RTD 0 ms
- Average game FPS 59.90–60.04
- Actual bitrate 40.0 Mbps
- Private-bus client joined successfully

720p note: the handshake in that run was slow; the `Video stream is` line
appeared 17 seconds into a 20-second window. It is recorded as a pass for
compatibility but should be re-run with a longer window for a latency baseline.

## Lifecycle

- A forced client kill leaves the host streamer process resident and the host
  in a busy state. This is a test-harness artifact, not a product defect.
- A normal `Moonlight quit <host>` returns the host to AVAILABLE within
  10 seconds and the client exits by itself.
- The client test harness now calls `quit` before any forced termination.

## Evidence locations

The directories lived on the original author's NAS share and local disk and
are not distributed with the public repository. The directory names are kept
below for the record only; fill in your own roots when reproducing.

- 4K: `<nas-evidence-root>\moonlight\mac-4k-evidence-20261031_080138`
- 1080p/720p: `<nas-evidence-root>\moonlight\mac-matrix-evidence-20261031_080715`
- Local host copy: `C:\gs-evidence\mac-4k-20261031_080138`,
  `C:\gs-evidence\mac-matrix-20261031_080715`
- Screenshot: `mac-4k-evidence-20261031_080138\overlay.png`
- Client logs: `moonlight-runtime.log`, `key-lines.txt`,
  `laptop-evidence.json`

## Not covered

- HDR, AV1, 7.1 surround, gamepad. Cases, procedures and pass criteria are in
  `docs/compatibility-test-plan.md`; all cases are `not covered` until run.
- 30–60 minute stability and reconnect
- Other GPUs and driver branches
- Wired-vs-Wi-Fi comparison on the same client
