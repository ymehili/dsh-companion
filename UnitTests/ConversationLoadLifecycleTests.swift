import XCTest
@testable import DSHCompanion

@MainActor private final class LoadGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ started: XCTestExpectation) { self.started = started }
    func wait() async { await withCheckedContinuation { continuation = $0; started.fulfill() } }
    func resume() { continuation?.resume(); continuation = nil }
}

final class ConversationLoadLifecycleTests: XCTestCase {
    @MainActor private func setup() async -> (NativeStore, ScriptedTransport) {
        let transport = ScriptedTransport()
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false)
        await store.start(); return (store, transport)
    }
    @MainActor func testCancellingDetailTaskDuringFollowDoesNotFailSelectedConversation() async {
        let (store, transport) = await setup()
        let reached = expectation(description: "Follow send suspended"), gate = LoadGate(reached)
        transport.beforeFollow = { _ in await gate.wait() }
        let row = store.sessions.first(where: { $0.id == "one" })!
        let detailTask = Task { @MainActor in await store.choose(row) }
        await fulfillment(of: [reached], timeout: 3)
        detailTask.cancel(); gate.resume(); await detailTask.value
        XCTAssertEqual(store.conversationLoad, .loaded)
        XCTAssertEqual(store.selected?.id, "one")
        await store.setForeground(false)
    }
    @MainActor func testAlreadyCancelledDetailTaskStillLoadsCurrentSelection() async {
        let (store, _) = await setup()
        let reached = expectation(description: "Detail task mounted"), gate = LoadGate(reached)
        let row = store.sessions.first(where: { $0.id == "one" })!
        let detailTask = Task { @MainActor in await gate.wait(); await store.choose(row) }
        await fulfillment(of: [reached], timeout: 3)
        detailTask.cancel(); gate.resume(); await detailTask.value
        XCTAssertEqual(store.conversationLoad, .loaded)
        await store.setForeground(false)
    }
    @MainActor func testSupersededFollowCannotFailNewChat() async {
        let (store, transport) = await setup()
        let reached = expectation(description: "Old session send suspended"), gate = LoadGate(reached)
        transport.beforeFollow = { frame in
            if frame["payload"]["args"]["request"]["address"]["sessionId"].string == "one" { await gate.wait() }
        }
        let old = Task { @MainActor in await store.choose(store.sessions.first(where: { $0.id == "one" })!) }
        await fulfillment(of: [reached], timeout: 3)
        await store.choose(store.sessions.first(where: { $0.id == "two" })!)
        gate.resume(); await old.value
        XCTAssertEqual(store.selected?.id, "two"); XCTAssertEqual(store.conversationLoad, .loaded)
        await store.setForeground(false)
    }
    @MainActor func testRemountedDetailCoalescesAlreadyLoadingSession() async {
        let (store, transport) = await setup()
        let reached = expectation(description: "Loading before remount"), gate = LoadGate(reached)
        transport.beforeFollow = { _ in await gate.wait() }
        let row = store.sessions[0]
        let first = Task { @MainActor in await store.choose(row) }
        await fulfillment(of: [reached], timeout: 3)
        await store.choose(row)
        XCTAssertEqual(transport.sent.filter { $0["endpoint"].string == "session/follow" }.count, 1)
        gate.resume(); await first.value
        XCTAssertEqual(store.conversationLoad, .loaded)
        await store.setForeground(false)
    }
    @MainActor func testDeadlineRemainsMeaningfulWhenOwnedOpeningIsCancelled() async {
        let (store, transport) = await setup(); store.connectionDeadline = .milliseconds(30)
        let reached = expectation(description: "Send awaiting deadline"), gate = LoadGate(reached)
        transport.beforeFollow = { _ in await gate.wait() }
        let task = Task { @MainActor in await store.choose(store.sessions[0]) }
        await fulfillment(of: [reached], timeout: 3)
        try? await Task.sleep(for: .milliseconds(80))
        guard case .failed(let before) = store.conversationLoad else { gate.resume(); await task.value; return XCTFail("Deadline should remain visible") }
        XCTAssertTrue(before.contains("Loading timed out"))
        gate.resume(); await task.value
        XCTAssertEqual(store.conversationLoad, .failed(before))
        await store.setForeground(false)
    }
    @MainActor func testRealFollowFailureStillShowsErrorAndExplicitRetryWorks() async {
        let (store, transport) = await setup()
        transport.beforeFollow = { _ in throw NativeRPCError(message: "Synthetic transport failure") }
        await store.choose(store.sessions[0])
        guard case .failed(let message) = store.conversationLoad else { return XCTFail("Real errors must remain visible") }
        XCTAssertTrue(message.contains("Synthetic transport failure"))
        transport.beforeFollow = nil; await store.retryConversation()
        XCTAssertEqual(store.conversationLoad, .loaded)
        await store.setForeground(false)
    }
}
