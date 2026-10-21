import Foundation

// The toolkit helper: the root program for everything but the fans (ADR 0003).
public enum ToolkitHelperIdentity {
    public static let app = "io.github.sergkhl.MacHelm"
    public static let helper = "io.github.sergkhl.MacHelm.ToolkitHelper"
    public static let plist = helper + ".plist"
    public static let protocolVersion = 1
}

// What Service Management says about the helper's registration.
public enum ToolkitHelperRegistration: Sendable {
    case enabled, requiresApproval, notRegistered, notFound
}

// What the Power page shows of the toolkit helper.
public enum ToolkitHelperState: Equatable, Sendable {
    case notSetUp
    // Registered; macOS waits for the owner's switch under Login Items & Extensions.
    case needsApproval
    case ready
    // An ad-hoc build, or the app holds no helper.
    case unavailable(String)

    // A helper that was never registered reads as not found, as the fan
    // helper's does; then the files in the app say whether one can be set up.
    public static func reading(_ registration: ToolkitHelperRegistration, signed: Bool, bundled: Bool) -> ToolkitHelperState {
        guard signed else { return .unavailable("This build is not signed by an Apple team, so it has no toolkit helper.") }
        switch registration {
        case .enabled: return .ready
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .notSetUp
        case .notFound: return bundled ? .notSetUp : .unavailable("This copy of MacHelm holds no toolkit helper.")
        }
    }
}

// One of the four macOS settings for when the display turns off and when the
// Mac sleeps. They are macOS's own: MacHelm shows and changes them.
public enum SleepTimer: String, CaseIterable, Codable, Sendable {
    case displayOnBattery, displayOnPowerAdapter, sleepOnBattery, sleepOnPowerAdapter

    // The names macOS keeps them under.
    public var source: String {
        switch self {
        case .displayOnBattery, .sleepOnBattery: return "Battery Power"
        case .displayOnPowerAdapter, .sleepOnPowerAdapter: return "AC Power"
        }
    }

    public var key: String {
        switch self {
        case .displayOnBattery, .displayOnPowerAdapter: return "Display Sleep Timer"
        case .sleepOnBattery, .sleepOnPowerAdapter: return "System Sleep Timer"
        }
    }

    // What is offered, in minutes; 0 is never.
    public static let minutes = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 120, 180, 0]

    public static func text(_ minutes: Int) -> String {
        guard minutes > 0 else { return "Never" }
        let hours = minutes / 60, rest = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if rest > 0 { parts.append(rest == 1 ? "1 minute" : "\(rest) minutes") }
        return parts.joined(separator: " ")
    }
}

public struct SleepTimers: Equatable, Sendable {
    // In minutes; 0 is never. A timer macOS does not report is missing.
    public var minutes: [SleepTimer: Int]

    public init(minutes: [SleepTimer: Int] = [:]) {
        self.minutes = minutes
    }

    // From the dictionary macOS keeps its power settings in.
    public init(preferences: [String: Any]) {
        self.init()
        for timer in SleepTimer.allCases {
            guard let source = preferences[timer.source] as? [String: Any], let value = source[timer.key] as? NSNumber else { continue }
            minutes[timer] = value.intValue
        }
    }
}

// What the helper answers to every request.
public struct ToolkitHelperReply: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    // The helper holds stay-awake for MacHelm.
    public var stayAwakeHeld: Bool
    // What macOS says now; nil when it could not be read.
    public var sleepDisabled: Bool?
    public var error: String?

    public init(protocolVersion: Int = ToolkitHelperIdentity.protocolVersion, stayAwakeHeld: Bool = false, sleepDisabled: Bool? = nil,
                error: String? = nil) {
        self.protocolVersion = protocolVersion
        self.stayAwakeHeld = stayAwakeHeld
        self.sleepDisabled = sleepDisabled
        self.error = error
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decoded(_ data: Data) -> ToolkitHelperReply? { try? JSONDecoder().decode(ToolkitHelperReply.self, from: data) }
}

// The helper's four requests (ADR 0003). No request carries a command, and
// only the removal carries a path.
@objc public protocol ToolkitHelperXPC {
    func powerState(protocolVersion: Int, reply: @escaping (Data) -> Void)
    func holdStayAwake(_ hold: Bool, reply: @escaping (Data) -> Void)
    func setSleepTimer(_ timer: String, minutes: Int, reply: @escaping (Data) -> Void)
    func removeDirectory(atPath path: String, reply: @escaping (Data) -> Void)
}
