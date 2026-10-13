import XCTest
@testable import StartupServicesCore

final class ServiceLifecycleTests: XCTestCase {
    private var sandbox: ServiceSandbox!
    private var controller: StartupServicesController { sandbox.controller }
    private var launchd: FakeLaunchd { sandbox.launchd }

    override func setUpWithError() throws {
        sandbox = try ServiceSandbox()
    }

    override func tearDown() {
        sandbox = nil
    }

    private func status(_ label: String) throws -> ServiceStatus {
        try controller.status(label)
    }

    // MARK: Import and observation

    func testImportAndStatusAreObservationOnly() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        let original = try Data(contentsOf: url)
        launchd.setJob("com.example.server", LaunchdJobSnapshot(state: "running", pid: 77, runs: 1, program: sandbox.program.path))

        let definition = try controller.importLaunchAgent(at: url)
        for _ in 0..<3 { _ = try controller.statuses() }
        _ = try controller.discover()

        XCTAssertEqual(launchd.calls, [], "Importing and reading status must not ask launchd to change anything")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(definition.isManaged)
        let observed = try status("com.example.server")
        XCTAssertEqual(observed.activity, .running(pid: 77))
        XCTAssertEqual(observed.loadedInstance, .original)
        XCTAssertEqual(observed.actions, [.takeOver, .remove])
        XCTAssertEqual(sandbox.locks.probes, 0, "A lock is asked about only while a stop is being confirmed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.sessionPlist("com.example.server").path))
    }

    func testImportingTheSameLabelTwiceIsRefused() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        try controller.importLaunchAgent(at: url)
        assertRefused(.conflict) { try controller.importLaunchAgent(at: url) }
        XCTAssertEqual(try controller.store.read().services.count, 1)
    }

    func testDiscoverReportsImportableAndRefusedAgents() throws {
        try sandbox.writeAgent(sandbox.continuousAgent())
        try sandbox.writeAgent(["Label": "com.example.watcher", "ProgramArguments": ["/bin/x"], "WatchPaths": ["/tmp"]])
        try controller.importLaunchAgent(at: sandbox.paths.launchAgents.appendingPathComponent("com.example.server.plist"))
        let found = try controller.discover()
        XCTAssertEqual(found.map(\.label), ["com.example.server", "com.example.watcher"])
        XCTAssertEqual(found.map(\.inCatalog), [true, false])
        XCTAssertNotNil(found[0].definition)
        XCTAssertNil(found[1].definition)
        XCTAssertTrue(found[1].refusal?.contains("WatchPaths") == true)
    }

    // MARK: Taking over

    func testTakeOverBacksUpTheExactOriginalAndRunsNothing() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent(), mode: 0o600)
        let original = try Data(contentsOf: url)
        launchd.setJob("com.example.server", LaunchdJobSnapshot(state: "running", pid: 77, runs: 1, program: sandbox.program.path))
        try controller.importLaunchAgent(at: url)
        try controller.takeOver("com.example.server")

        XCTAssertEqual(launchd.calls, [], "Taking over replaces a file; it starts and stops nothing")
        let definition = try sandbox.definition("com.example.server")
        guard case .managed(let installedHash?, let backup?) = definition.ownership else {
            return XCTFail("Expected a managed definition with an installed plist and a backup")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup.path)), original)
        XCTAssertEqual(backup.sha256, ServiceHash.sha256(original))
        XCTAssertEqual(backup.originalPath, url.path)
        XCTAssertTrue(backup.path.hasPrefix(sandbox.paths.backups.path))
        XCTAssertEqual(ServiceHash.sha256(try Data(contentsOf: url)), installedHash)
        XCTAssertEqual(PrivateFile.mode(url), 0o600, "The private mode of the original is kept")

        let installed = try sandbox.installedPlist("com.example.server")
        XCTAssertEqual(installed["ProgramArguments"] as? [String], [sandbox.runner.path, "run", "com.example.server"])
        XCTAssertEqual(installed["AssociatedBundleIdentifiers"] as? [String], ["io.github.sergkhl.MacHelm"])
        XCTAssertEqual(installed["KeepAlive"] as? Bool, true)
        XCTAssertEqual(installed["ThrottleInterval"] as? Int, 10)
        XCTAssertEqual(installed["WorkingDirectory"] as? String, sandbox.root.path)

        // The job loaded before the takeover keeps running as it was.
        let after = try status("com.example.server")
        XCTAssertEqual(after.activity, .running(pid: 77))
        XCTAssertEqual(after.loadedInstance, .original)
        XCTAssertEqual(after.problems, [])
        XCTAssertEqual(after.actions, [.stop])
    }

    func testTakeOverRefusesASourceEditedSinceImport() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        try controller.importLaunchAgent(at: url)
        // An installer rewrites its LaunchAgent between the import and the takeover.
        var edited = sandbox.continuousAgent()
        edited["ProgramArguments"] = [sandbox.program.path, "--port", "9000"]
        let editedURL = try sandbox.writeAgent(edited)
        let editedData = try Data(contentsOf: editedURL)

        XCTAssertEqual(try status("com.example.server").problems, [.sourceChanged(url.path)])
        XCTAssertEqual(try status("com.example.server").actions, [.remove])
        assertRefused(.conflict) { try controller.takeOver("com.example.server") }
        XCTAssertEqual(try Data(contentsOf: url), editedData, "The installer's edit is not lost")
        XCTAssertFalse(try sandbox.definition("com.example.server").isManaged)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.backups.path), [])
    }

    func testTakeOverOfASwitchedOffAgentLeavesNothingToLoadAtLogin() throws {
        var agent = sandbox.continuousAgent()
        agent["Disabled"] = true
        let url = try sandbox.writeAgent(agent)
        let original = try Data(contentsOf: url)
        try controller.importLaunchAgent(at: url)
        try controller.takeOver("com.example.server")

        let definition = try sandbox.definition("com.example.server")
        XCTAssertFalse(definition.automaticStartup)
        guard case .managed(nil, let backup?) = definition.ownership else { return XCTFail("Expected no installed plist") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup.path)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try status("com.example.server").problems, [])
    }

    func testTakeOverOfAnAgentUnderAnotherFileNameLeavesOneOwner() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent(), named: "my-server")
        try controller.importLaunchAgent(at: url)
        try controller.takeOver("com.example.server")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "The original would load beside the managed one")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.paths.installedPlist("com.example.server").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.launchAgents.path), ["com.example.server.plist"])
    }

    func testTakeOverPutsTheOriginalBackWhenTheCatalogCannotBeSaved() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        let original = try Data(contentsOf: url)
        try controller.importLaunchAgent(at: url)
        controller.store.beforeSave = { throw StartupServicesError(.storage, "disk full") }

        assertRefused(.storage) { try controller.takeOver("com.example.server") }
        controller.store.beforeSave = nil
        XCTAssertEqual(try Data(contentsOf: url), original, "A half-finished takeover leaves the original owner in place")
        XCTAssertFalse(try sandbox.definition("com.example.server").isManaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.sessionPlist("com.example.server").path))
        XCTAssertEqual(launchd.calls, [])
        // The same step can then be repeated.
        try controller.takeOver("com.example.server")
        XCTAssertTrue(try sandbox.definition("com.example.server").isManaged)
    }

    func testTakeOverLeavesTheOriginalWhenTheManagedPlistCannotBeWritten() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        let original = try Data(contentsOf: url)
        try controller.importLaunchAgent(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sandbox.paths.launchAgents.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sandbox.paths.launchAgents.path) }

        assertRefused(.storage) { try controller.takeOver("com.example.server") }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(try sandbox.definition("com.example.server").isManaged)
    }

    func testTakeOverNeedsTheInstalledApp() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        sandbox.controller = StartupServicesController(paths: sandbox.paths, transport: launchd, invocation: nil)
        try controller.importLaunchAgent(at: url)
        XCTAssertEqual(try status("com.example.server").actions, [.remove])
        assertRefused(.notInstalled) { try controller.takeOver("com.example.server") }
    }

    func testRevertPutsTheExactOriginalBack() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        let original = try Data(contentsOf: url)
        try controller.importLaunchAgent(at: url)
        try controller.takeOver("com.example.server")
        try controller.start("com.example.server")

        assertRefused(.busy) { try controller.revert("com.example.server") }
        try controller.stop("com.example.server")
        try controller.revert("com.example.server")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try sandbox.definition("com.example.server").ownership,
                       .observed(ServiceSource(path: url.path, sha256: ServiceHash.sha256(original), fileMode: 0o644)))
        XCTAssertEqual(PrivateFile.mode(url), 0o644)
        XCTAssertEqual(launchd.calls.filter { $0.hasPrefix("bootstrap") }.count, 1, "Reverting starts nothing")
    }

    // MARK: Automatic startup is separate from the current session

    func testTurningAutomaticStartupOffLeavesTheRunningJobAlone() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.start(label)
        let running = try status(label).activity
        let callsBefore = launchd.calls

        try controller.setAutomaticStartup(label, enabled: false)

        XCTAssertEqual(launchd.calls, callsBefore, "The preference applies at the next login only")
        XCTAssertEqual(try status(label).activity, running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.installedPlist(label).path))
        XCTAssertFalse(try sandbox.definition(label).automaticStartup)
        XCTAssertEqual(try status(label).problems, [])
    }

    func testManualStartWorksWhileAutomaticStartupIsOffAndDoesNotChangeIt() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.setAutomaticStartup(label, enabled: false)

        try controller.start(label)

        XCTAssertEqual(launchd.calls, ["bootstrap \(sandbox.paths.sessionPlist(label).path)"])
        guard case .running = try status(label).activity else { return XCTFail("Expected a running service") }
        XCTAssertEqual(try status(label).loadedInstance, .managed)
        XCTAssertFalse(try sandbox.definition(label).automaticStartup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.installedPlist(label).path),
                       "Nothing was put where macOS would load it at login")
    }

    func testTurningAutomaticStartupOnInstallsTheDefinitionAndStartsNothing() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.setAutomaticStartup(label, enabled: false)
        try controller.setAutomaticStartup(label, enabled: true)

        XCTAssertEqual(launchd.calls, [])
        XCTAssertEqual(try status(label).activity, .inactive)
        XCTAssertEqual(try sandbox.installedPlist(label)["Label"] as? String, label)
        XCTAssertTrue(try sandbox.definition(label).automaticStartup)
        // With it on, a start in this session loads the file macOS loads at login.
        try controller.start(label)
        XCTAssertEqual(launchd.calls, ["bootstrap \(sandbox.paths.installedPlist(label).path)"])
    }

    func testAutomaticStartupCannotBeChangedForAnObservedService() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        let original = try Data(contentsOf: url)
        try controller.importLaunchAgent(at: url)
        assertRefused(.conflict) { try controller.setAutomaticStartup("com.example.server", enabled: false) }
        assertRefused(.conflict) { try controller.start("com.example.server") }
        assertRefused(.conflict) { try controller.stop("com.example.server") }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(launchd.calls, [])
    }

    // MARK: Start and Stop

    func testStopUnderKeepAliveEndsTheRegistrationAndKeepsThePreference() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.start(label)

        try controller.stop(label)

        XCTAssertEqual(launchd.calls.last, "bootout \(label)", "Unloading is what keeps launchd from restarting it")
        XCTAssertNil(launchd.job(label))
        XCTAssertEqual(try status(label).activity, .inactive)
        XCTAssertTrue(try sandbox.definition(label).automaticStartup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.paths.installedPlist(label).path),
                      "The next login still loads it")
        XCTAssertEqual(launchd.calls.filter { $0.hasPrefix("kickstart") }, [])
        XCTAssertEqual(try status(label).actions, [.start, .remove])
    }

    func testStoppingIsShownUntilTheProcessAndItsLockAreGone() throws {
        var agent = sandbox.continuousAgent()
        agent["KeepAlive"] = ["SuccessfulExit": false]
        let label = try sandbox.manage(agent)
        let lockPath = sandbox.root.appendingPathComponent("owner.lock").path
        try controller.store.mutate { catalog in catalog.services[0].ownerLockPaths = [lockPath] }
        try controller.start(label)
        // The runner recorded the process the command runs in: launchd's own job process.
        let pid = try XCTUnwrap(launchd.job(label)?.pid)
        var record = ServiceRunRecord(label: label, pid: pid, startedAt: Date())
        record.processStartTime = 1000.5
        try record.write(to: sandbox.paths.runRecord(label))
        sandbox.processes.startTimes[pid] = 1000.5
        sandbox.locks.held = [lockPath]
        launchd.bootoutLeavesJob = true

        try controller.stop(label)
        XCTAssertEqual(try status(label).activity, .stopping, "launchd still lists the job")
        XCTAssertEqual(try status(label).actions, [])
        assertRefused(.busy) { try controller.start(label) }
        assertRefused(.busy) { try controller.remove(label) }

        // The registration disappearing does not show that the process exited.
        launchd.setJob(label, nil)
        XCTAssertEqual(try status(label).activity, .stopping, "The command is still alive")
        assertRefused(.busy) { try controller.remove(label) }

        // Nor does the process exiting show that the lock was released.
        sandbox.processes.startTimes[pid] = nil
        XCTAssertEqual(try status(label).activity, .stopping, "The owner lock is still held")
        XCTAssertFalse(try controller.waitUntilStopped(label, timeout: 0.05, poll: 0.01))

        sandbox.locks.held = []
        XCTAssertTrue(try controller.waitUntilStopped(label, timeout: 0.05, poll: 0.01))
        XCTAssertEqual(try status(label).activity, .inactive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.stopMarker(label).path))
        XCTAssertEqual(launchd.calls.filter { $0.hasPrefix("bootout") }.count, 1, "No second request and no kill follows")
    }

    func testAPidGivenToAnotherProcessIsNotTakenForTheCommand() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        var record = ServiceRunRecord(label: label, pid: 4002, startedAt: Date())
        record.processStartTime = 1000.5
        try record.write(to: sandbox.paths.runRecord(label))
        // The number is in use again, by a process that started later.
        sandbox.processes.startTimes[4002] = 2000
        XCTAssertEqual(try status(label).problems, [])
        XCTAssertEqual(try status(label).actions, [.start, .remove])
    }

    func testStartAfterStopLoadsTheDefinitionAgain() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.start(label)
        try controller.stop(label)
        try controller.start(label)
        XCTAssertEqual(launchd.calls, [
            "bootstrap \(sandbox.paths.installedPlist(label).path)", "bootout \(label)",
            "bootstrap \(sandbox.paths.installedPlist(label).path)"
        ])
        // Starting what already runs asks for nothing more.
        try controller.start(label)
        XCTAssertEqual(launchd.calls.count, 3)
    }

    func testAServiceThatExitedCleanlyIsStartedInPlace() throws {
        var agent = sandbox.continuousAgent()
        agent["KeepAlive"] = ["SuccessfulExit": false]
        let label = try sandbox.manage(agent)
        launchd.setJob(label, LaunchdJobSnapshot(state: "not running", lastExitCode: 0, runs: 1, program: sandbox.runner.path))
        XCTAssertEqual(try status(label).activity, .idle)
        XCTAssertEqual(try status(label).stateText, "Exited; stays stopped until started")
        XCTAssertEqual(try status(label).actions, [.start, .stop])
        try controller.start(label)
        XCTAssertEqual(launchd.calls, ["kickstart \(label)"])

        launchd.setJob(label, LaunchdJobSnapshot(state: "not running", lastExitCode: 1, runs: 2, program: sandbox.runner.path))
        XCTAssertEqual(try status(label).activity, .waiting)
        XCTAssertEqual(try status(label).stateText, "Waiting to restart after exit 1")
        XCTAssertEqual(try status(label).actions, [.stop])
    }

    func testAFailedLoadIsReportedAndLeavesNoHalfState() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        let before = try controller.store.read()
        launchd.bootstrapFailure = StartupServicesError(.launchd, "Bootstrap failed: 5: Input/output error")

        assertRefused(.launchd) { try controller.start(label) }

        XCTAssertEqual(try controller.store.read(), before)
        XCTAssertEqual(try status(label).activity, .inactive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.stopMarker(label).path))
        launchd.bootstrapFailure = nil
        try controller.start(label)
        guard case .running = try status(label).activity else { return XCTFail("Expected a running service") }
    }

    func testAFailedStopDoesNotClaimToBeStopping() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.start(label)
        launchd.bootoutFailure = StartupServicesError(.launchd, "Boot-out failed: 1: Operation not permitted")
        assertRefused(.launchd) { try controller.stop(label) }
        guard case .running = try status(label).activity else { return XCTFail("The service is still running") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.stopMarker(label).path))
    }

    func testAnUnreadableLaunchdIsReportedAsUnknownNotAsStopped() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        launchd.snapshotFailure = StartupServicesError(.launchd, "launchctl could not be run")
        guard case .unknown = try status(label).activity else { return XCTFail("Expected an unknown state") }
        XCTAssertEqual(try status(label).actions, [])
        assertRefused(.launchd) { try controller.start(label) }
    }

    // MARK: Review findings of 2026-10-11

    func testAServiceStartedAgainAfterAStopIsNotShownAsStoppingForGood() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.start(label)
        let stopped = try XCTUnwrap(launchd.job(label)?.pid)
        sandbox.processes.startTimes[stopped] = 500
        try controller.stop(label)
        sandbox.processes.startTimes[stopped] = nil
        // Before anything reads the state, the next login (or the owner, by hand) loads the job again.
        launchd.setJob(label, LaunchdJobSnapshot(state: "running", pid: 9100, runs: 1, program: sandbox.runner.path))
        sandbox.processes.startTimes[9100] = 900

        XCTAssertEqual(try status(label).activity, .running(pid: 9100), "A new process is not the one that was asked to stop")
        XCTAssertEqual(try status(label).actions, [.stop])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.stopMarker(label).path))
        // The same holds when the service's own lock is held again, by the new process.
        try controller.stop(label)
        sandbox.processes.startTimes[9100] = nil
        launchd.setJob(label, LaunchdJobSnapshot(state: "running", pid: 9200, runs: 1, program: sandbox.runner.path))
        sandbox.processes.startTimes[9200] = 950
        let lockPath = sandbox.root.appendingPathComponent("owner.lock").path
        try controller.store.mutate { catalog in catalog.services[0].ownerLockPaths = [lockPath] }
        sandbox.locks.held = [lockPath]
        XCTAssertEqual(try status(label).activity, .running(pid: 9200))
    }

    func testStoppingAJobWithNoProcessLeavesNothingToWaitFor() throws {
        let label = try sandbox.manage(sandbox.scheduledAgent())
        try controller.resumeSchedule(label)
        try controller.stop(label)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.stopMarker(label).path))
        XCTAssertEqual(try status(label).activity, .inactive)
        // Loaded again by hand, it is simply scheduled again.
        launchd.setJob(label, LaunchdJobSnapshot(state: "not running", runs: 0, program: sandbox.runner.path))
        XCTAssertEqual(try status(label).activity, .idle)
    }

    func testAScheduleThatAlsoRunsWhenLoadedIsNotOfferedAQuietResume() throws {
        var agent = sandbox.scheduledAgent()
        agent["RunAtLoad"] = true
        let label = try sandbox.manage(agent)
        XCTAssertEqual(try status(label).actions, [.runNow, .remove], "Loading it would run it; only Run Now says so")
        assertRefused(.invalid) { try controller.resumeSchedule(label) }
        XCTAssertEqual(launchd.calls, [], "Nothing was loaded, so nothing ran")
        XCTAssertNil(launchd.job(label))
    }

    func testALaunchAgentKeptOutsideTheLoginFolderDoesNotStartAtLoginAfterTakeover() throws {
        // A definition the owner keeps in a project folder and loads by hand.
        let elsewhere = sandbox.root.appendingPathComponent("project/agents")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let url = elsewhere.appendingPathComponent("com.example.server.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: sandbox.continuousAgent(), format: .xml, options: 0)
        try original.write(to: url)

        let imported = try controller.importLaunchAgent(at: url)
        XCTAssertFalse(imported.automaticStartup, "It does not start at login today, so it must not after the takeover")
        try controller.takeOver("com.example.server")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.launchAgents.path), [],
                       "Nothing was put where macOS loads it at login")
        XCTAssertEqual(try Data(contentsOf: url), original, "A file that is not loaded at login is left where it is")
        XCTAssertFalse(try sandbox.definition("com.example.server").automaticStartup)
        XCTAssertEqual(try status("com.example.server").problems, [])
        // It can still be started by hand, as before.
        try controller.start("com.example.server")
        XCTAssertEqual(launchd.calls, ["bootstrap \(sandbox.paths.sessionPlist("com.example.server").path)"])
    }

    func testSystemWideDefinitionsAreNotImported() throws {
        for path in ["/Library/LaunchDaemons/com.example.daemon.plist", "/Library/LaunchAgents/com.example.agent.plist",
                     "/System/Library/LaunchAgents/com.apple.example.plist"] {
            XCTAssertThrowsError(try controller.importLaunchAgent(at: URL(fileURLWithPath: path)), path) { error in
                XCTAssertEqual((error as? StartupServicesError)?.kind, .unsupported)
                XCTAssertTrue((error as? StartupServicesError)?.message.contains("belongs to the whole Mac") == true, "\(error)")
            }
        }
        XCTAssertEqual(try controller.store.read().services, [])
    }

    func testAFileThatCannotBeReadIsNeverTakenForAnAbsentOne() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.setAutomaticStartup(label, enabled: false)
        // Someone leaves a link that points nowhere where the LaunchAgent would go.
        let installed = sandbox.paths.installedPlist(label)
        try FileManager.default.createSymbolicLink(atPath: installed.path, withDestinationPath: "/no/such/target.plist")

        XCTAssertEqual(try status(label).problems, [.foreignDefinition(installed.path)])
        assertRefused(.conflict) { try controller.setAutomaticStartup(label, enabled: true) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installed.path), "/no/such/target.plist",
                       "The link was not replaced")
    }

    func testAcceptingAChangedLaunchAgentIsUndoneWhenTheCatalogCannotBeSaved() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        var variant = sandbox.continuousAgent()
        variant["ProgramArguments"] = [sandbox.program.path, "-l", "ru"]
        let variantData = try Data(contentsOf: try sandbox.writeAgent(variant))
        let before = try sandbox.definition(label)
        controller.store.beforeSave = { throw StartupServicesError(.storage, "disk full") }

        assertRefused(.storage) { try controller.useOutsideDefinition(label) }
        controller.store.beforeSave = nil

        XCTAssertEqual(try Data(contentsOf: sandbox.paths.installedPlist(label)), variantData, "The outside file is back as it was found")
        XCTAssertEqual(try sandbox.definition(label), before)
        XCTAssertEqual(try status(label).actions, [.useOutsideDefinition, .remove], "The same answer can be given again")
        try controller.useOutsideDefinition(label)
        XCTAssertEqual(try status(label).problems, [])
    }

    func testARollbackThatCannotBeSavedLeavesTheManagedDefinitionInPlace() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        let managedPlist = try Data(contentsOf: sandbox.paths.installedPlist(label))
        let before = try sandbox.definition(label)
        controller.store.beforeSave = { throw StartupServicesError(.storage, "disk full") }

        assertRefused(.storage) { try controller.revert(label) }
        controller.store.beforeSave = nil

        XCTAssertEqual(try Data(contentsOf: sandbox.paths.installedPlist(label)), managedPlist)
        XCTAssertEqual(try sandbox.definition(label), before)
        XCTAssertEqual(try status(label).problems, [], "Still one owner, and it is the managed one")
        try controller.revert(label)
        XCTAssertFalse(try sandbox.definition(label).isManaged)
    }

    func testAnInstallerUpdateKeepsWhatItDoesNotState() throws {
        // A scheduled job with a priority, imported and taken over.
        var agent = sandbox.scheduledAgent(label: "com.quantumcraft.reply-assistant")
        agent["Nice"] = 5
        try sandbox.manage(agent)
        var update = external()
        update.runAtLoad = nil; update.keepAlive = nil; update.throttleInterval = nil; update.processType = nil
        try controller.installDefinition(update)
        let launch = try sandbox.definition("com.quantumcraft.reply-assistant").launch
        XCTAssertEqual(launch.calendar.count, 2, "The schedule the installer did not mention is kept")
        XCTAssertEqual(launch.nice, 5)
        XCTAssertEqual(launch.restart, .never)
        XCTAssertEqual(launch.standardOutPath, update.standardOutPath)

        // The same holds for the command's settings.
        try controller.installDefinition(external())
        var bare = external(port: "9000")
        bare.environment = nil; bare.umask = nil; bare.workingDirectory = nil
        try controller.installDefinition(bare)
        let command = try sandbox.definition("com.quantumcraft.reply-assistant").command
        XCTAssertEqual(command.arguments.last, "9000")
        XCTAssertEqual(command.umask, 0o077)
        XCTAssertEqual(command.environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(command.workingDirectory, sandbox.root.path)
    }

    func testARollbackSaysAgainWhatTheOriginalItselfSays() throws {
        // Kept outside the login folder, taken over, switched on, then rolled back.
        let elsewhere = sandbox.root.appendingPathComponent("project/agents")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let url = elsewhere.appendingPathComponent("com.example.server.plist")
        try PropertyListSerialization.data(fromPropertyList: sandbox.continuousAgent(), format: .xml, options: 0).write(to: url)
        let identity = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        try controller.importLaunchAgent(at: url)
        try controller.takeOver("com.example.server")
        try controller.setAutomaticStartup("com.example.server", enabled: true)

        try controller.revert("com.example.server")

        XCTAssertFalse(try sandbox.definition("com.example.server").automaticStartup,
                       "The original is not in the login folder, so it does not start at login")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.launchAgents.path), [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, identity,
                       "An original that was never moved is not rewritten")
    }

    func testATestFolderCannotTouchARealLabel() throws {
        // A test entry that carries a real service's label, managed from a test folder.
        let guarded = StartupServicesController(paths: sandbox.paths, transport: SelfTestOnlyTransport(launchd),
                                                invocation: ServiceRunnerInvocation(runnerPath: sandbox.runner.path),
                                                processes: sandbox.processes, locks: sandbox.locks, permission: sandbox.permission)
        let real = try sandbox.manage(sandbox.continuousAgent(label: "com.globesoul.wg-keepalive"))
        launchd.setJob(real, LaunchdJobSnapshot(state: "running", pid: 1040, program: "/sbin/ping"))

        XCTAssertEqual(try guarded.status(real).activity, .running(pid: 1040), "Reading is allowed")
        assertRefused(.invalid) { try guarded.stop(real) }
        XCTAssertEqual(launchd.job(real)?.pid, 1040, "The real job was not unloaded")
        launchd.setJob(real, nil)
        assertRefused(.invalid) { try guarded.start(real) }
        XCTAssertEqual(launchd.calls, [])

        let test = try sandbox.manage(sandbox.continuousAgent(label: SelfTestOnlyTransport.labelPrefix + "server"))
        try guarded.start(test)
        try guarded.stop(test)
        XCTAssertEqual(launchd.calls.count, 2)
    }

    // MARK: One-shot and scheduled jobs

    func testImportingACompletedLoginJobDoesNotRunItAgain() throws {
        let url = try sandbox.writeAgent(sandbox.oneShotAgent())
        launchd.setJob("com.example.login", LaunchdJobSnapshot(state: "not running", lastExitCode: 0, runs: 1, program: sandbox.program.path))
        try controller.importLaunchAgent(at: url)
        try controller.takeOver("com.example.login")
        _ = try controller.statuses()

        XCTAssertEqual(launchd.calls, [], "A login job that already ran is not run again by importing it")
        XCTAssertEqual(launchd.job("com.example.login")?.runs, 1)
        let after = try status("com.example.login")
        XCTAssertEqual(after.activity, .idle)
        XCTAssertEqual(after.stateText, "Finished")
        XCTAssertEqual(after.lastResult?.exitCode, 0)
        XCTAssertEqual(after.actions, [.runNow, .stop])
    }

    func testRunNowRunsAOneShotOnceMoreAndNeverTwiceAtOnce() throws {
        let label = try sandbox.manage(sandbox.oneShotAgent())
        launchd.setJob(label, LaunchdJobSnapshot(state: "not running", lastExitCode: 0, runs: 1, program: sandbox.runner.path))

        try controller.runNow(label)
        XCTAssertEqual(launchd.calls, ["kickstart \(label)"])
        guard case .running = try status(label).activity else { return XCTFail("Expected a running job") }
        XCTAssertEqual(try status(label).actions, [.stop])

        assertRefused(.busy) { try controller.runNow(label) }
        XCTAssertEqual(launchd.calls, ["kickstart \(label)"], "A run in progress is not doubled")
        assertRefused(.invalid) { try controller.start(label) }
    }

    func testRunNowOfAnUnloadedOneShotLoadsItOnce() throws {
        let label = try sandbox.manage(sandbox.oneShotAgent())
        try controller.runNow(label)
        // Loading a run-at-load job is the run; no second start is asked for.
        XCTAssertEqual(launchd.calls, ["bootstrap \(sandbox.paths.installedPlist(label).path)"])
        XCTAssertEqual(launchd.job(label)?.runs, 1)
    }

    func testAScheduledJobIsShownAsScheduledAndRunsOnlyWhenAsked() throws {
        let label = try sandbox.manage(sandbox.scheduledAgent())
        XCTAssertEqual(try sandbox.definition(label).kind, .scheduled)
        XCTAssertEqual(try status(label).actions, [.runNow, .resumeSchedule, .remove])

        try controller.resumeSchedule(label)
        XCTAssertEqual(launchd.calls, ["bootstrap \(sandbox.paths.installedPlist(label).path)"])
        XCTAssertEqual(try status(label).activity, .idle)
        XCTAssertEqual(try status(label).stateText, "Scheduled; not running now")
        XCTAssertEqual(try status(label).actions, [.runNow, .stop])
        XCTAssertNil(launchd.job(label)?.pid, "Putting the schedule back does not run the job")

        try controller.runNow(label)
        XCTAssertEqual(launchd.calls.last, "kickstart \(label)")
        assertRefused(.busy) { try controller.runNow(label) }

        try controller.stop(label)
        XCTAssertEqual(try status(label).activity, .inactive)
        try controller.runNow(label)
        XCTAssertEqual(Array(launchd.calls.suffix(2)), ["bootstrap \(sandbox.paths.installedPlist(label).path)", "kickstart \(label)"])
        assertRefused(.invalid) { try controller.start(label) }
    }

    func testAContinuousServiceHasNoRunNow() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        assertRefused(.invalid) { try controller.runNow(label) }
        assertRefused(.invalid) { try controller.resumeSchedule(label) }
        XCTAssertEqual(launchd.calls, [])
    }

    // MARK: Problems are shown at the service and block only what they must

    func testAMissingProgramIsReportedAndNotStarted() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try FileManager.default.moveItem(at: sandbox.program, to: sandbox.root.appendingPathComponent("moved"))

        XCTAssertEqual(try status(label).problems, [.executableMissing(sandbox.program.path)])
        XCTAssertEqual(try status(label).actions, [.remove])
        assertRefused(.invalid) { try controller.start(label) }
        XCTAssertEqual(launchd.calls, [])
    }

    func testAMissingRunnerIsReportedAndNotStarted() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try FileManager.default.removeItem(at: sandbox.runner)
        XCTAssertEqual(try status(label).problems, [.runnerMissing(sandbox.runner.path)])
        assertRefused(.notInstalled) { try controller.start(label) }
        XCTAssertEqual(launchd.calls, [])
    }

    func testABlockedBackgroundPermissionIsReportedAndNotWorkedAround() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        sandbox.permission.value = .blocked

        XCTAssertEqual(try status(label).problems, [.permissionBlocked])
        XCTAssertEqual(try status(label).actions, [.remove])
        assertRefused(.blocked) { try controller.start(label) }
        XCTAssertEqual(launchd.calls, [], "No load from another path is tried")
        XCTAssertEqual(sandbox.permission.asked.last, [sandbox.paths.installedPlist(label)])

        // A running service can still be stopped while blocked.
        sandbox.permission.value = .allowed
        try controller.start(label)
        sandbox.permission.value = .blocked
        XCTAssertEqual(try status(label).actions, [.stop])
        try controller.stop(label)
        XCTAssertEqual(try status(label).activity, .inactive)
    }

    func testAReappearingOriginalIsNeverOverwrittenOrRunBesideTheManagedOne() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        // The service's old installer writes its own LaunchAgent again.
        let foreignURL = try sandbox.writeAgent(sandbox.continuousAgent())
        let foreign = try Data(contentsOf: foreignURL)

        XCTAssertEqual(try status(label).problems, [.definitionChangedOutside(foreignURL.path)])
        XCTAssertEqual(try status(label).actions, [.useOutsideDefinition, .remove])
        assertRefused(.conflict) { try controller.start(label) }
        assertRefused(.conflict) { try controller.setAutomaticStartup(label, enabled: false) }
        assertRefused(.conflict) { try controller.setAutomaticStartup(label, enabled: true) }
        XCTAssertEqual(launchd.calls, [])
        XCTAssertEqual(try Data(contentsOf: foreignURL), foreign)

        // Removing the managed entry leaves the foreign file, which can then be imported as it is.
        try controller.remove(label)
        XCTAssertEqual(try Data(contentsOf: foreignURL), foreign)
        XCTAssertFalse(try controller.importLaunchAgent(at: foreignURL).isManaged)
    }

    func testALaunchAgentAppearingWhileAutomaticStartupIsOffIsAConflict() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.setAutomaticStartup(label, enabled: false)
        let foreignURL = try sandbox.writeAgent(sandbox.continuousAgent())
        let foreign = try Data(contentsOf: foreignURL)

        XCTAssertEqual(try status(label).problems, [.foreignDefinition(foreignURL.path)])
        assertRefused(.conflict) { try controller.start(label) }
        assertRefused(.conflict) { try controller.setAutomaticStartup(label, enabled: true) }
        XCTAssertEqual(try Data(contentsOf: foreignURL), foreign)
    }

    func testAChangedLaunchAgentBecomesTheDefinitionOnlyWhenTheOwnerSaysSo() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try controller.rename(label, to: "Speech server")
        try controller.start(label)
        let callsBefore = launchd.calls
        // The owner swaps the LaunchAgent by hand for another variant, as before the takeover.
        var variant = sandbox.continuousAgent()
        variant["ProgramArguments"] = [sandbox.program.path, "-l", "ru"]
        variant["ThrottleInterval"] = 20
        let variantURL = try sandbox.writeAgent(variant)
        let variantData = try Data(contentsOf: variantURL)
        XCTAssertEqual(try sandbox.definition(label).command.arguments.last, "8765", "Nothing changes by itself")
        XCTAssertEqual(try status(label).actions, [.useOutsideDefinition, .stop])

        try controller.useOutsideDefinition(label)

        let definition = try sandbox.definition(label)
        XCTAssertEqual(definition.command.arguments, [sandbox.program.path, "-l", "ru"])
        XCTAssertEqual(definition.launch.throttleInterval, 20)
        XCTAssertEqual(definition.name, "Speech server")
        XCTAssertTrue(definition.automaticStartup)
        guard case .managed(_, let backup?) = definition.ownership else { return XCTFail("Expected a backup") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup.path)), variantData, "The hand-written file is kept exactly")
        XCTAssertEqual(try sandbox.installedPlist(label)["ProgramArguments"] as? [String], [sandbox.runner.path, "run", label])
        XCTAssertEqual(try sandbox.installedPlist(label)["ThrottleInterval"] as? Int, 20)
        XCTAssertEqual(try status(label).problems, [])
        XCTAssertEqual(launchd.calls, callsBefore, "Nothing is started or stopped; the running process uses it from its next start")

        // A file that cannot be preserved is refused and left as found.
        var unsupported = variant
        unsupported["WatchPaths"] = ["/tmp"]
        let unsupportedData = try Data(contentsOf: try sandbox.writeAgent(unsupported))
        assertRefused(.unsupported) { try controller.useOutsideDefinition(label) }
        XCTAssertEqual(try Data(contentsOf: variantURL), unsupportedData)
        XCTAssertEqual(try sandbox.definition(label), definition)

        // So is one that defines another label.
        try sandbox.writeAgent(sandbox.continuousAgent(label: "com.example.other"), named: label)
        assertRefused(.conflict) { try controller.useOutsideDefinition(label) }
        XCTAssertEqual(try sandbox.definition(label), definition)
    }

    func testALabelSwitchedOffInLaunchdIsImportedAsOffAndCanStillBeStartedByHand() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        let original = try Data(contentsOf: url)
        launchd.disabled = ["com.example.server"]

        XCTAssertEqual(try controller.discover().first?.definition?.automaticStartup, false)
        let imported = try controller.importLaunchAgent(at: url)
        XCTAssertFalse(imported.automaticStartup, "The owner's current choice is kept: it does not start at login")
        XCTAssertEqual(try status("com.example.server").stateText, "Not registered; switched off in launchd")
        XCTAssertEqual(launchd.calls, [])

        try controller.takeOver("com.example.server")
        XCTAssertEqual(launchd.calls, ["enable com.example.server"], "launchd's off switch is replaced by the managed one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Nothing is left for macOS to load at login")
        guard case .managed(nil, let backup?) = try sandbox.definition("com.example.server").ownership else {
            return XCTFail("Expected no installed plist and a backup")
        }
        XCTAssertTrue(backup.launchdDisabled)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup.path)), original)
        XCTAssertEqual(try status("com.example.server").problems, [])

        // Manual Start now works while automatic startup stays off.
        try controller.start("com.example.server")
        XCTAssertEqual(launchd.calls.last, "bootstrap \(sandbox.paths.sessionPlist("com.example.server").path)")
        XCTAssertFalse(try sandbox.definition("com.example.server").automaticStartup)

        // The rollback restores both the file and launchd's switch.
        try controller.stop("com.example.server")
        try controller.revert("com.example.server")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(launchd.calls.last, "disable com.example.server")
        XCTAssertEqual(launchd.disabled, ["com.example.server"])
    }

    func testATakeoverThatCannotBeSavedPutsLaunchdsSwitchBackToo() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        let original = try Data(contentsOf: url)
        launchd.disabled = ["com.example.server"]
        try controller.importLaunchAgent(at: url)
        controller.store.beforeSave = { throw StartupServicesError(.storage, "disk full") }
        assertRefused(.storage) { try controller.takeOver("com.example.server") }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(launchd.disabled, ["com.example.server"])
        XCTAssertEqual(launchd.calls, ["enable com.example.server", "disable com.example.server"])
    }

    func testAManagedLabelSwitchedOffInLaunchdIsReportedAndNotStarted() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        launchd.disabled = [label]
        XCTAssertEqual(try status(label).problems, [.disabledInLaunchd(label)])
        XCTAssertEqual(try status(label).actions, [.remove])
        assertRefused(.blocked) { try controller.start(label) }
        XCTAssertEqual(launchd.calls, [], "MacHelm does not clear a switch someone set afterwards")
        XCTAssertTrue(try sandbox.definition(label).automaticStartup, "The saved preference is a separate fact")
    }

    func testADeletedInstalledDefinitionIsReportedAndCanBeSwitchedOffOrOnAgain() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        try FileManager.default.removeItem(at: sandbox.paths.installedPlist(label))
        XCTAssertEqual(try status(label).problems, [.definitionMissing(sandbox.paths.installedPlist(label).path)])
        assertRefused(.conflict) { try controller.start(label) }
        try controller.setAutomaticStartup(label, enabled: true)
        XCTAssertEqual(try status(label).problems, [])
    }

    func testAStrayProcessBlocksASecondOwner() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        var record = ServiceRunRecord(label: label, pid: 4002, startedAt: Date())
        record.processStartTime = 1000.5
        try record.write(to: sandbox.paths.runRecord(label))
        sandbox.processes.startTimes[4002] = 1000.5

        XCTAssertEqual(try status(label).problems, [.strayProcess(4002)])
        assertRefused(.busy) { try controller.start(label) }
        assertRefused(.busy) { try controller.remove(label) }
        XCTAssertEqual(launchd.calls, [])
    }

    // MARK: Remove

    func testRemoveNeedsACompletedStopAndKeepsEverythingElse() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        let original = try Data(contentsOf: url)
        try controller.importLaunchAgent(at: url)
        try controller.takeOver("com.example.server")
        let label = "com.example.server"
        let log = sandbox.root.appendingPathComponent("server.log")
        try Data("log line\n".utf8).write(to: log)
        try controller.start(label)

        assertRefused(.busy) { try controller.remove(label) }
        XCTAssertNotNil(try controller.store.read().service(label))

        try controller.stop(label)
        guard case .managed(_, let backup?) = try sandbox.definition(label).ownership else { return XCTFail("Expected a backup") }
        try controller.remove(label)

        XCTAssertNil(try controller.store.read().service(label))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "The original is not put back by Remove")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.sessionPlist(label).path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backup.path)), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.program.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        XCTAssertEqual(launchd.calls.filter { $0.hasPrefix("bootstrap") }.count, 1)
    }

    func testRemovingAnObservedEntryTouchesNothingElse() throws {
        let url = try sandbox.writeAgent(sandbox.continuousAgent())
        let original = try Data(contentsOf: url)
        launchd.setJob("com.example.server", LaunchdJobSnapshot(state: "running", pid: 77, program: sandbox.program.path))
        try controller.importLaunchAgent(at: url)
        try controller.remove("com.example.server")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(launchd.calls, [])
        XCTAssertNotNil(launchd.job("com.example.server"))
    }

    // MARK: Add

    func testAddSavesASwitchedOffDefinitionAndRunsNothing() throws {
        let definition = try controller.add(NewServiceRequest(
            name: "  Nightly Report  ", program: sandbox.program.path, arguments: ["--all", "two words"],
            workingDirectory: sandbox.root.path, preset: .calendar([ServiceCalendarEntry(minute: 0, hour: 2)])))

        XCTAssertEqual(launchd.calls, [])
        XCTAssertEqual(definition.name, "Nightly Report")
        XCTAssertEqual(definition.label, "io.github.sergkhl.MacHelm.service.nightly-report")
        XCTAssertEqual(definition.command.arguments, [sandbox.program.path, "--all", "two words"])
        XCTAssertFalse(definition.automaticStartup)
        XCTAssertEqual(definition.kind, .scheduled)
        XCTAssertEqual(definition.launch.standardOutPath, sandbox.paths.logs.appendingPathComponent(definition.label + ".log").path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.launchAgents.path), [])
        XCTAssertEqual(try status(definition.label).activity, .inactive)

        let once = try controller.add(NewServiceRequest(name: "Nightly report", program: sandbox.program.path, preset: .onceAtLogin))
        XCTAssertEqual(once.label, "io.github.sergkhl.MacHelm.service.nightly-report-2", "A second service never shares a label")
        XCTAssertEqual(once.kind, .oneShot)
        let kept = try controller.add(NewServiceRequest(name: "Keeper", program: sandbox.program.path, preset: .keepRunning))
        XCTAssertEqual(kept.launch.restart, .always)
        XCTAssertEqual(kept.kind, .continuous)
    }

    func testAddRefusesWhatCannotRun() throws {
        let notExecutable = sandbox.root.appendingPathComponent("notes.txt")
        try Data("text".utf8).write(to: notExecutable)
        let requests = [
            NewServiceRequest(name: "", program: sandbox.program.path, preset: .onceAtLogin),
            NewServiceRequest(name: "x", program: "relative/tool", preset: .onceAtLogin),
            NewServiceRequest(name: "x", program: notExecutable.path, preset: .onceAtLogin),
            NewServiceRequest(name: "x", program: sandbox.root.path, preset: .onceAtLogin),
            NewServiceRequest(name: "x", program: sandbox.program.path, workingDirectory: "/no/such/folder", preset: .onceAtLogin),
            NewServiceRequest(name: "x", program: sandbox.program.path, preset: .calendar([]))
        ]
        for request in requests {
            assertRefused(.invalid) { try controller.add(request) }
        }
        XCTAssertEqual(try controller.store.read().services, [])
    }

    func testRenameChangesOnlyTheName() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        let installed = try Data(contentsOf: sandbox.paths.installedPlist(label))
        try controller.rename(label, to: " My server ")
        XCTAssertEqual(try sandbox.definition(label).name, "My server")
        XCTAssertEqual(try Data(contentsOf: sandbox.paths.installedPlist(label)), installed)
        XCTAssertEqual(try status(label).problems, [])
        assertRefused(.invalid) { try controller.rename(label, to: "  ") }
        assertRefused(.notFound) { try controller.rename("com.example.none", to: "x") }
    }

    // MARK: A managed service's own installer

    private func external(port: String = "8765") -> ExternalServiceDefinition {
        ExternalServiceDefinition(
            label: "com.quantumcraft.reply-assistant", name: nil, program: sandbox.program.path,
            arguments: [sandbox.program.path, "--mode", "personal", "--port", port], workingDirectory: sandbox.root.path,
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8"], umask: 0o077, runAtLoad: true,
            keepAlive: .afterFailure, throttleInterval: 30, processType: "Background", exitTimeOut: nil,
            standardOutPath: sandbox.root.appendingPathComponent("service.log").path,
            standardErrorPath: sandbox.root.appendingPathComponent("service-error.log").path,
            ownerLockPaths: [sandbox.root.appendingPathComponent("service.owner.lock").path])
    }

    func testAnInstallerCreatesASwitchedOffManagedDefinition() throws {
        let definition = try controller.installDefinition(external())
        XCTAssertEqual(definition.name, "Telegram Reply Assistant")
        XCTAssertTrue(definition.isManaged)
        XCTAssertFalse(definition.automaticStartup)
        XCTAssertEqual(definition.launch.restart, .afterFailure)
        XCTAssertEqual(definition.command.umask, 0o077)
        XCTAssertEqual(launchd.calls, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.launchAgents.path), [],
                       "The installer no longer writes a LaunchAgent of its own")
    }

    func testAnInstallerUpdateKeepsNameAndPreferenceAndNeedsAStoppedService() throws {
        try controller.installDefinition(external())
        let label = "com.quantumcraft.reply-assistant"
        try controller.rename(label, to: "Replies")
        try controller.setAutomaticStartup(label, enabled: true)
        try controller.start(label)

        assertRefused(.busy) { try controller.installDefinition(external(port: "9000")) }
        XCTAssertEqual(try sandbox.definition(label).command.arguments.last, "8765")

        try controller.stop(label)
        try controller.installDefinition(external(port: "9000"))
        let updated = try sandbox.definition(label)
        XCTAssertEqual(updated.command.arguments.last, "9000")
        XCTAssertEqual(updated.name, "Replies")
        XCTAssertTrue(updated.automaticStartup)
        XCTAssertEqual(try status(label).problems, [], "The installed plist was written again and still matches")
        XCTAssertEqual(try sandbox.installedPlist(label)["Umask"] as? Int, 0o077)
    }

    func testAnInstallerCannotReplaceAnotherOwner() throws {
        // The original LaunchAgent is still the owner: imported, not taken over.
        var agent = sandbox.continuousAgent(label: "com.quantumcraft.reply-assistant")
        agent["KeepAlive"] = ["SuccessfulExit": false]
        let url = try sandbox.writeAgent(agent)
        let original = try Data(contentsOf: url)
        assertRefused(.conflict) { try controller.installDefinition(external()) }
        XCTAssertEqual(try controller.store.read().services, [], "An existing LaunchAgent is imported, never replaced")

        try controller.importLaunchAgent(at: url)
        assertRefused(.conflict) { try controller.installDefinition(external()) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(launchd.calls, [])

        // After the old installer writes its plist over the managed one, the update is refused too.
        try controller.takeOver("com.quantumcraft.reply-assistant")
        try sandbox.writeAgent(agent)
        assertRefused(.conflict) { try controller.installDefinition(external(port: "9000")) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAnInstallerDefinitionIsValidated() throws {
        var bad = external(); bad.label = "bad/label"
        assertRefused(.invalid) { try controller.installDefinition(bad) }
        bad = external(); bad.program = "python"
        assertRefused(.invalid) { try controller.installDefinition(bad) }
        bad = external(); bad.processType = "Turbo"
        assertRefused(.invalid) { try controller.installDefinition(bad) }
        bad = external(); bad.umask = 99999
        assertRefused(.invalid) { try controller.installDefinition(bad) }
    }

    // MARK: Concurrent edits and storage

    func testConcurrentChangesFromTwoOwnersAreSerialised() throws {
        let label = try sandbox.manage(sandbox.continuousAgent())
        let other = sandbox.secondController()
        let group = DispatchGroup()
        let failures = NSLock()
        var errors: [String] = []
        for index in 0..<40 {
            group.enter()
            DispatchQueue.global().async { [controller, program = sandbox.program.path] in
                defer { group.leave() }
                do {
                    let owner = index.isMultiple(of: 2) ? controller : other
                    try owner.add(NewServiceRequest(name: "Job \(index)", program: program, preset: .onceAtLogin))
                    try owner.rename(label, to: "Server \(index)")
                    try owner.setAutomaticStartup(label, enabled: index.isMultiple(of: 3))
                } catch {
                    failures.lock(); errors.append("\(error)"); failures.unlock()
                }
            }
        }
        group.wait()

        XCTAssertEqual(errors, [])
        let catalog = try controller.store.read()
        XCTAssertEqual(catalog.services.count, 41, "No edit was lost")
        XCTAssertEqual(Set(catalog.services.map(\.label)).count, 41)
        // The file on disk and the catalog still agree with each other.
        XCTAssertEqual(try status(label).problems, [])
        XCTAssertEqual(FileManager.default.fileExists(atPath: sandbox.paths.installedPlist(label).path),
                       try sandbox.definition(label).automaticStartup)
        XCTAssertEqual(launchd.calls, [])
    }

    func testADamagedOrNewerCatalogIsLeftUntouched() throws {
        try sandbox.manage(sandbox.continuousAgent())
        for content in ["{ not json", "{\"schemaVersion\": 99, \"services\": []}"] {
            try Data(content.utf8).write(to: sandbox.paths.catalog)
            XCTAssertThrowsError(try controller.statuses())
            assertRefused(.storage) { try controller.add(NewServiceRequest(name: "x", program: sandbox.program.path, preset: .onceAtLogin)) }
            XCTAssertEqual(try String(contentsOf: sandbox.paths.catalog, encoding: .utf8), content)
        }
    }

    func testCatalogFilesArePrivate() throws {
        try sandbox.manage(sandbox.continuousAgent())
        XCTAssertEqual(PrivateFile.mode(sandbox.paths.catalog), 0o600)
        XCTAssertEqual(PrivateFile.mode(sandbox.paths.root), 0o700)
        XCTAssertEqual(PrivateFile.mode(sandbox.paths.backups), 0o700)
    }

    func testLastResultIsLaunchdsUnlessTheCommandCouldNotStart() throws {
        let label = try sandbox.manage(sandbox.oneShotAgent())
        launchd.setJob(label, LaunchdJobSnapshot(state: "not running", lastExitCode: 3, runs: 2, program: sandbox.runner.path))
        var record = ServiceRunRecord(label: label, pid: 11, startedAt: Date(timeIntervalSince1970: 100))
        record.processStartTime = 100
        try record.write(to: sandbox.paths.runRecord(label))
        XCTAssertEqual(try status(label).lastResult, ServiceLastResult(exitCode: 3, terminatingSignal: nil, failure: nil))
        XCTAssertEqual(try status(label).lastResult?.summary, "Failed (exit 3)")

        launchd.setJob(label, LaunchdJobSnapshot(state: "not running", lastExitCode: nil, lastTerminatingSignal: "Killed: 9",
                                                 runs: 3, program: sandbox.runner.path))
        XCTAssertEqual(try status(label).lastResult?.summary, "Ended by a signal (Killed: 9)")

        launchd.setJob(label, LaunchdJobSnapshot(state: "not running", lastExitCode: 78, runs: 4, program: sandbox.runner.path))
        record.failure = "The program is missing or cannot be executed: /x"
        try record.write(to: sandbox.paths.runRecord(label))
        XCTAssertEqual(try status(label).lastResult?.summary, "Could not start: The program is missing or cannot be executed: /x")
        XCTAssertEqual(try status(label).problems, [], "A record of a failed start is not a live process")
    }
}
