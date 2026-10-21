import AppKit
import Combine
import ServiceManagement

// The one source of Startup Services state for the dashboard and the menu
// bar. It reads local state only: launchd's report, the catalog and the
// runner's record. Showing a surface never starts, installs or repairs a job.
@MainActor
final class StartupServicesStore: ObservableObject {
    @Published private(set) var services: [ServiceStatus] = []
    @Published private(set) var loaded = false
    // When the state shown was last read. Not published: a read that found nothing new redraws nothing.
    private(set) var refreshedAt: Date?
    // The catalog could not be read; nothing is shown as if it were empty.
    @Published private(set) var loadFailure: String?
    // The latest refusal or failure, kept at the service it belongs to.
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var generalFailure: String?
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var discovered: [DiscoveredLaunchAgent] = []
    @Published private(set) var openAtLogin = false

    // Registrations name the runner inside /Applications/MacHelm.app, so
    // a copy run from anywhere else can look but not register.
    let isInstalled: Bool
    let launchAgentsFolder: URL

    private let controller: StartupServicesController
    private let queue = DispatchQueue(label: "io.github.sergkhl.MacHelm.startup-services", qos: .userInitiated)
    // Reading has a queue of its own, so a slow Stop does not hold back the Stopping state.
    private let readQueue = DispatchQueue(label: "io.github.sergkhl.MacHelm.startup-services.read", qos: .userInitiated)
    private var timer: Timer?
    private var watchers = 0
    private var refreshing = false
    private var refreshAgain = false
    private static let loginDecidedKey = "StartupServicesOpenAtLoginDecided"
    private static let refreshInterval: TimeInterval = 3

    init() {
        let runner = Bundle.main.bundleURL.appendingPathComponent(StartupServicesIdentity.runnerRelativePath).path
        let paths: StartupServicesPaths
        var invocation: ServiceRunnerInvocation?
        if let root = ProcessInfo.processInfo.environment["MACHELM_STARTUP_SERVICES_ROOT"], root.hasPrefix("/") {
            // A self-contained folder for development: its jobs name it, so
            // they can never read the owner's catalog.
            paths = .sandbox(root: URL(fileURLWithPath: root))
            invocation = ServiceRunnerInvocation(runnerPath: runner, rootArgument: root)
        } else {
            paths = .standard()
            if Bundle.main.bundleURL.resolvingSymlinksInPath().path == StartupServicesIdentity.installedAppPath {
                invocation = ServiceRunnerInvocation(runnerPath: StartupServicesIdentity.installedRunnerPath)
            }
        }
        isInstalled = invocation != nil
        launchAgentsFolder = paths.launchAgents
        controller = StartupServicesController(
            paths: paths, transport: paths.isStandard ? LaunchctlTransport() : SelfTestOnlyTransport(LaunchctlTransport()),
            invocation: invocation,
            permission: paths.isStandard ? SystemBackgroundPermission() : UnknownBackgroundPermission())
        refreshOpenAtLogin()
    }

    var permissionBlocked: Bool {
        services.contains { $0.problems.contains(.permissionBlocked) }
    }

    // MARK: Watching

    // A visible dashboard watches; nothing is polled while it is hidden.
    func beginWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Common modes, so the dashboard is still refreshed while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let controller = controller
        readQueue.async {
            let result = Result { try controller.statuses() }
            Task { @MainActor in
                self.refreshing = false
                self.show(result)
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    private func show(_ result: Result<[ServiceStatus], Error>) {
        switch result {
        case .success(let statuses):
            if statuses != services { services = statuses }
            if loadFailure != nil { loadFailure = nil }
        case .failure(let error):
            if loadFailure != "\(error)" { loadFailure = "\(error)" }
        }
        if !loaded { loaded = true }
        refreshedAt = Date()
    }

    // MARK: Actions

    func perform(_ action: ServiceAction, on label: String) {
        run(on: label) { controller in
            switch action {
            case .start: try controller.start(label)
            case .stop: try controller.stop(label)
            case .runNow: try controller.runNow(label)
            case .resumeSchedule: try controller.resumeSchedule(label)
            case .takeOver: try controller.takeOver(label)
            case .useOutsideDefinition: try controller.useOutsideDefinition(label)
            case .remove: try controller.remove(label)
            }
        } then: { [weak self] in
            if action == .takeOver { self?.enableOpenAtLoginDuringSetup() }
        }
    }

    func setAutomaticStartup(_ label: String, enabled: Bool) {
        run(on: label) { try $0.setAutomaticStartup(label, enabled: enabled) }
    }

    func rename(_ label: String, to name: String) {
        run(on: label) { try $0.rename(label, to: name) }
    }

    func importLaunchAgent(at url: URL, completion: @escaping (Bool) -> Void = { _ in }) {
        run(on: nil, { _ = try $0.importLaunchAgent(at: url) }, then: { [weak self] in
            self?.loadDiscovered()
            completion(true)
        }, otherwise: { completion(false) })
    }

    func add(_ request: NewServiceRequest, completion: @escaping (Bool) -> Void) {
        run(on: nil, { _ = try $0.add(request) }, then: { [weak self] in
            self?.enableOpenAtLoginDuringSetup()
            completion(true)
        }, otherwise: { completion(false) })
    }

    func loadDiscovered() {
        let controller = controller
        readQueue.async {
            let found = (try? controller.discover()) ?? []
            Task { @MainActor in self.discovered = found }
        }
    }

    func clearFailure(for label: String?) {
        if let label { failures[label] = nil } else { generalFailure = nil }
    }

    private func run(on label: String?, _ work: @escaping @Sendable (StartupServicesController) throws -> Void,
                     then success: @escaping @MainActor () -> Void = {},
                     otherwise failure: @escaping @MainActor () -> Void = {}) {
        if let label {
            guard !busy.contains(label) else { return }
            busy.insert(label)
            failures[label] = nil
        } else {
            generalFailure = nil
        }
        let controller = controller
        // Shows an action that takes a while, such as a stop the service is slow to follow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
        queue.async {
            let result = Result { try work(controller) }
            Task { @MainActor in
                if let label { self.busy.remove(label) }
                switch result {
                case .success:
                    success()
                case .failure(let error):
                    if let label { self.failures[label] = "\(error)" } else { self.generalFailure = "\(error)" }
                    failure()
                }
                self.refresh()
            }
        }
    }

    // MARK: Logs

    func logPaths(for definition: ServiceDefinition) -> [String] {
        var paths: [String] = []
        for path in [definition.launch.standardOutPath, definition.launch.standardErrorPath] {
            if let path, path != "/dev/null", !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    // The end of a log file, read when the owner opens it.
    nonisolated static func logTail(at path: String, maximumBytes: Int = 65_536) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "No log file at \(path) yet." }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return "The log is empty." }
        return start > 0 ? "… earlier lines are in the file …\n" + text : text
    }

    // MARK: Opening MacHelm at login (Q7)

    func refreshOpenAtLogin() {
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setOpenAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(true, forKey: Self.loginDecidedKey)
        applyOpenAtLogin(enabled)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // Setting up the first managed service turns the quiet login launch on,
    // once; afterwards the owner's own choice stands.
    private func enableOpenAtLoginDuringSetup() {
        // A copy outside Applications cannot be a login item; it stays undecided.
        guard isInstalled, !UserDefaults.standard.bool(forKey: Self.loginDecidedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.loginDecidedKey)
        applyOpenAtLogin(true)
    }

    private func applyOpenAtLogin(_ enabled: Bool) {
        // A login item for a copy outside Applications would point at that copy.
        guard Bundle.main.bundleURL.resolvingSymlinksInPath().path == StartupServicesIdentity.installedAppPath else {
            generalFailure = "Install MacHelm in the Applications folder before opening it at login."
            return
        }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            generalFailure = "macOS did not change the login item: \(error.localizedDescription)"
        }
        refreshOpenAtLogin()
    }
}
