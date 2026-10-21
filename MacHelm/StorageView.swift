import SwiftUI

private func size(_ kilobytes: Int?) -> String {
    kilobytes.map { Int64($0 * 1_024).formatted(.byteCount(style: .file)) } ?? "unknown"
}

// A group's or kind's total: "at least" where a target cannot say, and
// "unknown" where none can.
private func amount(_ total: (kilobytes: Int, atLeast: Bool)) -> String {
    if total.atLeast && total.kilobytes == 0 { return "unknown" }
    return "\(total.atLeast ? "≥ " : "")\(size(total.kilobytes))"
}

private func space(_ bytes: Int64?) -> String {
    bytes.map { $0.formatted(.byteCount(style: .file)) } ?? "unknown"
}

// The startup disk's available space, as the Overview and the Storage page both show it.
struct AvailableSpaceLine: View {
    @ObservedObject var storage: StorageService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(space(storage.available)) available").font(.subheadline)
                Spacer(minLength: 8)
                Text("of \(space(storage.capacity))").font(.caption).foregroundStyle(.secondary)
            }
            if let available = storage.available, let capacity = storage.capacity, capacity > 0 {
                ProgressView(value: Double(capacity - available), total: Double(capacity))
                    .accessibilityLabel("Used space")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

// The Overview's share of Storage: available space and what the last scan found.
struct StorageOverviewCard: View {
    @ObservedObject var storage: StorageService
    let openStorage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AvailableSpaceLine(storage: storage)
            HStack(alignment: .firstTextBaseline) {
                Text(lastScan).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open Storage", action: openStorage).controlSize(.small)
            }
            .padding(.vertical, 8)
        }
        .onAppear { storage.refreshSpace() }
    }

    private var lastScan: String {
        guard let at = storage.scannedAt else { return "Not scanned yet. A scan runs only when you ask for it." }
        let defaults = StorageSelection(defaultsOf: storage.targets, helperReady: storage.helperReady).total(in: storage.targets)
        return "Scanned \(at.formatted(.relative(presentation: .named))): \(size(defaults.kilobytes)) can be reclaimed safely."
    }
}

// The Storage page: available space, and the cleanup script's scan and clean
// as two separate presses.
struct StoragePage: View {
    @ObservedObject var storage: StorageService
    @State private var confirming = false
    // Kinds start folded, with their totals (ADR 0008).
    @State private var unfolded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolPanel(title: "Startup Disk", symbol: "internaldrive") {
                AvailableSpaceLine(storage: storage)
            }
            ToolPanel(title: "Cleanup", symbol: "shippingbox") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(state).font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if storage.phase == .idle {
                            Button("Scan") { storage.scan() }
                                .accessibilityIdentifier("storage-scan")
                        } else {
                            Button("Stop") { storage.cancel() }
                        }
                    }
                    .controlSize(.small)
                    .padding(.vertical, 8)
                    if storage.phase != .idle {
                        StorageActivity(cleaning: storage.phase == .cleaning, progress: storage.progress,
                                        now: StorageActivity.steps(of: storage.removing, working: storage.working),
                                        failed: storage.results.values.filter { !$0.ok }.count)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Stepper(value: $storage.idleDays, in: StorageIdle.days) {
                            Text("Idle for at least \(storage.idleDays) \(storage.idleDays == 1 ? "day" : "days")").font(.subheadline)
                        }
                        .disabled(storage.phase != .idle)
                        .accessibilityIdentifier("storage-idle-days")
                        Text("Codex chats, Claude Code sessions and worktrees left alone this long are listed. A change applies at the next scan.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .controlSize(.small)
                    .padding(.bottom, 8)
                    if storage.needsFullDiskAccess {
                        Divider()
                        HStack(alignment: .firstTextBaseline) {
                            Label("Full Disk Access is off: device backups and the Trash can't be measured, and some app data can't be read.",
                                  systemImage: "lock.shield")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button("Open Settings…") { storage.openFullDiskAccessSettings() }
                                .controlSize(.small)
                                .help("Switch MacHelm on under Full Disk Access, then scan again.")
                        }
                        .padding(.vertical, 8)
                    }
                    ForEach(StorageTree.groups(storage.targets)) { group in
                        Divider()
                        StorageParentRow(storage: storage, title: group.name, children: group.targets, isGroup: true)
                            .padding(.top, 8).padding(.bottom, 2)
                        ForEach(group.entries) { entry in
                            switch entry {
                            case .target(let target):
                                StorageTargetRow(storage: storage, target: target)
                            case .kind(let kind):
                                StorageParentRow(storage: storage, title: kind.name, children: kind.targets, isGroup: false,
                                                 unfolded: Binding(get: { unfolded.contains(kind.id) },
                                                                   set: { if $0 { unfolded.insert(kind.id) } else { unfolded.remove(kind.id) } }))
                                if unfolded.contains(kind.id) {
                                    ForEach(kind.targets) { target in
                                        StorageTargetRow(storage: storage, target: target).padding(.leading, 22)
                                    }
                                }
                            }
                        }
                    }
                    if !storage.targets.isEmpty {
                        Divider()
                        HStack(alignment: .firstTextBaseline) {
                            Text(selected).font(.subheadline)
                            Spacer(minLength: 8)
                            Button("Select All") { storage.selectAll() }
                                .disabled(storage.phase != .idle || storage.allSelected)
                                .accessibilityIdentifier("storage-select-all")
                            Button("Select None") { storage.selectNone() }
                                .disabled(storage.phase != .idle || storage.selection.keys.isEmpty)
                                .accessibilityIdentifier("storage-select-none")
                            Button("Clean…") { confirming = true }
                                .disabled(storage.phase != .idle || storage.chosen.isEmpty)
                                .accessibilityIdentifier("storage-clean")
                        }
                        .controlSize(.small)
                        .padding(.vertical, 8)
                    }
                }
            }
            if let report = storage.report {
                LastCleanPanel(report: report)
            }
            if let notice = storage.notice {
                Label(notice, systemImage: "exclamationmark.triangle").font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { storage.refreshSpace() }
        // Q24: Clean always asks first, with what goes and the total.
        .sheet(isPresented: $confirming) {
            CleanConfirmation(chosen: storage.chosen, total: selected) { storage.clean() }
        }
    }

    private var state: String {
        switch storage.phase {
        case .scanning: return "Scanning: measuring what can be cleaned. Nothing is removed."
        case .cleaning: return "Removing what you checked…"
        case .idle:
            guard let at = storage.scannedAt else { return "Not scanned yet. A scan lists and measures; it removes nothing." }
            return "Scanned \(at.formatted(date: .omitted, time: .shortened)): \(storage.targets.count) found."
        }
    }

    private var selected: String {
        let total = storage.selection.total(in: storage.chosen)
        return "Checked: \(total.atLeast ? "at least " : "")\(size(total.kilobytes))"
    }
}

// Clean's question (Q24): what goes and the total. An alert grew with its
// text until a long selection pushed its buttons off the screen, and Return
// pressed its first button, Remove. Here what goes scrolls inside a bounded
// list, grouped as the page groups it, the buttons stay in view, and only
// Escape has a key: Cancel. What cannot be restored is named under its own
// warning (ADR 0008).
private struct CleanConfirmation: View {
    let chosen: [StorageTarget]
    let total: String
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var listHeight: CGFloat = 0

    // The script's group for chats, sessions, worktrees, backups and the Trash.
    private static let cannotBeRestored = "cannot be restored"
    // Tall enough to show a dozen lines, short enough for the smallest screen.
    private static let listLimit: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(chosen.count == 1 ? "1 target" : "\(chosen.count) targets")?").font(.headline)
            Text("\(total). What is removed is gone for good; it does not go to the Trash.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            let own = chosen.filter { $0.group == Self.cannotBeRestored }
            if !own.isEmpty {
                Label("\(own.count == 1 ? "1 of them cannot" : "\(own.count) of them cannot") be restored once removed: chats, sessions, worktrees, backups or app data, listed first.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            amountLine(group.name, group.targets, font: .caption)
                                .foregroundStyle(.secondary)
                            ForEach(group.entries) { entry in
                                switch entry {
                                case .target(let target):
                                    amountLine(target.label, [target], font: .subheadline)
                                case .kind(let kind):
                                    VStack(alignment: .leading, spacing: 1) {
                                        amountLine("\(kind.name) (\(kind.targets.count))", kind.targets, font: .subheadline)
                                        Text(kind.targets.map(\.label).joined(separator: ", "))
                                            .font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.leading, 12)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ConfirmationListHeight.self, value: proxy.size.height)
                })
            }
            .frame(height: min(listHeight, Self.listLimit))
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .onPreferenceChange(ConfirmationListHeight.self) { listHeight = $0 }
            .accessibilityLabel("What Clean removes")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    dismiss()
                    remove()
                }
                .accessibilityIdentifier("storage-clean-remove")
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    // As the page groups them, with what cannot be restored first.
    private var groups: [StorageGroup] {
        let all = StorageTree.groups(chosen)
        return all.filter { $0.name == Self.cannotBeRestored } + all.filter { $0.name != Self.cannotBeRestored }
    }

    private func amountLine(_ title: String, _ targets: [StorageTarget], font: Font) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(font)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(amount(StorageTree.size(of: targets))).font(font).monospacedDigit()
        }
    }
}

// What the last Clean did: the total, and each target it did not remove, or
// removed only in part, with the script's reason. A row whose files all went
// is not listed by the scan that follows, so the reasons stay here until the
// next Scan or Clean.
private struct LastCleanPanel: View {
    let report: StorageCleanReport
    @State private var showsAll = false

    // Enough to see what went wrong at a glance; the rest unfold.
    private static let shown = 3

    var body: some View {
        ToolPanel(title: "Last Clean", symbol: report.failures == 0 ? "checkmark.circle" : "exclamationmark.triangle",
                  detail: report.reclaimed) {
            VStack(alignment: .leading, spacing: 8) {
                Text(report.outcome).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(showsAll ? report.notRemoved : Array(report.notRemoved.prefix(Self.shown))) { failure in
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(failure.title).font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(failure.outcome).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
                if report.notRemoved.count > Self.shown {
                    Button(showsAll ? "Show fewer" : "Show \(report.notRemoved.count - Self.shown) more") { showsAll.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct ConfirmationListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// What a running scan or clean is doing, from the script's own reports: how
// far it has got, and during a clean each target being removed now with its
// latest step. Rows in a folded kind are out of sight, so this names them.
private struct StorageActivity: View {
    struct Step: Equatable {
        var key: String
        var label: String
        var step: String
    }

    let cleaning: Bool
    let progress: StorageProgress?
    let now: [Step]
    let failed: Int

    // The targets being removed, in the list's order, with the kind in front where the row has one.
    static func steps(of removing: [StorageTarget], working: [String: String]) -> [Step] {
        removing.compactMap { target in
            working[target.key].map { Step(key: target.key, label: target.kind.isEmpty ? target.label : "\(target.kind): \(target.label)", step: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress, progress.total > 0 {
                ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
                    .accessibilityLabel(caption(progress))
                Text(caption(progress)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Until the script's first count arrives.
                ProgressView().progressViewStyle(.linear)
            }
            ForEach(now, id: \.key) { item in
                HStack(alignment: .center, spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(item.label).font(.subheadline).lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                    Text(item.step.isEmpty ? "starting…" : item.step)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.bottom, 8)
    }

    private func caption(_ progress: StorageProgress) -> String {
        guard cleaning else {
            return "\(progress.done) of \(progress.total) checks and measurements done."
        }
        guard progress.removing else {
            return "Checking that what you chose is still there: \(progress.done) of \(progress.total) checks and measurements."
        }
        return "Finished \(progress.done) of \(progress.total)\(failed > 0 ? "; \(failed) not removed" : "")."
    }
}

// A group's or kind's row: a checkbox for everything below it that may be
// checked, its name and its total. A kind also folds (ADR 0008).
private struct StorageParentRow: View {
    @ObservedObject var storage: StorageService
    let title: String
    let children: [StorageTarget]
    let isGroup: Bool
    var unfolded: Binding<Bool>?

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let unfolded {
                Button { unfolded.wrappedValue.toggle() } label: {
                    Image(systemName: unfolded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2).frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(unfolded.wrappedValue ? "Fold \(title)" : "Unfold \(title)")
            }
            let state = storage.checkState(of: children)
            if state != .unavailable {
                MixedCheckbox(state: state, label: title, enabled: storage.phase == .idle) { checked in
                    storage.setChecked(checked, children: children)
                }
                .fixedSize()
            }
            Group {
                if isGroup {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(title) (\(children.count))").font(.subheadline)
                }
            }
            .lineLimit(1).truncationMode(.middle)
            .contentShape(Rectangle())
            .onTapGesture { unfolded?.wrappedValue.toggle() }
            Spacer(minLength: 8)
            Text(amount(StorageTree.size(of: children)))
                .font(isGroup ? .caption : .subheadline).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, isGroup ? 0 : 3)
    }
}

// A checkbox that also shows "some": SwiftUI's own cannot, so AppKit's does.
private struct MixedCheckbox: NSViewRepresentable {
    let state: StorageSelection.CheckState
    let label: String
    let enabled: Bool
    // true checks everything below, false clears it.
    let action: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        button.allowsMixedState = true
        button.controlSize = .small
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.state = state == .checked ? .on : state == .mixed ? .mixed : .off
        button.isEnabled = enabled
        button.setAccessibilityLabel(label)
    }

    final class Coordinator: NSObject {
        var parent: MixedCheckbox?

        @MainActor @objc func pressed(_ button: NSButton) {
            guard let parent else { return }
            // From none or some, check all; from all, clear. AppKit would cycle
            // through "some" on its own, so the box shows the outcome at once
            // and the model's next update confirms it.
            let checking = parent.state != .checked
            parent.action(checking)
            button.state = checking ? .on : .off
        }
    }
}

private struct StorageTargetRow: View {
    @ObservedObject var storage: StorageService
    let target: StorageTarget

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if StorageSelection.canSelect(target, helperReady: storage.helperReady) {
                Toggle(target.label, isOn: Binding(get: { storage.selection.keys.contains(target.key) }, set: { _ in storage.toggle(target.key) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(storage.phase != .idle)
                    .accessibilityLabel(target.label)
            } else {
                Image(systemName: target.state == .reportOnly ? "eye" : target.needsFullDiskAccess ? "lock.shield" : "lock")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(target.label).font(.subheadline).lineLimit(1).truncationMode(.middle)
                if let line = note {
                    Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(line)
                }
            }
            Spacer(minLength: 8)
            // A root target the app cannot remove offers the command for a terminal (Q25).
            if StorageSelection.needsTerminal(target, helperReady: storage.helperReady) {
                Button("Copy command") { storage.copyCommand(for: target) }.controlSize(.mini)
            }
            Text(value).font(.subheadline).monospacedDigit()
                .foregroundStyle(target.state == .selectable ? .primary : .secondary)
        }
        .padding(.vertical, 3)
    }

    // What the latest Clean did to it, or else what the script says about it.
    private var note: String? {
        if let step = storage.working[target.key] {
            return step.isEmpty ? "Removing…" : "Removing: \(step)"
        }
        if let result = storage.results[target.key] {
            return result.note
        }
        if StorageSelection.needsTerminal(target, helperReady: storage.helperReady) {
            return "Needs root. " + (storage.helperReady ? "It lies outside the folders the toolkit helper may clean." : "Set up the toolkit helper on the Power page, or run the command in a terminal.")
        }
        return target.detail.isEmpty ? nil : target.detail
    }

    private var value: String {
        // What removing it frees where that is known, else what it occupies.
        guard target.state == .selectable else { return size(target.sizeKB) }
        if let projected = target.projectedKB { return size(projected) }
        // The Trash without Full Disk Access: Finder empties it, but nobody can say how much it holds.
        return target.sizeKB == nil ? "unknown" : "\(size(target.sizeKB)) used"
    }
}
