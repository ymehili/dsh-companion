import XCTest
@testable import DSHCompanion

@MainActor
final class ScriptedTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var calls: [(String, JSONValue)] = []
    var sent: [JSONValue] = []
    var openCount = 0
    var closeCount = 0
    var readyAutomatically = true
    var snapshotsAutomatically = true
    var failPrompt = false
    var failAnswer = false
    var receiptBeforeReply = false
    var events = ""
    var follow = ""
    var beforeFollow: (@MainActor (JSONValue) async throws -> Void)?
    var beforeFrame: (@MainActor (JSONValue) async throws -> Void)?
    func openStream() { openCount += 1 }
    func closeStream() { closeCount += 1 }
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        calls.append((endpoint, payload))
        switch endpoint {
        case "session/list": return .obj(["items": .array([row("one"), row("two")])])
        case "threadInbox/snapshot": return .obj(["full": .bool(true), "epoch": .text("test"), "revision": .number(0), "settings": .obj(["activated": .bool(true)]), "threads": .obj([:])])
        case "threadInbox/watch": try await Task.sleep(for: .seconds(60)); throw CancellationError()
        case "$events/result", "userQuestions/answer":
            if failAnswer { throw NativeRPCError(message: "Synthetic answer failure") }; return .bool(true)
        case "session/prompt":
            if receiptBeforeReply {
                let message: JSONValue = .obj(["source": .obj(["kind": .text("user"), "rpcId": payload["args"]["request"]["requestId"]]), "content": payload["args"]["request"]["content"]])
                onFrame?(.obj(["type": .text("item"), "streamId": .text(follow), "value": .obj(["type": .text("event"), "event": .obj(["type": .text("user/message"), "seq": .number(0), "surfaceOp": .text("append"), "data": message])])]))
            }
            if failPrompt { throw NativeRPCError(message: "Simulated timeout") }
            return .obj(["accepted": .bool(true)])
        default: return .obj([:])
        }
    }
    func row(_ id: String) -> JSONValue { .obj(["sessionId": .text(id), "updatedAt": .number(1000), "running": .bool(false), "projections": .obj(["values": .obj(["title": .text(id)])])]) }
    func sendFrame(_ frame: JSONValue) async throws {
        sent.append(frame)
        try await beforeFrame?(frame)
        guard frame["type"].string == "open", let stream = frame["streamId"].string else { return }
        switch frame["endpoint"].string {
        case "$events": events = stream; if readyAutomatically { ready() }
        case "session/follow":
            try await beforeFollow?(frame)
            try Task.checkCancellation() // mirror NativeGateway after its asynchronous send
            follow = stream; if snapshotsAutomatically { snapshot() }
        case "workspace/follow": onFrame?(.obj(["type": .text("item"), "streamId": .text(stream), "value": .obj(["type": .text("baseline"), "value": .obj(["items": .array([]), "archivedSessionIds": .array([]), "pinnedSessionIds": .array([])])])]))
        default: break
        }
    }
    func ready() { onFrame?(.obj(["type": .text("item"), "streamId": .text(events), "value": .obj(["type": .text("ready"), "clientId": .text("test-client"), "host": .obj(["home": .text("test")])])])) }
    func snapshot() { onFrame?(.obj(["type": .text("item"), "streamId": .text(follow), "value": .obj(["type": .text("snapshot"), "cursor": .number(0), "records": .array([]), "hasMore": .bool(false), "projections": .obj(["asOfSeq": .number(0), "values": .obj([:])]), "assistantStream": .obj(["revision": .number(0)])])])) }
    func endFollow() { onFrame?(.obj(["type": .text("end"), "streamId": .text(follow)])) }
    func emit(_ event: String, _ args: [JSONValue]) { onFrame?(.obj(["type": .text("item"), "streamId": .text(events), "value": .obj(["type": .text("emit"), "event": .text(event), "args": .array(args)])])) }
}
@MainActor
private final class ScriptedPairing: NativePairingClient {
    var fail = false
    func pair(_ link: String) async throws -> String {
        if fail { throw NativeRPCError(message: "This QR has expired") }
        return String(repeating: "a", count: 43)
    }
}

final class NativeStoreTests: XCTestCase {
    @MainActor private func setup() async -> (NativeStore, ScriptedTransport) {
        let transport = ScriptedTransport()
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false)
        await store.start()
        return (store, transport)
    }
    @MainActor func testLaunchAndActiveDoNotReconnectTwice() async {
        let (store, transport) = await setup()
        XCTAssertTrue(store.connected)
        await store.start(); await store.setForeground(true); await store.setForeground(true)
        XCTAssertEqual(transport.openCount, 1)
        XCTAssertEqual(transport.calls.filter { $0.0 == "session/list" }.count, 1)
        await store.setForeground(false)
    }
    @MainActor func testLoadingWaitsForSnapshotAndDisablesSend() async {
        let (store, transport) = await setup()
        transport.snapshotsAutomatically = false
        await store.choose(store.sessions[0])
        XCTAssertEqual(store.conversationLoad, .loading)
        XCTAssertFalse(store.canSend)
        transport.snapshot()
        XCTAssertEqual(store.conversationLoad, .loaded)
        XCTAssertTrue(store.canSend)
        await store.setForeground(false)
    }
    @MainActor func testFollowEndDoesNotKillOtherStreamsOrReconnect() async {
        let (store, transport) = await setup()
        await store.choose(store.sessions[0])
        let closed = transport.closeCount
        transport.endFollow()
        XCTAssertTrue(store.connected)
        XCTAssertEqual(transport.closeCount, closed)
        XCTAssertEqual(transport.openCount, 1)
        if case .failed = store.conversationLoad {} else { XCTFail("Must show a scoped retry state") }
        XCTAssertFalse(store.canSend)
        await store.setForeground(false)
    }
    @MainActor func testRemovedSelectionCannotEnterReconnectLoop() async {
        let (store, transport) = await setup()
        await store.choose(store.sessions[0]); let id = store.selected!.id
        store.draft = "Keep my unsent text"
        transport.emit("api-session/removed", [.text(id)])
        XCTAssertNil(store.selected)
        XCTAssertTrue(store.connected)
        XCTAssertEqual(transport.openCount, 1)
        await store.setForeground(false)
    }
    @MainActor func testUncertainDeliverySurvivesReconnectAndRetriesSameID() async {
        let (store, transport) = await setup()
        await store.choose(store.sessions[0]); let id = store.selected!.id
        transport.failPrompt = true; store.draft = "Hello"
        do { let delivered = await store.send(for: id); XCTAssertFalse(delivered) }
        XCTAssertNotNil(store.deliveryWarnings[id])
        XCTAssertEqual(store.failedMessageText(id), "Hello")
        store.draft = "My next message"
        await store.connect(force: true)
        XCTAssertNotNil(store.deliveryWarnings[id])
        XCTAssertEqual(store.draft, "My next message")
        await store.retryFailedMessage(id)
        XCTAssertEqual(store.draft, "My next message")
        let requests = transport.calls.filter { $0.0 == "session/prompt" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].1["args"]["request"]["requestId"], requests[1].1["args"]["request"]["requestId"])
        await store.setForeground(false)
    }
    @MainActor func testActivityPatchesRowsWithoutFullListFetch() async {
        let (store, transport) = await setup()
        for time in 1...20 { transport.emit("api-session/activity", [.text("one"), .number(Double(time + 1000))]) }
        XCTAssertEqual(transport.calls.filter { $0.0 == "session/list" }.count, 1)
        XCTAssertEqual(store.sessions.first?.id, "one")
        XCTAssertEqual(store.sessions.first?.updatedAt, 1020)
        await store.setForeground(false)
    }
    @MainActor func testPairingFailureIsScopedAndVisible() async {
        let pairing = ScriptedPairing(); pairing.fail = true
        let store = NativeStore(transport: ScriptedTransport(), pairingClient: pairing, restoreCredentials: false)
        let paired = await store.pair("test")
        XCTAssertFalse(paired)
        XCTAssertEqual(store.pairingError, "This QR has expired")
        XCTAssertNil(store.error)
        XCTAssertFalse(store.paired)
    }
    @MainActor func testOfflineChoiceHasRetryStateNotEmptyNewChat() async {
        let transport = ScriptedTransport()
        let store = NativeStore(transport: transport, restoreCredentials: false)
        await store.choose(SessionRow(transport.row("one"))!)
        if case .failed = store.conversationLoad {} else { XCTFail("Offline load needs an error state") }
        XCTAssertFalse(store.canSend)
        XCTAssertTrue(transport.sent.isEmpty)
    }
    @MainActor func testReadyDeadlineStopsAnIndefiniteConnectingState() async throws {
        let transport = ScriptedTransport(); transport.readyAutomatically = false
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false)
        store.connectionDeadline = .milliseconds(30)
        await store.start()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(store.connecting)
        XCTAssertFalse(store.connected)
        XCTAssertNotEqual(store.status, "Connecting…")
        XCTAssertNotNil(store.connectionIssue)
        await store.setForeground(false)
    }
    @MainActor func testDurableReceiptWinsOverAnUncertainHTTPReply() async {
        let (store, transport) = await setup()
        await store.choose(store.sessions[0]); let id = store.selected!.id
        transport.receiptBeforeReply = true; transport.failPrompt = true
        store.draft = "Accepted by Mac"
        let delivered = await store.send(for: id)
        XCTAssertTrue(delivered)
        XCTAssertNil(store.deliveryWarnings[id])
        XCTAssertFalse(store.hasFailedMessage(id))
        XCTAssertEqual(store.conversation.entries.filter { $0.role == "user" }.count, 1)
        await store.setForeground(false)
    }
    @MainActor func testModelErrorsDoNotReuseGlobalActionErrors() async {
        let (store, _) = await setup()
        store.error = "Unrelated action"; store.modelError = "Old model error"
        await store.loadModels()
        XCTAssertEqual(store.error, "Unrelated action")
        XCTAssertNil(store.modelError)
        await store.setForeground(false)
    }
    @MainActor func testLogFailureDoesNotPretendTheAgentStopped() async {
        let (store, transport) = await setup()
        await store.choose(store.sessions[0]); let id = store.selected!.id
        transport.emit("api-session/status", [.text(id), .bool(true)])
        XCTAssertTrue(store.conversation.running)
        transport.endFollow()
        XCTAssertTrue(store.connected)
        XCTAssertTrue(store.conversation.running, "A stream failure must not hide Stop for a running Mac agent")
        transport.emit("api-session/status", [.text(id), .bool(false)])
        XCTAssertFalse(store.conversation.running)
        await store.setForeground(false)
    }
    @MainActor func testMultiImagePromptKeepsAllImagesAndOrder() async {
        let (store, transport) = await setup()
        await store.choose(store.sessions[0]); let id = store.selected!.id
        store.draft = "Compare these"
        let images = [Data([1,2]), Data([3,4])]
        let sent = await store.send(for: id, images: images)
        XCTAssertTrue(sent)
        let content = transport.calls.last(where: { $0.0 == "session/prompt" })!.1["args"]["request"]["content"].array
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[0]["text"].string, "Compare these")
        XCTAssertEqual(content.dropFirst().compactMap { $0["data"].string.flatMap { Data(base64Encoded: $0) } }, images)
        XCTAssertTrue(store.draft.isEmpty)
        await store.setForeground(false)
    }
    @MainActor func testMultiImageFailureRetriesExactPayloadWithoutTouchingNextDraft() async {
        let (store, transport) = await setup()
        await store.choose(store.sessions[0]); let id = store.selected!.id
        transport.failPrompt = true
        let sent = await store.send(for: id, images: [Data([1]),Data([2])])
        XCTAssertFalse(sent)
        store.draft = "Next draft"
        await store.retryFailedMessage(id)
        let requests = transport.calls.filter { $0.0 == "session/prompt" }.map { $0.1["args"]["request"] }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["requestId"], requests[1]["requestId"])
        XCTAssertEqual(requests[0]["content"], requests[1]["content"])
        XCTAssertEqual(requests[0]["content"].array.count, 2)
        XCTAssertEqual(store.draft, "Next draft")
        await store.setForeground(false)
    }
    @MainActor func testHostPhotoLimitRejectsWithoutSendingOrClearingDraft() async {
        let (store, transport) = await setup()
        await store.choose(store.sessions[0]); let id = store.selected!.id
        store.desktopProjections[id] = .obj(["imageLimits": .obj(["maxImagesPerMessage": .number(1)])])
        store.draft = "Keep me"
        let sent = await store.send(for: id, images: [Data([1]),Data([2])])
        XCTAssertFalse(sent)
        XCTAssertEqual(store.draft, "Keep me")
        XCTAssertNotNil(store.error)
        XCTAssertTrue(transport.calls.filter { $0.0 == "session/prompt" }.isEmpty)
        await store.setForeground(false)
    }
}
