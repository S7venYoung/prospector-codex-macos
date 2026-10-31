import Foundation
import XCTest
@testable import ProspectorCodexMacOS

final class KeyboardDashboardTests: XCTestCase {
    func testCubeHostFrameUsesTheSameKeyboardPayload() {
        let metrics = CodexMetrics(usedPercent: 18, weekUsedPercent: 36, totalTokens: nil,
            resetInMinutes: 155, updatedAt: 1, quotaAgeSeconds: 0)
        let system = SystemMetrics(cpuPercent: 24, ramPercent: 70,
            usedBytes: 179 * 64 * 1024 * 1024, totalBytes: 16 * 1024 * 1024 * 1024,
            cpuTemperatureDeciC: 635)
        XCTAssertEqual(CubeProtocol.hostFrame(metrics, system: system, sequence: 1),
                       "HOST1 011f0118465240007b02b300000100000000\n")
        let missing = CubeProtocol.hostFrame(metrics, system: SystemMetrics(), sequence: 0)
        XCTAssertTrue(missing.hasPrefix("HOST1 011800"))
        XCTAssertEqual(missing.count, 43)
    }
    func testRemainingQuotaAndCPUTemperatureAreIndependent() {
        let metrics = CodexMetrics(usedPercent: 18, weekUsedPercent: 36, totalTokens: nil,
            resetInMinutes: 155, updatedAt: 1, quotaAgeSeconds: 0)
        let system = SystemMetrics(cpuPercent: 24, ramPercent: 70,
            usedBytes: 179 * 64 * 1024 * 1024, totalBytes: 16 * 1024 * 1024 * 1024,
            cpuTemperatureDeciC: 635)
        let p = KeyboardDashboard.payload(metrics, system: system, sequence: 1)
        XCTAssertEqual(p, [1, 31, 1, 24, 70, 82, 64, 0, 0x7b, 2, 179, 0, 0, 1, 0, 0, 0, 0])
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
    func testResetUsesLocalClockInsteadOfCountdown() {
        let reset = UInt32(ISO8601DateFormatter().date(from: "2026-10-31T11:20:00Z")!.timeIntervalSince1970)
        let metrics = CodexMetrics(usedPercent: 18, weekUsedPercent: nil, totalTokens: nil,
            resetInMinutes: 155, updatedAt: 1, quotaAgeSeconds: 0, primaryResetAt: reset)
        for (offset, minutes) in [(28800, UInt32(1160)), (-25200, UInt32(260))] {
            let p = KeyboardDashboard.payload(metrics, system: SystemMetrics(), sequence: 1,
                timeZone: TimeZone(secondsFromGMT: offset)!)
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(p[14+$1]) << ($1*8) }
            XCTAssertEqual(value, 0x80000000 | minutes)
            XCTAssertNotEqual(p[1] & 32, 0)
        }
    }

}
