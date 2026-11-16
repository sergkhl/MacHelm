import CryptoKit
import Foundation

struct ClaudeShellLaunch: Equatable, Sendable {
    let fingerprint: SHA256.Digest
    let startedAt: TimeInterval

    init?(arguments: [String], startedAt: TimeInterval) {
        guard let switchIndex = arguments.firstIndex(of: "-c"),
              let script = arguments.dropFirst(switchIndex + 1).first,
              let evaluation = script.range(of: " && eval "),
              script[..<evaluation.lowerBound].contains("/shell-snapshots/"),
              let end = script.range(of: " < /dev/null && pwd -P ", options: .backwards),
              evaluation.upperBound < end.lowerBound else { return nil }

        // Match Claude's quoted eval argument as a whole. Keep only a hash of
        // it, since command lines can contain arguments we should not display.
        let literal = script[evaluation.upperBound..<end.lowerBound]
        guard literal.first == "'", literal.last == "'" else { return nil }
        let escapes = ["'\\''", "'\"'\"'"]
        guard let command = escapes.lazy.compactMap({ escape -> String? in
            let decoded = literal.dropFirst().dropLast().replacingOccurrences(of: escape, with: "'")
            return "'" + decoded.replacingOccurrences(of: "'", with: escape) + "'" == literal ? decoded : nil
        }).first else { return nil }
        fingerprint = Self.hash(command)
        self.startedAt = startedAt
    }

    static func hash(_ command: String) -> SHA256.Digest {
        SHA256.hash(data: Data(command.utf8))
    }
}

enum ClaudeTaskRecords {
    private struct Record: Decodable {
        struct Result: Decodable { let backgroundTaskId: String? }
        struct Block: Decodable {
            struct Input: Decodable {
                let description: String?
                let command: String?
            }
            let type: String
            let id: String?
            let name: String?
            let tool_use_id: String?
            let input: Input?
        }
        struct Message: Decodable { let content: [Block] }

        let type: String
        let sessionId: UUID?
        let timestamp: String?
        let uuid: UUID?
        let sourceToolAssistantUUID: UUID?
        let toolUseResult: Result?
        let message: Message?

        private enum CodingKeys: String, CodingKey {
            case type, sessionId, timestamp, uuid, sourceToolAssistantUUID, toolUseResult, message
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            type = try fields.decode(String.self, forKey: .type)
            sessionId = try fields.decodeIfPresent(UUID.self, forKey: .sessionId)
            timestamp = try fields.decodeIfPresent(String.self, forKey: .timestamp)
            uuid = try? fields.decode(UUID.self, forKey: .uuid)
            sourceToolAssistantUUID = try? fields.decode(UUID.self, forKey: .sourceToolAssistantUUID)
            toolUseResult = try? fields.decode(Result.self, forKey: .toolUseResult)
            message = try? fields.decode(Message.self, forKey: .message)
        }
    }

    private struct Transcript: Hashable {
        let project: String
        let session: UUID
    }

    private struct Receipt {
        let time: TimeInterval
        let toolID: String?
        let assistantID: UUID?
    }

    private struct Invocation {
        let toolID: String
        let assistantID: UUID?
        let time: TimeInterval
        let title: String?
        let fingerprint: SHA256.Digest?
    }

    static func read(_ outputs: Set<ClaudeTaskOutput>, in config: URL, sessions: Set<UUID>,
                     launches: [ClaudeTaskOutput: ClaudeShellLaunch]) -> ClaudeRead<[ClaudeTaskOutput: ClaudeTaskRecord]> {
        let transcripts = Dictionary(grouping: outputs) { Transcript(project: $0.projectKey, session: $0.sessionID) }
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        var result = ClaudeRead<[ClaudeTaskOutput: ClaudeTaskRecord]>(value: [:])
        for (key, outputs) in transcripts {
            let file = projects.appendingPathComponent(key.project, isDirectory: true)
                .appendingPathComponent(key.session.uuidString.lowercased() + ".jsonl")
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    result.quality = .partial
                    continue
                }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let length = try handle.seekToEnd()
                // Jobs can outlive many messages. Search a bounded window only
                // in transcripts named by a live task output.
                let limit: UInt64 = 8 * 1_048_576
                let start = length > limit ? length - limit : 0
                try handle.seek(toOffset: start)
                let data = try handle.read(upToCount: Int(min(length, limit))) ?? Data()
                let candidates = launches.filter { outputs.contains($0.key) }
                result.value.merge(records(in: data, for: outputs, launches: candidates, startsMidFile: start > 0),
                                   uniquingKeysWith: Self.merge)
            } catch {
                if !ClaudeDiscovery.missing(error) || sessions.contains(key.session) { result.quality = .partial }
            }
        }
        return result
    }

    static func merge(_ first: ClaudeTaskRecord, _ second: ClaudeTaskRecord) -> ClaudeTaskRecord {
        let time = [first.backgroundedAt, second.backgroundedAt].compactMap { $0 }.max()
        let titles = Set([first.title, second.title].compactMap { $0 })
        return ClaudeTaskRecord(backgroundedAt: time, title: titles.count == 1 ? titles.first : nil)
    }

    static func records(in data: Data, for outputs: [ClaudeTaskOutput],
                        launches: [ClaudeTaskOutput: ClaudeShellLaunch] = [:],
                        startsMidFile: Bool = false) -> [ClaudeTaskOutput: ClaudeTaskRecord] {
        guard let sessionID = outputs.first?.sessionID else { return [:] }
        let requested = Dictionary(outputs.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        let decoder = JSONDecoder()
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let receiptField = Data("\"backgroundTaskId\"".utf8)
        let toolUse = Data("\"tool_use\"".utf8)
        let toolResult = Data("\"tool_result\"".utf8)
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropFirst(startsMidFile ? 1 : 0)

        var receipts: [ClaudeTaskOutput: Receipt] = [:]
        var invocations: [Invocation] = []
        var results: [String: TimeInterval] = [:]
        for line in lines {
            let hasReceipt = line.range(of: receiptField) != nil
            let hasCall = line.range(of: toolUse) != nil
            let hasResult = !launches.isEmpty && line.range(of: toolResult) != nil
            guard hasReceipt || hasCall || hasResult,
                  let record = try? decoder.decode(Record.self, from: line), record.sessionId == sessionID,
                  let timestamp = record.timestamp.flatMap(time.date(from:))?.timeIntervalSince1970 else { continue }

            if record.type == "user" {
                let toolIDs = record.message?.content.filter { $0.type == "tool_result" }.compactMap(\.tool_use_id) ?? []
                if let id = record.toolUseResult?.backgroundTaskId, let output = requested[id],
                   timestamp > (receipts[output]?.time ?? -.infinity) {
                    receipts[output] = Receipt(time: timestamp, toolID: toolIDs.count == 1 ? toolIDs.first : nil,
                                               assistantID: record.sourceToolAssistantUUID)
                }
                for toolID in toolIDs {
                    results[toolID] = min(timestamp, results[toolID] ?? timestamp)
                }
            } else if record.type == "assistant" {
                for block in record.message?.content ?? [] where block.type == "tool_use" {
                    guard let id = block.id, block.name == "Bash" || block.name == "PowerShell" else { continue }
                    let title = block.input?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                    invocations.append(Invocation(toolID: id, assistantID: record.uuid, time: timestamp,
                                                  title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(512)) },
                                                  fingerprint: launches.isEmpty ? nil : block.input?.command.map(ClaudeShellLaunch.hash)))
                }
            }
        }

        var records: [ClaudeTaskOutput: ClaudeTaskRecord] = [:]
        let callsByID = Dictionary(grouping: invocations, by: \.toolID)
        for output in outputs {
            if let receipt = receipts[output] {
                let matches = (receipt.toolID.flatMap { callsByID[$0] } ?? []).filter {
                    (receipt.assistantID == nil || receipt.assistantID == $0.assistantID) && $0.time <= receipt.time + 1
                }
                records[output] = ClaudeTaskRecord(backgroundedAt: receipt.time, title: uniqueTitle(matches))
            } else if let launch = launches[output] {
                let matches = invocations.filter {
                    $0.fingerprint == launch.fingerprint && $0.time <= launch.startedAt + 1 &&
                        launch.startedAt - $0.time <= 60 && (results[$0.toolID] ?? .infinity) >= launch.startedAt
                }
                if let title = uniqueTitle(matches) {
                    records[output] = ClaudeTaskRecord(backgroundedAt: nil, title: title)
                }
            }
        }
        return records
    }

    private static func uniqueTitle(_ matches: [Invocation]) -> String? {
        guard Set(matches.map(\.toolID)).count == 1 else { return nil }
        let titles = Set(matches.map(\.title))
        return titles.count == 1 ? matches.first?.title : nil
    }
}
