import XCTest
@testable import DSHCompanion

@MainActor final class MobileQueueTests: XCTestCase {
    private func row(_ id: String = "stable-item", text: String = "Original", source: String = "user", extra: [JSONValue] = []) -> JSONValue {
        .obj(["id": .text(id), "content": .array([.obj(["type": .text("text"), "text": .text(text)])] + extra), "source": .obj(["kind": .text(source), "rpcId": .text("rpc-1")])])
    }
    private func projection(_ rows: [JSONValue], steering: [JSONValue] = []) -> JSONValue {
        .obj(["inbox": .obj(["next-turn": .array(rows), "next-step": .array(steering)])])
    }
    private func item(_ value: JSONValue? = nil, session: String = "session-a") throws -> MobileQueueItem {
        try MobileQueueSnapshot(sessionId: session, projection: value ?? projection([row()])).items[0]
    }
    func testExactNestedArgsAndStableIdentityForEveryAction() async throws {
        let transport = QueueTestTransport()
        let service = MobileQueueService(sessionId: "session-a", transport: transport)
        let original = try item()
        for action in [MobileQueueAction.edit("  Keep whitespace\n"), .remove, .steer] {
            try await service.update(original, action: action)
            XCTAssertEqual(transport.calls.last?.0, "session/updateQueue")
            XCTAssertEqual(transport.calls.last?.1, .obj(["args": .obj(["request": .obj([
                "sessionId": .text("session-a"), "itemId": .text("stable-item"), "action": action.wire
            ])])]))
        }
        XCTAssertEqual(transport.calls[0].1["args"]["request"]["action"]["content"], .array([.obj(["type": .text("text"), "text": .text("  Keep whitespace\n")])]))
    }
    func testAcceptedTrueRequiredAndErrorsSanitized() async throws {
        let transport = QueueTestTransport()
        let service = MobileQueueService(sessionId: "session-a", transport: transport)
        let original = try item()
        for response in [JSONValue.null, .obj([:]), .obj(["accepted": .bool(false)]), .obj(["accepted": .text("true")])] {
            transport.response = response
            do { try await service.update(original, action: .remove); XCTFail("Missing acknowledgement") }
            catch { XCTAssertEqual(error as? MobileQueueFailure, .rejected) }
        }
        transport.failure = NativeRPCError(message: "private payload must not be shown")
        do { try await service.update(original, action: .remove); XCTFail() }
        catch { XCTAssertEqual(error as? MobileQueueFailure, .transport); XCTAssertFalse(error.localizedDescription.contains("private")) }
    }
    func testValidationNeverDispatchesWhitespaceOversizeOrNonTextEdits() async throws {
        let transport = QueueTestTransport()
        let service = MobileQueueService(sessionId: "session-a", transport: transport)
        for text in ["", " \n\t", String(repeating: "x", count: MobileQueueSnapshot.maximumTextBytes + 1)] {
            do { try await service.update(try item(), action: .edit(text)); XCTFail() }
            catch { XCTAssertEqual(error as? MobileQueueFailure, .invalidText) }
        }
        for type in ["image", "file", "tool-call", "future-part"] {
            let attached = try item(projection([row(extra: [.obj(["type": .text(type)])])]))
            XCTAssertFalse(attached.canEdit)
            do { try await service.update(attached, action: .edit("Replacement")); XCTFail() }
            catch { XCTAssertEqual(error as? MobileQueueFailure, .nonTextEdit) }
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }
    func testOtherSessionOwnershipIsNotCurrentSelection() async throws {
        let transport = QueueTestTransport()
        let service = MobileQueueService(sessionId: "session-a", transport: transport)
        do { try await service.update(try item(session: "session-b"), action: .remove); XCTFail() }
        catch { XCTAssertEqual(error as? MobileQueueFailure, .boundary) }
        XCTAssertTrue(transport.calls.isEmpty)
        let store = NativeStore(transport: transport, restoreCredentials: false)
        store.selected = SessionRow(.obj(["sessionId": .text("session-b")]))
        store.desktopProjections["session-a"] = projection([row("item-a")])
        store.desktopProjections["session-b"] = projection([row("item-b")])
        let controller = MobileQueueController(service: service)
        controller.receive(store.desktopProjections["session-a"]!)
        let captured = try XCTUnwrap(controller.snapshot?.items.first)
        let accepted = await controller.perform(captured, action: .remove)
        XCTAssertTrue(accepted)
        XCTAssertEqual(transport.calls.last?.1["args"]["request"]["sessionId"].string, "session-a")
        XCTAssertEqual(transport.calls.last?.1["args"]["request"]["itemId"].string, "item-a")
    }
    func testParsingFiltersInternalRowsAndLabelsActualKinds() throws {
        let snapshot = try MobileQueueSnapshot(sessionId: "session-a", projection: projection([row("q"), row("system", source: "system"), row("tool", source: "tool")], steering: [row("s")]))
        XCTAssertEqual(snapshot.items.map(\.id), ["q", "s"])
        XCTAssertEqual(snapshot.items.map { $0.kind.label }, ["Queued", "Steering"])
        XCTAssertTrue(snapshot.items.allSatisfy { $0.sessionId == "session-a" })
    }
    func testDuplicateConflictingIdsAndParsingLimitsFailClosed() throws {
        for value in [projection([row(), row()]), projection([row()], steering: [row(text: "Conflicting")]),
                      projection([row("")]), projection([row(" bad ")]), projection([row("x\n")]),
                      projection([row(String(repeating: "x", count: 513))]),
                      projection([row(text: String(repeating: "x", count: MobileQueueSnapshot.maximumTextBytes + 1))]),
                      projection((0...MobileQueueSnapshot.maximumRows).map { row("id-\($0)") }),
                      .obj(["inbox": .obj(["next-turn": .array([])])])] {
            XCTAssertThrowsError(try MobileQueueSnapshot(sessionId: "session-a", projection: value))
        }
    }
    func testCanonicalImagesOnlyNeverURLs() throws {
        let attachment: JSONValue = .obj(["attachmentId": .text("image-ref"), "mediaType": .text("image/png"), "bytes": .number(100), "width": .number(40), "height": .number(30)])
        let original = try item(projection([row(extra: [
            .obj(["type": .text("image"), "url": .text("https://example.invalid/private")]),
            .obj(["type": .text("image"), "attachment": attachment])
        ])]))
        XCTAssertEqual(original.images.map(\.attachmentId), ["image-ref"])
        XCTAssertEqual(original.images.first?.contentIndex, 2)
        XCTAssertFalse(original.canEdit)
    }
    func testAdmittedWhileEditingRetainsTextWithoutRPC() async throws {
        let service = QueueTestService()
        let controller = MobileQueueController(service: service)
        controller.receive(projection([row()]))
        controller.beginEdit(try XCTUnwrap(controller.snapshot?.items.first))
        controller.editing?.text = "Unsaved local edit"
        controller.receive(projection([]))
        await controller.saveEdit()
        XCTAssertEqual(controller.errors["stable-item"], .alreadyStarted)
        XCTAssertEqual(controller.editing?.text, "Unsaved local edit")
        XCTAssertTrue(service.updates.isEmpty)
    }
    func testRemoteEditConflictRetainsLocalText() async throws {
        let service = QueueTestService()
        let controller = MobileQueueController(service: service)
        controller.receive(projection([row()]))
        controller.beginEdit(try XCTUnwrap(controller.snapshot?.items.first))
        controller.editing?.text = "Local"
        controller.receive(projection([row(text: "Remote")]))
        await controller.saveEdit()
        XCTAssertEqual(controller.errors["stable-item"], .changed)
        XCTAssertEqual(controller.editing?.text, "Local")
        XCTAssertTrue(service.updates.isEmpty)
    }
    func testFailedEditRetryKeepsTextAndId() async throws {
        let service = QueueTestService()
        let controller = MobileQueueController(service: service)
        controller.receive(projection([row()]))
        controller.beginEdit(try XCTUnwrap(controller.snapshot?.items.first))
        controller.editing?.text = "Retained retry text"
        service.failure = .transport
        await controller.saveEdit()
        XCTAssertEqual(controller.editing?.text, "Retained retry text")
        XCTAssertEqual(controller.errors["stable-item"], .transport)
        XCTAssertTrue(controller.pending.isEmpty)
        service.failure = nil
        await controller.saveEdit()
        XCTAssertNil(controller.editing)
        XCTAssertEqual(service.updates.map { $0.0.id }, ["stable-item", "stable-item"])
        XCTAssertEqual(service.updates.map { $0.1 }, [.edit("Retained retry text"), .edit("Retained retry text")])
    }
    func testBackendMissingRowRefreshesAndKeepsEdit() async throws {
        let service = QueueTestService()
        service.failure = .alreadyStarted; service.projection = projection([])
        let controller = MobileQueueController(service: service)
        controller.receive(projection([row()]))
        controller.beginEdit(try XCTUnwrap(controller.snapshot?.items.first))
        controller.editing?.text = "Keep me"
        await controller.saveEdit()
        XCTAssertEqual(service.reads, 1)
        XCTAssertEqual(controller.editing?.text, "Keep me")
        XCTAssertEqual(controller.errors["stable-item"], .alreadyStarted)
        await controller.saveEdit()
        XCTAssertEqual(service.updates.count, 1)
    }
    func testPendingAndCapturedActionSurviveAdmissionDuringRequest() async throws {
        let service = QueueTestService()
        let controller = MobileQueueController(service: service)
        controller.receive(projection([row()]))
        let original = try XCTUnwrap(controller.snapshot?.items.first)
        controller.beginEdit(original)
        controller.editing?.text = "Captured edit"
        service.failure = .alreadyStarted
        service.projection = projection([])
        service.onUpdate = {
            XCTAssertEqual(controller.pending, [original.id])
            controller.receive(self.projection([]))
            XCTAssertEqual(controller.editing?.text, "Captured edit")
        }
        await controller.saveEdit()
        XCTAssertEqual(service.updates.count, 1)
        XCTAssertEqual(service.updates[0].0, original)
        XCTAssertEqual(service.updates[0].1, .edit("Captured edit"))
        XCTAssertEqual(controller.editing?.text, "Captured edit")
        XCTAssertTrue(controller.pending.isEmpty)
    }
    func testLiveProjectionWinsOverInFlightRefresh() async throws {
        let service = QueueTestService()
        let controller = MobileQueueController(service: service)
        service.projection = projection([row("stale")])
        service.onRead = { controller.receive(self.projection([self.row("new-live")])) }
        await controller.refresh()
        XCTAssertEqual(controller.snapshot?.items.map(\.id), ["new-live"])
    }
    func testProjectionRefreshIsNonactivatingAndCorrectlyNested() async throws {
        let transport = QueueTestTransport()
        transport.response = .obj(["asOfSeq": .number(4), "values": projection([row()])])
        let service = MobileQueueService(sessionId: "session-a", transport: transport)
        _ = try await service.readProjection()
        XCTAssertEqual(transport.calls.map { $0.0 }, ["session/projections"])
        XCTAssertEqual(transport.calls[0].1, .obj(["args": .obj(["request": .obj(["sessionId": .text("session-a")])])]))
    }
    func testFixturePositiveGraphAllActionsAreSynthetic() async throws {
        let service = MobileQueueFixtureService(sessionId: "fixture-session")
        var snapshot = try MobileQueueSnapshot(sessionId: service.sessionId, projection: await service.readProjection())
        XCTAssertEqual(snapshot.items.filter { $0.kind == .queued }.count, 2)
        XCTAssertEqual(snapshot.items.filter { $0.kind == .steering }.count, 1)
        let id = snapshot.items[0].id
        try await service.update(snapshot.items[0], action: .edit("Synthetic edit"))
        snapshot = try MobileQueueSnapshot(sessionId: service.sessionId, projection: await service.readProjection())
        XCTAssertEqual(snapshot.items[0].id, id); XCTAssertEqual(snapshot.items[0].text, "Synthetic edit")
        try await service.update(snapshot.items[0], action: .steer)
        snapshot = try MobileQueueSnapshot(sessionId: service.sessionId, projection: await service.readProjection())
        let steered = try XCTUnwrap(snapshot.items.first { $0.id == id })
        XCTAssertEqual(steered.kind, .steering)
        try await service.update(steered, action: .remove)
        snapshot = try MobileQueueSnapshot(sessionId: service.sessionId, projection: await service.readProjection())
        XCTAssertFalse(snapshot.items.contains { $0.id == id })
    }
}

@MainActor private final class QueueTestTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var response: JSONValue = .obj(["accepted": .bool(true)])
    var failure: Error?
    var calls: [(String, JSONValue)] = []
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        calls.append((endpoint, payload))
        if let failure { throw failure }
        return response
    }
    func openStream() { }
    func sendFrame(_ value: JSONValue) async throws { }
    func closeStream() { }
}

@MainActor private final class QueueTestService: MobileQueueServing {
    let sessionId = "session-a"
    var failure: MobileQueueFailure?
    var projection: JSONValue = MobileQueueFixtureService.graph
    var reads = 0
    var onUpdate: (() -> Void)?
    var onRead: (() -> Void)?
    var updates: [(MobileQueueItem, MobileQueueAction)] = []
    func update(_ item: MobileQueueItem, action: MobileQueueAction) async throws {
        updates.append((item, action))
        onUpdate?()
        if let failure { throw failure }
    }
    func readProjection() async throws -> JSONValue { reads += 1; onRead?(); return projection }
}
