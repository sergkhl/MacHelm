import Foundation
import XCTest
@testable import ClaudeCore

final class ClaudeLauncherTests: XCTestCase {
    func testCommandSettingAcceptsNamesAndRejectsShellSource() {
        XCTAssertEqual(ClaudeCLICommand.standard.name, "claude")
        XCTAssertEqual(ClaudeCLICommand(" claude-work ")?.name, "claude-work")
        for invalid in ["", "-claude", "claude --work", "claude; exit", "$(claude)", "a\nb"] {
            XCTAssertNil(ClaudeCLICommand(invalid))
        }
    }

    func testInventoryUsesConfiguredAliasAndIgnoresShellStartupAndColorOutput() throws {
        try withZshStartup("""
        print -r -- '[]'
        work_cli() {
            [[ "$*" == 'agents --json' ]] || return 1
            printf '\\033]11;#293134\\007'
            print -r -- '[{"id":"14bc06df","kind":"background","state":"blocked","name":"Work fixture"}]'
            printf '\\033]111\\033\\\\'
        }
        alias claude-work=work_cli
        """) { installation in
            let inventory = ClaudeDiscovery().readInventory(installation)
            XCTAssertEqual(inventory.quality, .complete)
            XCTAssertEqual(inventory.value.map(\.name), ["Work fixture"])
        }
    }

    func testFailedConfiguredCommandCannotUseStartupJSONOrDefaultClaude() throws {
        try withZshStartup("""
        print -r -- '[{"id":"14bc06df","kind":"background"}]'
        claude() { print -r -- '[{"id":"14bc06df","kind":"background"}]' }
        claude-work() { return 1 }
        """) { installation in
            let inventory = ClaudeDiscovery().readInventory(installation)
            XCTAssertEqual(inventory.quality, .unavailable)
            XCTAssertTrue(inventory.value.isEmpty)
        }
    }

    func testGhosttyAndClipboardUseTheSameConfiguredCommandAndAttachID() throws {
        try withZshStartup("""
        claude-work() {
            [[ "$#" == 2 && "$1" == attach && "$2" == 14bc06df ]] || return 1
            print -r -- 'work command attached'
        }
        """) { installation in
            let id = try XCTUnwrap(ClaudeAttachID("14bc06df"))
            XCTAssertEqual(installation.copyAttachCommand(id), "claude-work attach 14bc06df")
            let ghosttyArguments = installation.ghosttyArguments(for: id)
            XCTAssertEqual(Array(ghosttyArguments.prefix(3)), ["-e", "/bin/zsh", "-lic"])
            let output = ClaudeCommand.run(URL(fileURLWithPath: ghosttyArguments[1]),
                                           arguments: Array(ghosttyArguments.dropFirst(2)),
                                           environment: installation.environment, directory: installation.home, timeout: 2)
            let text = String(decoding: try XCTUnwrap(output), as: UTF8.self)
            XCTAssertTrue(text.contains("work command attached"))
            XCTAssertFalse(text.contains("Press any key to close"))
        }
    }

    private func withZshStartup(_ source: String, _ test: (ClaudeInstallation) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try source.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["ZDOTDIR"] = directory.path
        try test(ClaudeInstallation(command: XCTUnwrap(ClaudeCLICommand("claude-work")), environment: env, home: directory))
    }
}
