import Darwin
import Foundation

struct ClaudeTranscriptInput: Sendable, Equatable {
    var replies: [ClaudeTranscriptPrompt] = []
    var native: [ClaudeTranscriptPrompt] = []
}

struct ClaudeTranscriptPrompt: Sendable, Equatable {
    let text: String
    let date: Date?
}

enum ClaudeInputTranscript {
    private struct Block: Decodable {
        private struct Input: Decodable {
            struct Question: Decodable { let question: String }
            let questions: [Question]
        }

        let type: String
        let id: String?
        let toolUseID: String?
        let text: String?
        let questions: [String]

        private enum CodingKeys: String, CodingKey {
            case type, id, text, name, input
            case toolUseID = "tool_use_id"
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            type = try fields.decode(String.self, forKey: .type)
            id = try fields.decodeIfPresent(String.self, forKey: .id)
            toolUseID = try fields.decodeIfPresent(String.self, forKey: .toolUseID)
            text = try fields.decodeIfPresent(String.self, forKey: .text)
            if type == "tool_use", try fields.decodeIfPresent(String.self, forKey: .name) == "AskUserQuestion" {
                questions = (try? fields.decode(Input.self, forKey: .input).questions.map(\.question)) ?? []
            } else {
                questions = []
            }
        }
    }

    private enum Content: Decodable {
        case text(String)
        case blocks([Block])

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let text = try? value.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try value.decode([Block].self))
            }
        }

        var text: [String] {
            switch self {
            case .text(let text): [text]
            case .blocks(let blocks): blocks.filter { $0.type == "text" }.compactMap(\.text)
            }
        }

        var blocks: [Block] {
            if case .blocks(let blocks) = self { return blocks }
            return []
        }
    }

    private struct Record: Decodable {
        struct Message: Decodable {
            let id: String?
            let role: String?
            let model: String?
            let stop_reason: String?
            let content: Content
        }
        struct Origin: Decodable { let kind: String }

        let type: String
        let sessionId: UUID?
        let uuid: UUID?
        let parentUuid: UUID?
        let sourceToolAssistantUUID: UUID?
        let timestamp: String?
        let isReplay: Bool?
        let isSidechain: Bool?
        let isMeta: Bool?
        let isCompactSummary: Bool?
        let isSynthetic: Bool?
        let origin: Origin?
        let message: Message?

        var conversationMessage: Bool {
            (type == "assistant" || type == "user") && (message?.role ?? type) == type && message != nil
        }

        private var isVisible: Bool { isMeta != true && isCompactSummary != true && isSynthetic != true }

        var assistantOutput: Bool {
            type == "assistant" && conversationMessage && isVisible && message?.model != "<synthetic>"
        }

        var humanInput: Bool {
            guard type == "user", conversationMessage, isVisible, let content = message?.content,
                  sourceToolAssistantUUID == nil, origin == nil || origin?.kind == "human",
                  !content.blocks.contains(where: { $0.type == "tool_result" }) else { return false }
            return content.blocks.contains { $0.type == "image" || $0.type == "document" }
                || content.text.contains(where: ClaudeInputTranscript.humanText)
        }
    }

    private struct Reply {
        let id: String
        var text: [ClaudeTranscriptPrompt] = []
        var completed = false
        var usedTool = false
    }

    private static let fractionalDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeDate = Date.ISO8601FormatStyle()
    private static let limit: UInt64 = 1_048_576

    static func read(_ file: URL, session: UUID) -> ClaudeTranscriptInput {
        guard file.isFileURL, file.pathExtension == "jsonl",
              UUID(uuidString: file.deletingPathExtension().lastPathComponent) == session else { return .init() }
        let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .init() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size > 0 else { return .init() }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let length = UInt64(info.st_size)
        let start = length > limit ? length - limit : 0
        let offset = start > 0 ? start - 1 : start
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(length - offset)) ?? Data()
            return input(in: data, session: session, startsMidFile: start > 0)
        } catch {
            return .init()
        }
    }

    private static func input(in data: Data, session: UUID, startsMidFile: Bool) -> ClaudeTranscriptInput {
        let decoder = JSONDecoder()
        // Ignore a partial first record and any append that hasn't reached its newline.
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropFirst(startsMidFile ? 1 : 0).dropLast()
        let records = lines.compactMap { line -> Record? in
            guard let record = try? decoder.decode(Record.self, from: Data(line)),
                  record.sessionId == session, record.uuid != nil,
                  record.isSidechain != true, record.isReplay != true else { return nil }
            return record
        }
        guard var index = records.lastIndex(where: \.conversationMessage) else { return .init() }
        let positions = Dictionary(records.enumerated().compactMap { index, record in
            record.uuid.map { ($0, index) }
        }, uniquingKeysWith: max)
        var branch: [Int] = []
        while true {
            branch.append(index)
            guard let parent = records[index].parentUuid, let previous = positions[parent], previous < index else { break }
            index = previous
        }

        var pending: [String: (order: Int, prompts: [ClaudeTranscriptPrompt])] = [:]
        var nextQuestion = 0
        var reply: Reply?
        for index in branch.reversed() {
            let record = records[index]
            guard let message = record.message, let rowID = record.uuid else { continue }
            if record.humanInput { reply = nil }
            if record.type == "user", record.conversationMessage {
                for block in message.content.blocks where block.type == "tool_result" {
                    if let id = block.toolUseID { pending.removeValue(forKey: id) }
                }
            }
            guard record.assistantOutput else { continue }
            let date = record.timestamp.flatMap { (try? fractionalDate.parse($0)) ?? (try? wholeDate.parse($0)) }
            let id = message.id ?? rowID.uuidString
            if reply?.id != id { reply = Reply(id: id) }
            if let reason = message.stop_reason { reply?.completed = reason == "end_turn" }
            reply?.text.append(contentsOf: message.content.text.map { .init(text: $0, date: date) })
            for block in message.content.blocks where block.type == "tool_use" {
                reply?.usedTool = true
                guard let id = block.id else { continue }
                let prompts = block.questions.prefix(4).compactMap { question in
                    summary(question).map { ClaudeTranscriptPrompt(text: $0, date: date) }
                }
                if !prompts.isEmpty {
                    pending[id] = (nextQuestion, prompts)
                    nextQuestion += 1
                }
            }
        }

        let native = pending.values.sorted { $0.order < $1.order }.flatMap(\.prompts)
        guard let reply, reply.completed, !reply.usedTool else { return .init(native: native) }
        return .init(replies: unansweredRequests(in: reply.text), native: native)
    }

    private static let generatedUserPrefixes = [
        "<task-notification", "<system-reminder", "<local-command-", "<command-name", "<command-message",
        "<bash-stdout", "<bash-stderr", "<teammate-message", "<tick"
    ]

    private static func humanText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !generatedUserPrefixes.contains(where: trimmed.hasPrefix)
    }

    private static func summary(_ text: String) -> String? {
        let trimmed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 320 ? "\(trimmed.prefix(319))…" : trimmed
    }

    // A general question mark does not imply that a finished turn is waiting for the user.
    private static let directRequest = try! NSRegularExpression(pattern: #"""
        (?ix) (?: ^ | [,:]\s+ )
        (?: (?: (?:can|could|would|will)\s+you\s+(?:please\s+)? | please\s+ )
             (?:confirm|approve|pick|select|choose|decide|reply|respond|tell\s+(?:me|us))
           | let\s+(?:me|us)\s+know\s+(?:which|what|whether|when|how|if\s+you\s+(?:agree|approve))
           | (?:pick|choose|select)\s+(?:one|between)
           | (?:reply|respond)\s+with
        ) \b
        """#)
    private static let explicitlyWaiting = try! NSRegularExpression(pattern: #"""
        (?ix)
        (?: ^ | [,:]\s+ | \b(?:i(?:'m|\sam)|we(?:'re|\sare))\s+ )
        (?:still\s+|now\s+)? (?:awaiting|waiting\s+(?:for|on))\s+your\s+
        (?:yes|approval|answer|response|reply|decision|choice|confirmation|go[-\s]ahead|green\s+light|input)\b
        | \b(?:i|we)\s+need\s+
        (?: your\s+(?:approval|answer|reply|decision|choice|confirmation|go[-\s]ahead)
           | you\s+to\s+(?:approve|choose|confirm|decide|reply)
        )\b
        """#)
    private static let decidingQuestion = try! NSRegularExpression(pattern: #"""
        (?ix) (?: ^ | [,:]\s+ )
        (?: should\s+(?:i|we)\s+
             (?:continue|proceed|start|stop|use|choose|pick|apply|merge|ship|keep|wait|go\s+(?:ahead|with)|move\s+on)\b
           | (?:do|would)\s+you\s+(?:prefer|approve|agree)\b
           | which\s+(?:one|option|approach|version|plan|target)\s*(?=\?)
           | (?:which|what)\s+[^?]{0,150}\b
             (?: (?:would|do)\s+you\s+(?:prefer|want|choose|like) | should\s+(?:i|we) | works\s+(?:best\s+)?for\s+you )\b
        ) [^?]*\?\s*$
        """#)
    private static let optionalOffer = try! NSRegularExpression(pattern: #"""
        (?ix) \b(?: if\s+you(?:'d)?\s+(?:like|want)
                   | if\s+you\s+(?:would\s+like|need\s+anything|have\s+any\s+questions)
                   | no\s+(?:reply|response|action|confirmation)\s+(?:is\s+)?(?:needed|required)
        )\b
        """#)
    private static let reportedSpeech = try! NSRegularExpression(pattern:
        #"(?ix) \b(?:the\s+(?:docs|guide|example|message|prompt)|you|they)\s+(?:said|says|asked|asks|reads|wrote)\s*[,:]"#)
    private static let selfAnswer = try! NSRegularExpression(pattern:
        #"(?i)^(?:the answer is\b|answer:|i (?:chose|picked|selected|used|went with)\b|i(?:'ll| will) go with\b)"#)
    private static let quotedText = try! NSRegularExpression(pattern: #"\x60[^\x60]*\x60|"[^"]*"|“[^”]*”"#)
    private static let clauseEnds = try! NSRegularExpression(pattern: #"[.!?;](?=\s|$)"#)

    private static func unansweredRequests(in blocks: [ClaudeTranscriptPrompt]) -> [ClaudeTranscriptPrompt] {
        let lines = blocks.flatMap { block in
            block.text.split(whereSeparator: \.isNewline).map { ($0, block.date) }
        }
        var candidates: [(original: String, visible: String, date: Date?)] = []
        var fence: String?
        for (line, date) in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\u{60}\u{60}\u{60}") || text.hasPrefix("~~~") {
                let marker = String(text.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                continue
            }
            guard fence == nil, !text.hasPrefix(">"), !text.isEmpty else { continue }
            let visible = NSMutableString(string: text)
            let range = NSRange(location: 0, length: visible.length)
            for match in quotedText.matches(in: text, range: range).reversed() {
                visible.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
            let masked = visible as String
            let original = text as NSString
            var start = 0
            let ends = clauseEnds.matches(in: masked, range: range).map { NSMaxRange($0.range) } + [range.length]
            for end in ends where end > start {
                let clause = NSRange(location: start, length: end - start)
                let reading = visible.substring(with: clause).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "*_#-–—•")))
                    .replacingOccurrences(of: "’", with: "'")
                if !reading.isEmpty { candidates.append((original.substring(with: clause), reading, date)) }
                start = end
            }
        }
        var requests: [ClaudeTranscriptPrompt] = []
        var seen: Set<String> = []
        for index in candidates.indices {
            let clause = candidates[index]
            if index + 1 < candidates.count, matches(selfAnswer, candidates[index + 1].visible) { continue }
            guard !matches(reportedSpeech, clause.visible), !matches(optionalOffer, clause.visible) else { continue }
            if matches(explicitlyWaiting, clause.visible) || matches(directRequest, clause.visible) || matches(decidingQuestion, clause.visible),
               let text = summary(clause.original), seen.insert(text).inserted {
                requests.append(.init(text: text, date: clause.date))
            }
        }
        return requests
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
