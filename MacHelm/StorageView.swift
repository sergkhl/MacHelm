import SwiftUI

private func size(_ kilobytes: Int?) -> String {
    kilobytes.map { Int64($0 * 1_024).formatted(.byteCount(style: .file)) } ?? "unknown"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolPanel(title: "Startup Disk", symbol: "internaldrive") {
                AvailableSpaceLine(storage: storage)
            }
            ToolPanel(title: "Developer Storage", symbol: "shippingbox") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(state).font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if storage.phase == .idle {
                            Button("Scan") { storage.scan() }
                                .accessibilityIdentifier("storage-scan")
                        } else {
                            ProgressView().controlSize(.small)
                            Button("Stop") { storage.cancel() }
                        }
                    }
                    .controlSize(.small)
                    .padding(.vertical, 8)
                    ForEach(groups, id: \.name) { group in
                        Divider()
                        Text(group.name).font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 8).padding(.bottom, 2)
                        ForEach(group.targets) { target in
                            StorageTargetRow(storage: storage, target: target)
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
            if let summary = storage.summary {
                Label(summary, systemImage: "checkmark.circle").font(.caption)
            }
            if let notice = storage.notice {
                Label(notice, systemImage: "exclamationmark.triangle").font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { storage.refreshSpace() }
        // Q24: Clean always asks first, with what goes and the total.
        .confirmationDialog("Remove \(storage.chosen.count == 1 ? "1 target" : "\(storage.chosen.count) targets")?", isPresented: $confirming) {
            Button("Remove", role: .destructive) { storage.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(storage.chosen.map(\.label).joined(separator: ", ")).\n\n\(selected). What is removed is gone for good; it does not go to the Trash.")
        }
    }

    private var state: String {
        switch storage.phase {
        case .scanning: return "Scanning: measuring what developer tools left behind. Nothing is removed."
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

    // In the order the script lists them.
    private var groups: [(name: String, targets: [StorageTarget])] {
        var names: [String] = []
        var byName: [String: [StorageTarget]] = [:]
        for target in storage.targets {
            if byName[target.group] == nil { names.append(target.group) }
            byName[target.group, default: []].append(target)
        }
        return names.map { ($0, byName[$0] ?? []) }
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
                Image(systemName: target.state == .reportOnly ? "eye" : "lock")
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
        if let result = storage.results[target.key] {
            return result.ok ? "Removed\(result.freedKB.map { ": \(size($0))" } ?? "")" : "Not removed: \(result.error ?? "unknown reason")"
        }
        if StorageSelection.needsTerminal(target, helperReady: storage.helperReady) {
            return "Needs root. " + (storage.helperReady ? "It lies outside the folders the toolkit helper may clean." : "Set up the toolkit helper on the Power page, or run the command in a terminal.")
        }
        return target.detail.isEmpty ? nil : target.detail
    }

    private var value: String {
        // What removing it frees where that is known, else what it occupies.
        target.state == .selectable ? (target.projectedKB.map { size($0) } ?? "\(size(target.sizeKB)) used") : size(target.sizeKB)
    }
}
