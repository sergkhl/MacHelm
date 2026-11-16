import Foundation
import XCTest
@testable import ClaudeCore

final class ClaudeInputTranscriptTests: XCTestCase {
    private let session = UUID()
    private let timestamp = "2023-11-14T22:13:20.000Z"
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testLatestCompletedReplyCanRequestAChoiceOrWaitForConfirmation() throws {
        let initial = user("Review this change")
        let interim = assistant("Can you confirm the older target?", after: initial, stop: "tool_use")
        let requested = assistant("The model is ready; awaiting your yes before moving on.", after: interim)
        let result = try read([initial, interim, requested])
        XCTAssertEqual(result.replies, [.init(text: "awaiting your yes before moving on.", date: date)])

        let decision = assistant("Would you prefer “red” or “blue”?", after: initial)
        XCTAssertEqual(try read([initial, decision]).replies.map(\.text), ["Would you prefer “red” or “blue”?"])
        XCTAssertTrue(try read([initial, interim]).replies.isEmpty)
    }

    func testOneCompletedReplyCanContainSeveralUnansweredRequests() throws {
        let response = assistant("Please confirm the environment. Would you prefer red or blue? Please confirm the environment.")
        XCTAssertEqual(try read([response]).replies.map(\.text),
                       ["Please confirm the environment.", "Would you prefer red or blue?"])
    }

    func testNonHumanMessagesDoNotAnswerAndANewHumanReplyDoes() throws {
        let initial = user("Review this change")
        let question = assistant("Please confirm the release target.", after: initial)
        let generated = user("A tracked job has exited.", after: question, fields: ["origin": ["kind": "task-notification"]])
        let toolResult = user([["type": "tool_result", "tool_use_id": "toolu_unrelated"]], after: generated)
        let meta = user("Generated progress.", after: toolResult, fields: ["isMeta": true])
        let rows = [initial, question, generated, toolResult, meta]
        XCTAssertFalse(try read(rows).replies.isEmpty)

        let response = user([["type": "text", "text": "Use the preview environment."]], after: meta,
                            fields: ["origin": ["kind": "human"]])
        XCTAssertTrue(try read(rows + [response]).replies.isEmpty)
        let attachment = user([["type": "image", "source": ["type": "base64"]]], after: meta)
        XCTAssertTrue(try read(rows + [attachment]).replies.isEmpty)
    }

    func testFollowsTheCurrentBranchAndIgnoresSidechainsAndReplay() throws {
        let initial = user("Review the release")
        let abandoned = assistant("Please choose the old target.", after: initial)
        let response = user("Retry the review from here.", after: initial)
        let finished = assistant("The review passed.", after: response)
        let sidechain = assistant("Please confirm this other task.", after: finished, fields: ["isSidechain": true])
        let replay = assistant("Please approve a replayed action.", after: finished, fields: ["isReplay": true])
        XCTAssertTrue(try read([initial, abandoned, response, finished, sidechain, replay]).replies.isEmpty)

        let awaiting = assistant("Which option should I use?", after: response)
        let lateReplay = user("Recorded on a different branch.", after: awaiting, fields: ["isReplay": true])
        XCTAssertEqual(try read([initial, abandoned, response, awaiting, lateReplay]).replies.map(\.text),
                       ["Which option should I use?"])
    }

    func testCompletedMessageCanHaveSeveralTranscriptBlocks() throws {
        let initial = user("Review this change")
        let first = assistant([["type": "thinking"]], after: initial, messageID: "msg_segments")
        let second = assistant("Can you confirm which account to use?", after: first, messageID: "msg_segments")
        XCTAssertEqual(try read([initial, first, second]).replies.map(\.text), ["Can you confirm which account to use?"])
    }

    func testOptionalOffersQuotedTextAndSelfAnsweredQuestionsDoNotCreateReminders() throws {
        for text in [
            "The change is done. Would you like me to add another example?",
            "Done. Tell me if you have any questions.",
            "Can you believe it?",
            "Should I use blue? The answer is blue.",
            "The instructions say “Please confirm the target.”",
            "The guide says: Please confirm the target.",
            "The verification steps are below.\n1. Select the preview environment.\n2. Run the tests.",
            "> Please confirm the target.",
            "~~~text\nPlease confirm the target.\n~~~",
            "The release note contains \u{60}Please confirm the target.\u{60}."
        ] {
            XCTAssertTrue(try read([assistant(text)]).replies.isEmpty, text)
        }
    }

    func testPendingNativeQuestionsHaveTheirOwnTimestampAndResolveByToolID() throws {
        let initial = user("Review this change")
        let call = assistant([
            ask("toolu_first", ["Which release target?", "Which account?"]),
            ask("toolu_second", ["Choose a notification channel."])
        ], after: initial, stop: "tool_use")
        let pending = try read([initial, call])
        XCTAssertEqual(pending.native, ["Which release target?", "Which account?", "Choose a notification channel."]
            .map { .init(text: $0, date: date) })
        XCTAssertTrue(pending.replies.isEmpty)

        let denied = user([["type": "tool_result", "tool_use_id": "toolu_first", "is_error": true]], after: call)
        XCTAssertEqual(try read([initial, call, denied]).native, [.init(text: "Choose a notification channel.", date: date)])
        let answered = user([["type": "tool_result", "tool_use_id": "toolu_second"]], after: denied)
        XCTAssertEqual(try read([initial, call, denied, answered]), .init())
    }

    func testRejectsForeignSessionsAndSymlinksAndReadsOnlyCompleteTailRecords() throws {
        let huge = user(String(repeating: "x", count: 1_100_000))
        let question = assistant("Please choose a target.", after: huge)
        let foreign = user("This does not answer the question.", after: question, fields: ["sessionId": UUID().uuidString])
        XCTAssertEqual(try read([huge, question, foreign], trailing: #"{"type":"user"#).replies.map(\.text),
                       ["Please choose a target."])

        let oldTail = String(repeating: "x", count: 1_100_000) + "\n"
        XCTAssertTrue(try read([question], trailing: oldTail).replies.isEmpty)

        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.jsonl")
        try transcript([question]).write(to: source)
        let link = directory.appendingPathComponent(session.uuidString.lowercased() + ".jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertEqual(ClaudeInputTranscript.read(link, session: session), .init())
        XCTAssertEqual(ClaudeInputTranscript.read(source, session: session), .init())
    }

    private func ask(_ id: String, _ questions: [String]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": "AskUserQuestion",
         "input": ["questions": questions.map { ["question": $0] }]]
    }

    private func user(_ content: Any, after parent: [String: Any]? = nil,
                      fields: [String: Any] = [:]) -> [String: Any] {
        row("user", content: content, parent: parent, fields: fields)
    }

    private func assistant(_ content: Any, after parent: [String: Any]? = nil, stop: String = "end_turn",
                           messageID: String? = nil, fields: [String: Any] = [:]) -> [String: Any] {
        let blocks = (content as? String).map { [["type": "text", "text": $0]] as Any } ?? content
        return row("assistant", content: blocks, parent: parent, stop: stop, messageID: messageID, fields: fields)
    }

    private func row(_ type: String, content: Any, parent: [String: Any]?, stop: String? = nil,
                     messageID: String? = nil, fields: [String: Any]) -> [String: Any] {
        var message: [String: Any] = ["role": type, "content": content]
        message["stop_reason"] = stop
        message["id"] = messageID
        let record: [String: Any] = [
            "type": type, "sessionId": session.uuidString, "uuid": UUID().uuidString,
            "timestamp": timestamp, "parentUuid": parent?["uuid"] ?? NSNull(), "message": message
        ]
        return record.merging(fields) { _, supplied in supplied }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func transcript(_ rows: [[String: Any]]) throws -> Data {
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(10)
        }
        return data
    }

    private func read(_ rows: [[String: Any]], trailing: String = "") throws -> ClaudeTranscriptInput {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(session.uuidString.lowercased() + ".jsonl")
        var data = try transcript(rows)
        data.append(contentsOf: trailing.utf8)
        try data.write(to: file)
        return ClaudeInputTranscript.read(file, session: session)
    }
}
