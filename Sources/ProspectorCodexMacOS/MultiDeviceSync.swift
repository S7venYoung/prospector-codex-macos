import Foundation

enum SyncDevice: CaseIterable, Equatable {
    case cube, prospector
}

enum MultiDeviceSync {
    // A failure is scoped to its device. Both use the same quota snapshot.
    static func run(cubeEnabled: Bool, prospectorEnabled: Bool,
                    cube: () throws -> String, prospector: () throws -> String,
                    report: (SyncDevice, Result<String, Error>) -> Void) {
        for device in SyncDevice.allCases {
            let enabled = device == .cube ? cubeEnabled : prospectorEnabled
            guard enabled else { continue }
            do {
                let connection: String
                if device == .cube { connection = try cube() }
                else { connection = try prospector() }
                report(device, .success(connection))
            } catch {
                report(device, .failure(error))
            }
        }
    }
}

enum SerialDeviceRouting {
    static func candidates(for device: SyncDevice, selected: String,
                           available: [String], excluding: Set<String>) throws -> [String] {
        let selected = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty {
            guard selected.hasPrefix("/dev/cu.") else {
                throw BridgeError.serial("串口路径必须以 /dev/cu. 开头")
            }
            guard !excluding.contains(selected) else {
                throw BridgeError.serial("两台设备不能使用同一个串口，请分别选择")
            }
            return [selected]
        }
        return available.filter { path in
            let name = path.lowercased()
            return path.hasPrefix("/dev/cu.") && !excluding.contains(path) &&
                (name.contains("usbserial") || name.contains("usbmodem") || name.contains("wchusb"))
        }.sorted { lhs, rhs in
            func rank(_ path: String) -> Int {
                let name = path.lowercased()
                if device == .cube { return name.contains("usbmodem") ? 1 : 0 }
                if name.contains("prospector") || name.contains("usbmodem11304") { return 0 }
                return name.contains("usbmodem") ? 1 : 2
            }
            return rank(lhs) == rank(rhs) ? lhs < rhs : rank(lhs) < rank(rhs)
        }
    }

    static func availablePorts() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).map { "/dev/" + $0 }
    }
}
