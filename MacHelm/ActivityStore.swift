import AppKit
import Combine

// One pass over the processes and the whole Mac.
private struct ActivityReading: Sendable {
    var averages: ActivityAverages?
    var load: SystemLoad
    // nil when it was not ranked: nothing watched while it was read.
    var ranked: ActivitySnapshot??
}

// The reader and its window. They belong to the store's queue.
private final class ActivitySampler: @unchecked Sendable {
    private let reader = ProcessReader(transport: DarwinProcessTransport())
    private var window = ActivityWindow()
    private var meter = SystemMeter(transport: DarwinSystemTransport())

    // `ranking` is nil while nothing watches: the reading is kept and not ranked.
    func sample(length: TimeInterval, ranking: (services: [ServiceRoot], ownPID: Int32)?) -> ActivityReading {
        let uptime = ProcessInfo.processInfo.systemUptime
        // The whole Mac first, so that reading the processes is not in its figure.
        let load = meter.read(at: uptime)
        window.length = length
        window.add(reader.read(at: uptime))
        let averages = window.averages()
        return ActivityReading(averages: averages, load: load, ranked: ranking.map { ranking in
            averages.map { ActivityRanking.snapshot(of: $0, services: ranking.services, ownPID: ranking.ownPID) }
        })
    }
}

// The one source of Activity's state. It reads whenever MacHelm runs
// (ADR 0005): at the background pace, and at the on-screen pace while a page
// shows the lists or the menu bar menu is open. A reading is ranked and
// published only while something watches (ADR 0006).
@MainActor
final class ActivityStore: ObservableObject {
    // nil until the first two readings.
    @Published private(set) var snapshot: ActivitySnapshot?
    // The whole Mac now (Q34); nil until the first reading.
    @Published private(set) var load: SystemLoad?
    // Why the latest Quit or Force Quit ended nothing.
    @Published private(set) var notice: String?
    // The three settings, remembered. A value that is not offered falls back to the usual one.
    @Published var windowLength: TimeInterval {
        didSet { changed(windowLength, from: oldValue, key: Self.windowKey) }
    }
    @Published var backgroundPace: TimeInterval {
        didSet { changed(backgroundPace, from: oldValue, key: Self.backgroundKey) }
    }
    @Published var onScreenPace: TimeInterval {
        didSet { changed(onScreenPace, from: oldValue, key: Self.onScreenKey) }
    }

    private static let windowKey = "ActivityWindowLength"
    private static let backgroundKey = "ActivityBackgroundPace"
    private static let onScreenKey = "ActivityOnScreenPace"

    private let services: StartupServicesStore
    private let sampler = ActivitySampler()
    private let queue = DispatchQueue(label: "io.github.sergkhl.MacHelm.activity", qos: .utility)
    private let signals = DarwinProcessTransport()
    private let terminator: ProcessTerminator
    private var timer: Timer?
    private var sampling = false
    private var listsOnScreen = false
    private var menuOpen = false
    // The latest reading while nothing watched, kept for whoever looks next.
    private var unranked: ActivityReading?

    init(services: StartupServicesStore) {
        self.services = services
        terminator = ProcessTerminator(transport: signals, ownPID: getpid())
        let defaults = UserDefaults.standard
        windowLength = Self.saved(Self.windowKey, among: ActivityWindow.lengths, in: defaults) ?? ActivityWindow.defaultLength
        backgroundPace = Self.saved(Self.backgroundKey, among: ActivityPace.background, in: defaults) ?? ActivityPace.defaultBackground
        onScreenPace = Self.saved(Self.onScreenKey, among: ActivityPace.onScreen, in: defaults) ?? ActivityPace.defaultOnScreen
        schedule()
        sample()
    }

    private static func saved(_ key: String, among offered: [TimeInterval], in defaults: UserDefaults) -> TimeInterval? {
        (defaults.object(forKey: key) as? Double).flatMap { offered.contains($0) ? $0 : nil }
    }

    private func changed(_ value: TimeInterval, from old: TimeInterval, key: String) {
        guard value != old else { return }
        UserDefaults.standard.set(value, forKey: key)
        schedule()
    }

    // MARK: Reading

    // A page that shows the lists came on screen, or left it.
    func setListsOnScreen(_ on: Bool) {
        guard on != listsOnScreen else { return }
        listsOnScreen = on
        watchingChanged()
    }

    func setMenuOpen(_ open: Bool) {
        guard open != menuOpen else { return }
        menuOpen = open
        watchingChanged()
    }

    private func watchingChanged() {
        schedule()
        // Whoever starts to look gets what was read meanwhile, and a reading
        // at once, not at the next background tick.
        if listsOnScreen || menuOpen {
            bringUpToDate()
            sample()
        }
    }

    // Ranks what was read while nothing watched. The menu bar menu asks
    // before it is built, which is before it counts as open.
    func bringUpToDate() {
        guard let reading = unranked else { return }
        unranked = nil
        let roots = serviceRoots
        show(reading.averages.map { ActivityRanking.snapshot(of: $0, services: roots, ownPID: getpid()) }, reading.load)
    }

    private func show(_ ranked: ActivitySnapshot?, _ read: SystemLoad) {
        if ranked != snapshot { snapshot = ranked }
        if read != load { load = read }
    }

    private var serviceRoots: [ServiceRoot] {
        services.services.compactMap { status -> ServiceRoot? in
            guard case .running(let pid) = status.activity else { return nil }
            return ServiceRoot(id: status.id, name: status.definition.name, pid: pid, canStop: status.actions.contains(.stop))
        }
    }

    private func schedule() {
        let interval = ActivityPace.interval(watched: listsOnScreen || menuOpen, background: backgroundPace, onScreen: onScreenPace,
                                             window: windowLength)
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = interval / 10
        // Common modes, so the lists keep moving while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        // A read that takes longer than the pace is not doubled.
        guard !sampling else { return }
        sampling = true
        let ranking = listsOnScreen || menuOpen ? (services: serviceRoots, ownPID: getpid()) : nil
        let length = windowLength
        queue.async { [sampler] in
            let read = sampler.sample(length: length, ranking: ranking)
            Task { @MainActor in
                self.sampling = false
                if let ranked = read.ranked {
                    self.unranked = nil
                    self.show(ranked, read.load)
                } else {
                    self.unranked = read
                    // Someone began to look while it was read.
                    if self.listsOnScreen || self.menuOpen { self.bringUpToDate() }
                }
            }
        }
    }

    // MARK: Actions

    // An app is asked to quit, as ⌘Q asks it. Anything else gets the terminate
    // signal. Returns false, having done nothing, when the owner has to be
    // asked first: a bundle with nobody in it to ask and several processes to signal.
    @discardableResult
    func quit(_ row: ActivityRow, confirmed: Bool = false) -> Bool {
        notice = nil
        if case .app(let bundlePath) = row.group.kind {
            let apps = applications(among: row.members)
            let asked = Set(ProcessActionPolicy.appsToAsk(toQuit: bundlePath, among: apps.map(\.info)))
            if !asked.isEmpty {
                let taken = apps.filter { asked.contains($0.info.identity) }.filter { $0.app.terminate() }
                if taken.isEmpty { notice = "\(row.group.name) did not take the request to quit." }
                return true
            }
            if !confirmed, ProcessActionPolicy.asksFirst(.quit, in: row.group, members: row.members.count, canBeAsked: false) {
                return false
            }
        }
        report(terminator.terminate(row.members, force: false), name: row.group.name)
        return true
    }

    func forceQuit(_ row: ActivityRow) {
        notice = nil
        report(terminator.terminate(row.members, force: true), name: row.group.name)
    }

    func forceQuit(_ process: ActivityProcessRow) {
        notice = nil
        report(terminator.terminate([process.identity], force: true), name: process.name)
    }

    func stopService(_ id: String) {
        notice = nil
        services.perform(.stop, on: id)
    }

    func clearNotice() {
        notice = nil
    }

    // The apps among the processes a row showed, each checked to be the same process still.
    private func applications(among members: [ProcessIdentity]) -> [(info: RunningApp, app: NSRunningApplication)] {
        members.compactMap { member in
            guard let app = NSRunningApplication(processIdentifier: member.pid), let bundle = app.bundleURL,
                  signals.startTime(of: member.pid) == member.startedAt else { return nil }
            return (RunningApp(identity: member, bundlePaths: [bundle.path, bundle.resolvingSymlinksInPath().path],
                               isUserFacing: app.activationPolicy != .prohibited), app)
        }
    }

    private func report(_ result: ProcessTermination, name: String) {
        // Helpers that ended by themselves in the meantime are no news.
        if result.signalled.isEmpty { notice = "Nothing was ended: \(name) had already quit, or macOS refused." }
    }
}
