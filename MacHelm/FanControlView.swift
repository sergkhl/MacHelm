import SwiftUI

// Fan Control's switch with its state in a few words: the same line on the
// Overview and on the Cooling page.
struct FanControlRow: View {
    @ObservedObject var service: FanControlService

    var body: some View {
        ToolRow(icon: "fan", title: "Fan Control", subtitle: service.subtitle, isActive: service.enabled) {
            Toggle("Fan Control", isOn: Binding(get: { service.enabled }, set: { _ in service.toggle() }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(!service.canMutateHelper || service.recoveryRequired)
                .accessibilityLabel(service.enabled ? "Turn off fan control" : "Turn on fan control")
        }
    }
}

private func readingRow(_ label: String, _ value: String) -> some View {
    HStack {
        Text(label).font(.caption)
        Spacer()
        Text(value).font(.callout).monospacedDigit()
    }
    .accessibilityElement(children: .combine)
}

// The Overview's share of Cooling: the switch, three readings, and a
// required recovery, which is resolved on the Cooling page.
struct CoolingOverviewCard: View {
    @ObservedObject var service: FanControlService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FanControlRow(service: service)
            if service.recoveryRequired {
                Label("Recovery required", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
            }
            Divider()
            if let capabilities = service.status.capabilities, let snapshot = service.status.snapshot,
               (try? snapshot.validate(against: capabilities, now: ProcessInfo.processInfo.systemUptime)) != nil {
                readingRow("CPU", String(format: "%.0f °C", snapshot.cpuDieAverage(in: capabilities)))
                readingRow("GPU", String(format: "%.0f °C", snapshot.hottestGPU(in: capabilities)))
                if let fastest = snapshot.fans.map(\.actualRPM).max() {
                    readingRow("Fans", "\(Int(fastest.rounded())) RPM")
                }
            } else {
                Text(service.helperApproved ? "No readings yet" : "Fan helper required")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 8)
    }
}

// The Cooling page: Fan Control's state, its readings, the temperature ramp
// and the helper. Showing it reads the fans and changes nothing.
struct CoolingPage: View {
    @ObservedObject var service: FanControlService
    // Both act on the toolkit helper as well.
    let setUpHelpers: () -> Void
    let removeHelpers: () -> Void
    @State private var start: Double = FanProfile.standard.start
    @State private var maximum: Double = FanProfile.standard.maximum
    @State private var showRecoveryConfirmation = false
    @State private var pendingRecoveryID: String?
    @State private var showRestoreConfirmation = false
    @State private var pendingRestoreID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ToolPanel(title: "State", symbol: "switch.2") { state.padding(.bottom, 8) }
            ToolPanel(title: "Readings", symbol: "thermometer.medium", info: readingsInfo) { telemetry.padding(.bottom, 10) }
            ToolPanel(title: "Temperatures", symbol: "chart.line.uptrend.xyaxis", info: rampInfo) { ramp.padding(.bottom, 10) }
            ToolPanel(title: "Helpers", symbol: "lock.shield", info: helperInfo) { helper.padding(.bottom, 10) }
        }
        .onAppear { start = service.profile.start; maximum = service.profile.maximum }
        .alert("Verify external fan recovery?", isPresented: $showRecoveryConfirmation) {
            Button("Cancel", role: .cancel) { pendingRecoveryID = nil }
            Button("Verify external recovery") {
                if let recoveryID = pendingRecoveryID { service.confirmExternalRecovery(recoveryID: recoveryID) }
                pendingRecoveryID = nil
            }
            .disabled(!service.canVerifyExternalRecovery || pendingRecoveryID != service.status.externalRecoveryID)
        } message: {
            Text("Set both fans to Auto in your independent fan utility, then quit that utility. Confirm only after completing both steps. The helper will read the current fan state and clear this recovery hold only if both fans are automatic. Fan Control stays off.")
        }
        .alert("Restore automatic fan control?", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) { pendingRestoreID = nil }
            Button("Restore automatic now") {
                if let recoveryID = pendingRestoreID { service.restoreAutomatic(recoveryID: recoveryID) }
                pendingRestoreID = nil
            }
            .disabled(!service.canRestoreAutomatic || pendingRestoreID != service.status.externalRecoveryID)
        } message: {
            Text("The helper will set the fans it recorded back to automatic and check them. It never sets a fan speed. Quit Macs Fan Control first; the helper does nothing while it is running. If the fans cannot be confirmed automatic, this recovery hold stays. Fan Control stays off.")
        }
        .onDisappear {
            showRecoveryConfirmation = false; pendingRecoveryID = nil
            showRestoreConfirmation = false; pendingRestoreID = nil
        }
    }

    // MARK: State

    private var state: some View {
        VStack(alignment: .leading, spacing: 8) {
            FanControlRow(service: service)
            if service.status.mode.title != service.subtitle {
                Text(service.status.mode.title).font(.subheadline.weight(.semibold))
            }
            if let reason = service.message ?? service.status.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fan-control-reason")
            }
            if let note = service.launchNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fan-control-launch-note")
            }
            if service.helperApproved && !service.helperProtocolReady {
                Text("Fan controls are locked until the connected helper passes its compatibility check.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fan-control-protocol-readiness")
            }
            if service.recoveryRequired { recovery }
        }
    }

    private var recovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recovery required", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(service.restoreAutomaticOffered
                 ? "A fan command could not be confirmed. Choose Restore automatic now to let the helper return the fans to automatic and check them. Or set both fans to Auto in your independent fan utility, quit that utility, then verify. Fan Control, temperature saving and helper removal stay locked until then."
                 : "A fan command recorded before the Mac restarted, or by another helper version, could not be confirmed. Set both fans to Auto in your independent fan utility, quit that utility, then verify. Fan Control, temperature saving and helper removal stay locked until then.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let failure = service.lastRestoreFailure {
                Text("Last attempt: \(failure)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fan-control-restore-failure")
            }
            HStack {
                if service.restoreAutomaticOffered {
                    Button("Restore automatic now") {
                        guard let recoveryID = service.status.externalRecoveryID else { return }
                        pendingRestoreID = recoveryID
                        showRestoreConfirmation = true
                    }
                    .disabled(!service.canRestoreAutomatic)
                    .accessibilityIdentifier("fan-control-restore-automatic")
                }
                Button("Verify external recovery") {
                    guard let recoveryID = service.status.externalRecoveryID else { return }
                    pendingRecoveryID = recoveryID
                    showRecoveryConfirmation = true
                }
                .disabled(!service.canVerifyExternalRecovery)
                .accessibilityIdentifier("fan-control-verify-external-recovery")
            }
        }
    }

    // MARK: Readings

    @ViewBuilder private var telemetry: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let capabilities = service.status.capabilities, let snapshot = service.status.snapshot,
               (try? snapshot.validate(against: capabilities, now: ProcessInfo.processInfo.systemUptime)) != nil {
                readingRow("CPU average", String(format: "%.1f °C", snapshot.cpuDieAverage(in: capabilities)))
                readingRow("CPU maximum", String(format: "%.1f °C", snapshot.cpuDieMaximum(in: capabilities)))
                readingRow("GPU", String(format: "%.1f °C", snapshot.hottestGPU(in: capabilities)))
            } else {
                Text("Temperature readings unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let probe = service.status.fanProbe {
                Divider()
                ForEach(probe.observation.fans) { fan in
                    HStack(alignment: .top) {
                        Text("Fan \(fan.id + 1)").font(.caption)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(fan.actualRPM.rounded())) RPM · \(fan.isAutomatic ? "Auto" : "Manual")")
                                .font(.callout)
                            if let requested = service.status.requestedRPM[fan.id] {
                                Text("Requested \(Int(requested.rounded())) · Target \(Int(fan.targetRPM.rounded())) RPM")
                            } else {
                                Text("\(service.enabled ? "Apple automatic" : "Control off") · Target \(Int(fan.targetRPM.rounded())) RPM")
                            }
                        }.font(.caption2).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text(service.helperApproved ? "Fan readings unavailable" : "Fan helper required")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Temperature ramp

    private var ramp: some View {
        VStack(alignment: .leading, spacing: 8) {
            threshold("Start", value: $start, range: 40...75)
            threshold("Maximum", value: $maximum, range: 55...90)
            if !validProfile {
                Label("Keep at least 10 °C between thresholds.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Save") { service.saveProfile(start: start, maximum: maximum) }
                    .disabled(!validProfile || !service.canSaveProfile)
                    .accessibilityLabel("Save temperatures")
                ToolIconButton("Restore default temperatures", symbol: "arrow.counterclockwise") {
                    start = FanProfile.standard.start; maximum = FanProfile.standard.maximum
                }
            }
        }
    }

    private var validProfile: Bool { (try? FanProfile(start: start, maximum: maximum).validate()) != nil }

    private func threshold(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            Stepper(value: value, in: range, step: 1) {
                Text("\(Int(value.wrappedValue)) °C").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            .frame(width: 110).accessibilityLabel("\(label) cooling temperature")
        }
    }

    // MARK: Helper

    private var helper: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(service.helperDescription).font(.subheadline.weight(.semibold))
            HStack {
                Button("Set Up", action: setUpHelpers)
                    .disabled(service.busy || service.helperApproved)
                    .accessibilityLabel("Set up helpers")
                ToolIconButton("Open helper settings", symbol: "gearshape") { service.openHelperSettings() }
                Spacer()
                Button("Remove", action: removeHelpers)
                    .disabled(!service.canMutateHelper || service.recoveryRequired)
                    .accessibilityLabel("Remove helpers")
            }
        }
    }

    private var readingsInfo: String {
        "CPU average is the firmware CPU die average; CPU maximum is the hottest CPU die reading, and GPU is the hottest GPU reading. AppleSMC TCMb drives the ramp and TCMz protects the CPU. The firmware's averaging formula is undocumented. Temperature readings need a complete, fresh, qualified sensor set.\n\nEach fan shows its measured speed and observed mode. Requested is MacHelm's command; Target is the target reported by the fan. Live fan speeds are read while Fan Control is on or this window shows them, after helper approval."
    }

    private var rampInfo: String {
        "Keep at least 10 °C between Start and Maximum. MacHelm takes control at Start using the smoothed CPU die average, and returns the fans to Apple after ten seconds below it.\n\nThermal protection requests maximum cooling after three CPU maximum readings of at least 90 °C, or immediately at GPU ≥85 °C or serious/critical system pressure. Recovery requires ten cool seconds."
    }

    private var helperInfo: String {
        "Set Up and Remove act on both the fan helper and the toolkit helper. Removing them ends Fan Control and Keep Awake with the lid closed. Fan Control starts as you left it when MacHelm last ran. Quit Macs Fan Control and return any existing custom settings to automatic before enabling."
    }
}
