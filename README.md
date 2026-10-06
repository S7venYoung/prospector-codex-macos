# Prospector Codex macOS / Cube

Native macOS 13+ menu bar companion. Cube firmware now uses USB UART at **115200 baud** and optional authenticated LAN HTTP. Original Prospector/ZMK Studio remains a separate selectable target, using its original 12500 baud protocol.

## Cube setup

1. Install the matching Cube Codex dashboard firmware. Connect the board's USB-to-UART port; native USB is unavailable because GPIO20 controls its backlight.
2. Open settings, select **Cube Codex 双通道**, enable USB and click **立即同步**. Specify `/dev/cu.…` if automatic discovery selects no device.
3. Successful USB sync saves the board's IP and random pairing token. Enable Wi-Fi, keep Cube and Mac on the same trusted LAN. If DHCP changes its IP, reconnect USB or update the IP manually.
4. Both enabled channels send data every 15/30/60 seconds. Close the settings window; the menu bar app continues syncing. Quit the app to stop.

USB has a 75-second data lease; when packets stop, a fresh Wi-Fi sample takes over. Samples expire after 120 seconds. Wi-Fi is HTTP on port 8765, authenticated with `X-Cube-Token`; it is **not encrypted** and must not be exposed to the internet. Only quota/token metrics are sent, never login credentials or conversation content. Pairing tokens are saved in local app preferences.

## Data semantics

Local `~/.codex/sessions` JSONL files supply used percentages and cumulative token counts. The display shows `100 - used`, with today's token increments summed once per session. Quota samples older than 15 minutes or a passed primary reset time are unavailable; unknown values remain `--`, never fabricated 100%. Transport connectivity does not guarantee a fresh Codex quota sample. Desktop/chat activity not recorded in these local logs cannot be included. Keyboard layer/WPM/L/R battery remain unavailable until real ZMK telemetry is implemented.

Protocol: `CAPS` -> `CUBE-CODEX/2`; `PAIR` -> `CUBE-PAIR <IPv4> <32-hex-token>`; `CODEX2 <5h-left|-1> <week-left|-1> <today-tokens|-1> <quota-age-seconds> <ttl-seconds>` -> `OK`. Wi-Fi POST `/v1/codex` accepts the same frame. `-1` means unavailable. Compatibility `PING` and legacy `CODEX` remain supported on the Cube.

```sh
swift build -c release
swift test
```

GitHub Actions packages `Prospector.dmg`. The app is ad-hoc signed, not Apple notarized.
