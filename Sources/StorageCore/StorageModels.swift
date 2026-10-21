import Foundation

public enum StorageTargetState: String, Codable, Sendable {
    case selectable
    // It cannot be removed from here.
    case blocked
    // Measured, never touched.
    case reportOnly = "report_only"
}

// One thing a scan lists, as the cleanup script reports it (ADR 0004).
public struct StorageTarget: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    public var group: String
    // The level between the group and this target, such as App caches (ADR 0008); "" for none.
    public var kind: String
    public var label: String
    public var state: StorageTargetState
    public var detail: String
    // In kilobytes; nil when it could not be measured.
    public var sizeKB: Int?
    // What removing it frees; nil when that cannot be known in advance.
    public var projectedKB: Int?
    // A root target: it lies in a folder only root can change.
    public var needsRoot: Bool
    // macOS kept a folder of it from the script until Full Disk Access is granted.
    public var needsFullDiskAccess: Bool
    public var defaultSelected: Bool
    public var lastUsedAt: String?
    public var paths: [String]
    // Targets that share this tag are treatments of one thing: choosing one clears the others.
    public var exclusive: String

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, group, kind, label, state, detail, paths, exclusive
        case sizeKB = "size_kb"
        case projectedKB = "projected_kb"
        case needsRoot = "needs_sudo"
        case needsFullDiskAccess = "needs_full_disk_access"
        case defaultSelected = "default_selected"
        case lastUsedAt = "last_used_at"
    }

    public init(key: String, group: String = "", kind: String = "", label: String = "", state: StorageTargetState = .selectable,
                detail: String = "", sizeKB: Int? = 0, projectedKB: Int? = 0, needsRoot: Bool = false,
                needsFullDiskAccess: Bool = false, defaultSelected: Bool = false, lastUsedAt: String? = nil,
                paths: [String] = [], exclusive: String = "") {
        self.key = key
        self.group = group
        self.kind = kind
        self.label = label
        self.state = state
        self.detail = detail
        self.sizeKB = sizeKB
        self.projectedKB = projectedKB
        self.needsRoot = needsRoot
        self.needsFullDiskAccess = needsFullDiskAccess
        self.defaultSelected = defaultSelected
        self.lastUsedAt = lastUsedAt
        self.paths = paths
        self.exclusive = exclusive
    }

    // A script from before ADR 0008 names no kind and no access.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        group = try values.decode(String.self, forKey: .group)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? ""
        label = try values.decode(String.self, forKey: .label)
        state = try values.decode(StorageTargetState.self, forKey: .state)
        detail = try values.decode(String.self, forKey: .detail)
        sizeKB = try values.decodeIfPresent(Int.self, forKey: .sizeKB)
        projectedKB = try values.decodeIfPresent(Int.self, forKey: .projectedKB)
        needsRoot = try values.decode(Bool.self, forKey: .needsRoot)
        needsFullDiskAccess = try values.decodeIfPresent(Bool.self, forKey: .needsFullDiskAccess) ?? false
        defaultSelected = try values.decode(Bool.self, forKey: .defaultSelected)
        lastUsedAt = try values.decodeIfPresent(String.self, forKey: .lastUsedAt)
        paths = try values.decode([String].self, forKey: .paths)
        exclusive = try values.decode(String.self, forKey: .exclusive)
    }
}

// What the script says while MacHelm runs it: one of these per line.
public enum StorageEvent: Equatable, Sendable {
    // asOf and idleDays are what the scan judged idleness by; a clean passes them back.
    case targets(freeKB: Int, asOf: Double?, idleDays: Int?, [StorageTarget])
    // The script asks for a root target's removal and waits for one line back.
    case removeRoot(path: String)
    // How far a scan ("scanning") or the removals ("deleting") have got, a few times a second.
    case progress(phase: String, done: Int, total: Int)
    // What a target being removed is doing now; "" when it has just started.
    case working(key: String, detail: String)
    case result(key: String, ok: Bool, freedKB: Int?, error: String?)
    case done(reclaimedKB: Int, failures: Int, freeKB: Int)
    case error(String)
}

public enum StorageProtocol {
    // The event in one line of output. The shell's own start-up output may
    // stand before it on the same line; a line without an event gives nil.
    public static func event(in line: String) -> StorageEvent? {
        guard let start = line.range(of: "{\"event\"") else { return nil }
        let data = Data(line[start.lowerBound...].utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = object["event"] as? String else {
            return nil
        }
        switch name {
        case "targets":
            guard let free = object["free_kb"] as? Int, let listed = object["targets"],
                  let encoded = try? JSONSerialization.data(withJSONObject: listed),
                  let targets = try? JSONDecoder().decode([StorageTarget].self, from: encoded) else { return nil }
            return .targets(freeKB: free, asOf: object["as_of"] as? Double, idleDays: object["idle_days"] as? Int, targets)
        case "remove-root":
            guard let path = object["path"] as? String else { return nil }
            return .removeRoot(path: path)
        case "progress":
            guard let phase = object["phase"] as? String, let done = object["done"] as? Int,
                  let total = object["total"] as? Int else { return nil }
            return .progress(phase: phase, done: done, total: total)
        case "working":
            guard let key = object["key"] as? String else { return nil }
            return .working(key: key, detail: object["detail"] as? String ?? "")
        case "result":
            guard let key = object["key"] as? String, let ok = object["ok"] as? Bool else { return nil }
            return .result(key: key, ok: ok, freedKB: object["freed_kb"] as? Int, error: object["error"] as? String)
        case "done":
            guard let reclaimed = object["reclaimed_kb"] as? Int, let failures = object["failures"] as? Int,
                  let free = object["free_kb"] as? Int else { return nil }
            return .done(reclaimedKB: reclaimed, failures: failures, freeKB: free)
        case "error":
            return (object["message"] as? String).map { .error($0) }
        default:
            return nil
        }
    }

    // The one line that answers a root removal.
    public static func reply(ok: Bool, error: String? = nil) -> String {
        var answer: [String: Any] = ["ok": ok]
        if let error { answer["error"] = error }
        // One line: the encoder escapes a line break inside the reason.
        let data = (try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // The script through the owner's login shell (Q26), so that it finds the
    // same Python and tools as in a terminal. Without keys it scans. A clean
    // passes back the scan's instant and idle days, so it judges idleness as
    // the scan did and removes nothing that went idle in between (ADR 0008).
    public static func command(shell: String, script: String, select keys: [String]? = nil,
                               idleDays: Int? = nil, asOf: Double? = nil) -> (executable: String, arguments: [String]) {
        // The script and what follows it reach the shell as arguments, so nothing in a key is read as a command.
        var arguments = ["-l", "-i", "-c", "exec python3 \"$0\" \"$@\"", script, "--app"]
        if let idleDays { arguments += ["--idle-days", String(idleDays)] }
        if let asOf { arguments += ["--as-of", String(asOf)] }
        if let keys { arguments += ["--select", keys.joined(separator: ",")] }
        return (shell, arguments)
    }
}

// What a Clean did to one target, as the script reported it.
public struct StorageResult: Equatable, Sendable {
    public var ok: Bool
    // What it freed; for a target that failed, what went before it did.
    public var freedKB: Int?
    // Its first line says what happened; further lines say why, part by part.
    public var error: String?

    public init(ok: Bool, freedKB: Int? = nil, error: String? = nil) {
        self.ok = ok
        self.freedKB = freedKB
        self.error = error
    }

    // Part of it went before the rest failed.
    public var partly: Bool { !ok && (freedKB ?? 0) > 0 }

    // What the row says about it after the Clean.
    public var note: String {
        if ok { return "Removed" + (freedKB.map { ": \(StorageCleanReport.bytes($0))" } ?? "") }
        let reason = error ?? "no reason was given"
        return partly ? "Partly removed, \(StorageCleanReport.bytes(freedKB ?? 0)) freed: \(reason)" : "Not removed: \(reason)"
    }
}

// What a finished Clean says (2026-10-15). "17 not removed: A; B; C and 14
// more. Their rows say why" sent the owner to rows that the scan after the
// Clean no longer listed, because their files had gone after all. The report
// keeps each target that was not removed, or only in part, with the script's
// reason, in the list's order, until the next Scan or Clean.
public struct StorageCleanReport: Equatable, Sendable {
    public struct Failure: Equatable, Identifiable, Sendable {
        public var key: String
        // The row as the list names it, its kind in front.
        public var title: String
        public var result: StorageResult

        public var id: String { key }

        public var outcome: String {
            result.partly ? "Partly removed, \(StorageCleanReport.bytes(result.freedKB ?? 0)) freed" : "Not removed"
        }

        public var reason: String { result.error ?? "No reason was given." }
    }

    public var reclaimedKB: Int
    // The targets that did not complete, as the script counted them.
    public var failures: Int
    public var notRemoved: [Failure]

    public init(reclaimedKB: Int, failures: Int, confirmed: [StorageTarget], results: [String: StorageResult]) {
        self.reclaimedKB = reclaimedKB
        self.failures = failures
        notRemoved = confirmed.compactMap { target in
            guard let result = results[target.key], !result.ok else { return nil }
            return Failure(key: target.key, title: target.kind.isEmpty ? target.label : "\(target.kind): \(target.label)", result: result)
        }
    }

    public var reclaimed: String { "Reclaimed \(Self.bytes(reclaimedKB))" }

    public var outcome: String {
        guard failures > 0 else { return "Everything you checked was removed." }
        // A refused run reports no targets: the count alone.
        guard !notRemoved.isEmpty else { return "\(failures) did not complete; nothing else was affected." }
        let partly = notRemoved.contains { $0.result.partly }
        return "\(notRemoved.count) not removed\(partly ? " or only in part" : ""); nothing else was affected."
    }

    static func bytes(_ kilobytes: Int) -> String {
        Int64(kilobytes * 1_024).formatted(.byteCount(style: .file))
    }
}

// How long a chat, session or worktree must be left alone to be listed (ADR 0008).
public enum StorageIdle {
    public static let days = 1...90
    public static let standard = 7

    public static func clamped(_ value: Int) -> Int {
        min(max(value, days.lowerBound), days.upperBound)
    }
}

// What a scan lists, as the page shows it: groups, the kinds inside them, and
// the targets, all in the script's order (ADR 0008).
public struct StorageKind: Equatable, Identifiable, Sendable {
    public var group: String
    public var name: String
    public var targets: [StorageTarget]

    public var id: String { group + "\u{1F}" + name }
}

public enum StorageEntry: Equatable, Identifiable, Sendable {
    case target(StorageTarget)
    case kind(StorageKind)

    public var id: String {
        switch self {
        case .target(let target): return "target:" + target.key
        case .kind(let kind): return "kind:" + kind.id
        }
    }
}

public struct StorageGroup: Equatable, Identifiable, Sendable {
    public var name: String
    public var entries: [StorageEntry]

    public var id: String { name }

    // Every target in the group, those inside kinds too.
    public var targets: [StorageTarget] {
        entries.flatMap { entry -> [StorageTarget] in
            switch entry {
            case .target(let target): return [target]
            case .kind(let kind): return kind.targets
            }
        }
    }
}

public enum StorageTree {
    // A kind sits where its first target is listed.
    public static func groups(_ targets: [StorageTarget]) -> [StorageGroup] {
        var groups: [StorageGroup] = []
        for target in targets {
            if !groups.contains(where: { $0.name == target.group }) {
                groups.append(StorageGroup(name: target.group, entries: []))
            }
            let index = groups.firstIndex { $0.name == target.group }!
            guard !target.kind.isEmpty else {
                groups[index].entries.append(.target(target))
                continue
            }
            let existing = groups[index].entries.firstIndex {
                if case .kind(let kind) = $0 { return kind.name == target.kind }
                return false
            }
            if let existing, case .kind(var kind) = groups[index].entries[existing] {
                kind.targets.append(target)
                groups[index].entries[existing] = .kind(kind)
            } else {
                groups[index].entries.append(.kind(StorageKind(group: target.group, name: target.kind, targets: [target])))
            }
        }
        return groups
    }

    // What a group or kind holds: what its targets free, or occupy where they
    // cannot be removed. Treatments of one thing count once, at their largest.
    public static func size(of targets: [StorageTarget]) -> (kilobytes: Int, atLeast: Bool) {
        var total = 0, unknown = false
        var largest: [String: Int] = [:]
        for target in targets {
            let value = target.state == .selectable ? target.projectedKB : target.sizeKB
            if value == nil { unknown = true }
            if target.exclusive.isEmpty {
                total += value ?? 0
            } else {
                largest[target.exclusive] = max(largest[target.exclusive] ?? 0, value ?? 0)
            }
        }
        return (total + largest.values.reduce(0, +), unknown)
    }
}

// The folder the toolkit helper may clean, with how deep in it a directory may sit (ADR 0003).
public struct StorageRoot: Equatable, Sendable {
    public var path: String
    public var depth: Int

    public init(_ path: String, depth: Int) {
        self.path = path
        self.depth = depth
    }

    public static let helper = [StorageRoot("/Library/Developer/CoreSimulator/Caches/dyld", depth: 2)]

    // Whether the path names something inside this folder, no deeper than it is cleaned.
    public func holds(_ path: String) -> Bool {
        guard path.hasPrefix(self.path + "/") else { return false }
        let below = path.dropFirst(self.path.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        return (1...depth).contains(below.count) && !below.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

// Which targets are checked, and what the owner may check.
public struct StorageSelection: Equatable, Sendable {
    public private(set) var keys: Set<String> = []

    public init() {}

    // The script's own defaults (Q24). A root target is checked only where the helper can remove it.
    public init(defaultsOf targets: [StorageTarget], helperReady: Bool) {
        keys = Set(targets.filter { $0.defaultSelected && Self.canSelect($0, helperReady: helperReady) }.map(\.key))
    }

    // Whether the owner may check it here: a root target needs the helper, and a path the helper may clean.
    public static func canSelect(_ target: StorageTarget, helperReady: Bool, roots: [StorageRoot] = StorageRoot.helper) -> Bool {
        guard target.state == .selectable else { return false }
        return !target.needsRoot || (helperReady && target.paths.contains { path in roots.contains { $0.holds(path) } })
    }

    // A root target the app cannot remove: its row offers the command for a terminal.
    public static func needsTerminal(_ target: StorageTarget, helperReady: Bool, roots: [StorageRoot] = StorageRoot.helper) -> Bool {
        target.state == .selectable && target.needsRoot && !canSelect(target, helperReady: helperReady, roots: roots)
    }

    public mutating func toggle(_ key: String, in targets: [StorageTarget], helperReady: Bool) {
        guard let target = targets.first(where: { $0.key == key }), Self.canSelect(target, helperReady: helperReady) else { return }
        if keys.remove(key) != nil { return }
        // Delete or erase this simulator, never both.
        if !target.exclusive.isEmpty {
            for other in targets where other.exclusive == target.exclusive { keys.remove(other.key) }
        }
        keys.insert(key)
    }

    // Select All: everything the owner may check here. Of the treatments of
    // one thing one is checked: the one that was, else the script's own
    // choice, else the first listed.
    public mutating func selectAll(in targets: [StorageTarget], helperReady: Bool) {
        let allowed = targets.filter { Self.canSelect($0, helperReady: helperReady) }
        var all: Set<String> = []
        var decided: Set<String> = []
        for target in allowed {
            guard !target.exclusive.isEmpty else {
                all.insert(target.key)
                continue
            }
            guard decided.insert(target.exclusive).inserted else { continue }
            let treatments = allowed.filter { $0.exclusive == target.exclusive }
            all.insert((treatments.first { keys.contains($0.key) } ?? treatments.first(where: \.defaultSelected) ?? target).key)
        }
        keys = all
    }

    public mutating func selectNone() {
        keys = []
    }

    // A group's or kind's checkbox (ADR 0008).
    public enum CheckState: Equatable, Sendable {
        case unchecked, mixed, checked
        // Nothing below it may be checked here.
        case unavailable
    }

    // Treatments of one thing count as one: any of them checked checks that thing.
    public func state(of children: [StorageTarget], helperReady: Bool) -> CheckState {
        let allowed = children.filter { Self.canSelect($0, helperReady: helperReady) }
        guard !allowed.isEmpty else { return .unavailable }
        var things: [String: Bool] = [:]
        for target in allowed {
            let thing = target.exclusive.isEmpty ? "key:" + target.key : "one-of:" + target.exclusive
            things[thing] = (things[thing] ?? false) || keys.contains(target.key)
        }
        let checked = things.values.filter { $0 }.count
        return checked == 0 ? .unchecked : checked == things.count ? .checked : .mixed
    }

    // Checks or clears everything below a group or kind that may be checked
    // here. Of treatments of one thing one is checked: the one that was, else
    // the script's own choice, else the first listed below this parent.
    public mutating func set(_ checked: Bool, children: [StorageTarget], in targets: [StorageTarget], helperReady: Bool) {
        let allowed = children.filter { Self.canSelect($0, helperReady: helperReady) }
        guard checked else {
            for target in allowed { keys.remove(target.key) }
            return
        }
        var decided: Set<String> = []
        for target in allowed {
            guard !target.exclusive.isEmpty else {
                keys.insert(target.key)
                continue
            }
            guard decided.insert(target.exclusive).inserted else { continue }
            let treatments = allowed.filter { $0.exclusive == target.exclusive }
            let chosen = treatments.first { keys.contains($0.key) } ?? treatments.first(where: \.defaultSelected) ?? target
            for other in targets where other.exclusive == target.exclusive { keys.remove(other.key) }
            keys.insert(chosen.key)
        }
    }

    // Whether Select All would change nothing.
    public func holdsAll(in targets: [StorageTarget], helperReady: Bool) -> Bool {
        var all = self
        all.selectAll(in: targets, helperReady: helperReady)
        return all.keys == keys
    }

    // In the list's order. A target that a later scan no longer lists, or
    // lists as blocked, is not passed on.
    public func chosen(in targets: [StorageTarget]) -> [StorageTarget] {
        targets.filter { keys.contains($0.key) && $0.state == .selectable }
    }

    // What the checked targets free, and whether that is a lower bound because one of them cannot say.
    public func total(in targets: [StorageTarget]) -> (kilobytes: Int, atLeast: Bool) {
        let chosen = chosen(in: targets)
        return (chosen.reduce(0) { $0 + ($1.projectedKB ?? 0) }, chosen.contains { $0.projectedKB == nil })
    }
}

public enum RootRemovalPolicy {
    // Q28: the app asks its helper only for a path the scan listed for a
    // root target the owner confirmed.
    public static func allows(_ path: String, confirmed: [StorageTarget]) -> Bool {
        confirmed.contains { $0.needsRoot && $0.state == .selectable && $0.paths.contains(path) }
    }
}
