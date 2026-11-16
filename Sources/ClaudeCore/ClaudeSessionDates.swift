import Darwin
import Foundation

enum ClaudeSessionDates {
    private struct DesktopSession: Decodable {
        let sessionId: String
        let cliSessionId: UUID
        let createdAt: Double
    }

    private struct TranscriptEntry: Decodable {
        let sessionId: UUID
        let timestamp: String
    }

    private struct DirectoryIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Candidates {
        private var seen: Set<UUID> = []
        private(set) var dates: [UUID: Date] = [:]

        mutating func read(_ session: UUID, date: () -> Date?) {
            guard seen.insert(session).inserted else {
                dates.removeValue(forKey: session)
                return
            }
            dates[session] = date()
        }
    }

    static func desktopDates(for records: [ClaudeSessionRecord], home: URL) -> [UUID: Date] {
        var hostsBySession: [UUID: Set<String>] = [:]
        var sessionsByHost: [String: Set<UUID>] = [:]
        for record in records where record.entrypoint == "claude-desktop" {
            guard let host = ClaudeDesktopID(record.hostSessionId)?.value, let session = record.sessionID else { continue }
            hostsBySession[session, default: []].insert(host)
            sessionsByHost[host, default: []].insert(session)
        }
        let nominated = hostsBySession.compactMap { session, hosts -> (String, UUID)? in
            guard hosts.count == 1, let host = hosts.first, sessionsByHost[host] == [session] else { return nil }
            return (host, session)
        }
        guard !nominated.isEmpty else { return [:] }

        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        let decoder = JSONDecoder()
        let limit = 1_048_576
        var candidates = Candidates()
        withDirectory(root.path) { rootFD, _ in
            for account in children(of: rootFD) where UUID(uuidString: account) != nil {
                withDirectory(account, relativeTo: rootFD) { accountFD, _ in
                    for scope in children(of: accountFD) where UUID(uuidString: scope) != nil {
                        withDirectory(scope, relativeTo: accountFD) { scopeFD, _ in
                            for (host, session) in nominated {
                                withRegularFile(host + ".json", relativeTo: scopeFD) { handle in
                                    candidates.read(session) {
                                        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
                                              let entry = try? decoder.decode(DesktopSession.self, from: data),
                                              entry.sessionId == host, entry.cliSessionId == session,
                                              entry.createdAt.isFinite, entry.createdAt > 0 else { return nil }
                                        return Date(timeIntervalSince1970: entry.createdAt / 1_000)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return candidates.dates
    }

    static func cliDates(for sessions: Set<UUID>, configs: Set<URL>) -> [UUID: Date] {
        guard !sessions.isEmpty else { return [:] }
        var seenRoots: Set<DirectoryIdentity> = []
        var candidates = Candidates()
        let nominated = sessions.map { ($0.uuidString.lowercased() + ".jsonl", $0) }
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle()
        for config in configs {
            // CLI profiles can share their configured projects tree.
            let root = config.appendingPathComponent("projects", isDirectory: true).resolvingSymlinksInPath()
            withDirectory(root.path) { rootFD, info in
                guard seenRoots.insert(.init(device: info.st_dev, inode: info.st_ino)).inserted else { return }
                for project in children(of: rootFD) {
                    withDirectory(project, relativeTo: rootFD) { projectFD, _ in
                        for (file, session) in nominated {
                            withRegularFile(file, relativeTo: projectFD) { handle in
                                candidates.read(session) {
                                    guard let data = try? handle.read(upToCount: 65_536) else { return nil }
                                    // Ignore the final fragment, which may be cut off mid-write or by the read limit.
                                    for line in data.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
                                        guard let entry = try? decoder.decode(TranscriptEntry.self, from: Data(line)),
                                              entry.sessionId == session else { continue }
                                        if let date = (try? fractional.parse(entry.timestamp)) ?? (try? whole.parse(entry.timestamp)) {
                                            return date
                                        }
                                    }
                                    return nil
                                }
                            }
                        }
                    }
                }
            }
        }
        return candidates.dates
    }

    private static func withDirectory(_ path: String, relativeTo parent: Int32 = AT_FDCWD, _ use: (Int32, stat) -> Void) {
        let fd = openat(parent, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else { return }
        use(fd, info)
    }

    private static func children(of fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(directory) }
        var result: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            if let name, name != ".", name != ".." { result.append(name) }
        }
        return result
    }

    private static func withRegularFile(_ name: String, relativeTo parent: Int32, _ use: (FileHandle) -> Void) {
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return }
        use(FileHandle(fileDescriptor: fd, closeOnDealloc: false))
    }
}
