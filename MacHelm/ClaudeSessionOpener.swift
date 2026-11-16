import AppKit

enum ClaudeSessionAction: Equatable {
    case openSession, openClaude, copySessionID, copyAttachCommand

    var title: String {
        switch self {
        case .openSession: return "Open Session"
        case .openClaude: return "Open Claude"
        case .copySessionID: return "Copy Session ID"
        case .copyAttachCommand: return "Copy Attach Command"
        }
    }
}

@MainActor
struct ClaudeSessionOpener {
    private static let ghostty = "com.mitchellh.ghostty"
    private static let desktop = "com.anthropic.claudefordesktop"
    private let workspace = NSWorkspace.shared

    func action(for conversation: ClaudeConversation, installation: ClaudeInstallation?) -> ClaudeSessionAction? {
        switch conversation.location {
        case .desktop(let id):
            if let app = workspace.urlForApplication(withBundleIdentifier: Self.desktop) {
                return desktopLink(id, in: app) == nil ? .openClaude : .openSession
            }
        case .terminal(let terminal):
            if let terminal, focusScript(for: terminal) != nil { return .openSession }
        case .detached:
            if installation?.canLaunch == true, workspace.urlForApplication(withBundleIdentifier: Self.ghostty) != nil {
                return .openSession
            }
            return .copyAttachCommand
        case nil:
            if conversation.activity == .closed || conversation.id == .unknown { return nil }
        }
        return conversation.sessionID == nil ? nil : .copySessionID
    }

    func perform(_ action: ClaudeSessionAction, for session: ClaudeConversation, installation: ClaudeInstallation) async -> String? {
        switch (action, session.location) {
        case (.openSession, .desktop(let id)):
            return await openDesktop(session, exact: id)
        case (.openClaude, .desktop):
            return await openDesktop(session, exact: nil)
        case (.openSession, .terminal(let terminal)):
            guard let terminal, let worker = session.worker, let script = focusScript(for: terminal) else {
                return terminal.map { "Couldn’t focus the exact tab in \($0.name)." } ?? "Couldn’t identify this session’s terminal tab."
            }
            let focused = await Task.detached(priority: .userInitiated) {
                guard ClaudeDiscovery().stillHasTTY(terminal.tty, worker: worker) else { return false }
                return Self.runScript(script, [terminal.tty]) == "focused"
            }.value
            return focused ? nil : "Couldn’t focus the exact tab in \(terminal.name)."
        case (.openSession, .detached(let id)):
            guard let ghostty = workspace.urlForApplication(withBundleIdentifier: Self.ghostty), installation.canLaunch else {
                return "Ghostty or the Claude command is unavailable."
            }
            // Launch arguments apply to a fresh Ghostty instance.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = installation.ghosttyArguments(for: id)
            if installation.command.usesZsh {
                configuration.environment = installation.environment.filter { ["ZDOTDIR", "PATH", "CLAUDE_CONFIG_DIR"].contains($0.key) }
            }
            configuration.createsNewApplicationInstance = true
            let launched = try? await workspace.openApplication(at: ghostty, configuration: configuration)
            return launched == nil ? "Couldn’t launch Ghostty." : nil
        case (.copyAttachCommand, .detached(let id)):
            copy(installation.copyAttachCommand(id))
            return "Attach command copied."
        default:
            return "The session’s opening options changed."
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // An installed build may accept the URL at the OS level yet ignore the route.
    // This is the build on which navigation to an existing Code session was verified.
    private func desktopLink(_ id: ClaudeDesktopID?, in app: URL) -> URL? {
        guard let id, Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "5.11492.5" else { return nil }
        return URL(string: "claude://claude.ai/epitaxy/" + id.value)
    }

    private func openDesktop(_ session: ClaudeConversation, exact: ClaudeDesktopID?) async -> String? {
        guard let app = workspace.urlForApplication(withBundleIdentifier: Self.desktop) else { return "Claude Desktop is unavailable." }
        if let link = desktopLink(exact, in: app),
           (try? await workspace.open([link], withApplicationAt: app, configuration: .init())) != nil { return nil }
        do {
            _ = try await workspace.openApplication(at: app, configuration: .init())
            return "Select “\(session.title)” in Claude."
        } catch {
            return "Couldn’t open Claude Desktop."
        }
    }

    private func focusScript(for terminal: ClaudeTerminal) -> String? {
        guard let bundle = terminal.bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        switch bundle {
        case Self.ghostty:
            guard let path = app.bundleURL, let version = Bundle(url: path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  version.compare("1.4", options: .numeric) != .orderedAscending else { return nil }
            return Self.focusGhostty
        case "com.apple.Terminal": return Self.focusTerminal
        case "com.googlecode.iterm2": return Self.focusITerm
        default: return nil
        }
    }

    nonisolated private static func runScript(_ source: String, _ arguments: [String]) -> String? {
        ClaudeCommand.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", source, "--"] + arguments, timeout: 45)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static let focusGhostty = """
    on run argv
        set device to item 1 of argv
        tell application id "com.mitchellh.ghostty"
            set matches to every terminal whose tty is device
            if (count of matches) is not 1 then return "missing"
            focus item 1 of matches
            return "focused"
        end tell
    end run
    """

    private static let focusTerminal = """
    on run argv
        set device to item 1 of argv
        set matchCount to 0
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is device then
                        set matchCount to matchCount + 1
                        set foundWindow to contents of w
                        set foundTab to contents of t
                    end if
                end repeat
            end repeat
            if matchCount is not 1 then return "missing"
            set selected tab of foundWindow to foundTab
            set frontmost of foundWindow to true
            activate
            return "focused"
        end tell
    end run
    """

    private static let focusITerm = """
    on run argv
        set device to item 1 of argv
        set matchCount to 0
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with p in sessions of t
                        if tty of p is device then
                            set matchCount to matchCount + 1
                            set foundTab to contents of t
                            set foundPane to contents of p
                        end if
                    end repeat
                end repeat
            end repeat
            if matchCount is not 1 then return "missing"
            tell foundTab to select
            tell foundPane to select
            activate
            return "focused"
        end tell
    end run
    """
}
