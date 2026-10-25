import SwiftUI

private extension ToolkitHelperState {
    var line: String {
        switch self {
        case .ready: return "Ready"
        case .needsApproval: return "Approval required"
        case .notSetUp: return "Not set up"
        case .unavailable(let reason): return reason
        }
    }
}

private extension KeepAwakeStatus {
    var shortLabel: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .idleOnly: return "Idle only"
        case .paused(let charge, _): return "Paused · \(charge)%"
        }
    }
}

private struct KeepAwakeSwitch: View {
    @ObservedObject var power: PowerService

    var body: some View {
        Toggle("Keep Awake", isOn: Binding(get: { power.keepAwakeOn }, set: { power.setKeepAwake($0) }))
            .toggleStyle(.switch).labelsHidden()
            .accessibilityIdentifier("keep-awake")
    }
}

struct KeepAwakeRow: View {
    @ObservedObject var power: PowerService

    var body: some View {
        ToolRow(icon: "cup.and.saucer.fill", title: "Keep Awake", subtitle: power.status.shortLabel,
                isActive: power.status == .on || power.status == .idleOnly) {
            InfoButton(KeepAwakePolicy.note(power.status), label: "About Keep Awake")
            KeepAwakeSwitch(power: power)
        }
    }
}

struct PowerOverviewCard: View {
    @ObservedObject var power: PowerService

    var body: some View {
        KeepAwakeRow(power: power)
    }
}

// Keep Awake, the four sleep timers and the helpers they need.
struct PowerPage: View {
    @ObservedObject var power: PowerService
    // Both act on the fan helper as well.
    let setUpHelpers: () -> Void
    let removeHelpers: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolPanel(title: "Keep Awake", symbol: "cup.and.saucer",
                      info: KeepAwakePolicy.note(power.status)) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(power.status.shortLabel).font(.subheadline)
                        Spacer()
                        KeepAwakeSwitch(power: power)
                    }
                    .padding(.vertical, 8)
                    Divider()
                    HStack(spacing: 8) {
                        Text("Battery limit").font(.subheadline)
                        InfoButton("On battery, Keep Awake pauses at or below this level. Connecting the power adapter lets it resume. This limit does not apply on Macs without a battery.", label: "About the battery limit")
                        Spacer(minLength: 8)
                        Text(battery).font(.caption).foregroundStyle(.secondary)
                        Picker("Battery limit", selection: $power.batteryLevel) {
                            ForEach(KeepAwakePolicy.levels, id: \.self) { Text(verbatim: "\($0)%").tag($0) }
                        }
                        .labelsHidden().controlSize(.small).fixedSize()
                        .accessibilityIdentifier("keep-awake-battery-level")
                    }
                    .padding(.vertical, 8)
                }
            }
            ToolPanel(title: "Sleep Timers", symbol: "moon.zzz",
                      info: "These macOS settings stay after MacHelm quits. An approved toolkit helper is needed to change them. The Mac does not sleep while its display is on, or while Keep Awake is active.") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Label("Battery", systemImage: "battery.100")
                            .labelStyle(.iconOnly)
                            .help("On battery")
                        Label("Power Adapter", systemImage: "powerplug.fill")
                            .labelStyle(.iconOnly)
                            .help("On power adapter")
                    }
                    .foregroundStyle(.secondary)
                    GridRow {
                        Text("Display").font(.subheadline)
                        picker(.displayOnBattery)
                        picker(.displayOnPowerAdapter)
                    }
                    GridRow {
                        Text("Sleep").font(.subheadline)
                        picker(.sleepOnBattery)
                        picker(.sleepOnPowerAdapter)
                    }
                }
                .padding(.vertical, 8)
            }
            ToolPanel(title: "Toolkit Helper", symbol: "lock.shield",
                      info: "The toolkit helper enables Keep Awake with the lid closed and changes to sleep timers. Approve MacHelm under Login Items & Extensions in System Settings. Set up helpers and Remove helpers affect both the toolkit and fan helpers. Setup lets Fan Control resume its saved state; removal ends Fan Control and Keep Awake with the lid closed.") {
                HStack(spacing: 12) {
                    Text(power.helper.line).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    switch power.helper {
                    case .notSetUp:
                        Button("Set up helpers", action: setUpHelpers)
                    case .needsApproval:
                        ToolIconButton("Open helper settings", symbol: "gearshape") { power.openHelperSettings() }
                        Button("Remove helpers", action: removeHelpers)
                    case .ready:
                        Button("Remove helpers", action: removeHelpers)
                    case .unavailable:
                        EmptyView()
                    }
                }
                .controlSize(.small)
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
        guard let charge = power.charge else { return "No battery" }
        return "\(charge)% · \(power.onBattery ? "Battery" : "Power adapter")"
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
