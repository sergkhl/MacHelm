import Darwin
import Foundation
#if SWIFT_PACKAGE
import ActivityCore
#endif

struct ClaudeInstallation: Sendable {
    let command: ClaudeCLICommand
    let executable: URL?
    let configDirectory: URL
    let configOverride: String?
    let outputRoots: Set<String>
    let environment: [String: String]
    let home: URL

    init(command: ClaudeCLICommand = .standard, environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.command = command
        self.home = home
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".claude/local").path,
            home.appendingPathComponent(".npm-global/bin").path, "/opt/homebrew/bin", "/usr/local/bin"
        ]
        executable = paths.lazy.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        configOverride = environment["CLAUDE_CONFIG_DIR"].flatMap {
            $0.isEmpty ? nil : Self.directory($0, relativeTo: home, home: home).standardizedFileURL.path
        }
        configDirectory = configOverride.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".claude", isDirectory: true)
        let tempPaths = ["/private/tmp", "/tmp"] + [environment["CLAUDE_CODE_TMPDIR"]].compactMap { $0 }
        outputRoots = Set(tempPaths.flatMap { Self.taskOutputRoots(in: Self.directory($0, relativeTo: home, home: home)) })
        var environment = environment
        environment["CLAUDE_CONFIG_DIR"] = configOverride
        self.environment = environment
    }

    static func directory(_ value: String, relativeTo base: URL, home: URL) -> URL {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2)), isDirectory: true) }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: true) : base.appendingPathComponent(value, isDirectory: true)
    }

    static func taskOutputRoots(in directory: URL) -> [String] {
        let root = directory.appendingPathComponent("claude-\(getuid())")
        // Kernel vnode paths use /private/tmp, while Foundation may resolve it to /tmp.
        return [root.path, root.resolvingSymlinksInPath().path]
    }
}

struct ClaudeDiscovery: Sendable {
    private let transport = DarwinProcessTransport()
    private let inputReader = ClaudeInputDiscovery()

    func read(pass: ProcessPass, installation: ClaudeInstallation) -> ClaudeDiscoveryFrame {
        var inventory = readInventory(installation, includeCompleted: true)
        if inventory.quality == .unavailable {
            inventory = readInventory(installation)
            if inventory.quality == .complete { inventory.quality = .partial }
        }
        let sampled = pass.own.map(\.description).filter { $0.isOwn && $0.identity.startedAt > 0 }
        let selectedCLIOnly = installation.command.usesZsh
        let locations = selectedCLIOnly ? profileLocations(for: inventory.value, sampled: sampled, installation: installation) : [:]
        let outputRoots = installation.outputRoots.union(locations.values.flatMap(\.outputRoots))
        let processes = readProcesses(sampled, outputRoots: outputRoots)
        let desktopDirectory = installation.home.appendingPathComponent(".claude", isDirectory: true)
        let configs = Set([installation.configDirectory, desktopDirectory]).union(locations.values.compactMap(\.config))
        let registrationsByConfig = configs.map { config in
            let read = readRegistrations(in: config, sampled: sampled, processes: processes.value)
            let cliInventory = selectedCLIOnly ? inventory.value : nil
            let desktopOnly = !selectedCLIOnly && config != installation.configDirectory
            let registrations = Self.registrationsInScope(read.value, cliInventory: cliInventory, desktopOnly: desktopOnly)
            return (config: config, quality: read.quality, registrations: registrations)
        }
        let registrationQuality: ClaudeReadQuality
        if registrationsByConfig.allSatisfy({ $0.quality == .unavailable }) {
            registrationQuality = .unavailable
        } else {
            registrationQuality = registrationsByConfig.contains { $0.quality != .complete } ? .partial : .complete
        }

        let outputs = Set(processes.value.flatMap(\.outputs))
        let registrations = registrationsByConfig.flatMap(\.registrations)
        let launches = readShellLaunches(from: processes.value, registrations: registrations)
        let registeredElsewhere = Set(registrationsByConfig.filter { $0.config != installation.configDirectory }
            .flatMap(\.registrations).compactMap(\.record.sessionID))
        var taskRecords = ClaudeRead<[ClaudeTaskOutput: ClaudeTaskRecord]>(value: [:])
        for source in registrationsByConfig {
            var sessions = Set(source.registrations.compactMap(\.record.sessionID))
            let broadRead = !selectedCLIOnly && source.config == installation.configDirectory
            let listedHere = inventory.value.filter { agent in
                if broadRead { return agent.sessionID.map { !registeredElsewhere.contains($0) } ?? false }
                return agent.pid.flatMap { locations[$0]?.config } == source.config
            }
            sessions.formUnion(listedHere.compactMap(\.sessionID))
            let matchingOutputs = outputs.filter { output in
                broadRead ? !registeredElsewhere.contains(output.sessionID) : sessions.contains(output.sessionID)
            }
            let read = ClaudeTaskRecords.read(matchingOutputs, in: source.config, sessions: sessions, launches: launches)
            taskRecords.value.merge(read.value, uniquingKeysWith: ClaudeTaskRecords.merge)
            if read.quality != .complete { taskRecords.quality = .partial }
        }

        let registered = registrations.map(\.record)
        let records = inventory.value + registered
        let input = inputReader.read(home: installation.home, records: records, configs: configs, at: Date())
        let waiting = Set(records.filter { $0.activity == .needsInput }.compactMap(\.sessionID))
        let replyIDs = Set(input.value.transcripts.compactMap { $0.value.replies.isEmpty ? nil : $0.key })
        let draftIDs = Set(input.value.drafts.keys.compactMap { id -> UUID? in
            if case .session(let uuid) = id { return uuid }
            return nil
        })
        let desktop = registered.filter { $0.entrypoint == "claude-desktop" }
        let desktopIDs = Set(desktop.compactMap(\.sessionID)).union(input.value.desktop.values.compactMap(\.sessionID))
        let desktopWaiting = desktop.filter { record in
            guard let id = record.sessionID else { return false }
            return waiting.contains(id) && input.value.desktop[.session(id)] == nil
        }
        let cliInputIDs = waiting.union(replyIDs).union(draftIDs).subtracting(desktopIDs)
        var dates = ClaudeSessionDates.cliDates(for: cliInputIDs, configs: configs)
        dates.merge(ClaudeSessionDates.desktopDates(for: desktopWaiting, home: installation.home)) { _, desktopDate in
            desktopDate
        }
        return ClaudeDiscoveryFrame(inventory: inventory, registrations: .init(value: registrations, quality: registrationQuality),
                                    processes: processes, taskRecords: taskRecords, creationDates: dates,
                                    restrictToKnownConversations: selectedCLIOnly, input: input)
    }

    private func readShellLaunches(from processes: [ClaudeObservedProcess], registrations: [ClaudeRegistration])
        -> [ClaudeTaskOutput: ClaudeShellLaunch] {
        let desktop = Dictionary(grouping: registrations.filter { $0.record.entrypoint == "claude-desktop" },
                                 by: \.worker.pid)
        let identities = Dictionary(uniqueKeysWithValues: processes.map { ($0.identity.pid, $0.identity) })
        var launches: [ClaudeTaskOutput: ClaudeShellLaunch] = [:]
        var ambiguous: Set<ClaudeTaskOutput> = []
        for process in processes {
            // Read the launching shell only. Descendants may inherit the same
            // descriptors, but their arguments do not identify the tool call.
            guard process.outputs.count == 1, let output = process.outputs.first, output.isLocalShell,
                  process.sessionMarker == nil || process.sessionMarker == output.sessionID,
                  let roots = desktop[process.parent], roots.count == 1, let root = roots.first,
                  root.record.sessionID == output.sessionID, identities[process.parent] == root.worker,
                  root.worker.startedAt < process.identity.startedAt,
                  let arguments = transport.arguments(of: process.identity.pid),
                  liveInfo(process.identity) != nil,
                  let launch = ClaudeShellLaunch(arguments: arguments, startedAt: process.startedAt) else { continue }
            if launches.updateValue(launch, forKey: output) != nil { ambiguous.insert(output) }
        }
        return launches.filter { !ambiguous.contains($0.key) }
    }

    func readInventory(_ installation: ClaudeInstallation, includeCompleted: Bool = false) -> ClaudeRead<[ClaudeSessionRecord]> {
        guard installation.canLaunch else { return .init(value: [], quality: .missingExecutable) }
        guard let data = installation.inventoryOutput(includeCompleted: includeCompleted) else {
            return .init(value: [], quality: .unavailable)
        }
        return Self.decodeInventory(data)
    }

    private struct ProfileLocation {
        let config: URL?
        let outputRoots: [String]
    }

    // The inventory identifies the CLI's sessions. Inspect its live workers for
    // the corresponding metadata directories, including those set inside a shell function.
    private func profileLocations(for inventory: [ClaudeSessionRecord], sampled: [ProcessDescription],
                                  installation: ClaudeInstallation) -> [Int32: ProfileLocation] {
        let identities = Dictionary(sampled.map { ($0.identity.pid, $0.identity) }, uniquingKeysWith: { first, _ in first })
        var locations: [Int32: ProfileLocation] = [:]
        for agent in inventory {
            guard let pid = agent.pid, locations[pid] == nil, let identity = identities[pid],
                  let info = liveInfo(identity), let started = agent.startedAt,
                  started / 1_000 + 0.001 >= Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000 else { continue }
            let home = installation.home
            let base = agent.cwd.map { ClaudeInstallation.directory($0, relativeTo: home, home: home) } ?? home
            let config = transport.environmentValue("CLAUDE_CONFIG_DIR", of: pid)
                .flatMap { $0.isEmpty ? nil : ClaudeInstallation.directory($0, relativeTo: base, home: home) }
            let temp = transport.environmentValue("CLAUDE_CODE_TMPDIR", of: pid)
                .flatMap { $0.isEmpty ? nil : ClaudeInstallation.directory($0, relativeTo: base, home: home) }
            guard liveInfo(identity) != nil else { continue }
            locations[pid] = ProfileLocation(config: config?.standardizedFileURL, outputRoots: temp.map(ClaudeInstallation.taskOutputRoots(in:)) ?? [])
        }
        return locations
    }

    static func registrationsInScope(_ registrations: [ClaudeRegistration], cliInventory: [ClaudeSessionRecord]?,
                                     desktopOnly: Bool) -> [ClaudeRegistration] {
        let inventoryByPID = Dictionary(grouping: cliInventory ?? []) { $0.pid }
        return registrations.filter { registration in
            if registration.record.entrypoint == "claude-desktop" { return true }
            if desktopOnly { return false }
            if cliInventory == nil { return true }
            return inventoryByPID[registration.worker.pid, default: []].contains { agent in
                if let session = agent.sessionID { return registration.record.sessionID == session }
                return agent.attachID.map { registration.record.attachID == $0 } ?? false
            }
        }
    }

    static func decodeInventory(_ data: Data) -> ClaudeRead<[ClaudeSessionRecord]> {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return .init(value: [], quality: .unavailable)
        }
        let decoder = JSONDecoder()
        let sessions = list.compactMap { item -> ClaudeSessionRecord? in
            guard JSONSerialization.isValidJSONObject(item), let encoded = try? JSONSerialization.data(withJSONObject: item),
                  let session = try? decoder.decode(ClaudeSessionRecord.self, from: encoded),
                  session.sessionID != nil || session.attachID != nil else { return nil }
            return session
        }
        return .init(value: sessions, quality: sessions.count == list.count ? .complete : .partial)
    }

    private func readRegistrations(in config: URL, sampled: [ProcessDescription], processes: [ClaudeObservedProcess])
        -> ClaudeRead<[ClaudeRegistration]> {
        let folder = config.appendingPathComponent("sessions", isDirectory: true)
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                                options: .skipsHiddenFiles)
        } catch {
            return .init(value: [], quality: Self.missing(error) ? .complete : .unavailable)
        }

        let table = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = Dictionary(sampled.map { ($0.identity.pid, $0.executablePath) }, uniquingKeysWith: { first, _ in first })
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var result = ClaudeRead<[ClaudeRegistration]>(value: [])
        for file in files where file.pathExtension == "json" {
            guard let pid = Int32(file.deletingPathExtension().lastPathComponent), let process = table[pid] else { continue }
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 256 * 1_024 else {
                    result.quality = .partial
                    continue
                }
                let record = try decoder.decode(ClaudeSessionRecord.self, from: Data(contentsOf: file))
                guard record.pid == pid, record.sessionID != nil || record.attachID != nil,
                      record.pidDomain == nil || record.pidDomain == "darwin",
                      let processStart = record.procStart, let started = record.startedAt,
                      started / 1_000 + 0.001 >= process.startedAt else { continue }
                let actualStart = Date(timeIntervalSince1970: process.startedAt.rounded(.down))
                let written = processStart.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let matches = [TimeZone.gmt, TimeZone.current].contains { zone in
                    formatter.timeZone = zone
                    return formatter.string(from: actualStart) == written
                }
                guard matches, let info = liveInfo(process.identity) else { continue }
                let terminal = record.entrypoint == "claude-desktop" || record.isDetached ? nil : terminal(of: info, process: process, paths: paths, table: table)
                result.value.append(ClaudeRegistration(record: record, worker: process.identity, terminal: terminal))
            } catch {
                if !Self.missing(error) { result.quality = .partial }
            }
        }
        return result
    }

    static func missing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    private func readProcesses(_ sampled: [ProcessDescription], outputRoots: Set<String>) -> ClaudeRead<[ClaudeObservedProcess]> {
        guard !sampled.isEmpty else { return .init(value: [], quality: .unavailable) }
        var observed: [Int32: ClaudeObservedProcess] = [:]
        var unreadable: Set<Int32> = []
        for process in sampled {
            guard let info = liveInfo(process.identity) else { continue }
            let pid = process.identity.pid
            let output = outputs(of: pid, roots: outputRoots)
            if output.quality == .partial { unreadable.insert(pid) }
            observed[pid] = ClaudeObservedProcess(identity: process.identity, parent: Int32(bitPattern: info.pbi_ppid), name: process.name,
                                                 startedAt: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000,
                                                 outputs: output.value)
        }
        var relevantFailure = false
        let processes = observed.values.compactMap { entry -> ClaudeObservedProcess? in
            var process = entry
            var ancestor = entry
            while ancestor.outputs.isEmpty, let parent = observed[ancestor.parent],
                  parent.identity.startedAt < ancestor.identity.startedAt { ancestor = parent }
            if process.parent <= 1 || !ancestor.outputs.isEmpty {
                process.sessionMarker = transport.environmentValue("CLAUDE_CODE_SESSION_ID", of: process.identity.pid)
                    .flatMap(UUID.init(uuidString:))
            }
            guard liveInfo(process.identity) != nil else { return nil }
            if unreadable.contains(process.identity.pid), process.sessionMarker != nil { relevantFailure = true }
            return process
        }
        return .init(value: processes, quality: relevantFailure ? .partial : .complete)
    }

    private func liveInfo(_ expected: ProcessIdentity) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == transport.userID, info.pbi_status != SZOMB,
              transport.startTime(of: expected.pid) == expected.startedAt else { return nil }
        return info
    }

    private func outputs(of pid: Int32, roots: Set<String>) -> ClaudeRead<Set<ClaudeTaskOutput>> {
        var result = ClaudeRead<Set<ClaudeTaskOutput>>(value: [])
        for fd in [STDOUT_FILENO, STDERR_FILENO] {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                if errno == EPERM || errno == EACCES { result.quality = .partial }
                continue
            }
            // libproc reports XNU's file flags. FREAD also has a bit set,
            // so testing against open(2)'s O_RDONLY accepts read-only FDs.
            guard info.pvip.vip_vi.vi_stat.vst_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                  info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if let output = ClaudeTaskOutput(path: path, roots: roots) { result.value.insert(output) }
        }
        return result
    }

    private func terminal(of info: proc_bsdinfo, process: ClaudeObservedProcess, paths: [Int32: String],
                          table: [Int32: ClaudeObservedProcess]) -> ClaudeTerminal? {
        guard let tty = ttyPath(info) else { return nil }
        let responsible = transport.responsibleProcess(of: process.identity.pid).flatMap { terminalBundle(for: transport.executablePath(of: $0)) }
        var child = process
        while let parent = table[child.parent], parent.identity.startedAt < child.identity.startedAt {
            if let app = terminalBundle(for: paths[parent.identity.pid]) {
                return ClaudeTerminal(name: app.name, bundleID: app.id, tty: tty)
            }
            child = parent
        }
        if let responsible, ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2"].contains(responsible.id) {
            return ClaudeTerminal(name: responsible.name, bundleID: responsible.id, tty: tty)
        }
        return ClaudeTerminal(name: "Terminal session", bundleID: nil, tty: tty)
    }

    func stillHasTTY(_ tty: String, worker: ProcessIdentity) -> Bool {
        liveInfo(worker).flatMap(ttyPath) == tty
    }

    private func ttyPath(_ info: proc_bsdinfo) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        guard devname_r(Int32(bitPattern: info.e_tdev), S_IFCHR, &name, Int32(name.count)) != nil else { return nil }
        let tty = "/dev/" + String(cString: name)
        return tty.hasPrefix("/dev/tty") ? tty : nil
    }

    private func terminalBundle(for path: String?) -> (id: String, name: String)? {
        guard let path, let range = path.range(of: ".app/Contents/"),
              let app = Bundle(url: URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")),
              let id = app.bundleIdentifier else { return nil }
        let name = app.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? app.bundleURL.deletingPathExtension().lastPathComponent
        return (id, name)
    }
}

// Only the caller's disposable subprocess is ended on timeout. The read must
// finish even when an inherited pipe stays open or the command closes stdout.
enum ClaudeCommand {
    static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                    directory: URL? = nil, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let handle = pipe.fileHandleForReading
        defer { try? handle.close() }

        let fd = handle.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { return nil }
        let deadline = DispatchTime.now() + timeout
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }

        var buffer = [UInt8](repeating: 0, count: 16_384)
        var output = Data()
        var eof = false
        while DispatchTime.now() < deadline {
            if eof {
                if !process.isRunning { return process.terminationStatus == 0 ? output : nil }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= 2 * 1_024 * 1_024 else { return nil }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                eof = true
            } else if errno == EAGAIN || errno == EINTR {
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&event, 1, 20)
            } else {
                return nil
            }
        }
        return nil
    }
}
