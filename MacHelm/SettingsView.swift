import AppKit
import SwiftUI

// The settings that belong to the app as a whole, not to one tool group's
// page: opening at login, the menu bar readout, and how often Activity reads.
struct ToolkitSettingsView: View {
    @ObservedObject var services: StartupServicesStore
    @ObservedObject var fan: FanControlService
    @ObservedObject var activity: ActivityStore

    var body: some View {
        Form {
            Section {
                Toggle("Open MacHelm at login", isOn: Binding(get: { services.openAtLogin }, set: { services.setOpenAtLogin($0) }))
                Text("Opens MacHelm in the menu bar when you log in, without showing its window. Your startup services start at login whether or not MacHelm is open.")
                    .font(.caption).foregroundStyle(.secondary)
                if let failure = services.generalFailure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            Section {
                Toggle("Show temperature and fan speed in the menu bar",
                       isOn: Binding(get: { fan.menuBarReadoutEnabled }, set: { fan.setMenuBarReadout($0) }))
                    .accessibilityIdentifier("fan-control-menu-bar-readout")
                Text("The CPU temperature above the faster fan's speed, while the fan helper is approved. While it is shown, the helper reads the fans once a second.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Activity") {
                Picker("Read the processes in the background every", selection: $activity.backgroundPace) {
                    ForEach(ActivityPace.background, id: \.self) { Text(ActivityText.span($0)).tag($0) }
                }
                .accessibilityIdentifier("activity-background-pace")
                Picker("While the lists or the menu are open, every", selection: $activity.onScreenPace) {
                    ForEach(ActivityPace.onScreen, id: \.self) { Text($0 == 1 ? "second" : ActivityText.span($0)).tag($0) }
                }
                .accessibilityIdentifier("activity-on-screen-pace")
                Text("Activity reads whenever MacHelm runs, so the menu bar menu has figures at once. A slower pace costs less; a process that starts and ends between two readings is not seen. A pace is never longer than the window chosen on the Activity page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { services.refreshOpenAtLogin() }
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
                                                                        activity: host.activity))
        let window = NSWindow(contentViewController: content)
        window.title = "MacHelm Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
