import Foundation

public struct StartupServicesPaths: Equatable, Sendable {
    public let root: URL
    public let launchAgents: URL
    // False for a test root, whose jobs name it explicitly.
    public let isStandard: Bool

    // Editable configuration lives in the user's Application Support, in the
    // app's existing data domain and outside the signed bundle.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> StartupServicesPaths {
        StartupServicesPaths(
            root: home.appendingPathComponent("Library/Application Support/\(StartupServicesIdentity.appBundleIdentifier)/StartupServices"),
            launchAgents: home.appendingPathComponent("Library/LaunchAgents"), isStandard: true)
    }

    // Everything, the LaunchAgents folder included, stays under `root`.
    public static func sandbox(root: URL) -> StartupServicesPaths {
        StartupServicesPaths(root: root, launchAgents: root.appendingPathComponent("LaunchAgents"), isStandard: false)
    }

    public var catalog: URL { root.appendingPathComponent("catalog.json") }
    public var lock: URL { root.appendingPathComponent("catalog.lock") }
    public var agents: URL { root.appendingPathComponent("Agents") }
    public var run: URL { root.appendingPathComponent("Run") }
    public var backups: URL { root.appendingPathComponent("Backups") }
    public var logs: URL { root.appendingPathComponent("Logs") }

    // Loaded by launchd at login while automatic startup is on.
    public func installedPlist(_ label: String) -> URL { launchAgents.appendingPathComponent(label + ".plist") }
    // Loaded only by an explicit Start in the current session.
    public func sessionPlist(_ label: String) -> URL { agents.appendingPathComponent(label + ".plist") }
    public func runRecord(_ label: String) -> URL { run.appendingPathComponent(label + ".json") }
    public func stopMarker(_ label: String) -> URL { run.appendingPathComponent(label + ".stopping") }
}

enum PrivateFile {
    static func ensureDirectory(_ url: URL, mode: mode_t = 0o700) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw StartupServicesError(.storage, "\(url.path) is not a folder.")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: mode)])
        } catch {
            throw StartupServicesError(.storage, "Cannot create \(url.path): \(error.localizedDescription)")
        }
    }

    // Writes a complete file under a temporary name, then renames it into
    // place, so a reader never sees half a file.
    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            throw StartupServicesError(.storage, "Cannot write \(url.path): \(String(cString: strerror(errno)))")
        }
        var failure: String?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = String(cString: strerror(errno)); return
                }
                offset += written
            }
        }
        if failure == nil, fchmod(descriptor, mode) != 0 || fsync(descriptor) != 0 {
            failure = String(cString: strerror(errno))
        }
        close(descriptor)
        if failure == nil, rename(temporary.path, url.path) != 0 {
            failure = String(cString: strerror(errno))
        }
        if let failure {
            unlink(temporary.path)
            throw StartupServicesError(.storage, "Cannot write \(url.path): \(failure)")
        }
    }

    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func exists(_ url: URL) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
    }

    static func mode(_ url: URL) -> Int? {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return nil }
        return Int(information.st_mode & 0o777)
    }
}

// The catalog file. Every change takes an exclusive file lock, so the app and
// the command-line runner cannot interleave edits or registrations.
public final class ServiceCatalogStore: @unchecked Sendable {
    public let paths: StartupServicesPaths
    // Test seam: runs after a change is computed and before it is saved.
    var beforeSave: (() throws -> Void)?

    public init(paths: StartupServicesPaths) {
        self.paths = paths
    }

    public func read() throws -> ServiceCatalog {
        guard let data = PrivateFile.read(paths.catalog) else {
            if PrivateFile.exists(paths.catalog) {
                throw StartupServicesError(.storage, "The Startup Services catalog cannot be read.")
            }
            return ServiceCatalog()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let catalog = try? decoder.decode(ServiceCatalog.self, from: data) else {
            throw StartupServicesError(.storage, "The Startup Services catalog is damaged; it was left untouched.")
        }
        guard catalog.schemaVersion <= ServiceCatalog.currentSchema else {
            throw StartupServicesError(.storage, "The Startup Services catalog was written by a newer MacHelm.")
        }
        guard Set(catalog.services.map(\.label)).count == catalog.services.count else {
            throw StartupServicesError(.storage, "The Startup Services catalog lists a service twice; it was left untouched.")
        }
        return catalog
    }

    @discardableResult
    public func mutate<T>(_ body: (inout ServiceCatalog) throws -> T) throws -> T {
        try PrivateFile.ensureDirectory(paths.root)
        for directory in [paths.agents, paths.run, paths.backups, paths.logs] {
            try PrivateFile.ensureDirectory(directory)
        }
        let descriptor = open(paths.lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw StartupServicesError(.storage, "Cannot open the catalog lock: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw StartupServicesError(.storage, "Cannot lock the catalog: \(String(cString: strerror(errno)))")
            }
        }
        defer { flock(descriptor, LOCK_UN) }

        let before = try read()
        var catalog = before
        let result = try body(&catalog)
        if catalog != before {
            try beforeSave?()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try PrivateFile.write(try encoder.encode(catalog), to: paths.catalog)
        }
        return result
    }
}

// What the runner recorded when it last started the command. The command
// runs in the runner's own process, so this PID is the command's. Status is
// read from this and from launchd; nothing is executed to find it out.
public struct ServiceRunRecord: Codable, Equatable, Sendable {
    public var label: String
    public var pid: Int32
    // From the kernel's process table; tells this process from a later one
    // that was given the same number.
    public var processStartTime: Double?
    public var startedAt: Date
    // Why the command could not be started at all.
    public var failure: String?

    public init(label: String, pid: Int32, startedAt: Date) {
        self.label = label; self.pid = pid; self.startedAt = startedAt
    }

    // True while the recorded process is still the same live process.
    public func isAlive(_ processes: ProcessInspecting) -> Bool {
        guard failure == nil, let recorded = processStartTime, let current = processes.startTime(of: pid) else { return false }
        return abs(current - recorded) < 0.01
    }

    public static func read(_ url: URL) -> ServiceRunRecord? {
        guard let data = PrivateFile.read(url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ServiceRunRecord.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try PrivateFile.ensureDirectory(url.deletingLastPathComponent())
        try PrivateFile.write(try encoder.encode(self), to: url)
    }
}
