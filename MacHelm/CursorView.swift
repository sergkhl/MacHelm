import SwiftUI

struct CursorControls: View {
    @ObservedObject var controller: CursorController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolRow(icon: "cursorarrow", title: "Cursor hide",
                    subtitle: controller.hidden ? "Hide requested · press again to restore" : CursorController.shortcutLabel,
                    isActive: controller.hidden) {
                Button(controller.hidden ? "Restore" : "Hide") { controller.toggle() }
                    .controlSize(.small)
                    .accessibilityIdentifier("cursor-toggle")
            }
            if !controller.shortcutAvailable {
                Label("The global shortcut is unavailable. Another app may already use it.", systemImage: "keyboard")
                    .font(.caption).foregroundStyle(.secondary)
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
        ToolPanel(group: .cursor) {
            VStack(alignment: .leading, spacing: 12) {
                CursorControls(controller: controller)
                Text("Press \(CursorController.shortcutLabel) to hide or restore the system pointer while another app is active. The shortcut is fixed and does not require Accessibility permission.")
                Text("This feature is experimental. If macOS shows the pointer again before you restore it, MacHelm hides it again within a tenth of a second, except while it is over the Dock. Some games draw their own pointer. MacHelm restores its own hide request on Quit.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)
        }
    }
}
