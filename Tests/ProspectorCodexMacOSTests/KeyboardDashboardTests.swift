import XCTest
@testable import ProspectorCodexMacOS

final class KeyboardDashboardTests: XCTestCase {
    func testRemainingQuotaAndCPUTemperatureAreIndependent() {
        let metrics = CodexMetrics(usedPercent: 18, weekUsedPercent: 36, totalTokens: nil,
            resetInMinutes: 155, updatedAt: 1, quotaAgeSeconds: 0)
        let system = SystemMetrics(cpuPercent: 24, ramPercent: 70,
            usedBytes: 179 * 64 * 1024 * 1024, totalBytes: 16 * 1024 * 1024 * 1024,
            cpuTemperatureDeciC: 635)
        let p = KeyboardDashboard.payload(metrics, system: system, sequence: 1)
        XCTAssertEqual(p, [1, 63, 1, 24, 70, 82, 64, 0, 0x7b, 2, 179, 0, 0, 1, 0x54, 0x24, 0, 0])
    }
    func testMissingAndStaleDataStayUnknown() {
        let metrics = CodexMetrics(usedPercent: 0, weekUsedPercent: 0, totalTokens: nil,
            resetInMinutes: 2, updatedAt: 1, quotaAgeSeconds: 901)
        let p = KeyboardDashboard.payload(metrics, system: SystemMetrics(), sequence: 2)
        XCTAssertEqual(p[1], 0)
        XCTAssertEqual(p[2], 2)
    }
    func testZeroQuotaIsRealAndInvalidTemperatureRejected() {
        let metrics = CodexMetrics(usedPercent: 100, weekUsedPercent: nil, totalTokens: nil,
            resetInMinutes: nil, updatedAt: 1, quotaAgeSeconds: 0)
        let p = KeyboardDashboard.payload(metrics,
            system: SystemMetrics(cpuPercent: 0, cpuTemperatureDeciC: 2000), sequence: 255)
        XCTAssertEqual(p[1], 1 | 8)
        XCTAssertEqual(p[3], 0)
        XCTAssertEqual(p[5], 0)
    }
}
