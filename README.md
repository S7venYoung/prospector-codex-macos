# Prospector Codex macOS / Cube

Native macOS 13+ menu bar companion. **Sync the Xiaozhi Cube and the Prospector scanner at the same time.** Cube uses USB UART at **115200 baud** and optional authenticated LAN HTTP; Prospector/scanner retains its original **12500 baud** protocol.

## Two-device setup

Enable both **同步小智 Cube** and **同步扫描仪**. Each cycle reads one Codex quota snapshot and sends it to both devices, with separate connection results. Failure of one target does not suppress the other. Existing Cube Wi-Fi pairing settings are retained; the old device-type picker is no longer used. Both new device switches default to enabled and can be turned off independently.

If both are connected by USB, assign different `/dev/cu.…` ports in their separate fields. Automatic discovery prefers USB-UART for Cube and USB CDC for Prospector, excludes the Cube's connected/configured port from scanner discovery, and confirms the protocol before sending quota data. Explicitly selecting the same port for both is rejected. Device writes are serialized on the background queue to avoid simultaneous probing/reconfiguring of serial ports; this is dual-target synchronization, not parallel serial traffic.

The settings show **小智 Cube** and **扫描仪** statuses independently. Manual synchronization and the 15/30/60-second background schedule update both enabled targets. Weather/clock remains a Prospector host-status feature; this change does not extend Cube's quota protocol.

## Cube setup

1. Install the matching Cube Codex dashboard firmware. Connect the board's USB-to-UART port; native USB is unavailable because GPIO20 controls its backlight.
2. Open settings, enable **同步小智 Cube**, enable USB and click **立即同步**. Specify its `/dev/cu.…` port if automatic discovery selects no device. Keep **同步扫描仪** enabled to update the second device too.
3. Successful USB sync saves the board's IP and random pairing token. Enable Wi-Fi, keep Cube and Mac on the same trusted LAN. If DHCP changes its IP, reconnect USB or update the IP manually.
   Allow the app's local-network permission if macOS prompts. For webpage flashing, **quit this app first** to release its serial port; disabling USB also releases the port after the next sync.
4. Both enabled channels send data every 15/30/60 seconds. Close the settings window; the menu bar app continues syncing. Quit the app to stop.

USB has a 75-second data lease; when packets stop, a fresh Wi-Fi sample takes over. Samples expire after 120 seconds. Wi-Fi is HTTP on port 8765, authenticated with `X-Cube-Token`; it is **not encrypted** and must not be exposed to the internet. Only quota/token metrics are sent, never login credentials or conversation content. Pairing tokens are saved in local app preferences.

## Data semantics

Metrics are cached in memory and read incrementally by file identity and byte offset. Unchanged files are not reread; old unmodified logs are skipped. Each cycle processes at most 8 MiB with a 0.4-second processing budget, then proceeds to device sync. Initial catch-up may take several cycles; incomplete daily totals remain unavailable rather than being presented as final totals. Truncation, replacement, deletion, partial JSONL writes and midnight rollover are handled. Only metric summaries and a bounded incomplete line are retained, not conversations. Clearing local session logs removes the source of historical totals, not account quota; new logged activity repopulates the display.

Local `~/.codex/sessions` JSONL files supply used percentages and cumulative token counts. The display shows `100 - used`, with today's token increments summed once per session. Quota samples older than 15 minutes or a passed primary reset time are unavailable; unknown values remain `--`, never fabricated 100%. Transport connectivity does not guarantee a fresh Codex quota sample. Desktop/chat activity not recorded in these local logs cannot be included. Keyboard layer/WPM/L/R battery remain unavailable until real ZMK telemetry is implemented.

Protocol: `CAPS` -> `CUBE-CODEX/2`; `PAIR` -> `CUBE-PAIR <IPv4> <32-hex-token>`; `CODEX2 <5h-left|-1> <week-left|-1> <today-tokens|-1> <quota-age-seconds> <ttl-seconds>` -> `OK`. Wi-Fi POST `/v1/codex` accepts the same frame. `-1` means unavailable. Compatibility `PING` and legacy `CODEX` remain supported on the Cube.

```sh
swift build -c release
swift test
```

GitHub Actions packages `Prospector.dmg`. The app is ad-hoc signed, not Apple notarized.
