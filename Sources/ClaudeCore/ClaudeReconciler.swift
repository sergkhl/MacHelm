import Foundation
#if SWIFT_PACKAGE
import ActivityCore
#endif

// Only the current process identity can inherit a previous attribution.
struct ClaudeReconciler {
    private struct Work {
        var process: ClaudeJobProcess
        var parent: Int32
        var owner: ClaudeConversationID
        var confirmedOwner: ClaudeConversationID?
        var output: ClaudeTaskOutput?

        var jobID: ClaudeJob.ID { output.map(ClaudeJob.ID.shell) ?? .process(process.id) }
    }

    private var known: [ClaudeConversationID: ClaudeConversation] = [:]
    private var work: [ProcessIdentity: Work] = [:]
    private(set) var active: [ClaudeConversationID: ClaudeConversation] = [:]

    mutating func update(_ frame: ClaudeDiscoveryFrame) -> ClaudeSnapshot {
        let processes = Dictionary(frame.processes.value.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let (sessions, roots) = Self.sessions(in: frame, processes: processes)
        active = sessions

        let metadata = known.merging(sessions) { _, fresh in fresh }
        let sessionReadsComplete = frame.inventory.quality == .complete && frame.registrations.quality == .complete
        if frame.processes.quality != .unavailable {
            work = attributedWork(in: processes, roots: roots, metadata: metadata, receipts: frame.taskRecords.value,
                                  sessions: sessions, sessionReadsComplete: sessionReadsComplete,
                                  restrictToKnownConversations: frame.restrictToKnownConversations)
        }

        var visible = sessions.filter { _, session in Self.isVisibleWithoutJobs(session) }
        // A failed inventory cannot tell us that an attachable session or a
        // prompt has gone away. Only fresh observations can supply an action.
        if frame.inventory.quality != .complete {
            for (id, old) in known where sessions[id] == nil && Self.isVisibleWithoutJobs(old) {
                let lastWorker = old.worker.flatMap { processes[$0.pid]?.identity == $0 ? $0 : nil }
                guard lastWorker != nil || frame.processes.quality == .unavailable || old.activity == .needsInput || old.activity == .working else { continue }
                var stale = old
                stale.worker = lastWorker
                stale.location = nil
                visible[id] = stale
            }
        }

        let groups = Dictionary(grouping: work.values, by: \.owner)
        for (id, members) in groups {
            var conversation = sessions[id] ?? metadata[id] ?? ClaudeConversation(
                id: id, title: "Session unknown", activity: .unknown
            )
            if sessions[id] == nil {
                conversation.worker = nil
                conversation.location = nil
                conversation.activity = id != .unknown && sessionReadsComplete ? .closed : .unknown
                conversation.waitingFor = nil
            }
            conversation.jobs = Dictionary(grouping: members, by: \.jobID).map { id, processes in
                ClaudeJob(id: id, processes: processes.map(\.process).sorted { $0.id.pid < $1.id.pid })
            }.sorted { ($0.processes.first?.id.pid ?? 0) < ($1.processes.first?.id.pid ?? 0) }
            visible[id] = conversation
        }

        // Keep metadata for active sessions and the owners of surviving work.
        let remembered = Set(sessions.keys).union(visible.keys).union(work.values.compactMap(\.confirmedOwner))
        known = metadata.filter { remembered.contains($0.key) }
        return ClaudeSnapshot(conversations: visible.values.sorted(by: Self.precedes), inventory: frame.inventory.quality,
                             registrations: frame.registrations.quality, processes: frame.processes.quality,
                             taskRecords: frame.taskRecords.quality)
    }

    private static func sessions(in frame: ClaudeDiscoveryFrame, processes: [Int32: ClaudeObservedProcess])
        -> ([ClaudeConversationID: ClaudeConversation], [Int32: Set<ClaudeConversationID>]) {
        let records = frame.inventory.value + frame.registrations.value.map(\.record)
        var aliases: [ClaudeAttachID: Set<UUID>] = [:]
        for record in records {
            if let attach = record.attachID, let uuid = record.sessionID { aliases[attach, default: []].insert(uuid) }
        }
        func key(_ record: ClaudeSessionRecord) -> ClaudeConversationID? {
            if let uuid = record.sessionID { return .session(uuid) }
            guard let attach = record.attachID else { return nil }
            if let ids = aliases[attach], ids.count == 1, let uuid = ids.first { return .session(uuid) }
            return .detached(attach)
        }

        var inventory: [ClaudeConversationID: [ClaudeSessionRecord]] = [:]
        var pidClaims: [Int32: Set<ClaudeConversationID>] = [:]
        for agent in frame.inventory.value {
            guard let id = key(agent) else { continue }
            inventory[id, default: []].append(agent)
            if let pid = agent.pid { pidClaims[pid, default: []].insert(id) }
        }
        var registrations: [ClaudeConversationID: [ClaudeRegistration]] = [:]
        var roots: [Int32: Set<ClaudeConversationID>] = [:]
        for registration in frame.registrations.value {
            let pid = registration.worker.pid
            guard processes[pid]?.identity == registration.worker, let id = key(registration.record) else { continue }
            registrations[id, default: []].append(registration)
            roots[pid, default: []].insert(id)
            roots[pid]?.formUnion(pidClaims[pid] ?? [])
        }

        var sessions: [ClaudeConversationID: ClaudeConversation] = [:]
        for id in Set(inventory.keys).union(registrations.keys) {
            let agents = inventory[id] ?? []
            let registered = registrations[id] ?? []
            let agent = agents.first
            let usable = registered.filter { registration in
                roots[registration.worker.pid] == [id] && agents.allSatisfy { $0.pid == nil || $0.pid == registration.worker.pid }
            }
            let exact = usable.count == 1 ? usable[0] : nil
            let record = exact?.record ?? (registered.count == 1 ? registered[0].record : nil)
            let detached = agent?.isDetached == true || record?.isDetached == true
            let attachIDs = Set((agents + usable.map(\.record)).compactMap(\.attachID))
            var worker = exact?.worker
            if worker == nil, agents.count == 1, let pid = agent?.pid, pidClaims[pid] == [id], roots[pid] == nil {
                worker = workerListed(by: agent, in: processes)
            }
            var session = ClaudeConversation(
                id: id, title: display(agent?.name) ?? display(record?.name) ?? "Claude session",
                path: display(agent?.cwd) ?? display(record?.cwd), activity: agent?.activity ?? record?.activity ?? .unknown,
                waitingFor: display(agent?.waitingFor) ?? display(record?.waitingFor), detached: detached,
                worker: worker
            )
            if detached {
                // An attach ID is independent of both the UUID and the worker PID.
                if attachIDs.count == 1, let attach = attachIDs.first, aliases[attach, default: []].count <= 1 {
                    session.location = .detached(attach)
                }
            } else if record?.entrypoint == "claude-desktop" {
                session.location = .desktop(ClaudeDesktopID(exact?.record.hostSessionId))
            } else {
                session.location = .terminal(exact?.terminal)
            }
            sessions[id] = session
        }
        return (sessions, roots)
    }

    private static func workerListed(by agent: ClaudeSessionRecord?, in processes: [Int32: ClaudeObservedProcess]) -> ProcessIdentity? {
        guard let agent, let pid = agent.pid, let process = processes[pid], let milliseconds = agent.startedAt,
              abs(process.startedAt - milliseconds / 1_000) < 3 else { return nil }
        return process.identity
    }

    private func attributedWork(in processes: [Int32: ClaudeObservedProcess], roots: [Int32: Set<ClaudeConversationID>],
                                metadata: [ClaudeConversationID: ClaudeConversation], receipts: [ClaudeTaskOutput: TimeInterval],
                                sessions: [ClaudeConversationID: ClaudeConversation], sessionReadsComplete: Bool,
                                restrictToKnownConversations: Bool) -> [ProcessIdentity: Work] {
        // Foreground Bash also opens a .output file. Require the structured
        // background receipt and a matching live writer, or an unchanged writer
        // from a previous refresh whose receipt has since rolled out of the tail.
        var liveOutputs: Set<ClaudeTaskOutput> = []
        for process in processes.values where roots[process.identity.pid] == nil {
            for output in process.outputs {
                if work[process.identity]?.output == output || receipts[output].map({ $0 + 1 >= process.startedAt }) == true {
                    liveOutputs.insert(output)
                }
            }
        }

        var result: [ProcessIdentity: Work] = [:]
        for process in processes.values where roots[process.identity.pid] == nil {
            let prior = work[process.identity]
            let initial = process.outputs.intersection(liveOutputs)
            var outputs = initial
            var ownerRoots: Set<ClaudeConversationID> = []
            var child = process
            while let parent = processes[child.parent], parent.identity.startedAt < child.identity.startedAt {
                if let owners = roots[parent.identity.pid] {
                    ownerRoots = owners
                    break
                }
                if outputs.isEmpty { outputs = parent.outputs.intersection(liveOutputs) }
                child = parent
            }

            let orphan = ownerRoots.isEmpty
            let mayOutliveTask = prior.map { previous in
                previous.output == nil || previous.parent != process.parent ||
                    (orphan && sessionReadsComplete && previous.confirmedOwner.flatMap { sessions[$0] } == nil)
            } ?? false
            let marker = process.sessionMarker.map(ClaudeConversationID.session)
            let markerInScope = marker.map { !restrictToKnownConversations || metadata[$0] != nil } ?? false
            let independent = orphan && process.parent <= 1 && markerInScope
            guard !outputs.isEmpty || mayOutliveTask || independent else { continue }

            var claims = ownerRoots
            claims.formUnion(outputs.map { .session($0.sessionID) })
            if let marker { claims.insert(marker) }
            if let prior = prior?.confirmedOwner { claims.insert(prior) }
            let resolved = claims.count == 1 ? claims.first.flatMap { metadata[$0]?.id } : nil
            let output = outputs.count == 1 ? outputs.first : nil
            result[process.identity] = Work(process: ClaudeJobProcess(id: process.identity, name: process.name),
                                            parent: process.parent, owner: resolved ?? .unknown,
                                            confirmedOwner: prior?.confirmedOwner ?? resolved, output: output)
        }
        return result
    }

    private static func display(_ string: String?) -> String? {
        guard let text = string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func isVisibleWithoutJobs(_ session: ClaudeConversation) -> Bool {
        session.activity == .needsInput || session.detached && (session.worker != nil || session.activity == .working)
    }

    private static func precedes(_ left: ClaudeConversation, _ right: ClaudeConversation) -> Bool {
        func order(_ item: ClaudeConversation) -> Int {
            if item.id == .unknown { return 3 }
            if item.activity == .closed { return 2 }
            return item.activity == .needsInput ? 0 : 1
        }
        if order(left) != order(right) { return order(left) < order(right) }
        if left.title != right.title { return left.title.localizedStandardCompare(right.title) == .orderedAscending }
        return String(describing: left.id) < String(describing: right.id)
    }
}
