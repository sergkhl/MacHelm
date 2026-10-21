import Darwin
import Foundation

public enum ProcessAction: Equatable, Sendable {
    // Asks an app to quit, as ⌘Q does; a program without that gets the terminate signal.
    case quit
    // Ends the processes at once.
    case forceQuit
    // The Stop of Startup Services, for this session only.
    case stopService(id: String)
}

public enum ProcessActionPolicy {
    // Ending it logs the owner out.
    static let loginWindow = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"

    // A protected row has no actions: a system process, which cannot be
    // signalled without root, loginwindow, and MacHelm itself. launchd
    // would start a startup service again, so its row offers Stop instead,
    // and nothing when Startup Services cannot stop it.
    public static func actions(for group: ProcessGroupID, members: [ProcessDescription], ownPID: Int32,
                               stoppableServices: Set<String>) -> [ProcessAction] {
        if group.kind == .system { return [] }
        if members.contains(where: { $0.identity.pid == ownPID || $0.executablePath == loginWindow }) { return [] }
        if case .service(let id) = group.kind { return stoppableServices.contains(id) ? [.stopService(id: id)] : [] }
        return [.quit, .forceQuit]
    }

    // Force Quit always asks first. Quit asks where nothing else would: an app
    // can ask about unsaved work itself; a Windows program gets a signal and
    // cannot; and a row of several programs that only share a name, or of a
    // bundle with no app in it to ask, ends them all by signal.
    public static func asksFirst(_ action: ProcessAction, in group: ProcessGroupID, members: Int, canBeAsked: Bool = true) -> Bool {
        switch action {
        case .forceQuit: return true
        case .stopService: return false
        case .quit:
            switch group.kind {
            case .windowsProgram, .wineBackground: return true
            case .process: return members > 1
            case .app: return !canBeAsked && members > 1
            case .service, .system: return false
            }
        }
    }

    // Who a Quit on an app's row asks: every running copy of the row's own
    // app, or, when that is not running, the apps inside its bundle that have
    // a place in the Dock or the menu bar. A helper without one is never
    // asked; it goes when its app does. With nobody to ask, the row's
    // processes get the terminate signal instead.
    public static func appsToAsk(toQuit bundlePath: String, among apps: [RunningApp]) -> [ProcessIdentity] {
        let facing = apps.filter(\.isUserFacing)
        let own = facing.filter { $0.bundlePaths.contains(bundlePath) }
        return (own.isEmpty ? facing : own).map(\.identity).sorted { $0.pid < $1.pid }
    }

    // One process inside an expanded row can only be force-quit, and only where its row can be.
    public static func actions(forProcessIn groupActions: [ProcessAction]) -> [ProcessAction] {
        groupActions.contains(.forceQuit) ? [.forceQuit] : []
    }
}

// An app among a row's processes, as the system knows it.
public struct RunningApp: Equatable, Sendable {
    public var identity: ProcessIdentity
    // Its bundle's path as given and with links resolved.
    public var bundlePaths: Set<String>
    // It has a place in the Dock or the menu bar; a helper has neither.
    public var isUserFacing: Bool

    public init(identity: ProcessIdentity, bundlePaths: Set<String>, isUserFacing: Bool) {
        self.identity = identity
        self.bundlePaths = bundlePaths
        self.isUserFacing = isUserFacing
    }
}

public struct ProcessTermination: Equatable, Sendable {
    public var signalled: [ProcessIdentity] = []
    // Ended meanwhile, replaced by another process under the same identifier, or refused.
    public var skipped: [ProcessIdentity] = []
}

// Ends exactly the processes a row showed. An identifier that belongs to
// another process by now is left alone.
public struct ProcessTerminator: Sendable {
    private let transport: ProcessSignalTransport
    private let ownPID: Int32

    public init(transport: ProcessSignalTransport, ownPID: Int32) {
        self.transport = transport
        self.ownPID = ownPID
    }

    public func terminate(_ processes: [ProcessIdentity], force: Bool) -> ProcessTermination {
        var result = ProcessTermination()
        for process in processes {
            // A system process has no start time to check, so it is never signalled.
            guard process.pid > 1, process.pid != ownPID, process.startedAt != 0,
                  transport.startTime(of: process.pid) == process.startedAt,
                  transport.send(force ? SIGKILL : SIGTERM, to: process.pid) else {
                result.skipped.append(process)
                continue
            }
            result.signalled.append(process)
        }
        return result
    }
}
