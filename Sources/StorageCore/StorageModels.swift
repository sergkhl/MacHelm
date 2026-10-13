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
    public var label: String
    public var state: StorageTargetState
    public var detail: String
    // In kilobytes; nil when it could not be measured.
    public var sizeKB: Int?
    // What removing it frees; nil when that cannot be known in advance.
    public var projectedKB: Int?
    // A root target: it lies in a folder only root can change.
    public var needsRoot: Bool
    public var defaultSelected: Bool
    public var lastUsedAt: String?
    public var paths: [String]
    // Targets that share this tag are treatments of one thing: choosing one clears the others.
    public var exclusive: String

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, group, label, state, detail, paths, exclusive
        case sizeKB = "size_kb"
        case projectedKB = "projected_kb"
        case needsRoot = "needs_sudo"
        case defaultSelected = "default_selected"
        case lastUsedAt = "last_used_at"
    }

    public init(key: String, group: String = "", label: String = "", state: StorageTargetState = .selectable, detail: String = "",
                sizeKB: Int? = 0, projectedKB: Int? = 0, needsRoot: Bool = false, defaultSelected: Bool = false,
                lastUsedAt: String? = nil, paths: [String] = [], exclusive: String = "") {
        self.key = key
        self.group = group
        self.label = label
        self.state = state
        self.detail = detail
        self.sizeKB = sizeKB
        self.projectedKB = projectedKB
        self.needsRoot = needsRoot
        self.defaultSelected = defaultSelected
        self.lastUsedAt = lastUsedAt
        self.paths = paths
        self.exclusive = exclusive
    }
}

// What the script says while MacHelm runs it: one of these per line.
public enum StorageEvent: Equatable, Sendable {
    case targets(freeKB: Int, [StorageTarget])
    // The script asks for a root target's removal and waits for one line back.
    case removeRoot(path: String)
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
            return .targets(freeKB: free, targets)
        case "remove-root":
            guard let path = object["path"] as? String else { return nil }
            return .removeRoot(path: path)
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
    // same Python and tools as in a terminal. Without keys it scans.
    public static func command(shell: String, script: String, select keys: [String]? = nil) -> (executable: String, arguments: [String]) {
        // The script and what follows it reach the shell as arguments, so nothing in a key is read as a command.
        var arguments = ["-l", "-i", "-c", "exec python3 \"$0\" \"$@\"", script, "--app"]
        if let keys { arguments += ["--select", keys.joined(separator: ",")] }
        return (shell, arguments)
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
