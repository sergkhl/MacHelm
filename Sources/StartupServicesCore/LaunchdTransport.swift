import Foundation

// What launchd reports about one job in the user's session.
public struct LaunchdJobSnapshot: Equatable, Sendable {
    public var state: String?
    public var pid: Int32?
    // Nil while the job has never exited.
    public var lastExitCode: Int32?
    public var lastTerminatingSignal: String?
    public var runs: Int?
    public var program: String?
    public var plistPath: String?

    public init(state: String? = nil, pid: Int32? = nil, lastExitCode: Int32? = nil, lastTerminatingSignal: String? = nil,
                runs: Int? = nil, program: String? = nil, plistPath: String? = nil) {
        self.state = state; self.pid = pid; self.lastExitCode = lastExitCode
        self.lastTerminatingSignal = lastTerminatingSignal; self.runs = runs
        self.program = program; self.plistPath = plistPath
    }

    // `launchctl print` is meant for people, so only the job's own top-level
    // fields are read and an unknown shape yields empty fields, never a guess.
    public static func parse(_ output: String) -> LaunchdJobSnapshot {
        var snapshot = LaunchdJobSnapshot()
        // Only the job's own fields are read: lines with one tab that are not
        // inside a nested block (arguments, environment, coalitions). A line
        // of an argument that happens to look like a field is inside one.
        var insideBlock = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("\t"), !line.dropFirst().hasPrefix("\t") else { continue }
            if line.hasSuffix("= {") {
                insideBlock = true
                continue
            }
            if line.dropFirst() == "}" {
                insideBlock = false
                continue
            }
            guard !insideBlock else { continue }
            let parts = line.dropFirst().components(separatedBy: " = ")
            guard parts.count >= 2 else { continue }
            let value = parts.dropFirst().joined(separator: " = ")
            switch parts[0] {
            case "state" where snapshot.state == nil: snapshot.state = value
            case "pid" where snapshot.pid == nil: snapshot.pid = Int32(value)
            case "runs" where snapshot.runs == nil: snapshot.runs = Int(value)
            case "program" where snapshot.program == nil: snapshot.program = value
            case "path" where snapshot.plistPath == nil: snapshot.plistPath = value
            case "last exit code" where snapshot.lastExitCode == nil:
                snapshot.lastExitCode = Int32(value.prefix { $0.isNumber || $0 == "-" })
            case "last terminating signal" where snapshot.lastTerminatingSignal == nil:
                snapshot.lastTerminatingSignal = value
            default: break
            }
        }
        return snapshot
    }
}

public protocol LaunchdTransport: Sendable {
    // Nil when the label is not registered in this session.
    func snapshot(label: String) throws -> LaunchdJobSnapshot?
    func bootstrap(plist: URL) throws
    func bootout(label: String) throws
    func kickstart(label: String) throws
    // Labels switched off in launchd's own persistent list (`launchctl disable`).
    // launchd neither loads such a label at login nor lets it be loaded by hand.
    func disabledLabels() throws -> Set<String>
    func setDisabled(_ disabled: Bool, label: String) throws
}

// The user's own launchd session through /bin/launchctl. No privilege is used.
public struct LaunchctlTransport: LaunchdTransport {
    public let domain: String

    public init(domain: String = "gui/\(getuid())") {
        self.domain = domain
    }

    public func snapshot(label: String) throws -> LaunchdJobSnapshot? {
        let result = try run(["print", "\(domain)/\(label)"])
        if result.status == 0 { return LaunchdJobSnapshot.parse(result.output) }
        if result.status == 113 || result.error.contains("Could not find service") { return nil }
        throw StartupServicesError(.launchd, "launchd did not report on \(label): \(result.summary)")
    }

    public func bootstrap(plist: URL) throws {
        let result = try run(["bootstrap", domain, plist.path])
        guard result.status == 0 else {
            throw StartupServicesError(.launchd, "launchd did not load the service: \(result.summary)")
        }
    }

    public func bootout(label: String) throws {
        let result = try run(["bootout", "\(domain)/\(label)"])
        // 36: the job is still exiting. 3 and 113: it was not registered.
        guard [0, 3, 36, 113].contains(result.status) else {
            throw StartupServicesError(.launchd, "launchd did not stop the service: \(result.summary)")
        }
    }

    public func kickstart(label: String) throws {
        let result = try run(["kickstart", "\(domain)/\(label)"])
        guard result.status == 0 else {
            throw StartupServicesError(.launchd, "launchd did not start the service: \(result.summary)")
        }
    }

    public func disabledLabels() throws -> Set<String> {
        let result = try run(["print-disabled", domain])
        guard result.status == 0 else {
            throw StartupServicesError(.launchd, "launchd did not list its switched-off labels: \(result.summary)")
        }
        return Self.parseDisabled(result.output)
    }

    public func setDisabled(_ disabled: Bool, label: String) throws {
        let result = try run([disabled ? "disable" : "enable", "\(domain)/\(label)"])
        guard result.status == 0 else {
            throw StartupServicesError(.launchd, "launchd did not \(disabled ? "switch off" : "switch on") \(label): \(result.summary)")
        }
    }

    // Lines read `"label" => disabled`; older systems wrote `=> true`.
    static func parseDisabled(_ output: String) -> Set<String> {
        var labels: Set<String> = []
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: " => ")
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value == "disabled" || value == "true" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")))
        }
        return labels
    }

    private struct Result {
        let status: Int32
        let output: String
        let error: String
        var summary: String {
            let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "exit \(status)" : "\(text) (exit \(status))"
        }
    }

    private func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            throw StartupServicesError(.launchd, "launchctl could not be run: \(error.localizedDescription)")
        }
        // Read both pipes to their ends before waiting, so a long report cannot block the child.
        var errorData = Data()
        let reader = DispatchQueue(label: "launchctl.stderr")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: outputData, as: UTF8.self),
                      error: String(decoding: errorData, as: UTF8.self))
    }
}

// A test folder keeps its files to itself, but launchd labels belong to the
// whole login session. From a test folder only labels under the self-test
// prefix can be loaded, unloaded, started or switched, so a test entry that
// happens to carry a real service's label can never touch the real job.
public struct SelfTestOnlyTransport: LaunchdTransport {
    public static let labelPrefix = StartupServicesIdentity.appBundleIdentifier + ".selftest."
    private let base: LaunchdTransport

    public init(_ base: LaunchdTransport) {
        self.base = base
    }

    private func allow(_ label: String?) throws {
        guard let label, label.hasPrefix(Self.labelPrefix) else {
            throw StartupServicesError(.invalid, "A test folder can only act on labels that begin with \(Self.labelPrefix)")
        }
    }

    public func snapshot(label: String) throws -> LaunchdJobSnapshot? { try base.snapshot(label: label) }
    public func disabledLabels() throws -> Set<String> { try base.disabledLabels() }

    public func bootstrap(plist: URL) throws {
        let root = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        try allow(root?["Label"] as? String)
        try base.bootstrap(plist: plist)
    }

    public func bootout(label: String) throws {
        try allow(label)
        try base.bootout(label: label)
    }

    public func kickstart(label: String) throws {
        try allow(label)
        try base.kickstart(label: label)
    }

    public func setDisabled(_ disabled: Bool, label: String) throws {
        try allow(label)
        try base.setDisabled(disabled, label: label)
    }
}

public protocol ProcessInspecting: Sendable {
    // The kernel's start time for the process, nil when there is none.
    func startTime(of pid: Int32) -> Double?
}

public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    public func startTime(of pid: Int32) -> Double? {
        guard pid > 0 else { return nil }
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size,
              information.pbi_status != UInt32(SZOMB) else { return nil }
        return Double(information.pbi_start_tvsec) + Double(information.pbi_start_tvusec) / 1_000_000
    }
}

public protocol OwnerLockProbing: Sendable {
    func isHeld(_ path: String) -> Bool
}

// Asks the kernel whether another process holds the file's lock. The lock
// file's mere existence says nothing: the owner never deletes it.
public struct SystemOwnerLockProbe: OwnerLockProbing {
    public init() {}

    public func isHeld(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}

public enum BackgroundPermission: String, Sendable {
    case allowed, blocked, unknown
}

public protocol BackgroundPermissionReading: Sendable {
    // The macOS switch for the app's background items, read from the
    // LaunchAgents this feature has installed.
    func permission(forInstalled plists: [URL]) -> BackgroundPermission
}

public struct UnknownBackgroundPermission: BackgroundPermissionReading {
    public init() {}
    public func permission(forInstalled plists: [URL]) -> BackgroundPermission { .unknown }
}
