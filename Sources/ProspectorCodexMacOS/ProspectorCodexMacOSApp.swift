import SwiftUI
import AppKit

@main
struct ProspectorCodexMacOSApp: App {
    @Environment(\.openWindow) private var openWindow

    init() {
        // Accessory apps stay out of the Dock while remaining available from the menu bar.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Prospector Codex", systemImage: "circle.hexagongrid.fill") {
            Button("打开 Prospector Codex") {
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            Text("接收器：等待连接")
                .foregroundStyle(.secondary)
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }

        Window("Prospector Codex", id: "dashboard") {
            ContentView()
                .frame(width: 540, height: 640)
        }
        .defaultPosition(.center)
        .defaultSize(width: 540, height: 640)
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @StateObject private var model = SyncModel()

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("● ●").foregroundStyle(.black)
                Text("CODEX // PROSPECTOR").font(.system(size: 26, weight: .black, design: .monospaced))
                Spacer()
                Text("USB ●").font(.system(.headline, design: .monospaced))
            }
            .padding(20)
            .background(Color(red: 1, green: 0.75, blue: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 22))

            MetricCard(title: "5 HOUR USED", value: model.used, color: .yellow)
            MetricCard(title: "TODAY TOTAL TOKEN", value: model.tokens, color: .white)

            Text(model.status).foregroundStyle(.secondary)
            Button(model.connecting ? "正在连接…" : "连接并同步") { model.connect() }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                .disabled(model.connecting)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.06, green: 0.08, blue: 0.07))
        .onAppear { model.refreshPreview() }
    }
}

@MainActor
final class SyncModel: ObservableObject {
    @Published var used = "--%"
    @Published var tokens = "--"
    @Published var status = "未连接接收器"
    @Published var connecting = false

    func refreshPreview() {
        let metrics = CodexMetricsReader.read()
        used = metrics.usedPercent.map { "\($0)%" } ?? "--%"
        tokens = compact(metrics.totalTokens)
    }

    func connect() {
        connecting = true
        status = "正在连接 Prospector 接收器…"
        DispatchQueue.global(qos: .userInitiated).async {
            let metrics = CodexMetricsReader.read()
            do {
                try ProspectorSerialBridge().connectAndSync(metrics)
                DispatchQueue.main.async {
                    self.used = metrics.usedPercent.map { "\($0)%" } ?? "--%"
                    self.tokens = self.compact(metrics.totalTokens)
                    self.status = "已同步 · \(Date.now.formatted(date: .omitted, time: .shortened))"
                    self.connecting = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = error.localizedDescription
                    self.connecting = false
                }
            }
        }
    }

    private func compact(_ value: UInt32) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(.white)
            Text(value).font(.system(size: 70, weight: .black, design: .monospaced)).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(18)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.yellow, lineWidth: 2))
    }
}
