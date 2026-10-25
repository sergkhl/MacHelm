import SwiftUI

struct CursorControls: View {
    @ObservedObject var controller: CursorController

    static var help: String {
        "Press \(CursorController.shortcutLabel) to hide or restore the system pointer in any app. The shortcut is fixed and needs no Accessibility permission.\n\nThis feature is experimental. MacHelm keeps its hide request active until you restore it or quit. The pointer can still appear over the Dock, and some games draw their own pointer."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolRow(icon: "cursorarrow", title: "Cursor hide",
                    subtitle: controller.hidden ? "Hide requested · \(CursorController.shortcutLabel)" : CursorController.shortcutLabel,
                    isActive: controller.hidden) {
                ToolIconButton(controller.hidden ? "Restore cursor" : "Hide cursor",
                               symbol: controller.hidden ? "eye" : "eye.slash") { controller.toggle() }
                    .controlSize(.small)
                    .accessibilityIdentifier("cursor-toggle")
            }
            if !controller.shortcutAvailable && controller.message == nil {
                Label("Shortcut unavailable", systemImage: "keyboard")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Another app may already use \(CursorController.shortcutLabel).")
            }
            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cursor-status")
            }
        }
        .padding(.bottom, 8)
    }
}

struct CursorPage: View {
    @ObservedObject var controller: CursorController

    var body: some View {
        ToolPanel(title: "Cursor", symbol: "cursorarrow", info: CursorControls.help) {
            CursorControls(controller: controller)
        }
    }
}
