import AppKit
import Combine

@MainActor
final class ClaudeStore: ObservableObject {
    @Published private(set) var snapshot: ClaudeSnapshot?
    @Published private(set) var refreshingOnShow = false
    @Published private(set) var opening: ClaudeConversationID?
    @Published private(set) var feedback: Feedback?

    struct Feedback {
        let id: ClaudeConversationID
        let text: String
    }

    private let activity: ActivityStore
    private let discovery = ClaudeDiscovery()
    private let opener = ClaudeSessionOpener()
    private var reconciler = ClaudeReconciler()
    private var refreshTask: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    private var installation: ClaudeInstallation?

    init(activity: ActivityStore) {
        self.activity = activity
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
        if let existing = refreshTask {
            await existing.value
            return
        }
        let pending = Task { [discovery] in
            let processes = await activity.readProcesses()
            let (installation, frame) = await Task.detached(priority: .utility) {
                let installation = ClaudeInstallation()
                return (installation, discovery.read(pass: processes, installation: installation))
            }.value
            self.installation = installation
            let next = reconciler.update(frame)
            if next != snapshot { snapshot = next }
            if refreshingOnShow { refreshingOnShow = false }
            refreshTask = nil
        }
        refreshTask = pending
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
        Task {
            await refresh()
            defer { opening = nil }
            guard let current = reconciler.active[row.id], let installation else {
                feedback = Feedback(id: row.id, text: "This session is no longer available.")
                return
            }
            let message = await opener.perform(action, for: current, installation: installation)
            if let message { feedback = Feedback(id: row.id, text: message) }
        }
    }
}
