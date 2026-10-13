import Foundation

public enum ActivityMeasure: String, CaseIterable, Sendable {
    case cpu, memory, gpu, energy, disk

    // Below this a process group is not listed.
    var floor: Double {
        switch self {
        case .cpu, .gpu: return 0.05
        case .memory: return 1
        case .energy: return 0.005
        case .disk: return 1_024
        }
    }

    func value(of process: ProcessAverage) -> Double? {
        switch self {
        case .cpu: return process.cpuPercent
        case .memory: return process.memoryBytes
        case .gpu: return process.gpuPercent
        case .energy: return process.energyWatts
        case .disk: return process.diskBytesPerSecond
        }
    }
}

public struct ActivityProcessRow: Equatable, Identifiable, Sendable {
    public var identity: ProcessIdentity
    public var name: String
    public var value: Double
    public var actions: [ProcessAction]
    public var kind: String?
    public var starter: ProcessStarter?
    public var responsibleApp: String?
    public var chain: [String] = []
    public var ended = false

    public var id: ProcessIdentity { identity }
}

public struct ActivityRow: Equatable, Identifiable, Sendable {
    public var group: ProcessGroupID
    public var value: Double
    // Those with a figure for this measure, heaviest first.
    public var processes: [ActivityProcessRow]
    // Every running process of the group, which is what Quit and Force Quit act on.
    public var members: [ProcessIdentity]
    public var actions: [ProcessAction]
    // Every process of the group has ended.
    public var ended = false

    public var id: ProcessGroupID { group }
}

public struct ActivitySnapshot: Equatable, Sendable {
    public var seconds: TimeInterval
    public var rows: [ActivityMeasure: [ActivityRow]]

    public init(seconds: TimeInterval, rows: [ActivityMeasure: [ActivityRow]]) {
        self.seconds = seconds
        self.rows = rows
    }

    public func heaviest(_ measure: ActivityMeasure) -> ActivityRow? {
        rows[measure]?.first
    }
}

public enum ActivityRanking {
    public static let count = 5

    // The rows in an order held from before: those still listed stay where
    // they were, with their new figures, and a newcomer joins at the end.
    public static func keeping(_ order: [ProcessGroupID], in rows: [ActivityRow]) -> [ActivityRow] {
        guard !order.isEmpty else { return rows }
        let listed = Dictionary(rows.map { ($0.group, $0) }) { first, _ in first }
        let held = Set(order)
        return order.compactMap { listed[$0] } + rows.filter { !held.contains($0.group) }
    }

    // The heaviest processes: for each measure, the five process groups with the highest average.
    public static func snapshot(of averages: ActivityAverages, services: [ServiceRoot], ownPID: Int32) -> ActivitySnapshot {
        let roots = Dictionary(services.map { ($0.pid, $0) }) { first, _ in first }
        var members: [ProcessGroupID: [ProcessAverage]] = [:]
        for process in averages.processes {
            members[ProcessGrouping.group(of: process.description, parents: averages.parents, services: roots), default: []].append(process)
        }
        let stoppable = Set(services.filter(\.canStop).map(\.id))
        // An action reaches what still runs. A row with nothing running offers none.
        var running: [ProcessGroupID: [ProcessDescription]] = [:]
        var actions: [ProcessGroupID: [ProcessAction]] = [:]
        for (group, processes) in members {
            let live = processes.filter { !$0.ended }.map(\.description)
            running[group] = live
            actions[group] = live.isEmpty ? [] : ProcessActionPolicy.actions(for: group, members: live, ownPID: ownPID,
                                                                             stoppableServices: stoppable)
        }

        var rows: [ActivityMeasure: [ActivityRow]] = [:]
        for measure in ActivityMeasure.allCases {
            var ranked: [ActivityRow] = []
            for (group, processes) in members {
                let groupActions = actions[group] ?? []
                let parts = processes.compactMap { process -> ActivityProcessRow? in
                    guard let value = measure.value(of: process), value > 0 else { return nil }
                    let description = process.description
                    return ActivityProcessRow(identity: description.identity, name: description.name, value: value,
                                              actions: process.ended ? [] : ProcessActionPolicy.actions(forProcessIn: groupActions),
                                              kind: description.kind, starter: description.starter,
                                              responsibleApp: description.responsibleApp, chain: description.chain, ended: process.ended)
                }
                let total = parts.reduce(0) { $0 + $1.value }
                guard total >= measure.floor else { continue }
                ranked.append(ActivityRow(group: group, value: total,
                                          processes: parts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.identity.pid < $1.identity.pid },
                                          members: (running[group] ?? []).map(\.identity).sorted { $0.pid < $1.pid },
                                          actions: groupActions, ended: (running[group] ?? []).isEmpty))
            }
            // The name settles a tie, so equal rows do not swap places from one second to the next.
            ranked.sort { $0.value != $1.value ? $0.value > $1.value : $0.group.name < $1.group.name }
            rows[measure] = Array(ranked.prefix(count))
        }
        return ActivitySnapshot(seconds: averages.seconds, rows: rows)
    }
}

// The wording of what a row says about time and about who started what.
public enum ActivityText {
    // What the averages cover: "10 seconds", "5 minutes", and "2 min 30 s" while a long window fills.
    public static func span(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) seconds" }
        if whole % 60 == 0 { return whole == 60 ? "1 minute" : "\(whole / 60) minutes" }
        return "\(whole / 60) min \(whole % 60) s"
    }

    // A row's second line: who started this copy of the app.
    public static func origin(_ origin: [String]) -> String? {
        origin.isEmpty ? nil : "from " + origin.joined(separator: " ← ")
    }

    // The line under a process of an expanded row, where it tells something the row does not.
    public static func startedBy(_ process: ActivityProcessRow, in group: ProcessGroupID) -> String? {
        var parts: [String] = []
        if let starter = process.starter, starter.name != group.origin.first {
            parts.append("started by \(starter.name) " + (starter.ended ? "(ended)" : "(PID \(starter.pid))"))
        }
        if let app = process.responsibleApp, !group.origin.contains(app) { parts.append("for \(app)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
