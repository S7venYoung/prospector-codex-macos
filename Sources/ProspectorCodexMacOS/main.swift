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
                .frame(minWidth: 520, minHeight: 620)
        }
        .defaultPosition(.center)
    }
}

struct ContentView: View {
    @State private var used = "--%"
    @State private var tokens = "--"
    @State private var status = "未连接接收器"

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

            MetricCard(title: "5 HOUR USED", value: used, color: .yellow)
            MetricCard(title: "TODAY TOTAL TOKEN", value: tokens, color: .white)

            Text(status).foregroundStyle(.secondary)
            Button("连接并同步") { status = "原生串口模块准备中…" }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
        }
        .padding(24)
        .background(Color(red: 0.06, green: 0.08, blue: 0.07))
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
