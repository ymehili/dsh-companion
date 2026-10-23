import XCTest
@testable import DSHCompanion

final class NativeAuxiliaryStreamTests: XCTestCase {
    @MainActor private func setup() async -> (NativeStore, ScriptedTransport) {
        let transport = ScriptedTransport()
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false)
        await store.start(); return (store, transport)
    }
    @MainActor func testTerminalMuxUsesExactOpenInputAndCancelCarrier() async throws {
        let (store, transport) = await setup(); var events: [JSONValue] = []
        let args = JSONValue.obj(["agentId": .text("one"), "id": .text("terminal-a")])
        let id = try await store.openAuxiliaryStream("terminal/attach", args: args, onEvent: { events.append($0) }, onClose: { _ in })
        let open = try XCTUnwrap(transport.sent.last)
        XCTAssertEqual(open["type"].string, "open"); XCTAssertEqual(open["endpoint"].string, "terminal/attach")
        XCTAssertEqual(open["payload"]["args"], args)
        let snapshot = JSONValue.obj(["type": .text("snapshot"), "sequence": .number(3)])
        transport.onFrame?(.obj(["type": .text("item"), "streamId": .text(id), "value": snapshot]))
        XCTAssertEqual(events, [snapshot])
        let input = JSONValue.obj(["type": .text("write"), "sequence": .number(1), "data": .text("synthetic-only")])
        try await store.sendAuxiliaryInput(id, value: input)
        XCTAssertEqual(transport.sent.last, .obj(["type": .text("item"), "streamId": .text(id), "value": input]))
        await store.closeAuxiliaryStream(id)
        XCTAssertEqual(transport.sent.last?["type"].string, "cancel")
        do { try await store.sendAuxiliaryInput(id, value: input); XCTFail("Closed input must not be replayable") } catch {}
        await store.setForeground(false)
    }
    @MainActor func testReadOnlyStreamCannotCarryTerminalInput() async throws {
        let (store, transport) = await setup()
        let id = try await store.openAuxiliaryStream("workspaceFiles/changes", args: .obj(["workspaceFileScopeId": .text("one"), "path": .text(".")]), onEvent: { _ in }, onClose: { _ in })
        let before = transport.sent.count
        do { try await store.sendAuxiliaryInput(id, value: .obj(["type": .text("write"), "sequence": .number(0), "data": .text("never forwarded") ])); XCTFail("Read stream accepted write") } catch {}
        XCTAssertEqual(transport.sent.count, before)
        await store.setForeground(false)
    }
    @MainActor func testReconnectInvalidatesOldStreamAndNeverReplaysInput() async throws {
        let (store, transport) = await setup(); var closes = 0, events = 0
        let id = try await store.openAuxiliaryStream("terminal/attach", args: .obj(["agentId": .text("one"), "id": .text("terminal-a")]), onEvent: { _ in events += 1 }, onClose: { _ in closes += 1 })
        await store.connect(force: true)
        XCTAssertEqual(closes, 1)
        transport.onFrame?(.obj(["type": .text("item"), "streamId": .text(id), "value": .obj([:])]))
        XCTAssertEqual(events, 0)
        XCTAssertEqual(transport.sent.filter { $0["endpoint"].string == "terminal/attach" }.count, 1)
        do { try await store.sendAuxiliaryInput(id, value: .obj(["type": .text("write"), "sequence": .number(2), "data": .text("no replay")])); XCTFail("Stale stream stayed writable") } catch {}
        await store.setForeground(false)
    }
    @MainActor func testStreamErrorClosesOnlyItsOwnSubscription() async throws {
        let (store, transport) = await setup(); var firstError: String?, secondEvents = 0
        let first = try await store.openAuxiliaryStream("job/list", args: .obj(["request": .obj(["sessionId": .text("one")])]), onEvent: { _ in }, onClose: { firstError = $0 })
        let second = try await store.openAuxiliaryStream("job/list", args: .obj(["request": .obj(["sessionId": .text("two")])]), onEvent: { _ in secondEvents += 1 }, onClose: { _ in })
        transport.onFrame?(.obj(["type": .text("error"), "streamId": .text(first), "error": .obj(["message": .text("Synthetic scoped error")])]))
        transport.onFrame?(.obj(["type": .text("item"), "streamId": .text(second), "value": .obj([:])]))
        XCTAssertEqual(firstError, "Synthetic scoped error"); XCTAssertEqual(secondEvents, 1); XCTAssertTrue(store.connected)
        await store.setForeground(false)
    }
}
