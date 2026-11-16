import Foundation

enum ClaudeTaskRecords {
    private struct Receipt: Decodable {
        struct Result: Decodable { let backgroundTaskId: String? }
        let type: String?
        let sessionId: UUID?
        let timestamp: String?
        let toolUseResult: Result?
    }

    private struct Transcript: Hashable {
        let project: String
        let session: UUID
    }

    static func read(_ outputs: Set<ClaudeTaskOutput>, in config: URL, sessions: Set<UUID>) -> ClaudeRead<[ClaudeTaskOutput: TimeInterval]> {
        let transcripts = Dictionary(grouping: outputs) { Transcript(project: $0.projectKey, session: $0.sessionID) }
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        var result = ClaudeRead<[ClaudeTaskOutput: TimeInterval]>(value: [:])
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
                let limit: UInt64 = 1_048_576
                // Read one bounded tail per transcript, even when several jobs share it.
                if length > limit { try handle.seek(toOffset: length - limit) } else { try handle.seek(toOffset: 0) }
                let data = try handle.read(upToCount: Int(limit)) ?? Data()
                result.value.merge(receipts(in: data, for: outputs, startsMidFile: length > limit), uniquingKeysWith: max)
            } catch {
                if !ClaudeDiscovery.missing(error) || sessions.contains(key.session) { result.quality = .partial }
            }
        }
        return result
    }

    static func receipts(in data: Data, for outputs: [ClaudeTaskOutput], startsMidFile: Bool = false) -> [ClaudeTaskOutput: TimeInterval] {
        guard let sessionID = outputs.first?.sessionID else { return [:] }
        let requested = Dictionary(outputs.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        let field = Data("\"backgroundTaskId\"".utf8)
        let decoder = JSONDecoder()
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropFirst(startsMidFile ? 1 : 0)
        var result: [ClaudeTaskOutput: TimeInterval] = [:]
        for line in lines where line.range(of: field) != nil {
            guard let record = try? decoder.decode(Receipt.self, from: line), record.type == "user", record.sessionId == sessionID,
                  let id = record.toolUseResult?.backgroundTaskId, let output = requested[id],
                  let timestamp = record.timestamp, let date = time.date(from: timestamp) else { continue }
            result[output] = max(result[output] ?? 0, date.timeIntervalSince1970)
        }
        return result
    }
}
