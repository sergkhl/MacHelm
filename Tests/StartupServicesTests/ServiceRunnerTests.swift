import XCTest
@testable import StartupServicesCore

// These tests run the built runner as launchd would, against a self-contained
// root. Nothing is registered with launchd.
final class ServiceRunnerTests: XCTestCase {
    private var root: URL!
    private var paths: StartupServicesPaths!

    private var runner: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MacHelmServiceRunner")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("service-runner-\(UUID().uuidString)")
        paths = .sandbox(root: root.appendingPathComponent("data"))
        try FileManager.default.createDirectory(at: paths.launchAgents, withIntermediateDirectories: true)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: runner.path), "The runner was not built at \(runner.path)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func script(_ name: String, _ body: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func save(_ label: String, program: String, arguments: [String] = [], workingDirectory: String? = nil,
                      environment: [String: String] = [:], umask: Int? = nil, managed: Bool = true) throws {
        let definition = ServiceDefinition(
            label: label, name: label,
            command: ServiceCommand(program: program, arguments: [program] + arguments, workingDirectory: workingDirectory,
                                    environment: environment, umask: umask),
            launch: ServiceLaunchPolicy(), automaticStartup: false,
            ownership: managed ? .managed(installedSHA256: nil, backup: nil)
                : .observed(ServiceSource(path: "/tmp/x.plist", sha256: "0", fileMode: 0o644)))
        try ServiceCatalogStore(paths: paths).mutate { $0.services.append(definition) }
    }

    private func launch(_ arguments: [String]) throws -> (process: Process, output: Pipe, error: Pipe) {
        let process = Process()
        process.executableURL = runner
        process.arguments = ["--root", paths.root.path] + arguments
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        return (process, output, error)
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, reason: Process.TerminationReason, output: String, error: String) {
        let started = try launch(arguments)
        let output = started.output.fileHandleForReading.readDataToEndOfFile()
        let error = started.error.fileHandleForReading.readDataToEndOfFile()
        started.process.waitUntilExit()
        return (started.process.terminationStatus, started.process.terminationReason,
                String(decoding: output, as: UTF8.self), String(decoding: error, as: UTF8.self))
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    func testTheCommandGetsItsArgumentsDirectoryEnvironmentAndUmask() throws {
        let work = root.appendingPathComponent("work dir")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let program = try script("report.sh", """
        printf '%s\\n' "$#" "$1" "$2" "$(pwd -P)" "$SERVICE_MODE" "$(umask)" > "$PWD/report.txt"
        touch made-by-command
        echo to-stdout
        echo to-stderr >&2
        """)
        try save("test.report", program: program, arguments: ["two words", "$HOME;not-a-shell"],
                 workingDirectory: work.path, environment: ["SERVICE_MODE": "personal"], umask: 0o077)

        let result = try run(["run", "test.report"])

        XCTAssertEqual(result.status, 0, result.error)
        let report = try String(contentsOf: work.appendingPathComponent("report.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(report.prefix(3)), ["2", "two words", "$HOME;not-a-shell"], "Arguments are passed as typed, never through a shell")
        XCTAssertEqual(report[3], String(cString: realpath(work.path, nil)))
        XCTAssertEqual(report[4], "personal")
        XCTAssertEqual(report[5], "0077")
        XCTAssertEqual(PrivateFile.mode(work.appendingPathComponent("made-by-command")), 0o600)
        // The command's own output goes where launchd pointed the job.
        XCTAssertEqual(result.output, "to-stdout\n")
        XCTAssertEqual(result.error, "to-stderr\n")

        let record = try XCTUnwrap(ServiceRunRecord.read(paths.runRecord("test.report")))
        XCTAssertNil(record.failure)
        XCTAssertNotNil(record.processStartTime)
        XCTAssertFalse(record.isAlive(SystemProcessInspector()))
    }

    func testTheCommandsExitStatusIsTheRunnersExitStatus() throws {
        try save("test.exit", program: "/bin/sh", arguments: ["-c", "exit 7"])
        let result = try run(["run", "test.exit"])
        XCTAssertEqual(result.reason, .exit)
        XCTAssertEqual(result.status, 7, "launchd's restart policy must see the command's own status")
    }

    func testTheCommandRunsInTheVeryProcessLaunchdStarted() throws {
        let started = root.appendingPathComponent("started")
        let cleaned = root.appendingPathComponent("cleaned")
        let program = try script("server.sh", """
        trap 'echo cleanup > "\(cleaned.path)"; exit 42' TERM
        echo $$ > "\(started.path)"
        while :; do sleep 0.05; done
        """)
        try save("test.term", program: program)
        let running = try launch(["run", "test.term"])
        XCTAssertTrue(waitForFile(started))
        Thread.sleep(forTimeInterval: 0.1)
        let commandPID = try String(contentsOf: started, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(commandPID, "\(running.process.processIdentifier)",
                       "No wrapper stays between launchd and the command, so launchd's signals and exit timeout reach the command itself")
        let record = try XCTUnwrap(ServiceRunRecord.read(paths.runRecord("test.term")))
        XCTAssertEqual(record.pid, running.process.processIdentifier)
        XCTAssertTrue(record.isAlive(SystemProcessInspector()))

        // The request launchd sends on a stop arrives at the command, which ends in its own way.
        kill(running.process.processIdentifier, SIGTERM)
        running.process.waitUntilExit()

        XCTAssertEqual(running.process.terminationReason, .exit)
        XCTAssertEqual(running.process.terminationStatus, 42)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path))
        XCTAssertFalse(record.isAlive(SystemProcessInspector()))
    }

    func testACommandEndedByASignalEndsTheJobByTheSameSignal() throws {
        let started = root.appendingPathComponent("started")
        let program = try script("victim.sh", "touch \"\(started.path)\"\nexec /bin/sleep 600")
        try save("test.signal", program: program)
        let running = try launch(["run", "test.signal"])
        XCTAssertTrue(waitForFile(started))

        kill(running.process.processIdentifier, SIGKILL)
        running.process.waitUntilExit()

        XCTAssertEqual(running.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(running.process.terminationStatus, SIGKILL)
    }

    func testAMissingProgramEndsLikeAJobLaunchdCannotStart() throws {
        try save("test.missing", program: root.appendingPathComponent("moved-away").path)
        let result = try run(["run", "test.missing"])
        XCTAssertEqual(result.status, ServiceRunner.configurationFailure)
        XCTAssertTrue(result.error.contains("missing or cannot be executed"), result.error)
        let record = try XCTUnwrap(ServiceRunRecord.read(paths.runRecord("test.missing")))
        XCTAssertNotNil(record.failure)
        XCTAssertFalse(record.isAlive(SystemProcessInspector()))
    }

    func testAMissingWorkingDirectoryIsAConfigurationFailure() throws {
        try save("test.directory", program: "/usr/bin/true", workingDirectory: root.appendingPathComponent("gone").path)
        XCTAssertEqual(try run(["run", "test.directory"]).status, ServiceRunner.configurationFailure)
    }

    func testOnlyAManagedCatalogEntryIsRun() throws {
        let marker = root.appendingPathComponent("ran")
        let program = try script("touch.sh", "touch \"\(marker.path)\"")
        XCTAssertEqual(try run(["run", "test.unknown"]).status, ServiceRunner.configurationFailure)
        try save("test.observed", program: program, managed: false)
        XCTAssertEqual(try run(["run", "test.observed"]).status, ServiceRunner.configurationFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testASecondOwnerIsNotStartedWhileAnEarlierCommandIsAlive() throws {
        let marker = root.appendingPathComponent("ran")
        let program = try script("touch.sh", "touch \"\(marker.path)\"")
        try save("test.duplicate", program: program)
        // An earlier command that outlived its runner.
        let survivor = Process()
        survivor.executableURL = URL(fileURLWithPath: "/bin/sleep")
        survivor.arguments = ["600"]
        try survivor.run()
        defer { survivor.terminate() }
        var earlier = ServiceRunRecord(label: "test.duplicate", pid: survivor.processIdentifier, startedAt: Date())
        earlier.processStartTime = try XCTUnwrap(SystemProcessInspector().startTime(of: survivor.processIdentifier))
        try earlier.write(to: paths.runRecord("test.duplicate"))
        let recorded = try Data(contentsOf: paths.runRecord("test.duplicate"))

        let result = try run(["run", "test.duplicate"])

        XCTAssertEqual(result.status, ServiceRunner.temporaryFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "No second owner ran")
        XCTAssertEqual(try Data(contentsOf: paths.runRecord("test.duplicate")), recorded, "The record of the live process is kept")

        // Once it is gone, the service runs again.
        survivor.terminate()
        survivor.waitUntilExit()
        XCTAssertEqual(try run(["run", "test.duplicate"]).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAnOwnerLockIsSeenOnlyWhileItIsHeld() throws {
        let lockURL = root.appendingPathComponent("service.owner.lock")
        let probe = SystemOwnerLockProbe()
        XCTAssertFalse(probe.isHeld(lockURL.path), "No file, no owner")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertFalse(probe.isHeld(lockURL.path), "A lock file that merely exists is not an owner")
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(probe.isHeld(lockURL.path))
        close(descriptor)
        XCTAssertFalse(probe.isHeld(lockURL.path))
        // Asking did not leave a lock behind.
        let again = open(lockURL.path, O_RDWR)
        XCTAssertEqual(flock(again, LOCK_EX | LOCK_NB), 0)
        close(again)
    }

    func testTheCommandLineReportsStatusAsDataAndRefusalsAsErrors() throws {
        try save("test.cli", program: "/usr/bin/true")
        let status = try run(["status", "test.cli", "--json"])
        XCTAssertEqual(status.status, 0, status.error)
        let report = try JSONDecoder().decode(ServiceRunnerCLI.StatusReport.self, from: Data(status.output.utf8))
        XCTAssertEqual(report.label, "test.cli")
        XCTAssertEqual(report.activity, "inactive")
        XCTAssertFalse(report.registered)
        XCTAssertTrue(report.managed)
        XCTAssertFalse(report.automaticStartup)

        let unknown = try run(["status", "test.none", "--json"])
        XCTAssertEqual(unknown.status, 1)
        XCTAssertTrue(unknown.output.contains("\"error\" : \"notFound\""), unknown.output)

        XCTAssertEqual(try run(["set-automatic", "test.cli", "maybe"]).status, 2)
        XCTAssertEqual(try run([]).status, 2)

        try run(["rename", "test.cli", "A new name"]).status == 0 ? () : XCTFail("rename failed")
        XCTAssertEqual(try ServiceCatalogStore(paths: paths).read().service("test.cli")?.name, "A new name")
    }

    func testAnInstallerDefinitionFileBecomesAManagedDefinition() throws {
        let file = root.appendingPathComponent("definition.json")
        let json = """
        {"label": "test.installer", "program": "/usr/bin/true", "arguments": ["/usr/bin/true", "--mode", "personal"],
         "runAtLoad": true, "keepAlive": "afterFailure", "throttleInterval": 30, "processType": "Background", "umask": 63,
         "environment": {"LANG": "en_US.UTF-8"}, "ownerLockPaths": ["/tmp/x.lock"]}
        """
        try Data(json.utf8).write(to: file)
        let result = try run(["install-definition", file.path, "--json"])
        XCTAssertEqual(result.status, 0, result.error)
        let definition = try XCTUnwrap(try ServiceCatalogStore(paths: paths).read().service("test.installer"))
        XCTAssertTrue(definition.isManaged)
        XCTAssertFalse(definition.automaticStartup)
        XCTAssertEqual(definition.launch.restart, .afterFailure)
        XCTAssertEqual(definition.command.umask, 0o077)
        XCTAssertEqual(definition.ownerLockPaths, ["/tmp/x.lock"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.launchAgents.path), [])

        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(try run(["install-definition", file.path]).status, 1)
    }
}
