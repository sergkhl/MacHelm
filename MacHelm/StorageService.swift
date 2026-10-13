import AppKit
import Combine

struct StorageResult: Equatable {
    var ok: Bool
    var freedKB: Int?
    var error: String?
}

// Storage: the startup disk's available space, and the cleanup script's scan
// and clean. Nothing is scanned or removed unless the owner presses for it.
@MainActor
final class StorageService: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning, cleaning
    }

    // In bytes: the figure Finder shows, and the disk's size.
    @Published private(set) var available: Int64?
    @Published private(set) var capacity: Int64?
    @Published private(set) var targets: [StorageTarget] = []
    @Published private(set) var scannedAt: Date?
    @Published private(set) var selection = StorageSelection()
    @Published private(set) var phase: Phase = .idle
    // What the latest Clean did, by target.
    @Published private(set) var results: [String: StorageResult] = [:]
    @Published private(set) var summary: String?
    @Published private(set) var notice: String?

    private let power: PowerService
    // The script's run, through the owner's login shell (`StorageRunner`, in the tested package).
    private var run: StorageRunner?
    // What the owner confirmed for the Clean that runs: only these may ask for a root removal.
    private var confirmed: [StorageTarget] = []

    init(power: PowerService) {
        self.power = power
        refreshSpace()
    }

    var helperReady: Bool { power.helper == .ready }

    // The script as it ships in the app. Run in a terminal it works as before.
    var scriptPath: String? { Bundle.main.path(forResource: "cleanup-macos-dev", ofType: "py") }

    func refreshSpace() {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                                              .volumeTotalCapacityKey])
        available = values?.volumeAvailableCapacityForImportantUsage
        capacity = values?.volumeTotalCapacity.map(Int64.init)
    }

    // MARK: Scan

    // Lists and measures; removes nothing.
    func scan() {
        guard phase == .idle else { return }
        notice = nil
        summary = nil
        results = [:]
        start(select: nil, phase: .scanning)
    }

    // L4: at Quit a scan or a clean that runs is ended at once.
    func endForQuit() {
        run?.end()
    }

    // MARK: Selection

    func toggle(_ key: String) {
        guard phase == .idle else { return }
        selection.toggle(key, in: targets, helperReady: helperReady)
    }

    func selectAll() {
        guard phase == .idle else { return }
        selection.selectAll(in: targets, helperReady: helperReady)
    }

    func selectNone() {
        guard phase == .idle else { return }
        selection.selectNone()
    }

    // Whether everything that may be checked is.
    var allSelected: Bool { selection.holdsAll(in: targets, helperReady: helperReady) }

    var chosen: [StorageTarget] {
        selection.chosen(in: targets).filter { StorageSelection.canSelect($0, helperReady: helperReady) }
    }

    // MARK: Clean

    // Removes what is checked. The page asks first; what is removed is gone for good.
    func clean() {
        guard phase == .idle else { return }
        let chosen = chosen
        guard !chosen.isEmpty else { return }
        notice = nil
        summary = nil
        results = [:]
        confirmed = chosen
        start(select: chosen.map(\.key), phase: .cleaning)
    }

    func cancel() {
        run?.cancel()
    }

    // The command for a terminal, for a root target the app cannot remove itself.
    func copyCommand(for target: StorageTarget) {
        guard let scriptPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("'\(scriptPath)' --select '\(target.key)'", forType: .string)
    }

    // MARK: The script

    private func start(select keys: [String]?, phase: Phase) {
        guard let scriptPath else {
            notice = "This copy of MacHelm does not hold the cleanup script."
            return
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let run = StorageRunner()
        self.run = run
        self.phase = phase
        var listed = false
        let command = StorageProtocol.command(shell: shell, script: scriptPath, select: keys)
        let started = run.start(executable: command.executable, arguments: command.arguments,
                                directory: FileManager.default.homeDirectoryForCurrentUser, event: { [weak self] event in
            MainActor.assumeIsolated {
                if case .targets = event { listed = true }
                self?.handle(event, from: run)
            }
        }, ended: { [weak self] status, errors in
            MainActor.assumeIsolated { self?.ended(run, phase: phase, status: status, errors: errors, listed: listed) }
        })
        if !started {
            self.run = nil
            self.phase = .idle
            notice = "The cleanup script could not be started through \(shell)."
        }
    }

    private func handle(_ event: StorageEvent, from run: StorageRunner) {
        guard run === self.run else { return }
        switch event {
        case .targets(_, let listed):
            targets = listed
            scannedAt = Date()
            // A new list starts from the script's own defaults (Q24).
            selection = StorageSelection(defaultsOf: listed, helperReady: helperReady)
        case .removeRoot(let path):
            removeRoot(path, for: run)
        case .result(let key, let ok, let freedKB, let error):
            results[key] = StorageResult(ok: ok, freedKB: freedKB, error: error)
        case .done(let reclaimedKB, let failures, _):
            let reclaimed = Int64(reclaimedKB * 1_024).formatted(.byteCount(style: .file))
            summary = failures == 0 ? "Reclaimed \(reclaimed)." : "Reclaimed \(reclaimed). \(failures) did not complete; nothing else was affected."
        case .error(let message):
            notice = message
        }
    }

    // Q28 and Q33: the helper is asked only for a path the scan listed for a
    // root target the owner confirmed. Anything else is refused here, before
    // any root program hears of it.
    private func removeRoot(_ path: String, for run: StorageRunner) {
        guard RootRemovalPolicy.allows(path, confirmed: confirmed) else {
            return run.answer(StorageProtocol.reply(ok: false, error: "MacHelm did not list \(path) for a target you confirmed."))
        }
        guard helperReady else {
            return run.answer(StorageProtocol.reply(ok: false, error: "The toolkit helper is not set up."))
        }
        power.client.removeDirectory(atPath: path) { reply in
            let error = reply == nil ? "The toolkit helper did not answer." : reply?.error
            run.answer(StorageProtocol.reply(ok: error == nil, error: error))
        }
    }

    private func ended(_ run: StorageRunner, phase: Phase, status: Int32, errors: String, listed: Bool) {
        guard run === self.run else { return }
        self.run = nil
        self.phase = .idle
        confirmed = []
        refreshSpace()
        if notice == nil, phase == .scanning ? !listed : summary == nil {
            let said = errors.split(separator: "\n").last.map(String.init)
            notice = status == SIGTERM || status == SIGKILL ? "Stopped." : (said ?? "The cleanup script ended without a result (status \(status)).")
        }
        // Q24: after a clean a new scan follows, so the list shows what is left.
        // It keeps what the clean said: its results, its summary, and the reason if it was refused or stopped.
        if phase == .cleaning { start(select: nil, phase: .scanning) }
    }
}
