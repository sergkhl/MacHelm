import SwiftUI

struct ClaudePage: View {
    @ObservedObject var store: ClaudeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = store.snapshot {
                let waiting = snapshot.conversations.filter { $0.activity == .needsInput }
                if !waiting.isEmpty {
                    ToolPanel(title: "Needs input", symbol: "person.crop.circle.badge.exclamationmark") {
                        rows(waiting, jobs: { _ in [] })
                    }
                }
                let runningShell = snapshot.conversations.filter { $0.jobs.contains(where: \.isShell) }
                ToolPanel(title: "Running shell work", symbol: "terminal") {
                    Text("Claude’s full task list is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                    if runningShell.isEmpty {
                        Text("No verified shell work to show.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        rows(runningShell, jobs: { $0.jobs.filter(\.isShell) })
                    }
                }
                let other = snapshot.conversations.filter { row in
                    row.jobs.contains { !$0.isShell } || (row.detached && row.activity != .needsInput && row.jobs.isEmpty)
                }
                if !other.isEmpty {
                    ToolPanel(title: "Background Work", symbol: "square.stack.3d.up") {
                        rows(other, jobs: { $0.jobs.filter { !$0.isShell } })
                    }
                }
            } else {
                ToolPanel(title: "Running shell work", symbol: "terminal") {
                    Text("Reading Claude sessions…").font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                }
            }
            if let snapshot = store.snapshot {
                if store.refreshingOnShow {
                    Text("Refreshing the last reading…").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(notices(for: snapshot), id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                }
                if let feedback = store.feedback, !snapshot.conversations.contains(where: { $0.id == feedback.id }) {
                    Text(feedback.text).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Open a conversation to view output, see in-process tasks, or stop work in Claude’s Background tasks pane or with `/tasks`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rows(_ conversations: [ClaudeConversation], jobs: @escaping (ClaudeConversation) -> [ClaudeJob]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(conversations) { row in
                if row.id != conversations.first?.id { Divider() }
                ClaudeConversationRow(row: row, jobs: jobs(row), store: store)
            }
        }
        .padding(.bottom, 4)
    }

    private func notices(for snapshot: ClaudeSnapshot) -> [String] {
        var messages: [String] = []
        switch snapshot.inventory {
        case .missingExecutable: messages.append("Claude Code was not found. Detached sessions and session states may be incomplete.")
        case .unavailable: messages.append("Couldn’t read sessions with \(store.cliCommand.name). Session states may be out of date.")
        case .partial: messages.append("Claude’s session list is incomplete. Some session states may be out of date.")
        case .complete: break
        }
        if snapshot.registrations != .complete { messages.append("Some Claude registrations are unavailable. Session opening may be limited.") }
        if snapshot.processes == .unavailable { messages.append("Process readings are unavailable. Job details may be out of date.") }
        if snapshot.processes == .partial { messages.append("Some process details are unavailable.") }
        if snapshot.taskRecords != .complete { messages.append("Some Claude task records are unavailable.") }
        return messages
    }
}

private struct ClaudeConversationRow: View {
    let row: ClaudeConversation
    let jobs: [ClaudeJob]
    @ObservedObject var store: ClaudeStore
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold)).frame(width: 12).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.subheadline.weight(.medium)).lineLimit(1).help(row.title)
                            if let path = row.path {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(path)
                            }
                            if row.activity == .needsInput, let date = row.createdAt {
                                Text("Created \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide details for \(row.title)" : "Show details for \(row.title)")

                if row.id != .unknown {
                    Text(row.activity.rawValue).font(.caption)
                        .foregroundStyle(row.activity == .needsInput ? Color.orange : Color.secondary)
                        .fixedSize()
                }
                let action = store.action(for: row)
                if let action {
                    Button(action.title) { store.perform(action, for: row) }
                        .controlSize(.small)
                        .disabled(store.opening != nil)
                        .accessibilityLabel("\(action.title) for \(row.title)")
                }
                actions(excluding: action)
            }
            if case .terminal(let terminal) = row.location, let terminal {
                Text(terminal.name).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            }
            if let feedback = store.feedback, feedback.id == row.id {
                Text(feedback.text).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            }
            if expanded { details.padding(.leading, 20) }
            ForEach(jobs) { job in
                ClaudeJobRow(job: job).padding(.leading, 20)
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func actions(excluding action: ClaudeSessionAction?) -> some View {
        let attach = if case .detached = row.location { action != .copyAttachCommand } else { false }
        let copyID = row.sessionID != nil && action != .copySessionID && row.activity != .closed
        if attach || copyID {
            Menu {
                if attach {
                    Button(ClaudeSessionAction.copyAttachCommand.title) { store.perform(.copyAttachCommand, for: row) }
                }
                if copyID {
                    Button(ClaudeSessionAction.copySessionID.title) { store.perform(.copySessionID, for: row) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(row.title)")
            .disabled(store.opening != nil)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let path = row.path { detail("Path", path) }
            if let id = row.sessionID { detail("Session ID", id.uuidString.lowercased()) }
            if let worker = row.worker { detail("Session worker PID", String(worker.pid)) }
            if row.activity == .needsInput, let waiting = row.waitingFor { detail("Waiting for", waiting) }
        }
        .accessibilityElement(children: .contain)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }
}

private struct ClaudeJobRow: View {
    let job: ClaudeJob
    @State private var expanded = false

    private var title: String {
        job.title ?? (job.isShell ? "Shell job" : (job.processes.first?.name ?? "Process"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).frame(width: 12).accessibilityHidden(true)
                    Text(verbatim: title).font(.callout).lineLimit(1).help(title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide workers for \(title)" : "Show workers for \(title)")

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    if job.processes.isEmpty {
                        Text("Worker PID unavailable").foregroundStyle(.secondary)
                    }
                    ForEach(job.processes) { process in
                        HStack(spacing: 6) {
                            Text(process.name).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: "PID \(process.id.pid)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.caption)
                .padding(.leading, 20)
            }
        }
    }
}
