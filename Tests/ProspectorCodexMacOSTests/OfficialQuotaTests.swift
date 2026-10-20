import XCTest
@testable import ProspectorCodexMacOS

final class OfficialQuotaTests: XCTestCase {
    func testOfficialQuotaPreservesLocalDailyTokens() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let result = try JSONSerialization.jsonObject(with: Data("""
        {"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":15,"windowDurationMins":300,"resetsAt":2000003600},"secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":2000500000}}}}
        """.utf8)) as! [String: Any]
        let snapshot = try XCTUnwrap(OfficialQuotaReader.Snapshot.parse(result, now: now))
        let logs = CodexMetrics(usedPercent: nil, weekUsedPercent: nil, totalTokens: 123456,
                                resetInMinutes: nil, updatedAt: 2_000_000_000)
        let merged = snapshot.merging(logs, now: now.addingTimeInterval(60))
        XCTAssertEqual(merged.usedPercent, 15)
        XCTAssertEqual(merged.weekUsedPercent, 2)
        XCTAssertEqual(merged.totalTokens, 123456)
        XCTAssertEqual(merged.quotaAgeSeconds, 60)
        XCTAssertNil(snapshot.merging(logs, now: now.addingTimeInterval(901)).usedPercent)
    }

    func testUnknownWrongBucketAndExpiredWindowsStayUnknown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertNil(OfficialQuotaReader.Snapshot.parse([:], now: now))
        XCTAssertNil(OfficialQuotaReader.Snapshot.parse(["rateLimitsByLimitId": ["other": [:]]], now: now))
        let invalid: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 0,
            "windowDurationMins": 300, "resetsAt": 1]]]
        XCTAssertNil(OfficialQuotaReader.Snapshot.parse(invalid, now: now))
        let unknown: [String: Any] = ["rateLimits": ["primary": ["windowDurationMins": 300,
            "resetsAt": 2_000_003_600]]]
        XCTAssertNil(OfficialQuotaReader.Snapshot.parse(unknown, now: now))
    }
}
