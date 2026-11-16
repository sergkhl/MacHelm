import Foundation

struct ClaudeCLICommand: Equatable, Sendable {
    static let standard = ClaudeCLICommand(name: "claude")
    let name: String

    private init(name: String) { self.name = name }

    init?(_ input: String) {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = name.utf8.first, Self.isLetter(first) || first == 95,
              name.utf8.allSatisfy({ Self.isLetter($0) || (48...57).contains($0) || "_.+-".utf8.contains($0) }) else { return nil }
        self.init(name: name)
    }

    var usesZsh: Bool { self != Self.standard }

    private static func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
}

extension ClaudeInstallation {
    var canLaunch: Bool { command.usesZsh || executable != nil }

    func inventoryOutput(includeCompleted: Bool = false) -> Data? {
        guard command.usesZsh else {
            guard let executable else { return nil }
            let arguments = ["agents", "--json"] + (includeCompleted ? ["--all"] : [])
            return ClaudeCommand.run(executable, arguments: arguments, environment: environment, directory: home, timeout: 2)
        }

        // An interactive login shell loads aliases and functions. Frame its
        // output so prompts and banners emitted before the command stay out of the JSON.
        let marker = UUID().uuidString
        let script = """
        print -rn -- "$1"
        if \(command.name) agents --json\(includeCompleted ? " --all" : ""); then
            print -rn -- "$1"
        else
            exit $?
        fi
        """
        guard let stdout = ClaudeCommand.run(Self.zsh, arguments: ["-lic", script, "machelm", marker],
                                            environment: environment, directory: home, timeout: 2),
              let first = stdout.range(of: Data(marker.utf8)),
              let last = stdout.range(of: Data(marker.utf8), in: first.upperBound..<stdout.endIndex) else { return nil }
        let json = String(decoding: stdout[first.upperBound..<last.lowerBound], as: UTF8.self)
        // A profile command can set tab colors or terminal titles around its output.
        let stripped = json.replacingOccurrences(of: #"\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|\[[0-?]*[ -/]*[@-~])"#,
                                                  with: "", options: .regularExpression)
        return Data(stripped.utf8)
    }

    func ghosttyArguments(for id: ClaudeAttachID) -> [String] {
        let call = command.usesZsh ? "\(command.name) \"$@\"" : "\"$@\""
        let script = """
        if \(call); then
            exit 0
        else
            attach_exit=$?
            if [[ -t 0 ]]; then
                printf '\\nClaude attach exited with status %s. Press any key to close.\\n' "$attach_exit" >&2
                read -sk 1
            fi
            exit "$attach_exit"
        fi
        """
        let arguments = attachArguments(id)
        return ["-e", Self.zsh.path, command.usesZsh ? "-lic" : "-c", script, "machelm"] +
            (command.usesZsh ? Array(arguments.dropFirst()) : arguments)
    }

    func copyAttachCommand(_ id: ClaudeAttachID) -> String {
        attachArguments(id).map { argument in
            if !argument.isEmpty, argument.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "_/-=.+".utf8.contains(byte)
            }) { return argument }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    private static var zsh: URL { URL(fileURLWithPath: "/bin/zsh") }

    private func attachArguments(_ id: ClaudeAttachID) -> [String] {
        if command.usesZsh { return [command.name, "attach", id.value] }
        let arguments = [executable?.path ?? command.name, "attach", id.value]
        if let configOverride { return ["/usr/bin/env", "CLAUDE_CONFIG_DIR=" + configOverride] + arguments }
        return arguments
    }
}
