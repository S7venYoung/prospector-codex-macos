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

## Velvet 左右键盘屏幕（待构建和实机验证）

沿用现有 Prospector USB Studio 连接，识别接收器的 `velvet_display` 和 `cormoran_custom_settings` 子系统后，把 Codex 与 Mac 系统数据写入 `host_metrics`（MEMORY 模式，不刷写 Flash）。接收器将数据转发至左右键盘，不影响原扫描仪/Cube 协议。

左手默认 Codex 5 小时/7 天剩余额度及重置倒计时；右手默认 CPU、RAM、CPU 温度和趋势。DYA Custom Settings 的 `velvet_display/left_theme`、`right_theme`：0=原小猫咪，1=Codex，2=系统信息，可各自保存。

CPU 使用 Mach 计数差值，首次采样未知；RAM 为 active+wired+compressed，非 macOS 内存压力指标。CPU 温度通过 AppleSMC 的 CPU 专用 TC0D/TC0P 传感器读取；不同 Mac 的接口/键名可用性不同，尤其 Apple Silicon，读不到显示 `--°C`。不会用天气、GPU 或电池温度替代 CPU 温度。已知 CPU SMC 键可通过 `prospector.cpuTemperatureSMCKey` 自定义；未确认该键含义时不要指定。此温度读取尚未在用户硬件上验证。

沿用应用现有 15–60 秒同步周期，接收器 90 秒没有新数据后显示未知；趋势记录最近 12 次电脑更新，不重复填充未更新的旧值。与 DYA 不能同时独占同一串口，改主题并保存后退出 DYA，再开启本应用同步。需要配套更新 `zmk-elashvelvet` 的 nano 分支三份固件。Actions 已改为仅手动触发，此次没有构建或发布安装包。
