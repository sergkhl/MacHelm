import SwiftUI

extension ActivityMeasure {
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .energy: return "Energy"
        case .disk: return "Disk"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "display"
        case .energy: return "bolt"
        case .disk: return "internaldrive"
        }
    }

    // Every figure in the owner's own number format.
    func text(_ value: Double) -> String {
        switch self {
        case .cpu, .gpu: return (value / 100).formatted(.percent.precision(.fractionLength(value < 10 ? 1 : 0)))
        case .memory: return Int64(value).formatted(.byteCount(style: .memory, spellsOutZero: false))
        case .energy: return value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))) + " W"
        // Read and written together, each second.
        case .disk: return Int64(value).formatted(.byteCount(style: .file, spellsOutZero: false)) + "/s"
        }
    }

    // The whole Mac now, beside the list's title (Q34). nil where this Mac does not say.
    func total(_ load: SystemLoad) -> String? {
        guard let value = load.value(of: self) else { return nil }
        switch self {
        // On the rows' scale, so the title and the rows compare.
        case .cpu: return "\(text(value)) · \(load.cores) cores"
        case .memory: return load.memoryBytes.map { "\(text(value)) of \(text($0))" } ?? text(value)
        case .gpu, .energy, .disk: return text(value)
        }
    }
}

private extension ProcessGroupKind {
    // A word after the name where the name alone would mislead.
    var tag: String? {
        switch self {
        case .system: return "system"
        case .service: return "service"
        case .windowsProgram: return "Windows"
        case .wineBackground, .app, .process: return nil
        }
    }
}

// A request that asks first, with the row as it was shown when it was chosen.
private enum ActivityRequest: Identifiable {
    case quit(ActivityRow)
    case forceQuit(ActivityRow)
    case forceQuitProcess(ActivityProcessRow)

    var id: String {
        switch self {
        case .quit(let row): return "quit \(row.group.name) \(row.members.map(\.pid))"
        case .forceQuit(let row): return "force \(row.group.name) \(row.members.map(\.pid))"
        case .forceQuitProcess(let process): return "process \(process.identity.pid)"
        }
    }

    var title: String {
        switch self {
        case .quit(let row) where row.group.kind == .process: return "Quit the \(row.members.count) programs named \(row.group.name)?"
        case .quit(let row): return "Quit \(row.group.name)?"
        case .forceQuit(let row): return "Force Quit \(row.group.name)?"
        case .forceQuitProcess(let process): return "Force Quit \(process.name)?"
        }
    }

    var consequence: String {
        switch self {
        case .quit(let row) where row.group.kind == .process:
            return "They are separate programs that share a name. Each is asked to end, and what it was doing may be lost."
        case .quit(let row) where row.group.kind == .windowsProgram || row.group.kind == .wineBackground:
            return "A Windows program cannot be asked to save first. It ends, and progress that was not saved is lost."
        case .quit(let row):
            return "No app in it can be asked. Its \(row.members.count) processes get the terminate signal, and what they were doing may be lost."
        case .forceQuit(let row) where row.members.count > 1:
            return "Its \(row.members.count) processes end at once. Changes that were not saved are lost."
        case .forceQuit, .forceQuitProcess:
            return "It ends at once. Changes that were not saved are lost."
        }
    }

    var confirm: String {
        switch self {
        case .quit(let row): return row.members.count > 1 ? "Quit All" : "Quit"
        case .forceQuit, .forceQuitProcess: return "Force Quit"
        }
    }
}

// The Activity page: the five heaviest process groups for each measure,
// averaged over the window the owner chose.
struct ActivityPage: View {
    @ObservedObject var store: ActivityStore
    @State private var expanded: Set<String> = []
    @State private var request: ActivityRequest?
    // The order of the list under the pointer, held so that a press lands on the row aimed at.
    @State private var held: [ActivityMeasure: [ProcessGroupID]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                ForEach(ActivityMeasure.allCases, id: \.self) { measure in
                    ToolPanel(title: measure.title, symbol: measure.symbol, detail: store.load.flatMap { measure.total($0) }) { list(measure) }
                        .onHover { inside in
                            held[measure] = inside ? (store.snapshot?.rows[measure] ?? []).map(\.group) : nil
                        }
                }
            }
            if let notice = store.notice {
                HStack(alignment: .firstTextBaseline) {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.caption)
                    ToolIconButton("Dismiss", symbol: "xmark") { store.clearNotice() }.controlSize(.small)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                InfoButton(caption, label: "About activity readings")
                Spacer(minLength: 12)
                Text("Average").font(.caption).foregroundStyle(.secondary)
                Picker("Averaged over", selection: $store.windowLength) {
                    ForEach(ActivityWindow.lengths, id: \.self) { Text(ActivityText.span($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Averaged over")
                .accessibilityIdentifier("activity-window-length")
                ToolIconButton("Open Activity Monitor", symbol: "arrow.up.forward.app") {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                       configuration: NSWorkspace.OpenConfiguration())
                }
                .controlSize(.small)
            }
        }
        .confirmationDialog(request?.title ?? "", isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                            presenting: request) { request in
            Button(request.confirm, role: .destructive) {
                switch request {
                case .quit(let row): store.quit(row, confirmed: true)
                case .forceQuit(let row): store.forceQuit(row)
                case .forceQuitProcess(let process): store.forceQuit(process)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.consequence)
        }
    }

    // What the figures cover now: less than the window while it fills.
    private var caption: String {
        let covered = store.snapshot.map { "Averaged over the last \(ActivityText.span($0.seconds))." } ?? "Measuring…"
        return "Beside each title: the whole Mac now, its power as macOS last measured it, once a minute. " + covered
            + " Memory, Energy and Disk list your own processes; system processes appear under CPU and GPU only."
    }

    @ViewBuilder private func list(_ measure: ActivityMeasure) -> some View {
        if let ranked = store.snapshot?.rows[measure] {
            let rows = ActivityRanking.keeping(held[measure] ?? [], in: ranked)
            if rows.isEmpty {
                placeholder("Nothing to list.")
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        let key = "\(measure.rawValue) \(row.group)"
                        ActivityRowView(measure: measure, row: row, top: ranked.first?.value ?? 0,
                                        isExpanded: Binding(get: { expanded.contains(key) },
                                                            set: { open in if open { expanded.insert(key) } else { expanded.remove(key) } }),
                                        quit: { if !store.quit(row) { request = .quit(row) } }, stop: { store.stopService($0) },
                                        ask: { request = $0 })
                    }
                }
                .padding(.bottom, 8)
            }
        } else {
            placeholder("Measuring…")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

private struct ActivityRowView: View {
    let measure: ActivityMeasure
    let row: ActivityRow
    // The list's highest value, which is a full bar.
    let top: Double
    @Binding var isExpanded: Bool
    let quit: () -> Void
    let stop: (String) -> Void
    let ask: (ActivityRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button { isExpanded.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide the processes of \(row.group.name)" : "Show the processes of \(row.group.name)")

                Text(row.group.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                if let tag = row.ended ? "ended" : row.group.kind.tag {
                    Text(tag).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(measure.text(row.value)).font(.subheadline).monospacedDigit()
                actions
            }
            // Who started this copy of the app.
            if let origin = ActivityText.origin(row.group.origin) {
                Text(origin).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 18)
                    .help(origin)
            }
            Capsule().fill(.tint)
                .frame(height: 3)
                .scaleEffect(x: top > 0 ? max(0.01, min(1, row.value / top)) : 0, y: 1, anchor: .leading)
                .padding(.leading, 18)
                .accessibilityHidden(true)
            if isExpanded {
                ForEach(row.processes) { process in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(process.name).lineLimit(1).truncationMode(.middle)
                            // What a browser's helper does; which page a tab shows is not known outside the browser.
                            if let kind = process.kind { Text(kind).foregroundStyle(.secondary) }
                            Text(verbatim: "PID \(process.identity.pid)").foregroundStyle(.secondary)
                            if process.ended { Text("ended").foregroundStyle(.secondary) }
                            Spacer(minLength: 8)
                            Text(measure.text(process.value)).monospacedDigit()
                            if process.actions.contains(.forceQuit) {
                                Button("Force Quit…") { ask(.forceQuitProcess(process)) }
                                    .controlSize(.mini)
                                    .accessibilityLabel(Text(verbatim: "Force Quit \(process.name), process \(process.identity.pid)"))
                            }
                        }
                        // Who started it, where the row does not say so already. The tooltip holds the whole chain.
                        if let startedBy = ActivityText.startedBy(process, in: row.group) {
                            Text(startedBy).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(process.chain.isEmpty ? startedBy : process.chain.joined(separator: " ← "))
                        }
                    }
                    .font(.caption)
                    .padding(.leading, 18)
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([row.group.name, ActivityText.origin(row.group.origin), "\(measure.title) \(measure.text(row.value))"]
            .compactMap { $0 }.joined(separator: ", "))
    }

    // A protected row has none. Every entry names its row: the lists re-rank
    // at every reading, and the row under the pointer may not be the one aimed at.
    @ViewBuilder private var actions: some View {
        if row.actions.isEmpty {
            Color.clear.frame(width: 18, height: 1)
        } else {
            Menu {
                ForEach(row.actions.indices, id: \.self) { index in
                    switch row.actions[index] {
                    case .quit:
                        if ProcessActionPolicy.asksFirst(.quit, in: row.group, members: row.members.count) {
                            Button("Quit \(row.group.name)…") { ask(.quit(row)) }
                        } else {
                            Button("Quit \(row.group.name)", action: quit)
                        }
                    case .forceQuit: Button("Force Quit \(row.group.name)…") { ask(.forceQuit(row)) }
                    case .stopService(let id): Button("Stop \(row.group.name)") { stop(id) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 18)
            .accessibilityLabel("Actions for \(row.group.name)")
        }
    }
}

// The Overview's share of Activity: the heaviest process group for each measure.
struct ActivityOverviewCard: View {
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = store.snapshot {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 24, alignment: .top)], spacing: 0) {
                    ForEach(ActivityMeasure.allCases, id: \.self) { measure in
                        HStack(spacing: 8) {
                            Text(measure.title).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            if let row = snapshot.heaviest(measure) {
                                Text(row.group.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(measure.text(row.value)).font(.subheadline).monospacedDigit()
                            } else {
                                Text("Nothing to list").font(.subheadline).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.vertical, 5)
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Text("Measuring…").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            HStack {
                if let snapshot = store.snapshot {
                    Text("\(ActivityText.span(snapshot.seconds)) average")
                        .font(.caption).foregroundStyle(.secondary)
                }
                InfoButton("The heaviest process group for each measure, averaged over the window selected on the Activity page. CPU uses the percentage of one core; a group can exceed 100% when using multiple cores.",
                           label: "About activity readings")
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
    }
}
