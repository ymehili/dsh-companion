import XCTest
@testable import DSHCompanion

@MainActor final class MobileLifecycleTests: XCTestCase {
    private func baseline(version: Int = 4, epoch: String = "epoch-a", active: Bool = true, facts: JSONValue = .obj(["completedAt": .number(900)])) -> JSONValue {
        MobileLifecycleService.snapshot(epoch: epoch, revision: version, activated: active, threads: ["session-a": .obj(["version": .number(Double(version)), "facts": facts])])
    }
    private func result(_ version: Int = 5, epoch: String = "epoch-a", token: String? = "host-token", expiry: Double = 6000) -> JSONValue {
        .obj(["epoch": .text(epoch), "revision": .number(Double(version)), "threads": .obj(["session-a": .obj(["version": .number(Double(version)), "pinnedAt": .number(1000)])]), "undoToken": token.map(JSONValue.text) ?? .null, "undoExpiresAt": .number(expiry)])
    }
    func testExactWireCapturesImmutableIdentityEpochVersionsAndArguments() async throws {
        let transport = LifecycleTestTransport()
        transport.handler = { _, _ in self.result() }
        let service = MobileLifecycleService(transport: transport, now: { 1000 }, uuid: { "immutable-command" })
        service.synchronize(baseline())
        let command = try service.capture(id: "session-a", action: .snooze, arguments: .obj(["until": .number(50000)]))
        try await service.execute(command)
        XCTAssertEqual(transport.calls.first?.0, "threadInbox/apply")
        XCTAssertEqual(transport.calls.first?.1, .obj(["args": .obj(["request": .obj([
            "commandId": .text("immutable-command"), "epoch": .text("epoch-a"), "ids": .array([.text("session-a")]), "versions": .obj(["session-a": .number(4)]), "action": .text("snooze"), "args": .obj(["until": .number(50000)])
        ])])]))
        XCTAssertEqual(service.replica.threads["session-a"]?["version"].integer, 5)
    }
    func testAmbiguousRetryPreservesExactCommandAndNewActivityRequiresNewGesture() async throws {
        let transport = LifecycleTestTransport()
        var fail = true
        transport.handler = { endpoint, _ in
            if endpoint == "threadInbox/snapshot" { return self.baseline(version: 6) }
            if fail { throw URLError(.networkConnectionLost) }
            return self.result()
        }
        let service = MobileLifecycleService(transport: transport, now: { 1000 })
        service.synchronize(baseline())
        let command = try service.capture(id: "session-a", action: .pin)
        do { try await service.execute(command); XCTFail() } catch {}
        XCTAssertEqual(service.retryCommand, command)
        fail = false
        try await service.execute(try XCTUnwrap(service.retryCommand))
        XCTAssertEqual(transport.calls[0].1, transport.calls[1].1)
        let stale = try service.capture(id: "session-a", action: .unpin)
        // Fact-only observation changes do not increment lifecycle version.
        service.synchronize(baseline(version: 5, facts: .obj(["running": .bool(true)])))
        do { try await service.execute(stale); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertEqual(transport.calls.last?.0, "threadInbox/snapshot")
        XCTAssertNil(service.retryCommand)
    }
    func testConflictRefreshesButNeverResubmitsOrReauthorizes() async throws {
        let transport = LifecycleTestTransport()
        transport.handler = { endpoint, _ in
            if endpoint == "threadInbox/snapshot" { return self.baseline(version: 7) }
            throw NativeRPCError(message: "Concurrent mutation", code: "thread-inbox/conflict")
        }
        var identity = 0
        let service = MobileLifecycleService(transport: transport, uuid: { identity += 1; return "command-\(identity)" })
        service.synchronize(baseline())
        let command = try service.capture(id: "session-a", action: .settle)
        do { try await service.execute(command); XCTFail() } catch {}
        XCTAssertEqual(transport.calls.map { $0.0 }, ["threadInbox/apply", "threadInbox/snapshot"])
        XCTAssertNil(service.retryCommand)
        let next = try service.capture(id: "session-a", action: .settle)
        XCTAssertNotEqual(next.commandId, command.commandId)
        XCTAssertEqual(next.versions["session-a"], 7)
    }
    func testDeniedNeverConfiguresElevatesOrRetries() async throws {
        let transport = LifecycleTestTransport()
        transport.handler = { _, _ in throw NativeRPCError(message: "Remote access denied", code: "remote-access/denied") }
        let service = MobileLifecycleService(transport: transport)
        service.synchronize(baseline())
        do { try await service.execute(service.capture(id: "session-a", action: .pin)); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("not authorized")) }
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertNil(service.retryCommand)
    }
    func testHostUndoTokenAndExpiryAndVersionsAreAuthoritative() async throws {
        let transport = LifecycleTestTransport()
        var now = 1000.0
        transport.handler = { endpoint, _ in endpoint == "threadInbox/undo" ? self.result(6, token: nil) : self.result() }
        let service = MobileLifecycleService(transport: transport, now: { now })
        service.synchronize(baseline())
        try await service.execute(service.capture(id: "session-a", action: .pin))
        XCTAssertTrue(service.canUndo)
        try await service.undo()
        XCTAssertEqual(transport.calls.last?.1, .obj(["args": .obj(["request": .obj(["token": .text("host-token")])])]))
        XCTAssertFalse(service.canUndo)
        service.synchronize(baseline(version: 6))
        transport.handler = { _, _ in self.result(7, expiry: 6000) }
        try await service.execute(service.capture(id: "session-a", action: .pin))
        now = 6000
        XCTAssertFalse(service.canUndo)
        let count = transport.calls.count
        do { try await service.undo(); XCTFail() } catch {}
        XCTAssertEqual(transport.calls.count, count)
    }
    func testNoAutomaticActivationVisitWakeOrMutationOnInitializationAndSnapshot() async throws {
        let transport = LifecycleTestTransport()
        transport.handler = { _, _ in self.baseline(active: false) }
        let service = MobileLifecycleService(transport: transport)
        service.synchronize(baseline(active: false))
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertThrowsError(try service.capture(id: "session-a", action: .pin))
        _ = try await service.refresh()
        XCTAssertEqual(transport.calls.map { $0.0 }, ["threadInbox/snapshot"])
    }
    func testFixtureLifecycleMutatesReplicaWithoutAnyTransportAndHasRealUndo() async throws {
        let transport = LifecycleTestTransport()
        let service = MobileLifecycleService(transport: transport, fixtureSnapshot: baseline(), now: { 1000 })
        var merged = InboxReplica(); _ = merged.apply(baseline())
        service.onMerge = { merged.apply($0) }
        for (action, arguments) in [(MobileLifecycleAction.pin, JSONValue.obj([:])), (.snooze, .obj(["until": .number(4000)])), (.wake, .obj([:])), (.autoSettle, .obj(["enabled": .bool(false)])), (.markUnread, .obj([:]))] {
            try await service.execute(service.capture(id: "session-a", action: action, arguments: arguments))
        }
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(merged.threads, service.replica.threads)
        XCTAssertEqual(merged.threads["session-a"]?["lastVisitedAt"].number, 899)
        XCTAssertEqual(merged.threads["session-a"]?["autoSettleDisabled"].bool, true)
        try await service.execute(service.capture(id: "session-a", action: .settle))
        XCTAssertEqual(service.replica.threads["session-a"]?["settledOverride"].string, "settled")
        try await service.undo()
        XCTAssertNil(service.replica.threads["session-a"]?["settledOverride"].string)
    }
    func testFixtureBusySettleAndSnoozeAdmissionAndPastTimeFailWithoutGateway() async throws {
        let transport = LifecycleTestTransport()
        let service = MobileLifecycleService(transport: transport, fixtureSnapshot: baseline(facts: .obj(["running": .bool(true), "queuedHuman": .bool(true)])), now: { 1000 })
        XCTAssertThrowsError(try service.capture(id: "session-a", action: .snooze, arguments: .obj(["until": .number(999)])))
        for action in [MobileLifecycleAction.settle, .snooze] {
            do { try await service.execute(service.capture(id: "session-a", action: action, arguments: .obj(["until": .number(2000)]))); XCTFail() } catch {}
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }
    func testRenameConversationForkAndArchiveNeverAliasDeleteOrRepositoryFork() async throws {
        let transport = LifecycleTestTransport()
        transport.handler = { endpoint, _ in
            switch endpoint {
            case "session/rename": return .obj(["title": .text("Renamed"), "seq": .number(2)])
            case "session/fork": return .obj(["sessionId": .text("forked")])
            default: return .obj(["archivedSessionIds": .array([.text("captured-session")])])
            }
        }
        let service = MobileLifecycleService(transport: transport)
        _ = try await service.rename(sessionId: "captured-session", title: "Renamed")
        _ = try await service.fork(sessionId: "captured-session")
        _ = try await service.archive(sessionId: "captured-session")
        XCTAssertEqual(transport.calls.map { $0.0 }, ["session/rename", "session/fork", "workspace/archiveSession"])
        XCTAssertEqual(transport.calls[1].1["args"]["request"], .obj(["sessionId": .text("captured-session")]))
        XCTAssertEqual(transport.calls[2].1["args"]["request"], .obj(["sessionId": .text("captured-session"), "stopActivity": .bool(false)]))
    }
    func testConfigureAndPreviewExactWireOnlyAfterExplicitCalls() async throws {
        let transport = LifecycleTestTransport()
        transport.handler = { endpoint, _ in
            if endpoint == "threadInbox/preview" { return .obj(["autoSettle": .number(2), "total": .number(5), "days": .null]) }
            return self.baseline()
        }
        let service = MobileLifecycleService(transport: transport)
        let preview = try await service.preview()
        XCTAssertEqual(preview, MobileLifecyclePreview(autoSettle: 2, total: 5, days: nil))
        XCTAssertEqual(transport.calls[0].1, .obj(["args": .obj(["request": .obj([:])])]))
        try await service.configure(MobileLifecycleSettingsPatch(activated: true, autoSettleAfterDays: .some(nil)))
        XCTAssertEqual(transport.calls[1].1, .obj(["args": .obj(["request": .obj(["activated": .bool(true), "autoSettleAfterDays": .null])])]))
    }
    func testWrongEpochRequiresFullSnapshotAndDoesNotMergeForeignDelta() async throws {
        let transport = LifecycleTestTransport()
        transport.handler = { endpoint, _ in endpoint == "threadInbox/snapshot" ? self.baseline(version: 1, epoch: "epoch-b") : self.result(epoch: "epoch-b") }
        let service = MobileLifecycleService(transport: transport)
        service.synchronize(baseline())
        do { try await service.execute(service.capture(id: "session-a", action: .pin)); XCTFail() } catch {}
        XCTAssertEqual(service.replica.epoch, "epoch-b")
        XCTAssertEqual(service.replica.threads["session-a"]?["version"].integer, 1)
        XCTAssertFalse(service.canUndo)
    }
    func testFractionalOrderMatchesHostAlphabetAndRejectsInvalidKeys() throws {
        XCTAssertEqual(try MobileLifecycleOrder.between(nil, nil), "n")
        XCTAssertEqual(try MobileLifecycleOrder.between("n", nil), "u")
        XCTAssertEqual(try MobileLifecycleOrder.between(nil, "n"), "h")
        XCTAssertEqual(try MobileLifecycleOrder.between("b", "c"), "bn")
        XCTAssertEqual(try MobileLifecycleOrder.between("ab", "ac"), "abn")
        for key in ["", "a", "123", "A", String(repeating: "b", count: 2049)] { XCTAssertThrowsError(try MobileLifecycleOrder.between(key, nil)) }
        XCTAssertThrowsError(try MobileLifecycleOrder.between("z", "b"))
    }
}

@MainActor private final class LifecycleTestTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var calls: [(String, JSONValue)] = []
    var handler: ((String, JSONValue) throws -> JSONValue)?
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        calls.append((endpoint, payload))
        return try handler?(endpoint, payload) ?? .null
    }
    func openStream() {}
    func sendFrame(_ value: JSONValue) async throws { XCTFail("No lifecycle stream writes") }
    func closeStream() {}
}
