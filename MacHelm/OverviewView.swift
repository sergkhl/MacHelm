import SwiftUI

// The Overview: every tool's switch and its live readings, without detail.
// A page holds the rest.
struct OverviewPage: View {
    let host: ToolHost
    let open: (DashboardPage) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    cursor.frame(minWidth: 300)
                    cooling.frame(minWidth: 300)
                }
                VStack(spacing: 16) { cursor; cooling }
            }
            ToolPanel(group: .power) {
                PowerOverviewCard(power: host.power) { open(.power) }
            }
            ToolPanel(group: .activity) {
                ActivityOverviewCard(store: host.activity) { open(.activity) }
            }
            ToolPanel(group: .storage) {
                StorageOverviewCard(storage: host.storage) { open(.storage) }
            }
            ToolPanel(group: .startupServices) {
                ServicesOverviewLine(store: host.startupServices) { open(.startupServices) }
            }
        }
    }

    private var cursor: some View {
        ToolPanel(group: .cursor) {
            CursorControls(controller: host.cursor)
        }
    }

    private var cooling: some View {
        ToolPanel(group: .cooling) {
            CoolingOverviewCard(service: host.cooling) { open(.cooling) }
        }
    }
}

// How many services run, and whether any needs a look. They are managed on their page.
private struct ServicesOverviewLine: View {
    @ObservedObject var store: StartupServicesStore
    let openServices: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(summary).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Manage", action: openServices).controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    private var summary: String {
        if let failure = store.loadFailure { return failure }
        guard store.loaded else { return "Reading…" }
        guard !store.services.isEmpty else { return "No services yet" }
        let running = store.services.filter { if case .running = $0.activity { return true } else { return false } }.count
        let troubled = store.services.filter { !$0.problems.isEmpty || store.failures[$0.id] != nil }.count
        var parts = ["\(running) of \(store.services.count) running"]
        parts.append(troubled == 0 ? "no problems" : troubled == 1 ? "1 needs attention" : "\(troubled) need attention")
        return parts.joined(separator: ", ")
    }
}
