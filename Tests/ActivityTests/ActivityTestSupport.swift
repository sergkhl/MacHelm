import XCTest
@testable import ActivityCore

// A process table that only answers. It counts the reads that cost
// something and records every signal it is asked to send.
final class FakeProcesses: ProcessTransport, ProcessSignalTransport, @unchecked Sendable {
    struct Entry {
        var parent: Int32 = 1
        var userID: UInt32 = 501
        var name = "tool"
        var path: String? = "/usr/local/bin/tool"
        var arguments: [String]?
        // nil refuses, as a system process does.
        var usage: ProcessUsage?
    }

    var userID: UInt32 = 501
    // One unit is one nanosecond unless a test says otherwise.
    var timebase: (numerator: UInt32, denominator: UInt32) = (1, 1)
    var table: [Int32: Entry] = [:]
    var listing: String? = ""
    var clients: [GPUClient]? = []
    var signalRefused = false
    // Paths that are names of one file, by any number they share.
    var files: [String: Int] = [:]
    private(set) var listingReads = 0
    private(set) var pathReads: [Int32] = []
    private(set) var argumentReads: [Int32] = []
    private(set) var signals: [String] = []

    func own(_ pid: Int32, path: String = "/usr/local/bin/tool", parent: Int32 = 1, startedAt: UInt64 = 1_000_000_000,
             cpu: Double = 0, energy: Double = 0, memory: UInt64 = 0, disk: UInt64 = 0, arguments: [String]? = nil) {
        table[pid] = Entry(parent: parent, name: String((path as NSString).lastPathComponent.prefix(15)), path: path,
                           arguments: arguments,
                           usage: ProcessUsage(startedAt: startedAt, cpuTime: UInt64(cpu * 1e9),
                                               energyNanojoules: UInt64(energy * 1e9), footprintBytes: memory, diskBytes: disk))
    }

    func system(_ pid: Int32, name: String, userID: UInt32 = 0) {
        table[pid] = Entry(userID: userID, name: name, path: nil, usage: nil)
    }

    func processIDs() -> [Int32] { table.keys.sorted() }

    func shortInfo(of pid: Int32) -> ProcessShortInfo? {
        table[pid].map { ProcessShortInfo(parent: $0.parent, userID: $0.userID, name: $0.name) }
    }

    func usage(of pid: Int32) -> ProcessUsage? { table[pid]?.usage }

    func executablePath(of pid: Int32) -> String? {
        pathReads.append(pid)
        return table[pid]?.path
    }

    func arguments(of pid: Int32) -> [String]? {
        argumentReads.append(pid)
        return table[pid]?.arguments
    }

    // The process macOS holds responsible, for those it names one for.
    var responsible: [Int32: Int32] = [:]

    func responsibleProcess(of pid: Int32) -> Int32? { responsible[pid] }

    func sameFile(_ first: String, _ second: String) -> Bool {
        guard let one = files[first], let other = files[second] else { return false }
        return one == other
    }

    func systemListing() -> String? {
        listingReads += 1
        return listing
    }

    func gpuClients() -> [GPUClient]? { clients }

    func startTime(of pid: Int32) -> UInt64? { table[pid]?.usage?.startedAt }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        signals.append("\(signal) \(pid)")
        return !signalRefused
    }
}

// Samples and passes written by hand, for the window and the ranking.
enum Sampled {
    static func identity(_ pid: Int32, started: TimeInterval = -100) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startedAt: UInt64((started + 1_000) * 1_000))
    }

    static func describe(_ pid: Int32, path: String = "/usr/local/bin/tool", parent: Int32 = 1, started: TimeInterval = -100,
                         wine: WineRole? = nil) -> ProcessDescription {
        ProcessDescription(identity: identity(pid, started: started), parent: parent, isOwn: true,
                           name: (path as NSString).lastPathComponent, executablePath: path, wine: wine, startedUptime: started)
    }

    static func describeSystem(_ pid: Int32, path: String, parent: Int32 = 1) -> ProcessDescription {
        ProcessDescription(identity: ProcessIdentity(pid: pid, startedAt: 0), parent: parent, isOwn: false,
                           name: (path as NSString).lastPathComponent, executablePath: path)
    }

    static func own(_ pid: Int32, cpu: Double, energy: Double = 0, memory: UInt64 = 0, started: TimeInterval = -100,
                    path: String = "/usr/local/bin/tool", disk: Double? = nil) -> ProcessSample {
        ProcessSample(description: describe(pid, path: path, started: started), cpuSeconds: cpu, energyJoules: energy, memoryBytes: memory,
                      diskBytes: disk)
    }

    static func system(_ pid: Int32, cpu: Double, path: String = "/usr/sbin/daemon") -> ProcessSample {
        ProcessSample(description: describeSystem(pid, path: path), cpuSeconds: cpu)
    }
}

extension ActivityAverages {
    func process(_ pid: Int32) -> ProcessAverage? {
        processes.first { $0.description.identity.pid == pid }
    }
}
