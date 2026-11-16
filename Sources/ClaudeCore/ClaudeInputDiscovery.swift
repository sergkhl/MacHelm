import Darwin
import Foundation
import os

struct ClaudeStoredDesktopSession: Equatable, Sendable {
    let host: ClaudeDesktopID
    let sessionID: UUID?
    let accountID: UUID
    let title: String?
    let path: String?
    let createdAt: Date?
    let turnWasCutShort: Bool

    var id: ClaudeConversationID { sessionID.map(ClaudeConversationID.session) ?? .desktop(host) }
}

struct ClaudeInputReading: Sendable {
    var desktop: [ClaudeConversationID: ClaudeStoredDesktopSession] = [:]
    var transcripts: [UUID: ClaudeTranscriptInput] = [:]
    var drafts: [ClaudeConversationID: [Date?]] = [:]
}

struct ClaudeInputDiscovery: Sendable {
    private struct DesktopMetadata: Decodable {
        let sessionId: String
        let cliSessionId: UUID?
        let title: String?
        let cwd: String?
        let createdAt: Double?
        let isArchived: Bool?
        let lastTurnCutShort: Bool?
    }

    private struct DesktopScope {
        let account: UUID
        let directory: URL
    }

    private struct Revision: Equatable {
        let device: dev_t
        let inode: ino_t
        let modified: Date
        let size: off_t
    }

    private struct CachedTranscript {
        let revision: Revision
        let input: ClaudeTranscriptInput
    }

    private struct CLIJob: Decodable {
        let sessionId: UUID?
        let resumeSessionId: UUID?
    }

    private struct Stash: Decodable { let text: String }

    private let transcriptCache = OSAllocatedUnfairLock(initialState: [URL: CachedTranscript]())

    func read(home: URL, records: [ClaudeSessionRecord], configs: Set<URL>, at now: Date)
        -> ClaudeRead<ClaudeInputReading> {
        let cutoff = now.addingTimeInterval(-ClaudeInputItem.lookback)
        let drafts = ClaudeDesktopDrafts.read(home: home)
        let catalog = Self.desktopCatalog(home: home, live: records, draftHosts: Set(drafts.value.keys), since: cutoff)
        var result = ClaudeInputReading(desktop: catalog.value)
        for session in catalog.value.values {
            let saved = drafts.value[session.host, default: []].filter { draft in
                draft.ownerID == nil || draft.ownerID.flatMap(UUID.init(uuidString:)) == session.accountID
            }
            if !saved.isEmpty { result.drafts[session.id] = saved.map(\.savedAt) }
        }
        for (id, date) in Self.cliStashes(records: records, configs: configs, since: cutoff) {
            result.drafts[.session(id), default: []].append(date)
        }

        let waiting = Set(records.filter { $0.activity == .needsInput }.compactMap(\.sessionID))
        // Look up exact conversation UUIDs. Several CLI profiles can share the
        // same projects directory, while different transcripts claiming one UUID are ambiguous.
        let ids = Set(records.compactMap(\.sessionID)).union(catalog.value.values.compactMap(\.sessionID))
        var reading: ClaudeRead<ClaudeInputReading> = .init(value: result)
        let paths = Self.transcripts(for: ids, configs: configs)
        for (id, file) in paths {
            guard let revision = Self.revision(of: file), revision.modified >= cutoff || waiting.contains(id) else { continue }
            reading.value.transcripts[id] = transcript(file, session: id, revision: revision)
        }
        transcriptCache.withLock { cache in
            let considered = Set(paths.values)
            cache = cache.filter { considered.contains($0.key) }
        }
        if drafts.quality != .complete || catalog.quality != .complete {
            reading.quality = .partial
        }
        return reading
    }

    private func transcript(_ file: URL, session: UUID, revision: Revision) -> ClaudeTranscriptInput {
        if let cached = transcriptCache.withLock({ $0[file] }), cached.revision == revision {
            return cached.input
        }
        let found = ClaudeInputTranscript.read(file, session: session)
        if Self.revision(of: file) == revision {
            transcriptCache.withLock { $0[file] = CachedTranscript(revision: revision, input: found) }
        }
        return found
    }

    private static func desktopCatalog(home: URL, live: [ClaudeSessionRecord], draftHosts: Set<ClaudeDesktopID>, since: Date)
        -> ClaudeRead<[ClaudeConversationID: ClaudeStoredDesktopSession]> {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        let scopes = directories(in: root).flatMap { account -> [DesktopScope] in
            guard let id = UUID(uuidString: account.lastPathComponent) else { return [] }
            return directories(in: account).compactMap { organization in
                guard UUID(uuidString: organization.lastPathComponent) != nil else { return nil }
                return DesktopScope(account: id, directory: organization)
            }
        }
        let liveDesktop = live.filter { $0.entrypoint == "claude-desktop" }
        let allowed = scopes.count <= 1 ? scopes : scopes.filter { scope in
            liveDesktop.contains { record in
                guard let id = record.sessionID, let host = ClaudeDesktopID(record.hostSessionId) else { return false }
                let file = scope.directory.appendingPathComponent(host.value + ".json")
                let metadata = readMetadata(file, host: host)
                return metadata?.cliSessionId == id
            }
        }
        guard !allowed.isEmpty else { return .init(value: [:], quality: scopes.isEmpty ? .complete : .partial) }
        let liveHosts = Set(liveDesktop.compactMap { ClaudeDesktopID($0.hostSessionId) })
        let exactHosts = liveHosts.union(draftHosts)
        var sessions: [ClaudeConversationID: ClaudeStoredDesktopSession] = [:]
        var seen: Set<ClaudeConversationID> = []
        var quality = ClaudeReadQuality.complete
        for scope in allowed {
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(at: scope.directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])
            } catch {
                quality = .partial
                continue
            }
            for file in files where file.pathExtension == "json" {
                guard let host = ClaudeDesktopID(file.deletingPathExtension().lastPathComponent),
                      let stamp = revision(of: file),
                      exactHosts.contains(host) || stamp.modified >= since,
                      let data = readMetadata(file, host: host), data.isArchived != true else { continue }

                let stored = ClaudeStoredDesktopSession(host: host, sessionID: data.cliSessionId, accountID: scope.account,
                                                       title: data.title, path: data.cwd, createdAt: date(milliseconds: data.createdAt),
                                                       turnWasCutShort: data.lastTurnCutShort == true)
                if seen.insert(stored.id).inserted {
                    sessions[stored.id] = stored
                } else {
                    sessions.removeValue(forKey: stored.id)
                    quality = .partial
                }
            }
        }
        return .init(value: sessions, quality: quality)
    }

    private static func readMetadata(_ file: URL, host: ClaudeDesktopID) -> DesktopMetadata? {
        guard let data = readSmallFile(file, limit: 1_048_576)?.data,
              let metadata = try? JSONDecoder().decode(DesktopMetadata.self, from: data),
              metadata.sessionId == host.value else { return nil }
        return metadata
    }

    private static func transcripts(for ids: Set<UUID>, configs: Set<URL>) -> [UUID: URL] {
        guard !ids.isEmpty else { return [:] }
        let roots = Set(configs.map { $0.appendingPathComponent("projects", isDirectory: true).resolvingSymlinksInPath() })
        var files: [UUID: URL] = [:]
        var seen: Set<UUID> = []
        for root in roots {
            for project in directories(in: root) {
                let entries = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil,
                                                                            options: [.skipsHiddenFiles])) ?? []
                for entry in entries where entry.pathExtension == "jsonl" {
                    guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent),
                          ids.contains(id), revision(of: entry) != nil else { continue }
                    if seen.insert(id).inserted {
                        files[id] = entry
                    } else {
                        files.removeValue(forKey: id)
                    }
                }
            }
        }
        return files
    }

    private static func cliStashes(records: [ClaudeSessionRecord], configs: Set<URL>, since: Date) -> [UUID: Date] {
        // Claude persists Ctrl+S stashes to a separate .prompt-stash file in
        // the detached job directory. A submitted reply uses a different file.
        var paths: [UUID: Set<URL>] = [:]
        let roots = Set(configs.map { $0.appendingPathComponent("jobs", isDirectory: true).resolvingSymlinksInPath() })
        for record in records where record.isDetached && record.entrypoint != "claude-desktop" {
            guard let id = record.sessionID, let attach = record.attachID else { continue }
            for root in roots where isDirectory(root) {
                let job = root.appendingPathComponent(attach.value, isDirectory: true)
                guard isDirectory(job),
                      let data = readSmallFile(job.appendingPathComponent("state.json"), limit: 262_144)?.data,
                      let state = try? JSONDecoder().decode(CLIJob.self, from: data),
                      state.sessionId == id || state.resumeSessionId == id else { continue }
                paths[id, default: []].insert(job.appendingPathComponent(".prompt-stash"))
            }
        }
        return paths.compactMapValues { files in
            guard files.count == 1, let file = files.first, let stamp = revision(of: file), stamp.modified >= since,
                  let stored = readSmallFile(file, limit: 262_144), stored.revision == stamp,
                  let draft = try? JSONDecoder().decode(Stash.self, from: stored.data),
                  !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return stored.revision.modified
        }
    }

    private static func directories(in directory: URL) -> [URL] {
        guard isDirectory(directory) else { return [] }
        let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])
        return entries?.filter(isDirectory) ?? []
    }

    private static func isDirectory(_ path: URL) -> Bool {
        var info = stat()
        return lstat(path.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func revision(of path: URL) -> Revision? {
        var info = stat()
        guard lstat(path.path, &info) == 0 else { return nil }
        return revision(info)
    }

    private static func revision(_ info: stat) -> Revision? {
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { return nil }
        let timestamp = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return Revision(device: info.st_dev, inode: info.st_ino, modified: Date(timeIntervalSince1970: timestamp), size: info.st_size)
    }

    private static func readSmallFile(_ file: URL, limit: Int) -> (data: Data, revision: Revision)? {
        let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, let snapshot = revision(info), snapshot.size <= limit,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1),
              data.count <= limit, fstat(fd, &info) == 0, revision(info) == snapshot else { return nil }
        return (data, snapshot)
    }

    static func date(milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}
