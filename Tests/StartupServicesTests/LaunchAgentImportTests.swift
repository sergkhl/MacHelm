import XCTest
@testable import StartupServicesCore

final class LaunchAgentImportTests: XCTestCase {
    private func plistData(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func imported(_ plist: [String: Any]) throws -> ServiceDefinition {
        try LaunchAgentImporter.definition(fromPlist: try plistData(plist), sourcePath: "/tmp/source.plist")
    }

    private func rendered(_ definition: ServiceDefinition) -> [String: Any] {
        LaunchAgentRenderer.plist(for: definition, invocation: ServiceRunnerInvocation(runnerPath: "/Applications/MacHelm.app/runner"))
    }

    // The six retained jobs, in the shapes the audit recorded.
    private let retained: [[String: Any]] = [
        ["Label": "com.globesoul.wg-keepalive", "ProgramArguments": ["/sbin/ping", "-q", "-i", "20", "10.8.0.1"],
         "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 30, "ProcessType": "Background",
         "StandardOutPath": "/dev/null", "StandardErrorPath": "/tmp/wg-keepalive.err"],
        ["Label": "com.globesoul.skyrimnet-native-tts", "ProgramArguments": ["/opt/tts/.venv/bin/python", "server.py"],
         "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10, "ProcessType": "Interactive",
         "WorkingDirectory": "/opt/tts", "StandardOutPath": "/tmp/native.log", "StandardErrorPath": "/tmp/native.log"],
        ["Label": "com.globesoul.skyrimnet-fish-tts", "ProgramArguments": ["/opt/tts/.venv/bin/python", "fish_server.py"],
         "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10, "ProcessType": "Interactive",
         "WorkingDirectory": "/opt/tts", "StandardOutPath": "/tmp/fish.log", "StandardErrorPath": "/tmp/fish.log"],
        ["Label": "local.whisper-server.skyrimnet",
         "ProgramArguments": ["/opt/homebrew/bin/whisper-server", "-m", "/models/a model.bin", "--prompt", "I escaped Helgen, with Ralof."],
         "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Interactive",
         "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
         "WorkingDirectory": "/Users/someone/Library/Application Support/whisper-server",
         "StandardOutPath": "/tmp/whisper.log", "StandardErrorPath": "/tmp/whisper.log"],
        ["Label": "com.quantumcraft.reply-assistant",
         "ProgramArguments": ["/opt/reply/.venv/bin/python", "-m", "reply_assistant.cli", "--mode", "personal", "--port", "8765"],
         "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 30, "ProcessType": "Background",
         "Umask": 0o077, "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8"],
         "WorkingDirectory": "/opt/reply", "StandardOutPath": "/opt/reply/.local/service/service.log",
         "StandardErrorPath": "/opt/reply/.local/service/service-error.log"],
        ["Label": "com.user.loginscript", "ProgramArguments": ["/bin/zsh", "/Users/someone/optimize_tahoe.sh"], "RunAtLoad": true]
    ]

    func testEachRetainedJobKeepsEveryLaunchdFieldWhenRendered() throws {
        for source in retained {
            let definition = try imported(source)
            var output = rendered(definition)
            // The managed job runs the runner and is attributed to the app; the rest must be the source.
            XCTAssertEqual(output.removeValue(forKey: "ProgramArguments") as? [String],
                           ["/Applications/MacHelm.app/runner", "run", definition.label])
            XCTAssertEqual(output.removeValue(forKey: "AssociatedBundleIdentifiers") as? [String], ["io.github.sergkhl.MacHelm"])
            var expected = source
            expected.removeValue(forKey: "ProgramArguments")
            XCTAssertEqual(output as NSDictionary, expected as NSDictionary, definition.label)
            // The command itself is kept as typed arguments, never as a shell line.
            XCTAssertEqual(definition.command.arguments, source["ProgramArguments"] as? [String])
            XCTAssertEqual(definition.command.program, (source["ProgramArguments"] as? [String])?.first)
            XCTAssertTrue(definition.automaticStartup)
        }
    }

    func testRetainedJobsGetTheirAcceptedNamesKindsAndNotes() throws {
        let definitions = try retained.map(imported)
        XCTAssertEqual(definitions.map(\.name), [
            "WireGuard Keepalive", "Skyrim English Speech — Pocket TTS", "Skyrim Russian Speech — Fish TTS",
            "Skyrim Speech Recognition — Whisper", "Telegram Reply Assistant", "Tahoe Background Process Priority"
        ])
        XCTAssertEqual(definitions.map(\.kind), [.continuous, .continuous, .continuous, .continuous, .continuous, .oneShot])
        XCTAssertEqual(definitions[4].launch.restart, .afterFailure)
        XCTAssertEqual(definitions[4].ownerLockPaths, ["/opt/reply/.local/service.owner.lock"])
        XCTAssertEqual(definitions[2].dependencies.count, 1)
        XCTAssertEqual(Set(definitions.map(\.label)).count, 6)
    }

    func testProgramKeyAndArgumentsAreBothKept() throws {
        let definition = try imported(["Label": "a.b", "Program": "/bin/real", "ProgramArguments": ["shown-name", "x"]])
        XCTAssertEqual(definition.command.program, "/bin/real")
        XCTAssertEqual(definition.command.arguments, ["shown-name", "x"])
        let alone = try imported(["Label": "a.c", "Program": "/bin/real"])
        XCTAssertEqual(alone.command.arguments, ["/bin/real"])
    }

    func testCalendarAsOneEntryOrSeveralIsKept() throws {
        let single = try imported(["Label": "a.single", "ProgramArguments": ["/bin/x"],
                                   "StartCalendarInterval": ["Weekday": 0, "Hour": 5, "Minute": 30]])
        XCTAssertEqual(single.kind, .scheduled)
        XCTAssertEqual(single.launch.calendar, [ServiceCalendarEntry(minute: 30, hour: 5, weekday: 0)])
        XCTAssertEqual(rendered(single)["StartCalendarInterval"] as? [String: Int], ["Weekday": 0, "Hour": 5, "Minute": 30])

        let several = try imported(["Label": "a.several", "ProgramArguments": ["/bin/x"],
                                    "StartCalendarInterval": [["Hour": 3, "Minute": 45], ["Hour": 9, "Minute": 45]]])
        XCTAssertEqual(several.launch.calendar.count, 2)
        XCTAssertEqual(rendered(several)["StartCalendarInterval"] as? [[String: Int]],
                       [["Hour": 3, "Minute": 45], ["Hour": 9, "Minute": 45]])
        XCTAssertEqual(single.launch.calendar[0].summary, "Sunday 05:30")
    }

    func testDisabledSourceIsImportedWithAutomaticStartupOff() throws {
        let definition = try imported(["Label": "a.off", "ProgramArguments": ["/bin/x"], "RunAtLoad": true, "Disabled": true])
        XCTAssertFalse(definition.automaticStartup)
        XCTAssertNil(rendered(definition)["Disabled"])
    }

    func testUnsupportedFieldsRefuseTheImportByName() throws {
        let source: [String: Any] = ["Label": "a.b", "ProgramArguments": ["/bin/x"], "WatchPaths": ["/tmp"],
                                     "Sockets": ["Listeners": ["SockServiceName": "8080"]], "UserName": "root"]
        XCTAssertThrowsError(try imported(source)) { error in
            let refusal = error as? StartupServicesError
            XCTAssertEqual(refusal?.kind, .unsupported)
            for key in ["WatchPaths", "Sockets", "UserName"] {
                XCTAssertTrue(refusal?.message.contains(key) == true, key)
            }
        }
    }

    func testKeepAliveConditionsOtherThanSuccessfulExitFalseAreRefused() throws {
        for keepAlive: Any in [["NetworkState": true], ["SuccessfulExit": true], ["SuccessfulExit": false, "Crashed": true], "yes", 1] {
            XCTAssertThrowsError(try imported(["Label": "a.b", "ProgramArguments": ["/bin/x"], "KeepAlive": keepAlive])) { error in
                XCTAssertTrue((error as? StartupServicesError)?.message.contains("KeepAlive") == true)
            }
        }
        XCTAssertEqual(try imported(["Label": "a.b", "ProgramArguments": ["/bin/x"], "KeepAlive": false]).launch.restart, .never)
    }

    func testWrongTypesAndBadValuesAreRefused() throws {
        let bad: [[String: Any]] = [
            ["Label": "a.b", "ProgramArguments": ["/bin/x"], "RunAtLoad": 1],
            ["Label": "a.b", "ProgramArguments": ["/bin/x"], "ThrottleInterval": true],
            ["Label": "a.b", "ProgramArguments": ["/bin/x"], "ThrottleInterval": 10.5],
            ["Label": "a.b", "ProgramArguments": ["/bin/x"], "ProcessType": "Turbo"],
            ["Label": "a.b", "ProgramArguments": ["/bin/x"], "EnvironmentVariables": ["A": 1]],
            ["Label": "a.b", "ProgramArguments": ["/bin/x"], "Umask": 4096],
            ["Label": "a.b", "ProgramArguments": ["/bin/x"], "StartCalendarInterval": ["Hour": 24]],
            ["Label": "a.b", "ProgramArguments": ["/bin/x"], "StartCalendarInterval": ["Second": 1]],
            ["Label": "a.b", "ProgramArguments": ["relative/program"]],
            ["Label": "a.b", "ProgramArguments": [String]()],
            ["Label": "a.b"],
            ["Label": "../escape", "ProgramArguments": ["/bin/x"]],
            ["Label": "", "ProgramArguments": ["/bin/x"]],
            ["ProgramArguments": ["/bin/x"]]
        ]
        for source in bad {
            XCTAssertThrowsError(try imported(source), "\(source)") { error in
                XCTAssertEqual((error as? StartupServicesError)?.kind, .unsupported)
            }
        }
        XCTAssertThrowsError(try LaunchAgentImporter.definition(fromPlist: Data("not a plist".utf8), sourcePath: "/tmp/x")) { error in
            XCTAssertEqual((error as? StartupServicesError)?.kind, .invalid)
        }
    }

    func testADefinitionThatAlreadyBelongsToAnAppIsNotImported() throws {
        let managed = try imported(retained[0])
        let data = try LaunchAgentRenderer.data(for: managed, invocation: ServiceRunnerInvocation(runnerPath: StartupServicesIdentity.installedRunnerPath))
        XCTAssertThrowsError(try LaunchAgentImporter.definition(fromPlist: data, sourcePath: "/tmp/x")) { error in
            XCTAssertEqual((error as? StartupServicesError)?.kind, .conflict)
        }
    }

    func testATestRootIsNamedInTheJobAndTheStandardCatalogIsNot() throws {
        let definition = try imported(retained[5])
        let standard = LaunchAgentRenderer.plist(for: definition, invocation: ServiceRunnerInvocation(runnerPath: "/r"))
        XCTAssertEqual(standard["ProgramArguments"] as? [String], ["/r", "run", "com.user.loginscript"])
        let sandboxed = LaunchAgentRenderer.plist(for: definition, invocation: ServiceRunnerInvocation(runnerPath: "/r", rootArgument: "/tmp/root"))
        XCTAssertEqual(sandboxed["ProgramArguments"] as? [String], ["/r", "--root", "/tmp/root", "run", "com.user.loginscript"])
    }

    func testSourceHashAndModeAreRecorded() throws {
        let data = try plistData(retained[0])
        let definition = try LaunchAgentImporter.definition(fromPlist: data, sourcePath: "/tmp/a.plist", fileMode: 0o600)
        XCTAssertEqual(definition.ownership, .observed(ServiceSource(path: "/tmp/a.plist", sha256: ServiceHash.sha256(data), fileMode: 0o600)))
    }

    func testLaunchdsSwitchedOffLabelsAreRead() {
        let output = """
        \tdisabled services = {
        \t\t"com.docker.helper" => enabled
        \t\t"com.globesoul.skyrimnet-native-tts" => disabled
        \t\t"com.example.old-format" => true
        \t\t"com.example.old-enabled" => false
        \t}
        \tlogin item associations = {
        \t}
        """
        XCTAssertEqual(LaunchctlTransport.parseDisabled(output), ["com.globesoul.skyrimnet-native-tts", "com.example.old-format"])
        XCTAssertEqual(LaunchctlTransport.parseDisabled("unexpected"), [])
    }

    func testLaunchdReportIsReadFromItsTopLevelFieldsOnly() {
        let running = """
        gui/505/com.globesoul.wg-keepalive = {
        \tactive count = 1
        \tpath = /Users/someone/Library/LaunchAgents/com.globesoul.wg-keepalive.plist
        \ttype = LaunchAgent
        \tstate = running

        \tprogram = /sbin/ping
        \targuments = {
        \t\t/sbin/ping
        \t\t-q
        \t}

        \truns = 1
        \tpid = 1040
        \tlast exit code = (never exited)

        \tresource coalition = {
        \t\tID = 880
        \t\tstate = active
        \t\tpid = 7
        \t}
        }
        """
        XCTAssertEqual(LaunchdJobSnapshot.parse(running), LaunchdJobSnapshot(
            state: "running", pid: 1040, lastExitCode: nil, runs: 1, program: "/sbin/ping",
            plistPath: "/Users/someone/Library/LaunchAgents/com.globesoul.wg-keepalive.plist"))

        // A line of an argument that looks like a field is inside the arguments block and is not read.
        let tricky = "x = {\n\tstate = running\n\targuments = {\n\t\t/bin/sh\n\tpid = 1\n\tstate = fake\n\t}\n\tpid = 77\n}\n"
        XCTAssertEqual(LaunchdJobSnapshot.parse(tricky), LaunchdJobSnapshot(state: "running", pid: 77))

        let finished = "x = {\n\tstate = not running\n\tprogram = /bin/zsh\n\truns = 1\n\tlast exit code = 0\n}\n"
        XCTAssertEqual(LaunchdJobSnapshot.parse(finished), LaunchdJobSnapshot(state: "not running", lastExitCode: 0, runs: 1, program: "/bin/zsh"))

        let retrying = "x = {\n\tstate = spawn scheduled\n\truns = 201\n\tlast exit code = 78: EX_CONFIG\n}\n"
        XCTAssertEqual(LaunchdJobSnapshot.parse(retrying), LaunchdJobSnapshot(state: "spawn scheduled", lastExitCode: 78, runs: 201))

        let killed = "x = {\n\tstate = spawn scheduled\n\truns = 2\n\tlast terminating signal = Killed: 9\n}\n"
        XCTAssertEqual(LaunchdJobSnapshot.parse(killed),
                       LaunchdJobSnapshot(state: "spawn scheduled", lastTerminatingSignal: "Killed: 9", runs: 2))
        XCTAssertEqual(LaunchdJobSnapshot.parse("unexpected output"), LaunchdJobSnapshot())
    }
}
