import XCTest
@testable import ProspectorCodexMacOS

final class ResetTimeTests: XCTestCase {
    func testAbsoluteTimeFrameAndLegacyCompatibility() {
        let metrics = CodexMetrics(usedPercent: 32, weekUsedPercent: 35, totalTokens: 68200000,
            resetInMinutes: nil, updatedAt: 0, quotaAgeSeconds: 2, primaryResetAt: 1577836800)
        XCTAssertEqual(CubeProtocol.frame(metrics), "CODEX2 68 65 68200000 2 120\n")
        XCTAssertEqual(CubeProtocol.frame(metrics, version: 3, timeZone: TimeZone(secondsFromGMT: 28800)!),
                       "CODEX3 68 65 68200000 2 120 1577836800 28800\n")
    }

    func testOfficialResetSurvivesMergeWithoutChangingDailyTokens() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let result: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 15,
            "windowDurationMins": 300, "resetsAt": 2_000_003_600]]]
        let snapshot = try XCTUnwrap(OfficialQuotaReader.Snapshot.parse(result, now: now))
        let logs = CodexMetrics(usedPercent: nil, weekUsedPercent: nil, totalTokens: 123,
                               resetInMinutes: nil, updatedAt: 0)
        let merged = snapshot.merging(logs, now: now)
        XCTAssertEqual(merged.primaryResetAt, 2_000_003_600)
        XCTAssertEqual(merged.totalTokens, 123)
        XCTAssertNil(snapshot.merging(logs, now: now.addingTimeInterval(3601)).primaryResetAt)
    }
}
