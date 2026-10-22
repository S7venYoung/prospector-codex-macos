import Foundation
import Darwin

enum CubeProtocol {
    static func frame(_ metrics: CodexMetrics, version: Int = 2, timeZone: TimeZone = .current) -> String {
        let left = metrics.usedPercent.map { max(0, min(100, 100 - $0)) } ?? -1
        let week = metrics.weekUsedPercent.map { max(0, min(100, 100 - $0)) } ?? -1
        let tokens = metrics.totalTokens.map(String.init) ?? "-1"
        if version >= 3 {
            let reset = metrics.usedPercent != nil ? metrics.primaryResetAt : nil
            let offset = reset.map { timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double($0))) } ?? 0
            return "CODEX3 \(left) \(week) \(tokens) \(metrics.quotaAgeSeconds) 120 \(reset.map(String.init) ?? "-1") \(offset)\n"
        }
        return "CODEX2 \(left) \(week) \(tokens) \(metrics.quotaAgeSeconds) 120\n"
    }
    static func hostFrame(_ metrics: CodexMetrics, system: SystemMetrics, sequence: UInt8) -> String {
        let bytes = KeyboardDashboard.payload(metrics, system: system, sequence: sequence)
        return "HOST1 " + bytes.map { String(format: "%02x", $0) }.joined() + "\n"
    }

}

// Used exclusively from SyncModel's serial utility queue.
final class CubeBridge {
    static let shared = CubeBridge()
    private var serial: CubeSerialPort?
    private var hostSequence: UInt8 = 0
    private var connectedPath: String?
    private var lastIdentifiedPath: String?
    var identifiedSerialPath: String? { connectedPath ?? lastIdentifiedPath }
    func disconnect() { serial = nil; connectedPath = nil }

    func sync(_ metrics: CodexMetrics, system: SystemMetrics? = nil, excludingPaths: Set<String> = []) throws -> String {
        let settings = UserDefaults.standard
        let frame = CubeProtocol.frame(metrics)
        hostSequence &+= 1
        let hostFrame = CubeProtocol.hostFrame(metrics, system: system ?? SystemMetricsReader.read(),
                                               sequence: hostSequence)
        var successes: [String] = []
        var failures: [String] = []
        if settings.object(forKey: "cube.usbEnabled") == nil || settings.bool(forKey: "cube.usbEnabled") {
            do {
                let port = try usbPort(excludingPaths: excludingPaths)
                try port.write(CubeProtocol.frame(metrics, version: port.protocolVersion))
                _ = try port.waitLine(timeout: 3) { $0 == "OK" }
                if port.supportsHostMetrics {
                    try port.write(hostFrame)
                    let reply = try port.waitLine(timeout: 3) { $0 == "OK" || $0 == "ERR" }
                    guard reply == "OK" else { throw BridgeError.serial("Cube 拒绝系统信息") }
                }
                successes.append("USB")
                // Pairing is only available over the locally connected cable.
                try port.write("PAIR\n")
                if let pair = try? port.waitLine(timeout: 2, matching: { $0.hasPrefix("CUBE-PAIR ") }) {
                    let parts = pair.split(separator: " ")
                    if parts.count == 3, parts[2].count == 32 {
                        if parts[1] != "0.0.0.0" { settings.set(String(parts[1]), forKey: "cube.wifiHost") }
                        settings.set(String(parts[2]), forKey: "cube.wifiToken")
                    }
                }
            } catch {
                serial = nil; connectedPath = nil
                failures.append("USB: \(error.localizedDescription)")
            }
        } else { disconnect() }
        if settings.bool(forKey: "cube.wifiEnabled") {
            do {
                try sendWiFi(CubeProtocol.frame(metrics, version: 3), host: settings.string(forKey: "cube.wifiHost") ?? "",
                             token: settings.string(forKey: "cube.wifiToken") ?? "", fallback: frame)
                // Old firmware rejects HOST1 with HTTP 400; keep its quota sync working.
                try sendWiFi(hostFrame, host: settings.string(forKey: "cube.wifiHost") ?? "",
                             token: settings.string(forKey: "cube.wifiToken") ?? "", fallback: frame)
                successes.append("Wi-Fi")
            } catch { failures.append("Wi-Fi: \(error.localizedDescription)") }
        }
        guard !successes.isEmpty else {
            throw BridgeError.serial(failures.isEmpty ? "请启用 USB 或 Wi-Fi 同步" : failures.joined(separator: "；"))
        }
        let warning = failures.isEmpty ? "" : "（另一通道未连接）"
        return successes.joined(separator: " + ") + warning
    }

    private func usbPort(excludingPaths: Set<String>) throws -> CubeSerialPort {
        let selected = (UserDefaults.standard.string(forKey: "cube.serialPath") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let serial, let connectedPath, !excludingPaths.contains(connectedPath),
           selected.isEmpty || selected == connectedPath { return serial }
        serial = nil; connectedPath = nil
        let candidates = try SerialDeviceRouting.candidates(for: .cube, selected: selected,
            available: SerialDeviceRouting.availablePorts(), excluding: excludingPaths)
        for path in candidates {
            do {
                let port = try CubeSerialPort(path: path)
                // Only probe; no data is written to a device before it identifies.
                try port.write("CAPS\n")
                _ = try port.waitLine(timeout: 2) { $0 == "CUBE-CODEX/2" }
                // Keep CAPS/2 unchanged so existing companion versions still work.
                try port.write("CAPS3\n")
                if (try? port.waitLine(timeout: 1, matching: { $0 == "CUBE-CODEX/3" })) != nil {
                    port.protocolVersion = 3
                }
                try port.write("CAPSHOST\n")
                if let reply = try? port.waitLine(timeout: 1, matching: {
                    $0 == "CUBE-HOST-METRICS/1" || $0 == "CUBE-HOST-METRICS/0"
                }) {
                    port.supportsHostMetrics = reply == "CUBE-HOST-METRICS/1"
                }
                lastIdentifiedPath = path
                serial = port; connectedPath = path
                return port
            } catch { continue }
        }
        throw BridgeError.serial("未发现新版 Cube；请检查固件和 115200 波特率串口")
    }

    private func sendWiFi(_ frame: String, host: String, token: String, fallback: String? = nil) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }),
              token.count == 32, token.allSatisfy({ $0.isHexDigit }),
              let url = URL(string: "http://\(host):8765/v1/codex") else {
            throw BridgeError.serial("请先通过 USB 配对，或填写 Cube 的 IPv4 地址和 32 位配对码")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue(token, forHTTPHeaderField: "X-Cube-Token")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(frame.utf8)
        let semaphore = DispatchSemaphore(value: 0)
        let result = HTTPResult()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            let reply = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.set(success: (response as? HTTPURLResponse)?.statusCode == 200 && reply == "OK", error: error,
                       status: (response as? HTTPURLResponse)?.statusCode)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 5) == .timedOut { task.cancel(); throw BridgeError.serial("Wi-Fi 同步超时") }
        let (success, error, status) = result.get()
        if status == 400, let fallback {
            // Only a syntax rejection permits fallback; never mask auth/network failures.
            return try sendWiFi(fallback, host: host, token: token)
        }
        guard success else { throw BridgeError.serial(error?.localizedDescription ?? "Cube 拒绝同步，请核对配对码") }
    }
}

private final class HTTPResult {
    private let lock = NSLock()
    private var success = false
    private var error: Error?
    private var status: Int?
    func set(success: Bool, error: Error?, status: Int?) { lock.lock(); defer { lock.unlock() }; self.success = success; self.error = error; self.status = status }
    func get() -> (Bool, Error?, Int?) { lock.lock(); defer { lock.unlock() }; return (success, error, status) }
}

private final class CubeSerialPort {
    var protocolVersion = 2
    var supportsHostMetrics = false
    private let fd: Int32
    private var input: [UInt8] = []
    private var lines: [String] = []
    init(path: String) throws {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw BridgeError.serial("无法打开 \(path)") }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { close(fd); throw BridgeError.serial("无法读取串口设置") }
        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(HUPCL)
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { close(fd); throw BridgeError.serial("无法设置串口 115200") }
        var modem = Int32(TIOCM_DTR | TIOCM_RTS)
        _ = ioctl(fd, UInt(TIOCMBIC), &modem)
        tcflush(fd, TCIFLUSH)
    }
    deinit { close(fd) }
    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        let deadline = Date().addingTimeInterval(2)
        while offset < bytes.count && Date() < deadline {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if n > 0 { offset += n }
            else if n < 0 && errno != EAGAIN && errno != EINTR { throw BridgeError.serial("USB 写入失败") }
            else { usleep(10_000) }
        }
        guard offset == bytes.count else { throw BridgeError.serial("USB 写入超时") }
    }
    func waitLine(timeout: TimeInterval, matching: (String) -> Bool) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 512)
        while Date() < deadline {
            while !lines.isEmpty {
                let line = lines.removeFirst()
                if matching(line) { return line }
            }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                for byte in buffer.prefix(n) {
                    if byte == 10 {
                        let line = String(bytes: input, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if lines.count < 64 { lines.append(line) }
                        input.removeAll(keepingCapacity: true)
                    } else if byte != 13 && input.count < 2048 { input.append(byte) }
                }
            } else if n < 0 && errno != EAGAIN && errno != EINTR { throw BridgeError.serial("USB 连接已断开") }
            else { usleep(10_000) }
        }
        throw BridgeError.serial("Cube 回复超时")
    }
}
