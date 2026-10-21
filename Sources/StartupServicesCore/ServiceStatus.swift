import Foundation

// What is happening in this login session. It is separate from the saved
// automatic-startup preference and from the macOS permission.
public enum ServiceActivity: Equatable, Sendable {
    // Not registered with launchd in this session.
    case inactive
    case running(pid: Int32)
    // Registered with no process; launchd will start it again.
    case waiting
    // Registered with no process and nothing pending: between scheduled runs,
    // after a finished one-shot, or after a successful exit.
    case idle
    // Stop was asked and the process, or the lock it holds, is still there.
    case stopping
    // launchd could not be asked.
    case unknown(String)
}

// Which definition launchd has loaded for the label.
public enum ServiceLoadedInstance: String, Equatable, Sendable {
    case none, managed, original
}

public enum ServiceProblem: Equatable, Sendable {
    case notInstalled
    case runnerMissing(String)
    case executableMissing(String)
    case permissionBlocked
    // The installed LaunchAgent is not the one MacHelm wrote.
    case definitionChangedOutside(String)
    case definitionMissing(String)
    // Automatic startup is off, yet a LaunchAgent with this label exists.
    case foreignDefinition(String)
    case sourceChanged(String)
    case sourceMissing(String)
    // No registration and no Stop request, yet the recorded process is alive.
    case strayProcess(Int32)
    // The label is switched off in launchd itself (`launchctl disable`).
    case disabledInLaunchd(String)

    public var isConflict: Bool {
        switch self {
        case .definitionChangedOutside, .definitionMissing, .foreignDefinition, .sourceChanged, .sourceMissing: return true
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .notInstalled:
            return "Install MacHelm in the Applications folder to start services or change their startup."
        case .runnerMissing(let path):
            return "The MacHelm service runner is missing at \(path)."
        case .executableMissing(let path):
            return "The program is missing or cannot be executed: \(path)."
        case .permissionBlocked:
            return "macOS is blocking MacHelm's background items. Allow MacHelm in System Settings → General → Login Items & Extensions. The same switch covers the Fan Control helper."
        case .definitionChangedOutside(let path):
            return "The LaunchAgent at \(path) was changed outside MacHelm. It was left as found."
        case .definitionMissing(let path):
            return "The LaunchAgent MacHelm installed at \(path) is gone."
        case .foreignDefinition(let path):
            return "A LaunchAgent with this label appeared at \(path). It was not written by MacHelm and was left as found."
        case .sourceChanged(let path):
            return "The original LaunchAgent at \(path) changed after it was imported. Import it again."
        case .sourceMissing(let path):
            return "The original LaunchAgent at \(path) is gone."
        case .strayProcess(let pid):
            return "A process from an earlier run (PID \(pid)) is still alive without a registration."
        case .disabledInLaunchd(let label):
            return "launchd itself has this label switched off, so it cannot be started and does not start at login. Switch it on with: launchctl enable gui/$(id -u)/\(label)"
        }
    }
}

public struct ServiceLastResult: Equatable, Sendable {
    public var exitCode: Int32?
    // As launchd words it, for example "Killed: 9".
    public var terminatingSignal: String?
    public var failure: String?

    public var summary: String {
        if let failure { return "Could not start: \(failure)" }
        if let terminatingSignal { return "Ended by a signal (\(terminatingSignal))" }
        if let exitCode { return exitCode == 0 ? "Finished successfully (exit 0)" : "Failed (exit \(exitCode))" }
        return "No result recorded"
    }
}

public enum ServiceAction: String, Sendable, CaseIterable {
    case start, stop, runNow, resumeSchedule, takeOver, useOutsideDefinition, remove

    public var title: String {
        switch self {
        case .useOutsideDefinition: return "Use Changed Definition"
        case .start: return "Start"
        case .stop: return "Stop"
        case .runNow: return "Run Now"
        case .resumeSchedule: return "Resume Schedule"
        case .takeOver: return "Manage with MacHelm"
        case .remove: return "Remove"
        }
    }
}

public struct ServiceStatus: Equatable, Identifiable, Sendable {
    public var definition: ServiceDefinition
    public var activity: ServiceActivity
    public var loadedInstance: ServiceLoadedInstance
    public var runs: Int?
    public var lastResult: ServiceLastResult?
    public var problems: [ServiceProblem]
    public var actions: [ServiceAction]
    public var disabledInLaunchd = false

    public var id: String { definition.label }

    // Running is evidence of a process only. Whether the service answers
    // correctly is never checked here (Q16).
    public var stateText: String {
        let scheduled = definition.kind == .scheduled
        switch activity {
        case .inactive:
            if !definition.isManaged { return disabledInLaunchd ? "Not registered; switched off in launchd" : "Not registered" }
            return "Not active in this session"
        case .running(let pid):
            return "Running (PID \(pid)); readiness not checked"
        case .waiting:
            if let code = lastResult?.exitCode, code != 0 { return "Waiting to restart after exit \(code)" }
            return "Waiting to restart"
        case .idle:
            if scheduled { return "Scheduled; not running now" }
            if definition.kind == .oneShot { return runs == 0 ? "Loaded; has not run yet" : "Finished" }
            return "Exited; stays stopped until started"
        case .stopping:
            return "Stopping…"
        case .unknown(let reason):
            return "State unavailable: \(reason)"
        }
    }
}
