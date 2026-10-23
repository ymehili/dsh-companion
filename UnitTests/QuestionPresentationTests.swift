import XCTest
@testable import DSHCompanion

@MainActor private final class QuestionSendGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    init(_ started: XCTestExpectation) { self.started = started }
    func wait() async { await withCheckedContinuation { continuation = $0; started.fulfill() } }
    func resume() { continuation?.resume(); continuation = nil }
}

final class QuestionPresentationTests: XCTestCase {
    private func request() -> JSONValue {
        .obj(["questions": .array([.obj(["id": .text("choice"), "question": .text("Choose one"), "options": .array([.obj(["label": .text("A")]), .obj(["label": .text("B")])])])]), "wait": .obj(["callId": .text("same-call"), "timed": .bool(true)])])
    }
    private func card(_ session: String = "one", id: String = "same-event") -> NativeQuestionCard {
        NativeQuestionCard(id: id, sessionId: session, request: request())!
    }
    @MainActor private func setup() async -> (NativeStore, ScriptedTransport) {
        let transport = ScriptedTransport()
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false)
        await store.start(); store.liveQuestions = [card()]; return (store, transport)
    }
    @MainActor func testDraftsAreStoreAndAuthorizationAndOwnerScoped() async {
        let (one, _) = await setup(), (two, _) = await setup()
        two.imageAuthorizationScope = one.imageAuthorizationScope
        let a = card(), b = card("two")
        var draft = NativeQuestionDraft(); draft.toggle("A", in: a.questions[0])
        let key = one.questionPresentationKey(a)
        one.questionDraftBook.update(key, draft)
        XCTAssertNotNil(one.questionDraftBook.draft(key).answers(for: a))
        XCTAssertNil(two.questionDraftBook.draft(two.questionPresentationKey(a)).answers(for: a))
        XCTAssertNotEqual(key, one.questionPresentationKey(b))
        one.imageAuthorizationScope = UUID()
        XCTAssertNil(one.questionDraftBook.draft(one.questionPresentationKey(a)).answers(for: a))
        await one.setForeground(false); await two.setForeground(false)
    }
    @MainActor func testInlineAndSheetShareOneWaitUntilLastVisibleHolderLeaves() async {
        let (store, transport) = await setup(); let pending = store.questions[0]
        let inline = UUID(), sheet = UUID(), leases = store.questionLeaseBook
        let first = leases.sync(holder: inline, cards: [pending], previous: [:], store: store)
        let second = leases.sync(holder: sheet, cards: [pending], previous: [:], store: store)
        await leases.drain()
        let opens = transport.sent.filter { $0["endpoint"].string == "userQuestions/attachWait" }
        XCTAssertEqual(opens.count, 1); let stream = opens[0]["streamId"].string!
        _ = leases.sync(holder: sheet, cards: [], previous: second, store: store)
        await leases.drain()
        XCTAssertFalse(transport.sent.contains { $0["type"].string == "cancel" && $0["streamId"].string == stream })
        _ = leases.sync(holder: inline, cards: [], previous: first, store: store)
        await leases.drain()
        XCTAssertEqual(transport.sent.filter { $0["type"].string == "cancel" && $0["streamId"].string == stream }.count, 1)
        await store.setForeground(false)
    }
    @MainActor func testRapidPresentationChangesUseOnlyLatestDesiredState() async {
        let (store, transport) = await setup(); let pending = store.questions[0], holder = UUID(), leases = store.questionLeaseBook
        let visible = leases.sync(holder: holder, cards: [pending], previous: [:], store: store)
        _ = leases.sync(holder: holder, cards: [], previous: visible, store: store)
        await leases.drain()
        XCTAssertTrue(transport.sent.filter { $0["endpoint"].string == "userQuestions/attachWait" }.isEmpty)
        let visibleAgain = leases.sync(holder: holder, cards: [pending], previous: [:], store: store)
        _ = leases.sync(holder: holder, cards: [], previous: visibleAgain, store: store)
        _ = leases.sync(holder: holder, cards: [pending], previous: [:], store: store)
        await leases.drain()
        XCTAssertEqual(transport.sent.filter { $0["endpoint"].string == "userQuestions/attachWait" }.count, 1)
        await store.setForeground(false)
    }
    @MainActor func testResetInvalidatesScheduledOldAuthorizationWork() async {
        let (store, transport) = await setup(); let pending = store.questions[0]
        _ = store.questionLeaseBook.sync(holder: UUID(), cards: [pending], previous: [:], store: store)
        store.imageAuthorizationScope = UUID(); store.questionLeaseBook.reset(); store.questionDraftBook.reset()
        await store.questionLeaseBook.drain()
        XCTAssertTrue(transport.sent.filter { $0["endpoint"].string == "userQuestions/attachWait" }.isEmpty)
        await store.setForeground(false)
    }
    @MainActor func testLateOldLeaseSendErrorCannotEraseNewClaim() async {
        let (store, transport) = await setup(); let pending = store.questions[0]
        let reached = expectation(description: "Old lease send blocked"), gate = QuestionSendGate(reached)
        var opens = 0
        transport.beforeFrame = { frame in
            guard frame["endpoint"].string == "userQuestions/attachWait" else { return }
            opens += 1
            if opens == 1 { await gate.wait(); throw NativeRPCError(message: "Synthetic late old error") }
        }
        let old = Task { @MainActor in await store.setQuestionVisible(pending, visible: true) }
        await fulfillment(of: [reached], timeout: 3)
        await store.setQuestionVisible(pending, visible: false)
        await store.setQuestionVisible(pending, visible: true)
        let newest = transport.sent.last(where: { $0["endpoint"].string == "userQuestions/attachWait" })!["streamId"].string!
        gate.resume(); await old.value
        XCTAssertNil(store.questionErrors[pending.id])
        await store.setQuestionVisible(pending, visible: false)
        XCTAssertEqual(transport.sent.last?["streamId"].string, newest)
        XCTAssertEqual(transport.sent.last?["type"].string, "cancel")
        await store.setForeground(false)
    }
}
