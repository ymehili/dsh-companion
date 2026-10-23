import Foundation

struct SessionRow: Identifiable, Hashable {
    let id: String
    var title: String
    let updatedAt: Double
    var running: Bool
    let cwd: String
    let isSubagent: Bool
    let blank: Bool
    init?(_ value: JSONValue) {
        guard let id = value["sessionId"].string else { return nil }
        self.id = id
        title = value["projections"]["values"]["title"].string ?? "Untitled conversation"
        updatedAt = value["updatedAt"].number ?? 0
        running = value["running"].bool ?? false
        cwd = value["cwd"].string ?? ""
        isSubagent = value["origin"].string == "subagent"
        blank = value["blank"].bool ?? false
    }
}

/// One rendered transcript row.
///
/// `role` is one of:
/// - `"user"`: human-authored input only (`message.source.kind == "user"`, or a
///   fixture without any source).
/// - `"context"`: a `user/message` injected by the host rather than typed by the
///   person: skills, subagent/goal/schedule notices, session recall, plugin
///   status, etc. The Mac app renders these as collapsed context rows and never
///   as a "You" bubble. `contextTitle`/`contextLabel`/`contextSummary` follow its
///   wording, and `text` keeps the model-facing body for an expanded view.
/// - `"assistant"`: committed model reply text/reasoning.
/// - `"tool"`: a tool call or tool result.
struct ChatEntry: Identifiable, Equatable {
    let id: Int
    let role: String
    let text: String
    let reasoning: String
    let tool: String?
    let detail: String?
    let images: [String]
    let imageReferences: [ChatImageReference]
    /// Durable event time in Unix milliseconds.
    let time: Double?
    /// `message.source.kind` of input messages; nil for fixtures without a source.
    let sourceKind: String?
    /// Collapsed-row title for `role == "context"`, e.g. "Context injection".
    let contextTitle: String?
    /// Producer label shown after the title, e.g. a skill name or recalled session labels.
    let contextLabel: String?
    /// Producer-supplied one-line summary (`source.summary`, used by notices).
    let contextSummary: String?
    /// Correlates a tool call with its result.
    let callId: String?
    let isError: Bool
    /// Presentation metadata from a durable tool/result, never parsed from tool text or arguments.
    let toolResultMeta: JSONValue?
    /// Host turn number recorded on the durable event (`data.turn`); nil when the
    /// host recorded none (e.g. `user/message`). Never inferred from position.
    let turn: Int?

    /// Calls and ordinary messages never have result metadata. Invalid envelopes stay generic tool UI.
    var openUICard: OpenUIToolCard? {
        guard role == "tool", tool == "openui_card", !isError, let toolResultMeta else { return nil }
        return OpenUIToolCard(meta: toolResultMeta)
    }

    init(id: Int, role: String, text: String, reasoning: String, tool: String?, detail: String?, images: [String],
         time: Double? = nil, sourceKind: String? = nil, contextTitle: String? = nil, contextLabel: String? = nil,
         contextSummary: String? = nil, callId: String? = nil, isError: Bool = false,
         imageReferences: [ChatImageReference] = [], toolResultMeta: JSONValue? = nil, turn: Int? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.tool = tool
        self.detail = detail
        self.images = images
        self.imageReferences = imageReferences
        self.time = time
        self.sourceKind = sourceKind
        self.contextTitle = contextTitle
        self.contextLabel = contextLabel
        self.contextSummary = contextSummary
        self.callId = callId
        self.isError = isError
        self.toolResultMeta = toolResultMeta
        self.turn = turn
    }

    var isHumanInput: Bool { role == "user" }
    var isContext: Bool { role == "context" }
}

/// Versioned plugin presentation envelope, deliberately separate from Markdown/fenced answer parsing.
struct OpenUIToolCard: Equatable {
    static let maxSourceBytes = 256 * 1024
    static let maxTitleBytes = 160
    let title: String
    let source: String
    let catalog: String

    init?(meta: JSONValue) {
        let card = meta["openui"]
        switch card["version"] {
        case .number(1): catalog = "chat-v1"
        case .number(2):
            guard card["catalog"].string == "intelligent-v1" else { return nil }
            catalog = "intelligent-v1"
        default: return nil
        }
        guard card["kind"].string == "card",
              let title = card["title"].string, title.utf8.count <= Self.maxTitleBytes,
              let source = card["source"].string, source.utf8.count <= Self.maxSourceBytes,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.title = title
        self.source = source
    }
}

/// A prepared `openui_card` result shown with its completed turn's final answer.
struct OpenUIFinalCard: Identifiable, Equatable {
    /// Durable callId of the result (`seq-N` when the host recorded none).
    let id: String
    let card: OpenUIToolCard
}

/// Per-turn ledger for final-answer cards, fed one durable row/lifecycle event at
/// a time in seq order. It attributes rows only by their recorded `data.turn`
/// and publishes cards only once that turn's actual `turn/end` reports
/// `reason.kind == "completed"` and the turn has a final text reply (an
/// assistant reply with no later tool row in the same turn). Running, failed,
/// aborted and reply-less turns publish nothing; tool work never carries cards.
struct OpenUITurnLedger {
    static let maxCardsPerTurn = 8

    private struct Turn {
        var cards: [OpenUIFinalCard] = []
        var finalReply: Int?
        var ended = false
    }

    private var turns: [Int: Turn] = [:]
    /// Final reply seq → that completed turn's cards, in durable call order (at most 8).
    private(set) var cardsByReply: [Int: [OpenUIFinalCard]] = [:]

    /// Records one transcript row. Nothing publishes before the turn's actual end.
    mutating func note(_ entry: ChatEntry) {
        guard let number = entry.turn else { return }
        var turn = turns[number] ?? Turn()
        // Rows recorded after the turn's own end are never attached to it.
        guard !turn.ended else { return }
        if entry.role == "tool" {
            turn.finalReply = nil
            if let card = entry.openUICard, turn.cards.count < Self.maxCardsPerTurn {
                let id = entry.callId ?? "seq-\(entry.id)"
                if !turn.cards.contains(where: { $0.id == id }) { turn.cards.append(OpenUIFinalCard(id: id, card: card)) }
            }
        } else if entry.role == "assistant", !entry.text.isEmpty {
            turn.finalReply = entry.id
        }
        turns[number] = turn
    }

    /// Accepts any durable event; only the first `turn/end` with a recorded turn
    /// number matters. Returns true when it published cards.
    @discardableResult
    mutating func noteLifecycle(_ event: JSONValue) -> Bool {
        guard event["type"].string == "turn/end", let number = event["data"]["turn"].integer else { return false }
        var turn = turns[number] ?? Turn()
        guard !turn.ended else { return false }
        turn.ended = true
        turns[number] = turn
        guard event["data"]["reason"]["kind"].string == "completed", let reply = turn.finalReply, !turn.cards.isEmpty else { return false }
        cardsByReply[reply] = turn.cards
        return true
    }
}

/// Pure transcript + transient stream reducer. A new follow snapshot is the reconnect baseline.
///
/// Performance contract: `entries` is cached. It is rebuilt once per snapshot,
/// once per `prepend` batch and when a transcript-relevant durable event lands out
/// of order or replaces a different event. A new tail event is appended in O(1).
/// Assistant-stream frames never touch the durable history or its order.
struct Conversation {
    /// Durable events by seq. Assigning replaces history and rebuilds the transcript once.
    var events: [Int: JSONValue] {
        get { storage }
        set { storage = newValue; rebuildTranscript() }
    }
    var cursor = 0
    var hasMore = false
    var revision = -1
    var attempt: String?
    var nextIndex = 0
    var settledSeq: Int?
    var needsBaseline = false
    var running = false

    /// Cached transcript rows in seq order.
    var entries: [ChatEntry] { transcript }
    /// Cached ascending durable seqs (all event types), e.g. for the trajectory list.
    var eventSeqs: [Int] { orderedSeqs }
    /// Increments whenever `entries` changes, including in-place replacements,
    /// and when a turn's actual end publishes final-answer cards.
    private(set) var transcriptRevision = 0
    /// O(1) row lookup by durable seq.
    func entry(for seq: Int) -> ChatEntry? { entryIndex[seq].map { transcript[$0] } }
    /// Cached `openui_card` results of completed turns, keyed by the seq of the
    /// turn's final assistant reply. Maintained with the transcript cache: O(1)
    /// per live event, never derived by scanning history at render time.
    var finalAnswerCards: [Int: [OpenUIFinalCard]] { ledger.cardsByReply }

    /// Transient assistant blocks keyed by stream index (read-only JSON view).
    var blocks: [Int: JSONValue] { stream.mapValues(\.json) }
    /// Open-attempt text blocks joined by newline in index order (cached per frame).
    private(set) var streamingText = ""
    /// Open-attempt reasoning blocks joined by newline in index order (cached per frame).
    private(set) var streamingReasoning = ""

    private var storage: [Int: JSONValue] = [:]
    private var orderedSeqs: [Int] = []
    private var transcript: [ChatEntry] = []
    private var entryIndex: [Int: Int] = [:]
    private var toolNames: [String: String] = [:]
    private var ledger = OpenUITurnLedger()
    private var stream: [Int: StreamBlock] = [:]
    private var lastLifecycleSeq = -1

    private struct StreamBlock {
        /// Delta type of an open block: "text" or "reasoning".
        var type: String
        var text: String
        /// The host's final block from `block-end`, plus `closed: true`; frozen afterwards.
        var closedBlock: [String: JSONValue]?
        var joinType: String? {
            if let closedBlock { return closedBlock["type"]?.string }
            return type
        }
        var joinText: String? {
            if let closedBlock { return closedBlock["text"]?.string }
            return text
        }
        var json: JSONValue { closedBlock.map(JSONValue.obj) ?? .obj(["type": .text(type), "text": .text(text)]) }
    }

    // MARK: Durable transcript

    static func contentText(_ content: JSONValue) -> String {
        if let text = content.string { return text }
        return content.array.compactMap { block -> String? in
            if block["type"].string == "text" { return block["text"].string }
            return nil
        }.joined(separator: "\n")
    }

    /// Mac semantics: only `source.kind == "user"` is human input. A missing source
    /// (synthetic fixtures; the host always records one) is treated as human.
    static func isHumanAuthored(_ source: JSONValue) -> Bool {
        source == .null || source["kind"].string == "user"
    }

    /// Mirrors the Mac's collapsed context row (`contextProducer`) and turn-trigger titles.
    static func contextPresentation(_ source: JSONValue) -> (title: String, label: String?, summary: String?) {
        let kind = source["kind"].string ?? ""
        let summary = nonEmpty(source["summary"].string)
        switch kind {
        case "": return ("Context injection", nil, summary)
        case "session-reference": return ("Session recall", joinedField(source["references"], "label") ?? kind, summary)
        case "agent-instructions": return ("Context injection", joinedField(source["changes"], "path") ?? kind, summary)
        case "skill-invocation": return ("Context injection", nonEmpty(source["name"].string) ?? kind, summary)
        case "goal": return ("Continuing goal", nil, summary)
        case "agent-message": return ("Task message received", nil, summary)
        case "team-message": return ("Team message received", nil, summary)
        case "subagent-settled": return ("Subtask status updated", nil, summary)
        case "webhook": return (source["provider"].string == "github" ? "GitHub event received" : "External event received", nil, summary)
        case "schedule": return ("Automation task", nil, summary)
        case "tool-jobs": return ("Background task updated", nil, summary)
        case "cordis-host-runner": return ("Plugin status updated", nil, summary)
        default: return ("Context injection", kind, summary)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func joinedField(_ list: JSONValue, _ field: String) -> String? {
        var seen: [String] = []
        for item in list.array {
            if let value = nonEmpty(item[field].string), !seen.contains(value) { seen.append(value) }
        }
        return seen.isEmpty ? nil : seen.joined(separator: ", ")
    }

    private static func affectsTranscript(_ event: JSONValue?) -> Bool {
        switch event?["type"].string {
        case "user/message", "assistant/message", "tool/call", "tool/result": return true
        default: return false
        }
    }

    private func makeEntry(_ seq: Int, _ event: JSONValue) -> ChatEntry? {
        guard let type = event["type"].string else { return nil }
        // Append-origin only: replacement copies are model-only (Mac `isAppendSurfaceEvent`).
        if event["surfaceOp"] != .null && event["surfaceOp"].string != "append" { return nil }
        let data = event["data"]
        let time = event["time"].number
        switch type {
        case "tool/call":
            let name = data["name"].string
            return ChatEntry(id: seq, role: "tool", text: name ?? "Tool", reasoning: "", tool: name ?? "Tool", detail: data["arguments"].string, images: [],
                             time: time, callId: data["callId"].string, turn: data["turn"].integer)
        case "tool/result":
            // ToolResultMessage carries no name; resolve it through the durable call.
            let message = data["message"]
            let callId = message["source"]["callId"].string ?? message["toolCallId"].string
            let name = callId.flatMap { toolNames[$0] } ?? message["name"].string
            let failed = data["error"] != .null || message["isError"].bool == true
            var detail = Self.contentText(message["content"])
            if detail.isEmpty, failed { detail = data["error"]["reason"].string ?? data["error"]["code"].string ?? "" }
            let text = name.map { failed ? "\($0) error" : "\($0) result" } ?? (failed ? "Tool error" : "Tool result")
            return ChatEntry(id: seq, role: "tool", text: text, reasoning: "", tool: name ?? "Tool", detail: detail, images: [],
                             time: time, callId: callId, isError: failed, toolResultMeta: data["meta"] == .null ? nil : data["meta"],
                             turn: data["turn"].integer)
        case "user/message", "assistant/message":
            let message = type == "user/message" ? data : data["message"]
            let content = message["content"]
            let text = Self.contentText(content)
            let reasoning = content.array.filter { $0["type"].string == "reasoning" }.compactMap { $0["text"].string }.joined(separator: "\n")
            let images = content.array.filter { $0["type"].string == "image" }.map { $0["attachment"]["name"].string ?? $0["name"].string ?? "Image attachment" }
            let imageReferences = ChatImageReference.references(in: content)
            guard !text.isEmpty || !reasoning.isEmpty || !images.isEmpty else { return nil }
            if type == "assistant/message" {
                return ChatEntry(id: seq, role: "assistant", text: text, reasoning: reasoning, tool: nil, detail: nil, images: images, time: time,
                                 imageReferences: imageReferences, turn: data["turn"].integer)
            }
            let source = message["source"]
            if Self.isHumanAuthored(source) {
                return ChatEntry(id: seq, role: "user", text: text, reasoning: reasoning, tool: nil, detail: nil, images: images, time: time, sourceKind: source["kind"].string, imageReferences: imageReferences)
            }
            let context = Self.contextPresentation(source)
            return ChatEntry(id: seq, role: "context", text: text, reasoning: "", tool: nil, detail: nil, images: images, time: time,
                             sourceKind: source["kind"].string, contextTitle: context.title, contextLabel: context.label, contextSummary: context.summary, imageReferences: imageReferences)
        default:
            return nil
        }
    }

    private mutating func rebuildTranscript() {
        orderedSeqs = storage.keys.sorted()
        toolNames = [:]
        entryIndex = [:]
        ledger = OpenUITurnLedger()
        var rows: [ChatEntry] = []
        rows.reserveCapacity(transcript.count)
        for seq in orderedSeqs {
            guard let event = storage[seq] else { continue }
            noteToolName(event)
            if let entry = makeEntry(seq, event) {
                entryIndex[seq] = rows.count
                rows.append(entry)
                ledger.note(entry)
            } else {
                ledger.noteLifecycle(event)
            }
        }
        transcript = rows
        transcriptRevision += 1
    }

    /// Replays the cached rows and lifecycle events in seq order (out-of-order or replaced `turn/end`).
    private mutating func rebuildLedger() {
        let before = ledger.cardsByReply
        ledger = OpenUITurnLedger()
        for seq in orderedSeqs {
            if let row = entryIndex[seq] { ledger.note(transcript[row]) }
            else if let event = storage[seq] { ledger.noteLifecycle(event) }
        }
        if ledger.cardsByReply != before { transcriptRevision += 1 }
    }

    private mutating func noteToolName(_ event: JSONValue) {
        guard event["type"].string == "tool/call", let id = event["data"]["callId"].string, let name = event["data"]["name"].string else { return }
        toolNames[id] = name
    }

    /// Keeps the cache current after one live durable event.
    private mutating func integrate(_ seq: Int, _ event: JSONValue, replacing previous: JSONValue?) {
        if previous == nil, seq > (orderedSeqs.last ?? -1) {
            orderedSeqs.append(seq)
            noteToolName(event)
            if let entry = makeEntry(seq, event) {
                entryIndex[seq] = transcript.count
                transcript.append(entry)
                ledger.note(entry)
                transcriptRevision += 1
            } else if ledger.noteLifecycle(event) {
                // The turn's actual end attached cards to its final reply.
                transcriptRevision += 1
            }
            return
        }
        if previous == event { return }
        if previous == nil {
            var low = 0, high = orderedSeqs.count
            while low < high {
                let mid = (low + high) / 2
                if orderedSeqs[mid] < seq { low = mid + 1 } else { high = mid }
            }
            orderedSeqs.insert(seq, at: low)
        }
        if Self.affectsTranscript(previous) || Self.affectsTranscript(event) { rebuildTranscript() }
        else if previous?["type"].string == "turn/end" || event["type"].string == "turn/end" { rebuildLedger() }
    }

    // MARK: Reducer

    mutating func accept(_ value: JSONValue) {
        switch value["type"].string {
        case "snapshot":
            storage = [:]
            lastLifecycleSeq = -1
            cursor = value["cursor"].integer ?? 0
            hasMore = value["hasMore"].bool ?? false
            needsBaseline = false
            for record in value["records"].array { store(record["event"], incremental: false) }
            rebuildTranscript()
            revision = value["assistantStream"]["revision"].integer ?? -1
            clearAttempt()
            let active = value["assistantStream"]["activeAttempt"]
            if let id = active["attemptId"].string {
                attempt = id
                nextIndex = active["nextIndex"].integer ?? 0
                for record in active["stream"].array { expand(record) }
            }
        case "event":
            let event = value["event"]
            if let seq = event["seq"].integer, let maxSeq = orderedSeqs.last, seq > maxSeq + 1 { needsBaseline = true }
            store(event, incremental: true)
        case "assistant-stream": acceptStream(value["frame"])
        default: break
        }
    }

    mutating func prepend(_ records: [JSONValue]) {
        var stored = false
        for record in records { stored = store(record["event"], incremental: false) || stored }
        if stored { rebuildTranscript() }
    }

    @discardableResult
    private mutating func store(_ event: JSONValue, incremental: Bool) -> Bool {
        guard let seq = event["seq"].integer, seq >= 0 else { return false }
        let previous = storage.updateValue(event, forKey: seq)
        let type = event["type"].string
        if seq > lastLifecycleSeq && (type == "turn/start" || type == "turn/end") {
            running = type == "turn/start"
            lastLifecycleSeq = seq
        }
        if settledSeq == seq { clearAttempt() }
        if incremental { integrate(seq, event, replacing: previous) }
        return true
    }

    private mutating func clearAttempt() {
        attempt = nil
        stream = [:]
        streamingText = ""
        streamingReasoning = ""
        nextIndex = 0
        settledSeq = nil
    }

    private mutating func acceptStream(_ frame: JSONValue) {
        guard let newRevision = frame["revision"].integer else { needsBaseline = true; return }
        guard newRevision == revision + 1 else { needsBaseline = true; return }
        revision = newRevision
        switch frame["type"].string {
        case "start":
            clearAttempt()
            attempt = frame["attemptId"].string
        case "chunk":
            guard let attempt, frame["attemptId"].string == attempt else { return }
            guard frame["index"].integer == nextIndex else { needsBaseline = true; return }
            nextIndex += 1
            chunk(frame["chunk"])
        case "end":
            guard let attempt, frame["attemptId"].string == attempt else { return }
            guard frame["index"].integer == nextIndex else { needsBaseline = true; return }
            if frame["outcome"]["kind"].string == "committed", let seq = frame["outcome"]["seq"].integer {
                settledSeq = seq
                if storage[seq] != nil { clearAttempt() }
            } else { clearAttempt() }
        default: break
        }
    }

    private mutating func expand(_ record: JSONValue) {
        let type = record["type"].string
        if type == "chunk" { chunk(record["chunk"]); return }
        if type == "text-chunks" || type == "reasoning-chunks" {
            for text in record["texts"].array {
                chunk(.obj(["type": .text(type == "text-chunks" ? "text-delta" : "reasoning-delta"), "index": record["index"], "text": text]))
            }
        }
    }

    private mutating func chunk(_ chunk: JSONValue) {
        guard let index = chunk["index"].integer, index >= 0 else { return }
        switch chunk["type"].string {
        case "text-delta", "reasoning-delta":
            if stream[index]?.closedBlock != nil { return }
            let type = chunk["type"].string == "text-delta" ? "text" : "reasoning"
            let delta = chunk["text"].string ?? ""
            if stream[index]?.type == type {
                stream[index]?.text.append(delta)
                // Fast path: this block is the last joined block of its type.
                if stream.contains(where: { $0.key > index && $0.value.joinType == type && $0.value.joinText != nil }) {
                    refreshStreamText()
                } else if type == "text" {
                    streamingText.append(delta)
                } else {
                    streamingReasoning.append(delta)
                }
            } else {
                // New block, or the same index switching delta type: text continues, type follows the delta.
                stream[index] = StreamBlock(type: type, text: (stream[index]?.text ?? "") + delta, closedBlock: nil)
                refreshStreamText()
            }
        case "block-end":
            if stream[index]?.closedBlock != nil { return }
            var block = chunk["block"].object ?? [:]
            block["closed"] = .bool(true)
            stream[index] = StreamBlock(type: stream[index]?.type ?? "", text: "", closedBlock: block)
            refreshStreamText()
        default: break
        }
    }

    private mutating func refreshStreamText() {
        let order = stream.keys.sorted()
        func joined(_ type: String) -> String {
            order.compactMap { index -> String? in
                guard let block = stream[index], block.joinType == type else { return nil }
                return block.joinText
            }.joined(separator: "\n")
        }
        streamingText = joined("text")
        streamingReasoning = joined("reasoning")
    }
}
