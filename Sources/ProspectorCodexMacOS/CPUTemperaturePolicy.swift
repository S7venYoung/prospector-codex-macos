import Foundation

// CPU sensor identifiers are hardware facts, grouped by chip generation.
// Reference: exelban/stats Modules/Sensors/values.swift (CPU temperature entries).
// No GPU, battery, ambient, NAND, weather or unspecified SoC sensor keys.
enum CPUTemperaturePolicy {
    static func keys(for brand: String) -> [String] {
        let words = brand.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard words.first == "APPLE", words.count > 1 else {
            return words.contains(where: { $0.contains("INTEL") }) ? ["TC0D", "TC0P"] : []
        }
        switch words[1] {
        case "M1": return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
        case "M2": return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
        case "M3": return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
        case "M4": return ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        case "M5": return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        case "M6": return ["Tp0j", "Tp0g", "Tp09", "Tp07", "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05", "Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"]
        default: return [] // Never guess CPU sensor names for a new chip.
        }
    }

    static func decode(type: UInt32, bytes: [UInt8]) -> Int? {
        let value: Double
        switch type {
        case 0x73703738: // sp78: signed big-endian fixed-point 8.8
            guard bytes.count >= 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case 0x666c7420: // flt : native little-endian Float32
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            value = Double(Float(bitPattern: bits))
        default: return nil
        }
        guard value.isFinite, value > 0, value <= 150 else { return nil }
        return Int((value * 10).rounded())
    }

    static func isCPUHIDProduct(_ product: String) -> Bool {
        let name = product.lowercased()
        // CPU efficiency/performance accelerator thermal sensors. Reject
        // ambiguous PMU die names and all GPU/battery/ambient sensors.
        return name.hasPrefix("pacc ") || name.hasPrefix("eacc ") || name.hasPrefix("cpu ")
    }

    static func hottest(_ values: [Int]) -> Int? {
        values.filter { $0 > 0 && $0 <= 1500 }.max()
    }
}
