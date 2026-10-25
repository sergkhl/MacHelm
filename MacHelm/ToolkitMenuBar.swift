import AppKit
import Combine

// The app's one menu bar item: the quiet entry point after a login launch.
// Its menu links to the dashboard, toggles Fan Control and Keep Awake,
// lists the five heaviest CPU groups and holds the app's own login switch;
// what it holds is decided by ToolkitMenu. It reads the same
// state objects as the dashboard, so the two surfaces cannot disagree about
// whether a tool is on.
@MainActor
final class ToolkitMenuBar: NSObject, NSMenuDelegate {
    private let host: ToolHost
    private let openDashboard: () -> Void
    private let openPage: (DashboardPage) -> Void
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var shown: FanMenuBarReadout?
    private var shownHold = false
    private var subscriptions: Set<AnyCancellable> = []

    init(host: ToolHost, openDashboard: @escaping () -> Void, openPage: @escaping (DashboardPage) -> Void) {
        self.host = host
        self.openDashboard = openDashboard
        self.openPage = openPage
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        showImage(nil, hold: false)

        let fan = host.cooling
        fan.menuBarReadout
            .combineLatest(fan.$helperApproved, fan.$menuBarReadoutEnabled, fan.fanWarning)
            .sink { [weak self] readout, approved, enabled, hold in
                // The service publishes on the main actor only.
                MainActor.assumeIsolated { self?.showImage(approved && enabled ? readout : nil, hold: hold) }
            }
            .store(in: &subscriptions)
    }

    // M-Q5: the fan symbol with temperature above speed while the readout is
    // available; the toolkit symbol otherwise. Z-Q8: while the fans need
    // attention a warning sign takes the place of either symbol.
    private func showImage(_ readout: FanMenuBarReadout?, hold: Bool) {
        guard let button = item.button else { return }
        let held = "MacHelm: fans need attention"
        guard let readout else {
            shown = nil
            let symbol = NSImage(systemSymbolName: hold ? "exclamationmark.triangle" : "wrench.and.screwdriver",
                                 accessibilityDescription: hold ? held : "MacHelm")
            symbol?.isTemplate = true
            button.image = symbol
            button.toolTip = hold ? "MacHelm — the fans need attention. Open the Cooling page." : "MacHelm"
            button.setAccessibilityLabel(hold ? held : "MacHelm")
            return
        }
        // F-Q6: the service publishes every second; the image is redrawn only
        // when the reading or the hold changes.
        guard readout != shown || hold != shownHold else { return }
        shown = readout; shownHold = hold
        button.image = FanMenuBarImage.make(temperature: readout.temperature, speed: readout.speed, warning: hold)
        button.toolTip = hold ? "MacHelm — the fans need attention. Open the Cooling page."
            : "MacHelm — firmware CPU die average and the faster fan's measured speed"
        button.setAccessibilityLabel(hold ? held : "MacHelm: CPU \(readout.temperature), fan \(readout.speed)")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        host.cooling.refreshHelperStatus()
        host.startupServices.refreshOpenAtLogin()
        host.power.refresh()
        host.storage.refreshSpace()
        // The list is built from what Activity read while the menu was shut.
        host.activity.bringUpToDate()
        rebuild()
    }

    // While the menu is open Activity reads at the on-screen pace, so the
    // next opening has fresh figures. The list itself stays as it was built:
    // a row must not move under the pointer.
    func menuWillOpen(_ menu: NSMenu) {
        // A service's row is named after the service, so they are read too.
        host.startupServices.refresh()
        host.activity.setMenuOpen(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        host.activity.setMenuOpen(false)
    }

    private func rebuild() {
        menu.removeAllItems()
        let fan = host.cooling
        let snapshot = host.activity.snapshot
        let heaviest = snapshot?.rows[.cpu]?.map {
            ToolkitMenuProcess(name: $0.group.name, origin: ActivityText.origin($0.group.origin), value: ActivityMeasure.cpu.text($0.value))
        }
        let entries = ToolkitMenu.entries(fanOn: fan.enabled,
                                          fanCanToggle: fan.canMutateHelper && !fan.recoveryRequired,
                                          keepAwakeOn: host.power.keepAwakeOn, keepAwakeNote: keepAwakeNote,
                                          availableSpace: host.storage.available,
                                          heaviest: heaviest, span: ActivityText.span(snapshot?.seconds ?? host.activity.windowLength),
                                          openAtLogin: host.startupServices.openAtLogin)
        for entry in entries { menu.addItem(item(for: entry)) }
    }

    private func item(for entry: ToolkitMenuEntry) -> NSMenuItem {
        switch entry {
        case .openDashboard:
            return action("Open MacHelm", #selector(showDashboard), symbol: "square.grid.2x2", key: "o")
        case .separator:
            return .separator()
        case .fanControl(let on, let canToggle):
            // The toggle carries the state it was shown with. A row that went
            // stale under the open menu then does nothing, instead of the opposite.
            let fanItem = action("Fan Control", #selector(toggleFanControl(_:)), symbol: "fan", checked: on, enabled: canToggle)
            fanItem.representedObject = on
            fanItem.toolTip = host.cooling.subtitle
            fanItem.setAccessibilityLabel(on ? "Turn off fan control" : "Turn on fan control")
            return fanItem
        case .keepAwake(let on, let note):
            // Like the fan's entry, it carries the state it was shown with.
            let entry = action("Keep Awake", #selector(toggleKeepAwake(_:)), symbol: "sun.max", checked: on)
            entry.representedObject = on
            entry.subtitle = note
            entry.setAccessibilityLabel(on ? "Turn off Keep Awake" : "Turn on Keep Awake")
            return entry
        case .storage(let available):
            let space = available.map { "\($0.formatted(.byteCount(style: .file))) available" } ?? "Unavailable"
            return action("Storage · \(space)", #selector(showStorage), symbol: "internaldrive")
        case .startupServices:
            return action("Startup Services", #selector(showStartupServices), symbol: "power")
        case .activity(let span):
            let entry = action("Activity", #selector(showActivity), symbol: "waveform.path.ecg")
            let detail = span.map { "Heaviest by CPU, last \($0)" } ?? "Heaviest by CPU"
            entry.toolTip = detail
            entry.setAccessibilityLabel("Activity: \(detail)")
            return entry
        case .measuring:
            let entry = action("Measuring…", nil, enabled: false)
            entry.indentationLevel = 1
            return entry
        case .process(let process):
            // A click opens the Activity page. Nothing is quit from here: a slip would end an app.
            let row = action(process.value.isEmpty ? process.name : "\(process.name) — \(process.value)", #selector(showActivity),
                             symbol: process.value.isEmpty ? nil : "app",
                             enabled: !process.value.isEmpty)
            row.subtitle = process.origin
            row.indentationLevel = 1
            return row
        case .openAtLogin(let on):
            return action("Open at Login", #selector(toggleOpenAtLogin), symbol: "person.crop.circle", checked: on)
        case .quit:
            return action("Quit", #selector(quit), symbol: "xmark.circle", key: "q")
        }
    }

    private func action(_ title: String, _ selector: Selector?, symbol: String? = nil, key: String = "", checked: Bool = false,
                        enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        if let symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            image?.size = NSSize(width: 16, height: 16)
            entry.image = image
        }
        entry.target = self
        entry.state = checked ? .on : .off
        entry.isEnabled = enabled
        return entry
    }

    // MARK: Actions

    @objc private func showDashboard() { openDashboard() }

    @objc private func showActivity() { openPage(.activity) }

    @objc private func showStorage() { openPage(.storage) }

    @objc private func showStartupServices() { openPage(.startupServices) }

    @objc private func toggleFanControl(_ sender: NSMenuItem) {
        guard sender.representedObject as? Bool == host.cooling.enabled else { return }
        host.cooling.toggle()
    }

    @objc private func toggleKeepAwake(_ sender: NSMenuItem) {
        guard sender.representedObject as? Bool == host.power.keepAwakeOn else { return }
        host.power.setKeepAwake(!host.power.keepAwakeOn)
    }

    // What holds when that is less than the switch asks for: paused on battery, or no helper for the lid.
    private var keepAwakeNote: String? {
        switch host.power.status {
        case .off, .on: return nil
        case .idleOnly: return "The lid still sleeps the Mac"
        case .paused(let charge, _): return "Paused at \(charge)% on battery"
        }
    }

    @objc private func toggleOpenAtLogin() {
        host.startupServices.setOpenAtLogin(!host.startupServices.openAtLogin)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
