import Darwin
import Foundation
import IOKit

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

public struct ProcessShortInfo: Equatable, Sendable {
    public var parent: Int32
    public var userID: UInt32
    // At most 15 characters; the executable's file name is preferred.
    public var name: String

    public init(parent: Int32, userID: UInt32, name: String) {
        self.parent = parent
        self.userID = userID
        self.name = name
    }
}

public struct ProcessUsage: Equatable, Sendable {
    // Mach absolute time.
    public var startedAt: UInt64
    // User and system time together, in Mach absolute time units.
    public var cpuTime: UInt64
    public var energyNanojoules: UInt64
    // The figure Activity Monitor shows as Memory.
    public var footprintBytes: UInt64
    // Bytes read from disk and written to it, together.
    public var diskBytes: UInt64

    public init(startedAt: UInt64, cpuTime: UInt64, energyNanojoules: UInt64, footprintBytes: UInt64, diskBytes: UInt64 = 0) {
        self.startedAt = startedAt
        self.cpuTime = cpuTime
        self.energyNanojoules = energyNanojoules
        self.footprintBytes = footprintBytes
        self.diskBytes = diskBytes
    }
}

// One connection of a process to the GPU, with the GPU time it has used.
public struct GPUClient: Equatable, Sendable {
    public var id: UInt64
    // As the IORegistry words it: "pid 425, WindowServer".
    public var creator: String
    public var nanoseconds: UInt64

    public init(id: UInt64, creator: String, nanoseconds: UInt64) {
        self.id = id
        self.creator = creator
        self.nanoseconds = nanoseconds
    }
}

// Where the reader's data comes from. Everything here works without root
// (ADR 0002); a privileged source would be another conformance.
public protocol ProcessTransport: Sendable {
    var userID: UInt32 { get }
    // Mach absolute time units to nanoseconds.
    var timebase: (numerator: UInt32, denominator: UInt32) { get }
    func processIDs() -> [Int32]
    func shortInfo(of pid: Int32) -> ProcessShortInfo?
    // nil for a process that refuses, as every system process does, and for one that has ended.
    func usage(of pid: Int32) -> ProcessUsage?
    func executablePath(of pid: Int32) -> String?
    func arguments(of pid: Int32) -> [String]?
    // The process macOS holds responsible for this one, as Activity Monitor
    // shows it. nil where macOS does not say, as for every system process.
    func responsibleProcess(of pid: Int32) -> Int32?
    // Whether two paths name one file, as the two names of a hard-linked program do.
    func sameFile(_ first: String, _ second: String) -> Bool
    // Lines of "pid uid ppid time command" for every process, from `ps`.
    func systemListing() -> String?
    // nil when the GPU's clients cannot be read.
    func gpuClients() -> [GPUClient]?
}

public protocol ProcessSignalTransport: Sendable {
    // Mach absolute time; nil when the process has ended or refuses.
    func startTime(of pid: Int32) -> UInt64?
    func send(_ signal: Int32, to pid: Int32) -> Bool
}

// What a command wrote, handed from the thread that read it.
private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    func set(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes = data
    }
}

public struct DarwinProcessTransport: ProcessTransport, ProcessSignalTransport {
    public let userID: UInt32
    public let timebase: (numerator: UInt32, denominator: UInt32)

    public init() {
        userID = getuid()
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (info.numer, max(info.denom, 1))
    }

    public func processIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes that start between the two calls.
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    public func shortInfo(of pid: Int32) -> ProcessShortInfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: &info.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ProcessShortInfo(parent: Int32(bitPattern: info.pbsi_ppid), userID: info.pbsi_uid, name: name)
    }

    public func usage(of pid: Int32) -> ProcessUsage? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard result == 0 else { return nil }
        return ProcessUsage(startedAt: info.ri_proc_start_abstime, cpuTime: info.ri_user_time &+ info.ri_system_time,
                            energyNanojoules: info.ri_energy_nj, footprintBytes: info.ri_phys_footprint,
                            diskBytes: info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten)
    }

    public func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // A private call, like the GPU's registry properties (ADR 0002). It is
    // what Activity Monitor groups by.
    public func responsibleProcess(of pid: Int32) -> Int32? {
        let responsible = responsibility_get_pid_responsible_for_pid(pid)
        return responsible > 0 ? responsible : nil
    }

    public func sameFile(_ first: String, _ second: String) -> Bool {
        var one = stat(), other = stat()
        guard stat(first, &one) == 0, stat(second, &other) == 0 else { return false }
        return one.st_dev == other.st_dev && one.st_ino == other.st_ino
    }

    public func arguments(of pid: Int32) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return Self.arguments(inProcArgs: Array(buffer.prefix(size)))
    }

    // The kernel's layout: the argument count, the executable's path, padding
    // of zero bytes, then the arguments, each ending in a zero byte.
    static func arguments(inProcArgs bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard count > 0 else { return [] }
        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < bytes.count {
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.count
            arguments.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }

    public func systemListing() -> String? {
        Self.run("/bin/ps", ["-Ao", "pid=,uid=,ppid=,time=,comm="], limit: 2)
    }

    // Runs a command and returns what it wrote. One that takes longer than
    // the limit is ended, so a `ps` that hangs cannot hold the reader for good.
    static func run(_ path: String, _ arguments: [String], limit: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read while it runs, so a full pipe cannot hold the command back.
        let written = ProcessOutput()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            written.set(output.fileHandleForReading.readDataToEndOfFile())
            finished.signal()
        }
        guard finished.wait(timeout: .now() + limit) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: written.data, as: UTF8.self)
    }

    // Undocumented IORegistry properties (ADR 0002): every user client of the
    // GPU names its process and carries the GPU time it has accumulated.
    public func gpuClients() -> [GPUClient]? {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(accelerators) }
        var clients: [GPUClient] = []
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(child, &id) == KERN_SUCCESS,
                      let creator = Self.property("IOUserClientCreator", of: child) as? String,
                      let usage = Self.property("AppUsage", of: child) as? [[String: Any]] else { continue }
                let time = usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                clients.append(GPUClient(id: id, creator: creator, nanoseconds: time))
            }
        }
        return clients
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    public func startTime(of pid: Int32) -> UInt64? {
        usage(of: pid)?.startedAt
    }

    public func send(_ signal: Int32, to pid: Int32) -> Bool {
        kill(pid, signal) == 0
    }
}
