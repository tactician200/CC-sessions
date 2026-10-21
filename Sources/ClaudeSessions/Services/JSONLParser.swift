import Foundation

enum JSONLParser {
    struct ParsedTranscript: Equatable {
        var model: String?
        var cwd: String?
        /// Tokens the session has spent: new input + output + cache writes, one
        /// count per API response (cache reads excluded — they are re-reads of context).
        var usedTokens: Int = 0
        /// What the model has loaded right now: input + cache read + cache write of
        /// the last main-chain response. Drops after a compaction.
        var contextTokens: Int = 0
        var toolCallCount: Int = 0
        var lastToolName: String?
        var subagents: [Subagent] = []
        var lastTimestamp: Date?
        /// Session title as the VS Code tab shows it: a rename wins over the generated one.
        var aiTitle: String?
        var customTitle: String?
        /// Tool calls written to the transcript with no tool_result yet, in order.
        var openToolCalls: [OpenToolCall] = []

        var title: String? { customTitle ?? aiTitle }

        static let empty = ParsedTranscript()
    }

    /// A tool_use with no tool_result yet; `at` is its line's timestamp.
    struct OpenToolCall: Equatable, Sendable {
        let id: String
        let name: String
        let at: Date?
    }

    static func parse(url: URL) throws -> ParsedTranscript {
        let data = try Data(contentsOf: url)
        return parse(data: data)
    }

    /// Whole transcript at once: same as feeding every byte to a fresh state.
    static func parse(data: Data) -> ParsedTranscript {
        var state = ParserState()
        state.feed(data)
        return state.snapshot()
    }

    /// Everything the parser accumulates, carried across `feed` calls so a
    /// growing transcript is parsed once (TranscriptCache feeds only new bytes).
    /// Bytes may be split anywhere (mid-line, mid-UTF-8): the unterminated tail
    /// waits in `carry` until its "\n" arrives. `snapshot()` reads a pending tail
    /// as a final line, so feed(a); feed(b); snapshot() == parse(a + b).
    struct ParserState {
        private var model: String?
        private var cwd: String?
        private var contextTokens = 0
        private var toolCallCount = 0
        private var lastToolName: String?
        private var lastTimestamp: Date?
        private var aiTitle: String?
        private var customTitle: String?

        // One API response is written as several transcript lines (one per content
        // block), each repeating the same `usage`. Keyed by message id, last wins.
        private var usageByMessage: [String: Int] = [:]
        private var usedWithoutId = 0

        private var pendingTasks: [String: (type: String, description: String)] = [:]
        private var completedTaskIds: Set<String> = []
        /// Task/Agent calls without an id get a stable synthetic one (it was a random
        /// UUID per parse, so two parses of the same bytes never compared equal).
        private var anonymousTasks = 0
        private var openCalls: [String: (order: Int, call: OpenToolCall)] = [:]
        private var callOrder = 0

        /// Unterminated last line of what was fed so far.
        private var carry = Data()

        /// Bytes fed but not processed yet (an unterminated line).
        var pendingByteCount: Int { carry.count }

        init() {}

        mutating func feed(_ data: Data) {
            guard !data.isEmpty else { return }
            let newline = UInt8(ascii: "\n")
            var start = data.startIndex
            if !carry.isEmpty {
                guard let end = data.firstIndex(of: newline) else {
                    carry.append(data)
                    return
                }
                carry.append(data[start..<end])
                let line = carry
                carry = Data()
                consume(line: line)
                start = data.index(after: end)
            }
            while start < data.endIndex {
                guard let end = data[start...].firstIndex(of: newline) else {
                    carry = Data(data[start...])
                    return
                }
                if end > start {
                    consume(line: Data(data[start..<end]))
                }
                start = data.index(after: end)
            }
        }

        func snapshot() -> ParsedTranscript {
            if !carry.isEmpty {
                var finished = self
                finished.carry = Data()
                finished.consume(line: carry)
                return finished.snapshot()
            }
            var result = ParsedTranscript()
            result.model = model
            result.cwd = cwd
            result.usedTokens = usageByMessage.values.reduce(usedWithoutId, +)
            result.contextTokens = contextTokens
            result.toolCallCount = toolCallCount
            result.lastToolName = lastToolName
            result.lastTimestamp = lastTimestamp
            result.aiTitle = aiTitle
            result.customTitle = customTitle
            result.openToolCalls = openCalls.values.sorted { $0.order < $1.order }.map(\.call)
            result.subagents = pendingTasks.compactMap { id, info -> Subagent? in
                guard !completedTaskIds.contains(id) else { return nil }
                return Subagent(id: id, type: info.type, description: info.description, isActive: true)
            }
            // Tie-break on id: dictionary order differs between two equal states.
            .sorted { ($0.type, $0.id) < ($1.type, $1.id) }
            return result
        }

        /// One complete line (no "\n"). Autorelease pool per line: the Foundation
        /// objects JSONSerialization returns otherwise pile up over a 100 MB file.
        private mutating func consume(line: Data) {
            guard !line.isEmpty else { return }
            autoreleasepool {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    return
                }
                consume(object: obj)
            }
        }

        private mutating func consume(object obj: [String: Any]) {
            if cwd == nil, let lineCwd = obj["cwd"] as? String {
                cwd = lineCwd
            }

            var lineDate: Date?
            if let ts = obj["timestamp"] as? String, let date = parseISODate(ts) {
                lastTimestamp = date
                lineDate = date
            }

            let message = obj["message"] as? [String: Any]
            let type = obj["type"] as? String

            if type == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty {
                aiTitle = t
            } else if type == "custom-title", let t = obj["customTitle"] as? String {
                customTitle = t.isEmpty ? nil : t
            }

            guard let message else { return }
            if let lineModel = message["model"] as? String {
                model = lineModel
            }
            if type == "assistant", let usage = message["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let used = input + output + cacheWrite
                if let id = message["id"] as? String {
                    usageByMessage[id] = used
                } else {
                    usedWithoutId += used
                }
                let context = input + cacheRead + cacheWrite
                if context > 0, obj["isSidechain"] as? Bool != true {
                    contextTokens = context
                }
            }
            // A tool_result on any line (user turns included) completes its task
            // and closes its call.
            guard let content = message["content"] as? [[String: Any]] else { return }
            for block in content {
                guard let blockType = block["type"] as? String else { continue }
                if blockType == "tool_use" {
                    let name = (block["name"] as? String) ?? ""
                    if type == "assistant" {   // blob lines replay calls already counted
                        toolCallCount += 1
                        lastToolName = name
                    }
                    // Only the assistant's own line: `api-request-blob` lines replay
                    // the request history, old (answered) calls included.
                    if type == "assistant", let id = block["id"] as? String {
                        callOrder += 1
                        openCalls[id] = (callOrder, OpenToolCall(id: id, name: name, at: lineDate))
                    }
                    if name == "Task" || name == "Agent" {
                        let id: String
                        if let blockId = block["id"] as? String {
                            id = blockId
                        } else {
                            anonymousTasks += 1
                            id = "task-without-id-\(anonymousTasks)"
                        }
                        let input = (block["input"] as? [String: Any]) ?? [:]
                        let subType = (input["subagent_type"] as? String) ?? "general-purpose"
                        let desc = (input["description"] as? String)
                            ?? (input["prompt"] as? String)
                            ?? ""
                        pendingTasks[id] = (subType, String(desc.prefix(60)))
                    }
                } else if blockType == "tool_result" {
                    if let id = block["tool_use_id"] as? String {
                        completedTaskIds.insert(id)
                        openCalls[id] = nil
                    }
                }
            }
        }
    }

    private static func parseISODate(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
