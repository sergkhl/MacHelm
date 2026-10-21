import SwiftUI

private extension ToolkitHelperState {
    var line: String {
        switch self {
        case .ready: return "Toolkit helper approved"
        case .needsApproval: return "Turn MacHelm on under Login Items & Extensions to approve the toolkit helper"
        case .notSetUp: return "The toolkit helper is not set up"
        case .unavailable(let reason): return reason
        }
    }
}

// Keep Awake's switch, as the Overview and the Power page both show it.
struct KeepAwakeRow: View {
    @ObservedObject var power: PowerService

    var body: some View {
        ToolRow(icon: "cup.and.saucer.fill", title: "Keep Awake", subtitle: KeepAwakePolicy.note(power.status),
                isActive: power.status == .on || power.status == .idleOnly) {
            Toggle("Keep Awake", isOn: Binding(get: { power.keepAwakeOn }, set: { power.setKeepAwake($0) }))
                .toggleStyle(.switch).labelsHidden()
                .accessibilityIdentifier("keep-awake")
        }
    }
}

// The Overview's share of Power: the switch and Sleep Now.
struct PowerOverviewCard: View {
    @ObservedObject var power: PowerService
    let openPower: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            KeepAwakeRow(power: power)
            Divider()
            HStack {
                Button("Sleep Now") { power.sleepNow() }
                    .controlSize(.small)
                    .disabled(power.sleepPending)
                    .accessibilityIdentifier("sleep-now")
                Spacer()
                Button("Open Power", action: openPower).controlSize(.small)
            }
            .padding(.vertical, 8)
        }
    }
}

// The Power page: Keep Awake with its battery level, Sleep Now, the four
// sleep timers and the toolkit helper they need.
struct PowerPage: View {
    @ObservedObject var power: PowerService
    // Both act on the fan helper as well.
    let setUpHelpers: () -> Void
    let removeHelpers: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolPanel(title: "Keep Awake", symbol: "cup.and.saucer") {
                VStack(alignment: .leading, spacing: 0) {
                    KeepAwakeRow(power: power)
                    Divider()
                    HStack {
                        Text("On battery, pause at").font(.subheadline)
                        Spacer(minLength: 8)
                        Picker("On battery, pause at", selection: $power.batteryLevel) {
                            ForEach(KeepAwakePolicy.levels, id: \.self) { Text(verbatim: "\($0)%").tag($0) }
                        }
                        .labelsHidden().controlSize(.small).fixedSize()
                        .accessibilityIdentifier("keep-awake-battery-level")
                    }
                    .padding(.vertical, 8)
                    Text(battery).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    Divider()
                    HStack {
                        Text("Sleeps the Mac once trackpad and keyboard have been still for a second, also while Keep Awake is on. A touch in the five seconds after that calls the sleep off.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Sleep Now") { power.sleepNow() }
                            .controlSize(.small)
                            .disabled(power.sleepPending)
                            .accessibilityIdentifier("sleep-now")
                    }
                    .padding(.vertical, 8)
                }
            }
            ToolPanel(title: "Sleep Timers", symbol: "moon.zzz") {
                VStack(alignment: .leading, spacing: 0) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("")
                            Text("On battery").font(.caption).foregroundStyle(.secondary)
                            Text("On power adapter").font(.caption).foregroundStyle(.secondary)
                        }
                        GridRow {
                            Text("Turn the display off after").font(.subheadline)
                            picker(.displayOnBattery)
                            picker(.displayOnPowerAdapter)
                        }
                        GridRow {
                            Text("Sleep after").font(.subheadline)
                            picker(.sleepOnBattery)
                            picker(.sleepOnPowerAdapter)
                        }
                    }
                    .padding(.vertical, 8)
                    Text("These are macOS's own settings, the ones System Settings shows. They stay after MacHelm quits. The Mac does not sleep while its display is on, and not at all while Keep Awake is in force.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
            }
            ToolPanel(title: "Toolkit Helper", symbol: "lock.shield") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(power.helper.line).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A small root program inside MacHelm. Keeping the Mac awake with the lid closed and changing the sleep timers need it. It starts when it is asked and leaves when it holds nothing. Set up helpers and Remove helpers act on both of MacHelm's helpers: this one and the fan helper on the Cooling page. Setting up the fan helper lets Fan Control start as you left it; removing them ends Fan Control and Keep Awake with the lid closed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        switch power.helper {
                        case .notSetUp:
                            Button("Set up helpers", action: setUpHelpers)
                        case .needsApproval:
                            Button("System Settings") { power.openHelperSettings() }
                            Button("Remove helpers", action: removeHelpers)
                        case .ready:
                            Button("Remove helpers", action: removeHelpers)
                        case .unavailable:
                            EmptyView()
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 8)
            }
            if let notice = power.notice {
                Label(notice, systemImage: "exclamationmark.triangle").font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { power.refresh() }
    }

    private var battery: String {
        guard let charge = power.charge else { return "This Mac has no battery, so the level never applies." }
        return "Now \(charge)% \(power.onBattery ? "on battery" : "on the power adapter"). At or below the level Keep Awake pauses and the Mac may sleep; it is in force again on the power adapter."
    }

    // A value set elsewhere that is not among the choices is listed too, so the picker shows what macOS has.
    private func picker(_ timer: SleepTimer) -> some View {
        let current = power.timers.minutes[timer]
        let choices = SleepTimer.minutes + (current.map { SleepTimer.minutes.contains($0) ? [] : [$0] } ?? [])
        return Picker(name(timer), selection: Binding(get: { current ?? -1 }, set: { power.setTimer(timer, minutes: $0) })) {
            if current == nil { Text("Unknown").tag(-1) }
            ForEach(choices, id: \.self) { Text(SleepTimer.text($0)).tag($0) }
        }
        .labelsHidden().controlSize(.small).fixedSize()
        .disabled(power.helper != .ready || current == nil)
        .accessibilityLabel(name(timer))
        .accessibilityIdentifier("sleep-timer-\(timer.rawValue)")
    }

    // What VoiceOver reads for a picker: the grid's row and column in words.
    private func name(_ timer: SleepTimer) -> String {
        switch timer {
        case .displayOnBattery: return "Turn the display off after, on battery"
        case .displayOnPowerAdapter: return "Turn the display off after, on power adapter"
        case .sleepOnBattery: return "Sleep after, on battery"
        case .sleepOnPowerAdapter: return "Sleep after, on power adapter"
        }
    }
}
