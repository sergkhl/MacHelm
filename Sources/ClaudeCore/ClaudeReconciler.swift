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
        var backgrounded: Bool
        var title: String?

        var jobID: ClaudeJob.ID { output.map(ClaudeJob.ID.shell) ?? .process(process.id) }
    }

    private var known: [ClaudeConversationID: ClaudeConversation] = [:]
    private var work: [ProcessIdentity: Work] = [:]
    private(set) var active: [ClaudeConversationID: ClaudeConversation] = [:]

    mutating func update(_ frame: ClaudeDiscoveryFrame, at now: Date = Date()) -> ClaudeSnapshot {
        let processes = Dictionary(frame.processes.value.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let (discovered, roots) = Self.sessions(in: frame, processes: processes, at: now)
        let sessions = discovered.mapValues { session in
            var result = session
            result.createdAt = session.createdAt ?? known[session.id]?.createdAt
            return result
        }
        active = sessions

        let metadata = known.merging(sessions) { _, fresh in fresh }
        let sessionReadsComplete = frame.inventory.quality == .complete && frame.registrations.quality == .complete
        if frame.processes.quality != .unavailable {
            work = attributedWork(in: processes, roots: roots, metadata: metadata, taskRecords: frame.taskRecords.value,
                                  sessions: sessions, sessionReadsComplete: sessionReadsComplete,
                                  restrictToKnownConversations: frame.restrictToKnownConversations)
        }

        var visible = sessions.filter { _, session in Self.isVisibleWithoutJobs(session) }
        // A failed inventory cannot tell us that an attachable session or a
        // prompt has gone away. Only fresh observations can supply an action.
        if frame.inventory.quality != .complete {
            for (id, old) in known where sessions[id] == nil {
                let lastWorker = old.worker.flatMap { processes[$0.pid]?.identity == $0 ? $0 : nil }
                guard lastWorker != nil || frame.processes.quality == .unavailable || old.activity == .needsInput || old.activity == .working else { continue }
                var stale = old
                stale.worker = lastWorker
                stale.location = nil
                // Only an incomplete session inventory can justify retaining a
                // previously reported wait. Drafts and replies use fresh reads.
                stale.inputItems = old.inputItems.filter { $0.kind == .native && $0.isRecent(at: now) }
                guard Self.isVisibleWithoutJobs(stale) else { continue }
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
                conversation.inputItems = visible[id]?.inputItems ?? []
            }
            conversation.jobs = Dictionary(grouping: members, by: \.jobID).map { id, processes in
                let titles = Set(processes.compactMap(\.title))
                let workers = processes.map(\.process).sorted { $0.id.pid < $1.id.pid }
                let processTitle: String? = if case .process = id { workers.first?.name } else { nil }
                return ClaudeJob(id: id, title: titles.count == 1 ? titles.first : processTitle,
                                processes: workers)
            }.sorted { ($0.processes.first?.id.pid ?? 0) < ($1.processes.first?.id.pid ?? 0) }
            if frame.processes.quality == .unavailable {
                for index in conversation.jobs.indices { conversation.jobs[index].processes = [] }
            }
            visible[id] = conversation
        }

        // Keep metadata for active sessions and the owners of surviving work.
        let remembered = Set(sessions.keys).union(visible.keys).union(work.values.compactMap(\.confirmedOwner))
        known = metadata.filter { remembered.contains($0.key) }
        return ClaudeSnapshot(conversations: visible.values.sorted(by: Self.precedes), inventory: frame.inventory.quality,
                             registrations: frame.registrations.quality, processes: frame.processes.quality,
                             taskRecords: frame.taskRecords.quality, inputRecords: frame.input.quality)
    }

    private static func sessions(in frame: ClaudeDiscoveryFrame, processes: [Int32: ClaudeObservedProcess], at now: Date)
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
            let statusRecord = if let record, record.entrypoint == "claude-desktop", record.activity != .unknown {
                record
            } else {
                agent ?? record
            }
            var session = ClaudeConversation(
                id: id, title: display(agent?.name) ?? display(record?.name) ?? "Claude session",
                path: display(agent?.cwd) ?? display(record?.cwd), activity: statusRecord?.activity ?? .unknown,
                waitingFor: display(statusRecord?.waitingFor) ?? display(record?.waitingFor), detached: detached,
                worker: worker
            )
            session.createdAt = session.sessionID.flatMap { frame.creationDates[$0] }
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
            let registeredWaitTime = record?.activity == .needsInput ? record?.statusUpdatedAt : nil
            let waitingSince = ClaudeInputDiscovery.date(milliseconds: statusRecord?.statusUpdatedAt ?? registeredWaitTime)
            let stored = frame.input.value.desktop[id]
            if case .desktop(let liveHost) = session.location, let stored, liveHost == nil || liveHost == stored.host {
                session.createdAt = stored.createdAt ?? session.createdAt
                session.location = .desktop(stored.host)
            }
            session.inputItems = Self.inputItems(for: session, from: frame.input.value, waitingSince: waitingSince, at: now)
            sessions[id] = session
        }

        for (id, stored) in frame.input.value.desktop where sessions[id] == nil {
            var session = ClaudeConversation(
                id: id, title: display(stored.title) ?? "Claude session",
                path: display(stored.path), activity: .idle, location: .desktop(stored.host), createdAt: stored.createdAt
            )
            session.inputItems = Self.inputItems(for: session, from: frame.input.value, waitingSince: nil, at: now)
            if !session.inputItems.isEmpty { sessions[id] = session }
        }
        return (sessions, roots)
    }

    private static func inputItems(for session: ClaudeConversation, from reading: ClaudeInputReading,
                                   waitingSince: Date?, at now: Date) -> [ClaudeInputItem] {
        let transcript = session.sessionID.flatMap { reading.transcripts[$0] }
        let stored = reading.desktop[session.id]
        let matchesDesktop: Bool
        if let stored {
            if case .desktop(let host) = session.location {
                matchesDesktop = host == stored.host
            } else {
                matchesDesktop = false
            }
        } else {
            matchesDesktop = false
        }
        var items: [ClaudeInputItem] = []
        if session.activity == .needsInput {
            let prompts = isQuestionWait(session.waitingFor) ? (transcript?.native ?? []) : []
            if prompts.isEmpty {
                items.append(ClaudeInputItem(kind: .native, text: session.waitingFor, date: waitingSince))
            } else {
                items.append(contentsOf: prompts.map {
                    ClaudeInputItem(kind: .native, text: $0.text, date: $0.date ?? waitingSince)
                })
            }
        } else if session.activity != .working, !(matchesDesktop && stored?.turnWasCutShort == true) {
            items.append(contentsOf: (transcript?.replies ?? []).map {
                ClaudeInputItem(kind: .reply, text: $0.text, date: $0.date)
            })
        }
        if stored == nil || matchesDesktop, let drafts = reading.drafts[session.id] {
            // A conversation can have drafts in more than one composer surface.
            // Show one label as long as at least one draft qualifies.
            let qualifying = drafts.map { ClaudeInputItem(kind: .draft, text: nil, date: $0) }.filter { $0.isRecent(at: now) }
            if let latest = qualifying.compactMap(\.date).max() {
                items.append(ClaudeInputItem(kind: .draft, text: nil, date: latest))
            } else if let unknown = qualifying.first {
                items.append(unknown)
            }
        }
        return items.filter { $0.isRecent(at: now) }
    }

    private static func isQuestionWait(_ reason: String?) -> Bool {
        guard let reason = reason?.lowercased() else { return true }
        // Claude Desktop reports AskUserQuestion as "input needed" and
        // other tool approvals as "permission prompt". An unmatched older
        // questionnaire cannot describe a new permission wait.
        return reason == "input needed" || reason == "input required" || reason.contains("question")
    }

    private static func workerListed(by agent: ClaudeSessionRecord?, in processes: [Int32: ClaudeObservedProcess]) -> ProcessIdentity? {
        guard let agent, let pid = agent.pid, let process = processes[pid], let milliseconds = agent.startedAt,
              abs(process.startedAt - milliseconds / 1_000) < 3 else { return nil }
        return process.identity
    }

    private func attributedWork(in processes: [Int32: ClaudeObservedProcess], roots: [Int32: Set<ClaudeConversationID>],
                                metadata: [ClaudeConversationID: ClaudeConversation],
                                taskRecords: [ClaudeTaskOutput: ClaudeTaskRecord],
                                sessions: [ClaudeConversationID: ClaudeConversation], sessionReadsComplete: Bool,
                                restrictToKnownConversations: Bool) -> [ProcessIdentity: Work] {
        // Preserve receipt-backed work beyond the transcript window for the
        // same live PID and start time. These receipts can also prove CLI work.
        var backgroundOutputs: Set<ClaudeTaskOutput> = []
        for process in processes.values where roots[process.identity.pid] == nil {
            for output in process.outputs {
                let prior = work[process.identity]
                let hasReceipt = taskRecords[output]?.backgroundedAt.map { $0 + 1 >= process.startedAt } == true
                if (prior?.output == output && prior?.backgrounded == true) || hasReceipt {
                    backgroundOutputs.insert(output)
                }
            }
        }

        var result: [ProcessIdentity: Work] = [:]
        for process in processes.values where roots[process.identity.pid] == nil {
            let prior = work[process.identity]
            var writer: ClaudeObservedProcess? = process.outputs.isEmpty ? nil : process
            var ownerRoots: Set<ClaudeConversationID> = []
            var root: ProcessIdentity?
            var markers = Set([process.sessionMarker].compactMap { $0 })
            var child = process
            while let parent = processes[child.parent], parent.identity.startedAt < child.identity.startedAt {
                if let owners = roots[parent.identity.pid] {
                    ownerRoots = owners
                    root = parent.identity
                    break
                }
                if writer == nil, !parent.outputs.isEmpty { writer = parent }
                if let marker = parent.sessionMarker { markers.insert(marker) }
                child = parent
            }

            var outputs = writer?.outputs.intersection(backgroundOutputs) ?? []
            let backgrounded = !outputs.isEmpty
            // A Desktop shell may be shown in Claude without a background
            // receipt. Qualify its writer in this ancestry chain only.
            if outputs.isEmpty, let writer, writer.outputs.count == 1, let candidate = writer.outputs.first,
               candidate.isLocalShell, markers.isSubset(of: [candidate.sessionID]) {
                let owner = ClaudeConversationID.session(candidate.sessionID)
                let previousWriter = work[writer.identity]
                let retained = ownerRoots.isEmpty && previousWriter?.output == candidate && previousWriter?.confirmedOwner == owner
                if ownerRoots == [owner], let root, let session = sessions[owner], session.worker == root,
                   case .desktop = session.location {
                    outputs.insert(candidate)
                } else if retained {
                    outputs.insert(candidate)
                }
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
            let title = output.flatMap { output in
                let record = taskRecords[output]
                let freshTitle = backgrounded || record?.backgroundedAt == nil ? record?.title : nil
                return freshTitle ?? (prior?.output == output ? prior?.title : nil)
            } ?? (mayOutliveTask && output == nil ? prior?.title : nil)
            result[process.identity] = Work(process: ClaudeJobProcess(id: process.identity, name: process.name),
                                            parent: process.parent, owner: resolved ?? .unknown,
                                            confirmedOwner: prior?.confirmedOwner ?? resolved, output: output,
                                            backgrounded: backgrounded, title: title)
        }
        return result
    }

    private static func display(_ string: String?) -> String? {
        guard let text = string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func isVisibleWithoutJobs(_ session: ClaudeConversation) -> Bool {
        !session.inputItems.isEmpty || session.detached && (session.worker != nil || session.activity == .working)
    }

    private static func precedes(_ left: ClaudeConversation, _ right: ClaudeConversation) -> Bool {
        func order(_ item: ClaudeConversation) -> Int {
            if item.id == .unknown { return 3 }
            if item.activity == .closed { return 2 }
            return item.inputItems.isEmpty ? 1 : 0
        }
        if order(left) != order(right) { return order(left) < order(right) }
        if !left.inputItems.isEmpty && !right.inputItems.isEmpty {
            switch (left.createdAt, right.createdAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate: return leftDate < rightDate
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
        }
        if left.title != right.title { return left.title.localizedStandardCompare(right.title) == .orderedAscending }
        return String(describing: left.id) < String(describing: right.id)
    }
}
