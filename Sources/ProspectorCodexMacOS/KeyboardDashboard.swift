import Foundation
import Darwin
import IOKit

struct SystemMetrics {
    var cpuPercent: Int?
    var ramPercent: Int?
    var usedBytes: UInt64?
    var totalBytes: UInt64?
    var cpuTemperatureDeciC: Int?
}

enum KeyboardDashboard {
    static func payload(_ metrics: CodexMetrics, system: SystemMetrics, sequence: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 18)
        p[0] = 1; p[2] = sequence
        if let cpu = system.cpuPercent, (0...100).contains(cpu) { p[1] |= 1; p[3] = UInt8(cpu) }
        let unit: UInt64 = 64 * 1024 * 1024
        if let ram = system.ramPercent, (0...100).contains(ram), let used = system.usedBytes,
           let total = system.totalBytes, total >= unit, used <= total,
           total / unit <= UInt64(UInt16.max) {
            p[1] |= 2; p[4] = UInt8(ram)
            put16(UInt16(used / unit), in: &p, at: 10)
            put16(UInt16(total / unit), in: &p, at: 12)
        }
        if let temp = system.cpuTemperatureDeciC, (-500...1500).contains(temp) {
            p[1] |= 4; put16(UInt16(bitPattern: Int16(temp)), in: &p, at: 8)
        }
        if metrics.quotaAgeSeconds <= 900 {
            if let used = metrics.usedPercent, (0...100).contains(used) { p[1] |= 8; p[5] = UInt8(100 - used) }
            if let used = metrics.weekUsedPercent, (0...100).contains(used) { p[1] |= 16; p[6] = UInt8(100 - used) }
            if metrics.usedPercent != nil, let minutes = metrics.resetInMinutes {
                p[1] |= 32
                let seconds = UInt32(min(UInt64(UInt32.max), UInt64(minutes) * 60))
                for i in 0..<4 { p[14+i] = UInt8(truncatingIfNeeded: seconds >> (i*8)) }
            }
        }
        return p
    }
    private static func put16(_ value: UInt16, in p: inout [UInt8], at offset: Int) {
        p[offset] = UInt8(truncatingIfNeeded: value); p[offset+1] = UInt8(value >> 8)
    }
}

enum SystemMetricsReader {
    private static let lock = NSLock()
    private static var previous: (UInt32, UInt32, UInt32, UInt32)?
    static func read() -> SystemMetrics {
        lock.lock(); defer { lock.unlock() }
        var result = SystemMetrics()
        var cpu = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &cpu) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let current = cpu.cpu_ticks
            if let old = previous {
                let deltas = [current.0 &- old.0, current.1 &- old.1, current.2 &- old.2, current.3 &- old.3]
                let total = deltas.reduce(UInt64(0)) { $0 + UInt64($1) }
                if total > 0 { result.cpuPercent = Int((total - UInt64(deltas[Int(CPU_STATE_IDLE)])) * 100 / total) }
            }
            previous = current
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let vmStatus = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmStatus == KERN_SUCCESS {
            let total = ProcessInfo.processInfo.physicalMemory
            let pageSize = UInt64(max(1, sysconf(_SC_PAGESIZE)))
            let used = min(total, (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * pageSize)
            result.usedBytes = used; result.totalBytes = total
            if total > 0 { result.ramPercent = Int(used * 100 / total) }
        }
        result.cpuTemperatureDeciC = CPUTemperatureReader.read()
        return result
    }
}

// AppleSMC availability and CPU key names vary by Mac. No weather/GPU/battery
// temperature fallback, shell command, sudo, or invented temperature is used.
enum CPUTemperatureReader {
    static func read() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }
        let configured = UserDefaults.standard.string(forKey: "prospector.cpuTemperatureSMCKey")
        let keys = configured.map { [$0] } ?? ["TC0D", "TC0P"]
        for key in keys {
            guard key.utf8.count == 4, let info = call(connection, key: key, command: 9),
                  read32(info, 28) > 0, read32(info, 28) <= 32,
                  let bytes = call(connection, key: key, command: 5, info: info) else { continue }
            let type = read32(info, 32)
            let value: Double
            if type == fourCC("sp78") {
                value = Double(Int16(bitPattern: UInt16(bytes[48]) << 8 | UInt16(bytes[49]))) / 256
            } else if type == fourCC("flt ") {
                // AppleSMC flt CPU sensors return a native little-endian float.
                value = Double(Float(bitPattern: read32(bytes, 48)))
            } else { continue }
            if value.isFinite, value > 0, value <= 150 { return Int((value * 10).rounded()) }
        }
        return nil
    }
    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
    }
    private static func call(_ connection: io_connect_t, key: String, command: UInt8, info: [UInt8]? = nil) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: 80), output = input
        let code = fourCC(key)
        for i in 0..<4 { input[i] = UInt8(truncatingIfNeeded: code >> (8*i)) }
        if let info { input.replaceSubrange(28..<40, with: info[28..<40]) }
        input[42] = command
        var size = 80
        let status = input.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                IOConnectCallStructMethod(connection, 2, src.baseAddress, 80, dst.baseAddress, &size)
            }
        }
        guard status == KERN_SUCCESS, size == 80, output[40] == 0 else { return nil }
        return output
    }
}
