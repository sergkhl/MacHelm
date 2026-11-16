import Foundation
#if SWIFT_PACKAGE
import ActivityCore
#endif

struct ClaudeAttachID: Hashable, Sendable {
    let value: String

    init?(_ string: String?) {
        guard let string, string.utf8.count == 8,
              string.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        value = string
    }
}

struct ClaudeDesktopID: Hashable, Sendable {
    let value: String

    init?(_ string: String?) {
        guard let string, string.hasPrefix("local_"), UUID(uuidString: String(string.dropFirst(6))) != nil else { return nil }
        value = string
    }
}

// The CLI list and session registrations share these fields. The registration
// alone carries the process start and Desktop host identifier.
struct ClaudeSessionRecord: Decodable, Sendable {
    var id: String? = nil
    var jobId: String? = nil
    var sessionId: String? = nil
    var pid: Int32? = nil
    var startedAt: Double? = nil
    var kind: String? = nil
    var status: String? = nil
    var state: String? = nil
    var waitingFor: String? = nil
    var name: String? = nil
    var cwd: String? = nil
    var entrypoint: String? = nil
    var hostSessionId: String? = nil
    var procStart: String? = nil
    var pidDomain: String? = nil

    var sessionID: UUID? { sessionId.flatMap(UUID.init(uuidString:)) }
    var isDetached: Bool { kind == "background" || kind == "bg" }
    var attachID: ClaudeAttachID? { isDetached ? ClaudeAttachID(id ?? jobId) : nil }

    var activity: ClaudeActivity {
        if state == "blocked" || status == "waiting" { return .needsInput }
        if status == "busy" || state == "working" { return .working }
        if status == "idle" { return .idle }
        switch state {
        case "done": return .idle
        case "failed": return .failed
        case "stopped": return .stopped
        default: return .unknown
        }
    }
}

enum ClaudeActivity: String, Equatable, Sendable {
    case working = "Working"
    case needsInput = "Needs input"
    case idle = "Idle"
    case failed = "Failed"
    case stopped = "Stopped"
    case unknown = "State unknown"
    case closed = "Session closed"
}

struct ClaudeTerminal: Equatable, Sendable {
    let name: String
    let bundleID: String?
    let tty: String
}

enum ClaudeSessionLocation: Equatable, Sendable {
    case desktop(ClaudeDesktopID?)
    case terminal(ClaudeTerminal?)
    case detached(ClaudeAttachID)
}

enum ClaudeConversationID: Hashable, Sendable {
    case session(UUID)
    case detached(ClaudeAttachID)
    case unknown
}

struct ClaudeConversation: Equatable, Identifiable, Sendable {
    let id: ClaudeConversationID
    var title: String
    var path: String?
    var activity: ClaudeActivity
    var waitingFor: String?
    var detached = false
    var worker: ProcessIdentity?
    var location: ClaudeSessionLocation?
    var createdAt: Date?
    var jobs: [ClaudeJob] = []

    var sessionID: UUID? {
        if case .session(let id) = id { return id }
        return nil
    }
}

struct ClaudeJob: Equatable, Identifiable, Sendable {
    enum ID: Hashable, Sendable {
        case shell(ClaudeTaskOutput)
        case process(ProcessIdentity)
    }

    let id: ID
    var title: String? = nil
    var processes: [ClaudeJobProcess]

    var isShell: Bool {
        if case .shell = id { return true }
        return false
    }
}

struct ClaudeJobProcess: Equatable, Identifiable, Sendable {
    let id: ProcessIdentity
    let name: String
}

enum ClaudeReadQuality: Equatable, Sendable {
    case complete, partial, unavailable, missingExecutable
}

struct ClaudeRead<Value: Sendable>: Sendable {
    var value: Value
    var quality: ClaudeReadQuality = .complete
}

struct ClaudeSnapshot: Equatable, Sendable {
    var conversations: [ClaudeConversation] = []
    var inventory: ClaudeReadQuality = .complete
    var registrations: ClaudeReadQuality = .complete
    var processes: ClaudeReadQuality = .complete
    var taskRecords: ClaudeReadQuality = .complete
}

struct ClaudeRegistration: Sendable {
    let record: ClaudeSessionRecord
    let worker: ProcessIdentity
    let terminal: ClaudeTerminal?
}

struct ClaudeTaskOutput: Hashable, Sendable {
    let sessionID: UUID
    let projectKey: String
    let taskID: String

    init(sessionID: UUID, projectKey: String, taskID: String) {
        self.sessionID = sessionID
        self.projectKey = projectKey
        self.taskID = taskID
    }

    // Claude Code allocates these IDs for local shell tasks in both modes.
    // A descriptor with this ID does not say whether the task was backgrounded.
    var isLocalShell: Bool {
        taskID.utf8.count == 9 && taskID.utf8.first == 98 &&
            taskID.utf8.dropFirst().allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
    }

    init?(path: String, roots: Set<String>) {
        let file = URL(fileURLWithPath: path)
        let taskFolder = file.deletingLastPathComponent()
        let sessionFolder = taskFolder.deletingLastPathComponent()
        let projectFolder = sessionFolder.deletingLastPathComponent()
        let taskID = file.deletingPathExtension().lastPathComponent
        guard file.pathExtension == "output", taskFolder.lastPathComponent == "tasks",
              roots.contains(projectFolder.deletingLastPathComponent().path),
              let sessionID = UUID(uuidString: sessionFolder.lastPathComponent),
              !taskID.isEmpty, taskID.utf8.count <= 64,
              taskID.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) else { return nil }
        self.init(sessionID: sessionID, projectKey: projectFolder.lastPathComponent, taskID: taskID)
    }
}

struct ClaudeTaskRecord: Sendable, Equatable {
    var backgroundedAt: TimeInterval? = nil
    var title: String? = nil
}

struct ClaudeObservedProcess: Sendable {
    let identity: ProcessIdentity
    let parent: Int32
    let name: String
    let startedAt: TimeInterval
    var sessionMarker: UUID? = nil
    var outputs: Set<ClaudeTaskOutput> = []
}

struct ClaudeDiscoveryFrame: Sendable {
    var inventory: ClaudeRead<[ClaudeSessionRecord]> = .init(value: [])
    var registrations: ClaudeRead<[ClaudeRegistration]> = .init(value: [])
    var processes: ClaudeRead<[ClaudeObservedProcess]> = .init(value: [])
    var taskRecords: ClaudeRead<[ClaudeTaskOutput: ClaudeTaskRecord]> = .init(value: [:])
    var creationDates: [UUID: Date] = [:]
    var restrictToKnownConversations = false
}
