import AppKit
import SwiftUI

@main
struct MacHelmApp: App {
    @NSApplicationDelegateAdaptor(MacHelmLifecycle.self) private var lifecycle

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…", action: lifecycle.openSettings)
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .newItem) {
                    Button("Open MacHelm", action: lifecycle.openDashboard)
                        .keyboardShortcut("0", modifiers: .command)
                }
            }
    }
}

@MainActor
final class MacHelmLifecycle: NSObject, NSApplicationDelegate {
    private var tools: ToolHost?
    private var dashboard: DashboardWindow?
    private var preferences: SettingsWindow?
    private var statusMenu: ToolkitMenuBar?
    private var terminating = false

    // A click on a fan alert can launch MacHelm; its delegate must exist first.
    func applicationWillFinishLaunching(_ notification: Notification) { _ = FanAlerts.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tools = ToolHost()
        let preferences = SettingsWindow(host: tools)
        let dashboard = DashboardWindow(host: tools, openSettings: preferences.show)
        self.tools = tools
        self.preferences = preferences
        self.dashboard = dashboard
        statusMenu = ToolkitMenuBar(host: tools, openDashboard: { dashboard.show() },
                                   openPage: { dashboard.show($0) })
        FanAlerts.shared.openCooling = { dashboard.show(.cooling) }
        let launch = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = launch?.eventID == kAEOpenApplication &&
            launch?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if loginLaunch {
            NSApp.setActivationPolicy(.accessory)
        } else {
            dashboard.show()
        }
    }

    func openDashboard() { dashboard?.show() }
    func openSettings() { preferences?.show() }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openDashboard()
        return true
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard let tools else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        tools.releaseBeforeQuit {
            DispatchQueue.main.async { application.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        tools?.cleanUpOnQuit()
    }
}
