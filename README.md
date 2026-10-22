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

左手默认 Codex 5 小时/7 天剩余额度及重置倒计时；右手默认 CPU、RAM 和 CPU 温度。DYA Custom Settings 只设置 `velvet_display/theme_set`：0=左右均为原小猫咪（默认），1=左 Codex＋右系统信息（同一套主题），Persist 保存后整套保持。旧的左右独立主题设置已取消。

CPU 使用 Mach 计数差值，首次采样未知；RAM 为 active+wired+compressed，非 macOS 内存压力指标。CPU 温度按芯片代际选取已知 CPU SMC 键，M 系列在 SMC 不可用时回退至 CPU 专用 HID 温度传感器；读不到显示 `--°C`。不会用天气、GPU 或电池温度替代 CPU 温度。已知 CPU SMC 键可通过 `prospector.cpuTemperatureSMCKey` 自定义；未确认该键含义时不要指定。温度采集已在当前 Apple M1 通过只读探针验证，键盘端显示和发布版应用仍待构建测试。

沿用应用现有 15–60 秒同步周期，接收器 90 秒没有新数据后显示未知；简洁主题使用三行进度条，不绘制趋势图。与 DYA 不能同时独占同一串口，改主题并保存后退出 DYA，再开启本应用同步。需要配套更新 `zmk-elashvelvet` 的 nano 分支三份固件。Actions 已改为仅手动触发，此次没有构建或发布安装包。

### M 系列温度支持与验证（2026-10-19）

- 自动识别 Apple M 芯片代际，只使用对应 CPU 键；未知代际不猜键，不回退 Intel 的 TC0P。键名映射参考 [Stats CPU 传感器表](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)。
- SMC 无法提供数据时，M 系列回退至 IOKit HID 温度事件，仅选择 `pACC`、`eACC` 和明确命名的 CPU 传感器；排除 GPU、电池、环境和无法归属 CPU 的 PMU die 名称。
- 屏幕的 CPU 温度定义为可用 CPU 传感器中的最高读数，并非全机平均或 GPU 温度。0、NaN、Infinity、越界和缺失数据均不伪造为有效温度。
- HID API 非公开稳定接口，通过动态符号查询调用；接口缺失、访问受限或没有 CPU 传感器时返回未知。应用不调用 sudo、不安装驱动或特权服务、不控制风扇。
- 当前这台 Apple M1 的 SMC CPU 键返回不存在；HID 回退的只读原生探针返回约 60.9°C。此结果验证的是该机器当时的电脑端采集，不能证明所有 M 系列/macOS 版本或键盘显示均已通过。
- 宿主传感器选择、Float32/SP78 解码、非法数值、最高值选择测试通过；XCTest 用例留待用户确认后在 Actions 执行。没有构建 macOS 安装包或触发 Actions，键盘的 18 字节协议保持不变。

### 整套主题选择

固件按整套主题切换，不按屏幕单独选择。猫咪套装左右都是猫咪；信息套装左 Codex、右系统和 CPU 温度。`host_metrics` 数据协议不变，此次仅更正主题说明，不需修改电脑端发送逻辑。

### 简洁信息套装

键盘信息套装现为左 5H/7D/RESET、右 CPU/RAM/TEMP 三行进度条，不显示 CODEX 大字。CPU 温度显示整数°C。电脑端仍发送同一份 18 字节遥测，无需改变同步逻辑；DYA 整套主题选择保持不变。

## 配套软件系统信息页面

已删除时间、天气设置及其网络请求和 host-status 同步。系统信息页显示 Mac CPU 使用率、内存使用率和 CPU 温度，不显示内存容量数值。页面与键盘遥测使用同一次采样，随后台同步刷新；首次 CPU 采样和不可用传感器显示未知值。同步状态显示“已同步”，不显示时间。

### Cube 键盘系统信息转发

Cube 同步复用现有 CPU/RAM/温度采集结果，使用与 Nano 相同的 18 字节 host_metrics。USB 经 CAPSHOST 探测能力后发送 HOST1 十六进制帧；Wi-Fi 经已有配对令牌的 /v1/codex 接口发送同一帧。保持原 CODEX2/3 额度同步。旧 Cube 的 USB 不发送新增帧，Wi-Fi 仅对 HTTP 400 回退额度帧，不掩盖认证或网络错误。

需同时更新 codex/xingzhi-cube-dongle 的 Cube 主控，以及 zmk-esp32-cube 分支的键盘固件（左猫咪、右系统信息）。电脑采集频率维持现有设置，Cube 每秒刷新键盘，90 秒无新电脑数据后显示未知。未新增时间、天气或采集器。
