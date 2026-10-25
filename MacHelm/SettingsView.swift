import AppKit
import SwiftUI

// The settings that belong to the app as a whole, not to one tool group's
// page: opening at login, the menu bar readout, and how often Activity reads.
struct ToolkitSettingsView: View {
    @ObservedObject var services: StartupServicesStore
    @ObservedObject var fan: FanControlService
    @ObservedObject var activity: ActivityStore
    @ObservedObject var storage: StorageService
    // Read when the window opens and when asked: macOS gives no notice of a change.
    @State private var fullDiskAccess: Bool? = StorageService.fullDiskAccess

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle("Open at login", isOn: Binding(get: { services.openAtLogin }, set: { services.setOpenAtLogin($0) }))
                        .accessibilityLabel("Open MacHelm at login")
                    InfoButton("Opens MacHelm in the menu bar at login without showing its window. Startup services start at login whether or not MacHelm is open.", label: "About opening at login")
                }
                if let failure = services.generalFailure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            Section("Menu Bar") {
                HStack {
                    Toggle("Temperature & fan speed",
                           isOn: Binding(get: { fan.menuBarReadoutEnabled }, set: { fan.setMenuBarReadout($0) }))
                        .accessibilityLabel("Show temperature and fan speed in the menu bar")
                        .accessibilityIdentifier("fan-control-menu-bar-readout")
                    InfoButton("Shows the CPU temperature above the faster fan's speed when the fan helper is approved. While visible, the helper reads the fans once a second.", label: "About the menu bar readout")
                }
            }
            Section {
                Picker("Background", selection: $activity.backgroundPace) {
                    ForEach(ActivityPace.background, id: \.self) { Text(ActivityText.span($0)).tag($0) }
                }
                .accessibilityLabel("Activity background reading interval")
                .accessibilityIdentifier("activity-background-pace")
                Picker("While visible", selection: $activity.onScreenPace) {
                    ForEach(ActivityPace.onScreen, id: \.self) { Text($0 == 1 ? "1 second" : ActivityText.span($0)).tag($0) }
                }
                .accessibilityLabel("Activity reading interval while lists or menu are open")
                .accessibilityIdentifier("activity-on-screen-pace")
            } header: {
                HStack {
                    Text("Activity")
                    InfoButton("Activity reads whenever MacHelm runs, so the menu has figures ready. While visible applies when the lists or menu are open. A slower interval costs less; processes that start and end between readings are not seen. An interval never exceeds the averaging window selected on Activity.", label: "About Activity reading intervals")
                }
            }
            Section("Storage") {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(fullDiskAccess == true ? "On" : fullDiskAccess == false ? "Off" : "Unknown")
                        InfoButton("Storage needs Full Disk Access to measure and remove device backups, measure the Trash, and read some apps' data. It also lets MacHelm and what it starts read Mail, Messages and Safari data. After enabling it, macOS asks to quit and reopen MacHelm.", label: "About Full Disk Access")
                        ToolIconButton("Check Full Disk Access", symbol: "arrow.clockwise") { fullDiskAccess = StorageService.fullDiskAccess }
                        ToolIconButton("Open Full Disk Access settings", symbol: "gearshape") { storage.openFullDiskAccessSettings() }
                    }
                    .controlSize(.small)
                }
                .accessibilityIdentifier("storage-full-disk-access")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            services.refreshOpenAtLogin()
            fullDiskAccess = StorageService.fullDiskAccess
        }
    }
}

// The Settings window, opened with ⌘, or from the dashboard's sidebar.
@MainActor
final class SettingsWindow {
    private let host: ToolHost
    private var window: NSWindow?

    init(host: ToolHost) {
        self.host = host
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let content = NSHostingController(rootView: ToolkitSettingsView(services: host.startupServices, fan: host.cooling,
                                                                        activity: host.activity, storage: host.storage))
        let window = NSWindow(contentViewController: content)
        window.title = "MacHelm Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
