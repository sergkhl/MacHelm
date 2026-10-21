import Foundation

// The runner's command line. `run` is what launchd calls. The other commands
// let a managed service's own tooling ask MacHelm to register, start, stop
// and report on it, through the same controller and catalog lock as the app.
public enum ServiceRunnerCLI {
    static let usage = """
    Usage: MacHelmServiceRunner [--root <folder>] <command>

      run <label>                     Run a managed service's command (called by launchd).
      status [<label>] [--json]       Report local state. Nothing is started or probed.
      discover [--json]               List the user's LaunchAgents and whether each can be imported.
      import <plist>                  Add a LaunchAgent to the catalog for viewing. Runs nothing.
      take-over <label>               Back up the original and install the managed definition. Runs nothing.
      accept-change <label>           Take a LaunchAgent changed outside MacHelm as the new definition.
      revert <label>                  Put the exact original back. The service must be stopped.
      set-automatic <label> on|off    Start at login or not, from the next login.
      start <label>                   Start a continuous service in this session.
      run-now <label>                 Run a one-shot or scheduled service once.
      resume-schedule <label>         Put a stopped schedule back for this session.
      stop <label> [--wait <seconds>] End this session's registration; exit 3 while still stopping.
      remove <label>                  Remove a stopped service's startup definition.
      rename <label> <name>           Change the friendly name.
      install-definition <file.json>  Create or update a managed definition from an installer.

    --root uses a self-contained test folder in place of the user's catalog and LaunchAgents.
    """

    public static func main(arguments: [String]) -> Never {
        var arguments = Array(arguments.dropFirst())
        var root: String?
        if arguments.first == "--root" {
            guard arguments.count >= 2 else { finish(usage, status: 2) }
            // The real path, so the job names the same folder launchd reports.
            let given = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
            root = realpath(given, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? given
            arguments.removeFirst(2)
        }
        guard let command = arguments.first else { finish(usage, status: 2) }
        let rest = Array(arguments.dropFirst())
        let json = rest.contains("--json")
        let positional = rest.filter { !$0.hasPrefix("--") }

        let paths: StartupServicesPaths
        let invocation: ServiceRunnerInvocation?
        let executable = executablePath()
        if let root {
            paths = .sandbox(root: URL(fileURLWithPath: root))
            invocation = ServiceRunnerInvocation(runnerPath: executable, rootArgument: root)
        } else {
            paths = .standard()
            // Only the installed runner may be written into a LaunchAgent.
            invocation = executable == StartupServicesIdentity.installedRunnerPath
                ? ServiceRunnerInvocation(runnerPath: executable) : nil
        }

        if command == "run" {
            guard positional.count == 1 else { finish(usage, status: 2) }
            ServiceRunner.run(label: positional[0], paths: paths)
        }

        let controller = StartupServicesController(
            paths: paths, transport: paths.isStandard ? LaunchctlTransport() : SelfTestOnlyTransport(LaunchctlTransport()),
            invocation: invocation,
            permission: paths.isStandard ? SystemBackgroundPermission() : UnknownBackgroundPermission())
        do {
            switch (command, positional.count) {
            case ("status", 0):
                let statuses = try controller.statuses()
                print(json ? encode(statuses.map(report)) : statuses.map(line).joined(separator: "\n"))
            case ("status", 1):
                let status = try controller.status(positional[0])
                print(json ? encode(report(status)) : line(status))
            case ("discover", 0):
                let found = try controller.discover()
                if json {
                    print(encode(found.map { agent in
                        DiscoveryReport(path: agent.path, label: agent.label, sha256: agent.sha256,
                                        importable: agent.definition != nil, refusal: agent.refusal,
                                        inCatalog: agent.inCatalog, kind: agent.definition?.kind.rawValue,
                                        trigger: agent.definition?.triggerDescription,
                                        knownName: agent.label.flatMap { KnownServiceDefaults.entries[$0]?.name },
                                        automaticStartup: agent.definition?.automaticStartup)
                    }))
                } else {
                    for agent in found {
                        print("\(agent.label ?? "(no label)")\t\(agent.definition != nil ? "importable" : "not importable: \(agent.refusal ?? "")")\t\(agent.path)")
                    }
                }
            case ("import", 1):
                let definition = try controller.importLaunchAgent(at: URL(fileURLWithPath: positional[0]))
                print(json ? encode(report(try controller.status(definition.label))) : "Imported \(definition.label) as \(definition.name).")
            case ("take-over", 1):
                try controller.takeOver(positional[0])
                print(json ? encode(report(try controller.status(positional[0]))) : "MacHelm now manages \(positional[0]).")
            case ("accept-change", 1):
                try controller.useOutsideDefinition(positional[0])
                print(json ? encode(report(try controller.status(positional[0]))) : "The changed LaunchAgent is now the definition of \(positional[0]).")
            case ("revert", 1):
                try controller.revert(positional[0])
                print(json ? encode(report(try controller.status(positional[0]))) : "The original definition of \(positional[0]) is back in place.")
            case ("set-automatic", 2):
                guard ["on", "off"].contains(positional[1]) else { finish(usage, status: 2) }
                try controller.setAutomaticStartup(positional[0], enabled: positional[1] == "on")
                print(json ? encode(report(try controller.status(positional[0]))) : "Automatic startup is \(positional[1]) from the next login.")
            case ("start", 1):
                try controller.start(positional[0])
                print(json ? encode(report(try controller.status(positional[0]))) : line(try controller.status(positional[0])))
            case ("run-now", 1):
                try controller.runNow(positional[0])
                print(json ? encode(report(try controller.status(positional[0]))) : line(try controller.status(positional[0])))
            case ("resume-schedule", 1):
                try controller.resumeSchedule(positional[0])
                print(json ? encode(report(try controller.status(positional[0]))) : line(try controller.status(positional[0])))
            case ("stop", 1), ("stop", 2):
                var wait: TimeInterval = 0
                if let index = rest.firstIndex(of: "--wait") {
                    guard positional.count == 2, index + 1 < rest.count, let seconds = TimeInterval(rest[index + 1]),
                          seconds >= 0, seconds <= 3600 else { finish(usage, status: 2) }
                    wait = seconds
                } else if positional.count != 1 {
                    finish(usage, status: 2)
                }
                try controller.stop(positional[0])
                let stopped = try controller.waitUntilStopped(positional[0], timeout: wait)
                let status = try controller.status(positional[0])
                print(json ? encode(report(status)) : line(status))
                exit(stopped ? 0 : 3)
            case ("remove", 1):
                try controller.remove(positional[0])
                print(json ? "{\"removed\":true}" : "Removed \(positional[0]). Its scripts, data, logs and backup were kept.")
            case ("rename", 2):
                try controller.rename(positional[0], to: positional[1])
                print(json ? encode(report(try controller.status(positional[0]))) : "Renamed.")
            case ("install-definition", 1):
                guard let data = FileManager.default.contents(atPath: positional[0]),
                      let external = try? JSONDecoder().decode(ExternalServiceDefinition.self, from: data) else {
                    throw StartupServicesError(.invalid, "The definition file is not valid.")
                }
                let definition = try controller.installDefinition(external)
                print(json ? encode(report(try controller.status(definition.label)))
                      : "Saved \(definition.label). Automatic startup is \(definition.automaticStartup ? "on" : "off").")
            default:
                finish(usage, status: 2)
            }
            exit(0)
        } catch let error as StartupServicesError {
            if json { print(encode(ErrorReport(error: error.kind.rawValue, message: error.message))) }
            finish(error.message, status: 1)
        } catch {
            finish("\(error)", status: 1)
        }
    }

    struct StatusReport: Codable, Equatable {
        var label: String
        var name: String
        var kind: String
        var managed: Bool
        var automaticStartup: Bool
        var registered: Bool
        var activity: String
        var pid: Int32?
        var loadedInstance: String
        var state: String
        var lastExitCode: Int32?
        var lastSignal: String?
        var lastFailure: String?
        var problems: [String]
        var actions: [String]
    }

    private struct DiscoveryReport: Codable {
        var path: String
        var label: String?
        var sha256: String?
        var importable: Bool
        var refusal: String?
        var inCatalog: Bool
        var kind: String?
        var trigger: String?
        // The accepted default name, for the retained jobs only.
        var knownName: String?
        var automaticStartup: Bool?
    }

    private struct ErrorReport: Codable {
        var error: String
        var message: String
    }

    static func report(_ status: ServiceStatus) -> StatusReport {
        var activity = "inactive"
        var pid: Int32?
        switch status.activity {
        case .inactive: activity = "inactive"
        case .running(let running): activity = "running"; pid = running
        case .waiting: activity = "waiting"
        case .idle: activity = "idle"
        case .stopping: activity = "stopping"
        case .unknown: activity = "unknown"
        }
        return StatusReport(
            label: status.definition.label, name: status.definition.name, kind: status.definition.kind.rawValue,
            managed: status.definition.isManaged, automaticStartup: status.definition.automaticStartup,
            registered: status.loadedInstance != .none, activity: activity, pid: pid,
            loadedInstance: status.loadedInstance.rawValue, state: status.stateText,
            lastExitCode: status.lastResult?.exitCode, lastSignal: status.lastResult?.terminatingSignal,
            lastFailure: status.lastResult?.failure, problems: status.problems.map(\.message),
            actions: status.actions.map(\.rawValue))
    }

    private static func line(_ status: ServiceStatus) -> String {
        var text = "\(status.definition.name) [\(status.definition.label)]: \(status.stateText); automatic startup \(status.definition.automaticStartup ? "on" : "off")"
        for problem in status.problems { text += "\n  ! \(problem.message)" }
        return text
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func finish(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }

    static func executablePath() -> String {
        var size = UInt32(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) != 0 {
            buffer = [CChar](repeating: 0, count: Int(size))
            _ = _NSGetExecutablePath(&buffer, &size)
        }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
}
