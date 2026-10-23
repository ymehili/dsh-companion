import XCTest
@testable import DSHCompanion

final class MobileTerminalTests: XCTestCase {
    func testOutputRequiresBaselineIgnoresDuplicateAndRejectsGap() throws {
        var state = MobileTerminalProtocol()
        XCTAssertThrowsError(try state.output(sequence: 1))
        try state.baseline(sequence: 10, writable: true, maxBytes: 2048, overhead: 32)
        XCTAssertFalse(try state.output(sequence: 10))
        XCTAssertTrue(try state.output(sequence: 11))
        XCTAssertThrowsError(try state.output(sequence: 13))
        XCTAssertEqual(state.outputSequence, 11)
    }
    func testInputByteLimitWindowAndOrderedAcknowledgments() throws {
        var state = MobileTerminalProtocol(); state.maxInputBytes = 4
        try state.baseline(sequence: 0, writable: true, maxBytes: 200, overhead: 20)
        XCTAssertThrowsError(try state.reserve(["type": .text("write"), "data": .text("🙂a")]))
        let first = try state.reserve(["type": .text("write"), "data": .text("🙂")])
        XCTAssertEqual(first["sequence"].integer, 1)
        XCTAssertGreaterThan(state.pendingBytes, 20)
        XCTAssertThrowsError(try state.acknowledge(2, refusal: nil))
        try state.acknowledge(1, refusal: "read-only")
        XCTAssertFalse(state.writable); XCTAssertEqual(state.pendingBytes, 0)
        XCTAssertThrowsError(try state.reserve(["type": .text("write"), "data": .text("a")]))
    }
    func testEncodedFrameOverheadCountsAgainstInputWindow() throws {
        var state = MobileTerminalProtocol()
        try state.baseline(sequence: 0, writable: true, maxBytes: 90, overhead: 40)
        XCTAssertThrowsError(try state.reserve(["type": .text("write"), "data": .text(String(repeating: "\n", count: 20))]))
        XCTAssertEqual(state.inputSequence, 0)
    }
    func testResetChangesGenerationAndNeverReplaysUnacknowledgedWrite() throws {
        var state = MobileTerminalProtocol()
        try state.baseline(sequence: 0, writable: true, maxBytes: nil, overhead: nil)
        _ = try state.reserve(["type": .text("write"), "data": .text("never replay")])
        let generation = state.generation; state.reset()
        XCTAssertNotEqual(state.generation, generation)
        XCTAssertTrue(state.pending.isEmpty); XCTAssertNil(state.outputSequence)
        try state.baseline(sequence: 20, writable: true, maxBytes: nil, overhead: nil)
        let resize = try state.reserve(["type": .text("resize"), "cols": .number(80), "rows": .number(24)])
        XCTAssertEqual(resize["sequence"].integer, 1)
        XCTAssertNil(resize["data"].string)
    }
    @MainActor func testControllerOnlyListsUntilExplicitSelectionAndDisconnectDoesNotKill() async throws {
        let fake = TerminalServiceFake(); let controller = MobileTerminalController(sessionId: "s", service: fake)
        await controller.refresh()
        XCTAssertEqual(fake.calls.map(\.0), ["terminal/list"])
        XCTAssertEqual(fake.attachCount, 0)
        await controller.select(controller.terminals[0])
        XCTAssertTrue(controller.canInput)
        XCTAssertEqual(fake.lastAttach, .obj(["agentId": .text("s"), "id": .text("fixture-terminal")]))
        await controller.disconnect()
        XCTAssertFalse(controller.canInput)
        XCTAssertFalse(fake.calls.contains { $0.0 == "terminal/close" || $0.0 == "terminal/create" })
    }
    @MainActor func testReconnectDropsWritesAndIgnoresOldGeneration() async throws {
        let fake = TerminalServiceFake(); let controller = MobileTerminalController(sessionId: "s", service: fake)
        await controller.refresh(); await controller.select(controller.terminals[0])
        let previousEvent = fake.event
        controller.write("not replayed")
        controller.write("queued and discarded")
        await fake.waitForInput()
        XCTAssertEqual(fake.inputs.count, 1)
        fake.closed?("transport reset")
        let count = fake.inputs.count
        await controller.retryAttachment()
        previousEvent?(.obj(["type": .text("output"), "sequence": .number(1), "data": .text("stale")]))
        XCTAssertFalse(controller.renderChunks.contains("stale"))
        await Task.yield()
        XCTAssertEqual(fake.inputs.count, count)
        XCTAssertTrue(controller.protocolState.pending.isEmpty)
        await controller.disconnect()
    }
    @MainActor func testGapDisablesInputUntilFreshAttachment() async throws {
        let fake = TerminalServiceFake(); let controller = MobileTerminalController(sessionId: "s", service: fake)
        await controller.refresh(); await controller.select(controller.terminals[0])
        fake.event?(.obj(["type": .text("output"), "sequence": .number(2), "data": .text("gap")]))
        XCTAssertFalse(controller.canInput)
        XCTAssertFalse(controller.renderChunks.contains("gap"))
        XCTAssertNotNil(controller.issue)
        await controller.retryAttachment(); XCTAssertTrue(controller.canInput)
        await controller.disconnect()
    }
    @MainActor func testCreateRetryRetainsIdAndSendsNoCommandOrAutoResume() async throws {
        let fake = TerminalServiceFake(); fake.failCreate = true
        let controller = MobileTerminalController(sessionId: "s", service: fake)
        await controller.createConfirmed(); let id = controller.pendingCreationID
        XCTAssertNotNil(id)
        await controller.createConfirmed()
        let creates = fake.calls.filter { $0.0 == "terminal/create" }
        XCTAssertEqual(creates.count, 2); XCTAssertEqual(creates[0].1, creates[1].1)
        XCTAssertEqual(creates[0].1["request"]["id"].string, id)
        XCTAssertTrue(fake.inputs.isEmpty)
        XCTAssertFalse(fake.calls.contains { $0.0.contains("resume") || $0.0 == "session/prompt" })
    }
    @MainActor func testFixtureEchoIsLocalAndSupportsRenameAndClose() async throws {
        let service = MobileTerminalFixtureService()
        let controller = MobileTerminalController(sessionId: "fixture", service: service)
        await controller.refresh(); XCTAssertEqual(controller.terminals.count, 1)
        await controller.select(controller.terminals[0])
        var events: [JSONValue] = []
        let id = try await service.attach(args: .obj(["id": .text("fixture-terminal")]), event: { events.append($0) }, close: { _ in })
        try await service.input(id, value: .obj(["type": .text("write"), "sequence": .number(1), "data": .text("echo hello\r")]))
        XCTAssertTrue(events.contains { $0["data"].string?.contains("\r\nhello\r\n") == true })
        XCTAssertEqual(events.last?["type"].string, "ack")
        await controller.rename("Renamed demo"); XCTAssertEqual(controller.selected?.title, "Renamed demo")
        await controller.closeConfirmed(); XCTAssertNil(controller.selected)
        await controller.refresh(); XCTAssertTrue(controller.terminals.isEmpty)
    }
}

@MainActor
private final class TerminalServiceFake: MobileTerminalService {
    var calls: [(String, JSONValue)] = []
    var event: ((JSONValue) -> Void)?
    var closed: ((String?) -> Void)?
    var inputs: [JSONValue] = []
    var attachCount = 0
    var lastAttach: JSONValue?
    var failCreate = false
    func rpc(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        calls.append((endpoint, args))
        if endpoint == "terminal/create", failCreate { throw NativeRPCError(message: "Synthetic lost response") }
        if endpoint == "terminal/environment" { return try encode(MobileTerminalEnvironment.fixture) }
        if endpoint == "terminal/list" { return .array([try encode(MobileTerminalInfo.fixture)]) }
        return .null
    }
    func attach(args: JSONValue, event: @escaping (JSONValue) -> Void, close: @escaping (String?) -> Void) async throws -> String {
        attachCount += 1; lastAttach = args; self.event = event; closed = close
        event(.obj(["type": .text("snapshot"), "sequence": .number(0), "screen": .text("$ "), "info": try encode(MobileTerminalInfo.fixture), "writable": .bool(true)]))
        return "attach-\(attachCount)"
    }
    private var inputWaiter: CheckedContinuation<Void, Never>?
    func waitForInput() async {
        if !inputs.isEmpty { return }
        await withCheckedContinuation { inputWaiter = $0 }
    }
    func input(_ id: String, value: JSONValue) async throws {
        inputs.append(value); inputWaiter?.resume(); inputWaiter = nil
    }
    func disconnect(_ id: String) async {}
    private func encode<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
}
