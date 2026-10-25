import SwiftUI
import UniformTypeIdentifiers

// The Startup Services group of the dashboard: the catalog, each service's
// automatic-startup preference, its state in this session and its actions.
struct StartupServicesGroup: View {
    @ObservedObject var store: StartupServicesStore
    @State private var expanded: Set<String> = []
    @State private var showAdd = false
    @State private var showImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !store.isInstalled {
                notice("Install in Applications to manage services. Viewing and importing are available.",
                       symbol: "arrow.down.app")
            }
            if store.permissionBlocked {
                VStack(alignment: .leading, spacing: 6) {
                    notice("Background items blocked. Services cannot start.",
                           symbol: "hand.raised")
                    HStack {
                        InfoButton("Enable MacHelm in Login Items & Extensions. This switch also covers the Fan Control helper.", label: "About blocked background items")
                        ToolIconButton("Open Login Items & Extensions", symbol: "gearshape") { store.openLoginItemsSettings() }
                    }
                }
            }
            if let failure = store.loadFailure {
                notice(failure, symbol: "exclamationmark.triangle")
            }
            if let failure = store.generalFailure {
                HStack(alignment: .top) {
                    notice(failure, symbol: "exclamationmark.triangle")
                    ToolIconButton("Dismiss error", symbol: "xmark") { store.clearFailure(for: nil) }
                }
            }
            if store.services.isEmpty, store.loaded, store.loadFailure == nil {
                Text("No services. Import or add one to get started.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(store.services) { status in
                ServiceRow(store: store, status: status, isExpanded: Binding(
                    get: { expanded.contains(status.id) },
                    set: { open in if open { expanded.insert(status.id) } else { expanded.remove(status.id) } }))
                if status.id != store.services.last?.id { Divider() }
            }
        }
        .padding(.bottom, 10)
        .sheet(isPresented: $showAdd) { AddServiceSheet(store: store) }
        .sheet(isPresented: $showImport) { ImportServiceSheet(store: store) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            InfoButton("Each service is its own launchd job and keeps running after MacHelm quits. Import adds an existing LaunchAgent for viewing without changing it. Add saves a program or script switched off, without running it.", label: "About Startup Services")
            Spacer(minLength: 8)
            ToolIconButton("Import a LaunchAgent", symbol: "square.and.arrow.down") { showImport = true }
            ToolIconButton("Add a service", symbol: "plus") { showAdd = true }
        }
        .controlSize(.small)
    }

    private func notice(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

private struct ServiceRow: View {
    @ObservedObject var store: StartupServicesStore
    let status: ServiceStatus
    @Binding var isExpanded: Bool
    @State private var confirmRemove = false
    @State private var confirmTakeOver = false
    @State private var confirmUseChange = false
    @State private var showLog = false
    @State private var draftName = ""

    private var definition: ServiceDefinition { status.definition }
    private var isBusy: Bool { store.busy.contains(status.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    identity
                    Spacer(minLength: 8)
                    controls
                }
                VStack(alignment: .leading, spacing: 6) {
                    identity
                    HStack(spacing: 10) { controls }.padding(.leading, 50)
                }
            }
            .controlSize(.small)

            ForEach(status.problems, id: \.message) { problem in
                Label(problem.message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
            if let failure = store.failures[status.id] {
                HStack(alignment: .top) {
                    Label(failure, systemImage: "xmark.octagon")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") { store.clearFailure(for: status.id) }.controlSize(.mini)
                }
                .padding(.leading, 24)
            }
            if isExpanded { details.padding(.leading, 24).padding(.top, 2) }
        }
        .padding(.vertical, 6)
        .confirmationDialog("Remove \(definition.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.perform(.remove, on: status.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(definition.isManaged
                 ? "Its startup definition is removed from MacHelm. Its scripts, data, logs and the backup of its original LaunchAgent are kept, and the original is not switched back on."
                 : "It is removed from this list only. Its LaunchAgent is not touched.")
        }
        .confirmationDialog("Manage \(definition.name) with MacHelm?", isPresented: $confirmTakeOver) {
            Button("Manage with MacHelm") { store.perform(.takeOver, on: status.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MacHelm backs up the original LaunchAgent exactly and puts its own in the same place, so the service appears under MacHelm in Login Items & Extensions. Nothing is started or stopped now: a service that is running keeps running from its original definition, restarts included, until you stop and start it here or log in again.")
        }
        .confirmationDialog("Use the changed LaunchAgent for \(definition.name)?", isPresented: $confirmUseChange) {
            Button("Use Changed Definition") { store.perform(.useOutsideDefinition, on: status.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The LaunchAgent now in your LaunchAgents folder was not written by MacHelm. MacHelm backs it up exactly, takes its program, arguments and schedule as this service's definition, and puts its own LaunchAgent back in that place. Nothing is started or stopped now.")
        }
        .sheet(isPresented: $showLog) { ServiceLogSheet(name: definition.name, paths: store.logPaths(for: definition)) }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide details of \(definition.name)" : "Show details of \(definition.name)")

            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(definition.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(status.stateText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("startup-service-state")
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var controls: some View {
        if definition.isManaged {
            Toggle("At login", isOn: Binding(get: { definition.automaticStartup },
                                             set: { store.setAutomaticStartup(status.id, enabled: $0) }))
                .toggleStyle(.switch).controlSize(.mini).font(.caption).fixedSize()
                .disabled(isBusy || !store.isInstalled)
                .help("Whether macOS starts this service when you log in. It applies from the next login and does not start or stop the service now.")
                .accessibilityLabel("Start \(definition.name) at login")
        }
        if isBusy { ProgressView().controlSize(.small) }
        ForEach(status.actions.filter { ![.remove, .takeOver, .useOutsideDefinition].contains($0) }, id: \.self) { action in
            Button(action.title) { store.perform(action, on: status.id) }
                .fixedSize()
                .disabled(isBusy)
                .help(help(for: action))
                .accessibilityLabel("\(action.title) \(definition.name)")
        }
        if status.actions.contains(.takeOver) {
            Button(ServiceAction.takeOver.title) { confirmTakeOver = true }.fixedSize().disabled(isBusy)
        }
        if status.actions.contains(.useOutsideDefinition) {
            Button(ServiceAction.useOutsideDefinition.title) { confirmUseChange = true }.fixedSize().disabled(isBusy)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            detail("Trigger", definition.triggerDescription)
            detail("Program", definition.command.program, monospaced: true)
            if definition.command.arguments.count > 1 {
                detail("Arguments", definition.command.arguments.dropFirst().map(Self.quoted).joined(separator: " "), monospaced: true)
            }
            if let directory = definition.command.workingDirectory { detail("Working folder", directory, monospaced: true) }
            detail("launchd label", definition.label, monospaced: true)
            detail("Owner", ownerText, info: ownerInfo)
            if case .managed(_, let backup?) = definition.ownership {
                detail("Backup", backup.path, monospaced: true)
            }
            if let result = status.lastResult { detail("Last result", result.summary) }
            if let runs = status.runs { detail("Session runs", "\(runs)") }
            ForEach(definition.dependencies, id: \.self) { detail("Depends on", $0) }
            detail("Readiness", "Not checked", info: "Running means a process exists. MacHelm has not checked whether the service is ready to accept work.")

            HStack(spacing: 8) {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .onSubmit(rename)
                    .accessibilityLabel("Name of \(definition.name)")
                Button("Rename", action: rename)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty || draftName == definition.name)
                Spacer()
                ToolIconButton("View service log", symbol: "doc.text.magnifyingglass") { showLog = true }
                    .disabled(store.logPaths(for: definition).isEmpty)
                    .help(store.logPaths(for: definition).isEmpty ? "This service does not write a log file." : "Show the end of this service's log.")
                if status.actions.contains(.remove) {
                    Button("Remove…", role: .destructive) { confirmRemove = true }.disabled(isBusy)
                } else if definition.isManaged {
                    Button("Remove…") {}.disabled(true)
                        .help("Stop the service and wait until it has stopped before removing it.")
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .onAppear { draftName = definition.name }
        .onChange(of: definition.name) { _, name in draftName = name }
    }

    private var ownerText: String {
        guard definition.isManaged else { return "Original LaunchAgent" }
        switch status.loadedInstance {
        case .original: return "MacHelm · original loaded"
        default: return "MacHelm"
        }
    }

    private var ownerInfo: String? {
        guard definition.isManaged else { return "The original LaunchAgent owns this service. MacHelm only shows it." }
        guard case .original = status.loadedInstance else { return nil }
        return "MacHelm manages this service, but the job loaded now still uses the original definition. The managed definition applies after Stop and Start here, or from the next login."
    }

    private func detail(_ title: String, _ value: String, monospaced: Bool = false, info: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 118, alignment: .trailing)
            Text(value).font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let info { InfoButton(info, label: "About \(title.lowercased())") }
        }
        .accessibilityElement(children: .contain)
    }

    private func rename() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != definition.name else { return }
        store.rename(status.id, to: name)
    }

    private func help(for action: ServiceAction) -> String {
        switch action {
        case .start: return "Start it for this session. Automatic startup is not changed."
        case .stop: return "End it for this session so that it is not restarted. Automatic startup is not changed."
        case .runNow: return "Run it once now. A run already in progress is not doubled."
        case .resumeSchedule: return "Put its schedule back for this session without running it now."
        case .takeOver, .useOutsideDefinition, .remove: return ""
        }
    }

    private var stateSymbol: String {
        switch status.activity {
        case .running: return "circle.fill"
        case .waiting: return "arrow.clockwise.circle"
        case .idle: return definition.kind == .scheduled ? "clock" : "checkmark.circle"
        case .stopping: return "hourglass"
        case .inactive: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var stateColor: Color {
        if !status.problems.isEmpty { return .orange }
        switch status.activity {
        case .running: return .green
        case .waiting: return .orange
        default: return .secondary
        }
    }

    private static func quoted(_ argument: String) -> String {
        argument.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) ? "\u{201C}\(argument)\u{201D}" : argument
    }
}

private struct ServiceLogSheet: View {
    let name: String
    let paths: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Log of \(name)").font(.headline)
                Spacer()
                if paths.count > 1 {
                    Picker("File", selection: $selected) {
                        ForEach(paths, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 240)
                }
            }
            Text(selected).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                Text(text).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary, in: .rect(cornerRadius: 8))
            HStack {
                ToolIconButton("Reload log", symbol: "arrow.clockwise") { load() }
                ToolIconButton("Show log in Finder", symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected)])
                }
                .disabled(!FileManager.default.fileExists(atPath: selected))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 420)
        .onAppear { selected = paths.first ?? ""; load() }
        .onChange(of: selected) { _, _ in load() }
    }

    private func load() {
        let path = selected
        guard !path.isEmpty else { text = "This service does not write a log file."; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let tail = StartupServicesStore.logTail(at: path)
            DispatchQueue.main.async { if path == selected { text = tail } }
        }
    }
}

private struct ImportServiceSheet: View {
    @ObservedObject var store: StartupServicesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Import LaunchAgent").font(.headline)
                InfoButton("Import adds a LaunchAgent for viewing. It keeps running under its own definition; nothing is started, stopped or changed. Choose Manage with MacHelm afterwards to manage it here.", label: "About importing LaunchAgents")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.discovered.isEmpty {
                        Text("No LaunchAgents found in \(store.launchAgentsFolder.path).")
                            .font(.callout).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(store.discovered) { agent in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(listedName(agent) ?? agent.definition?.name ?? agent.label
                                     ?? URL(fileURLWithPath: agent.path).lastPathComponent)
                                    .font(.subheadline.weight(.semibold))
                                Text(agent.label ?? agent.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if !agent.inCatalog, let definition = agent.definition {
                                    Text(definition.triggerDescription).font(.caption).foregroundStyle(.secondary)
                                } else if let refusal = agent.refusal {
                                    Text(refusal).font(.caption).foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            if agent.inCatalog {
                                Label("Imported", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                            } else if agent.definition != nil {
                                Button("Import") { store.importLaunchAgent(at: URL(fileURLWithPath: agent.path)) }
                                    .controlSize(.small)
                                    .accessibilityLabel("Import \(agent.label ?? agent.path)")
                            }
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        Divider()
                    }
                }
            }
            .background(.quaternary, in: .rect(cornerRadius: 8))
            if let failure = store.generalFailure {
                Label(failure, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                ToolIconButton("Choose a LaunchAgent file", symbol: "folder") { chooseFile() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { store.clearFailure(for: nil); store.loadDiscovered() }
    }

    private func listedName(_ agent: DiscoveredLaunchAgent) -> String? {
        guard agent.inCatalog else { return nil }
        return store.services.first { $0.id == agent.label }?.definition.name
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.launchAgentsFolder
        panel.message = "Choose a LaunchAgent property list to import."
        if panel.runModal() == .OK, let url = panel.url { store.importLaunchAgent(at: url) }
    }
}

private struct AddServiceSheet: View {
    private enum Preset: String, CaseIterable, Identifiable {
        case onceAtLogin = "Once at login"
        case keepRunning = "Keep running"
        case calendar = "On a schedule"
        var id: String { rawValue }
    }

    @ObservedObject var store: StartupServicesStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var program = ""
    @State private var arguments = ""
    @State private var workingDirectory = ""
    @State private var preset = Preset.onceAtLogin
    @State private var hour = 9
    @State private var minute = 0
    @State private var weekday = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add Service").font(.headline)
                InfoButton("Arguments are entered one per line and passed exactly as written; no shell reads them. The working folder is optional. The service is saved switched off: it does not run now or start at login until enabled.", label: "About adding a service")
            }
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Program", text: $program)
                        .accessibilityLabel("Program or script")
                    ToolIconButton("Choose a program or script", symbol: "folder") { choose(directories: false) { program = $0 } }
                }
                TextField("Arguments", text: $arguments, axis: .vertical).lineLimit(2...5)
                    .help("One argument per line")
                    .accessibilityLabel("Arguments, one per line")
                HStack {
                    TextField("Working folder", text: $workingDirectory)
                        .help("Optional working directory")
                        .accessibilityLabel("Working directory, optional")
                    ToolIconButton("Choose a working folder", symbol: "folder") { choose(directories: true) { workingDirectory = $0 } }
                }
                Picker("Runs", selection: $preset) {
                    ForEach(Preset.allCases) { Text($0.rawValue).tag($0) }
                }
                if preset == .calendar {
                    Picker("Day", selection: $weekday) {
                        Text("Every day").tag(-1)
                        ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                    }
                    Stepper("Hour: \(hour)", value: $hour, in: 0...23)
                    Stepper("Minute: \(String(format: "%02d", minute))", value: $minute, in: 0...59)
                }
            }
            if let failure = store.generalFailure {
                Label(failure, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || program.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { store.clearFailure(for: nil) }
    }

    private func add() {
        let lines = arguments.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let requestPreset: NewServiceRequest.Preset
        switch preset {
        case .onceAtLogin: requestPreset = .onceAtLogin
        case .keepRunning: requestPreset = .keepRunning
        case .calendar:
            requestPreset = .calendar([ServiceCalendarEntry(minute: minute, hour: hour, weekday: weekday >= 0 ? weekday : nil)])
        }
        let request = NewServiceRequest(name: name, program: program, arguments: lines,
                                        workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory, preset: requestPreset)
        store.add(request) { added in if added { dismiss() } }
    }

    private func choose(directories: Bool, _ assign: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { assign(url.path) }
    }
}
