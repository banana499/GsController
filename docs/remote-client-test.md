# Second-Client Acceptance Guide

## Prerequisites

- Host: Windows 11, product installed, `gs-product.ps1` available, LAN
  address `<host-ip>` (fill in; the original validation host's address is
  withheld from the public repository).
- Client: same LAN, Moonlight 6.2.0.
- Client can reach `http://<host-ip>:47989/serverinfo` and gets HTTP 200.
- Client is paired with the host using a fixed PIN. Do not rely on a random GUI
  PIN race.

## 1. Start the host product

```powershell
$p = 'C:\Program Files\Local Development\GsController\gs-product.ps1'
& $p -Action Start
& $p -Action Status
```

Confirm `serverinfo` returns 200 before starting the client.

## 2. Client 4K60

Windows client:

```powershell
.\client\Invoke-Moonlight4KTest.ps1 -HostUuid <host-uuid> `
  -Resolution 4K -Fps 60 -BitrateKbps 50000 -Seconds 60
```

`<host-uuid>` is the per-install UUID of your host as listed by
`Moonlight list`; the original value is withheld from the public
repository.

macOS/Linux client:

```bash
Moonlight stream <host-ip> "Desktop" \
  --4K --fps 60 --bitrate 50000 --display-mode fullscreen \
  --video-codec HEVC --performance-overlay
```

Record on the client: device/OS, Moonlight version, wired/Wi-Fi, screenshot,
actual resolution/FPS/bitrate, stutter or disconnects.

## 3. Host-side evidence

After the session, before stopping the product:

```powershell
# Launch response
Select-String -Path "$env:APPDATA\Moonlight Game Streaming Project\Moonlight\*.log" `
  -Pattern 'Launch response' -ErrorAction SilentlyContinue

# Streamer Qos / FPS / loss
Get-Content 'C:\ProgramData\NVIDIA Corporation\NvStream\NvStreamerCurrent.log' -Tail 300 |
  Select-String -Pattern 'QosManagerTxNati|Frame Number|Avg Game FPS|loss|Loss'

# Product state
Get-Content 'C:\ProgramData\Local Development\GsController\runtime\state\status.json' -Raw
```

Expected:

- `/launch` `status_code="200"`, `DisplayWidth=3840`, `DisplayHeight=2160`;
- `Video stream is 3840x2160x60`;
- Qos `Frame Number` keeps increasing and `Avg Game FPS` is near 60;
- client overlay shows Q-score, RTD, and packet loss;
- host returns to `AVAILABLE` after the client quits.

## 4. Stop and recover

```powershell
& $p -Action Stop
```

Confirm the official services are running again and the product's private
runtime is stopped.

## 5. Reboot acceptance

1. Confirm the supervisor task:
   ```powershell
   Get-ScheduledTask -TaskName GsControllerSupervisor
   ```
2. Remove the pause flag if present:
   ```powershell
   Remove-Item 'C:\ProgramData\Local Development\GsController\runtime\state\supervisor_pause.flag' -Force
   ```
3. Reboot and log in as the same user; wait 2–3 minutes.
4. Check:
   ```powershell
   Get-Content 'C:\ProgramData\Local Development\GsController\runtime\bin\_supervisor.log' -Tail 40
   Invoke-WebRequest http://127.0.0.1:47989/serverinfo
   Get-Content 'C:\ProgramData\Local Development\GsController\runtime\state\status.json' -Raw
   ```
   Expect `RESULT OK`, `serverinfo` 200, `state=ready`.
5. Start Desktop from the second client and capture evidence.

## Current status

The MacBook Pro M4 Pro second-client acceptance passed at 4K60, 1080p60, and
720p60. See `docs/acceptance-evidence.md`.

Always quit the client normally (`Moonlight quit <host>`). A forced kill can
leave the host streamer resident and the host busy; the test harness now quits
first and only force-stops as a fallback.
