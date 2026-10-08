import XCTest
@testable import ProspectorCodexMacOS

final class IncrementalMetricsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func event(_ now: Date, total: Int, last: Int, used: Int = 20) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": formatter.string(from: now), "payload": [
            "type": "token_count", "info": ["total_token_usage": ["total_tokens": total], "last_token_usage": ["total_tokens": last]],
            "rate_limits": ["primary": ["used_percent": used, "resets_at": now.timeIntervalSince1970 + 3600], "secondary": ["used_percent": 36]]
        ]])
        data.append(10)
        return data
    }
    func testAppendOnlyAndUnchangedReadZeroBytes() throws {
        let root = try directory(), file = root.appendingPathComponent("session.jsonl"), now = Date()
        try event(now, total: 100, last: 100).write(to: file)
        let reader = IncrementalMetricsReader(root: root)
        XCTAssertEqual(reader.read(now: now).totalTokens, 100)
        XCTAssertEqual(reader.read(now: now).totalTokens, 100)
        XCTAssertEqual(reader.bytesReadLastCycle, 0)
        let delta = try event(now.addingTimeInterval(1), total: 150, last: 50, used: 25)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: delta); try handle.close()
        let metrics = reader.read(now: now.addingTimeInterval(2))
        XCTAssertEqual(metrics.totalTokens, 150)
        XCTAssertEqual(metrics.usedPercent, 25)
        XCTAssertEqual(reader.bytesReadLastCycle, delta.count)
    }
    func testSplitLineIsCountedOnce() throws {
        let root = try directory(), file = root.appendingPathComponent("session.jsonl"), now = Date()
        let data = try event(now, total: 123, last: 123)
        try data.prefix(data.count / 2).write(to: file)
        let reader = IncrementalMetricsReader(root: root)
        XCTAssertNil(reader.read(now: now).totalTokens)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: data.suffix(data.count - data.count / 2)); try handle.close()
        XCTAssertEqual(reader.read(now: now).totalTokens, 123)
        XCTAssertEqual(reader.read(now: now).totalTokens, 123)
    }
    func testBudgetDoesNotPublishPartialTotal() throws {
        let root = try directory(), file = root.appendingPathComponent("session.jsonl"), now = Date()
        let data = try event(now, total: 100, last: 100) + event(now, total: 150, last: 50)
        try data.write(to: file)
        let reader = IncrementalMetricsReader(root: root, byteBudget: 64, timeBudget: 1)
        XCTAssertNil(reader.read(now: now).totalTokens)
        XCTAssertTrue(reader.catchingUp)
        XCTAssertLessThanOrEqual(reader.bytesReadLastCycle, 64)
        var metrics = reader.read(now: now)
        for _ in 0..<20 where reader.catchingUp { metrics = reader.read(now: now) }
        XCTAssertEqual(metrics.totalTokens, 150)
    }
    func testReplacementAndDeletionInvalidateCache() throws {
        let root = try directory(), file = root.appendingPathComponent("session.jsonl"), now = Date()
        try event(now, total: 900, last: 900).write(to: file)
        let reader = IncrementalMetricsReader(root: root)
        XCTAssertEqual(reader.read(now: now).totalTokens, 900)
        try event(now, total: 20, last: 20).write(to: file, options: .atomic)
        XCTAssertEqual(reader.read(now: now).totalTokens, 20)
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(reader.read(now: now).totalTokens)
        XCTAssertNil(reader.read(now: now).usedPercent)
    }
    func testOldConversationLogsAreSkipped() throws {
        let root = try directory(), file = root.appendingPathComponent("old.jsonl"), now = Date()
        try Data(repeating: 32, count: 2 * 1024 * 1024).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-172800)], ofItemAtPath: file.path)
        let reader = IncrementalMetricsReader(root: root)
        XCTAssertNil(reader.read(now: now).totalTokens)
        XCTAssertEqual(reader.bytesReadLastCycle, 0)
    }
    func testMidnightKeepsCumulativeBaseline() throws {
        let root = try directory(), file = root.appendingPathComponent("session.jsonl")
        let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86400)
        try event(midnight.addingTimeInterval(-1), total: 100, last: 100).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: midnight.addingTimeInterval(-1)], ofItemAtPath: file.path)
        let reader = IncrementalMetricsReader(root: root)
        XCTAssertEqual(reader.read(now: midnight.addingTimeInterval(-1)).totalTokens, 100)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: event(midnight.addingTimeInterval(1), total: 150, last: 50)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: midnight.addingTimeInterval(1)], ofItemAtPath: file.path)
        XCTAssertEqual(reader.read(now: midnight.addingTimeInterval(2)).totalTokens, 50)
    }
}
