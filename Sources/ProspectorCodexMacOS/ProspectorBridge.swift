import Foundation
import Darwin

// IOKit/serial/ioss.h: IOSSIOSPEED, expanded for 64-bit macOS speed_t.
// Web Serial opens the Prospector CDC endpoint at exactly 12500 baud.
private let iosSerialSpeed: UInt = 0x8008_5402

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
        case .noReceiver: return "æªåç° Prospector æ¥æ¶å¨ï¼è¯·ç¡®è®¤ USB å·²è¿æ¥"
        case .invalidResponse: return "æ¥æ¶å¨ååºæ æ"
        case .subsystemMissing: return "å½ååºä»¶æ²¡æ Codex metrics å­ç³»ç»"
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
        let timestampFormatter = ISO8601DateFormatter()
        // Codex writes timestamps such as 2026-09-15T09:27:22.481Z.
        // ISO8601DateFormatter does not accept fractional seconds unless this
        // option is set, which previously made every sample look unavailable.
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // A session can span midnight and remains in the directory in which it
        // began. Directory names therefore cannot be used as the data date.
        let files = (FileManager.default.enumerator(at: root,
                                                    includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }) ?? []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var previousTotal: UInt64?
            for line in text.split(separator: "\n") {
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let payload = json["payload"] as? [String: Any] else { continue }
                    let timestamp = (json["timestamp"] as? String).flatMap(timestampFormatter.date(from:))
                    if payload["type"] as? String == "token_count",
                       let info = payload["info"] as? [String: Any],
                       let usage = info["total_token_usage"] as? [String: Any],
                       let total = (usage["total_tokens"] as? NSNumber)?.uint64Value {
                        // total_token_usage is cumulative for a session. Only
                        // add its increase since the preceding event, never the
                        // whole cumulative value again.
                        if let timestamp, timestamp >= midnight {
                            if let previousTotal, total >= previousTotal {
                                tokens += total - previousTotal
                            } else if let last = info["last_token_usage"] as? [String: Any],
                                      let initial = (last["total_tokens"] as? NSNumber)?.uint64Value {
                                // First post-midnight sample of a new/unknown file.
                                tokens += initial
                            }
                        }
                        previousTotal = total
                    }
                    if let timestamp, timestamp > newest,
                       let limits = payload["rate_limits"] as? [String: Any],
                       let primary = limits["primary"] as? [String: Any], let value = primary["used_percent"] as? Double {
                        newest = timestamp
                        used = min(100, max(0, Int(value.rounded())))
                    }
            }
        }
        return CodexMetrics(usedPercent: used, totalTokens: UInt32(min(tokens, UInt64(UInt32.max))), updatedAt: UInt32(Date().timeIntervalSince1970))
    }
}

final class ProspectorSerialBridge {
    private let subsystemIdentifier = "s7venyoung__codex_metrics"
    private let hostStatusSubsystemIdentifier = "s7venyoung__host_status"
    private var port: SerialPort?
    // Do not use zero: protobuf omits a zero request ID, the same shape used
    // by asynchronous Studio notifications. Starting at one lets us ignore
    // those notifications while waiting for an RPC response.
    private var nextRequestID: UInt32 = 1

    func connectAndSync(_ metrics: CodexMetrics, hostStatus: HostStatus? = nil) throws {
        let device = try receiverPath()
        let serial = try SerialPort(path: device)
        port = serial
        // Scanner firmware uses a small newline-delimited CDC protocol rather
        // than ZMK Studio RPC. Probe it first; regular dongle firmware ignores
        // this PING and continues with the existing Studio flow.
        if try serial.isScanner() {
            let left = max(0, min(100, 100 - (metrics.usedPercent ?? 0)))
            try serial.writeText("CODEX \(left) \(metrics.totalTokens)\n")
            guard try serial.readTextLine(timeout: 2).trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
                throw BridgeError.serial("Scanner did not confirm Codex data")
            }
            return
        }
        let list = try requestList()
        var sent = false
        // A receiver-only weather theme intentionally omits the Codex metrics
        // endpoint. Do not let that prevent its independent clock/weather RPC.
        if let index = list[subsystemIdentifier] {
            try requestMetrics(subsystemIndex: index, metrics: metrics)
            sent = true
        }
        if let hostStatus, let hostIndex = list[hostStatusSubsystemIdentifier] {
            try requestHostStatus(subsystemIndex: hostIndex, status: hostStatus)
            sent = true
        }
        guard sent else { throw BridgeError.subsystemMissing }
    }

    private func receiverPath() throws -> String {
        let paths = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let candidates = paths.filter { $0.hasPrefix("cu.") && ($0.localizedCaseInsensitiveContains("usbmodem") || $0.localizedCaseInsensitiveContains("usbserial")) }
        // DYA identifies this receiver as usbmodem11304. Prefer it when both
        // the receiver and another USB CDC device are attached.
        let receiver = candidates.first { $0.localizedCaseInsensitiveContains("usbmodem11304") }
            ?? candidates.first { $0.localizedCaseInsensitiveContains("prospector") }
            ?? candidates.sorted().last
        guard let receiver else { throw BridgeError.noReceiver }
        return "/dev/" + receiver
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

    private func requestHostStatus(subsystemIndex: UInt32, status: HostStatus) throws {
        let payload = Proto.field(1, bytes:
            Proto.field(1, bytes:
                Proto.field(1, value: UInt64(status.unixTime))
                + Proto.field(2, value: Proto.zigZag(status.temperatureDeciC))
                + Proto.field(3, value: UInt64(status.weatherCode))
                + Proto.field(4, value: UInt64(status.observedAt))
                + Proto.field(5, value: Proto.zigZag(status.highTemperatureDeciC))
                + Proto.field(6, value: Proto.zigZag(status.lowTemperatureDeciC))
                + Proto.field(7, value: UInt64(status.rainProbability))
                + Proto.field(8, value: Proto.zigZag(status.timezoneOffsetMinutes))))
        let call = Proto.field(1, value: UInt64(subsystemIndex)) + Proto.field(2, bytes: payload)
        _ = try self.call(custom: Proto.field(2, bytes: call))
    }

    private func call(custom: [UInt8]) throws -> [UInt8] {
        guard let port else { throw BridgeError.serial("ä¸²å£æªæå¼") }
        let id = nextRequestID
        nextRequestID += 1
        let request = Proto.field(1, value: UInt64(id)) + Proto.field(100, bytes: custom)
        try port.write(Framing.encode(request))
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            do {
                let response = try port.readFrame(timeout: 0.5)
                if Proto.requestID(in: response) == id { return response }
            } catch {
                if Date() >= deadline { throw error }
            }
        }
        throw BridgeError.serial("æ¥æ¶å¨ååºè¶æ¶ï¼è¯·éåº DYA åéè¯")
    }
}

private final class SerialPort {
    private let fd: Int32
    private var frame: [UInt8] = []
    private var started = false
    private var escaped = false
    private var textBytes: [UInt8] = []

    init(path: String) throws {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw BridgeError.serial("æ æ³æå¼ \(path)ï¼\(String(cString: strerror(errno)))") }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { close(fd); throw BridgeError.serial("æ æ³è¯»åä¸²å£è®¾ç½®") }
        cfmakeraw(&options)
        // Match ZMK Studio / Chromium Web Serial exactly. The receiver's CDC
        // endpoint expects line coding 12500; B115200 causes its RPC replies
        // to time out even though the device node opens successfully.
        cfsetspeed(&options, speed_t(B9600))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { close(fd); throw BridgeError.serial("æ æ³éç½®ä¸²å£") }
        var requestedSpeed: speed_t = 12_500
        guard ioctl(fd, iosSerialSpeed, &requestedSpeed) != -1 else {
            close(fd)
            throw BridgeError.serial("æ æ³å° Prospector ä¸²å£è®¾ä¸º 12500 æ³¢ç¹ç")
        }
    }

    deinit { close(fd) }

    func write(_ bytes: [UInt8]) throws {
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
        guard written == bytes.count else { throw BridgeError.serial("ä¸²å£åå¥å¤±è´¥") }
    }

    func writeText(_ text: String) throws {
        try write(Array(text.utf8))
    }

    func isScanner() throws -> Bool {
        try writeText("PING\n")
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let line = try readTextLine(timeout: 0.2)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "PROSPECTOR-SCANNER/1" { return true }
        }
        return false
    }

    func readTextLine(timeout: TimeInterval) throws -> String {
        let end = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 128)
        let bufferLength = buffer.count
        while Date() < end {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, bufferLength) }
            if count > 0 {
                for byte in buffer.prefix(Int(count)) {
                    if byte == 0x0A {
                        let line = String(bytes: textBytes, encoding: .utf8) ?? ""
                        textBytes.removeAll(keepingCapacity: true)
                        return line
                    }
                    if byte != 0x0D && textBytes.count < 256 { textBytes.append(byte) }
                }
            } else {
                usleep(10_000)
            }
        }
        throw BridgeError.serial("Scanner response timed out")
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
        throw BridgeError.serial("æ¥æ¶å¨ååºè¶æ¶ï¼è¯·éåº DYA åéè¯")
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
    static func zigZag(_ value: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: (value << 1) ^ (value >> 31)))
    }

    static func subsystems(from response: [UInt8]) throws -> [String: UInt32] {
        let responseBody = try child(field: 1, in: response)
        let requestResponse = try child(field: 100, in: responseBody)
        let custom = try child(field: 1, in: requestResponse)
        var result: [String: UInt32] = [:]
        for info in children(field: 1, in: custom) {
            // The first registered subsystem uses protobuf's default index 0;
            // proto3 omits that scalar entirely rather than encoding a zero.
            let index = (try? unsigned(field: 1, in: info)) ?? 0
            let identifier = String(bytes: try child(field: 2, in: info), encoding: .utf8) ?? ""
            result[identifier] = UInt32(index)
        }
        return result
    }

    static func requestID(in response: [UInt8]) -> UInt32? {
        guard let requestResponse = try? child(field: 1, in: response) else { return nil }
        guard let id = try? unsigned(field: 1, in: requestResponse) else { return nil }
        return UInt32(id)
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
