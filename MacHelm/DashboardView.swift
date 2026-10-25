import AppKit
import SwiftUI

// One host for every tool. The dashboard and the menu bar present the tools
// together; each tool keeps its own state, its own way of running, its own
// privilege and its own clean-up when the app quits.
@MainActor
final class ToolHost {
    let cursor = CursorController()
    let cooling = FanControlService()
    // The user's launchd jobs. They keep running after quit.
    let startupServices = StartupServicesStore()
    // The heaviest processes. It only reads, in the background too (ADR 0005, ADR 0006).
    let activity: ActivityStore
    // Keep Awake and the sleep timers. Keep Awake's hold ends on quit; the timers are macOS's own.
    let power = PowerService()
    // Available space and the developer storage cleanup. Nothing is scanned or removed unless the owner asks.
    let storage: StorageService

    init() {
        activity = ActivityStore(services: startupServices)
        storage = StorageService(power: power)
    }

    // One press sets up both root helpers (the owner, 2026-10-12). One that
    // is approved already is left alone.
    func setUpHelpers() {
        if !cooling.helperApproved { cooling.setUpHelper() }
        // The toolkit helper's registration as it is now, not as the Power page last read it.
        power.readHelper()
        if power.helper == .notSetUp || power.helper == .needsApproval { power.setUpHelper() }
    }

    // One press removes both as well; each lets go of what it holds first.
    // The Cooling page's button does for the fan helper what it always did;
    // from the Power page the fan helper goes only where that button is enabled.
    func removeHelpers(pressedOn page: ToolGroup) {
        if page == .cooling || cooling.canMutateHelper && !cooling.recoveryRequired { cooling.removeHelper() }
        power.readHelper()
        if power.helper == .ready || power.helper == .needsApproval { power.removeHelper() }
    }

    // Stop the shortcut first, then release the fans and Keep Awake's hold.
    func releaseBeforeQuit(_ completion: @escaping @Sendable () -> Void) {
        cursor.stop()
        cooling.releaseForQuit { [power] in
            Task { @MainActor in power.releaseForQuit { DispatchQueue.main.async(execute: completion) } }
        }
    }

    func cleanUpOnQuit() {
        cursor.stop()
        storage.endForQuit()
    }
}

enum ToolGroup: String, CaseIterable, Identifiable {
    case cooling, power, activity, storage, startupServices, cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: return "Tweaks"
        case .cooling: return "Cooling"
        case .power: return "Power"
        case .activity: return "Activity"
        case .storage: return "Storage"
        case .startupServices: return "Startup Services"
        }
    }

    var symbol: String {
        switch self {
        case .cursor: return "slider.horizontal.3"
        case .cooling: return "fan"
        case .power: return "powersleep"
        case .activity: return "waveform.path.ecg"
        case .storage: return "internaldrive"
        case .startupServices: return "power"
        }
    }

    // What quitting MacHelm does to the group's effects.
    var quitNote: String {
        switch self {
        case .cursor: return "MacHelm requests cursor restoration when you quit."
        case .cooling: return "Quitting MacHelm returns the fans to automatic."
        case .power: return "Quitting MacHelm ends Keep Awake until it opens again; the switch is remembered. The sleep timers are macOS's own and stay."
        case .activity: return "Activity only reads. Quitting MacHelm changes nothing for the apps listed here."
        case .storage: return "Nothing is scanned or removed by itself. What Clean removes is gone for good; quitting MacHelm stops a scan or a clean that is running."
        case .startupServices: return "Services keep running when MacHelm quits."
        }
    }
}

// The dashboard's pages (ADR 0001): the Overview, then one page for each tool group.
enum DashboardPage: String, CaseIterable, Identifiable {
    case overview, cooling, power, activity, storage, startupServices, cursor

    var id: String { rawValue }

    var group: ToolGroup? {
        switch self {
        case .overview: return nil
        case .cursor: return .cursor
        case .cooling: return .cooling
        case .power: return .power
        case .activity: return .activity
        case .storage: return .storage
        case .startupServices: return .startupServices
        }
    }

    var title: String { group?.title ?? "Overview" }
    var symbol: String { group?.symbol ?? "square.grid.2x2" }
}

// Which page is shown and whether the window is on screen. From the two it
// decides what is read: a page that is not on screen reads nothing.
@MainActor
final class DashboardModel: ObservableObject {
    @Published var page: DashboardPage = .overview {
        didSet { if page != oldValue { applyWatching() } }
    }

    private let host: ToolHost
    private var visible = false
    private var servicesWatched = false
    private var readingsShown = false

    init(host: ToolHost) {
        self.host = host
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        applyWatching()
    }

    private func applyWatching() {
        host.cooling.setDashboardVisible(visible)
        // The Overview carries a line for every tool group.
        let services = visible
        if services != servicesWatched {
            servicesWatched = services
            if services { host.startupServices.beginWatching() } else { host.startupServices.endWatching() }
        }
        host.activity.setListsOnScreen(visible && (page == .overview || page == .activity))
        let readings = visible && (page == .overview || page == .cooling)
        if readings != readingsShown {
            readingsShown = readings
            host.cooling.setReadingsShown(readings)
        }
    }
}

// Explanations stay close to their controls without occupying the normal layout.
struct InfoButton: View {
    let text: String
    let label: String
    @State private var isPresented = false

    init(_ text: String, label: String = "More information") {
        self.text = text
        self.label = label
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $isPresented) {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(width: 340, alignment: .leading)
        }
    }
}

// Familiar actions keep a full name for hover help and VoiceOver.
struct ToolIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

struct ToolPanel<Content: View>: View {
    let title: String
    let symbol: String
    // A figure for the whole panel, at the title's right.
    let detail: String?
    let info: String?
    let open: (() -> Void)?
    let content: Content

    init(title: String, symbol: String, detail: String? = nil, info: String? = nil,
         open: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.info = info
        self.open = open
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let open {
                    Button(action: open) { heading }
                        .buttonStyle(.plain)
                        .help("Open \(title)")
                        .accessibilityLabel("Open \(title)")
                } else {
                    heading
                }
                if let info {
                    InfoButton(info, label: "About \(title)")
                }
            }
            .padding(.top, 12)
            content
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }

    private var heading: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if open != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

extension ToolPanel {
    init(group: ToolGroup, info: String? = nil, open: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: group.title, symbol: group.symbol, info: info, open: open, content: content)
    }
}

// The dashboard: a sidebar and the page it selects. Opening the window or a
// page reads state and changes nothing.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    let host: ToolHost
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(model.page.title).font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        if let group = model.page.group {
                            InfoButton(group.quitNote, label: "When MacHelm quits")
                        }
                        Spacer()
                    }
                    page
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(DashboardPage.allCases.enumerated()), id: \.element) { index, page in
                Button { model.page = page } label: {
                    Label(page.title, systemImage: page.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(model.page == page ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                    in: .rect(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .accessibilityAddTraits(model.page == page ? .isSelected : [])
            }
            Spacer(minLength: 12)
            Button(action: openSettings) {
                Label("Settings…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        // The window's buttons sit over the top of the sidebar.
        .padding(.top, 44).padding(.horizontal, 10).padding(.bottom, 12)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(.quinary)
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .overview:
            OverviewPage(host: host) { model.page = $0 }
        case .cursor:
            CursorPage(controller: host.cursor)
        case .cooling:
            CoolingPage(service: host.cooling, setUpHelpers: host.setUpHelpers, removeHelpers: { host.removeHelpers(pressedOn: .cooling) })
        case .power:
            PowerPage(power: host.power, setUpHelpers: host.setUpHelpers, removeHelpers: { host.removeHelpers(pressedOn: .power) })
        case .activity:
            ActivityPage(store: host.activity)
        case .storage:
            StoragePage(storage: host.storage)
        case .startupServices:
            StartupServicesGroup(store: host.startupServices)
                .padding(16)
                .glassEffect(in: .rect(cornerRadius: 16))
        }
    }
}

// The dashboard window. Q7: closing it hides it; active effects stay in
// force and the app stays in the menu bar until Quit.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate {
    private let host: ToolHost
    private let model: DashboardModel
    private let openSettings: () -> Void
    private var window: NSWindow?

    init(host: ToolHost, openSettings: @escaping () -> Void) {
        self.host = host
        self.openSettings = openSettings
        model = DashboardModel(host: host)
    }

    var isVisible: Bool { window?.isVisible == true }

    // `page` is where a link from outside leads, as a row of the menu bar menu does.
    func show(_ page: DashboardPage? = nil) {
        // A Dock icon and a main menu exist only while the window is open.
        NSApp.setActivationPolicy(.regular)
        let window = self.window ?? makeWindow()
        self.window = window
        // The window always opens on the Overview.
        if let page { model.page = page } else if !window.isVisible { model.page = .overview }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateVisibility()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        model.setVisible(false)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    // Covered, minimized or on another desktop, the window shows nothing, so nothing is read for it.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateVisibility()
    }

    private func updateVisibility() {
        guard let window else { return }
        model.setVisible(window.isVisible && window.occlusionState.contains(.visible))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "MacHelm"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.minSize = NSSize(width: 700, height: 460)
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        let content = NSHostingView(rootView: DashboardView(model: model, host: host, openSettings: openSettings))
        // The window's own minimum size bounds it, so SwiftUI is not asked to size the window.
        content.sizingOptions = []
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        window.contentView = background
        window.setContentSize(NSSize(width: 900, height: 680))
        window.center()
        window.setFrameAutosaveName("MacHelmDashboard")
        return window
    }
}
