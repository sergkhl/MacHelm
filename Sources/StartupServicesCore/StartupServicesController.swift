import Foundation

public struct NewServiceRequest: Equatable, Sendable {
    public enum Preset: Equatable, Sendable {
        case onceAtLogin
        case keepRunning
        case calendar([ServiceCalendarEntry])
    }

    public var name: String
    public var program: String
    // The arguments after the program itself.
    public var arguments: [String]
    public var workingDirectory: String?
    public var preset: Preset

    public init(name: String, program: String, arguments: [String] = [], workingDirectory: String? = nil, preset: Preset) {
        self.name = name; self.program = program; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.preset = preset
    }
}

// What another project's installer hands over instead of writing its own
// LaunchAgent. It carries no credentials: those stay with the service.
public struct ExternalServiceDefinition: Codable, Equatable, Sendable {
    public var label: String
    public var name: String?
    public var program: String
    // The complete argument vector, argv[0] included.
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]?
    public var umask: Int?
    public var runAtLoad: Bool?
    public var keepAlive: ServiceRestartPolicy?
    public var throttleInterval: Int?
    public var processType: String?
    public var exitTimeOut: Int?
    public var standardOutPath: String?
    public var standardErrorPath: String?
    public var ownerLockPaths: [String]?
}

public struct DiscoveredLaunchAgent: Equatable, Identifiable, Sendable {
    public var path: String
    public var label: String?
    public var sha256: String?
    // Present when the definition can be imported unchanged.
    public var definition: ServiceDefinition?
    public var refusal: String?
    public var inCatalog: Bool

    public var id: String { path }
}

// Owns every change to the catalog and to launchd registrations. Importing,
// reading status and reopening the app never start, install or repair a job.
public final class StartupServicesController: @unchecked Sendable {
    public let paths: StartupServicesPaths
    public let store: ServiceCatalogStore
    public let invocation: ServiceRunnerInvocation?
    private let transport: LaunchdTransport
    private let processes: ProcessInspecting
    private let locks: OwnerLockProbing
    private let permissionReader: BackgroundPermissionReading
    private let now: @Sendable () -> Date

    public init(paths: StartupServicesPaths, transport: LaunchdTransport, invocation: ServiceRunnerInvocation?,
                processes: ProcessInspecting = SystemProcessInspector(), locks: OwnerLockProbing = SystemOwnerLockProbe(),
                permission: BackgroundPermissionReading = UnknownBackgroundPermission(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths; self.store = ServiceCatalogStore(paths: paths); self.invocation = invocation
        self.transport = transport; self.processes = processes; self.locks = locks
        self.permissionReader = permission; self.now = now
    }

    // MARK: Reading

    public func statuses() throws -> [ServiceStatus] {
        let catalog = try store.read()
        let permission = permission(in: catalog)
        let disabled = disabledLabels()
        return catalog.services.map { status(of: $0, permission: permission, disabled: disabled) }
    }

    public func status(_ label: String) throws -> ServiceStatus {
        let catalog = try store.read()
        guard let definition = catalog.service(label) else { throw Self.notFound(label) }
        return status(of: definition, permission: permission(in: catalog), disabled: disabledLabels())
    }

    public func permission() throws -> BackgroundPermission {
        permission(in: try store.read())
    }

    // Lists the user's LaunchAgents and whether each could be imported.
    public func discover() throws -> [DiscoveredLaunchAgent] {
        let catalog = try store.read()
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.launchAgents, includingPropertiesForKeys: nil)) ?? []
        let disabled = disabledLabels()
        return files.filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                var found = DiscoveredLaunchAgent(path: url.path, label: nil, sha256: nil, definition: nil, refusal: nil, inCatalog: false)
                guard let data = PrivateFile.read(url) else {
                    found.refusal = "The file cannot be read."
                    return found
                }
                found.sha256 = ServiceHash.sha256(data)
                if let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    found.label = root["Label"] as? String
                }
                found.inCatalog = found.label.flatMap(catalog.service) != nil
                do {
                    found.definition = try parse(data, at: url, disabled: disabled)
                } catch {
                    found.refusal = "\(error)"
                }
                return found
            }
    }

    // MARK: Catalog changes that run nothing

    @discardableResult
    public func importLaunchAgent(at url: URL) throws -> ServiceDefinition {
        let url = url.standardizedFileURL
        // Q5: only the user's own jobs. A system definition would keep running beside a managed copy.
        guard !Self.isSystemWide(url) else {
            throw StartupServicesError(.unsupported, "\(url.path) belongs to the whole Mac, not to your account. Startup Services manages your own LaunchAgents only.")
        }
        guard let data = PrivateFile.read(url) else {
            throw StartupServicesError(.invalid, "The LaunchAgent at \(url.path) cannot be read.")
        }
        let definition = try parse(data, at: url, disabled: disabledLabels())
        return try store.mutate { catalog in
            guard catalog.service(definition.label) == nil else {
                throw StartupServicesError(.conflict, "\(definition.label) is already in Startup Services.")
            }
            catalog.services.append(definition)
            return definition
        }
    }

    // A new definition is saved switched off and is not run (Q10).
    @discardableResult
    public func add(_ request: NewServiceRequest) throws -> ServiceDefinition {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw StartupServicesError(.invalid, "Give the service a name of up to 80 characters.")
        }
        guard request.program.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: request.program),
              !Self.isDirectory(request.program) else {
            throw StartupServicesError(.invalid, "Choose a program or script that can be executed. For a script without the executable bit, choose its interpreter and pass the script as an argument.")
        }
        if let directory = request.workingDirectory, !Self.isDirectory(directory) {
            throw StartupServicesError(.invalid, "The working directory does not exist: \(directory)")
        }
        var launch = ServiceLaunchPolicy()
        switch request.preset {
        case .onceAtLogin:
            launch.runAtLoad = true
        case .keepRunning:
            launch.runAtLoad = true; launch.restart = .always
        case .calendar(let entries):
            guard !entries.isEmpty else {
                throw StartupServicesError(.invalid, "A scheduled service needs at least one time.")
            }
            launch.calendar = entries
        }
        return try store.mutate { catalog in
            let slug = Self.slug(name)
            var label = StartupServicesIdentity.addedLabelPrefix + slug
            var suffix = 2
            while catalog.service(label) != nil || PrivateFile.exists(paths.installedPlist(label)) {
                label = StartupServicesIdentity.addedLabelPrefix + slug + "-\(suffix)"
                suffix += 1
            }
            let log = paths.logs.appendingPathComponent(label + ".log").path
            launch.standardOutPath = log
            launch.standardErrorPath = log
            let definition = ServiceDefinition(
                label: label, name: name,
                command: ServiceCommand(program: request.program, arguments: [request.program] + request.arguments,
                                        workingDirectory: request.workingDirectory),
                launch: launch, automaticStartup: false, ownership: .managed(installedSHA256: nil, backup: nil))
            catalog.services.append(definition)
            return definition
        }
    }

    public func rename(_ label: String, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw StartupServicesError(.invalid, "Give the service a name of up to 80 characters.")
        }
        try store.mutate { catalog in
            guard let index = catalog.services.firstIndex(where: { $0.label == label }) else { throw Self.notFound(label) }
            catalog.services[index].name = name
        }
    }

    // Claims registration ownership of an imported definition: backs up the
    // exact original, then puts the managed LaunchAgent in its place. Nothing
    // is started or stopped; a job already loaded keeps running as it is until
    // its next start.
    public func takeOver(_ label: String) throws {
        var restore: (() -> Void)?
        do {
            try store.mutate { catalog in
                guard let index = catalog.services.firstIndex(where: { $0.label == label }) else { throw Self.notFound(label) }
                var definition = catalog.services[index]
                guard case .observed(let source) = definition.ownership else {
                    throw StartupServicesError(.conflict, "\(definition.name) is already managed by MacHelm.")
                }
                guard let invocation else { throw Self.error(for: .notInstalled) }
                let sourceURL = URL(fileURLWithPath: source.path)
                guard let original = PrivateFile.read(sourceURL) else { throw Self.error(for: .sourceMissing(source.path)) }
                // An installer may have rewritten the file since the import.
                guard ServiceHash.sha256(original) == source.sha256 else { throw Self.error(for: .sourceChanged(source.path)) }
                let installed = paths.installedPlist(label)
                let sameFile = installed.standardizedFileURL.path == sourceURL.standardizedFileURL.path
                if !sameFile, PrivateFile.exists(installed) {
                    throw Self.error(for: .foreignDefinition(installed.path))
                }

                // A label switched off with `launchctl disable` could never be
                // started by hand. Its off switch becomes the managed one:
                // nothing is installed for login, and launchd's own is cleared.
                let wasDisabled = try transport.disabledLabels().contains(label)
                if wasDisabled { definition.automaticStartup = false }
                let backupURL = try backUp(original, named: sourceURL.lastPathComponent, label: label)
                let backup = ServiceBackup(path: backupURL.path, sha256: source.sha256, originalPath: source.path,
                                           fileMode: source.fileMode, launchdDisabled: wasDisabled)
                let sourceLoadsAtLogin = loadsAtLogin(sourceURL)
                restore = { [paths] in
                    if sourceLoadsAtLogin || sameFile {
                        try? PrivateFile.write(original, to: sourceURL, mode: mode_t(source.fileMode))
                    }
                    if !sameFile { try? FileManager.default.removeItem(at: installed) }
                    try? FileManager.default.removeItem(at: paths.sessionPlist(label))
                }

                let rendered = try LaunchAgentRenderer.data(for: definition, invocation: invocation)
                try PrivateFile.write(rendered, to: paths.sessionPlist(label), mode: 0o600)
                var installedHash: String?
                if definition.automaticStartup {
                    try PrivateFile.ensureDirectory(paths.launchAgents, mode: 0o755)
                    try PrivateFile.write(rendered, to: installed, mode: mode_t(source.fileMode | 0o600))
                    installedHash = ServiceHash.sha256(rendered)
                    // An original under another file name would load beside the managed one.
                    if !sameFile, sourceLoadsAtLogin { try Self.removeFile(sourceURL) }
                } else if sourceLoadsAtLogin {
                    try Self.removeFile(sourceURL)
                }
                definition.ownership = .managed(installedSHA256: installedHash, backup: backup)
                catalog.services[index] = definition
                if wasDisabled {
                    try transport.setDisabled(false, label: label)
                    let filesBack = restore
                    restore = { [transport] in
                        filesBack?()
                        try? transport.setDisabled(true, label: label)
                    }
                }
            }
        } catch {
            // The catalog was not saved: put the original back as it was.
            restore?()
            throw error
        }
    }

    // The owner's answer to a LaunchAgent that was changed or written outside
    // MacHelm: take the file now in place as the service's definition. It
    // is backed up exactly, and the managed LaunchAgent is rendered from it.
    // Nothing is started or stopped.
    public func useOutsideDefinition(_ label: String) throws {
        var restore: (() -> Void)?
        do {
            try store.mutate { catalog in
                guard let index = catalog.services.firstIndex(where: { $0.label == label }) else { throw Self.notFound(label) }
                var definition = try managed(catalog.services[index])
                guard case .managed(let installedHash, _) = definition.ownership else { return }
                guard let invocation else { throw Self.error(for: .notInstalled) }
                let installed = paths.installedPlist(label)
                guard let outside = PrivateFile.read(installed) else {
                    guard PrivateFile.exists(installed) else { throw Self.error(for: .definitionMissing(installed.path)) }
                    throw StartupServicesError(.conflict, "What is at \(installed.path) cannot be read as a LaunchAgent. It was left as found.")
                }
                guard ServiceHash.sha256(outside) != installedHash else { return }
                let mode = PrivateFile.mode(installed) ?? 0o644
                let parsed = try parse(outside, at: installed, disabled: [])
                guard parsed.label == label else {
                    throw StartupServicesError(.conflict, "The file at \(installed.path) defines \(parsed.label), not \(label).")
                }
                let backupURL = try backUp(outside, named: installed.lastPathComponent, label: label)
                definition.command = parsed.command
                definition.launch = parsed.launch
                definition.automaticStartup = parsed.automaticStartup
                let rendered = try LaunchAgentRenderer.data(for: definition, invocation: invocation)
                let previousSession = PrivateFile.read(paths.sessionPlist(label))
                restore = { [paths] in
                    try? PrivateFile.write(outside, to: installed, mode: mode_t(mode))
                    if let previousSession { try? PrivateFile.write(previousSession, to: paths.sessionPlist(label), mode: 0o600) }
                }
                try PrivateFile.write(rendered, to: paths.sessionPlist(label), mode: 0o600)
                var newHash: String?
                if parsed.automaticStartup {
                    try PrivateFile.write(rendered, to: installed, mode: mode_t(mode | 0o600))
                    newHash = ServiceHash.sha256(rendered)
                } else {
                    try Self.removeFile(installed)
                }
                definition.ownership = .managed(
                    installedSHA256: newHash,
                    backup: ServiceBackup(path: backupURL.path, sha256: ServiceHash.sha256(outside), originalPath: installed.path, fileMode: mode))
                catalog.services[index] = definition
            }
        } catch {
            // The catalog was not saved: the outside file goes back as it was found.
            restore?()
            throw error
        }
    }

    // The rollback of `takeOver`: puts the exact original back and returns the
    // entry to an observed one. Nothing is started.
    public func revert(_ label: String) throws {
        var restore: (() -> Void)?
        do {
            try store.mutate { catalog in
                guard let index = catalog.services.firstIndex(where: { $0.label == label }) else { throw Self.notFound(label) }
                var definition = catalog.services[index]
                guard case .managed(let installedHash, let backup?) = definition.ownership else {
                    throw StartupServicesError(.conflict, "\(definition.name) has no original definition to return to.")
                }
                try requireStopped(definition, purpose: "returning it to its original definition")
                guard let original = PrivateFile.read(URL(fileURLWithPath: backup.path)),
                      ServiceHash.sha256(original) == backup.sha256 else {
                    throw StartupServicesError(.storage, "The backup at \(backup.path) is missing or was changed.")
                }
                let installed = paths.installedPlist(label)
                let originalURL = URL(fileURLWithPath: backup.originalPath)
                if let current = Self.fileHash(installed), current != installedHash {
                    throw Self.error(for: .definitionChangedOutside(installed.path))
                }
                let sameFile = installed.standardizedFileURL.path == originalURL.standardizedFileURL.path
                if !sameFile, let found = Self.fileHash(originalURL), found != backup.sha256 {
                    throw Self.error(for: .foreignDefinition(originalURL.path))
                }
                let managedPlist = PrivateFile.read(installed)
                let managedMode = PrivateFile.mode(installed) ?? 0o644
                let originalWasThere = PrivateFile.exists(originalURL)
                let session = PrivateFile.read(paths.sessionPlist(label))
                restore = { [paths, transport] in
                    if let managedPlist {
                        try? PrivateFile.write(managedPlist, to: installed, mode: mode_t(managedMode))
                    } else if sameFile {
                        try? FileManager.default.removeItem(at: installed)
                    }
                    if !sameFile, !originalWasThere { try? FileManager.default.removeItem(at: originalURL) }
                    if let session { try? PrivateFile.write(session, to: paths.sessionPlist(label), mode: 0o600) }
                    if backup.launchdDisabled { try? transport.setDisabled(false, label: label) }
                }
                // The original goes in first, so there is never a moment with no definition at all.
                // One that was never moved (kept outside the login folder) is left as it is.
                if Self.fileHash(originalURL) != backup.sha256 {
                    try PrivateFile.write(original, to: originalURL, mode: mode_t(backup.fileMode))
                }
                if !sameFile, PrivateFile.exists(installed) { try Self.removeFile(installed) }
                if backup.launchdDisabled { try transport.setDisabled(true, label: label) }
                try? FileManager.default.removeItem(at: paths.sessionPlist(label))
                // Whether it starts at login is again what the original itself says.
                if let asImported = try? parse(original, at: originalURL, disabled: backup.launchdDisabled ? [label] : []) {
                    definition.automaticStartup = asImported.automaticStartup
                }
                definition.ownership = .observed(ServiceSource(path: backup.originalPath, sha256: backup.sha256,
                                                               fileMode: backup.fileMode))
                catalog.services[index] = definition
            }
        } catch {
            // The catalog was not saved: the managed definition stays the owner.
            restore?()
            throw error
        }
    }

    // Q8: decides only what happens at the next login. The current session's
    // registration and process are left exactly as they are.
    public func setAutomaticStartup(_ label: String, enabled: Bool) throws {
        try store.mutate { catalog in
            guard let index = catalog.services.firstIndex(where: { $0.label == label }) else { throw Self.notFound(label) }
            var definition = try managed(catalog.services[index])
            guard case .managed(let installedHash, let backup) = definition.ownership else { return }
            let installed = paths.installedPlist(label)
            let currentHash = Self.fileHash(installed)
            if let currentHash {
                guard let installedHash else { throw Self.error(for: .foreignDefinition(installed.path)) }
                guard currentHash == installedHash else { throw Self.error(for: .definitionChangedOutside(installed.path)) }
            }
            if enabled {
                guard let invocation else { throw Self.error(for: .notInstalled) }
                let rendered = try LaunchAgentRenderer.data(for: definition, invocation: invocation)
                try PrivateFile.ensureDirectory(paths.launchAgents, mode: 0o755)
                try PrivateFile.write(rendered, to: installed, mode: 0o644)
                definition.ownership = .managed(installedSHA256: ServiceHash.sha256(rendered), backup: backup)
            } else {
                if currentHash != nil { try Self.removeFile(installed) }
                definition.ownership = .managed(installedSHA256: nil, backup: backup)
            }
            definition.automaticStartup = enabled
            catalog.services[index] = definition
        }
    }

    // Q11: removes the managed startup definition only. Scripts, data, logs
    // and the backup of the original stay, and the original is not reactivated.
    public func remove(_ label: String) throws {
        try store.mutate { catalog in
            guard let index = catalog.services.firstIndex(where: { $0.label == label }) else { throw Self.notFound(label) }
            let definition = catalog.services[index]
            if case .managed(let installedHash, _) = definition.ownership {
                try requireStopped(definition, purpose: "removing it")
                let installed = paths.installedPlist(label)
                // A file MacHelm did not write is left where it is.
                if let installedHash, Self.fileHash(installed) == installedHash { try Self.removeFile(installed) }
                try? FileManager.default.removeItem(at: paths.sessionPlist(label))
                try? FileManager.default.removeItem(at: paths.runRecord(label))
                try? FileManager.default.removeItem(at: paths.stopMarker(label))
            }
            catalog.services.remove(at: index)
        }
    }

    // The installer of a managed service calls this instead of writing a
    // LaunchAgent. It creates the definition switched off, or updates a
    // stopped one while keeping its name and startup preference.
    @discardableResult
    public func installDefinition(_ external: ExternalServiceDefinition) throws -> ServiceDefinition {
        guard LaunchAgentImporter.isValidLabel(external.label) else {
            throw StartupServicesError(.invalid, "The service label is not a plain launchd label.")
        }
        guard external.program.hasPrefix("/"), !external.arguments.isEmpty else {
            throw StartupServicesError(.invalid, "The service needs an absolute program path and its arguments.")
        }
        if let processType = external.processType, !["Background", "Standard", "Adaptive", "Interactive"].contains(processType) {
            throw StartupServicesError(.invalid, "\(processType) is not a launchd process type.")
        }
        if let umask = external.umask, !(0...0o777).contains(umask) {
            throw StartupServicesError(.invalid, "The umask is out of range.")
        }
        // A new definition takes launchd's defaults for what the installer
        // leaves out; an update keeps what the definition already has.
        func launchPolicy(from base: ServiceLaunchPolicy) -> ServiceLaunchPolicy {
            var launch = base
            if let value = external.runAtLoad { launch.runAtLoad = value }
            if let value = external.keepAlive { launch.restart = value }
            if let value = external.throttleInterval { launch.throttleInterval = value }
            if let value = external.processType { launch.processType = value }
            if let value = external.exitTimeOut { launch.exitTimeOut = value }
            if let value = external.standardOutPath { launch.standardOutPath = value }
            if let value = external.standardErrorPath { launch.standardErrorPath = value }
            return launch
        }
        func commandSettings(from base: ServiceCommand?) -> ServiceCommand {
            ServiceCommand(program: external.program, arguments: external.arguments,
                           workingDirectory: external.workingDirectory ?? base?.workingDirectory,
                           environment: external.environment ?? base?.environment ?? [:],
                           umask: external.umask ?? base?.umask)
        }
        return try store.mutate { catalog in
            let installed = paths.installedPlist(external.label)
            guard let index = catalog.services.firstIndex(where: { $0.label == external.label }) else {
                // An existing LaunchAgent is someone's registration; it is imported, never replaced.
                guard !PrivateFile.exists(installed) else { throw Self.error(for: .foreignDefinition(installed.path)) }
                let definition = ServiceDefinition(
                    label: external.label, name: external.name ?? KnownServiceDefaults.name(for: external.label),
                    command: commandSettings(from: nil), launch: launchPolicy(from: ServiceLaunchPolicy()), automaticStartup: false,
                    ownership: .managed(installedSHA256: nil, backup: nil),
                    dependencies: KnownServiceDefaults.entries[external.label]?.dependencies ?? [],
                    ownerLockPaths: external.ownerLockPaths ?? [])
                catalog.services.append(definition)
                return definition
            }
            var definition = try managed(catalog.services[index])
            guard case .managed(let installedHash, let backup) = definition.ownership else { return definition }
            try requireStopped(definition, purpose: "changing its definition")
            let currentHash = Self.fileHash(installed)
            if let currentHash {
                guard let installedHash else { throw Self.error(for: .foreignDefinition(installed.path)) }
                guard currentHash == installedHash else { throw Self.error(for: .definitionChangedOutside(installed.path)) }
            } else if installedHash != nil {
                throw Self.error(for: .definitionMissing(installed.path))
            }
            definition.command = commandSettings(from: definition.command)
            definition.launch = launchPolicy(from: definition.launch)
            if let locks = external.ownerLockPaths { definition.ownerLockPaths = locks }
            if installedHash != nil {
                guard let invocation else { throw Self.error(for: .notInstalled) }
                let rendered = try LaunchAgentRenderer.data(for: definition, invocation: invocation)
                try PrivateFile.write(rendered, to: installed, mode: mode_t((PrivateFile.mode(installed) ?? 0o644) | 0o600))
                definition.ownership = .managed(installedSHA256: ServiceHash.sha256(rendered), backup: backup)
            }
            catalog.services[index] = definition
            return definition
        }
    }

    // MARK: Current-session actions

    // Works whether or not automatic startup is on, and never changes it.
    public func start(_ label: String) throws {
        try store.mutate { catalog in
            guard let found = catalog.service(label) else { throw Self.notFound(label) }
            let definition = try managed(found)
            guard definition.kind == .continuous else {
                throw StartupServicesError(.invalid, "\(definition.name) runs on demand. Use Run Now.")
            }
            let status = self.status(of: definition, permission: permission(in: catalog), disabled: disabledLabels())
            if case .running = status.activity { return }
            try activate(definition, status: status, ensureRun: true)
        }
    }

    // Q12: one more run of a one-shot or scheduled job. launchd keeps one
    // instance per label, so a run in progress is never doubled.
    public func runNow(_ label: String) throws {
        try store.mutate { catalog in
            guard let found = catalog.service(label) else { throw Self.notFound(label) }
            let definition = try managed(found)
            guard definition.kind != .continuous else {
                throw StartupServicesError(.invalid, "\(definition.name) keeps running. Use Start.")
            }
            let status = self.status(of: definition, permission: permission(in: catalog), disabled: disabledLabels())
            if case .running = status.activity {
                throw StartupServicesError(.busy, "\(definition.name) is already running.")
            }
            try activate(definition, status: status, ensureRun: true)
        }
    }

    // Puts a stopped schedule back for this session without running the job.
    public func resumeSchedule(_ label: String) throws {
        try store.mutate { catalog in
            guard let found = catalog.service(label) else { throw Self.notFound(label) }
            let definition = try managed(found)
            guard definition.kind == .scheduled else {
                throw StartupServicesError(.invalid, "\(definition.name) has no schedule.")
            }
            // Loading a job that runs when loaded would run it now.
            guard !definition.launch.runAtLoad else {
                throw StartupServicesError(.invalid, "\(definition.name) also runs whenever it is loaded. Use Run Now, which runs it and puts its schedule back.")
            }
            let status = self.status(of: definition, permission: permission(in: catalog), disabled: disabledLabels())
            guard status.activity == .inactive else { return }
            try activate(definition, status: status, ensureRun: false)
        }
    }

    // Q8: ends this session's registration, so launchd cannot restart the
    // job, and leaves the automatic-startup preference alone. The status
    // stays Stopping until the process has exited and released its lock;
    // nothing here force-kills it.
    public func stop(_ label: String) throws {
        try store.mutate { catalog in
            guard let found = catalog.service(label) else { throw Self.notFound(label) }
            let definition = try managed(found)
            guard let snapshot = try transport.snapshot(label: label) else { return }
            // The marker names the process that was asked to stop. A job with
            // no process has nothing to wait for, and a process started later
            // under the same label is not the one being stopped.
            if let pid = snapshot.pid, let started = processes.startTime(of: pid) {
                let marker = StopMarker(pid: pid, processStartTime: started, requestedAt: now())
                try PrivateFile.ensureDirectory(paths.run)
                try PrivateFile.write(try JSONEncoder().encode(marker), to: paths.stopMarker(definition.label))
            }
            do {
                try transport.bootout(label: label)
            } catch {
                try? FileManager.default.removeItem(at: paths.stopMarker(label))
                throw error
            }
        }
    }

    // Waits for a Stop to finish, reading status only. Returns false if the
    // service is still stopping when the time is up.
    public func waitUntilStopped(_ label: String, timeout: TimeInterval, poll: TimeInterval = 0.1) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if try status(label).activity == .inactive { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            Thread.sleep(forTimeInterval: poll)
        }
    }

    // MARK: Internals

    private func parse(_ data: Data, at url: URL, disabled: Set<String>) throws -> ServiceDefinition {
        var runners: Set<String> = [StartupServicesIdentity.installedRunnerPath]
        if let invocation { runners.insert(invocation.runnerPath) }
        var definition = try LaunchAgentImporter.definition(fromPlist: data, sourcePath: url.path,
                                                            fileMode: PrivateFile.mode(url) ?? 0o644, runnerPaths: runners)
        // The owner's current choice. A label switched off in launchd does
        // not start at login, and neither does a file kept anywhere but in
        // the folder macOS loads at login.
        if disabled.contains(definition.label) || !loadsAtLogin(url) { definition.automaticStartup = false }
        return definition
    }

    private func loadsAtLogin(_ url: URL) -> Bool {
        url.deletingLastPathComponent().resolvingSymlinksInPath().path == paths.launchAgents.resolvingSymlinksInPath().path
    }

    private static func isSystemWide(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix("/Library/") || path.hasPrefix("/System/") || path.hasPrefix("/Network/")
    }

    // An unreadable list is treated as empty; a load that launchd refuses is still reported when tried.
    private func disabledLabels() -> Set<String> {
        (try? transport.disabledLabels()) ?? []
    }

    private func permission(in catalog: ServiceCatalog) -> BackgroundPermission {
        let installed = catalog.services.compactMap { definition -> URL? in
            if case .managed(_?, _) = definition.ownership { return paths.installedPlist(definition.label) }
            return nil
        }
        return permissionReader.permission(forInstalled: installed)
    }

    private func managed(_ definition: ServiceDefinition) throws -> ServiceDefinition {
        guard definition.isManaged else {
            throw StartupServicesError(.conflict, "\(definition.name) still belongs to its original LaunchAgent. Choose Manage with MacHelm first.")
        }
        return definition
    }

    private func activate(_ definition: ServiceDefinition, status: ServiceStatus, ensureRun: Bool) throws {
        switch status.activity {
        case .stopping:
            throw StartupServicesError(.busy, "\(definition.name) is still stopping.")
        case .unknown(let reason):
            throw StartupServicesError(.launchd, reason)
        default: break
        }
        if let problem = status.problems.first { throw Self.error(for: problem) }
        guard let invocation else { throw Self.error(for: .notInstalled) }
        if status.activity == .inactive {
            let rendered = try LaunchAgentRenderer.data(for: definition, invocation: invocation)
            try PrivateFile.write(rendered, to: paths.sessionPlist(definition.label), mode: 0o600)
            // While automatic startup is on, the session uses the same file
            // macOS loads at login, so the macOS switch governs both.
            var plist = paths.sessionPlist(definition.label)
            if case .managed(_?, _) = definition.ownership { plist = paths.installedPlist(definition.label) }
            try transport.bootstrap(plist: plist)
            let startsWhenLoaded = definition.launch.runAtLoad || definition.launch.restart == .always
            if ensureRun, !startsWhenLoaded { try transport.kickstart(label: definition.label) }
        } else if ensureRun {
            try transport.kickstart(label: definition.label)
        }
    }

    private func requireStopped(_ definition: ServiceDefinition, purpose: String) throws {
        let refusal = StartupServicesError(.busy, "Stop \(definition.name) and wait until it has stopped before \(purpose).")
        guard try transport.snapshot(label: definition.label) == nil else { throw refusal }
        guard liveChild(ServiceRunRecord.read(paths.runRecord(definition.label))) == nil,
              stopMarker(definition.label).map(isAlive) != true,
              !definition.ownerLockPaths.contains(where: locks.isHeld) else { throw refusal }
    }

    private struct StopMarker: Codable {
        var pid: Int32
        var processStartTime: Double
        var requestedAt: Date
    }

    private func stopMarker(_ label: String) -> StopMarker? {
        guard let data = PrivateFile.read(paths.stopMarker(label)) else { return nil }
        return try? JSONDecoder().decode(StopMarker.self, from: data)
    }

    // True while the process that was asked to stop is still that same process.
    private func isAlive(_ marker: StopMarker) -> Bool {
        guard let current = processes.startTime(of: marker.pid) else { return false }
        return abs(current - marker.processStartTime) < 0.01
    }

    // The recorded command process, if it is still the same live process.
    private func liveChild(_ record: ServiceRunRecord?) -> Int32? {
        guard let record, record.isAlive(processes) else { return nil }
        return record.pid
    }

    func status(of definition: ServiceDefinition, permission: BackgroundPermission, disabled: Set<String> = []) -> ServiceStatus {
        let label = definition.label
        var snapshot: LaunchdJobSnapshot?
        var launchdFailure: String?
        do { snapshot = try transport.snapshot(label: label) } catch { launchdFailure = "\(error)" }
        let record = ServiceRunRecord.read(paths.runRecord(label))
        let childPID = liveChild(record)

        // Stopping lasts while the process that was asked to stop is still
        // there: under launchd as the same process, or after launchd let go
        // of it, alive or with its lock still held. A job loaded again with
        // another process ends it. The lock is asked about only here.
        var stopping = false
        if PrivateFile.exists(paths.stopMarker(label)), launchdFailure == nil {
            if let marker = stopMarker(label) {
                if let snapshot {
                    stopping = snapshot.pid == marker.pid && isAlive(marker)
                } else {
                    stopping = isAlive(marker) || definition.ownerLockPaths.contains(where: locks.isHeld)
                }
            }
            if !stopping { try? FileManager.default.removeItem(at: paths.stopMarker(label)) }
        }

        let activity: ServiceActivity
        if let launchdFailure {
            activity = .unknown(launchdFailure)
        } else if stopping {
            activity = .stopping
        } else if let snapshot {
            if let pid = snapshot.pid {
                activity = .running(pid: pid)
            } else if snapshot.state == "spawn scheduled" || definition.launch.restart == .always {
                activity = .waiting
            } else if definition.launch.restart == .afterFailure, let code = snapshot.lastExitCode, code != 0 {
                activity = .waiting
            } else {
                activity = .idle
            }
        } else {
            activity = .inactive
        }

        var loaded = ServiceLoadedInstance.none
        if let snapshot {
            let runner = invocation?.runnerPath ?? StartupServicesIdentity.installedRunnerPath
            let isRunner = snapshot.program == runner
                || snapshot.program?.hasSuffix("/" + StartupServicesIdentity.runnerRelativePath) == true
            loaded = isRunner ? .managed : .original
        }

        // launchd keeps the last exit while the job is registered. The runner
        // adds only the reason a command could not be started at all.
        var lastResult: ServiceLastResult?
        if loaded != .original, let failure = record?.failure {
            lastResult = ServiceLastResult(exitCode: snapshot?.lastExitCode, terminatingSignal: nil, failure: failure)
        } else if snapshot?.lastExitCode != nil || snapshot?.lastTerminatingSignal != nil {
            lastResult = ServiceLastResult(exitCode: snapshot?.lastExitCode,
                                           terminatingSignal: snapshot?.lastTerminatingSignal, failure: nil)
        }

        var problems: [ServiceProblem] = []
        switch definition.ownership {
        case .observed(let source):
            let hash = Self.fileHash(URL(fileURLWithPath: source.path))
            if hash == nil { problems.append(.sourceMissing(source.path)) }
            else if hash != source.sha256 { problems.append(.sourceChanged(source.path)) }
        case .managed(let installedHash, _):
            let installed = paths.installedPlist(label)
            let hash = Self.fileHash(installed)
            if let installedHash {
                if hash == nil { problems.append(.definitionMissing(installed.path)) }
                else if hash != installedHash { problems.append(.definitionChangedOutside(installed.path)) }
            } else if hash != nil {
                problems.append(.foreignDefinition(installed.path))
            }
            if let invocation {
                if !FileManager.default.isExecutableFile(atPath: invocation.runnerPath) {
                    problems.append(.runnerMissing(invocation.runnerPath))
                }
            } else {
                problems.append(.notInstalled)
            }
            if !FileManager.default.isExecutableFile(atPath: definition.command.program) || Self.isDirectory(definition.command.program) {
                problems.append(.executableMissing(definition.command.program))
            }
            if permission == .blocked { problems.append(.permissionBlocked) }
            if disabled.contains(label) { problems.append(.disabledInLaunchd(label)) }
            if snapshot == nil, !stopping, let childPID { problems.append(.strayProcess(childPID)) }
        }

        var actions: [ServiceAction] = []
        switch definition.ownership {
        case .observed:
            if problems.isEmpty, invocation != nil { actions.append(.takeOver) }
            actions.append(.remove)
        case .managed:
            let canActivate = problems.isEmpty
            switch activity {
            case .stopping, .unknown: break
            case .running, .waiting: actions = [.stop]
            case .idle:
                if canActivate { actions.append(definition.kind == .continuous ? .start : .runNow) }
                actions.append(.stop)
            case .inactive:
                if canActivate {
                    switch definition.kind {
                    case .continuous: actions.append(.start)
                    case .scheduled: actions += definition.launch.runAtLoad ? [.runNow] : [.runNow, .resumeSchedule]
                    case .oneShot: actions.append(.runNow)
                    }
                }
                actions.append(.remove)
            }
            // A file someone else put in place can be taken as the new definition.
            let outside = problems.contains { problem in
                if case .definitionChangedOutside = problem { return true }
                if case .foreignDefinition = problem { return true }
                return false
            }
            if outside, invocation != nil { actions.insert(.useOutsideDefinition, at: 0) }
        }
        return ServiceStatus(definition: definition, activity: activity, loadedInstance: loaded, runs: snapshot?.runs,
                             lastResult: lastResult, problems: problems, actions: actions,
                             disabledInLaunchd: disabled.contains(label))
    }

    private func backUp(_ data: Data, named name: String, label: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now())
        var directory = paths.backups.appendingPathComponent("\(stamp)-\(label)")
        var attempt = 2
        while PrivateFile.exists(directory) {
            directory = paths.backups.appendingPathComponent("\(stamp)-\(label)-\(attempt)")
            attempt += 1
        }
        try PrivateFile.ensureDirectory(directory)
        let url = directory.appendingPathComponent(name)
        try PrivateFile.write(data, to: url, mode: 0o600)
        guard Self.fileHash(url) == ServiceHash.sha256(data) else {
            throw StartupServicesError(.storage, "The backup at \(url.path) could not be verified.")
        }
        return url
    }

    static func error(for problem: ServiceProblem) -> StartupServicesError {
        let kind: StartupServicesError.Kind
        switch problem {
        case .notInstalled, .runnerMissing: kind = .notInstalled
        case .permissionBlocked, .disabledInLaunchd: kind = .blocked
        case .executableMissing: kind = .invalid
        case .strayProcess: kind = .busy
        default: kind = .conflict
        }
        return StartupServicesError(kind, problem.message)
    }

    private static func notFound(_ label: String) -> StartupServicesError {
        StartupServicesError(.notFound, "\(label) is not in Startup Services.")
    }

    // Nil only when nothing is at the path. A file that is there but cannot
    // be read (a dangling link, a folder, no permission) gets a value no real
    // file has, so it is treated as someone else's and never replaced.
    static func fileHash(_ url: URL) -> String? {
        if let data = PrivateFile.read(url) { return ServiceHash.sha256(data) }
        return PrivateFile.exists(url) ? "unreadable" : nil
    }

    private static func removeFile(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw StartupServicesError(.storage, "Cannot remove \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func slug(_ name: String) -> String {
        var slug = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "service" : String(slug.prefix(48))
    }
}
