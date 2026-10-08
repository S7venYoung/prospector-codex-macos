import Foundation

/// Keeps only metrics, offsets and an incomplete JSONL line; never caches conversations.
final class IncrementalMetricsReader {
    private struct Quota {
        var timestamp: Date
        var used: Int
        var weekly: Int?
        var reset: Double?
    }
    private final class Cursor {
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var observedSize: UInt64 = 0
        var modified: Date = .distantPast
        var pending = Data()
        var droppingOversizedLine = false
        var previousTotal: UInt64?
        var daily: [Date: UInt64] = [:]
        var sampledDays = Set<Date>()
        var quota: Quota?
    }
    private let root: URL
    private var cursors: [String: Cursor] = [:]
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    private let calendar: Calendar
    private let byteBudget: Int
    private let timeBudget: TimeInterval
    private(set) var bytesReadLastCycle = 0
    private(set) var catchingUp = false

    init(root: URL, calendar: Calendar = .current, byteBudget: Int = 8 * 1024 * 1024,
         timeBudget: TimeInterval = 0.4) {
        self.root = root
        self.calendar = calendar
        self.byteBudget = max(1, byteBudget)
        self.timeBudget = max(0.001, timeBudget)
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func read(now: Date = Date()) -> CodexMetrics {
        let midnight = calendar.startOfDay(for: now)
        // Older, unmodified logs cannot contain today's increments or fresh quotas.
        let cutoff = min(midnight, now.addingTimeInterval(-900))
        let files = (FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])?.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }) ?? []
        let candidates = files.compactMap { file -> (URL, UInt64, UInt64, Date)? in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let modified = attrs[.modificationDate] as? Date,
                  modified >= cutoff else { return nil }
            return (file, size, inode, modified)
        }.sorted { $0.3 > $1.3 }
        let retained = Set(candidates.map { $0.0.path })
        cursors = cursors.filter { retained.contains($0.key) }
        bytesReadLastCycle = 0
        catchingUp = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeBudget
        for (file, size, inode, modified) in candidates {
            var cursor = cursors[file.path] ?? Cursor()
            // Replaced/truncated files and same-size rewrites must not retain old totals.
            if cursor.inode != inode || size < cursor.offset ||
                (size == cursor.observedSize && modified != cursor.modified) {
                cursor = Cursor()
            }
            cursor.inode = inode
            cursor.modified = modified
            cursor.observedSize = size
            cursor.daily = cursor.daily.filter { $0.key >= midnight }
            cursor.sampledDays = cursor.sampledDays.filter { $0 >= midnight }
            cursors[file.path] = cursor
            guard cursor.offset < size else { continue }
            guard bytesReadLastCycle < byteBudget, ProcessInfo.processInfo.systemUptime < deadline,
                  let handle = try? FileHandle(forReadingFrom: file) else { catchingUp = true; continue }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: cursor.offset)
                while cursor.offset < size, bytesReadLastCycle < byteBudget,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    let count = min(64 * 1024, byteBudget - bytesReadLastCycle, Int(size - cursor.offset))
                    guard let data = try handle.read(upToCount: count), !data.isEmpty else { break }
                    bytesReadLastCycle += data.count
                    cursor.offset += UInt64(data.count)
                    for byte in data {
                        if byte == 10 {
                            if !cursor.droppingOversizedLine { consume(cursor.pending, cursor: cursor, midnight: midnight) }
                            cursor.pending.removeAll(keepingCapacity: true)
                            cursor.droppingOversizedLine = false
                        } else if !cursor.droppingOversizedLine {
                            if cursor.pending.count < 1024 * 1024 { cursor.pending.append(byte) }
                            else { cursor.pending.removeAll(keepingCapacity: true); cursor.droppingOversizedLine = true }
                        }
                    }
                }
            } catch { catchingUp = true }
            if cursor.offset < size { catchingUp = true }
        }
        var total: UInt64 = 0
        var hasSample = false
        var latest: Quota?
        for cursor in cursors.values {
            total = min(UInt64(UInt32.max), total + (cursor.daily[midnight] ?? 0))
            hasSample = hasSample || cursor.sampledDays.contains(midnight)
            if let q = cursor.quota, latest == nil || q.timestamp > latest!.timestamp { latest = q }
        }
        let age = latest.map { max(0, now.timeIntervalSince($0.timestamp)) } ?? 86_400
        var resetMinutes: UInt32?
        if let reset = latest?.reset {
            let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: reset))
            if let hour = parts.hour, let minute = parts.minute { resetMinutes = UInt32(hour * 60 + minute) }
        }
        return CodexMetrics(usedPercent: age <= 900 && (latest?.reset ?? .greatestFiniteMagnitude) > now.timeIntervalSince1970 ? latest?.used : nil,
                            weekUsedPercent: age <= 900 ? latest?.weekly : nil,
                            // Never send an incomplete catch-up total as a completed daily sum.
                            totalTokens: !catchingUp && hasSample ? UInt32(total) : nil,
                            resetInMinutes: resetMinutes,
                            updatedAt: UInt32(max(0, min(Double(UInt32.max), now.timeIntervalSince1970))),
                            quotaAgeSeconds: UInt32(min(86_400, age)))
    }

    private func consume(_ line: Data, cursor: Cursor, midnight: Date) {
        // Most session lines contain conversation content, not metrics: don't parse them.
        guard line.range(of: Data("\"token_count\"".utf8)) != nil || line.range(of: Data("\"rate_limits\"".utf8)) != nil,
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let stamp = json["timestamp"] as? String,
              let timestamp = fractional.date(from: stamp) ?? plain.date(from: stamp) else { return }
        if payload["type"] as? String == "token_count",
           let info = payload["info"] as? [String: Any],
           let usage = info["total_token_usage"] as? [String: Any],
           let total = (usage["total_tokens"] as? NSNumber)?.uint64Value {
            if timestamp >= midnight {
                let day = calendar.startOfDay(for: timestamp)
                let increment: UInt64
                if let previous = cursor.previousTotal, total >= previous { increment = total - previous }
                else { increment = ((info["last_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber)?.uint64Value ?? 0 }
                cursor.daily[day] = min(UInt64(UInt32.max), (cursor.daily[day] ?? 0) + min(increment, UInt64(UInt32.max)))
                cursor.sampledDays.insert(day)
            }
            cursor.previousTotal = total
        }
        if cursor.quota == nil || timestamp > cursor.quota!.timestamp,
           let limits = payload["rate_limits"] as? [String: Any],
           let primary = limits["primary"] as? [String: Any],
           let used = percent(primary["used_percent"]) {
            let reset = (primary["resets_at"] as? NSNumber)?.doubleValue
            cursor.quota = Quota(timestamp: timestamp, used: used,
                weekly: percent((limits["secondary"] as? [String: Any])?["used_percent"]),
                reset: reset?.isFinite == true ? reset : nil)
        }
    }
    private func percent(_ value: Any?) -> Int? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
        return Int(min(100, max(0, number.rounded())))
    }
}
