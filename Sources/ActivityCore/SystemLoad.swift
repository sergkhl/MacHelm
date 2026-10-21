import Darwin
import Foundation
import IOKit

// What the whole Mac has used, read without root (Q34). CPU ticks and disk
// bytes count up from boot; the others are levels. nil where this Mac does
// not say, as a Mac without a battery says nothing about its power.
public protocol SystemTransport: Sendable {
    var cores: Int { get }
    // The ticks all cores spent working, and all their ticks.
    func cpuTicks() -> (busy: UInt64, all: UInt64)?
    // Memory in use as Activity Monitor counts it, and the Mac's memory.
    func memoryBytes() -> (used: UInt64, all: UInt64)?
    // Percent of the GPU in use.
    func gpuPercent() -> Double?
    // What the Mac draws, in watts.
    func powerWatts() -> Double?
    // Bytes read from every disk and written to it, together.
    func diskBytes() -> UInt64?
}

// The whole Mac now, beside each list's title.
public struct SystemLoad: Equatable, Sendable {
    // Percent of one core, as the rows read: every core at work is a hundred times the cores.
    public var cpuPercent: Double?
    public var cores: Int
    public var memoryUsedBytes: Double?
    public var memoryBytes: Double?
    public var gpuPercent: Double?
    public var powerWatts: Double?
    // Read and written, together.
    public var diskBytesPerSecond: Double?

    public init(cpuPercent: Double? = nil, cores: Int = 0, memoryUsedBytes: Double? = nil, memoryBytes: Double? = nil,
                gpuPercent: Double? = nil, powerWatts: Double? = nil, diskBytesPerSecond: Double? = nil) {
        self.cpuPercent = cpuPercent
        self.cores = cores
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryBytes = memoryBytes
        self.gpuPercent = gpuPercent
        self.powerWatts = powerWatts
        self.diskBytesPerSecond = diskBytesPerSecond
    }

    public func value(of measure: ActivityMeasure) -> Double? {
        switch measure {
        case .cpu: return cpuPercent
        case .memory: return memoryUsedBytes
        case .gpu: return gpuPercent
        case .energy: return powerWatts
        case .disk: return diskBytesPerSecond
        }
    }
}

// Reads the whole Mac at each pass. CPU and disk are what was used between
// the two latest readings; memory, GPU and power are as last read.
public struct SystemMeter: Sendable {
    // Readings closer together than this say too little: the figures of the one before stay.
    public static let shortest: TimeInterval = 0.5

    private struct Counters: Sendable {
        var uptime: TimeInterval
        var ticks: (busy: UInt64, all: UInt64)?
        var disk: UInt64?
    }

    private let transport: SystemTransport
    // The reading the next one counts from, and what the latest full one gave.
    private var before: Counters?
    private var cpuPercent: Double?
    private var diskBytesPerSecond: Double?

    public init(transport: SystemTransport) {
        self.transport = transport
    }

    public mutating func read(at uptime: TimeInterval) -> SystemLoad {
        let span = before.map { uptime - $0.uptime }
        if span.map({ $0 < 0 || $0 >= Self.shortest }) ?? true {
            let now = Counters(uptime: uptime, ticks: transport.cpuTicks(), disk: transport.diskBytes())
            cpuPercent = nil
            diskBytesPerSecond = nil
            // A counter that went back, as a disk's does when it is unplugged, gives no figure this once.
            if let before, let span, span > 0 {
                if let earlier = before.ticks, let later = now.ticks, later.all > earlier.all, later.busy >= earlier.busy {
                    cpuPercent = min(1, Double(later.busy - earlier.busy) / Double(later.all - earlier.all)) * 100
                        * Double(transport.cores)
                }
                if let earlier = before.disk, let later = now.disk, later >= earlier {
                    diskBytesPerSecond = Double(later - earlier) / span
                }
            }
            before = now
        }
        let memory = transport.memoryBytes()
        return SystemLoad(cpuPercent: cpuPercent, cores: transport.cores, memoryUsedBytes: memory.map { Double($0.used) },
                          memoryBytes: memory.map { Double($0.all) }, gpuPercent: transport.gpuPercent(),
                          powerWatts: transport.powerWatts(), diskBytesPerSecond: diskBytesPerSecond)
    }
}

// This Mac, through calls and IORegistry properties any user may read.
public struct DarwinSystemTransport: SystemTransport {
    public let cores: Int
    private let host: mach_port_t
    private let pageBytes: UInt64
    private let memory: UInt64

    public init() {
        cores = ProcessInfo.processInfo.activeProcessorCount
        host = mach_host_self()
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageBytes = UInt64(size)
        memory = ProcessInfo.processInfo.physicalMemory
    }

    public func cpuTicks() -> (busy: UInt64, all: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        // In the kernel's order: user, system, idle, nice.
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    // Memory Used as Activity Monitor counts it: app memory, wired and compressed.
    public func memoryBytes() -> (used: UInt64, all: UInt64)? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS, pageBytes > 0 else { return nil }
        let app = UInt64(info.internal_page_count) - min(UInt64(info.purgeable_count), UInt64(info.internal_page_count))
        return ((app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * pageBytes, memory)
    }

    // Undocumented, as the GPU's clients are (ADR 0002): the GPU says how much of it is in use.
    public func gpuPercent() -> Double? {
        var most: Double?
        Self.each("IOAccelerator") { entry in
            guard let statistics = Self.property("PerformanceStatistics", of: entry) as? [String: Any],
                  let used = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            most = max(most ?? 0, used)
        }
        return most
    }

    // What the Mac draws, in milliwatts, as its battery's telemetry gives it
    // on the power adapter as well. macOS refreshes it about once a minute
    // (measured on 2026-10-12). A Mac without a battery has none.
    public func powerWatts() -> Double? {
        var watts: Double?
        Self.each("AppleSmartBattery") { entry in
            guard let telemetry = Self.property("PowerTelemetryData", of: entry) as? [String: Any],
                  let milliwatts = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, milliwatts > 0 else { return }
            watts = milliwatts / 1_000
        }
        return watts
    }

    // Every disk's driver counts what it read and wrote since it appeared.
    public func diskBytes() -> UInt64? {
        var total: UInt64?
        Self.each("IOBlockStorageDriver") { entry in
            guard let statistics = Self.property("Statistics", of: entry) as? [String: Any] else { return }
            let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            total = (total ?? 0) &+ read &+ written
        }
        return total
    }

    private static func each(_ serviceClass: String, _ body: (io_registry_entry_t) -> Void) {
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &services) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(services) }
        while case let service = IOIteratorNext(services), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
