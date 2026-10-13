import Foundation

// One of the heaviest processes, as the menu shows it.
public struct ToolkitMenuProcess: Equatable {
    public var name: String
    // Who started this copy of the app, where it has an origin.
    public var origin: String?
    public var value: String

    public init(name: String, origin: String? = nil, value: String) {
        self.name = name
        self.origin = origin
        self.value = value
    }
}

public enum ToolkitMenuEntry: Equatable {
    case openDashboard
    case separator
    case fanControl(subtitle: String, on: Bool, canToggle: Bool)
    // The note says what holds when that is less than the switch asks for.
    case keepAwake(on: Bool, note: String?)
    case sleepNow
    // "Heaviest by CPU, last 10 seconds"
    case heaviestHeader(String)
    case process(ToolkitMenuProcess)
    // No figures yet.
    case measuring
    case openAtLogin(on: Bool)
    case quit
}

// What the menu bar menu holds (owner, 2026-10-11 and SR-Q5; Keep Awake,
// Sleep Now and the heaviest processes since 2026-10-12, Q9 and Q17 of the
// Power and Storage record). Startup services are managed in the dashboard
// and are not listed here.
public enum ToolkitMenu {
    public static func entries(fanSubtitle: String, fanOn: Bool, fanCanToggle: Bool,
                               keepAwakeOn: Bool, keepAwakeNote: String?,
                               heaviest: [ToolkitMenuProcess]?, span: String,
                               openAtLogin: Bool) -> [ToolkitMenuEntry] {
        var entries: [ToolkitMenuEntry] = [.openDashboard, .separator,
                                           .fanControl(subtitle: fanSubtitle, on: fanOn, canToggle: fanCanToggle),
                                           .keepAwake(on: keepAwakeOn, note: keepAwakeNote), .sleepNow, .separator]
        if let heaviest {
            entries.append(.heaviestHeader("Heaviest by CPU, last \(span)"))
            entries += heaviest.isEmpty ? [.process(ToolkitMenuProcess(name: "Nothing to list", value: ""))]
                                        : heaviest.prefix(5).map { .process($0) }
        } else {
            entries += [.heaviestHeader("Heaviest by CPU"), .measuring]
        }
        return entries + [.separator, .openAtLogin(on: openAtLogin), .quit]
    }
}
