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
                    cooling.frame(minWidth: 300)
                    power.frame(minWidth: 280)
                }
                VStack(spacing: 16) { cooling; power }
            }
            ToolPanel(group: .activity, open: { open(.activity) }) {
                ActivityOverviewCard(store: host.activity)
            }
            ToolPanel(group: .storage, open: { open(.storage) }) {
                StorageOverviewCard(storage: host.storage)
            }
            ToolPanel(group: .startupServices, open: { open(.startupServices) }) {
                ServicesOverviewLine(store: host.startupServices)
            }
            ToolPanel(group: .cursor, info: CursorControls.help, open: { open(.cursor) }) {
                CursorControls(controller: host.cursor)
            }
        }
    }

    private var power: some View {
        ToolPanel(group: .power, open: { open(.power) }) {
            PowerOverviewCard(power: host.power)
        }
    }

    private var cooling: some View {
        ToolPanel(group: .cooling, open: { open(.cooling) }) {
            CoolingOverviewCard(service: host.cooling)
        }
    }
}

// How many services run, and whether any needs a look. They are managed on their page.
private struct ServicesOverviewLine: View {
    @ObservedObject var store: StartupServicesStore
    var body: some View {
        Text(summary).font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var summary: String {
        if let failure = store.loadFailure { return failure }
        guard store.loaded else { return "Reading…" }
        guard !store.services.isEmpty else { return "No services yet" }
        let running = store.services.filter { if case .running = $0.activity { return true } else { return false } }.count
        let troubled = store.services.filter { !$0.problems.isEmpty || store.failures[$0.id] != nil }.count
        var parts = ["\(running)/\(store.services.count) running"]
        if troubled > 0 { parts.append("\(troubled) need\(troubled == 1 ? "s" : "") attention") }
        return parts.joined(separator: ", ")
    }
}
