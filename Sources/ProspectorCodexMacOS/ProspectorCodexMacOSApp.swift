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
            ProspectorSettingsView().frame(width: 720, height: 640)
        }
        .defaultPosition(.center)
        .defaultSize(width: 720, height: 640)
        .windowResizability(.contentSize)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case sync = "同步"
    case system = "系统信息"
    var id: String { rawValue }
    var icon: String { self == .sync ? "arrow.triangle.2.circlepath" : "cpu" }
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
            case .system: SystemSettingsView()
            }
        }
    }
}

struct SyncSettingsView: View {
    @ObservedObject private var model = SyncModel.shared
    @AppStorage("prospector.autoSync") private var enabled = true
    @AppStorage("cube.syncSeconds") private var interval = 30
    @AppStorage("cube.deviceEnabled") private var cubeEnabled = true
    @AppStorage("prospector.deviceEnabled") private var prospectorEnabled = true
    @AppStorage("prospector.serialPath") private var prospectorPath = ""
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

            Section("小智 Cube · USB / Wi-Fi") {
                Toggle("同步小智 Cube", isOn: $cubeEnabled)
                if cubeEnabled {
                    Toggle("USB 同步（优先）", isOn: $usb)
                    TextField("串口路径（留空自动识别）", text: $serialPath)
                    Toggle("Wi-Fi 同步", isOn: $wifi)
                    TextField("Cube IPv4 地址", text: $host)
                    SecureField("配对码（USB 同步后自动保存）", text: $token)
                    Text("先用 USB 同步一次，再启用 Wi-Fi。两通道同时发送；USB 优先租约为 75 秒。局域网 HTTP 不加密，请勿开放公网。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("扫描仪 · Prospector / ZMK") {
                Toggle("同步扫描仪", isOn: $prospectorEnabled)
                if prospectorEnabled {
                    TextField("扫描仪串口（留空自动识别）", text: $prospectorPath)
                    Text("可以与小智 Cube 同时启用。两个 USB 设备必须选择不同串口；扫描仪使用 12500，Cube 使用 115200。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("状态") {
                LabeledContent("小智 Cube", value: model.cubeStatus)
                LabeledContent("扫描仪", value: model.prospectorStatus)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
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

struct SystemSettingsView: View {
    @ObservedObject private var model = SyncModel.shared

    private func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "--"
    }

    var body: some View {
        Form {
            Section("Mac 系统信息") {
                LabeledContent("CPU 使用率", value: percent(model.systemMetrics.cpuPercent))
                LabeledContent("内存使用率", value: percent(model.systemMetrics.ramPercent))
                LabeledContent("CPU 温度", value: model.systemMetrics.cpuTemperatureDeciC.map {
                    String(format: "%.1f°C", Double($0) / 10)
                } ?? "--°C")
            }
            Section {
                Text("随后台同步刷新，并发送到支持系统信息主题的键盘。CPU 首次采样或传感器不可用时显示 --。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.syncing ? "正在同步…" : "立即同步") { model.syncNow() }
                    .disabled(model.syncing)
            }
        }
        .formStyle(.grouped)
        .padding(22)
        .navigationTitle("系统信息")
    }
}

@MainActor
final class SyncModel: ObservableObject {
    static let shared = SyncModel()
    private let queue = DispatchQueue(label: "dev.s7venyoung.cube-sync", qos: .utility)
    @Published var status = "未连接"
    @Published var cubeStatus = "等待同步"
    @Published var prospectorStatus = "等待同步"
    @Published var syncing = false
    @Published var systemMetrics = SystemMetrics()
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
            guard let model = self else { return }
            Task { @MainActor [model] in model.syncNow() }
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
        let settings = UserDefaults.standard
        let cubeEnabled = settings.object(forKey: "cube.deviceEnabled") == nil || settings.bool(forKey: "cube.deviceEnabled")
        let prospectorEnabled = settings.object(forKey: "prospector.deviceEnabled") == nil || settings.bool(forKey: "prospector.deviceEnabled")
        let prospectorPath = (settings.string(forKey: "prospector.serialPath") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cubePath = (settings.string(forKey: "cube.serialPath") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        cubeStatus = cubeEnabled ? "正在同步…" : "已停用"
        prospectorStatus = prospectorEnabled ? "正在同步…" : "已停用"
        queue.async {
            let metrics = CodexMetricsReader.read()
            let system = SystemMetricsReader.read()
            DispatchQueue.main.async { self.systemMetrics = system }
            if !cubeEnabled { CubeBridge.shared.disconnect() }
            MultiDeviceSync.run(cubeEnabled: cubeEnabled, prospectorEnabled: prospectorEnabled, cube: {
                let excluded: Set<String> = prospectorEnabled && !prospectorPath.isEmpty ? [prospectorPath] : []
                return try CubeBridge.shared.sync(metrics, excludingPaths: excluded)
            }, prospector: {
                var excluded = Set<String>()
                if cubeEnabled {
                    if !cubePath.isEmpty { excluded.insert(cubePath) }
                    if let identified = CubeBridge.shared.identifiedSerialPath { excluded.insert(identified) }
                }
                try ProspectorSerialBridge().connectAndSync(metrics, system: system,
                    selectedPath: prospectorPath, excludingPaths: excluded)
                return "USB"
            }, report: { device, result in
                let message: String
                switch result {
                case .success(let connection): message = "\(connection) · 已同步"
                case .failure(let error): message = error.localizedDescription
                }
                DispatchQueue.main.async {
                    if device == .cube { self.cubeStatus = message }
                    else { self.prospectorStatus = message }
                }
            })
            DispatchQueue.main.async {
                self.status = cubeEnabled || prospectorEnabled ? "本轮同步完成，两台设备结果分别显示" : "请至少启用一台设备"
                self.syncing = false
            }
        }
    }
}
