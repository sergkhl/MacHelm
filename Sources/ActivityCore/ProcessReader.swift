import Foundation

// Reads the processes through a transport and turns what it finds into a
// pass. Kept by one queue: it remembers what it has described, who started
// what, and the GPU time it has counted.
public final class ProcessReader: @unchecked Sendable {
    private let transport: ProcessTransport
    private let systemInterval: TimeInterval
    private let secondSystemRead: TimeInterval

    // What is known of a process for naming it as a starter. It is kept after
    // the process has ended for as long as something it started still runs.
    private struct Node {
        var pid: Int32
        // nil for a system process, whose start cannot be read.
        var identity: ProcessIdentity?
        // How it reads in a chain: an app by its name, an interpreter by its script.
        var label: String
        var bundle: String?
        // A shell or a package runner, which a chain leaves out.
        var skipped: Bool
        // The first parent seen; nil when that was launchd.
        var starter: Int?
        // The process macOS holds responsible, when it names another one.
        var responsible: Int?
        var ended = false
    }

    // What was read of an own process once, with the kernel's short name it was read under.
    private struct Known {
        var shortName: String
        var path: String
        var name: String
        var wine: WineRole?
        var kind: String?
        var startedUptime: TimeInterval
        var node: Int
        // It had launchd as its parent when it was first seen.
        var launchdStarted: Bool
        var description: ProcessDescription
    }

    private struct Entry {
        var pid: Int32
        var usage: ProcessUsage
        var info: ProcessShortInfo
        var identity: ProcessIdentity
        var path: String
    }

    private var known: [ProcessIdentity: Known] = [:]
    private var nodes: [Int: Node] = [:]
    // The node of each process that runs, by its identifier.
    private var running: [Int32: Int] = [:]
    private var nextNode = 0
    private var systemReadAt: TimeInterval?
    private var systemReads = 0
    private var gpu = GPUAccount()

    // ADR 0002: system processes every 5 seconds, everything else on every
    // read. Their second read comes after 2 seconds, so that they have a
    // figure when the lists first appear.
    public init(transport: ProcessTransport, systemInterval: TimeInterval = 5, secondSystemRead: TimeInterval = 2) {
        self.transport = transport
        self.systemInterval = systemInterval
        self.secondSystemRead = secondSystemRead
    }

    public func read(at uptime: TimeInterval) -> ProcessPass {
        let timebase = transport.timebase
        let unit = Double(timebase.numerator) / Double(max(timebase.denominator, 1))
        let pids = transport.processIDs().filter { $0 > 0 }
        let alive = Set(pids)
        var entries: [Entry] = []
        for pid in pids {
            guard let usage = transport.usage(of: pid), let info = transport.shortInfo(of: pid) else { continue }
            entries.append(Entry(pid: pid, usage: usage, info: info, identity: ProcessIdentity(pid: pid, startedAt: usage.startedAt),
                                 path: transport.executablePath(of: pid) ?? ""))
        }
        let identities = Set(entries.map(\.identity))
        let readable = Set(entries.map(\.pid))

        // A process that ended, or whose identifier now names another process, runs no more.
        for (pid, id) in running {
            guard let node = nodes[id] else { continue }
            if node.identity.map({ !identities.contains($0) }) ?? !alive.contains(pid) {
                nodes[id]?.ended = true
                running[pid] = nil
            }
        }

        // A process that runs another program keeps its identifier and its
        // start time. So what was read of it stands only while the name and
        // the path do. A program with two names on disk is reported under
        // whichever was looked up last; that is still the same program.
        var fresh: [(node: Int, pid: Int32, parent: Int32)] = []
        for entry in entries {
            let before = known[entry.identity]
            if let before, before.shortName == entry.info.name,
               before.path == entry.path || transport.sameFile(before.path, entry.path) { continue }
            let facts = Self.facts(path: entry.path, shortName: entry.info.name) { self.transport.arguments(of: entry.pid) ?? [] }
            // Another program under the same identity keeps its node, and with it its starter.
            let id = before?.node ?? newNode()
            var node = nodes[id] ?? Node(pid: entry.pid, identity: entry.identity, label: facts.label, bundle: facts.bundle, skipped: facts.skipped)
            node.label = facts.label
            node.bundle = facts.bundle
            node.skipped = facts.skipped
            nodes[id] = node
            running[entry.pid] = id
            if before == nil { fresh.append((id, entry.pid, entry.info.parent)) }
            let name = (entry.path as NSString).lastPathComponent
            let description = ProcessDescription(identity: entry.identity, parent: entry.info.parent, isOwn: entry.info.userID == transport.userID,
                                                 name: name.isEmpty ? entry.info.name : name, executablePath: entry.path)
            known[entry.identity] = Known(shortName: entry.info.name, path: entry.path, name: description.name, wine: facts.wine, kind: facts.kind,
                                          startedUptime: Double(entry.identity.startedAt) * unit / 1e9, node: id,
                                          launchdStarted: before?.launchdStarted ?? (entry.info.parent <= 1), description: description)
        }
        // Who started the new ones, now that every own process that runs has its node.
        for (id, pid, parent) in fresh {
            // Looked up first: finding a node may add one, and the table cannot be written twice at once.
            let starter = parent > 1 ? node(of: parent) : nil
            var responsible: Int?
            if let named = transport.responsibleProcess(of: pid), named > 1, named != pid { responsible = node(of: named) }
            nodes[id]?.starter = starter
            nodes[id]?.responsible = responsible
        }

        var chains: [Int: [String]] = [:]
        var own: [ProcessSample] = []
        own.reserveCapacity(entries.count)
        for entry in entries {
            guard var process = known[entry.identity] else { continue }
            let description = describe(entry, process, chains: &chains)
            // An unchanged description keeps the one already held.
            if description != process.description {
                process.description = description
                known[entry.identity] = process
            }
            own.append(ProcessSample(description: process.description,
                                     cpuSeconds: Double(entry.usage.cpuTime) * unit / 1e9,
                                     energyJoules: Double(entry.usage.energyNanojoules) / 1e9,
                                     memoryBytes: entry.usage.footprintBytes,
                                     diskBytes: Double(entry.usage.diskBytes)))
        }
        known = known.filter { identities.contains($0.key) }

        var system: [ProcessSample]?
        // The window's tolerance, so a timer that fires a little early still
        // reads and the window accepts what was read.
        let interval = systemReads == 1 ? secondSystemRead : systemInterval
        if systemReadAt.map({ uptime - $0 >= interval - ActivityWindow.tolerance }) ?? true, let listing = transport.systemListing() {
            systemReadAt = uptime
            systemReads += 1
            // A system process shows its parent only.
            system = Self.systemSamples(in: listing, readable: readable).map { sample in
                var sample = sample
                if sample.description.parent > 1, let parent = node(of: sample.description.parent).flatMap({ nodes[$0] }) {
                    sample.description.starter = ProcessStarter(pid: parent.pid, name: parent.label)
                }
                return sample
            }
        }
        forgetUnusedNodes()

        // A read that failed keeps the counts: without them a later window would start from zero.
        let gpuSeconds = transport.gpuClients().map { gpu.count($0, alive: alive) } ?? gpu.kept(alive: alive)
        return ProcessPass(uptime: uptime, own: own, system: system, gpuSeconds: gpuSeconds)
    }

    private func newNode() -> Int {
        nextNode += 1
        return nextNode
    }

    // The node of a process that runs. One that is not the owner's is made
    // when it is first asked for, with the processes above it.
    private func node(of pid: Int32, depth: Int = 0) -> Int? {
        if let id = running[pid] { return id }
        guard pid > 1, depth < 16, let info = transport.shortInfo(of: pid) else { return nil }
        let facts = Self.facts(path: transport.executablePath(of: pid) ?? "", shortName: info.name) { [] }
        let id = newNode()
        nodes[id] = Node(pid: pid, identity: nil, label: facts.label, bundle: facts.bundle, skipped: facts.skipped)
        running[pid] = id
        let starter = info.parent > 1 ? node(of: info.parent, depth: depth + 1) : nil
        nodes[id]?.starter = starter
        return id
    }

    // An ended process is remembered only while something that runs was started by it.
    private func forgetUnusedNodes() {
        guard nodes.count > running.count else { return }
        var used = Set(running.values)
        var open = Array(used)
        while let id = open.popLast() {
            guard let node = nodes[id] else { continue }
            for next in [node.starter, node.responsible].compactMap({ $0 }) where used.insert(next).inserted { open.append(next) }
        }
        nodes = nodes.filter { used.contains($0.key) }
    }

    private func describe(_ entry: Entry, _ process: Known, chains: inout [Int: [String]]) -> ProcessDescription {
        var description = ProcessDescription(identity: entry.identity, parent: entry.info.parent, isOwn: entry.info.userID == transport.userID,
                                             name: process.name, executablePath: process.path, wine: process.wine,
                                             startedUptime: process.startedUptime, kind: process.kind)
        guard let node = nodes[process.node] else { return description }
        // A starter inside the process's own app tells nothing the row does not.
        if let starter = node.starter.flatMap({ nodes[$0] }), starter.bundle == nil || starter.bundle != node.bundle {
            description.starter = ProcessStarter(pid: starter.pid, name: starter.label, ended: starter.ended)
        }
        if let responsible = node.responsible.flatMap({ nodes[$0] }), !responsible.ended,
           responsible.bundle == nil || responsible.bundle != node.bundle, responsible.label != description.starter?.name {
            description.responsibleApp = responsible.label
        }
        description.chain = chain(of: process.node, chains: &chains)
        if node.bundle != nil {
            description.origin = chain(of: top(ofCopyWith: process.node), chains: &chains)
        } else if process.launchdStarted, Self.isHelper(process.path), let id = node.responsible, let app = nodes[id], let bundle = app.bundle {
            // Q3: a helper that launchd started counts toward its responsible app, and toward that copy of it.
            description.adoptedBy = bundle
            description.origin = chain(of: top(ofCopyWith: id), chains: &chains)
        }
        return description
    }

    // The starters of a process by name, nearest first. Where they end, the
    // responsible process says where the last of them came from.
    private func chain(of id: Int, chains: inout [Int: [String]]) -> [String] {
        if let chain = chains[id] { return chain }
        guard let first = nodes[id] else { return [] }
        var labels: [String] = []
        var previous = first.label
        var current = first
        var steps = 0
        while let next = current.starter.flatMap({ nodes[$0] }), steps < 32 {
            if !next.skipped, next.label != previous {
                labels.append(next.label)
                previous = next.label
            }
            current = next
            steps += 1
        }
        if let responsible = current.responsible.flatMap({ nodes[$0] }), !responsible.skipped, responsible.label != previous {
            labels.append(responsible.label)
        }
        chains[id] = labels
        return labels
    }

    // The process at the top of a copy of an app: the one that something
    // outside the app started. A helper that left its parent is found
    // through the process macOS holds responsible for it.
    private func top(ofCopyWith id: Int) -> Int {
        guard let bundle = nodes[id]?.bundle else { return id }
        var top = id
        var steps = 0
        while steps < 32, let node = nodes[top] {
            if let starter = node.starter, nodes[starter]?.bundle == bundle {
                top = starter
            } else if node.starter == nil, let responsible = node.responsible, responsible != top, nodes[responsible]?.bundle == bundle {
                top = responsible
            } else {
                break
            }
            steps += 1
        }
        return top
    }

    // MARK: Starters

    private struct Facts {
        var label: String
        var bundle: String?
        var skipped: Bool
        var wine: WineRole?
        var kind: String?
    }

    // What a program's path and arguments say about it. The arguments are
    // read only where they tell something: for Wine, for an interpreter and
    // inside an app.
    private static func facts(path: String, shortName: String, arguments: () -> [String]) -> Facts {
        let file = path.isEmpty ? shortName : (path as NSString).lastPathComponent
        let bundle = ProcessGrouping.bundlePath(in: path)
        let wine = isWine(path)
        let interpreter = isInterpreter(file)
        let read = wine || interpreter || bundle != nil ? arguments() : []
        var facts = Facts(label: file, bundle: bundle, skipped: shells.contains(file) || runners.contains(file),
                          wine: wine ? wineRole(arguments: read) : nil, kind: kind(file: file, bundle: bundle, arguments: read))
        if let bundle {
            facts.label = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            facts.skipped = false
        } else if interpreter, let script = scriptName(arguments: read) {
            facts.label = script
            facts.skipped = runners.contains(script)
        }
        return facts
    }

    // Left out of a chain: they pass a command on and tell nothing about who wanted it.
    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "login", "sudo", "env", "nohup",
                                              "caffeinate", "script", "xargs", "timeout", "arch", "nice"]
    private static let runners: Set<String> = ["npm", "npx", "pnpm", "yarn", "corepack", "bunx", "uv", "uvx", "pipx"]
    private static let scriptFlagsWithAValue: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader", "-W", "-X"]
    private static let scriptsNamedForTheirFolder: Set<String> = ["index", "main", "cli", "server", "app", "run", "start", "__main__", "bin"]

    static func isInterpreter(_ file: String) -> Bool {
        ["node", "bun", "deno", "ruby", "perl", "Python"].contains(file) || file.hasPrefix("python")
    }

    // What an interpreter runs, as its arguments name it: a package by its
    // name, a module, or the script's file. nil for code given on the command line.
    static func scriptName(arguments: [String]) -> String? {
        var rest = arguments.dropFirst()
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "-m" { return rest.first }
            if ["-e", "-c", "-p", "--eval", "--print"].contains(argument) { return nil }
            if scriptFlagsWithAValue.contains(argument) {
                rest = rest.dropFirst()
                continue
            }
            if argument.hasPrefix("-") { continue }
            let parts = argument.split(separator: "/").map(String.init)
            if let modules = parts.lastIndex(of: "node_modules"), modules + 1 < parts.count {
                let package = parts[modules + 1]
                if package == ".bin", modules + 2 < parts.count { return parts[modules + 2] }
                return package.hasPrefix("@") && modules + 2 < parts.count ? package + "/" + parts[modules + 2] : package
            }
            guard let file = parts.last else { return nil }
            let stem = (file as NSString).deletingPathExtension
            // A script called index or server is told apart by its folder.
            if scriptsNamedForTheirFolder.contains(stem.lowercased()), parts.count >= 2 { return parts[parts.count - 2] + "/" + file }
            return stem
        }
        return nil
    }

    // A program launchd starts for an app, not one a shell left behind: an
    // XPC service, or a program of the system.
    static func isHelper(_ path: String) -> Bool {
        path.contains(".xpc/") || path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
    }

    // MARK: Process kinds

    private static let browsers = ["Chrome", "Chromium", "Brave", "Edge", "Vivaldi", "Opera", "Arc"]

    // What a helper of a browser, or of an app built like one, does. Which
    // page a tab shows is not known outside the browser.
    static func kind(file: String, bundle: String?, arguments: [String]) -> String? {
        if file.hasPrefix("com.apple.WebKit.WebContent") { return "tab" }
        if file.hasPrefix("com.apple.WebKit.Networking") { return "network" }
        if file.hasPrefix("com.apple.WebKit.GPU") { return "GPU" }
        guard let bundle else { return nil }
        if file.contains("crashpad_handler") { return "crash reporter" }
        guard let type = arguments.first(where: { $0.hasPrefix("--type=") })?.dropFirst(7) else { return nil }
        switch type {
        case "renderer":
            if arguments.contains("--extension-process") { return "extension" }
            let app = (bundle as NSString).lastPathComponent
            return browsers.contains(where: app.contains) ? "tab" : "window"
        case "gpu-process":
            return "GPU"
        default:
            let service = arguments.first(where: { $0.hasPrefix("--utility-sub-type=") }) ?? ""
            if service.contains("NetworkService") { return "network" }
            if service.contains("AudioService") { return "audio" }
            if service.contains("StorageService") { return "storage" }
            if service.contains("VideoCapture") { return "video capture" }
            return "utility"
        }
    }

    // MARK: Wine

    // CrossOver's loader and server, and Wine builds named the usual way.
    static func isWine(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if path.contains("/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/") { return true }
        return (path as NSString).lastPathComponent.lowercased().hasPrefix("wine")
    }

    // The first argument that names an .exe is the Windows program. Wine's own
    // programs run from C:\windows, or by their path among its built-in ones
    // (lib/wine/x86_64-windows); with the server they are its background.
    static func wineRole(arguments: [String]) -> WineRole {
        guard let program = arguments.first(where: { $0.lowercased().hasSuffix(".exe") }) else { return .background }
        let parts = program.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard let name = parts.last else { return .background }
        let folders = parts.dropLast().map { $0.lowercased() }
        let builtIn = folders.suffix(2).first == "wine" && folders.last?.hasSuffix("-windows") == true
        if folders.contains("windows") || builtIn || parts.count == 1 && Self.wineOwnPrograms.contains(name.lowercased()) { return .background }
        return .program(name)
    }

    // Started by name alone, without a path.
    private static let wineOwnPrograms: Set<String> = [
        "wineboot.exe", "winedevice.exe", "services.exe", "plugplay.exe", "explorer.exe", "rpcss.exe",
        "svchost.exe", "conhost.exe", "winemenubuilder.exe", "start.exe", "tabtip.exe"
    ]

    // MARK: System processes

    static func systemSamples(in listing: String, readable: Set<Int32>) -> [ProcessSample] {
        var samples: [ProcessSample] = []
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int32(fields[0]), UInt32(fields[1]) != nil, let parent = Int32(fields[2]),
                  let cpu = cpuSeconds(fields[3]), pid > 0, !readable.contains(pid) else { continue }
            let path = fields[4].trimmingCharacters(in: .whitespaces)
            let fileName = (path as NSString).lastPathComponent
            samples.append(ProcessSample(
                description: ProcessDescription(identity: ProcessIdentity(pid: pid, startedAt: 0), parent: parent, isOwn: false,
                                                name: fileName.isEmpty ? path : fileName, executablePath: path),
                cpuSeconds: cpu))
        }
        return samples
    }

    // `ps` writes minutes:seconds.hundredths, with hours and days in front when they are needed.
    static func cpuSeconds(_ text: Substring) -> Double? {
        var rest = text
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let value = Double(rest[..<dash]) else { return nil }
            days = value
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }
}

// GPU time by process, counted from the first read. A client that appears
// later was opened since the read before, so all of its time is new; a client
// that goes takes its time with it without the process's count going back.
struct GPUAccount {
    private var lastByClient: [UInt64: UInt64] = [:]
    private var secondsByPID: [Int32: Double] = [:]
    private var started = false

    mutating func count(_ clients: [GPUClient], alive: Set<Int32>) -> [Int32: Double] {
        var latest: [UInt64: UInt64] = [:]
        for client in clients {
            guard let pid = Self.pid(inCreator: client.creator) else { continue }
            latest[client.id] = client.nanoseconds
            var added: UInt64 = 0
            if started {
                let before = lastByClient[client.id] ?? 0
                // A count that went back is a new client under an old identifier.
                added = client.nanoseconds >= before ? client.nanoseconds - before : client.nanoseconds
            }
            secondsByPID[pid, default: 0] += Double(added) / 1e9
        }
        lastByClient = latest
        started = true
        return kept(alive: alive)
    }

    mutating func kept(alive: Set<Int32>) -> [Int32: Double] {
        secondsByPID = secondsByPID.filter { alive.contains($0.key) }
        return secondsByPID
    }

    // "pid 425, WindowServer"
    static func pid(inCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        return Int32(creator.dropFirst(4).prefix { $0.isNumber })
    }
}
