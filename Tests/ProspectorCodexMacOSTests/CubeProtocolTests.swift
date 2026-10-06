import XCTest
@testable import ProspectorCodexMacOS

final class CubeProtocolTests: XCTestCase {
    func testRemainingAndUnknownValues() {
        let known = CodexMetrics(usedPercent: 20, weekUsedPercent: 36, totalTokens: 7_000_000,
                                 resetInMinutes: nil, updatedAt: 0, quotaAgeSeconds: 5)
        XCTAssertEqual(CubeProtocol.frame(known), "CODEX2 80 64 7000000 5 120\n")
        let unknown = CodexMetrics(usedPercent: nil, weekUsedPercent: nil, totalTokens: nil,
                                   resetInMinutes: nil, updatedAt: 0)
        XCTAssertEqual(CubeProtocol.frame(unknown), "CODEX2 -1 -1 -1 86400 120\n")
    }

    func testReaderDoesNotDoubleCountCumulativeTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now)
        func event(_ total: Int, _ last: Int) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["timestamp": stamp, "payload": [
                "type": "token_count", "info": ["total_token_usage": ["total_tokens": total], "last_token_usage": ["total_tokens": last]],
                "rate_limits": ["primary": ["used_percent": 20.0, "resets_at": now.timeIntervalSince1970 + 3600], "secondary": ["used_percent": 36.0]]
            ]])
            return String(data: data, encoding: .utf8)!
        }
        try [event(100, 100), event(150, 50), event(150, 0)].joined(separator: "\n")
            .write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let metrics = CodexMetricsReader.read(root: root, now: now)
        XCTAssertEqual(metrics.totalTokens, 150)
        XCTAssertEqual(metrics.usedPercent, 20)
        XCTAssertEqual(metrics.weekUsedPercent, 36)
        let stale = CodexMetricsReader.read(root: root, now: now.addingTimeInterval(901))
        XCTAssertNil(stale.usedPercent)
        XCTAssertNil(stale.weekUsedPercent)
    }

    func testMissingLogsAreNotFullQuotaOrZeroTokens() {
        let metrics = CodexMetricsReader.read(root: URL(fileURLWithPath: "/nonexistent-cube-test-logs"))
        XCTAssertNil(metrics.usedPercent)
        XCTAssertNil(metrics.weekUsedPercent)
        XCTAssertNil(metrics.totalTokens)
    }
}
