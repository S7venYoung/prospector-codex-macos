import Foundation
import Darwin

/// Uses Codex's managed login, never reads credentials or starts a model turn.
final class OfficialQuotaReader {
    struct Window {
        let used: Int
        let resetsAt: TimeInterval
    }
    struct Snapshot {
        let primary: Window?
        let secondary: Window?
        let fetchedAt: Date

        static func parse(_ result: [String: Any], now: Date) -> Snapshot? {
            let buckets = result["rateLimitsByLimitId"] as? [String: Any]
            let bucket: [String: Any]?
            if let buckets, !buckets.isEmpty {
                bucket = buckets["codex"] as? [String: Any]
            } else {
                bucket = result["rateLimits"] as? [String: Any]
            }
            guard let bucket else { return nil }
            func window(_ key: String, minutes: Int) -> Window? {
                guard let value = bucket[key] as? [String: Any],
                      let duration = value["windowDurationMins"] as? Int, duration == minutes,
                      let used = value["usedPercent"] as? Double, used.isFinite,
                      (0...100).contains(used),
                      let reset = value["resetsAt"] as? Double,
                      reset > now.timeIntervalSince1970 else { return nil }
                return Window(used: Int(used.rounded()), resetsAt: reset)
            }
            let primary = window("primary", minutes: 300)
            let secondary = window("secondary", minutes: 10_080)
            guard primary != nil || secondary != nil else { return nil }
            return Snapshot(primary: primary, secondary: secondary, fetchedAt: now)
        }

        func merging(_ logs: CodexMetrics, now: Date) -> CodexMetrics {
            let age = max(0, now.timeIntervalSince(fetchedAt))
            guard age <= 900 else { return logs }
            let p = primary.flatMap { $0.resetsAt > now.timeIntervalSince1970 ? $0 : nil }
            let s = secondary.flatMap { $0.resetsAt > now.timeIntervalSince1970 ? $0 : nil }
            guard p != nil || s != nil else { return logs }
            // One age covers both windows on the wire: don't rejuvenate stale log values.
            return CodexMetrics(usedPercent: p?.used, weekUsedPercent: s?.used,
                totalTokens: logs.totalTokens,
                resetInMinutes: p.map { UInt32(max(0, ($0.resetsAt - now.timeIntervalSince1970) / 60)) },
                updatedAt: logs.updatedAt, quotaAgeSeconds: UInt32(age))
        }
    }

    static let shared = OfficialQuotaReader()
    private let lock = NSLock()
    private var lastAttempt: Date?
    private var cached: Snapshot?

    func read(now: Date = Date()) -> CodexMetrics {
        let logs = CodexMetricsReader.read(now: now)
        lock.lock()
        defer { lock.unlock() }
        if lastAttempt == nil || now.timeIntervalSince(lastAttempt!) >= 60 {
            lastAttempt = now
            if let result = try? Self.query(), let snapshot = Snapshot.parse(result, now: Date()) {
                cached = snapshot
            }
        }
        return cached?.merging(logs, now: Date()) ?? logs
    }

    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixed = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            home + "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        return (fixed + path).first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    enum QueryError: Error { case unavailable, timeout, invalidResponse }

    /// Bounded stdio JSON-RPC session. No shell, auth file access, login or reset RPC.
    static func query() throws -> [String: Any] {
        guard let executable = executable() else { throw QueryError.unavailable }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var buffer = Data()
        var received = 0
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func response(_ id: Int) throws -> [String: Any] {
            while ProcessInfo.processInfo.systemUptime < deadline {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline)
                    buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          message["id"] as? Int == id else { continue }
                    guard let result = message["result"] as? [String: Any] else { throw QueryError.invalidResponse }
                    return result
                }
                var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&fd, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; throw QueryError.invalidResponse }
                if ready > 0 {
                    let data = output.fileHandleForReading.availableData
                    guard !data.isEmpty else { throw QueryError.invalidResponse }
                    received += data.count
                    guard received <= 1_048_576 else { throw QueryError.invalidResponse }
                    buffer.append(data)
                }
            }
            throw QueryError.timeout
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "prospector_quota", "version": "0.1.0"]]])
        _ = try response(1)
        try send(["method": "initialized", "params": [:]])
        try send(["id": 2, "method": "account/rateLimits/read"])
        return try response(2)
    }
}
