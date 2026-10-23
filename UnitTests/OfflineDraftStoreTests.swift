import XCTest
@testable import DSHCompanion

private actor FailingDraftVault: NativeDraftPersisting {
    func load() -> NativeDraftVaultSnapshot { .init(records: [:], revisions: [:], issues: []) }
    func save(record: NativeDraftRecord, revision: UInt64) throws -> Bool { throw NativeDraftVaultError.quota("synthetic storage full") }
    func remove(sessionId: String, revision: UInt64) throws -> Bool { throw NativeDraftVaultError.io("synthetic failure") }
}
private actor DraftSaveGate: NativeDraftPersisting {
    let memory: NativeMemoryDraftVault
    let reached: XCTestExpectation
    private var waiter: CheckedContinuation<Void, Never>?
    init(_ reached: XCTestExpectation) throws { self.reached = reached; memory = try NativeMemoryDraftVault(origin: BridgeHTTP.origin) }
    func load() async -> NativeDraftVaultSnapshot { await memory.load() }
    func save(record: NativeDraftRecord, revision: UInt64) async throws -> Bool {
        if record.pending != nil { await withCheckedContinuation { waiter = $0; reached.fulfill() } }
        return try await memory.save(record: record, revision: revision)
    }
    func release() { waiter?.resume(); waiter = nil }
    func remove(sessionId: String, revision: UInt64) async throws -> Bool { try await memory.remove(sessionId: sessionId, revision: revision) }
}
final class OfflineDraftStoreTests: XCTestCase {
    @MainActor private func setup(_ vault: any NativeDraftPersisting, fail: Bool = false) async -> (NativeStore, ScriptedTransport) {
        let transport = ScriptedTransport(); transport.failPrompt = fail
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false, draftVault: vault)
        await store.start(); return (store, transport)
    }
    @MainActor func testUnconfirmedDiskPayloadRestoresWithoutReplayAndRetriesExactOriginal() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = parent.appendingPathComponent("DSHStoreDraftTests-" + UUID().uuidString, isDirectory: true)
        defer {
            let resolved = root.resolvingSymlinksInPath()
            if resolved.deletingLastPathComponent() == parent && resolved.lastPathComponent.hasPrefix("DSHStoreDraftTests-") { try? FileManager.default.removeItem(at: resolved) }
        }
        let firstVault = try NativeDraftVault(rootFolderURL: root, origin: BridgeHTTP.origin)
        let (first, firstWire) = await setup(firstVault, fail: true)
        await first.choose(first.sessions[0]); first.conversation.running = true
        first.updateDraftText("Original immutable message", for: "one")
        let images = [Data([1, 2, 3]), Data([4, 5, 6])]
        let sent = await first.send(for: "one", images: images)
        XCTAssertFalse(sent)
        let original = try XCTUnwrap(firstWire.calls.last(where: { $0.0 == "session/prompt" })?.1)
        first.updateDraftText("My separate next draft", for: "one")
        let token = first.attachments.begin("one")
        _ = try first.attachments.append("one", token: token, data: Data([7, 8, 9]), limits: PhotoLimits())
        _ = first.attachments.finish("one", token: token, data: nil)
        let photoID = first.attachments.photos(in: "one")[0].id
        await first.flushDrafts(); await first.setForeground(false)
        let persisted = await firstVault.load()
        XCTAssertEqual(persisted.records["one"]?.pending?.mode, "steer")
        XCTAssertEqual(persisted.records["one"]?.pending?.images, images)
        XCTAssertEqual(persisted.records["one"]?.text, "My separate next draft")
        let reopened = try NativeDraftVault(rootFolderURL: root, origin: BridgeHTTP.origin)
        let (second, secondWire) = await setup(reopened)
        XCTAssertTrue(second.hasFailedMessage("one"))
        XCTAssertFalse(secondWire.calls.contains { $0.0 == "session/prompt" })
        await second.choose(second.sessions.first { $0.id == "two" }!)
        second.updateDraftText("Other session draft", for: "two"); second.setFollowUpMode("queue")
        XCTAssertEqual(second.attachments.photos(in: "one")[0].id, photoID)
        await second.retryFailedMessage("one")
        let retried = try XCTUnwrap(secondWire.calls.last(where: { $0.0 == "session/prompt" })?.1)
        XCTAssertEqual(retried, original) // ID/content/image bytes/order/mode/timezone
        XCTAssertEqual(second.selected?.id, "two"); XCTAssertEqual(second.draft, "Other session draft")
        await second.choose(second.sessions.first { $0.id == "one" }!)
        XCTAssertEqual(second.draft, "My separate next draft")
        XCTAssertEqual(second.attachments.photos(in: "one").map(\.data), [Data([7, 8, 9])])
        await second.flushDrafts()
        let acknowledged = await reopened.load()
        XCTAssertNil(acknowledged.records["one"]?.pending)
        await second.setForeground(false)
    }
    @MainActor func testNoNetworkDispatchBeforeDurablePendingSaveCompletes() async throws {
        let reached = expectation(description: "Pending payload reached vault")
        let vault = try DraftSaveGate(reached), (store, wire) = await setup(vault)
        await store.choose(store.sessions[0]); store.updateDraftText("Save before dispatch", for: "one")
        let task = Task { @MainActor in await store.send(for: "one", images: []) }
        await fulfillment(of: [reached], timeout: 3)
        XCTAssertFalse(wire.calls.contains { $0.0 == "session/prompt" })
        await vault.release(); let sent = await task.value; XCTAssertTrue(sent)
        await store.setForeground(false)
    }
    @MainActor func testStorageFailureDoesNotSendAndRetainsPayloadAndNextDraft() async {
        let (store, wire) = await setup(FailingDraftVault())
        await store.choose(store.sessions[0]); store.updateDraftText("Do not lose me", for: "one")
        let result = await store.send(for: "one", images: [])
        XCTAssertFalse(result); XCTAssertFalse(wire.calls.contains { $0.0 == "session/prompt" })
        XCTAssertEqual(store.failedMessageText("one"), "Do not lose me"); XCTAssertNotNil(store.draftSaveErrors["one"])
        store.updateDraftText("Separate editable text", for: "one")
        await store.retryFailedMessage("one")
        XCTAssertFalse(wire.calls.contains { $0.0 == "session/prompt" }); XCTAssertEqual(store.draft, "Separate editable text")
        await store.setForeground(false)
    }
    @MainActor func testDraftAndPreparedPhotoStayInOwningSessionAcrossSelectionAndRestore() async throws {
        let vault = try NativeMemoryDraftVault(origin: BridgeHTTP.origin), (store, _) = await setup(vault)
        await store.choose(store.sessions[0]); store.updateDraftText("First session", for: "one")
        let photo = DraftPhoto(data: Data([10, 11]))
        store.attachments.restore("one", photos: [photo]); store.markUnsentDraft("one")
        await store.choose(store.sessions.first { $0.id == "two" }!); store.updateDraftText("Second session", for: "two")
        await store.setForeground(false)
        let (restored, wire) = await setup(vault)
        await restored.choose(restored.sessions.first { $0.id == "one" }!)
        XCTAssertEqual(restored.draft, "First session"); XCTAssertEqual(restored.attachments.photos(in: "one"), [photo])
        XCTAssertTrue(restored.unsentSessions.contains("one")); XCTAssertFalse(wire.calls.contains { $0.0 == "session/prompt" })
        await restored.choose(restored.sessions.first { $0.id == "two" }!)
        XCTAssertEqual(restored.draft, "Second session"); XCTAssertTrue(restored.attachments.photos(in: "two").isEmpty)
        await restored.setForeground(false)
    }
    @MainActor func testDiscardIsLocalOnlyAndTombstonePreventsReappearance() async throws {
        let vault = try NativeMemoryDraftVault(origin: BridgeHTTP.origin), (store, wire) = await setup(vault)
        await store.choose(store.sessions[0]); store.updateDraftText("Local only", for: "one"); store.markUnsentDraft("one")
        await store.flushDrafts(); let before = wire.calls.count
        let removed = await store.removeLocalDraft("one"); XCTAssertTrue(removed)
        XCTAssertEqual(wire.calls.count, before); XCTAssertTrue(store.sessions.contains { $0.id == "one" })
        XCTAssertFalse(store.unsentSessions.contains("one")); XCTAssertNil(store.localDraftRecords["one"])
        let snapshot = await vault.load(); XCTAssertNil(snapshot.records["one"]); XCTAssertNotNil(snapshot.revisions["one"])
        await store.setForeground(false)
    }
}
