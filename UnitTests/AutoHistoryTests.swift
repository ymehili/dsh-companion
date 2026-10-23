import XCTest
@testable import DSHCompanion

@MainActor private final class HistoryTransport: NativeTransport {
    let base = ScriptedTransport()
    var credential: String? { get { base.credential } set { base.credential = newValue } }
    var onFrame: ((JSONValue) -> Void)? { get { base.onFrame } set { base.onFrame = newValue } }
    var onDisconnect: (() -> Void)? { get { base.onDisconnect } set { base.onDisconnect = newValue } }
    var requests: [JSONValue] = []
    var page: JSONValue = .obj([:])
    var failure = false
    var beforePage: (() async -> Void)?
    func openStream() { base.openStream() }
    func closeStream() { base.closeStream() }
    func sendFrame(_ value: JSONValue) async throws { try await base.sendFrame(value) }
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        guard endpoint == "session/page" else { return try await base.rpc(endpoint, payload) }
        requests.append(payload)
        let response = page, fail = failure
        await beforePage?()
        if fail { throw NativeRPCError(message: "Controlled history error") }
        return response
    }
    static func record(_ seq: Int, type: String = "assistant/message") -> JSONValue {
        .obj(["event": .obj(["seq": .number(Double(seq)), "type": .text(type), "surfaceOp": .text("append"), "data": .obj(["message": .obj(["content": .text("Synthetic message \(seq)")])])])])
    }
    func snapshot() {
        onFrame?(.obj(["type": .text("item"), "streamId": .text(base.follow), "value": .obj(["type": .text("snapshot"), "cursor": .number(120), "hasMore": .bool(true), "records": .array([Self.record(100), Self.record(120)]), "assistantStream": .obj(["revision": .number(0)])])]))
    }
}

@MainActor private final class HistoryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    let started: XCTestExpectation
    init(_ started: XCTestExpectation) { self.started = started }
    func wait() async { await withCheckedContinuation { continuation = $0; started.fulfill() } }
    func resume() { continuation?.resume(); continuation = nil }
}

final class AutoHistoryTests: XCTestCase {
    @MainActor private func setup() async -> (NativeStore, HistoryTransport) {
        let transport = HistoryTransport()
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false)
        await store.start(); await store.choose(store.sessions.first { $0.id == "one" }!)
        transport.snapshot()
        transport.page = .obj(["records": .array((80..<100).map { HistoryTransport.record($0) }), "hasMore": .bool(true)])
        return (store, transport)
    }
    @MainActor func testPageContractAndDraftPhotoIdentityStaySeparate() async throws {
        let (store, transport) = await setup()
        store.updateDraftText("My next unsent draft", for: "one")
        let photo = DraftPhoto(id: UUID(), data: Data([1, 2, 3]))
        store.attachments.restore("one", photos: [photo])
        let result = await store.older()
        XCTAssertEqual(result, .loaded)
        let request = try XCTUnwrap(transport.requests.first?["args"]["request"])
        XCTAssertEqual(request["address"]["sessionId"].string, "one")
        XCTAssertEqual(request["throughSeq"].integer, 120)
        XCTAssertEqual(request["beforeSeq"].integer, 100)
        XCTAssertEqual(request["maxMessages"].integer, 60)
        XCTAssertEqual(store.conversation.eventSeqs, Array(80..<100) + [100, 120])
        XCTAssertEqual(store.savedDraftText("one"), "My next unsent draft")
        XCTAssertEqual(store.attachments.photos(in: "one").map(\.id), [photo.id])
        XCTAssertFalse(store.historyLoading); XCTAssertNil(store.error)
        await store.setForeground(false)
    }
    @MainActor func testDuplicateAndInvalidRecordsCannotOverwriteLiveEvents() async {
        let (store, transport) = await setup()
        let original = store.conversation.events[100]
        transport.page = .obj(["records": .array([HistoryTransport.record(80), HistoryTransport.record(100, type: "turn/start"), HistoryTransport.record(121), HistoryTransport.record(-1), .obj(["event": .obj(["seq": .number(60)])])]), "hasMore": .bool(true)])
        let result = await store.older()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(store.conversation.eventSeqs, [100, 120])
        XCTAssertNotNil(store.historyError)
        XCTAssertEqual(store.conversation.events[100], original)
        await store.setForeground(false)
    }
    @MainActor func testNonProgressPagesTerminateEvenWhenPeerClaimsMore() async {
        for records in [[], [HistoryTransport.record(100)], [HistoryTransport.record(-1)], [.obj(["event": .obj(["seq": .number(80)])])]] {
            let (store, transport) = await setup()
            transport.page = .obj(["records": .array(records), "hasMore": .bool(true)])
            let result = await store.older(), next = await store.older()
            XCTAssertEqual(result, .end); XCTAssertEqual(next, .unavailable)
            XCTAssertFalse(store.conversation.hasMore); XCTAssertEqual(transport.requests.count, 1)
            await store.setForeground(false)
        }
    }
    @MainActor func testHistoryEndPreventsMoreRequests() async {
        let (store, transport) = await setup()
        transport.page = .obj(["records": .array((0..<100).map { HistoryTransport.record($0) }), "hasMore": .bool(true)])
        let result = await store.older(), next = await store.older()
        XCTAssertEqual(result, .end); XCTAssertEqual(next, .unavailable)
        XCTAssertEqual(transport.requests.count, 1); XCTAssertFalse(store.conversation.hasMore)
        await store.setForeground(false)
    }
    @MainActor func testGapsDuplicatesAndWrongBoundaryNeverSkipHistory() async {
        for seqs in [[80, 99], [98, 98, 99], [99, 98], [95, 96, 97]] {
            let (store, transport) = await setup()
            transport.page = .obj(["records": .array(seqs.map { HistoryTransport.record($0) }), "hasMore": .bool(true)])
            let result = await store.older()
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(store.conversation.eventSeqs, [100, 120])
            XCTAssertTrue(store.conversation.hasMore)
            XCTAssertNotNil(store.historyError)
            await store.setForeground(false)
        }
    }
    @MainActor func testErrorNeedsExplicitRetryAndNeverUsesGlobalModal() async {
        let (store, transport) = await setup(); transport.failure = true
        let failure = await store.older()
        XCTAssertEqual(failure, .failed); XCTAssertNotNil(store.historyError); XCTAssertNil(store.error)
        let suppressed = await store.older()
        XCTAssertEqual(suppressed, .unavailable); XCTAssertEqual(transport.requests.count, 1)
        transport.failure = false
        let retry = await store.older(retry: true)
        XCTAssertEqual(retry, .loaded); XCTAssertNil(store.historyError)
        await store.setForeground(false)
    }
    @MainActor func testOverlappingCallsAreCoalesced() async {
        let (store, transport) = await setup()
        let gate = HistoryGate(expectation(description: "Page in flight")); transport.beforePage = { await gate.wait() }
        let first = Task { await store.older() }
        await fulfillment(of: [gate.started], timeout: 3)
        let second = await store.older()
        XCTAssertEqual(second, .busy); XCTAssertEqual(transport.requests.count, 1)
        gate.resume(); _ = await first.value
        XCTAssertFalse(store.historyLoading)
        await store.setForeground(false)
    }
    @MainActor func testOldPageCannotApplyAfterSameSessionRebaseline() async {
        let (store, transport) = await setup()
        let gate = HistoryGate(expectation(description: "Old page")); transport.beforePage = { await gate.wait() }
        let old = Task { await store.older() }
        await fulfillment(of: [gate.started], timeout: 3)
        let previous = store.historyGeneration
        transport.snapshot()
        XCTAssertNotEqual(store.historyGeneration, previous)
        gate.resume(); let result = await old.value
        XCTAssertEqual(result, .superseded); XCTAssertEqual(store.conversation.eventSeqs, [100, 120])
        XCTAssertNil(store.historyError); XCTAssertFalse(store.historyLoading)
        await store.setForeground(false)
    }
    @MainActor func testOldFailureCannotClearNewSessionsLoadingOrShowError() async {
        let (store, transport) = await setup(); transport.failure = true
        let oldGate = HistoryGate(expectation(description: "Old page")); transport.beforePage = { await oldGate.wait() }
        let old = Task { await store.older() }
        await fulfillment(of: [oldGate.started], timeout: 3)
        await store.choose(store.sessions.first { $0.id == "two" }!); transport.snapshot(); transport.failure = false
        let newGate = HistoryGate(expectation(description: "New page")); transport.beforePage = { await newGate.wait() }
        let new = Task { await store.older() }
        await fulfillment(of: [newGate.started], timeout: 3)
        oldGate.resume(); let stale = await old.value
        XCTAssertEqual(stale, .superseded); XCTAssertTrue(store.historyLoading); XCTAssertNil(store.historyError)
        newGate.resume(); let result = await new.value
        XCTAssertEqual(result, .loaded); XCTAssertFalse(store.historyLoading)
        XCTAssertEqual(store.selected?.id, "two")
        await store.setForeground(false)
    }
    @MainActor func testBackgroundInvalidatesPageEvenWithoutSelectionChange() async {
        let (store, transport) = await setup()
        let gate = HistoryGate(expectation(description: "Background page")); transport.beforePage = { await gate.wait() }
        let pending = Task { await store.older() }
        await fulfillment(of: [gate.started], timeout: 3)
        await store.setForeground(false)
        gate.resume(); let result = await pending.value
        XCTAssertEqual(result, .superseded); XCTAssertFalse(store.historyLoading)
        XCTAssertEqual(store.conversation.eventSeqs, [100, 120]); XCTAssertNil(store.historyError)
    }
    @MainActor func testReconnectInvalidatesPageAndNextFollowOwnsContext() async {
        let (store, transport) = await setup()
        let gate = HistoryGate(expectation(description: "Pre-reconnect page")); transport.beforePage = { await gate.wait() }
        let pending = Task { await store.older() }
        await fulfillment(of: [gate.started], timeout: 3)
        await store.connect(force: true); transport.snapshot()
        gate.resume(); let result = await pending.value
        XCTAssertEqual(result, .superseded); XCTAssertEqual(store.conversation.eventSeqs, [100, 120])
        XCTAssertNil(store.historyError); XCTAssertFalse(store.historyLoading)
        await store.setForeground(false)
    }
    func testOnlyUpwardUserIntentNearTopCanTriggerOncePerGesture() {
        var trigger = AutoHistoryTrigger()
        XCTAssertFalse(trigger.shouldLoad(before: 200, after: 0, userScrolling: false, eligible: true))
        XCTAssertFalse(trigger.shouldLoad(before: 200, after: 0, userScrolling: true, eligible: true))
        trigger.beginGesture()
        XCTAssertFalse(trigger.shouldLoad(before: 600, after: 300, userScrolling: true, eligible: true))
        XCTAssertFalse(trigger.shouldLoad(before: 100, after: 110, userScrolling: true, eligible: true))
        XCTAssertFalse(trigger.shouldLoad(before: 100, after: 90, userScrolling: true, eligible: false))
        XCTAssertFalse(trigger.shouldLoad(before: 250, after: 230, userScrolling: true, eligible: true))
        trigger.beginGesture()
        XCTAssertTrue(trigger.shouldLoad(before: 250, after: 230, userScrolling: true, eligible: true))
        XCTAssertFalse(trigger.shouldLoad(before: 230, after: 0, userScrolling: true, eligible: true))
        trigger.beginGesture()
        XCTAssertTrue(trigger.shouldLoad(before: 0, after: -10, userScrolling: true, eligible: true))
        trigger.endGesture()
        XCTAssertFalse(trigger.shouldLoad(before: 100, after: 0, userScrolling: true, eligible: true))
    }
}
