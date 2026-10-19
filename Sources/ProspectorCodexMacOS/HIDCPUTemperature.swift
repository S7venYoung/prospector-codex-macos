import Foundation
import CoreFoundation
import Darwin

// Optional IOKit HID temperature API. Resolve dynamically because these symbols
// are not part of the public SDK contract and may disappear or be denied.
enum HIDCPUTemperature {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias Match = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias Property = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias Event = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    static func read() -> Int? {
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        defer { dlclose(library) }
        guard let c = dlsym(library, "IOHIDEventSystemClientCreate"),
              let m = dlsym(library, "IOHIDEventSystemClientSetMatching"),
              let s = dlsym(library, "IOHIDEventSystemClientCopyServices"),
              let p = dlsym(library, "IOHIDServiceClientCopyProperty"),
              let e = dlsym(library, "IOHIDServiceClientCopyEvent"),
              let v = dlsym(library, "IOHIDEventGetFloatValue") else { return nil }
        let create = unsafeBitCast(c, to: Create.self), match = unsafeBitCast(m, to: Match.self)
        let copyServices = unsafeBitCast(s, to: Services.self), copyProperty = unsafeBitCast(p, to: Property.self)
        let copyEvent = unsafeBitCast(e, to: Event.self), floatValue = unsafeBitCast(v, to: FloatValue.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = match(client, matching)
        guard let services = copyServices(client)?.takeRetainedValue() else { return nil }
        var readings: [Int] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let pointer = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            guard let product = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  CPUTemperaturePolicy.isCPUHIDProduct(product),
                  let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }
            let temperature = floatValue(event, 15 << 16)
            if temperature.isFinite, temperature > 0, temperature <= 150 {
                readings.append(Int((temperature * 10).rounded()))
            }
        }
        return CPUTemperaturePolicy.hottest(readings)
    }
}
