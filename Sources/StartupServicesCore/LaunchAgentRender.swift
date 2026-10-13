import Foundation

// Where the runner is and which catalog it reads. The standard catalog needs
// no argument; any other root is passed explicitly, so a job registered from
// a test root can never read the owner's catalog.
public struct ServiceRunnerInvocation: Equatable, Sendable {
    public var runnerPath: String
    public var rootArgument: String?

    public init(runnerPath: String, rootArgument: String? = nil) {
        self.runnerPath = runnerPath; self.rootArgument = rootArgument
    }

    public func arguments(label: String) -> [String] {
        var arguments = [runnerPath]
        if let rootArgument { arguments += ["--root", rootArgument] }
        return arguments + ["run", label]
    }
}

// Renders the launchd job for a managed service. The job runs the signed
// runner, which executes the definition's own command; every launchd policy
// field of the source is carried over unchanged.
public enum LaunchAgentRenderer {
    public static func plist(for definition: ServiceDefinition, invocation: ServiceRunnerInvocation) -> [String: Any] {
        let launch = definition.launch
        var plist: [String: Any] = [
            "Label": definition.label,
            "ProgramArguments": invocation.arguments(label: definition.label),
            // Attributes the job to the app in Login Items & Extensions.
            "AssociatedBundleIdentifiers": [StartupServicesIdentity.appBundleIdentifier]
        ]
        if launch.runAtLoad { plist["RunAtLoad"] = true }
        switch launch.restart {
        case .never: break
        case .always: plist["KeepAlive"] = true
        case .afterFailure: plist["KeepAlive"] = ["SuccessfulExit": false]
        }
        if let value = launch.throttleInterval { plist["ThrottleInterval"] = value }
        if let value = launch.startInterval { plist["StartInterval"] = value }
        if let value = launch.exitTimeOut { plist["ExitTimeOut"] = value }
        if let value = launch.nice { plist["Nice"] = value }
        if let value = launch.lowPriorityIO { plist["LowPriorityIO"] = value }
        if let value = launch.lowPriorityBackgroundIO { plist["LowPriorityBackgroundIO"] = value }
        if let value = launch.processType { plist["ProcessType"] = value }
        if let value = launch.standardOutPath { plist["StandardOutPath"] = value }
        if let value = launch.standardErrorPath { plist["StandardErrorPath"] = value }
        if let value = launch.limitLoadToSessionType {
            plist["LimitLoadToSessionType"] = value.count == 1 ? value[0] as Any : value as Any
        }
        if !launch.calendar.isEmpty {
            let entries = launch.calendar.map(Self.calendarDictionary)
            plist["StartCalendarInterval"] = entries.count == 1 ? entries[0] as Any : entries as Any
        }
        if let value = definition.command.workingDirectory { plist["WorkingDirectory"] = value }
        if !definition.command.environment.isEmpty { plist["EnvironmentVariables"] = definition.command.environment }
        if let value = definition.command.umask { plist["Umask"] = value }
        return plist
    }

    public static func data(for definition: ServiceDefinition, invocation: ServiceRunnerInvocation) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(for: definition, invocation: invocation),
                                           format: .xml, options: 0)
    }

    private static func calendarDictionary(_ entry: ServiceCalendarEntry) -> [String: Int] {
        var result: [String: Int] = [:]
        if let value = entry.minute { result["Minute"] = value }
        if let value = entry.hour { result["Hour"] = value }
        if let value = entry.day { result["Day"] = value }
        if let value = entry.weekday { result["Weekday"] = value }
        if let value = entry.month { result["Month"] = value }
        return result
    }
}
