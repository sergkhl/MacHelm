import Foundation

public enum StartupServicesIdentity {
    // MacHelm owns a fresh app, helper and saved-data namespace.
    public static let appBundleIdentifier = "io.github.sergkhl.MacHelm"
    public static let runnerIdentifier = "io.github.sergkhl.MacHelm.ServiceRunner"
    public static let installedAppPath = "/Applications/MacHelm.app"
    public static let runnerRelativePath = "Contents/Library/HelperTools/MacHelmServiceRunner"
    public static let installedRunnerPath = installedAppPath + "/" + runnerRelativePath
    public static let addedLabelPrefix = appBundleIdentifier + ".service."
}

// One launchd calendar entry. A missing field matches every value.
public struct ServiceCalendarEntry: Codable, Equatable, Sendable {
    public var minute: Int?
    public var hour: Int?
    public var day: Int?
    public var weekday: Int?
    public var month: Int?

    public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute; self.hour = hour; self.day = day; self.weekday = weekday; self.month = month
    }
}

public enum ServiceRestartPolicy: String, Codable, Sendable {
    case never
    case always        // KeepAlive = true
    case afterFailure  // KeepAlive = { SuccessfulExit = false }
}

public enum ServiceKind: String, Sendable {
    case continuous, scheduled, oneShot
}

public struct ServiceCommand: Codable, Equatable, Sendable {
    public var program: String
    // The complete argument vector, argv[0] included. Never joined into a shell line.
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]
    public var umask: Int?

    public init(program: String, arguments: [String], workingDirectory: String? = nil,
                environment: [String: String] = [:], umask: Int? = nil) {
        self.program = program; self.arguments = arguments; self.workingDirectory = workingDirectory
        self.environment = environment; self.umask = umask
    }
}

// The launchd fields this feature preserves. Anything else in a source
// definition is reported at import, never dropped.
public struct ServiceLaunchPolicy: Codable, Equatable, Sendable {
    public var runAtLoad = false
    public var restart = ServiceRestartPolicy.never
    public var throttleInterval: Int?
    public var calendar: [ServiceCalendarEntry] = []
    public var startInterval: Int?
    public var processType: String?
    public var exitTimeOut: Int?
    public var standardOutPath: String?
    public var standardErrorPath: String?
    public var nice: Int?
    public var lowPriorityIO: Bool?
    public var lowPriorityBackgroundIO: Bool?
    public var limitLoadToSessionType: [String]?

    public init() {}
}

public struct ServiceSource: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var fileMode: Int

    public init(path: String, sha256: String, fileMode: Int) {
        self.path = path; self.sha256 = sha256; self.fileMode = fileMode
    }
}

public struct ServiceBackup: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var originalPath: String
    public var fileMode: Int
    // The label was switched off with `launchctl disable` when it was taken over.
    public var launchdDisabled: Bool

    public init(path: String, sha256: String, originalPath: String, fileMode: Int, launchdDisabled: Bool = false) {
        self.path = path; self.sha256 = sha256; self.originalPath = originalPath; self.fileMode = fileMode
        self.launchdDisabled = launchdDisabled
    }
}

public enum ServiceOwnership: Codable, Equatable, Sendable {
    // Imported for viewing; its original LaunchAgent still owns registration.
    case observed(ServiceSource)
    // MacHelm owns registration. `installedSHA256` is the plist it last
    // wrote into the user's LaunchAgents, nil while automatic startup is off.
    case managed(installedSHA256: String?, backup: ServiceBackup?)
}

public struct ServiceDefinition: Codable, Equatable, Identifiable, Sendable {
    public var label: String
    public var name: String
    public var command: ServiceCommand
    public var launch: ServiceLaunchPolicy
    public var automaticStartup: Bool
    public var ownership: ServiceOwnership
    // Shown to the owner; never started or enabled on the service's behalf (Q13).
    public var dependencies: [String]
    // Files the service keeps an exclusive flock on while it owns its data.
    public var ownerLockPaths: [String]

    public var id: String { label }

    public init(label: String, name: String, command: ServiceCommand, launch: ServiceLaunchPolicy,
                automaticStartup: Bool, ownership: ServiceOwnership, dependencies: [String] = [],
                ownerLockPaths: [String] = []) {
        self.label = label; self.name = name; self.command = command; self.launch = launch
        self.automaticStartup = automaticStartup; self.ownership = ownership
        self.dependencies = dependencies; self.ownerLockPaths = ownerLockPaths
    }

    public var kind: ServiceKind {
        if launch.restart != .never { return .continuous }
        if !launch.calendar.isEmpty || launch.startInterval != nil { return .scheduled }
        return .oneShot
    }

    public var isManaged: Bool {
        if case .managed = ownership { return true }
        return false
    }

    public var triggerDescription: String {
        var parts: [String] = []
        switch kind {
        case .continuous:
            parts.append(launch.restart == .always ? "Keeps running; restarts whenever it exits"
                         : "Keeps running; restarts after an unsuccessful exit")
            if let throttle = launch.throttleInterval { parts.append("at most one start every \(throttle) s") }
        case .scheduled:
            if !launch.calendar.isEmpty {
                parts.append("Runs on a calendar schedule (" + launch.calendar.map(\.summary).joined(separator: "; ") + ")")
            }
            if let interval = launch.startInterval { parts.append("Runs every \(interval) s") }
            if launch.runAtLoad { parts.append("and once at login") }
        case .oneShot:
            parts.append(launch.runAtLoad ? "Runs once at login" : "Runs only when asked")
        }
        return parts.joined(separator: ", ")
    }
}

extension ServiceCalendarEntry {
    public var summary: String {
        var parts: [String] = []
        if let month { parts.append("month \(month)") }
        if let day { parts.append("day \(day)") }
        if let weekday {
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            parts.append((0...7).contains(weekday) ? names[weekday] : "weekday \(weekday)")
        }
        switch (hour, minute) {
        case let (hour?, minute?): parts.append(String(format: "%02d:%02d", hour, minute))
        case let (hour?, nil): parts.append(String(format: "every minute of hour %02d", hour))
        case let (nil, minute?): parts.append(String(format: "minute %02d of every hour", minute))
        case (nil, nil): if parts.isEmpty { parts.append("every minute") }
        }
        return parts.joined(separator: " ")
    }
}

public struct ServiceCatalog: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion = ServiceCatalog.currentSchema
    public var services: [ServiceDefinition] = []

    public init() {}

    public func service(_ label: String) -> ServiceDefinition? {
        services.first { $0.label == label }
    }
}

// Q9: accepted default names for the six retained jobs. Every name stays editable.
public enum KnownServiceDefaults {
    public struct Entry: Sendable {
        public let name: String
        public let dependencies: [String]
        // Relative to the service's working directory.
        public let ownerLocks: [String]
    }

    public static let entries: [String: Entry] = [
        "com.globesoul.wg-keepalive": Entry(name: "WireGuard Keepalive", dependencies: [], ownerLocks: []),
        "com.globesoul.skyrimnet-native-tts": Entry(name: "Skyrim English Speech — Pocket TTS", dependencies: [], ownerLocks: []),
        "com.globesoul.skyrimnet-fish-tts": Entry(
            name: "Skyrim Russian Speech — Fish TTS",
            dependencies: ["Uses Skyrim Speech Recognition — Whisper for reference transcripts it has not cached. It is not started for you."],
            ownerLocks: []),
        "local.whisper-server.skyrimnet": Entry(name: "Skyrim Speech Recognition — Whisper", dependencies: [], ownerLocks: []),
        "com.quantumcraft.reply-assistant": Entry(name: "Telegram Reply Assistant", dependencies: [],
                                                 ownerLocks: [".local/service.owner.lock"]),
        "com.user.loginscript": Entry(name: "Tahoe Background Process Priority", dependencies: [], ownerLocks: [])
    ]

    public static func name(for label: String) -> String {
        entries[label]?.name ?? label
    }
}

public struct StartupServicesError: Error, Equatable, LocalizedError, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case notFound, invalid, conflict, blocked, notInstalled, busy, launchd, storage, unsupported
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind; self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
