import Foundation
import Darwin

struct CodexMetrics {
    let usedPercent: Int?
    let totalTokens: UInt32
    let updatedAt: UInt32
}

enum BridgeError: LocalizedError {
    case noReceiver
    case invalidResponse
    case subsystemMissing
    case serial(String)

    var errorDescription: String? {
        switch self {
        case .noReceiver: return "未发现 Prospector 接收器；请确认 USB 已连接"
        case .invalidResponse: return "接收器响应无效"
        case .subsystemMissing: return "当前固件没有 Codex metrics 子系统"
        case .serial(let message): return message
        }
    }
}

enum CodexMetricsReader {
    static func read() -> CodexMetrics {
        let now = Date()
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        var tokens: UInt64 = 0
        var newest = Date.distantPast
        var used: Int?

        for offset in 0..<4 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let directory = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let payload = json["payload"] as? [String: Any] else { continue }
                    let timestamp = (json["timestamp"] as? String).flatMap(ISO8601DateFormatter().date(from:))
                    if payload["type"] as? String == "token_count", let timestamp, timestamp >= midnight,
                       let info = payload["info"] as? [String: Any], let usage = info["last_token_usage"] as? [String: Any] {
                        tokens += UInt64(usage["input_tokens"] as? Int ?? 0)
                        tokens += UInt64(usage["cache_write_input_tokens"] as? Int ?? 0)
                        tokens += UInt64(usage["output_tokens"] as? Int ?? 0)
                    }
                    if let timestamp, timestamp > newest,
                       let limits = payload["rate_limits"] as? [String: Any],
                       let primary = limits["primary"] as? [String: Any], let value = primary["used_percent"] as? Double {
                        newest = timestamp
                        used = min(100, max(0, Int(value.rounded())))
                    }
                }
            }
        }
        return CodexMetrics(usedPercent: used, totalTokens: UInt32(min(tokens, UInt64(UInt32.max))), updatedAt: UInt32(Date().timeIntervalSince1970))
    }
}

final class ProspectorSerialBridge {
    private let subsystemIdentifier = "s7venyoung__codex_metrics"
    private var port: SerialPort?
    private var nextRequestID: UInt32 = 1

    func connectAndSync(_ metrics: CodexMetrics) throws {
        let device = try receiverPath()
        let serial = try SerialPort(path: device)
        port = serial
        let list = try requestList()
        guard let index = list[subsystemIdentifier] else { throw BridgeError.subsystemMissing }
        try requestMetrics(subsystemIndex: index, metrics: metrics)
    }

    private func receiverPath() throws -> String {
        let paths = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let candidates = paths.filter { $0.hasPrefix("cu.") && ($0.localizedCaseInsensitiveContains("usbmodem") || $0.localizedCaseInsensitiveContains("usbserial")) }
        guard let first = candidates.sorted().first else { throw BridgeError.noReceiver }
        return "/dev/" + first
    }

    private func requestList() throws -> [String: UInt32] {
        let custom = Proto.field(1, bytes: [])
        let response = try call(custom: custom)
        return try Proto.subsystems(from: response)
    }

    private func requestMetrics(subsystemIndex: UInt32, metrics: CodexMetrics) throws {
        let body = Proto.field(1, value: UInt64(metrics.usedPercent ?? 0))
            + Proto.field(2, value: UInt64(metrics.totalTokens))
            + Proto.field(3, value: UInt64(metrics.updatedAt))
        let payload = Proto.field(1, bytes: Proto.field(1, bytes: body))
        let call = Proto.field(1, value: UInt64(subsystemIndex)) + Proto.field(2, bytes: payload)
        _ = try self.call(custom: Proto.field(2, bytes: call))
    }

    private func call(custom: [UInt8]) throws -> [UInt8] {
        guard let port else { throw BridgeError.serial("串口未打开") }
        let id = nextRequestID
        nextRequestID += 1
        let request = Proto.field(1, value: UInt64(id)) + Proto.field(100, bytes: custom)
        try port.write(Framing.encode(request))
        let response = try port.readFrame(timeout: 6)
        return response
    }
}

private final class SerialPort {
    private let fd: Int32
    private var frame: [UInt8] = []
    private var started = false
    private var escaped = false

    init(path: String) throws {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw BridgeError.serial("无法打开 \(path)：\(String(cString: strerror(errno)))") }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { close(fd); throw BridgeError.serial("无法读取串口设置") }
        cfmakeraw(&options)
        // USB CDC ACM ignores the nominal baud rate, but macOS termios rejects
        // Web Serial's non-standard 12500 value. Use a supported host setting.
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { close(fd); throw BridgeError.serial("无法配置串口") }
    }

    deinit { close(fd) }

    func write(_ bytes: [UInt8]) throws {
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
        guard written == bytes.count else { throw BridgeError.serial("串口写入失败") }
    }

    func readFrame(timeout: TimeInterval) throws -> [UInt8] {
        let end = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 256)
        let bufferLength = buffer.count
        while Date() < end {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, bufferLength) }
            if count > 0 {
                for byte in buffer.prefix(Int(count)) {
                    if let complete = receive(byte) { return complete }
                }
            } else {
                usleep(10_000)
            }
        }
        throw BridgeError.serial("接收器响应超时；请退出 DYA 后重试")
    }

    private func receive(_ byte: UInt8) -> [UInt8]? {
        if !started { if byte == 0xAB { started = true; frame.removeAll(); escaped = false }; return nil }
        if escaped { frame.append(byte); escaped = false; return nil }
        if byte == 0xAC { escaped = true; return nil }
        if byte == 0xAD { started = false; return frame }
        if byte == 0xAB { frame.removeAll(); return nil }
        frame.append(byte)
        return nil
    }
}

private enum Framing {
    static func encode(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = [0xAB]
        for byte in input {
            if byte == 0xAB || byte == 0xAC || byte == 0xAD { output.append(0xAC) }
            output.append(byte)
        }
        output.append(0xAD)
        return output
    }
}

private enum Proto {
    static func field(_ number: UInt64, value: UInt64) -> [UInt8] { var out = varint(number << 3); out += varint(value); return out }
    static func field(_ number: UInt64, bytes: [UInt8]) -> [UInt8] { var out = varint((number << 3) | 2); out += varint(UInt64(bytes.count)); out += bytes; return out }
    static func varint(_ value: UInt64) -> [UInt8] { var n = value; var out: [UInt8] = []; repeat { var b = UInt8(n & 0x7F); n >>= 7; if n != 0 { b |= 0x80 }; out.append(b) } while n != 0; return out }

    static func subsystems(from response: [UInt8]) throws -> [String: UInt32] {
        let responseBody = try child(field: 1, in: response)
        let requestResponse = try child(field: 100, in: responseBody)
        let custom = try child(field: 1, in: requestResponse)
        var result: [String: UInt32] = [:]
        for info in children(field: 1, in: custom) {
            let index = try unsigned(field: 1, in: info)
            let identifier = String(bytes: try child(field: 2, in: info), encoding: .utf8) ?? ""
            result[identifier] = UInt32(index)
        }
        return result
    }

    static func child(field target: UInt64, in data: [UInt8]) throws -> [UInt8] {
        guard let value = children(field: target, in: data).first else { throw BridgeError.invalidResponse }
        return value
    }
    static func unsigned(field target: UInt64, in data: [UInt8]) throws -> UInt64 {
        var index = 0
        while index < data.count { let tag = try readVarint(data, &index); let wire = tag & 7; let field = tag >> 3; if field == target && wire == 0 { return try readVarint(data, &index) }; try skip(wire, data, &index) }
        throw BridgeError.invalidResponse
    }
    static func children(field target: UInt64, in data: [UInt8]) -> [[UInt8]] {
        var index = 0; var result: [[UInt8]] = []
        while index < data.count {
            guard let tag = try? readVarint(data, &index) else { break }; let wire = tag & 7; let field = tag >> 3
            if field == target && wire == 2, let length = try? readVarint(data, &index), index + Int(length) <= data.count { result.append(Array(data[index..<index + Int(length)])); index += Int(length) }
            else { try? skip(wire, data, &index) }
        }
        return result
    }
    static func readVarint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 { var value: UInt64 = 0; var shift: UInt64 = 0; while index < bytes.count && shift < 64 { let b = bytes[index]; index += 1; value |= UInt64(b & 0x7F) << shift; if b & 0x80 == 0 { return value }; shift += 7 }; throw BridgeError.invalidResponse }
    static func skip(_ wire: UInt64, _ data: [UInt8], _ index: inout Int) throws { switch wire { case 0: _ = try readVarint(data, &index); case 2: let length = try readVarint(data, &index); guard index + Int(length) <= data.count else { throw BridgeError.invalidResponse }; index += Int(length); case 5: index += 4; case 1: index += 8; default: throw BridgeError.invalidResponse } }
}
