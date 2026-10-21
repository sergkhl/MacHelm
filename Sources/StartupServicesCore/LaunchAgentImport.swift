import Foundation
import CryptoKit

public struct LaunchAgentIssue: Equatable, Sendable, CustomStringConvertible {
    public let key: String
    public let reason: String

    public init(_ key: String, _ reason: String) {
        self.key = key; self.reason = reason
    }

    public var description: String { "\(key): \(reason)" }
}

public enum ServiceHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// Reads a LaunchAgent definition without running or registering anything.
// A field this feature cannot preserve refuses the import by name.
public enum LaunchAgentImporter {
    public static let maximumPlistBytes = 1_048_576

    public static func definition(fromPlist data: Data, sourcePath: String, fileMode: Int = 0o644,
                                  runnerPaths: Set<String> = [StartupServicesIdentity.installedRunnerPath]) throws -> ServiceDefinition {
        guard data.count <= maximumPlistBytes else {
            throw StartupServicesError(.invalid, "The definition is larger than a LaunchAgent can be.")
        }
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw StartupServicesError(.invalid, "The file is not a LaunchAgent property list.")
        }
        var issues: [LaunchAgentIssue] = []
        var remaining = root

        func take<T>(_ key: String, _ type: T.Type) -> T? {
            guard let value = remaining.removeValue(forKey: key) else { return nil }
            // A Bool is not accepted where a number is expected, and the reverse.
            if let number = value as? NSNumber {
                let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
                if (type == Bool.self) != isBoolean {
                    issues.append(LaunchAgentIssue(key, "has an unexpected type")); return nil
                }
            }
            guard let typed = value as? T else {
                issues.append(LaunchAgentIssue(key, "has an unexpected type")); return nil
            }
            return typed
        }

        let label = take("Label", String.self) ?? ""
        if !Self.isValidLabel(label) {
            issues.append(LaunchAgentIssue("Label", "must be a plain launchd label"))
        }

        let programKey = take("Program", String.self)
        let argumentsKey = take("ProgramArguments", [String].self)
        var program = ""
        var arguments: [String] = []
        if let argumentsKey, !argumentsKey.isEmpty {
            program = programKey ?? argumentsKey[0]
            arguments = argumentsKey
        } else if let programKey {
            program = programKey; arguments = [programKey]
        } else if !issues.contains(where: { $0.key == "Program" || $0.key == "ProgramArguments" }) {
            issues.append(LaunchAgentIssue("ProgramArguments", "is missing or empty"))
        }
        if !program.isEmpty && !program.hasPrefix("/") {
            issues.append(LaunchAgentIssue("ProgramArguments", "the executable must be an absolute path"))
        }
        if runnerPaths.contains(program) || remaining["AssociatedBundleIdentifiers"] != nil {
            throw StartupServicesError(.conflict, "This definition already belongs to an app and cannot be imported.")
        }

        var launch = ServiceLaunchPolicy()
        launch.runAtLoad = take("RunAtLoad", Bool.self) ?? false
        if let keepAlive = remaining.removeValue(forKey: "KeepAlive") {
            if let flag = keepAlive as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
                launch.restart = flag.boolValue ? .always : .never
            } else if let conditions = keepAlive as? [String: Any], conditions.count == 1,
                      let successful = conditions["SuccessfulExit"] as? NSNumber,
                      CFGetTypeID(successful) == CFBooleanGetTypeID(), !successful.boolValue {
                launch.restart = .afterFailure
            } else {
                issues.append(LaunchAgentIssue("KeepAlive", "only true, false or SuccessfulExit = false is supported"))
            }
        }
        launch.throttleInterval = take("ThrottleInterval", Int.self)
        launch.startInterval = take("StartInterval", Int.self)
        launch.exitTimeOut = take("ExitTimeOut", Int.self)
        launch.nice = take("Nice", Int.self)
        launch.lowPriorityIO = take("LowPriorityIO", Bool.self)
        launch.lowPriorityBackgroundIO = take("LowPriorityBackgroundIO", Bool.self)
        launch.standardOutPath = take("StandardOutPath", String.self)
        launch.standardErrorPath = take("StandardErrorPath", String.self)
        if let processType = take("ProcessType", String.self) {
            if ["Background", "Standard", "Adaptive", "Interactive"].contains(processType) {
                launch.processType = processType
            } else {
                issues.append(LaunchAgentIssue("ProcessType", "is not a launchd process type"))
            }
        }
        if let session = remaining.removeValue(forKey: "LimitLoadToSessionType") {
            if let one = session as? String {
                launch.limitLoadToSessionType = [one]
            } else if let many = session as? [String], !many.isEmpty {
                launch.limitLoadToSessionType = many
            } else {
                issues.append(LaunchAgentIssue("LimitLoadToSessionType", "has an unexpected type"))
            }
        }
        if let calendar = remaining.removeValue(forKey: "StartCalendarInterval") {
            let entries: [[String: Any]]?
            if let one = calendar as? [String: Any] { entries = [one] } else { entries = calendar as? [[String: Any]] }
            if let entries, !entries.isEmpty {
                for entry in entries {
                    if let parsed = Self.calendarEntry(entry) {
                        launch.calendar.append(parsed)
                    } else {
                        issues.append(LaunchAgentIssue("StartCalendarInterval", "has an entry this feature cannot preserve"))
                    }
                }
            } else {
                issues.append(LaunchAgentIssue("StartCalendarInterval", "has an unexpected type"))
            }
        }

        var command = ServiceCommand(program: program, arguments: arguments)
        command.workingDirectory = take("WorkingDirectory", String.self)
        command.environment = take("EnvironmentVariables", [String: String].self) ?? [:]
        command.umask = take("Umask", Int.self)
        if let umask = command.umask, !(0...0o777).contains(umask) {
            issues.append(LaunchAgentIssue("Umask", "is out of range"))
        }
        // The owner's own switch: an agent marked Disabled does not start at login.
        let disabled = take("Disabled", Bool.self) ?? false

        for key in remaining.keys.sorted() {
            issues.append(LaunchAgentIssue(key, "is not preserved by Startup Services"))
        }
        guard issues.isEmpty else {
            throw StartupServicesError(.unsupported, "This LaunchAgent cannot be imported unchanged — "
                                       + issues.map(\.description).joined(separator: "; ") + ".")
        }

        let known = KnownServiceDefaults.entries[label]
        let base = command.workingDirectory.map { URL(fileURLWithPath: $0) }
        let locks = (known?.ownerLocks ?? []).compactMap { base?.appendingPathComponent($0).path }
        return ServiceDefinition(
            label: label, name: known?.name ?? label, command: command, launch: launch,
            automaticStartup: !disabled,
            ownership: .observed(ServiceSource(path: sourcePath, sha256: ServiceHash.sha256(data), fileMode: fileMode)),
            dependencies: known?.dependencies ?? [], ownerLockPaths: locks)
    }

    public static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 200, !label.hasPrefix("."), !label.hasPrefix("-") else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }

    private static func calendarEntry(_ entry: [String: Any]) -> ServiceCalendarEntry? {
        var result = ServiceCalendarEntry()
        for (key, value) in entry {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  CFNumberIsFloatType(number) == false else { return nil }
            let integer = number.intValue
            switch key {
            case "Minute" where (0...59).contains(integer): result.minute = integer
            case "Hour" where (0...23).contains(integer): result.hour = integer
            case "Day" where (1...31).contains(integer): result.day = integer
            case "Weekday" where (0...7).contains(integer): result.weekday = integer
            case "Month" where (1...12).contains(integer): result.month = integer
            default: return nil
            }
        }
        return result
    }
}
