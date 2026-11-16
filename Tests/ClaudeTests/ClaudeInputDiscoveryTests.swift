import Foundation
import XCTest
@testable import ClaudeCore

final class ClaudeInputDiscoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_800_000)
    private let account = UUID()
    private let scope = UUID()

    func testDormantConversationCombinesReplyAndUnknownDraftAndSortsByCreation() throws {
        let earlier = stored("Zulu", age: 18_000)
        let later = stored("Alpha", age: 600)
        let expired = stored("Expired", age: 15_000)
        var frame = ClaudeDiscoveryFrame()
        frame.input.value.desktop = [earlier.id: earlier, later.id: later, expired.id: expired]
        frame.input.value.transcripts[try XCTUnwrap(earlier.sessionID)] = .init(
            replies: [.init(text: "Please confirm the angle.", date: now.addingTimeInterval(-12))]
        )
        frame.input.value.drafts = [
            earlier.id: [nil, now.addingTimeInterval(-7_201)],
            later.id: [now.addingTimeInterval(-7_200)],
            expired.id: [now.addingTimeInterval(-7_201)]
        ]
        var reconciler = ClaudeReconciler()
        let listed = reconciler.update(frame, at: now).conversations
        XCTAssertEqual(listed.map(\.title), ["Zulu", "Alpha"])
        XCTAssertEqual(listed[0].inputItems.map(\.kind), [.reply, .draft])
        XCTAssertNil(listed[0].inputItems[1].date)
        XCTAssertEqual(listed[1].inputItems.map(\.kind), [.draft])
        XCTAssertEqual(reconciler.active[earlier.id]?.location, .desktop(earlier.host))

        frame.input.value.transcripts = [:]
        frame.input.value.drafts.removeValue(forKey: earlier.id)
        XCTAssertEqual(reconciler.update(frame, at: now).conversations.map(\.title), ["Alpha"])
        XCTAssertNil(reconciler.active[earlier.id])
    }

    func testNativeQuestionsUseThePromptDateAndNeedACurrentWait() throws {
        let id = UUID()
        var frame = ClaudeDiscoveryFrame()
        frame.inventory.value = [.init(sessionId: id.uuidString, status: "waiting",
                                       waitingFor: "input needed", name: "Questions",
                                       statusUpdatedAt: now.timeIntervalSince1970 * 1_000)]
        frame.input.value.transcripts[id] = .init(native: [
            .init(text: "Old prompt", date: now.addingTimeInterval(-7_201)),
            .init(text: "Recent prompt", date: now.addingTimeInterval(-50)),
            .init(text: "Untimed prompt", date: nil)
        ])
        var reconciler = ClaudeReconciler()
        let open = try XCTUnwrap(reconciler.update(frame, at: now).conversations.first)
        XCTAssertEqual(open.inputItems.compactMap(\.text), ["Recent prompt", "Untimed prompt"])
        XCTAssertTrue(open.inputItems.allSatisfy { $0.kind == .native })

        frame.input.value.transcripts[id]?.native = [.init(text: "Old prompt", date: now.addingTimeInterval(-7_201))]
        XCTAssertTrue(reconciler.update(frame, at: now).conversations.isEmpty)

        frame.inventory.value[0].waitingFor = "permission prompt"
        let approval = try XCTUnwrap(reconciler.update(frame, at: now).conversations.first)
        XCTAssertEqual(approval.inputItems, [.init(kind: .native, text: "permission prompt", date: now)])

        frame.inventory.value[0].status = "idle"
        frame.input.value.transcripts[id]?.native = [.init(text: "Cancelled prompt", date: now.addingTimeInterval(-40))]
        XCTAssertTrue(reconciler.update(frame, at: now).conversations.isEmpty)
    }

    func testPlainRequestFromInterruptedDesktopTurnDoesNotKeepASessionVisible() throws {
        let entry = stored("Interrupted", age: 600, cutShort: true)
        var frame = ClaudeDiscoveryFrame()
        frame.input.value.desktop[entry.id] = entry
        frame.input.value.transcripts[try XCTUnwrap(entry.sessionID)] = .init(
            replies: [.init(text: "Please choose a view.", date: now.addingTimeInterval(-10))]
        )
        var reconciler = ClaudeReconciler()
        XCTAssertTrue(reconciler.update(frame, at: now).conversations.isEmpty)

        frame.input.value.drafts[entry.id] = [nil]
        let result = try XCTUnwrap(reconciler.update(frame, at: now).conversations.first)
        XCTAssertEqual(result.inputItems.map(\.kind), [.draft])
    }

    func testDetachedStashRequiresTheInventoryConversationAndUsesItsOwnWriteTime() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".claude")
        let job = config.appendingPathComponent("jobs/14bc06df")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let id = UUID()
        let state = job.appendingPathComponent("state.json")
        let stash = job.appendingPathComponent(".prompt-stash")
        let record = ClaudeSessionRecord(id: "14bc06df", sessionId: id.uuidString, kind: "background", state: "done")
        try Data(#"{"text":"An unsent message"}"#.utf8).write(to: stash)
        let saveTime = now.addingTimeInterval(-150)
        try FileManager.default.setAttributes([.modificationDate: saveTime], ofItemAtPath: stash.path)
        try Data(#"{"sessionId":"\#(UUID())"}"#.utf8).write(to: state)
        let reader = ClaudeInputDiscovery()
        XCTAssertTrue(reader.read(home: home, records: [record], configs: [config], at: now).value.drafts.isEmpty)

        try Data(#"{"sessionId":"\#(id)"}"#.utf8).write(to: state)
        let input = reader.read(home: home, records: [record], configs: [config], at: now)
        XCTAssertEqual(input.value.drafts[.session(id)], [saveTime])
        var frame = ClaudeDiscoveryFrame()
        frame.inventory.value = [record]
        frame.input = input
        var reconciler = ClaudeReconciler()
        XCTAssertEqual(reconciler.update(frame, at: now).conversations.first?.inputItems.map(\.kind), [.draft])

        try FileManager.default.removeItem(at: stash)
        XCTAssertTrue(reader.read(home: home, records: [record], configs: [config], at: now).value.drafts.isEmpty)
    }

    func testDesktopMetadataExcludesArchivedAndUnconfirmedAccountScopes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let local = stored("Reachable", age: 1_000)
        let archive = stored("Archived", age: 150)
        let other = stored("Other account", age: 120)
        try metadata(local, archived: false, in: home, account: account)
        try metadata(archive, archived: true, in: home, account: account)
        try metadata(other, archived: false, in: home, account: UUID())

        let live = ClaudeSessionRecord(sessionId: try XCTUnwrap(local.sessionID).uuidString,
                                       entrypoint: "claude-desktop", hostSessionId: local.host.value)
        let read = ClaudeInputDiscovery().read(home: home, records: [live], configs: [], at: now)
        XCTAssertEqual(read.value.desktop.keys.first, local.id)
        XCTAssertEqual(read.value.desktop.count, 1)
    }

    private func stored(_ title: String, age: TimeInterval, cutShort: Bool = false) -> ClaudeStoredDesktopSession {
        ClaudeStoredDesktopSession(host: ClaudeDesktopID("local_" + UUID().uuidString.lowercased())!,
                                  sessionID: UUID(), accountID: account, title: title, path: nil,
                                  createdAt: now.addingTimeInterval(-age), turnWasCutShort: cutShort)
    }

    private func metadata(_ session: ClaudeStoredDesktopSession, archived: Bool, in home: URL, account: UUID) throws {
        let dir = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
            .appendingPathComponent(account.uuidString).appendingPathComponent(scope.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.host.value, "cliSessionId": try XCTUnwrap(session.sessionID).uuidString,
            "title": session.title ?? "Untitled", "isArchived": archived
        ])
        let file = dir.appendingPathComponent(session.host.value + ".json")
        try payload.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }
}
