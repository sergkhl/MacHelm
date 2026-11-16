import Foundation
import XCTest
@testable import ClaudeCore

final class ClaudeSessionDatesTests: XCTestCase {
    private let first = UUID(uuidString: "7520ec9c-2023-4561-9833-1d4f7ff875ac")!
    private let second = UUID(uuidString: "932a1670-9656-4045-a086-994aa44df524")!
    private let firstHost = "local_9ead3883-563f-420c-beb9-a1187e7960d6"
    private let secondHost = "local_436ff054-4f6e-47c9-b849-3f2eff669088"
    private let original = Date(timeIntervalSince1970: 1_700_000_000)

    func testDesktopCreationDateSurvivesNewWorkerAndUsesExactConversation() throws {
        let home = try temporaryHome()
        let scope = try makeDesktopScope(home)
        try writeDesktop(firstHost, session: first, createdAt: 1_700_000_000_000, to: scope)
        try writeDesktop(secondHost, session: second, createdAt: 1_700_000_001_000, to: scope)
        var oldWorker = registration(first, host: firstHost, pid: 100)
        let otherSession = registration(second, host: secondHost, pid: 300)
        let expected = [first: original, second: original.addingTimeInterval(1)]

        XCTAssertEqual(ClaudeSessionDates.desktopDates(for: [oldWorker, otherSession], home: home), expected)
        oldWorker.pid = 500
        oldWorker.startedAt = 1_800_000_000_000
        XCTAssertEqual(ClaudeSessionDates.desktopDates(for: [oldWorker, otherSession], home: home), expected)
    }

    func testDesktopRejectsMismatchedIdentityAndDuplicateScopeCopies() throws {
        let home = try temporaryHome()
        let scope = try makeDesktopScope(home)
        let copy = try makeDesktopScope(home)
        try writeDesktop(firstHost, session: second, createdAt: 1_700_000_000_000, to: scope)
        try writeDesktop(secondHost, session: second, createdAt: 1_700_000_000_000, to: scope)
        try writeDesktop(secondHost, session: second, createdAt: 1_700_000_001_000, to: copy)

        let records = [registration(first, host: firstHost, pid: 100), registration(second, host: secondHost, pid: 200)]
        XCTAssertTrue(ClaudeSessionDates.desktopDates(for: records, home: home).isEmpty)
    }

    func testDesktopIgnoresSymlinkScopeAndMetadata() throws {
        let home = try temporaryHome()
        let scope = try makeDesktopScope(home)
        let external = home.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try writeDesktop(firstHost, session: first, createdAt: 1_700_000_000_000, to: external)
        try writeDesktop(secondHost, session: second, createdAt: 1_700_000_001_000, to: external)
        let linkedScope = scope.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linkedScope, withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: scope.appendingPathComponent(firstHost + ".json"),
                                                   withDestinationURL: external.appendingPathComponent(firstHost + ".json"))

        let records = [registration(first, host: firstHost, pid: 100), registration(second, host: secondHost, pid: 200)]
        XCTAssertTrue(ClaudeSessionDates.desktopDates(for: records, home: home).isEmpty)
    }

    func testCLIUsesFirstExactSessionTimestampAndDeduplicatesSharedProjectsRoot() throws {
        let home = try temporaryHome()
        let profile = home.appendingPathComponent("profile")
        let alternate = home.appendingPathComponent("alternate")
        let project = try makeProject("-one", in: profile)
        let rows = [line(second, timestamp: "2023-11-14T22:13:19Z"),
                    line(first, timestamp: "2023-11-14T22:13:20Z"),
                    line(first, timestamp: "2023-11-14T22:13:21.000Z")]
        try writeTranscript(first, contents: rows.joined(separator: "\n") + "\n", to: project)
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alternate.appendingPathComponent("projects"),
                                                   withDestinationURL: profile.appendingPathComponent("projects"))

        XCTAssertEqual(ClaudeSessionDates.cliDates(for: [first, second], configs: [profile, alternate]), [first: original])
    }

    func testCLIRejectsDuplicateFilesAndIncompleteOrInvalidTimestamps() throws {
        let home = try temporaryHome()
        let project = try makeProject("-one", in: home)
        let otherProject = try makeProject("-two", in: home)
        let complete = line(first, timestamp: "2023-11-14T22:13:20.000Z") + "\n"
        try writeTranscript(first, contents: complete, to: project)
        try writeTranscript(first, contents: complete, to: otherProject)
        let invalid = line(second, timestamp: "unavailable") + "\n"
        let incomplete = line(second, timestamp: "2023-11-14T22:13:20.000Z")
        try writeTranscript(second, contents: invalid + incomplete, to: otherProject)

        XCTAssertTrue(ClaudeSessionDates.cliDates(for: [first, second], configs: [home]).isEmpty)
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return home
    }

    private func makeDesktopScope(_ home: URL) throws -> URL {
        let scope = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        return scope
    }

    private func writeDesktop(_ host: String, session: UUID, createdAt: Int64, to scope: URL) throws {
        let json = """
        {"sessionId":"\(host)","cliSessionId":"\(session)","createdAt":\(createdAt),"lastActivityAt":1800000000000,"isArchived":true}
        """
        try Data(json.utf8).write(to: scope.appendingPathComponent(host + ".json"))
    }

    private func registration(_ session: UUID, host: String, pid: Int32) -> ClaudeSessionRecord {
        ClaudeSessionRecord(sessionId: session.uuidString, pid: pid, startedAt: 1_750_000_000_000,
                            name: "Shared title", cwd: "/tmp/shared", entrypoint: "claude-desktop", hostSessionId: host)
    }

    private func makeProject(_ name: String, in profile: URL) throws -> URL {
        let project = profile.appendingPathComponent("projects").appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func line(_ session: UUID, timestamp: String) -> String {
        """
        {"type":"queue-operation","sessionId":"\(session)","timestamp":"\(timestamp)"}
        """
    }

    private func writeTranscript(_ session: UUID, contents: String, to project: URL) throws {
        try Data(contents.utf8).write(to: project.appendingPathComponent(session.uuidString.lowercased() + ".jsonl"))
    }
}
