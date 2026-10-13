// Read-only private HID temperature API, based on the pinned Stats bridge and
// its recognized MTR sensor names. See ThirdPartyNotices.txt.
import Foundation
import Darwin
#if canImport(FanControlCore)
import FanControlCore
#endif

public struct FanHIDChannelSummary: Codable {
    public let product: String
    public let recognizedGroup: FanSensorGroup?
    public let temperature: Double?
    public let ageSeconds: Double?
}

public enum FanHIDDiagnostics {
    public static func readOnlyInventory() throws -> [FanHIDChannelSummary] {
        try HIDThermalSource().inventory()
    }
}

public enum FanHIDSensorMap {
    public static func group(for name: String) -> FanSensorGroup? {
        for (prefix, group) in [("pACC MTR Temp Sensor", FanSensorGroup.performance),
                                ("eACC MTR Temp Sensor", .efficiency), ("GPU MTR Temp Sensor", .gpu)] {
            guard name.hasPrefix(prefix) else { continue }
            let suffix = name.dropFirst(prefix.count)
            guard !suffix.isEmpty, suffix.count <= 2, suffix.allSatisfy(\.isNumber),
                  let number = Int(suffix), (0..<64).contains(number), String(number) == suffix else { return nil }
            return group
        }
        return nil
    }
}

final class HIDThermalSource {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias Match = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias Property = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias Event = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double
    private typealias Timestamp = @convention(c) (CFTypeRef) -> UInt64
    private let client: CFTypeRef
    private let services: Services
    private let property: Property
    private let event: Event
    private let floatValue: FloatValue
    private let timestamp: Timestamp
    private let timebase: Double
    private let library: UnsafeMutableRawPointer

    init() throws {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL) else {
            throw FanControlError.unavailable("HID temperature framework is unavailable.")
        }
        library = handle
        do {
            func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
                guard let address = dlsym(handle, name) else {
                    throw FanControlError.unavailable("Required read-only HID API is missing: \(name).")
                }
                return unsafeBitCast(address, to: type)
            }
            let create = try symbol("IOHIDEventSystemClientCreate", Create.self)
            let match = try symbol("IOHIDEventSystemClientSetMatching", Match.self)
            services = try symbol("IOHIDEventSystemClientCopyServices", Services.self)
            property = try symbol("IOHIDServiceClientCopyProperty", Property.self)
            event = try symbol("IOHIDServiceClientCopyEvent", Event.self)
            floatValue = try symbol("IOHIDEventGetFloatValue", FloatValue.self)
            timestamp = try symbol("IOHIDEventGetTimeStamp", Timestamp.self)
            guard let created = create(kCFAllocatorDefault)?.takeRetainedValue() else {
                throw FanControlError.unavailable("Cannot create a read-only HID thermal client.")
            }
            client = created
            _ = match(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
            var info = mach_timebase_info_data_t()
            guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
                throw FanControlError.unavailable("Cannot establish HID event freshness.")
            }
            timebase = Double(info.numer) / Double(info.denom) / 1_000_000_000
        } catch { dlclose(handle); throw error }
    }

    deinit { dlclose(library) }

    func inventory() throws -> [FanHIDChannelSummary] {
        guard let array = services(client)?.takeRetainedValue(), CFArrayGetCount(array) <= 1024 else {
            throw FanControlError.unavailable("HID thermal inventory is unavailable.")
        }
        var result: [FanHIDChannelSummary] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            let service = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard let name = property(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  name.count <= 128 else { continue }
            let sample = event(service, 15, 0, 0)?.takeRetainedValue()
            let value = sample.map { floatValue($0, 15 << 16) }
            let age = sample.map { ProcessInfo.processInfo.systemUptime - Double(timestamp($0)) * timebase }
            result.append(FanHIDChannelSummary(product: name, recognizedGroup: FanHIDSensorMap.group(for: name),
                                               temperature: value?.isFinite == true ? value : nil,
                                               ageSeconds: age?.isFinite == true ? age : nil))
        }
        return result.sorted { $0.product < $1.product }
    }

}
