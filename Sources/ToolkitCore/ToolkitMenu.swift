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
    case fanControl(on: Bool, canToggle: Bool)
    // The note says what holds when that is less than the switch asks for.
    case keepAwake(on: Bool, note: String?)
    case storage(available: Int64?)
    case startupServices
    // Opens Activity even before the first figures are ready.
    case activity(span: String?)
    case process(ToolkitMenuProcess)
    // No figures yet.
    case measuring
    case openAtLogin(on: Bool)
    case quit
}

// The menu's quick controls and links to the dashboard. Activity keeps the
// five heaviest CPU groups visible beneath its own navigation entry.
public enum ToolkitMenu {
    public static func entries(fanOn: Bool, fanCanToggle: Bool,
                               keepAwakeOn: Bool, keepAwakeNote: String?,
                               availableSpace: Int64?,
                               heaviest: [ToolkitMenuProcess]?, span: String,
                               openAtLogin: Bool) -> [ToolkitMenuEntry] {
        var entries: [ToolkitMenuEntry] = [.openDashboard, .separator,
                                           .fanControl(on: fanOn, canToggle: fanCanToggle),
                                           .keepAwake(on: keepAwakeOn, note: keepAwakeNote),
                                           .storage(available: availableSpace), .startupServices, .separator,
                                           .activity(span: heaviest == nil ? nil : span)]
        if let heaviest {
            entries += heaviest.isEmpty ? [.process(ToolkitMenuProcess(name: "Nothing to list", value: ""))]
                                        : heaviest.prefix(5).map { .process($0) }
        } else {
            entries.append(.measuring)
        }
        return entries + [.separator, .openAtLogin(on: openAtLogin), .quit]
    }
}
