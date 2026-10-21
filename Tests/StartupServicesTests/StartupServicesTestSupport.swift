import XCTest
@testable import StartupServicesCore

// A launchd that only keeps a table. It records every request that would
// change a registration, so a test can show that reading status asks for none.
final class FakeLaunchd: LaunchdTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: LaunchdJobSnapshot] = [:]
    private var log: [String] = []
    private var nextPID: Int32 = 4000
    var bootstrapFailure: StartupServicesError?
    var bootoutFailure: StartupServicesError?
    var snapshotFailure: StartupServicesError?
    // The job stays registered after bootout, as while a process is still exiting.
    var bootoutLeavesJob = false
    // launchd's own persistent off switch, by label.
    var disabled: Set<String> = []

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func job(_ label: String) -> LaunchdJobSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return table[label]
    }

    func setJob(_ label: String, _ snapshot: LaunchdJobSnapshot?) {
        lock.lock(); defer { lock.unlock() }
        table[label] = snapshot
    }

    func snapshot(label: String) throws -> LaunchdJobSnapshot? {
        lock.lock(); defer { lock.unlock() }
        if let snapshotFailure { throw snapshotFailure }
        return table[label]
    }

    func disabledLabels() throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return disabled
    }

    func setDisabled(_ disabled: Bool, label: String) throws {
        lock.lock(); defer { lock.unlock() }
        log.append("\(disabled ? "disable" : "enable") \(label)")
        if disabled { self.disabled.insert(label) } else { self.disabled.remove(label) }
    }

    func bootstrap(plist: URL) throws {
        lock.lock(); defer { lock.unlock() }
        log.append("bootstrap \(plist.path)")
        if let bootstrapFailure { throw bootstrapFailure }
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = root["Label"] as? String, !disabled.contains(label) else {
            // launchd refuses to load a label that is switched off.
            throw StartupServicesError(.launchd, "Bootstrap failed: 5: Input/output error")
        }
        guard table[label] == nil else {
            throw StartupServicesError(.launchd, "Bootstrap failed: 37: Operation already in progress")
        }
        let starts = root["RunAtLoad"] as? Bool == true || root["KeepAlive"] != nil
        var snapshot = LaunchdJobSnapshot(state: starts ? "running" : "not running", runs: starts ? 1 : 0,
                                          program: (root["ProgramArguments"] as? [String])?.first, plistPath: plist.path)
        if starts { nextPID += 1; snapshot.pid = nextPID }
        table[label] = snapshot
    }

    func bootout(label: String) throws {
        lock.lock(); defer { lock.unlock() }
        log.append("bootout \(label)")
        if let bootoutFailure { throw bootoutFailure }
        if !bootoutLeavesJob { table[label] = nil }
    }

    func kickstart(label: String) throws {
        lock.lock(); defer { lock.unlock() }
        log.append("kickstart \(label)")
        guard var snapshot = table[label] else {
            throw StartupServicesError(.launchd, "Could not find service")
        }
        nextPID += 1
        snapshot.pid = nextPID; snapshot.state = "running"; snapshot.runs = (snapshot.runs ?? 0) + 1
        table[label] = snapshot
    }
}

final class FakeProcesses: ProcessInspecting, @unchecked Sendable {
    var startTimes: [Int32: Double] = [:]
    func startTime(of pid: Int32) -> Double? { startTimes[pid] }
}

final class FakeLocks: OwnerLockProbing, @unchecked Sendable {
    var held: Set<String> = []
    private(set) var probes = 0
    func isHeld(_ path: String) -> Bool {
        probes += 1
        return held.contains(path)
    }
}

final class FakePermission: BackgroundPermissionReading, @unchecked Sendable {
    var value = BackgroundPermission.allowed
    private(set) var asked: [[URL]] = []
    func permission(forInstalled plists: [URL]) -> BackgroundPermission {
        asked.append(plists)
        return value
    }
}

// One self-contained root per test: catalog, LaunchAgents folder, a fake
// runner and a fake program, all inside a temporary folder.
final class ServiceSandbox {
    let root: URL
    let paths: StartupServicesPaths
    let launchd = FakeLaunchd()
    let processes = FakeProcesses()
    let locks = FakeLocks()
    let permission = FakePermission()
    let runner: URL
    let program: URL
    var controller: StartupServicesController

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("startup-services-\(UUID().uuidString)")
        paths = .sandbox(root: root.appendingPathComponent("data"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        runner = root.appendingPathComponent("Contents/Library/HelperTools/MacHelmServiceRunner")
        program = root.appendingPathComponent("bin/server")
        for executable in [runner, program] {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        controller = StartupServicesController(
            paths: paths, transport: launchd, invocation: ServiceRunnerInvocation(runnerPath: runner.path),
            processes: processes, locks: locks, permission: permission,
            now: { Date(timeIntervalSince1970: 1_791_000_000) })
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // A second controller on the same files, as the command-line runner is to the app.
    func secondController() -> StartupServicesController {
        StartupServicesController(paths: paths, transport: launchd, invocation: ServiceRunnerInvocation(runnerPath: runner.path),
                                  processes: processes, locks: locks, permission: permission)
    }

    @discardableResult
    func writeAgent(_ plist: [String: Any], named name: String? = nil, mode: Int = 0o644) throws -> URL {
        let label = plist["Label"] as? String ?? "unnamed"
        let url = paths.launchAgents.appendingPathComponent((name ?? label) + ".plist")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func continuousAgent(label: String = "com.example.server") -> [String: Any] {
        ["Label": label, "ProgramArguments": [program.path, "--port", "8765"], "RunAtLoad": true, "KeepAlive": true,
         "ThrottleInterval": 10, "ProcessType": "Interactive", "WorkingDirectory": root.path,
         "StandardOutPath": root.appendingPathComponent("server.log").path,
         "StandardErrorPath": root.appendingPathComponent("server.log").path]
    }

    func oneShotAgent(label: String = "com.example.login") -> [String: Any] {
        ["Label": label, "ProgramArguments": [program.path, "once"], "RunAtLoad": true]
    }

    func scheduledAgent(label: String = "com.example.backup") -> [String: Any] {
        ["Label": label, "ProgramArguments": [program.path, "backup"],
         "StartCalendarInterval": [["Hour": 3, "Minute": 45], ["Hour": 15, "Minute": 45]]]
    }

    // Imports and takes over, as a migration step does.
    @discardableResult
    func manage(_ plist: [String: Any]) throws -> String {
        let url = try writeAgent(plist)
        let definition = try controller.importLaunchAgent(at: url)
        try controller.takeOver(definition.label)
        return definition.label
    }

    func installedPlist(_ label: String) throws -> [String: Any] {
        let data = try Data(contentsOf: paths.installedPlist(label))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func definition(_ label: String) throws -> ServiceDefinition {
        try XCTUnwrap(try controller.store.read().service(label))
    }
}

func assertRefused(_ kind: StartupServicesError.Kind, file: StaticString = #filePath, line: UInt = #line,
                   _ body: () throws -> Void) {
    do {
        try body()
        XCTFail("Expected a \(kind) refusal", file: file, line: line)
    } catch let error as StartupServicesError {
        XCTAssertEqual(error.kind, kind, error.message, file: file, line: line)
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
}
