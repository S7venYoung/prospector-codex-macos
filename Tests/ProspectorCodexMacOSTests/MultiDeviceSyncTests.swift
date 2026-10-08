import XCTest
@testable import ProspectorCodexMacOS

final class MultiDeviceSyncTests: XCTestCase {
    func testBothDevicesReceiveOneRound() {
        var calls: [String] = []
        var results: [SyncDevice] = []
        MultiDeviceSync.run(cubeEnabled: true, prospectorEnabled: true,
            cube: { calls.append("cube"); return "USB + Wi-Fi" },
            prospector: { calls.append("scanner"); return "USB" },
            report: { device, _ in results.append(device) })
        XCTAssertEqual(calls, ["cube", "scanner"])
        XCTAssertEqual(results, [.cube, .prospector])
    }

    func testFailureDoesNotSuppressOtherDevice() {
        for failing in SyncDevice.allCases {
            var successes: [SyncDevice] = []
            var failures: [SyncDevice] = []
            MultiDeviceSync.run(cubeEnabled: true, prospectorEnabled: true,
                cube: { if failing == .cube { throw BridgeError.noReceiver }; return "USB" },
                prospector: { if failing == .prospector { throw BridgeError.noReceiver }; return "USB" },
                report: { device, result in
                    if case .success = result { successes.append(device) }
                    else { failures.append(device) }
                })
            XCTAssertEqual(failures, [failing])
            XCTAssertEqual(successes.count, 1)
        }
    }

    func testDisabledDeviceIsNotContacted() {
        MultiDeviceSync.run(cubeEnabled: false, prospectorEnabled: true,
            cube: { XCTFail("disabled Cube contacted"); return "" },
            prospector: { "USB" }, report: { device, _ in XCTAssertEqual(device, .prospector) })
    }

    func testPortsRemainSeparate() throws {
        let cube = "/dev/cu.wchusbserial1"
        let scanner = "/dev/cu.usbmodem11304"
        let ports = [scanner, cube, "/dev/cu.Bluetooth-Incoming-Port"]
        XCTAssertEqual(try SerialDeviceRouting.candidates(for: .cube, selected: "", available: ports, excluding: [scanner]), [cube])
        XCTAssertEqual(try SerialDeviceRouting.candidates(for: .prospector, selected: "", available: ports, excluding: [cube]), [scanner])
        XCTAssertThrowsError(try SerialDeviceRouting.candidates(for: .cube, selected: scanner, available: ports, excluding: [scanner]))
        XCTAssertThrowsError(try SerialDeviceRouting.candidates(for: .prospector, selected: "/dev/tty.foo", available: ports, excluding: []))
    }

    func testAutomaticPortPreferenceAndManualSelection() throws {
        let ports = ["/dev/cu.usbmodem11304", "/dev/cu.usbserialABC"]
        XCTAssertEqual(try SerialDeviceRouting.candidates(for: .cube, selected: "", available: ports, excluding: []).first, ports[1])
        XCTAssertEqual(try SerialDeviceRouting.candidates(for: .prospector, selected: "", available: ports, excluding: []).first, ports[0])
        XCTAssertEqual(try SerialDeviceRouting.candidates(for: .prospector, selected: "  \(ports[1])\n", available: ports, excluding: []), [ports[1]])
    }
}
