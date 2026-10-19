import XCTest
@testable import ProspectorCodexMacOS

final class CPUTemperaturePolicyTests: XCTestCase {
    func testGenerationsDoNotReuseIntelOrOtherChipKeys() {
        XCTAssertTrue(CPUTemperaturePolicy.keys(for: "Apple M1 Max").contains("Tp09"))
        XCTAssertTrue(CPUTemperaturePolicy.keys(for: "Apple M2 Ultra").contains("Tp1h"))
        XCTAssertTrue(CPUTemperaturePolicy.keys(for: "Apple M3 Pro").contains("Tf04"))
        XCTAssertTrue(CPUTemperaturePolicy.keys(for: "Apple M4 Pro").contains("Te05"))
        XCTAssertTrue(CPUTemperaturePolicy.keys(for: "Apple M5").contains("Tp00"))
        XCTAssertFalse(CPUTemperaturePolicy.keys(for: "Apple M1").contains("TC0P"))
        XCTAssertTrue(CPUTemperaturePolicy.keys(for: "Apple M10").isEmpty)
        XCTAssertTrue(CPUTemperaturePolicy.keys(for: "Unknown").isEmpty)
    }
    func testDecoderRejectsMissingUnsupportedAndNonfinite() {
        XCTAssertEqual(CPUTemperaturePolicy.decode(type: 0x73703738, bytes: [0x3f, 0x80]), 635)
        XCTAssertEqual(CPUTemperaturePolicy.decode(type: 0x666c7420, bytes: [0, 0, 0x7e, 0x42]), 635)
        XCTAssertNil(CPUTemperaturePolicy.decode(type: 0x666c7420, bytes: []))
        XCTAssertNil(CPUTemperaturePolicy.decode(type: 0x666c7420, bytes: [0, 0, 0xc0, 0x7f]))
        XCTAssertNil(CPUTemperaturePolicy.decode(type: 0x666c7420, bytes: [0, 0, 0x80, 0x7f]))
        XCTAssertNil(CPUTemperaturePolicy.decode(type: 0x666c7420, bytes: [0, 0, 0, 0]))
        XCTAssertNil(CPUTemperaturePolicy.decode(type: 0, bytes: [1, 2, 3, 4]))
        XCTAssertEqual(CPUTemperaturePolicy.hottest([300, 750, 0, 1600]), 750)
        XCTAssertNil(CPUTemperaturePolicy.hottest([]))
    }
    func testHIDOnlyAcceptsNamedCPUSensors() {
        XCTAssertTrue(CPUTemperaturePolicy.isCPUHIDProduct("pACC MTR Temp Sensor0"))
        XCTAssertTrue(CPUTemperaturePolicy.isCPUHIDProduct("eACC MTR Temp Sensor1"))
        for name in ["GPU Die", "Battery", "Ambient", "PMU tdie1", "NAND", "Unknown"] {
            XCTAssertFalse(CPUTemperaturePolicy.isCPUHIDProduct(name), name)
        }
    }
}
