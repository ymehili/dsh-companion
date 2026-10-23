import XCTest
import SwiftUI
import WebKit
@testable import DSHCompanion

final class OpenUIToolCardTests: XCTestCase {
    static func metadata(title: String = "Weather", source: String = "root = Card([])") -> JSONValue {
        .obj(["openui": .obj(["kind": .text("card"), "version": .number(1), "title": .text(title), "source": .text(source)])])
    }

    static func call(name: String = "openui_card") -> JSONValue {
        .obj(["seq": .number(1), "type": .text("tool/call"), "data": .obj([
            "callId": .text("card-call"), "name": .text(name), "arguments": .text("{\"action\":\"render\"}")])])
    }

    static func result(meta: JSONValue = metadata(), failed: Bool = false, content: String = "Rendered Weather card.") -> JSONValue {
        .obj(["seq": .number(2), "type": .text("tool/result"), "data": .obj([
            "meta": meta, "message": .obj(["source": .obj(["callId": .text("card-call")]), "isError": .bool(failed),
                                          "content": .array([.obj(["type": .text("text"), "text": .text(content)])])])])])
    }

    func testDurableResultMetadataSurvivesLiveSnapshotPrependAndReplacement() throws {
        let meta = Self.metadata()
        var conversation = Conversation()
        conversation.accept(.obj(["type": .text("event"), "event": Self.call()]))
        XCTAssertNil(conversation.entries.first?.openUICard, "Calls never render cards")
        conversation.accept(.obj(["type": .text("event"), "event": Self.result(meta: meta)]))
        let live = try XCTUnwrap(conversation.entries.last)
        XCTAssertEqual(live.toolResultMeta, meta)
        XCTAssertEqual(live.detail, "Rendered Weather card.", "Source remains separate from ordinary text output")
        XCTAssertEqual(live.openUICard?.source, "root = Card([])")
        var snapshot = Conversation()
        snapshot.accept(.obj(["type": .text("snapshot"), "records": .array([Self.call(), Self.result()].map { .obj(["event": $0]) })]))
        XCTAssertEqual(snapshot.entries, conversation.entries)
        var paged = Conversation()
        paged.events = [2: Self.result()]
        XCTAssertNil(paged.entries.last?.openUICard, "No inferred tool name without a durable call")
        paged.prepend([.obj(["event": Self.call()])])
        XCTAssertEqual(paged.entries, conversation.entries)
        conversation.accept(.obj(["type": .text("event"), "event": Self.result(meta: .null)]))
        XCTAssertNil(conversation.entries.last?.openUICard, "A replaced result must remove its old presentation")
    }

    func testOnlySuccessfulExactToolResultsRenderAndGuideStaysGeneric() {
        for name in ["openui_card", "OpenUI_card", "functions.openui_card", "openui_card_extra", "read"] {
            for failed in [false, true] {
                var conversation = Conversation(); conversation.events = [1: Self.call(name: name), 2: Self.result(failed: failed)]
                let rows = ToolWork.rows(conversation.entries, events: conversation.events)
                XCTAssertEqual(rows.count, 1, "The generic audit row is kept for every tool")
                XCTAssertEqual(conversation.entries.last?.openUICard != nil, name == "openui_card" && !failed)
                XCTAssertEqual(rows.first?.hasResult, true)
                XCTAssertEqual(rows.first?.output, "Rendered Weather card.")
            }
        }
        var guide = Conversation(); guide.events = [1: Self.call(), 2: Self.result(meta: .null, content: "Use render to create a card.")]
        XCTAssertNil(guide.entries.last?.openUICard)
        XCTAssertEqual(ToolWork.rows(guide.entries, events: guide.events).first?.output, "Use render to create a card.")
        var failed = Self.result().object!
        var data = failed["data"]!.object!; data["error"] = .obj(["reason": .text("Failed")]); failed["data"] = .obj(data)
        guide.events = [1: Self.call(), 2: .obj(failed)]
        XCTAssertTrue(guide.entries.last?.isError == true)
        XCTAssertNil(guide.entries.last?.openUICard)
    }

    func testEnvelopeValidationUsesExactTypesAndUTF8ByteBounds() throws {
        let base = try XCTUnwrap(Self.metadata()["openui"].object)
        let invalid: [(String, JSONValue)] = [
            ("kind", .text("guide")), ("kind", .text("Card")), ("kind", .null),
            ("version", .text("1")), ("version", .bool(true)), ("version", .number(2)), ("version", .number(1.5)),
            ("title", .null), ("title", .number(1)), ("title", .text(String(repeating: "😀", count: 41))),
            ("source", .null), ("source", .array([])), ("source", .text(" \n\t")),
            ("source", .text(String(repeating: "x", count: OpenUIToolCard.maxSourceBytes + 1))),
            ("source", .text(String(repeating: "😀", count: OpenUIToolCard.maxSourceBytes / 4 + 1)))
        ]
        for (field, value) in invalid {
            var fields = base; fields[field] = value
            XCTAssertNil(OpenUIToolCard(meta: .obj(["openui": .obj(fields)])), field)
        }
        XCTAssertNil(OpenUIToolCard(meta: .text("{\"openui\":{\"kind\":\"card\"}}")))
        XCTAssertNotNil(OpenUIToolCard(meta: Self.metadata(title: String(repeating: "😀", count: 40), source: String(repeating: "😀", count: OpenUIToolCard.maxSourceBytes / 4))))
        XCTAssertEqual(OpenUIToolCard.maxSourceBytes, OpenUIContent.maxCardBytes)
        // Invalid DSL is left to the existing sandbox/native-source fallback, not interpreted natively.
        XCTAssertEqual(OpenUIToolCard(meta: Self.metadata(source: "not valid OpenUI"))?.source, "not valid OpenUI")
    }

    func testVersionTwoRequiresExactCatalogAndVersionOneKeepsLegacyCatalog() throws {
        XCTAssertEqual(OpenUIToolCard(meta: Self.metadata())?.catalog, "chat-v1")
        var fields = try XCTUnwrap(Self.metadata()["openui"].object)
        fields["version"] = .number(2)
        XCTAssertNil(OpenUIToolCard(meta: .obj(["openui": .obj(fields)])))
        fields["catalog"] = .text("intelligent-v1")
        XCTAssertEqual(OpenUIToolCard(meta: .obj(["openui": .obj(fields)]))?.catalog, "intelligent-v1")
        for catalog in [JSONValue.null, .text("chat-v1"), .text("intelligent-v2"), .number(1)] {
            fields["catalog"] = catalog
            XCTAssertNil(OpenUIToolCard(meta: .obj(["openui": .obj(fields)])))
        }
        fields["version"] = .number(1)
        fields["catalog"] = .text("intelligent-v1")
        XCTAssertEqual(OpenUIToolCard(meta: .obj(["openui": .obj(fields)]))?.catalog, "chat-v1", "v1 always uses the legacy catalog")
    }

    func testNeverReinterpretsContentArgumentsOrMessageMetadataAsCardMetadata() {
        var conversation = Conversation()
        let text = "```openui\nroot = Card([])\n```"
        conversation.events = [1: Self.call(), 2: Self.result(meta: .null, content: text)]
        XCTAssertNil(conversation.entries.last?.openUICard)
        var call = Self.call().object!, callData = Self.call()["data"].object!
        callData["meta"] = Self.metadata(); callData["arguments"] = .text("{\"openui\":{\"kind\":\"card\",\"version\":1,\"title\":\"Fake\",\"source\":\"root = Card([])\"}}")
        call["data"] = .obj(callData)
        conversation.events = [1: .obj(call), 2: Self.result(meta: .null)]
        XCTAssertTrue(conversation.entries.allSatisfy { $0.openUICard == nil }, "Call metadata/arguments cannot create result presentations")
        var result = Self.result(meta: .null).object!
        var data = result["data"]!.object!, message = data["message"]!.object!
        message["meta"] = Self.metadata(); data["message"] = .obj(message); result["data"] = .obj(data)
        conversation.events = [1: Self.call(), 2: .obj(result)]
        XCTAssertNil(conversation.entries.last?.openUICard)
        for role in ["user", "assistant", "context"] {
            let entry = ChatEntry(id: 3, role: role, text: text, reasoning: "", tool: "openui_card", detail: nil, images: [], toolResultMeta: Self.metadata())
            XCTAssertNil(entry.openUICard)
        }
    }
}

/// Durable host events in the recorded shapes: `data.turn` on assistant/tool
/// rows, no turn on `user/message`, and `turn/end` with `data.reason.kind`.
enum TurnEvents {
    static func turnStart(_ seq: Int, turn: Int) -> JSONValue {
        .obj(["seq": .number(Double(seq)), "type": .text("turn/start"), "data": .obj(["turn": .number(Double(turn))])])
    }
    static func turnEnd(_ seq: Int, turn: Int?, reason: String? = "completed") -> JSONValue {
        var data: [String: JSONValue] = [:]
        if let turn { data["turn"] = .number(Double(turn)) }
        if let reason { data["reason"] = .obj(["kind": .text(reason)]) }
        return .obj(["seq": .number(Double(seq)), "type": .text("turn/end"), "data": .obj(data)])
    }
    static func user(_ seq: Int, _ text: String) -> JSONValue {
        .obj(["seq": .number(Double(seq)), "type": .text("user/message"), "surfaceOp": .text("append"), "data": .obj([
            "source": .obj(["kind": .text("user")]), "content": .array([.obj(["type": .text("text"), "text": .text(text)])])])])
    }
    static func assistant(_ seq: Int, turn: Int?, _ text: String, reasoning: String? = nil) -> JSONValue {
        var content: [JSONValue] = []
        if let reasoning { content.append(.obj(["type": .text("reasoning"), "text": .text(reasoning)])) }
        if !text.isEmpty { content.append(.obj(["type": .text("text"), "text": .text(text)])) }
        var data: [String: JSONValue] = ["message": .obj(["role": .text("assistant"), "content": .array(content)])]
        if let turn { data["turn"] = .number(Double(turn)) }
        return .obj(["seq": .number(Double(seq)), "type": .text("assistant/message"), "surfaceOp": .text("append"), "data": .obj(data)])
    }
    static func call(_ seq: Int, turn: Int?, id: String, name: String = "openui_card") -> JSONValue {
        var data: [String: JSONValue] = ["callId": .text(id), "name": .text(name), "arguments": .text("{\"action\":\"render\"}")]
        if let turn { data["turn"] = .number(Double(turn)) }
        return .obj(["seq": .number(Double(seq)), "type": .text("tool/call"), "data": .obj(data)])
    }
    static func result(_ seq: Int, turn: Int?, id: String, title: String? = nil, source: String = "root = Card([])",
                       meta: JSONValue? = nil, failed: Bool = false) -> JSONValue {
        var data: [String: JSONValue] = ["meta": meta ?? OpenUIToolCardTests.metadata(title: title ?? "Card \(id)", source: source),
                                         "message": .obj(["source": .obj(["kind": .text("tool"), "callId": .text(id)]), "isError": .bool(failed),
                                                          "content": .array([.obj(["type": .text("text"), "text": .text("Displayed OpenUI card: \(title ?? id)")])])])]
        if let turn { data["turn"] = .number(Double(turn)) }
        return .obj(["seq": .number(Double(seq)), "type": .text("tool/result"), "data": .obj(data)])
    }
    static func live(_ event: JSONValue) -> JSONValue { .obj(["type": .text("event"), "event": event]) }
    static func snapshot(_ events: [JSONValue], hasMore: Bool = false) -> JSONValue {
        .obj(["type": .text("snapshot"), "cursor": .number(Double(events.count)), "hasMore": .bool(hasMore),
              "records": .array(events.map { .obj(["event": $0]) }), "assistantStream": .obj(["revision": .number(0)])])
    }
    static func conversation(live events: [JSONValue]) -> Conversation {
        var conversation = Conversation()
        for event in events { conversation.accept(live(event)) }
        return conversation
    }
    static let optionsSource = """
    root = Card([choices])
    choices = Buttons([warmer, cooler])
    warmer = Button("Warmer days", @ToAssistant("Show warmer days"))
    cooler = Button("Cooler days", @ToAssistant("Show cooler days"))
    """
    /// Turn 1: request → two card calls → final reply → actual completed end (seq 0…7).
    static let completedTurn: [JSONValue] = [
        turnStart(0, turn: 1), user(1, "Show me the weather"),
        call(2, turn: 1, id: "weather"), result(3, turn: 1, id: "weather", title: "Weather", source: OpenUIWebIntegrationTests.sample),
        call(4, turn: 1, id: "options"), result(5, turn: 1, id: "options", title: "Options", source: optionsSource),
        assistant(6, turn: 1, "Here is today's weather."), turnEnd(7, turn: 1),
    ]
}

/// Final-answer placement: cards come only from a completed turn's actual end,
/// attach only to that turn's final reply and never ride along with tool work.
final class OpenUIFinalAnswerTests: XCTestCase {
    /// Compact rendering order: role/kind, seq, footer and attached card IDs.
    private func layout(_ conversation: Conversation) -> [String] {
        TranscriptItem.group(conversation.entries, events: conversation.events, running: conversation.running,
                             finalCards: conversation.finalAnswerCards).map { item in
            switch item {
            case .work(let id, let rows, let live): return "work:\(id)[\(rows.map(\.id).joined(separator: ","))]\(live ? " live" : "")"
            case .message(let entry, let footer, let cards):
                return "\(entry.role):\(entry.id)\(footer ? " footer" : "")\(cards.isEmpty ? "" : " cards[\(cards.map(\.id).joined(separator: ","))]")"
            }
        }
    }

    func testRunningTurnHasNoCardsUntilItsActualCompletedEnd() throws {
        var conversation = TurnEvents.conversation(live: Array(TurnEvents.completedTurn.dropLast()))
        XCTAssertTrue(conversation.running)
        XCTAssertNotNil(conversation.entry(for: 3)?.openUICard, "The durable result is a valid card")
        XCTAssertEqual(conversation.finalAnswerCards, [:], "No card while the turn is running, even after a reply-shaped message")
        XCTAssertEqual(layout(conversation), ["user:1", "work:2[call-weather,call-options]", "assistant:6"])
        let revision = conversation.transcriptRevision
        conversation.accept(TurnEvents.live(TurnEvents.turnEnd(7, turn: 1)))
        XCTAssertFalse(conversation.running)
        XCTAssertEqual(conversation.transcriptRevision, revision + 1, "The actual end republishes the transcript once")
        let cards = try XCTUnwrap(conversation.finalAnswerCards[6])
        XCTAssertEqual(cards.map(\.id), ["weather", "options"], "Durable call order")
        XCTAssertEqual(cards.map(\.card.title), ["Weather", "Options"])
        XCTAssertEqual(cards.first?.card.source, OpenUIWebIntegrationTests.sample)
        XCTAssertEqual(layout(conversation), ["user:1", "work:2[call-weather,call-options]", "assistant:6 footer cards[weather,options]"],
                       "Cards follow the final reply; the work group keeps only its generic rows")
        let rows = ToolWork.rows(conversation.entries.filter { $0.tool != nil }, events: conversation.events)
        XCTAssertEqual(rows.map(\.output), ["Displayed OpenUI card: Weather", "Displayed OpenUI card: Options"], "Audit output unchanged")
        XCTAssertEqual(rows.map(\.arguments), ["{\"action\":\"render\"}", "{\"action\":\"render\"}"])
        conversation.accept(TurnEvents.live(TurnEvents.turnEnd(8, turn: 1, reason: "aborted")))
        XCTAssertEqual(conversation.finalAnswerCards[6]?.count, 2, "Only the first actual end of a turn counts")
    }

    func testOnlyTheFinalReplyGetsCardsInCallOrderDedupedAndCappedAtEight() throws {
        var events: [JSONValue] = [TurnEvents.turnStart(0, turn: 1), TurnEvents.user(1, "Cards please"),
                                   TurnEvents.assistant(2, turn: 1, "Let me prepare those.")]
        var seq = 3
        func append(_ event: (Int) -> JSONValue) { events.append(event(seq)); seq += 1 }
        append { TurnEvents.call($0, turn: 1, id: "guide") }
        append { TurnEvents.result($0, turn: 1, id: "guide", meta: .obj(["openui": .obj(["kind": .text("guide")])])) }
        append { TurnEvents.call($0, turn: 1, id: "broken") }
        append { TurnEvents.result($0, turn: 1, id: "broken", failed: true) }
        append { TurnEvents.call($0, turn: 1, id: "other", name: "read") }
        append { TurnEvents.result($0, turn: 1, id: "other") }
        for index in 0..<10 {
            append { TurnEvents.call($0, turn: 1, id: "c\(index)") }
            append { TurnEvents.result($0, turn: 1, id: "c\(index)") }
        }
        append { TurnEvents.result($0, turn: 1, id: "c1", title: "Duplicate") }
        append { TurnEvents.assistant($0, turn: 1, "Here are your cards.") }
        let final = seq - 1
        append { TurnEvents.turnEnd($0, turn: 1) }
        let conversation = TurnEvents.conversation(live: events)
        XCTAssertEqual(Array(conversation.finalAnswerCards.keys), [final], "The intermediate reply has none")
        let cards = try XCTUnwrap(conversation.finalAnswerCards[final])
        let expected = (0..<8).map { "c\($0)" }
        XCTAssertEqual(cards.map(\.id), expected, "Exact successful openui_card results only, first eight")
        XCTAssertEqual(cards[1].card.title, "Card c1", "First durable result of a call wins")
        XCTAssertEqual(layout(conversation).last, "assistant:\(final) footer cards[\(expected.joined(separator: ","))]")
        XCTAssertEqual(layout(conversation)[1], "assistant:2", "No cards or footer on the intermediate reply")
    }

    func testFailedAbortedAndReplyLessTurnsRenderNothing() {
        let card = [TurnEvents.turnStart(0, turn: 1), TurnEvents.user(1, "Go"), TurnEvents.call(2, turn: 1, id: "a"), TurnEvents.result(3, turn: 1, id: "a")]
        let cases: [(String, [JSONValue])] = [
            ("completed without a final reply", card + [TurnEvents.turnEnd(4, turn: 1)]),
            ("reasoning-only last message", card + [TurnEvents.assistant(4, turn: 1, "", reasoning: "Done thinking"), TurnEvents.turnEnd(5, turn: 1)]),
            ("reply before the card tool", [TurnEvents.turnStart(0, turn: 1), TurnEvents.user(1, "Go"), TurnEvents.assistant(2, turn: 1, "Working on it"),
                                            TurnEvents.call(3, turn: 1, id: "a"), TurnEvents.result(4, turn: 1, id: "a"), TurnEvents.turnEnd(5, turn: 1)]),
            ("aborted", card + [TurnEvents.assistant(4, turn: 1, "Partial"), TurnEvents.turnEnd(5, turn: 1, reason: "aborted")]),
            ("error", card + [TurnEvents.assistant(4, turn: 1, "Partial"), TurnEvents.turnEnd(5, turn: 1, reason: "error")]),
            ("no reason", card + [TurnEvents.assistant(4, turn: 1, "Partial"), TurnEvents.turnEnd(5, turn: 1, reason: nil)]),
            ("end without turn number", card + [TurnEvents.assistant(4, turn: 1, "Done"), TurnEvents.turnEnd(5, turn: nil)]),
            ("failed card result", [TurnEvents.turnStart(0, turn: 1), TurnEvents.user(1, "Go"), TurnEvents.call(2, turn: 1, id: "a"),
                                    TurnEvents.result(3, turn: 1, id: "a", failed: true), TurnEvents.assistant(4, turn: 1, "Done"), TurnEvents.turnEnd(5, turn: 1)]),
            ("rows without durable turn", [TurnEvents.turnStart(0, turn: 1), TurnEvents.user(1, "Go"), TurnEvents.call(2, turn: nil, id: "a"),
                                           TurnEvents.result(3, turn: nil, id: "a"), TurnEvents.assistant(4, turn: nil, "Done"), TurnEvents.turnEnd(5, turn: 1)]),
        ]
        for (name, events) in cases {
            let conversation = TurnEvents.conversation(live: events)
            XCTAssertFalse(conversation.running, name)
            XCTAssertEqual(conversation.finalAnswerCards, [:], name)
            XCTAssertFalse(layout(conversation).contains { $0.contains("cards[") }, name)
        }
    }

    func testIntelligentMetadataUsesUnchangedCompletedFinalAnswerLedger() throws {
        let meta: JSONValue = .obj(["openui": .obj(["kind": .text("card"), "version": .number(2), "catalog": .text("intelligent-v1"),
                                                      "title": .text("Savings explorer"), "source": .text(OpenUIWebIntegrationTests.intelligentSample)])])
        var conversation = TurnEvents.conversation(live: [TurnEvents.turnStart(0, turn: 1), TurnEvents.call(1, turn: 1, id: "savings"),
                                                           TurnEvents.result(2, turn: 1, id: "savings", meta: meta), TurnEvents.assistant(3, turn: 1, "Try the controls.")])
        XCTAssertTrue(conversation.finalAnswerCards.isEmpty)
        conversation.accept(TurnEvents.live(TurnEvents.turnEnd(4, turn: 1)))
        let cards = try XCTUnwrap(conversation.finalAnswerCards[3])
        XCTAssertEqual(cards.map(\.id), ["savings"])
        XCTAssertEqual(cards.first?.card.catalog, "intelligent-v1")
        XCTAssertEqual(layout(conversation).last, "assistant:3 footer cards[savings]")
    }

    func testCardsNeverLeakIntoOtherTurns() throws {
        var conversation = TurnEvents.conversation(live: TurnEvents.completedTurn)
        // A late card recorded for turn 1 after its end, and turn 2 still running with its own card.
        for event in [TurnEvents.call(8, turn: 1, id: "late"), TurnEvents.result(9, turn: 1, id: "late"),
                      TurnEvents.turnStart(10, turn: 2), TurnEvents.user(11, "Another"),
                      TurnEvents.call(12, turn: 2, id: "next"), TurnEvents.result(13, turn: 2, id: "next"),
                      TurnEvents.assistant(14, turn: 2, "Second answer")] {
            conversation.accept(TurnEvents.live(event))
        }
        XCTAssertNotNil(conversation.entry(for: 9)?.openUICard)
        XCTAssertNotNil(conversation.entry(for: 13)?.openUICard)
        XCTAssertTrue(conversation.running)
        XCTAssertEqual(conversation.finalAnswerCards.mapValues { $0.map(\.id) }, [6: ["weather", "options"]])
        conversation.accept(TurnEvents.live(TurnEvents.turnEnd(15, turn: 2, reason: "aborted")))
        XCTAssertEqual(conversation.finalAnswerCards.mapValues { $0.map(\.id) }, [6: ["weather", "options"]], "Aborted turn 2 shows nothing anywhere")
        for event in [TurnEvents.turnStart(16, turn: 3), TurnEvents.user(17, "Plain"), TurnEvents.assistant(18, turn: 3, "Plain answer"), TurnEvents.turnEnd(19, turn: 3)] {
            conversation.accept(TurnEvents.live(event))
        }
        XCTAssertEqual(conversation.finalAnswerCards.mapValues { $0.map(\.id) }, [6: ["weather", "options"]])
        XCTAssertEqual(layout(conversation).filter { $0.contains("cards[") }, ["assistant:6 footer cards[weather,options]"])
    }

    func testReplayPagingAndOutOfOrderEndsMatchLive() throws {
        let live = TurnEvents.conversation(live: TurnEvents.completedTurn)
        let expected = live.finalAnswerCards
        XCTAssertFalse(expected.isEmpty)
        var snapshot = Conversation(); snapshot.accept(TurnEvents.snapshot(TurnEvents.completedTurn))
        XCTAssertEqual(snapshot.finalAnswerCards, expected, "Snapshot replay")
        XCTAssertEqual(layout(snapshot), layout(live))
        var assigned = Conversation()
        assigned.events = Dictionary(uniqueKeysWithValues: TurnEvents.completedTurn.map { ($0["seq"].integer!, $0) })
        XCTAssertEqual(assigned.finalAnswerCards, expected)

        // A history page boundary between the card results and the final reply.
        var paged = Conversation(); paged.accept(TurnEvents.snapshot(Array(TurnEvents.completedTurn[6...]), hasMore: true))
        XCTAssertEqual(paged.finalAnswerCards, [:], "No card without its durable result")
        let revision = paged.transcriptRevision
        paged.prepend(TurnEvents.completedTurn[..<6].map { .obj(["event": $0]) })
        XCTAssertEqual(paged.transcriptRevision, revision + 1, "One rebuild per page keeps the history anchor contract")
        XCTAssertEqual(paged.finalAnswerCards, expected)
        XCTAssertEqual(layout(paged), layout(live))

        // An end that lands after a later event (out of seq order) still publishes once.
        var late = TurnEvents.conversation(live: Array(TurnEvents.completedTurn.dropLast()) + [TurnEvents.turnStart(8, turn: 2)])
        XCTAssertEqual(late.finalAnswerCards, [:])
        let before = late.transcriptRevision
        late.accept(TurnEvents.live(TurnEvents.completedTurn.last!))
        XCTAssertEqual(late.finalAnswerCards, expected)
        XCTAssertEqual(late.transcriptRevision, before + 1)

        // Replacing a durable result removes its presentation.
        var replaced = live
        replaced.accept(TurnEvents.live(TurnEvents.result(3, turn: 1, id: "weather", meta: .null)))
        XCTAssertEqual(replaced.finalAnswerCards[6]?.map(\.id), ["options"])
    }

    // MARK: Hosted SwiftUI

    @MainActor private final class Host {
        let window: UIWindow
        init<V: View>(_ view: V) {
            // A scene-attached window is actually on screen, so lazy stacks lay out and snapshots capture it.
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            } else {
                window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            }
            window.windowLevel = .alert + 1
            window.overrideUserInterfaceStyle = .dark
            window.rootViewController = UIHostingController(rootView: view)
            window.isHidden = false
            window.rootViewController?.view.frame = window.bounds
            window.rootViewController?.view.layoutIfNeeded()
        }
        var webViews: [WKWebView] {
            func collect(_ view: UIView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(collect) }
            return window.rootViewController.map { collect($0.view) } ?? []
        }
        func settle(_ duration: Duration = .milliseconds(800)) async throws {
            let end = ContinuousClock.now + duration
            while ContinuousClock.now < end { window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
        }
        func rendered(containing text: String, timeout: Duration = .seconds(20)) async throws -> String {
            let deadline = ContinuousClock.now + timeout
            var rendered = ""
            while ContinuousClock.now < deadline {
                for web in webViews {
                    rendered = (try? await web.evaluateJavaScript("document.getElementById('root')?.innerText || ''")) as? String ?? ""
                    if rendered.contains(text) { return rendered }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            return rendered
        }
        func screenshot(_ name: String) -> XCTAttachment {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            if let data = image.pngData() { try? data.write(to: URL(fileURLWithPath: "/private/tmp/\(name).png")) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            return attachment
        }
        func close() { window.isHidden = true; window.rootViewController = nil }
    }

    @MainActor func testToolWorkGroupNeverMountsCardsCollapsedOrExpanded() async throws {
        let conversation = TurnEvents.conversation(live: TurnEvents.completedTurn)
        let rows = ToolWork.rows(conversation.entries.filter { $0.tool != nil }, events: conversation.events)
        XCTAssertEqual(rows.map(\.name), ["openui_card", "openui_card"])
        for expanded in [Set<String>(), Set(["group-2"] + rows.map(\.id))] {
            let host = Host(ToolWorkGroup(groupID: 2, rows: rows, live: false, expanded: expanded, toggle: { _ in }).environment(OpenUIActionInbox()))
            try await host.settle()
            XCTAssertTrue(host.webViews.isEmpty, "Work details never contain a card (expanded: \(!expanded.isEmpty))")
            host.close()
        }
    }

    @MainActor func testFinalAnswerMountsCommittedCardInExistingSandbox() async throws {
        let conversation = TurnEvents.conversation(live: TurnEvents.completedTurn)
        let reply = try XCTUnwrap(conversation.entry(for: 6))
        let cards = try XCTUnwrap(conversation.finalAnswerCards[6])
        let inbox = OpenUIActionInbox()
        let host = Host(NativeMessage(entry: reply, sessionId: "one", showsFooter: true, finalCards: [cards[0]]).environment(inbox))
        defer { host.close() }
        let rendered = try await host.rendered(containing: "Sunny")
        XCTAssertTrue(rendered.contains("Sunny"), rendered)
        XCTAssertEqual(host.webViews.count, 1)
        let web = try XCTUnwrap(host.webViews.first)
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        _ = try await web.evaluateJavaScript("document.querySelector('button')?.click(); 1")
        XCTAssertNil(inbox.staged, "Scripted clicks must not bypass the existing trusted-click gate")
    }

    @MainActor func testFinalIntelligentCardThreadsDurableIdentityAndRestoresOnlyItsOwnState() async throws {
        let session = "state-remount-\(UUID().uuidString)", call = "savings"
        let meta: JSONValue = .obj(["openui": .obj(["kind": .text("card"), "version": .number(2), "catalog": .text("intelligent-v1"),
                                                      "title": .text("Savings explorer"), "source": .text(OpenUIWebIntegrationTests.intelligentSample)])])
        let card = OpenUIFinalCard(id: call, card: try XCTUnwrap(OpenUIToolCard(meta: meta)))
        let reply = ChatEntry(id: 6, role: "assistant", text: "Try the controls.", reasoning: "", tool: nil, detail: nil, images: [])
        let host = Host(NativeMessage(entry: reply, sessionId: session, showsFooter: true, finalCards: [card]).environment(OpenUIActionInbox()))
        defer { host.close() }
        let initial = try await host.rendered(containing: "$6,000")
        XCTAssertTrue(initial.contains("$6,000"), initial)
        let web = try XCTUnwrap(host.webViews.first)
        _ = try await web.evaluateJavaScript("""
        (() => { const el = document.querySelector('input[type=range]');
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, '750');
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true})); return true; })()
        """)
        let updated = try await host.rendered(containing: "$9,000")
        XCTAssertTrue(updated.contains("$9,000"), updated)
        let deadline = ContinuousClock.now + .seconds(5)
        while OpenUIStateStore.shared.restore(sessionId: session, cardId: call, source: card.card.source, catalog: card.card.catalog) == nil,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(OpenUIStateStore.shared.restore(sessionId: session, cardId: call, source: card.card.source, catalog: card.card.catalog), "Final caller must thread durable session/card identity")
        host.close()
        let remount = Host(NativeMessage(entry: reply, sessionId: session, showsFooter: true, finalCards: [card]).environment(OpenUIActionInbox()))
        defer { remount.close() }
        let restored = try await remount.rendered(containing: "$9,000")
        XCTAssertTrue(restored.contains("$9,000"), restored)
        remount.close()
        let other = Host(NativeMessage(entry: reply, sessionId: "other-\(session)", showsFooter: true, finalCards: [card]).environment(OpenUIActionInbox()))
        defer { other.close() }
        let isolated = try await other.rendered(containing: "$6,000")
        XCTAssertTrue(isolated.contains("$6,000"), isolated)
    }

    /// End to end through NativeStore's live follow stream and the real conversation view.
    @MainActor func testLiveConversationShowsCardsOnlyAfterTheCompletedFinalAnswer() async throws {
        let transport = ScriptedTransport()
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false)
        await store.start(); await store.choose(try XCTUnwrap(store.sessions.first { $0.id == "one" }))
        XCTAssertTrue(store.conversationLoad.isLoaded)
        func emit(_ event: JSONValue) {
            transport.onFrame?(.obj(["type": .text("item"), "streamId": .text(transport.follow), "value": TurnEvents.live(event)]))
        }
        let host = Host(NativeConversation(sessionId: "one").environment(store))
        defer { host.close() }
        for event in TurnEvents.completedTurn.dropLast() { emit(event) }
        XCTAssertTrue(store.conversation.running)
        try await host.settle(.seconds(2))
        XCTAssertTrue(host.webViews.isEmpty, "Running turn: no card in the transcript, work log or reply")
        add(host.screenshot("dsh-openui-final-answer-running"))

        emit(TurnEvents.completedTurn.last!)
        XCTAssertFalse(store.conversation.running)
        let rendered = try await host.rendered(containing: "Sunny")
        XCTAssertTrue(rendered.contains("Sunny"), rendered)
        let options = try await host.rendered(containing: "Warmer days")
        XCTAssertTrue(options.contains("Cooler days"), options)
        XCTAssertEqual(host.webViews.count, 2, "Both prepared cards of the completed turn")
        try await host.settle(.seconds(1))
        add(host.screenshot("dsh-openui-final-answer-completed"))

        for event in [TurnEvents.turnStart(8, turn: 2), TurnEvents.user(9, "Again"), TurnEvents.call(10, turn: 2, id: "again"),
                      TurnEvents.result(11, turn: 2, id: "again"), TurnEvents.assistant(12, turn: 2, "Stopped early."),
                      TurnEvents.turnEnd(13, turn: 2, reason: "aborted")] { emit(event) }
        try await host.settle(.seconds(2))
        XCTAssertEqual(store.conversation.finalAnswerCards.keys.sorted(), [6])
        XCTAssertEqual(host.webViews.count, 2, "The aborted turn adds no card")
        await store.setForeground(false)
    }
}

final class OpenUIContentTests: XCTestCase {
    private func cards(_ text: String) -> [OpenUISegment] { OpenUIContent.segments(MarkdownParser.parse(text)) }

    func testOnlyTopLevelLowercaseOpenUIFencesBecomeCards() {
        let text = "Intro\n\n```openui\nroot = Card([])\n```\n\nAfter\n\n```OpenUI\nx\n```\n\n- item\n\n  ```openui\nnested\n  ```\n\n> ```openui\n> quoted\n> ```\n\n```swift\nlet openui = 1\n```"
        let segments = cards(text)
        let sources = segments.compactMap { if case .card(let source, _) = $0 { return source } else { return nil } }
        XCTAssertEqual(sources, ["root = Card([])"])
        guard case .markdown(let first) = segments.first else { return XCTFail("Leading markdown kept") }
        XCTAssertEqual(first, [.paragraph("Intro")])
        guard case .markdown(let rest) = segments.last else { return XCTFail("Trailing markdown kept") }
        XCTAssertTrue(rest.contains(.code(language: "OpenUI", code: "x", closed: true)))
        XCTAssertTrue(rest.contains(.code(language: "swift", code: "let openui = 1", closed: true)))
    }

    func testUnterminatedStreamingFenceIsAnOpenCardAndPlainAnswersSkipTheCardPath() {
        XCTAssertEqual(cards("```openui\nroot = Card(["), [.card(source: "root = Card([", closed: false)])
        XCTAssertNil(OpenUIContent.segments(for: "Just **Markdown**\n\n```js\nx\n```", cache: false))
        XCTAssertNil(OpenUIContent.segments(for: "We talk about openui here", cache: false))
        XCTAssertNotNil(OpenUIContent.segments(for: "~~~openui\nroot = Card([])\n~~~", cache: true))
    }

    func testCommittedUnterminatedFenceIsIncompleteAndNotActionable() {
        guard case .card(_, let closed)? = OpenUIContent.segments(for: "Answer\n\n```openui\nroot = Card([", cache: true)?.last else { return XCTFail("card") }
        XCTAssertFalse(closed)
        XCTAssertTrue(OpenUIContent.isIncomplete(streaming: false, closed: closed))
        XCTAssertTrue(OpenUIContent.isIncomplete(streaming: true, closed: true))
        XCTAssertFalse(OpenUIContent.isIncomplete(streaming: false, closed: true))
    }

    func testCardLimitsMatchDesktop() {
        let many = (0..<10).map { "```openui\ncard \($0)\n```" }.joined(separator: "\n\n")
        XCTAssertEqual(cards(many).filter { if case .card = $0 { return true } else { return false } }.count, 8)
        let huge = "```openui\n" + String(repeating: "a", count: OpenUIContent.maxCardBytes + 1) + "\n```"
        XCTAssertFalse(cards(huge).contains { if case .card = $0 { return true } else { return false } })
    }
}

final class OpenUIBridgeTests: XCTestCase {
    private let event: [String: Any] = ["type": "continue_conversation", "params": ["context": ["orderId": 42]],
                                        "humanFriendlyMessage": "Tell me more", "formState": [String: Any](), "formName": NSNull()]

    func testActionTextIsPrefixedCompactCanonicalJSONOfTheWholeEvent() throws {
        let action = try XCTUnwrap(OpenUIActionEvent(raw: event))
        XCTAssertTrue(action.messageText.hasPrefix("OpenUI card action:\n{"))
        XCTAssertFalse(action.json.contains("\n"))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(action.json.utf8)) as? NSDictionary)
        XCTAssertEqual(decoded, event as NSDictionary)
        XCTAssertEqual(action.humanFriendlyMessage, "Tell me more")
        XCTAssertTrue(action.displayText.contains("\"orderId\" : 42"))
    }

    func testOnlyContinueConversationWithinSixteenKiBIsAccepted() {
        XCTAssertNil(OpenUIActionEvent(raw: ["type": "open_url", "params": ["url": "https://example.com"]]))
        XCTAssertNil(OpenUIActionEvent(raw: ["type": "custom", "params": [:]]))
        XCTAssertNil(OpenUIActionEvent(raw: ["params": [:]]))
        XCTAssertNil(OpenUIActionEvent(raw: "continue_conversation"))
        XCTAssertNil(OpenUIActionEvent(raw: ["type": "continue_conversation", "humanFriendlyMessage": String(repeating: "x", count: 16_400)]))
        XCTAssertNotNil(OpenUIActionEvent(raw: ["type": "continue_conversation", "humanFriendlyMessage": String(repeating: "x", count: 16_000)]))
    }

    func testBridgeMessageParsingAndHeightPolicy() {
        XCTAssertEqual(OpenUIBridgeMessage.parse(["type": "ready"]), .ready)
        XCTAssertEqual(OpenUIBridgeMessage.parse(["type": "height", "height": 321]), .height(321))
        XCTAssertNil(OpenUIBridgeMessage.parse(["type": "height", "height": "tall"]))
        XCTAssertNil(OpenUIBridgeMessage.parse(["type": "navigate", "url": "https://example.com"]))
        XCTAssertNil(OpenUIBridgeMessage.parse(["type": "action", "event": ["type": "open_url"]]))
        if case .action = OpenUIBridgeMessage.parse(["type": "action", "event": event]) {} else { XCTFail("Valid action") }
        XCTAssertEqual(OpenUIBridgeMessage.parse(["type": "error", "message": "render-failed"]), .error("render-failed"))
        XCTAssertEqual(OpenUICardLayout.frame(for: 20_000).height, OpenUICardLayout.maxHeight)
        XCTAssertFalse(OpenUICardLayout.frame(for: 20_000).scrolls)
        XCTAssertEqual(OpenUICardLayout.maxHeight, 12_000)
        for height in [1601.0, 3000, 8000, 12_000] {
            XCTAssertEqual(OpenUICardLayout.frame(for: height).height, CGFloat(height))
            XCTAssertFalse(OpenUICardLayout.frame(for: height).scrolls, "The transcript, not the answer, owns scrolling")
        }
        XCTAssertEqual(OpenUICardLayout.frame(for: 10).height, OpenUICardLayout.minHeight)
        XCTAssertEqual(OpenUICardLayout.frame(for: 400).height, 400, "A formerly tall answer can shrink")
        XCTAssertFalse(OpenUICardLayout.frame(for: 400).scrolls)
    }

    func testNavigationAndMessageOriginPolicy() {
        let document = URL(fileURLWithPath: "/bundle/OpenUI/index.html")
        XCTAssertTrue(OpenUINavigationPolicy.allows(document, mainFrame: true, document: document, initialLoadPending: true))
        XCTAssertFalse(OpenUINavigationPolicy.allows(document, mainFrame: true, document: document, initialLoadPending: false), "No reloads")
        XCTAssertFalse(OpenUINavigationPolicy.allows(document, mainFrame: false, document: document, initialLoadPending: true))
        XCTAssertFalse(OpenUINavigationPolicy.allows(URL(string: "https://example.com/")!, mainFrame: true, document: document, initialLoadPending: true))
        XCTAssertFalse(OpenUINavigationPolicy.allows(URL(fileURLWithPath: "/etc/passwd"), mainFrame: true, document: document, initialLoadPending: true))
        XCTAssertFalse(OpenUINavigationPolicy.allows(URL(string: "file:///bundle/OpenUI/index.html#x")!, mainFrame: true, document: document, initialLoadPending: true))
        XCTAssertTrue(OpenUINavigationPolicy.acceptsMessage(mainFrame: true, originProtocol: "file", documentURL: document, document: document))
        XCTAssertFalse(OpenUINavigationPolicy.acceptsMessage(mainFrame: false, originProtocol: "file", documentURL: document, document: document))
        XCTAssertFalse(OpenUINavigationPolicy.acceptsMessage(mainFrame: true, originProtocol: "https", documentURL: document, document: document))
    }

    private let ready: [String: Any] = ["type": "ready", "protocol": 2]
    private var action: [String: Any] { ["type": "action", "event": event, "protocol": 2] }
    @MainActor private func offlineController() -> OpenUIWebController {
        OpenUIWebController(document: URL(fileURLWithPath: "/nonexistent/index.html"))
    }

    @MainActor func testControllerGatesActionsOnReadyActionableAndNonStreaming() throws {
        let controller = offlineController()
        var events: [OpenUIWebEvent] = []
        var deliveries: [OpenUIScriptCompletion] = []
        controller.evaluateScript = { _, done in deliveries.append(done) }
        controller.onEvent = { events.append($0) }
        controller.actionable = true
        controller.update(OpenUICardState(response: "root = Card([])", isStreaming: false, dark: false))
        controller.handle(action)
        XCTAssertTrue(events.isEmpty, "No action before ready")
        XCTAssertTrue(deliveries.isEmpty, "No update before ready")
        controller.handle(ready)
        XCTAssertEqual(events, [.ready])
        XCTAssertEqual(deliveries.count, 1)
        controller.handle(action)
        XCTAssertEqual(events.count, 1, "No action before the state was delivered to the page")
        deliveries[0](.success(true))
        XCTAssertEqual(controller.deliveredState?.response, "root = Card([])")
        controller.handle(action)
        XCTAssertEqual(events.last, .action(try XCTUnwrap(OpenUIActionEvent(raw: event))))
        controller.handle(action)
        XCTAssertEqual(events.count, 2, "At most one action per second")
        controller.tearDown()

        let streaming = offlineController()
        var streamed: [OpenUIWebEvent] = []
        streaming.evaluateScript = { _, done in done(.success(true)) }
        streaming.onEvent = { streamed.append($0) }
        streaming.actionable = true
        streaming.update(OpenUICardState(response: "root", isStreaming: true, dark: false))
        streaming.handle(ready); streaming.handle(action)
        XCTAssertEqual(streamed, [.ready])
        streaming.handle(["type": "error", "message": "render-failed", "protocol": 2])
        XCTAssertEqual(streamed.last, .failed(.render))
        streaming.handle(ready)
        XCTAssertEqual(streamed.count, 2, "Nothing is accepted after failure")
        streaming.tearDown()
    }

    func testBridgeEnvelopeRequiresProtocolTwo() {
        XCTAssertEqual(OpenUIBridgeProtocol.version, 2)
        XCTAssertEqual(OpenUIBridgeProtocol.classify(ready), .message(.ready))
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["type": "height", "height": 321, "protocol": 2]), .message(.height(321)))
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["type": "error", "message": "render-failed", "protocol": 2]), .message(.error("render-failed")))
        if case .message(.action) = OpenUIBridgeProtocol.classify(action) {} else { XCTFail("Valid protocol-2 action") }
        // Lifecycle messages from any other frame version fail visibly instead of hanging until the load timeout.
        for version in [nil, 1, 3, 2.5, "2", true] as [Any?] {
            var legacy: [String: Any] = ["type": "ready"]
            legacy["protocol"] = version
            XCTAssertEqual(OpenUIBridgeProtocol.classify(legacy), .incompatible, "\(String(describing: version))")
        }
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["type": "error", "message": "render-failed"]), .incompatible)
        // Mismatched height/action and malformed or unknown messages are never acted on.
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["type": "height", "height": 321]), .ignored)
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["type": "action", "event": event, "protocol": 1]), .ignored)
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["type": "navigate", "url": "https://example.com", "protocol": 2]), .ignored)
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["type": "height", "height": "tall", "protocol": 2]), .ignored)
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["protocol": 2]), .ignored)
        XCTAssertEqual(OpenUIBridgeProtocol.classify("ready"), .ignored)
    }

    @MainActor func testControllerFailsIncompatibleFrameAndDropsMismatchedMessages() throws {
        for legacy in [["type": "ready"], ["type": "ready", "protocol": 1], ["type": "error", "message": "render-failed"]] as [[String: Any]] {
            let controller = offlineController()
            var events: [OpenUIWebEvent] = []
            var evaluations = 0
            controller.evaluateScript = { _, _ in evaluations += 1 }
            controller.onEvent = { events.append($0) }
            controller.update(OpenUICardState(response: "root = Card([])", isStreaming: false, dark: false))
            controller.handle(legacy)
            XCTAssertEqual(events, [.failed(.incompatible)], "\(legacy)")
            XCTAssertTrue(controller.isFailed)
            XCTAssertFalse(controller.isReady)
            controller.handle(ready)
            XCTAssertEqual(events.count, 1, "Nothing is accepted after an incompatible frame")
            XCTAssertEqual(evaluations, 0, "No update is pushed to an incompatible frame")
            controller.tearDown()
        }
        XCTAssertFalse(OpenUICardFailure.incompatible.retryable, "Reloading the same bundled frame can't fix a mismatch")

        let controller = offlineController()
        var events: [OpenUIWebEvent] = []
        controller.evaluateScript = { _, done in done(.success(true)) }
        controller.onEvent = { events.append($0) }
        controller.actionable = true
        controller.update(OpenUICardState(response: "root = Card([])", isStreaming: false, dark: false))
        controller.handle(["type": "height", "height": 300])
        controller.handle(ready)
        controller.handle(["type": "action", "event": event])
        controller.handle(["type": "action", "event": event, "protocol": "2"])
        XCTAssertEqual(events, [.ready], "Mismatched height/action are dropped")
        controller.handle(["type": "height", "height": 300, "protocol": 2])
        controller.handle(action)
        XCTAssertEqual(events, [.ready, .height(300), .action(try XCTUnwrap(OpenUIActionEvent(raw: event)))])
        controller.tearDown()
    }

    @MainActor func testUpdateEvaluationFailureFallsBackToNativeSource() throws {
        struct Thrown: Error {}
        let outcomes: [Result<Any, Error>] = [.failure(Thrown()), .success(false), .success(NSNull())]
        for outcome in outcomes {
            let controller = offlineController()
            var events: [OpenUIWebEvent] = []
            var scripts: [String] = []
            var deliveries: [OpenUIScriptCompletion] = []
            controller.evaluateScript = { script, done in scripts.append(script); deliveries.append(done) }
            controller.onEvent = { events.append($0) }
            controller.actionable = true
            controller.update(OpenUICardState(response: "root = Card([])", isStreaming: false, dark: true))
            controller.handle(ready)
            XCTAssertEqual(scripts.count, 1)
            deliveries[0](outcome)
            XCTAssertEqual(events, [.ready, .failed(.update)], "\(outcome)")
            XCTAssertNil(controller.deliveredState)
            XCTAssertTrue(controller.isFailed)
            controller.update(OpenUICardState(response: "root = Card([x])", isStreaming: false, dark: true))
            controller.handle(action)
            XCTAssertEqual(scripts.count, 1, "No further updates after the fallback")
            XCTAssertEqual(events.count, 2, "No actions after the fallback")
            controller.tearDown()
        }
        XCTAssertTrue(OpenUICardFailure.update.retryable)
    }

    @MainActor func testUpdateScriptCarriesTheUnchangedPayloadAndReportsDelivery() throws {
        let script = try XCTUnwrap(OpenUIWebController.updateScript(for: OpenUICardState(response: "a</script>\u{2028}b", isStreaming: true, dark: true)))
        let prefix = "typeof window.dshOpenUIUpdate === 'function' ? (window.dshOpenUIUpdate(", suffix = "), true) : false"
        XCTAssertTrue(script.hasPrefix(prefix) && script.hasSuffix(suffix), script)
        let json = String(script.dropFirst(prefix.count).dropLast(suffix.count))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["response", "isStreaming", "dark", "labels", "catalog", "initialState"])
        XCTAssertEqual(payload["catalog"] as? String, "chat-v1")
        XCTAssertEqual((payload["initialState"] as? [String: Any])?.count, 0)
        XCTAssertEqual(payload["response"] as? String, "a</script>\u{2028}b")
        XCTAssertEqual(payload["isStreaming"] as? Bool, true)
        XCTAssertEqual(payload["dark"] as? Bool, true)
        let labels = try XCTUnwrap(payload["labels"] as? [String: String])
        XCTAssertEqual(Set(labels.keys), ["loading", "error", "source"])
    }

    @MainActor func testContentRuleListCompiles() async throws {
        _ = try await OpenUIWebEnvironment.ruleList()
        XCTAssertNotNil(OpenUIResources.document, "Resources/OpenUI must be bundled")
    }
}

/// End-to-end with the real bundled shell: ready, rendered height, live update,
/// blocked navigation and untrusted (scripted) clicks never produce actions.
final class OpenUIWebIntegrationTests: XCTestCase {
    static let sample = """
    root = Card([header, body, actions])
    header = CardHeader("Weather", "Today")
    body = TextContent("Sunny and 22°C")
    actions = Buttons([more])
    more = Button("Tell me more", @ToAssistant("Tell me more"))
    """

    @MainActor func testBundledShellRendersAndBlocksNavigationAndUntrustedActions() async throws {
        let document = try XCTUnwrap(OpenUIResources.document)
        let controller = OpenUIWebController(document: document)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        controller.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.addSubview(controller.webView); window.isHidden = false
        defer { controller.tearDown(); window.isHidden = true }
        var events: [OpenUIWebEvent] = []
        let ready = expectation(description: "ready"), height = expectation(description: "height")
        height.assertForOverFulfill = false
        controller.onEvent = { event in
            events.append(event)
            if case .ready = event { ready.fulfill() }
            if case .height(let value) = event, value > 80 { height.fulfill() }
        }
        var conversation = Conversation()
        conversation.events = [1: OpenUIToolCardTests.call(), 2: OpenUIToolCardTests.result(meta: OpenUIToolCardTests.metadata(source: Self.sample))]
        let card = try XCTUnwrap(conversation.entries.last?.openUICard)
        XCTAssertEqual(card.title, "Weather")
        controller.actionable = true
        controller.update(OpenUICardState(response: card.source, isStreaming: false, dark: true))
        controller.start()
        await fulfillment(of: [ready, height], timeout: 30)
        XCTAssertFalse(events.contains { if case .failed = $0 { return true } else { return false } })
        XCTAssertTrue(controller.isReady, "The bundled frame speaks bridge protocol \(OpenUIBridgeProtocol.version)")
        XCTAssertEqual(controller.deliveredState?.response, Self.sample)
        let rendered = try await controller.webView.evaluateJavaScript("document.getElementById('root').innerText") as? String
        XCTAssertTrue(rendered?.contains("Sunny") == true, rendered ?? "nil")
        let dark = try await controller.webView.evaluateJavaScript("document.documentElement.classList.contains('dark')") as? Bool
        XCTAssertEqual(dark, true)

        _ = try? await controller.webView.evaluateJavaScript("location.href = 'https://example.com/'; window.open('https://example.com/'); 1")
        _ = try? await controller.webView.evaluateJavaScript("document.querySelector('button')?.click(); 1")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(controller.webView.url?.standardizedFileURL.path, document.standardizedFileURL.path)
        XCTAssertFalse(events.contains { if case .action = $0 { return true } else { return false } }, "Scripted clicks are not user gestures")
        let fetched = try await controller.webView.callAsyncJavaScript(
            "try { await fetch('https://example.com/'); return 'loaded' } catch (e) { return 'blocked' }", contentWorld: .page) as? String
        XCTAssertEqual(fetched, "blocked")
    }

    @MainActor func testAnswerFitsLongContentShrinksAndKeepsTransparentNonScrollingBackdrop() async throws {
        let controller = OpenUIWebController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        controller.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 120)
        window.addSubview(controller.webView); window.isHidden = false
        defer { controller.tearDown(); window.isHidden = true }
        XCTAssertFalse(controller.webView.isOpaque)
        for color in [controller.webView.backgroundColor, controller.webView.underPageBackgroundColor, controller.webView.scrollView.backgroundColor] {
            XCTAssertEqual(try XCTUnwrap(color).cgColor.alpha, 0, "Transparent even when WebKit normalizes the color space")
        }
        XCTAssertFalse(controller.webView.scrollView.isScrollEnabled)
        let long = expectation(description: "answer expands past the former 1600-point cap")
        let short = expectation(description: "answer shrinks after content changes")
        long.assertForOverFulfill = false; short.assertForOverFulfill = false
        var shrinking = false, heights: [Double] = [], failures: [OpenUICardFailure] = []
        controller.onEvent = { event in
            if case .failed(let reason) = event { failures.append(reason) }
            guard case .height(let height) = event else { return }
            heights.append(height)
            let frame = OpenUICardLayout.frame(for: height)
            controller.webView.frame.size.height = frame.height
            XCTAssertFalse(frame.scrolls)
            if !shrinking && height > 1600 { long.fulfill() }
            if shrinking && height < 400 { short.fulfill() }
        }
        let rows = (0..<80).map { "row\($0)" }
        let source = "root = Col([" + rows.joined(separator: ", ") + "])\n" + rows.enumerated().map {
            "\($0.element) = Text(\"Long answer fixture row \($0.offset)\")"
        }.joined(separator: "\n")
        controller.update(OpenUICardState(response: source, isStreaming: false, dark: true, catalog: "intelligent-v1"))
        controller.start()
        await fulfillment(of: [long], timeout: 30)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertGreaterThan(controller.webView.frame.height, 1600)
        XCTAssertLessThanOrEqual(controller.webView.frame.height, OpenUICardLayout.maxHeight)
        let appearance = try await controller.webView.evaluateJavaScript("""
        (() => { const html=getComputedStyle(document.documentElement), body=getComputedStyle(document.body), root=getComputedStyle(document.getElementById('root'));
          return {html:html.backgroundColor, body:body.backgroundColor, root:root.backgroundColor,
                  htmlOverflow:html.overflow, bodyOverflow:body.overflow, rootOverflow:root.overflow}; })()
        """) as? [String: String]
        for element in ["html", "body", "root"] { XCTAssertEqual(appearance?[element], "rgba(0, 0, 0, 0)", element) }
        XCTAssertEqual(appearance?["htmlOverflow"], "hidden")
        XCTAssertEqual(appearance?["bodyOverflow"], "hidden")
        XCTAssertFalse(["auto", "scroll"].contains(appearance?["rootOverflow"] ?? ""))
        shrinking = true
        controller.update(OpenUICardState(response: "root = Col([Text(\"Short answer fixture\")])", isStreaming: false, dark: true, catalog: "intelligent-v1"))
        await fulfillment(of: [short], timeout: 10)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertLessThan(controller.webView.frame.height, 400, "Prior tall WebKit bounds must not prevent shrinking: \(heights)")
        XCTAssertFalse(controller.webView.scrollView.isScrollEnabled)
    }

    static let intelligentSample = """
    $monthly = 500
    $years = 30
    $rate = 5
    root = Col([heading, monthly, years, rate, total, annual, ask])
    heading = Title("Savings explorer")
    monthly = Slider($monthly, 0, 2000, 50, "Monthly deposit", "$")
    years = Slider($years, 1, 40, 1, "Years")
    rate = Slider($rate, 0, 10, 0.5, "Annual return", "%")
    total = Title(@Format(@FutureValue($monthly, $rate / 12, $years * 12), "currency", 0))
    annual = Text(@Format($monthly * 12, "currency", 0))
    ask = Button("Review plan", @ToAssistant("Review this savings plan"))
    """

    @MainActor private func renderedText(in controller: OpenUIWebController, containing expected: String) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(10)
        var text = ""
        // A height is layout, not React-effect completion: wait for the actual bound output.
        repeat {
            text = try await controller.webView.evaluateJavaScript("document.getElementById('root').innerText") as? String ?? ""
            if text.contains(expected) { return text }
            try await Task.sleep(for: .milliseconds(50))
        } while !controller.isFailed && ContinuousClock.now < deadline
        return text
    }

    @MainActor func testIntelligentCalculatorReactsLocallyAndRestoresAfterRemount() async throws {
        let suite = "openui-web-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OpenUIStateStore(defaults: defaults)
        let first = OpenUIWebController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        first.webView.frame = window.bounds; window.addSubview(first.webView); window.isHidden = false
        defer { first.tearDown(); window.isHidden = true }
        let rendered = expectation(description: "intelligent render"), changed = expectation(description: "local state changed")
        rendered.assertForOverFulfill = false; changed.assertForOverFulfill = false
        var events: [OpenUIWebEvent] = []
        first.onEvent = { event in
            events.append(event)
            if case .height(let height) = event, height > 150 { rendered.fulfill() }
            if case .state(let state) = event {
                store.store(state, sessionId: "session", cardId: "call", source: Self.intelligentSample, catalog: "intelligent-v1")
                if state.object["$monthly"] as? Int == 750 { changed.fulfill() }
            }
        }
        first.actionable = true
        first.update(OpenUICardState(response: Self.intelligentSample, isStreaming: false, dark: true, catalog: "intelligent-v1"))
        first.start()
        await fulfillment(of: [rendered], timeout: 30)
        XCTAssertFalse(events.contains { if case .failed = $0 { return true }; return false }, "\(events)")
        let initial = try await renderedText(in: first, containing: "$6,000")
        XCTAssertTrue(initial.contains("Savings explorer"), initial)
        XCTAssertTrue(initial.contains("$6,000"), initial)
        let count = try await first.webView.evaluateJavaScript("document.querySelectorAll('input[type=range]').length") as? Int
        XCTAssertEqual(count, 3)
        // The DOM edit exercises React's actual input/binding path; no action bridge or model call.
        _ = try await first.webView.evaluateJavaScript("""
        (() => { const el = document.querySelector('input[type=range]');
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, '750');
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true})); return true; })()
        """)
        await fulfillment(of: [changed], timeout: 10)
        let updated = try await first.webView.evaluateJavaScript("document.getElementById('root').innerText") as? String ?? ""
        XCTAssertTrue(updated.contains("$9,000"), updated)
        XCTAssertFalse(events.contains { if case .action = $0 { return true }; return false })
        first.update(OpenUICardState(response: Self.intelligentSample, isStreaming: false, dark: false, catalog: "intelligent-v1", theme: OpenUITheme(fontSize: 24)))
        let themed = try await first.webView.callAsyncJavaScript("""
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return {text:document.getElementById('root').innerText,
                font:document.documentElement.style.getPropertyValue('--iui-font-size'),
                theme:document.documentElement.dataset.theme};
        """, contentWorld: .page) as? [String: String]
        XCTAssertTrue(themed?["text"]?.contains("$9,000") == true, "Theme update must not reset local controls")
        XCTAssertEqual(themed?["font"], "24.0px")
        XCTAssertEqual(themed?["theme"], "light")
        _ = try await first.webView.evaluateJavaScript("document.querySelector('button')?.click(); true")
        XCTAssertFalse(events.contains { if case .action = $0 { return true }; return false }, "Scripted follow-up clicks remain blocked")
        first.tearDown(); first.webView.removeFromSuperview()

        let restored = try XCTUnwrap(OpenUIStateStore(defaults: defaults).restore(sessionId: "session", cardId: "call", source: Self.intelligentSample, catalog: "intelligent-v1"))
        let second = OpenUIWebController()
        second.webView.frame = window.bounds; window.addSubview(second.webView)
        defer { second.tearDown() }
        let remounted = expectation(description: "restored card")
        remounted.assertForOverFulfill = false
        second.onEvent = { if case .height(let height) = $0, height > 150 { remounted.fulfill() } }
        second.actionable = true
        second.update(OpenUICardState(response: Self.intelligentSample, isStreaming: false, dark: false, catalog: "intelligent-v1", initialState: restored))
        second.start()
        await fulfillment(of: [remounted], timeout: 30)
        let afterRemount = try await renderedText(in: second, containing: "$9,000")
        XCTAssertTrue(afterRemount.contains("$9,000"), afterRemount)
        XCTAssertEqual(second.deliveredState?.catalog, "intelligent-v1")
    }

    // MARK: Stand-in frames through the real controller and WebKit

    private static let post = "window.webkit.messageHandlers.openui.postMessage"
    private static let readyV2 = "\(post)({type: 'ready', protocol: 2});"

    @MainActor private final class StandInFrame {
        let directory: URL
        let controller: OpenUIWebController
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        var events: [OpenUIWebEvent] = []

        init(script: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("openui-stand-in-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let document = directory.appendingPathComponent("index.html")
            try Data("<!doctype html><html><body><script>\(script)</script></body></html>".utf8).write(to: document)
            controller = OpenUIWebController(document: document)
            controller.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
            window.addSubview(controller.webView); window.isHidden = false
        }

        func close() { controller.tearDown(); window.isHidden = true; try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor private func load(_ script: String, until stop: @escaping (OpenUIWebEvent) -> Bool) async throws -> StandInFrame {
        let frame = try StandInFrame(script: script)
        let done = expectation(description: "stand-in frame"); done.assertForOverFulfill = false
        frame.controller.onEvent = { [unowned frame] event in
            frame.events.append(event)
            if stop(event) { done.fulfill() }
        }
        frame.controller.actionable = true
        frame.controller.update(OpenUICardState(response: "root = Card([])", isStreaming: false, dark: false))
        frame.controller.start()
        await fulfillment(of: [done], timeout: 20)
        return frame
    }

    private static func isFailure(_ event: OpenUIWebEvent) -> Bool { if case .failed = event { return true } else { return false } }

    @MainActor func testLegacyReadyWithoutProtocolFailsVisiblyInsteadOfTimingOut() async throws {
        let started = ContinuousClock.now
        let frame = try await load("window.dshOpenUIUpdate = () => {}; \(Self.post)({type: 'ready'}); \(Self.post)({type: 'height', height: 300});") {
            Self.isFailure($0) || $0 == .ready
        }
        defer { frame.close() }
        XCTAssertEqual(frame.events, [.failed(.incompatible)])
        XCTAssertFalse(frame.controller.isReady)
        XCTAssertNil(frame.controller.deliveredState)
        XCTAssertLessThan(ContinuousClock.now - started, OpenUICard.loadTimeout, "Fails at ready, not at the load timeout")
    }

    @MainActor func testUpdateEvaluationErrorsFallBackToNativeSource() async throws {
        // Control: a working update is delivered; the stand-in echoes it as a protocol-2 height.
        let working = try await load("window.dshOpenUIUpdate = v => \(Self.post)({type: 'height', height: v.response.length + 500, protocol: 2}); \(Self.readyV2)") {
            Self.isFailure($0) || $0 == .height(515)
        }
        defer { working.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        while working.controller.deliveredState == nil, !working.controller.isFailed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(working.events, [.ready, .height(515)])
        XCTAssertEqual(working.controller.deliveredState?.response, "root = Card([])")

        let throwing = "window.dshOpenUIUpdate = () => { throw new Error('boom') }; \(Self.readyV2)"
        let missing = Self.readyV2
        for script in [throwing, missing] {
            let frame = try await load(script, until: Self.isFailure)
            XCTAssertEqual(frame.events, [.ready, .failed(.update)], script)
            XCTAssertNil(frame.controller.deliveredState)
            frame.close()
        }
    }
}

final class OpenUILocalStateTests: XCTestCase {
    func testStateObjectValidationAndCanonicalUTF8Bounds() throws {
        let state = try XCTUnwrap(OpenUIJSONState(raw: ["amount": 500, "selected": "wheel", "active": true, "nested": ["x", NSNull()]]))
        XCTAssertEqual(state.object["amount"] as? Int, 500)
        XCTAssertEqual(state, OpenUIJSONState(raw: state.object))
        for raw in [[1, 2], "value", NSNull(), ["bad": Double.infinity], ["bad": Date()]] as [Any] {
            XCTAssertNil(OpenUIJSONState(raw: raw))
        }
        // {"x":""} is eight bytes; bounds apply to the encoded object, not characters.
        XCTAssertNotNil(OpenUIJSONState(raw: ["x": String(repeating: "a", count: 16_376)]))
        XCTAssertNil(OpenUIJSONState(raw: ["x": String(repeating: "a", count: 16_377)]))
        XCTAssertNil(OpenUIJSONState(raw: ["x": String(repeating: "😀", count: 4096)]))
        var deep: Any = 1
        for _ in 0..<40 { deep = ["child": deep] }
        XCTAssertNil(OpenUIJSONState(raw: deep))
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["protocol": 2, "type": "state", "state": state.object]), .message(.state(state)))
        for bad in [[], "x", NSNull(), ["x": String(repeating: "a", count: 16_384)]] as [Any] {
            XCTAssertEqual(OpenUIBridgeProtocol.classify(["protocol": 2, "type": "state", "state": bad]), .ignored)
        }
        XCTAssertEqual(OpenUIBridgeProtocol.classify(["protocol": 1, "type": "state", "state": [:]]), .ignored)
    }

    @MainActor func testPersistentStateRemountIsolationInvalidationAndBounds() throws {
        let suite = "openui-state-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = try XCTUnwrap(OpenUIJSONState(raw: ["monthly": 750, "part": "chain"]))
        let store = OpenUIStateStore(defaults: defaults)
        store.store(state, sessionId: "session", cardId: "call", source: "root", catalog: "intelligent-v1")
        let remounted = OpenUIStateStore(defaults: defaults)
        XCTAssertEqual(remounted.restore(sessionId: "session", cardId: "call", source: "root", catalog: "intelligent-v1"), state)
        for (session, card, source, catalog) in [("other", "call", "root", "intelligent-v1"), ("session", "other", "root", "intelligent-v1"),
                                                  ("session", "call", "changed", "intelligent-v1"), ("session", "call", "root", "chat-v1")] {
            XCTAssertNil(remounted.restore(sessionId: session, cardId: card, source: source, catalog: catalog))
        }
        // Tuple hashing must not collapse ambiguous session/call concatenations.
        store.store(state, sessionId: "a:b", cardId: "c", source: "root", catalog: "intelligent-v1")
        XCTAssertNil(store.restore(sessionId: "a", cardId: "b:c", source: "root", catalog: "intelligent-v1"))
        let large = try XCTUnwrap(OpenUIJSONState(raw: ["value": String(repeating: "a", count: 16_300)]))
        for index in 0..<90 { store.store(large, sessionId: "session", cardId: "c\(index)", source: "root", catalog: "intelligent-v1") }
        let data = try XCTUnwrap(defaults.data(forKey: OpenUIStateStore.storageKey))
        XCTAssertLessThanOrEqual(data.count, OpenUIStateStore.maxStoredBytes)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertLessThanOrEqual(saved.count, OpenUIStateStore.maxRecords)
        XCTAssertNil(store.restore(sessionId: "session", cardId: "call", source: "root", catalog: "intelligent-v1"), "Oldest state is evicted")
        XCTAssertEqual(OpenUIStateStore(defaults: defaults).restore(sessionId: "session", cardId: "c89", source: "root", catalog: "intelligent-v1"), large)
        defaults.set(Data("broken".utf8), forKey: OpenUIStateStore.storageKey)
        XCTAssertNil(OpenUIStateStore(defaults: defaults).restore(sessionId: "session", cardId: "c89", source: "root", catalog: "intelligent-v1"))
    }

    @MainActor func testUpdatePayloadCarriesCatalogAndInitialState() throws {
        let initial = try XCTUnwrap(OpenUIJSONState(raw: ["amount": 750]))
        let card = OpenUICardState(response: "root", isStreaming: false, dark: true, catalog: "intelligent-v1", initialState: initial)
        XCTAssertEqual(card.payload["catalog"] as? String, "intelligent-v1")
        XCTAssertEqual((card.payload["initialState"] as? [String: Int])?["amount"], 750)
        XCTAssertTrue(try XCTUnwrap(OpenUIWebController.updateScript(for: card)).contains("intelligent-v1"))
        var scaled = card
        scaled.theme = OpenUITheme(fontSize: 28)
        XCTAssertEqual((scaled.payload["theme"] as? [String: String])?["fontSize"], "28.0px")
        XCTAssertEqual((scaled.payload["theme"] as? [String: String])?["fontFamily"], "system-ui")
        XCTAssertEqual(scaled.initialState, card.initialState)
    }

    @MainActor func testStateDeliveryIsReadyGatedCoalescedFlushedAndStoppedOnFailure() async throws {
        let controller = OpenUIWebController(document: URL(fileURLWithPath: "/nonexistent/index.html"))
        var events: [OpenUIWebEvent] = [], completions: [OpenUIScriptCompletion] = []
        controller.onEvent = { events.append($0) }
        controller.evaluateScript = { _, done in completions.append(done) }
        controller.actionable = true
        controller.update(OpenUICardState(response: "root", isStreaming: false, dark: false, catalog: "intelligent-v1"))
        func state(_ n: Int) -> [String: Any] { ["protocol": 2, "type": "state", "state": ["n": n]] }
        controller.handle(state(0))
        controller.handle(["protocol": 2, "type": "ready"])
        controller.handle(state(1))
        XCTAssertEqual(events, [.ready])
        completions[0](.success(true))
        controller.handle(state(2)); controller.handle(state(3)); controller.handle(state(4))
        XCTAssertEqual(events, [.ready], "No synchronous state storm")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(events, [.ready, .state(try XCTUnwrap(OpenUIJSONState(raw: ["n": 4])))])
        controller.handle(state(5)); controller.tearDown()
        XCTAssertEqual(events.last, .state(try XCTUnwrap(OpenUIJSONState(raw: ["n": 5]))), "Unmount flushes the latest value")
        controller.handle(state(6))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(events.count, 3)

        let failed = OpenUIWebController(document: URL(fileURLWithPath: "/nonexistent/index.html"))
        defer { failed.tearDown() }
        failed.actionable = true
        failed.evaluateScript = { _, done in done(.success(true)) }
        var failures: [OpenUIWebEvent] = []
        failed.onEvent = { failures.append($0) }
        failed.update(OpenUICardState(response: "root", isStreaming: false, dark: false))
        failed.handle(["protocol": 2, "type": "ready"])
        failed.handle(state(1)); failed.handle(["protocol": 2, "type": "error"]); failed.handle(state(2))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(failures, [.ready, .failed(.render)], "Pending and subsequent state ignored when failed")
    }

    @MainActor func testReplacingProgramDropsOldPendingStateAndInFlightMessages() async throws {
        let controller = OpenUIWebController(document: URL(fileURLWithPath: "/nonexistent/index.html"))
        defer { controller.tearDown() }
        var events: [OpenUIWebEvent] = [], completions: [OpenUIScriptCompletion] = []
        controller.onEvent = { events.append($0) }
        controller.evaluateScript = { _, done in completions.append(done) }
        controller.actionable = true
        controller.update(OpenUICardState(response: "old", isStreaming: false, dark: false))
        controller.handle(["protocol": 2, "type": "ready"]); completions[0](.success(true))
        controller.handle(["protocol": 2, "type": "state", "state": ["old": true]])
        controller.update(OpenUICardState(response: "new", isStreaming: false, dark: false, catalog: "intelligent-v1"))
        controller.handle(["protocol": 2, "type": "state", "state": ["old": true]])
        controller.handle(["protocol": 2, "type": "copy", "text": "old"])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(events, [.ready])
        completions[1](.success(true))
        controller.handle(["protocol": 2, "type": "state", "state": ["new": true]])
        controller.tearDown()
        XCTAssertEqual(events.last, .state(try XCTUnwrap(OpenUIJSONState(raw: ["new": true]))))
        controller.update(OpenUICardState(response: "after teardown", isStreaming: false, dark: false))
        XCTAssertEqual(completions.count, 2)
    }

    @MainActor func testStreamingAndNonActionableCardsNeverPersistStateOrCopy() async throws {
        for streaming in [true, false] {
            let controller = OpenUIWebController(document: URL(fileURLWithPath: "/nonexistent/index.html"))
            defer { controller.tearDown() }
            controller.actionable = streaming
            controller.evaluateScript = { _, done in done(.success(true)) }
            var events: [OpenUIWebEvent] = []
            controller.onEvent = { events.append($0) }
            controller.update(OpenUICardState(response: "root", isStreaming: streaming, dark: false))
            controller.handle(["protocol": 2, "type": "ready"])
            controller.handle(["protocol": 2, "type": "state", "state": ["x": 1]])
            controller.handle(["protocol": 2, "type": "copy", "text": "hello"])
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(events, [.ready])
        }
    }

    @MainActor func testCopyProtocolIsBoundedReadyGatedAndRateLimited() throws {
        let copy: [String: Any] = ["protocol": 2, "type": "copy", "text": "Exact receipt\n$10.00"]
        XCTAssertEqual(OpenUIBridgeProtocol.classify(copy), .message(.copy("Exact receipt\n$10.00")))
        for bad in ["", String(repeating: "😀", count: 4097), 1, NSNull()] as [Any] {
            XCTAssertEqual(OpenUIBridgeProtocol.classify(["protocol": 2, "type": "copy", "text": bad]), .ignored)
        }
        let controller = OpenUIWebController(document: URL(fileURLWithPath: "/nonexistent/index.html"))
        defer { controller.tearDown() }
        controller.actionable = true
        controller.evaluateScript = { _, done in done(.success(true)) }
        var events: [OpenUIWebEvent] = []
        controller.onEvent = { events.append($0) }
        controller.update(OpenUICardState(response: "root", isStreaming: false, dark: false))
        controller.handle(copy)
        controller.handle(["protocol": 2, "type": "ready"])
        controller.handle(copy); controller.handle(copy)
        XCTAssertEqual(events, [.ready, .copy("Exact receipt\n$10.00")])
        controller.handle(["protocol": 2, "type": "error"]); controller.handle(copy)
        XCTAssertEqual(events.count, 3)
    }

    func testReadableActionValuesKeepExactFullOutgoingEvent() throws {
        let raw: [String: Any] = ["type": "continue_conversation", "humanFriendlyMessage": "Use this plan", "formName": "Trip",
                                  "formState": ["people": 3, "confirmed": true], "params": ["context": ["destination": "Paris", "hidden": "retained"]]]
        let action = try XCTUnwrap(OpenUIActionEvent(raw: raw))
        XCTAssertEqual(action.humanFriendlyMessage, "Use this plan")
        for value in ["Form: Trip", "people: 3", "confirmed: Yes", "destination: Paris", "hidden: retained"] { XCTAssertTrue(action.valuesSummary.contains(value), action.valuesSummary) }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(action.json.utf8)) as? NSDictionary, raw as NSDictionary)
        XCTAssertEqual(action.messageText, OpenUIActionEvent.prefix + action.json)
    }
}

final class OpenUIStagedSendTests: XCTestCase {
    @MainActor private func setup(_ vault: (any NativeDraftPersisting)? = nil, fail: Bool = false) async -> (NativeStore, ScriptedTransport) {
        let transport = ScriptedTransport(); transport.failPrompt = fail
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false, draftVault: vault)
        await store.start(); await store.choose(store.sessions[0])
        return (store, transport)
    }

    @MainActor func testStagedTextSendsExactTextAndPreservesDraftAndPhotos() async throws {
        let vault = try NativeMemoryDraftVault(origin: BridgeHTTP.origin)
        let (store, transport) = await setup(vault)
        store.updateDraftText("My unfinished draft", for: "one")
        let photo = DraftPhoto(data: Data([9, 8, 7])); store.attachments.restore("one", photos: [photo])
        let action = try XCTUnwrap(OpenUIActionEvent(raw: ["type": "continue_conversation", "params": [:], "humanFriendlyMessage": "Yes"]))
        let sent = await store.sendStagedText(action.messageText, for: "one")
        XCTAssertTrue(sent)
        let content = try XCTUnwrap(transport.calls.last(where: { $0.0 == "session/prompt" })?.1["args"]["request"]["content"].array)
        XCTAssertEqual(content.count, 1, "No draft photos are attached")
        XCTAssertEqual(content[0]["text"].string, action.messageText)
        XCTAssertEqual(store.draft, "My unfinished draft")
        XCTAssertEqual(store.attachments.photos(in: "one"), [photo])
        await store.flushDrafts()
        let saved = await vault.load()
        XCTAssertEqual(saved.records["one"]?.text, "My unfinished draft")
        XCTAssertEqual(saved.records["one"]?.photos.map(\.data), [photo.data])
        XCTAssertNil(saved.records["one"]?.pending)
        await store.setForeground(false)
    }

    @MainActor func testStagedTextFailureIsDurableRetriesSameIDAndKeepsDraft() async throws {
        let vault = try NativeMemoryDraftVault(origin: BridgeHTTP.origin)
        let (store, transport) = await setup(vault, fail: true)
        store.updateDraftText("Keep me", for: "one")
        let text = "OpenUI card action:\n{\"type\":\"continue_conversation\"}"
        let sent = await store.sendStagedText(text, for: "one")
        XCTAssertFalse(sent)
        XCTAssertEqual(store.failedMessageText("one"), text)
        XCTAssertNotNil(store.deliveryWarnings["one"])
        let pending = await vault.load().records["one"]
        XCTAssertEqual(pending?.pending?.text, text); XCTAssertEqual(pending?.text, "Keep me")
        let blocked = await store.sendStagedText("another", for: "one")
        XCTAssertFalse(blocked, "One unconfirmed message per session")
        transport.failPrompt = false
        await store.retryFailedMessage("one")
        let requests = transport.calls.filter { $0.0 == "session/prompt" }.map { $0.1["args"]["request"] }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["requestId"], requests[1]["requestId"])
        XCTAssertEqual(requests[1]["content"].array.first?["text"].string, text)
        XCTAssertFalse(store.hasFailedMessage("one"))
        XCTAssertEqual(store.draft, "Keep me")
        await store.setForeground(false)
    }

    @MainActor func testStagedTextRequiresSelectedSendableSession() async {
        let (store, transport) = await setup()
        let wrongSession = await store.sendStagedText("hello", for: "two")
        XCTAssertFalse(wrongSession)
        let empty = await store.sendStagedText("  \n", for: "one")
        XCTAssertFalse(empty)
        XCTAssertFalse(transport.calls.contains { $0.0 == "session/prompt" })
        await store.setForeground(false)
    }

    @MainActor func testInboxStagesOnlyOneActionAtATime() throws {
        let inbox = OpenUIActionInbox()
        let first = try XCTUnwrap(OpenUIActionEvent(raw: ["type": "continue_conversation", "humanFriendlyMessage": "A"]))
        let second = try XCTUnwrap(OpenUIActionEvent(raw: ["type": "continue_conversation", "humanFriendlyMessage": "B"]))
        inbox.stage(first, sessionId: "one"); inbox.stage(second, sessionId: "one")
        XCTAssertEqual(inbox.staged?.event, first)
    }
}
