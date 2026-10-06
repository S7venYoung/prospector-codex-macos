import SwiftUI
import AppKit

@main
@MainActor
struct ProspectorMacOSApp: App {
    @Environment(\.openWindow) private var openWindow

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        SyncModel.shared.configure(enabled: defaults.object(forKey: "prospector.autoSync") == nil || defaults.bool(forKey: "prospector.autoSync"),
                                   seconds: defaults.integer(forKey: "cube.syncSeconds") == 0 ? 30 : defaults.integer(forKey: "cube.syncSeconds"))
    }

    var body: some Scene {
        MenuBarExtra("Prospector", systemImage: "display") {
            Button("打开 Prospector 设置") {
                openWindow(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
        }

        Window("Prospector", id: "settings") {
            ProspectorSettingsView().frame(width: 680, height: 470)
        }
        .defaultPosition(.center)
        .defaultSize(width: 680, height: 470)
        .windowResizability(.contentSize)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case sync = "同步"
    case environment = "时间与天气"
    var id: String { rawValue }
    var icon: String { self == .sync ? "arrow.triangle.2.circlepath" : "cloud.sun" }
}

struct ProspectorSettingsView: View {
    @State private var section: SettingsSection? = .sync

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("Prospector")
        } detail: {
            switch section ?? .sync {
            case .sync: SyncSettingsView()
            case .environment: EnvironmentSettingsView()
            }
        }
    }
}

struct SyncSettingsView: View {
    @ObservedObject private var model = SyncModel.shared
    @AppStorage("prospector.autoSync") private var enabled = true
    @AppStorage("cube.syncSeconds") private var interval = 30
    @AppStorage("cube.target") private var target = "cube"
    @AppStorage("cube.usbEnabled") private var usb = true
    @AppStorage("cube.wifiEnabled") private var wifi = false
    @AppStorage("cube.serialPath") private var serialPath = ""
    @AppStorage("cube.wifiHost") private var host = ""
    @AppStorage("cube.wifiToken") private var token = ""

    var body: some View {
        Form {
            Section("接收器同步") {
                Toggle("启用后台同步", isOn: $enabled)
                    .onChange(of: enabled) { model.configure(enabled: $0, seconds: interval) }
                Picker("同步间隔", selection: $interval) {
                    Text("每 15 秒").tag(15)
                    Text("每 30 秒").tag(30)
                    Text("每 1 分钟").tag(60)
                }
                .disabled(!enabled)
                .onChange(of: interval) { model.configure(enabled: enabled, seconds: $0) }
            }

            Section("连接") {
                Picker("设备类型", selection: $target) {
                    Text("Cube Codex 双通道").tag("cube")
                    Text("原 Prospector / ZMK Studio").tag("prospector")
                }
                if target == "cube" {
                    Toggle("USB 同步（优先）", isOn: $usb)
                    TextField("串口路径（留空自动识别）", text: $serialPath)
                    Toggle("Wi-Fi 同步", isOn: $wifi)
                    TextField("Cube IPv4 地址", text: $host)
                    SecureField("配对码（USB 同步后自动保存）", text: $token)
                    Text("先用 USB 同步一次，再启用 Wi-Fi。两通道同时发送；USB 优先租约为 75 秒。局域网 HTTP 不加密，请勿开放公网。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("状态") {
                LabeledContent("接收器", value: model.status)
                Button(model.syncing ? "正在同步…" : "立即同步") { model.syncNow() }
                    .disabled(model.syncing)
            }
        }
        .formStyle(.grouped)
        .padding(22)
        .navigationTitle("同步")
        .onAppear { model.configure(enabled: enabled, seconds: interval) }
    }
}

struct EnvironmentSettingsView: View {
    @AppStorage("prospector.syncClock") private var syncClock = true
    @AppStorage("prospector.syncWeather") private var syncWeather = true
    @AppStorage("prospector.weatherPlace") private var place = "Shanghai"
    @AppStorage("prospector.weatherLatitude") private var latitude = "31.2304"
    @AppStorage("prospector.weatherLongitude") private var longitude = "121.4737"

    var body: some View {
        Form {
            Section("主机时间") {
                Toggle("同步 Mac 时间", isOn: $syncClock)
                Text("开启后，后台同步会将当前本地时间发送给支持 host-status 的主题。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("天气") {
                Toggle("同步天气", isOn: $syncWeather)
                TextField("地点名称", text: $place)
                HStack {
                    TextField("纬度", text: $latitude)
                    TextField("经度", text: $longitude)
                }
            }
            Section {
                Text("天气使用 Open-Meteo，无需 API 密钥。此页只配置通用 host-status 数据，不会更改当前主题。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(22)
        .navigationTitle("时间与天气")
    }
}

@MainActor
final class SyncModel: ObservableObject {
    static let shared = SyncModel()
    private let queue = DispatchQueue(label: "dev.s7venyoung.cube-sync", qos: .utility)
    @Published var status = "未连接"
    @Published var syncing = false
    private var timer: Timer?
    private var configuredInterval: Int?

    func configure(enabled: Bool, seconds: Int) {
        let normalizedSeconds = min(60, max(15, seconds))
        if enabled, configuredInterval == normalizedSeconds, timer != nil {
            return
        }
        stop()
        guard enabled else { status = "后台同步已关闭"; return }
        configuredInterval = normalizedSeconds
        syncNow()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(normalizedSeconds), repeats: true) { [weak self] _ in
            self?.syncNow()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        configuredInterval = nil
    }

    func syncNow() {
        guard !syncing else { return }
        syncing = true
        status = "正在同步…"
        let cube = UserDefaults.standard.string(forKey: "cube.target") != "prospector"
        queue.async {
            let metrics = CodexMetricsReader.read()
            do {
                let connection: String
                if cube {
                    connection = try CubeBridge.shared.sync(metrics)
                } else {
                    try ProspectorSerialBridge().connectAndSync(metrics, hostStatus: HostStatusReader.read())
                    connection = "Prospector"
                }
                DispatchQueue.main.async {
                    self.status = "\(connection) · \(Date.now.formatted(date: .omitted, time: .shortened))"
                    self.syncing = false
                }
            } catch {
                DispatchQueue.main.async { self.status = error.localizedDescription; self.syncing = false }
            }
        }
    }
}
