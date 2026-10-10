import XCTest
@testable import ProspectorCodexMacOS

final class ScannerProtocolTests: XCTestCase {
    func testPartialAndUnknownMetrics() throws {
        let partial = CodexMetrics(usedPercent: nil, weekUsedPercent: 21,
                                  totalTokens: 1234, resetInMinutes: nil, updatedAt: 0)
        XCTAssertEqual(try ScannerProtocol.frame(partial, version: 2), "CODEX2 -1 1234 79\n")
        XCTAssertThrowsError(try ScannerProtocol.frame(partial, version: 1))
        let unknown = CodexMetrics(usedPercent: nil, weekUsedPercent: nil,
                                  totalTokens: nil, resetInMinutes: nil, updatedAt: 0)
        XCTAssertEqual(try ScannerProtocol.frame(unknown, version: 2), "CODEX2 -1 -1 -1\n")
        let quotaOnly = CodexMetrics(usedPercent: 20, weekUsedPercent: nil,
                                    totalTokens: nil, resetInMinutes: nil, updatedAt: 0)
        XCTAssertEqual(try ScannerProtocol.frame(quotaOnly, version: 2), "CODEX2 80 -1 -1\n")
    }

    func testKnownLegacyAndRealZero() throws {
        let known = CodexMetrics(usedPercent: 20, weekUsedPercent: 36,
                                totalTokens: 7_000_000, resetInMinutes: nil, updatedAt: 0)
        XCTAssertEqual(try ScannerProtocol.frame(known, version: 1), "CODEX 80 7000000 64\n")
        let zero = CodexMetrics(usedPercent: 100, weekUsedPercent: nil,
                               totalTokens: 0, resetInMinutes: nil, updatedAt: 0)
        XCTAssertEqual(try ScannerProtocol.frame(zero, version: 2), "CODEX2 0 0 -1\n")
        XCTAssertEqual(try ScannerProtocol.frame(zero, version: 1), "CODEX 0 0\n")
    }
}
