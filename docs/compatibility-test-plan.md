# Compatibility Test Plan: HDR, AV1, Surround, Gamepad

Date: 2026-10-31
Roadmap: `docs/product-roadmap.md`, item 5.

This plan defines the cases, procedures, pass criteria and evidence for the
compatibility round. No case has been run. Every row starts as `not covered`
and changes only when evidence exists.

## Scope

- Video: SDR/HDR, H.264/HEVC/AV1.
- Audio: stereo, 5.1, 7.1 surround.
- Input: Xbox, DualShock 4 (DS4) and generic gamepads, including disconnect
  and reconnect during a session.

Out of scope: long-run stability, network interruption, other GPUs and
drivers (roadmap items 6 and 7), YUV 4:4:4, multiple simultaneous
controllers, and DS4 touchpad, motion and lightbar features (recorded as
observations only).

## Baseline

The baseline is the configuration that already passed in
`docs/acceptance-evidence.md`:

| Item | Value |
|---|---|
| Client | MacBook Pro (Mac16,8, Apple M4 Pro), macOS 15.7.9 |
| Moonlight | 6.2.0 |
| Network | Wi-Fi |
| Host | `<host-name>` / `<host-ip>` (fill in; the original validation host's name and LAN address are withheld from the public repository), app `Desktop` |
| Stream | 3840x2160, 60 FPS, 50 Mbps, HEVC, SDR, stereo, no gamepad |

## Variation strategy

Each case changes one dimension from the baseline. A few combinations are
added where the dimensions interact.

The full product (SDR/HDR x 3 codecs x 3 audio layouts x 4 input options) is
72 sessions. Most of those cells test nothing new. In the GameStream protocol,
video, audio and input travel on separate streams, so audio channel layout
and gamepad input do not depend on the codec. The real interactions are:

- HDR depends on the codec. Moonlight 6.2.0 offers HDR only with 10-bit HEVC
  or AV1; it refuses HDR with H.264 ("HDR is not supported using the H.264
  codec."). So HDR is tested with HEVC and with AV1, and H.264 + HDR has no
  case.
- The heaviest video setting may starve audio or input. One combination case
  (HEVC HDR + 7.1 + Xbox controller) covers this after the single-dimension
  cases pass.

Every case passes each dimension flag explicitly (`--video-codec`, `--hdr` or
`--no-hdr`, `--no-yuv444`, `--audio-config`), because options left out on the
Moonlight command line fall back to the client's saved GUI preferences.

## Statuses

| Status | Meaning |
|---|---|
| `pass` | All pass criteria met with the row's settings. Evidence path is required and points to the case evidence directory. |
| `fail` | Prerequisites met, case run, at least one pass criterion not met. Record what failed in `Reason`; add the evidence path. |
| `unsupported` | Cannot work for a documented capability reason on the client, host or protocol side, for example the client display is not HDR-capable, the client decoder lacks AV1, or the host GPU lacks AV1 encode. `Reason` is required and names the source (Moonlight warning text, setting screenshot, vendor specification). |
| `not covered` | Not tested. Initial state of every row. |

A silent fallback is never a pass. Moonlight falls back to HEVC when forced
AV1 is unavailable, and to SDR when HDR is unavailable; the stream then works
but the dimension under test was not exercised.

## Matrix

| ID | Dimension | Settings | Prerequisites | Procedure | Pass criteria | Evidence required | Status | Evidence path | Reason |
|---|---|---|---|---|---|---|---|---|---|
| CMP-BASE-01 | Baseline | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec HEVC --no-hdr --no-yuv444 --audio-config stereo` | Baseline client and host; product Ready | P-COMMON | Common criteria; `format 0x100`; overlay codec `HEVC` | Common set | not covered |  |  |
| CMP-H264-01 | H.264 | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec H.264 --no-hdr --no-yuv444 --audio-config stereo` | As baseline | P-COMMON, P-VIDEO | Common criteria; `format 0x1`; overlay codec `H.264` | Common set | not covered |  |  |
| CMP-HDR-01 | HDR | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec HEVC --hdr --no-yuv444 --audio-config stereo` | Client HDR/EDR output in Moonlight (Q1); host streamed display in Windows HDR (Q2) | P-COMMON, P-VIDEO | Common criteria; `format 0x200`; overlay codec `HEVC 10-bit HDR`; no HDR launch warning; HDR visual check | Common set; HDR test pattern note in record | not covered |  |  |
| CMP-AV1-01 | AV1 | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec AV1 --no-hdr --no-yuv444 --audio-config stereo` | Client AV1 hardware decode (Q3); host AV1 encode (Q4) | P-COMMON, P-VIDEO | Common criteria; `format 0x1000`; overlay codec `AV1`; no AV1 launch warning | Common set | not covered |  |  |
| CMP-AV1-02 | AV1+HDR | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec AV1 --hdr --no-yuv444 --audio-config stereo` | Q1, Q2, Q3, Q4 | P-COMMON, P-VIDEO | Common criteria; `format 0x2000`; overlay codec `AV1 10-bit HDR`; no AV1 or HDR launch warning; HDR visual check | Common set; HDR test pattern note in record | not covered |  |  |
| CMP-AUD-01 | 5.1 | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec HEVC --no-hdr --no-yuv444 --audio-config 5.1-surround` | Client output device with at least 6 channels (Q5); host surround path (Q6) | P-COMMON, P-AUDIO | Common criteria; `Audio channel count: 6`; no surround launch warning; each of 6 channels heard at its own speaker | Common set; `client-audio-device.png`; channel table in record | not covered |  |  |
| CMP-AUD-02 | 7.1 | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec HEVC --no-hdr --no-yuv444 --audio-config 7.1-surround` | Client output device exposing 8 channels (Q5); host surround path (Q6) | P-COMMON, P-AUDIO | Common criteria; `Audio channel count: 8`; no surround launch warning; each of 8 channels heard at its own speaker | Common set; `client-audio-device.png`; channel table in record | not covered |  |  |
| CMP-PAD-01 | Gamepad-Xbox | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec HEVC --no-hdr --no-yuv444 --audio-config stereo` | Physical Xbox controller, USB or Bluetooth (Q7); host check is manual (Q8) | P-COMMON, P-GAMEPAD | Common criteria; client detects controller; all inputs reach host; disconnect and reconnect recover without relaunch | Common set; `host-joycpl.png`; gamepad checklist in record | not covered |  |  |
| CMP-PAD-02 | Gamepad-DS4 | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec HEVC --no-hdr --no-yuv444 --audio-config stereo` | Physical DualShock 4, USB or Bluetooth (Q7); host check is manual (Q8) | P-COMMON, P-GAMEPAD | Common criteria; client detects controller; all inputs reach host; disconnect and reconnect recover without relaunch | Common set; `host-joycpl.png`; gamepad checklist in record | not covered |  |  |
| CMP-PAD-03 | Gamepad-Generic | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec HEVC --no-hdr --no-yuv444 --audio-config stereo` | Physical non-Xbox, non-Sony gamepad, model named in record (Q7); host check is manual (Q8) | P-COMMON, P-GAMEPAD | Common criteria; client detects controller with a mapping; all inputs reach host; disconnect and reconnect recover without relaunch | Common set; `host-joycpl.png`; gamepad checklist in record | not covered |  |  |
| CMP-CMB-01 | HDR+7.1+Gamepad-Xbox | `--4K --fps 60 --bitrate 50000 --display-mode fullscreen --performance-overlay --video-codec HEVC --hdr --no-yuv444 --audio-config 7.1-surround` | HDR-01, AUD-02 and PAD-01 rows at `pass` first | P-COMMON, P-VIDEO, P-AUDIO, P-GAMEPAD | All criteria of the HDR, 7.1 and Xbox gamepad cases in one session | Union of those cases | not covered |  |  |

To update a row: set `Status`, put the case evidence directory in
`Evidence path`, and fill `Reason` for `fail` and `unsupported`.

## Prerequisites to verify

None of these has been checked. Each must be answered before the matching
case is run; a negative answer makes the case `unsupported` with that answer
as the reason.

| # | Question | How to verify | Needs |
|---|---|---|---|
| Q1 | Does Moonlight 6.2.0 render HDR (EDR) on the MacBook Pro built-in display? | Moonlight's HDR option is available; no HDR launch warning; overlay shows `10-bit HDR`. Record the macOS display preset. | Client |
| Q2 | Can the host's streamed display run in Windows HDR mode? | Windows Settings > Display > Use HDR for the streamed display; record its state, and restore it after the test. Overlay `10-bit SDR` with `--hdr` means the host display is not in HDR. | Host operator |
| Q3 | Does Moonlight on the M4 Pro decode AV1 in hardware? | No "force AV1 without GPU support" software-decoding warning; `format 0x1000`. | Client |
| Q4 | Do the host GPU, driver and streamer encode AV1? | Record GPU model and driver as reported by the operator. NVIDIA added AV1 encode with the Ada generation (RTX 40 series); whether the host streamer offers it is to verify. Moonlight shows "Your host software or GPU doesn't support encoding AV1." when it does not. | Host operator |
| Q5 | Does the client have an output device with 6 or 8 channels? | macOS Audio MIDI Setup: output format channel count and Configure Speakers layout; set it as the default output. The built-in speakers are to verify and probably expose 2 channels; a multichannel USB interface or HDMI receiver is likely needed. | User hardware |
| Q6 | Does the host deliver 6 or 8 distinct channels in the session? | Observable only through the per-channel listening test in P-AUDIO. | Test run |
| Q7 | Which physical controllers are available? | Record model and connection (USB or Bluetooth) for Xbox, DS4 and one generic pad. | User hardware |
| Q8 | Host-side input check is manual. | Operator opens `joy.cpl` inside the streamed Desktop session (P-GAMEPAD). | Operator |

## Procedures

### P-COMMON: Common session procedure

Run for every case. Commands follow `docs/remote-client-test.md`.

1. Create the case evidence directory on a Windows machine with PowerShell
   5.1:
   ```powershell
   .\client\New-CompatibilityEvidence.ps1 -CaseId CMP-HDR-01 -EvidenceRoot 'C:\gs-evidence'
   ```
   It writes `record.md` with the row's settings and returns the directory.
2. Host: product Start, then save the product Status output to
   `host-status-before.txt` (`& $p -Action Status`).
3. Client: make sure no session is running (`Moonlight quit <host>`), then
   start the case:
   ```bash
   Moonlight stream <host-ip> "Desktop" <Settings from the matrix row>
   ```
4. Wait up to 30 seconds for the client log line `Video stream is`. The 720p
   acceptance run needed 17 seconds, so do not shorten this.
5. Screenshot any Moonlight launch warning (`launch-warning.png`) and copy its
   text into `record.md`.
6. Hold a 60-second steady window. At 30 seconds or later, screenshot the
   performance overlay (`overlay.png`).
7. Host: save the streamer Qos lines with the same filter as
   `docs/remote-client-test.md` section 3 to `host-qos.txt`. Collect no other
   host-side data.
8. Client: `Moonlight quit <host>`. Do not force-kill the client first; a
   forced kill leaves the host busy. Confirm Moonlight shows the host as
   available within 10 seconds, then save product Status to
   `host-status-after.txt`.
9. Copy the client log for the session to `moonlight-client.log` and extract
   the `Launch response`, `Video stream is`, `Audio channel`, `Gamepad` and
   warning lines to `key-lines.txt`. On macOS, release builds of Moonlight
   write `Moonlight-<unix time>.log` to the system temporary directory.
10. Fill `record.md` and update the matrix row.

Common pass criteria:

- `Launch response` contains `status_code="200"`.
- `Video stream is 3840x2160x60 (format 0x...)` appears within 30 seconds,
  with the format code the case expects.
- Overlay over the steady window: incoming and decoding frame rate at least
  57 FPS, rendering frame rate at least 55 FPS, frames dropped by the network
  at most 1%. The baseline measured 60.20 decode and 59.88 render at 4K.
- Host Qos `Frame Number` increases and `Avg Game FPS` stays at 57 or above.
- No disconnect during the window.
- Host available again within 10 seconds of quit; product Status after quit
  still reports the product as ready.

### P-VIDEO: Codec and HDR checks

Expected values with `--no-yuv444` (format codes from moonlight-common-c
`VIDEO_FORMAT_*`, overlay text from Moonlight 6.2.0):

| Codec flag | HDR flag | `Video stream is` format | Overlay `Codec:` |
|---|---|---|---|
| `H.264` | `--no-hdr` | `0x1` | `H.264` |
| `HEVC` | `--no-hdr` | `0x100` | `HEVC` |
| `HEVC` | `--hdr` | `0x200` | `HEVC 10-bit HDR` |
| `AV1` | `--no-hdr` | `0x1000` | `AV1` |
| `AV1` | `--hdr` | `0x2000` | `AV1 10-bit HDR` |

- A different format code than expected is a fallback: `fail`, or
  `unsupported` when a launch warning names the missing capability.
- Moonlight launch warnings that make a case `unsupported` (quote the text as
  the reason): "Your host software or GPU doesn't support encoding AV1.",
  "Using software decoding due to your selection to force AV1 without GPU
  support...", "This PC's GPU doesn't support 10-bit HEVC or AV1 decoding for
  HDR streaming.", "This PC's GPU doesn't support AV1 Main10 decoding for HDR
  streaming.", "Your host PC doesn't support HDR streaming.", "Your host PC and
  client PC don't support the same HDR video codecs."
- Overlay `10-bit SDR` with `--hdr` means the host display is not in HDR (Q2).
- HDR visual check: show an HDR test pattern or HDR video on the host desktop
  and record in `record.md` whether highlights look brighter than SDR white
  and colours are not washed out. macOS screenshots of EDR content may be tone
  mapped, so `overlay.png` is evidence of the codec line, not of brightness.

### P-AUDIO: Surround checks

1. Before launch, screenshot the client output device in Audio MIDI Setup
   showing its channel count and speaker layout (`client-audio-device.png`).
2. After launch, the client log shows `Audio channel count: 6` and
   `Audio channel mask: 3F` (5.1) or `Audio channel count: 8` and
   `Audio channel mask: 63F` (7.1). These lines confirm the requested layout
   only, not what reaches the speakers.
3. The launch warning "Your selected surround sound setting is not supported
   by the current audio device." makes the case `unsupported` (reason: client
   output device lacks the channels).
4. On the host, through the streamed Desktop, play a channel-identification
   clip that announces each channel name in turn (a standard 5.1/7.1 channel
   test file, or the Test button in the Windows Sound control panel speaker
   setup if the host endpoint offers the layout).
5. For each channel, record in the `record.md` table where it was heard.

Pass: every channel is heard only from its own speaker (LFE from the
subwoofer, or noted as low-frequency only), with no channel missing or
swapped. Audio/video sync is recorded as an observation.

### P-GAMEPAD: Controller checks

1. Connect the controller to the Mac before launch; record model and USB or
   Bluetooth. Keep Moonlight's gamepad settings at their defaults and record
   any change.
2. Client log shows `Gamepad 0 (player 1) is: <name> (VID/PID: ...)`. The
   launch warning "An attached gamepad has no mapping and won't be usable."
   makes the case `unsupported` (reason: no SDL mapping for that controller).
3. Host check (manual): inside the streamed Desktop, open `joy.cpl` (Win+R).
   A game controller is listed. In Properties, every face button, both
   shoulder buttons, both triggers (analog travel), both sticks (full range),
   the D-pad, Start and Back respond. Screenshot this on the client
   (`host-joycpl.png`). Xbox Game Bar (Win+G) is an optional second view.
   The host may present a different controller type than the physical one;
   the check is that input arrives, not the reported model.
4. Disconnect: unplug or power off the controller. The client log shows
   `Gamepad 0 is gone`; `joy.cpl` stops showing it within 5 seconds; the
   stream continues.
5. Reconnect: reconnect the controller. The client log shows a new
   `Gamepad ... is:` line; `joy.cpl` lists it and input responds within 10
   seconds, without relaunching the stream.
6. Avoid the Moonlight quit combo (Start + Select + L1 + R1); it ends the
   session.

Rumble and DS4 touchpad, motion and lightbar are observations, not pass
criteria.

## Evidence layout

Keep evidence outside the repository, under the same roots as
`docs/acceptance-evidence.md` (NAS share or `C:\gs-evidence`).
`client\New-CompatibilityEvidence.ps1` refuses an evidence root inside the
repository.

```text
<evidence root>\compat-<caseId>-<yyyyMMdd_HHmmss>\
  record.md                 created by New-CompatibilityEvidence.ps1, filled by the operator
  moonlight-client.log      client log for the session
  key-lines.txt             Launch response, Video stream is, Audio channel, Gamepad, warnings
  overlay.png               performance overlay with codec, FPS and drop rate
  launch-warning.png        only when Moonlight showed a warning
  host-status-before.txt    product Status output before launch
  host-status-after.txt     product Status output after quit
  host-qos.txt              host streamer Qos lines (remote-client-test.md section 3 filter)
  client-audio-device.png   audio cases only
  host-joycpl.png           gamepad cases only
```

No sensitive content is expected in these files. Never copy pairing data,
certificates, keys or the Moonlight settings store into evidence. The client
log can include the per-session `rikey` value in the logged launch request;
it is short-lived, but replace it with `<redacted>` in copies shared outside
the evidence root.

## Android TV client matrix

The second client is a wired Android TV box driven by the coordinator over
ADB. This section records the client class and the test rows only; device
identifiers (model, serial number, MAC/Bluetooth address, IP address, device
ID) are never written here or anywhere else in the repository. The examples
below use the documentation-range address `192.0.2.10:5555` and the
placeholder model name `TESTBOX`. Only the coordinator operates the box; the
automated tests never run `adb.exe` and never connect to the box.

Moonlight for Android has no command-line interface: every stream setting is
entered in its settings pages. That is why the rows below use a fixed `ui:`
settings format instead of the Moonlight CLI flags of the MacBook matrix, and
why the evidence is screenshots plus a filtered logcat extract.

### TV box baseline

| Item | Value |
|---|---|
| Client class | Wired Android TV box, Moonlight for Android 12.2, HDMI 2160p60 4:2:0 8-bit |
| Device | `TESTBOX` (placeholder; the real model and serial are never recorded) |
| Android version | 9 |
| Moonlight | 12.2 |
| Network | Wired Ethernet |
| Display | HDMI 3, 2160p60, YCbCr 4:2:0, 8-bit |
| Address used by the operator | `192.0.2.10:5555` (documentation-range example only) |
| Before every run | Read the HDMI output mode and the `frac_rate_policy` value (P-ANDROID step 3). `frac_rate_policy` can revert after a reboot, so it is read before every case and is never changed by a case run. |

### Matrix

| ID | Dimension | Settings | Prerequisites | Procedure | Pass criteria | Evidence required | Status | Evidence path | Reason |
|---|---|---|---|---|---|---|---|---|---|
| ATV-BASE-01 | Baseline | `ui: 4K; 60 FPS; 50 Mbps; codec HEVC; HDR off; audio stereo; overlay on` | `TESTBOX` baseline and host; product Ready; box paired | P-ANDROID | P-COMMON thresholds (incoming and decoding at least 57 FPS, rendering at least 55 FPS, network drops at most 1%); overlay `Decoder:` line confirms HEVC | P-ANDROID set | not covered |  | Judged per probe evidence |
| ATV-H264-01 | H.264 | `ui: 4K; 60 FPS; 50 Mbps; codec H.264; HDR off; audio stereo; overlay on` | As ATV-BASE-01 | P-ANDROID | P-COMMON thresholds; overlay `Decoder:` line confirms H.264 | P-ANDROID set | not covered |  | Judged per probe evidence |
| ATV-1080-01 | 1080p | `ui: 1080p; 60 FPS; 20 Mbps; codec HEVC; HDR off; audio stereo; overlay on` | As ATV-BASE-01; HDMI output stays 2160p60, only Moonlight's stream resolution changes | P-ANDROID | P-COMMON thresholds; overlay `Video stream:` line confirms 1080p60 and `Decoder:` line confirms HEVC | P-ANDROID set | not covered |  | Judged per probe evidence |
| ATV-1080-02 | 1080p + H.264 | `ui: 1080p; 60 FPS; 20 Mbps; codec H.264; HDR off; audio stereo; overlay on` | As ATV-1080-01 | P-ANDROID | P-COMMON thresholds; overlay `Video stream:` line confirms 1080p60 and `Decoder:` line confirms H.264 | P-ANDROID set | not covered |  | Judged per probe evidence |
| ATV-HDR-01 | HDR | `ui: 4K; 60 FPS; 50 Mbps; codec HEVC; HDR on; audio stereo; overlay on` | Client HDR-capable output per probe evidence; host streamed display in Windows HDR | P-ANDROID | P-COMMON thresholds; overlay `Decoder:` line confirms 10-bit HDR | P-ANDROID set | not covered |  | Judged per probe evidence |
| ATV-AV1-01 | AV1 | `ui: 4K; 60 FPS; 50 Mbps; codec AV1; HDR off; audio stereo; overlay on` | Client AV1 hardware decode per probe evidence; host AV1 encode | P-ANDROID | P-COMMON thresholds; overlay `Decoder:` line confirms AV1 (a silent "Prefer AV1" fallback is never a pass) | P-ANDROID set | not covered |  | Judged per probe evidence |
| ATV-AV1-02 | AV1 + HDR | `ui: 4K; 60 FPS; 50 Mbps; codec AV1; HDR on; audio stereo; overlay on` | As ATV-AV1-01 plus the ATV-HDR-01 prerequisites | P-ANDROID | P-COMMON thresholds; overlay `Decoder:` line confirms AV1 10-bit HDR; no silent fallback | P-ANDROID set | not covered |  | Judged per probe evidence |
| ATV-AUD-01 | 5.1 | `ui: 4K; 60 FPS; 50 Mbps; codec HEVC; HDR off; audio 5.1; overlay on` | Box output path exposing 6 channels, per probe evidence | P-ANDROID | P-COMMON thresholds; 6-channel layout confirmed in the logcat extract and by the per-channel listening test | P-ANDROID set | not covered |  | Judged per probe evidence |
| ATV-AUD-02 | 7.1 | `ui: 4K; 60 FPS; 50 Mbps; codec HEVC; HDR off; audio 7.1; overlay on` | Box output path exposing 8 channels, per probe evidence | P-ANDROID | P-COMMON thresholds; 8-channel layout confirmed in the logcat extract and by the per-channel listening test | P-ANDROID set | not covered |  | Judged per probe evidence |
| ATV-PAD-01 | Gamepad-Generic | `ui: 4K; 60 FPS; 50 Mbps; codec HEVC; HDR off; audio stereo; overlay on` | Physical generic gamepad connected to the box; model named in the record when the pad is chosen (to be filled in) | P-ANDROID | P-COMMON thresholds; controller detected and inputs reach the host; disconnect and reconnect recover without relaunch | P-ANDROID set | not covered |  | Judged per probe evidence |

Every ATV row starts as `not covered`. The coordinator sets `unsupported`
(or `pass` / `fail`) only from real probe or run evidence, and then replaces
the `Reason` with that evidence. No row is pre-classified as `unsupported`
in this batch.

### P-ANDROID: Android TV box session procedure

Run for every ATV- case. Only the coordinator operates the box; this section
records the operator steps. Moonlight for Android has no command-line flags:
the row's settings are entered in its settings pages before the run, and the
settings screenshot is the evidence that they were applied.

1. Create the case evidence directory on a Windows machine with PowerShell
   5.1:
   ```powershell
   .\client\New-CompatibilityEvidence.ps1 -CaseId ATV-BASE-01 -EvidenceRoot 'C:\gs-evidence'
   ```
   It writes `record.md` with the row's settings and the P-ANDROID checks.
2. Host: product Start, then save the product Status output to
   `host-status-before.txt` (`& $p -Action Status`). This is P-COMMON
   step 2.
3. Before connecting: screenshot the Moonlight settings pages that carry the
   row's settings (`settings-page.png`), then read the box's current HDMI
   output mode and its `frac_rate_policy` value and record both in
   `record.md`. If the output mode is not 2160p60 4:2:0 8-bit, or
   `frac_rate_policy` is not the expected value, stop: a case run never
   changes box system settings.
4. Start the stream from the Moonlight Android UI with the row's settings.
5. Hold a 60-second steady window. At 30 seconds or later, capture the
   performance overlay with `adb exec-out screencap -p > overlay.png`.
   This is an operator step only; nothing in this repository runs adb.

   Binary-safe capture form (required for step 5): run the capture through
   cmd.exe so the PNG bytes reach disk unchanged:

   ```powershell
   cmd /c "adb exec-out screencap -p > overlay.png"
   ```

   Do not use the bare PowerShell redirection shown in step 5
   (`adb exec-out screencap -p > overlay.png`): under Windows PowerShell 5.1
   the `>` redirection re-encodes native command output as text, and screencap
   writes a binary PNG, so the file on disk would be corrupted. cmd.exe
   performs the redirection itself and writes the raw bytes. The same rule
   applies to any other binary capture on the box. This is an operator step
   only; nothing in this repository runs adb.
6. Extract only the `com.limelight` lines from the session's logcat into
   `logcat-limelight.txt`. The full logcat is never copied into evidence.
   The `Launch response` line confirms the launch; the decoder lines
   corroborate the overlay `Decoder:` line.
7. Host: save the streamer Qos lines with the same filter as
   `docs/remote-client-test.md` section 3 to `host-qos.txt`. This is
   P-COMMON step 7.
8. Client: quit the stream normally from the Moonlight UI. Do not force-stop
   the app first; a forced kill leaves the host busy. Confirm the host shows
   as available within 10 seconds, then save product Status to
   `host-status-after.txt`. This is P-COMMON step 8.
9. Fill `record.md` and update the matrix row.

Overlay fields, read in Moonlight Android's original wording from
`overlay.png`:

| Overlay field | Pass criterion |
|---|---|
| `Video stream:` | matches the row's resolution and FPS |
| `Decoder:` | names the row's codec; a pass requires this confirmation |
| `Incoming frame rate from network:` | at least 57 FPS |
| `Rendering frame rate:` | at least 55 FPS |
| `Frames dropped by your network connection:` | at most 1% |
| `Average network latency:` | recorded as an observation |
| `Average decoding time:` | recorded as an observation |

The thresholds are the P-COMMON common pass criteria: incoming and decoding
frame rate at least 57 FPS, rendering frame rate at least 55 FPS, and frames
dropped by the network at most 1%.

A silent fallback is never a pass. The Android "Prefer AV1" option can fall
back to another codec without a warning, so a pass requires the codec
confirmed on the `Decoder:` line; the logcat decoder lines are the second
source.

Evidence files for an ATV case, under the same
`compat-<CaseId>-<yyyyMMdd_HHmmss>` directory convention as above:
`settings-page.png`, `overlay.png`, `logcat-limelight.txt`,
`host-status-before.txt`, `host-qos.txt`, `host-status-after.txt`.
