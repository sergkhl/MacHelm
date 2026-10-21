import Foundation

public struct ToolkitHelperError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// What the helper changes in macOS. The real one calls IOKit as root.
public protocol PowerSystem {
    func sleepDisabled() throws -> Bool
    func setSleepDisabled(_ disabled: Bool) throws
    func setTimer(_ timer: SleepTimer, minutes: Int) throws
}

// Whether this helper set the system's SleepDisabled, kept on disk so that a
// run that ended without clearing it is noticed at the next start.
public protocol StayAwakeJournal {
    func load() -> Bool
    func save(_ set: Bool) throws
}

// Removes a root target: one directory inside one of the folders it was given.
public struct RootRemover {
    // A folder the helper may clean, and how many levels inside it a directory may sit.
    public struct Root: Equatable, Sendable {
        public var path: String
        public var depth: Int

        public init(_ path: String, depth: Int) {
            self.path = path
            self.depth = depth
        }
    }

    // A simulator's dyld cache sits under the folder of the macOS build it
    // was made for: `dyld/25G83/<runtime>`. A whole build's folder goes when
    // that macOS is gone. Nothing MacHelm can ask for lies anywhere else.
    public static let roots = [Root("/Library/Developer/CoreSimulator/Caches/dyld", depth: 2)]
    public var roots: [Root]

    public init(roots: [Root] = RootRemover.roots) {
        self.roots = roots
    }

    // The path must name a real directory inside one of the roots, no deeper
    // than that root allows. Neither it nor any folder on the way may be a
    // link or a mount point, and it may not be reached through `..` or
    // through a root that is itself a link.
    public func remove(_ path: String) throws {
        let parts = (path as NSString).pathComponents
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !parts.contains(".."), !parts.contains(".") else {
            throw ToolkitHelperError("Not a plain path from the top: \(path)")
        }
        guard let root = roots.first(where: { path.hasPrefix($0.path + "/") }) else {
            throw ToolkitHelperError("Not inside a folder the helper may clean: \(path)")
        }
        let below = path.dropFirst(root.path.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...root.depth).contains(below.count), !below.contains(""), Self.realPath(root.path) == root.path else {
            throw ToolkitHelperError("Not a directory the helper may remove: \(path)")
        }
        var folder = stat()
        guard lstat(root.path, &folder) == 0, try Self.isSafeFolder(folder, root.path) else {
            throw ToolkitHelperError("Cannot read \(root.path)")
        }
        // Every step down from the root, the target last.
        var current = root.path
        for (index, name) in below.enumerated() {
            current += "/" + name
            var entry = stat()
            guard lstat(current, &entry) == 0 else { throw ToolkitHelperError("Cannot read \(current)") }
            guard entry.st_mode & S_IFMT == S_IFDIR else { throw ToolkitHelperError("Not a directory: \(current)") }
            // Another volume mounted here holds what that volume shows, not this folder's own files.
            guard entry.st_dev == folder.st_dev else { throw ToolkitHelperError("A volume is mounted at \(current)") }
            if index < below.count - 1, try !Self.isSafeFolder(entry, current) { throw ToolkitHelperError("Cannot read \(current)") }
        }
        // Removing a directory removes a link inside it as a link.
        try FileManager.default.removeItem(atPath: path)
    }

    // As root, a folder on the way must be root's own and closed to everyone
    // else, so that nobody can put a link in the place of what was checked.
    // Without root, as in the tests, whoever runs this can only remove their own.
    private static func isSafeFolder(_ folder: stat, _ path: String) throws -> Bool {
        guard geteuid() == 0 else { return true }
        guard folder.st_uid == 0, folder.st_mode & 0o022 == 0 else {
            throw ToolkitHelperError("\(path) can be changed by others than root.")
        }
        return true
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// The helper's four requests, over whatever stands for macOS.
// Kept by one queue.
public final class ToolkitHelperController {
    private let power: PowerSystem
    private let journal: StayAwakeJournal
    private let remover: RootRemover
    // The connection stay-awake is held for.
    private var holder: Int?

    public init(power: PowerSystem, journal: StayAwakeJournal, remover: RootRemover) {
        self.power = power
        self.journal = journal
        self.remover = remover
    }

    // A hold left by a run that ended without releasing it is cleared. The
    // journal says whether this helper set it: one the owner set with `pmset`
    // is theirs and stays.
    public func start() {
        guard journal.load() else { return }
        do {
            try power.setSleepDisabled(false)
            try journal.save(false)
        } catch {
            // It stays on record, and the next start tries again.
        }
    }

    // Nothing is held: the helper may exit.
    public var isIdle: Bool { holder == nil }

    public func state() -> ToolkitHelperReply {
        reply()
    }

    public func hold(_ hold: Bool, client: Int) -> ToolkitHelperReply {
        do {
            if hold {
                guard holder == nil else {
                    holder = client
                    return reply()
                }
                // Already set, and not by this helper: held as found, and left as found.
                if try !power.sleepDisabled() {
                    // On record first: what could not be written down could not be cleared after a crash.
                    try journal.save(true)
                    do { try power.setSleepDisabled(true) } catch {
                        // The change may have gone through although it could not be
                        // confirmed. It is taken back; if that fails too it stays on
                        // record, and the next start or the helper's stopping clears it.
                        if (try? power.setSleepDisabled(false)) != nil { try? journal.save(false) }
                        throw error
                    }
                }
                holder = client
            } else if holder != nil {
                try release()
            }
            return reply()
        } catch {
            return reply(error: error.localizedDescription)
        }
    }

    // launchd is stopping the helper, as it does when the owner turns
    // MacHelm off under Login Items & Extensions. Nothing would start it
    // again to clear what it set, so it is cleared now.
    public func stopping() {
        try? release()
    }

    // The client quit, crashed or lost its connection.
    public func clientGone(_ client: Int) {
        guard holder == client else { return }
        try? release()
    }

    private func release() throws {
        if journal.load() {
            try power.setSleepDisabled(false)
            try journal.save(false)
        }
        holder = nil
    }

    // Q33: a timer is written with the value chosen, or not at all.
    public func setTimer(_ name: String, minutes: Int) -> ToolkitHelperReply {
        guard let timer = SleepTimer(rawValue: name), SleepTimer.minutes.contains(minutes) else {
            return reply(error: "Not a sleep timer and a value MacHelm offers: \(name), \(minutes).")
        }
        do {
            try power.setTimer(timer, minutes: minutes)
            return reply()
        } catch {
            return reply(error: error.localizedDescription)
        }
    }

    public func remove(path: String) -> ToolkitHelperReply {
        do {
            try remover.remove(path)
            return reply()
        } catch {
            return reply(error: error.localizedDescription)
        }
    }

    private func reply(error: String? = nil) -> ToolkitHelperReply {
        ToolkitHelperReply(stayAwakeHeld: holder != nil, sleepDisabled: try? power.sleepDisabled(), error: error)
    }
}
