import Foundation

// A process identifier is reused after its process ends, so the start time
// belongs to the identity. A system process's start cannot be read; it is 0.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    // Mach absolute time.
    public let startedAt: UInt64

    public init(pid: Int32, startedAt: UInt64) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

// What a Wine process runs.
public enum WineRole: Equatable, Sendable {
    // A Windows program, by the name of its .exe.
    case program(String)
    // Wine's own background processes: its server and what runs from C:\windows.
    case background
}

// The process that started another: the first parent seen for it. macOS
// keeps only the current parent, which is launchd once the starter has ended.
public struct ProcessStarter: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var ended: Bool

    public init(pid: Int32, name: String, ended: Bool = false) {
        self.pid = pid
        self.name = name
        self.ended = ended
    }
}

public struct ProcessDescription: Equatable, Sendable {
    public var identity: ProcessIdentity
    // The current parent, which is launchd once the starter has ended.
    public var parent: Int32
    // A process of the owner's user. Any other is a system process.
    public var isOwn: Bool
    public var name: String
    public var executablePath: String
    public var wine: WineRole?
    // Seconds of uptime at which it started; nil for a system process.
    public var startedUptime: TimeInterval?
    // Who started it, where that is another program than the process's own app.
    public var starter: ProcessStarter?
    // The app macOS holds responsible, where it is neither the process's own app nor its starter.
    public var responsibleApp: String?
    // Its starters by name, nearest first, as far as they are known. Shells
    // and package runners are left out; an interpreter is named by its script.
    public var chain: [String]
    // What a helper of a browser, or of an app built like one, does: "tab", "GPU", "network".
    public var kind: String?
    // The bundle of the app it counts toward when that is not its own: the
    // responsible app of a helper that launchd started.
    public var adoptedBy: String?
    // Who started the copy of the app it counts toward. Empty for a copy that launchd started.
    public var origin: [String]

    public init(identity: ProcessIdentity, parent: Int32, isOwn: Bool, name: String, executablePath: String,
                wine: WineRole? = nil, startedUptime: TimeInterval? = nil, starter: ProcessStarter? = nil,
                responsibleApp: String? = nil, chain: [String] = [], kind: String? = nil, adoptedBy: String? = nil,
                origin: [String] = []) {
        self.identity = identity
        self.parent = parent
        self.isOwn = isOwn
        self.name = name
        self.executablePath = executablePath
        self.wine = wine
        self.startedUptime = startedUptime
        self.starter = starter
        self.responsibleApp = responsibleApp
        self.chain = chain
        self.kind = kind
        self.adoptedBy = adoptedBy
        self.origin = origin
    }
}

// CPU time, energy and disk bytes grow for as long as the process lives; memory is a level.
public struct ProcessSample: Equatable, Sendable {
    public var description: ProcessDescription
    public var cpuSeconds: Double
    public var energyJoules: Double?
    public var memoryBytes: UInt64?
    // Read and written, together.
    public var diskBytes: Double?

    public init(description: ProcessDescription, cpuSeconds: Double, energyJoules: Double? = nil, memoryBytes: UInt64? = nil,
                diskBytes: Double? = nil) {
        self.description = description
        self.cpuSeconds = cpuSeconds
        self.energyJoules = energyJoules
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }
}

// One read of the processes. System processes are read less often (ADR
// 0002), so a pass holds them only when they were read.
public struct ProcessPass: Equatable, Sendable {
    public var uptime: TimeInterval
    public var own: [ProcessSample]
    public var system: [ProcessSample]?
    // GPU seconds by process identifier, counted from the reader's first pass.
    public var gpuSeconds: [Int32: Double]

    public init(uptime: TimeInterval, own: [ProcessSample], system: [ProcessSample]? = nil, gpuSeconds: [Int32: Double] = [:]) {
        self.uptime = uptime
        self.own = own
        self.system = system
        self.gpuSeconds = gpuSeconds
    }
}
