import AppKit
import Combine

@MainActor
final class ClaudeStore: ObservableObject {
    @Published private(set) var snapshot: ClaudeSnapshot?
    @Published private(set) var refreshingOnShow = false
    @Published private(set) var opening: ClaudeConversationID?
    @Published private(set) var feedback: Feedback?
    @Published private(set) var cliCommand: ClaudeCLICommand

    struct Feedback {
        let id: ClaudeConversationID
        let text: String
    }

    private let activity: ActivityStore
    private let defaults: UserDefaults
    private let discovery = ClaudeDiscovery()
    private let opener = ClaudeSessionOpener()
    private var reconciler = ClaudeReconciler()
    private static let cliCommandKey = "ClaudeCLICommand"
    private var commandGeneration = 0
    private var refreshTask: (generation: Int, task: Task<Void, Never>)?
    private var watching: Task<Void, Never>?
    private var installation: ClaudeInstallation?

    init(activity: ActivityStore, defaults: UserDefaults = .standard) {
        self.activity = activity
        self.defaults = defaults
        cliCommand = defaults.string(forKey: Self.cliCommandKey).flatMap(ClaudeCLICommand.init) ?? .standard
    }

    func saveCLICommand(_ command: ClaudeCLICommand) {
        guard command != cliCommand else { return }
        defaults.set(command.name, forKey: Self.cliCommandKey)
        cliCommand = command
        commandGeneration += 1
        reconciler = ClaudeReconciler()
        installation = nil
        snapshot = nil
        feedback = nil
        if watching != nil {
            Task { await refresh() }
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            guard watching == nil else { return }
            if snapshot != nil { refreshingOnShow = true }
            watching = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } else {
            watching?.cancel()
            watching = nil
        }
    }

    private func refresh() async {
        while let existing = refreshTask {
            await existing.task.value
            if existing.generation == commandGeneration { return }
        }
        let generation = commandGeneration
        let command = cliCommand
        let pending = Task { [discovery] in
            let processes = await activity.readProcesses()
            let (installation, frame) = await Task.detached(priority: .utility) {
                let installation = ClaudeInstallation(command: command)
                return (installation, discovery.read(pass: processes, installation: installation))
            }.value
            refreshTask = nil
            guard generation == commandGeneration else { return }
            self.installation = installation
            let next = reconciler.update(frame)
            if next != snapshot { snapshot = next }
            if refreshingOnShow { refreshingOnShow = false }
        }
        refreshTask = (generation, pending)
        await pending.value
    }

    func action(for conversation: ClaudeConversation) -> ClaudeSessionAction? {
        opener.action(for: conversation, installation: installation)
    }

    func perform(_ action: ClaudeSessionAction, for row: ClaudeConversation) {
        guard opening == nil else { return }
        feedback = nil
        if action == .copySessionID, let id = row.sessionID {
            opener.copy(id.uuidString.lowercased())
            feedback = Feedback(id: row.id, text: "Session ID copied.")
            return
        }
        opening = row.id
        let generation = commandGeneration
        Task {
            await refresh()
            defer { opening = nil }
            guard generation == commandGeneration else { return }
            guard let current = reconciler.active[row.id], let installation else {
                feedback = Feedback(id: row.id, text: "This session is no longer available.")
                return
            }
            let message = await opener.perform(action, for: current, installation: installation)
            if generation == commandGeneration, let message { feedback = Feedback(id: row.id, text: message) }
        }
    }
}
