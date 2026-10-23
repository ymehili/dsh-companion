import XCTest
@testable import DSHCompanion

@MainActor final class MobileRepositoryTests: XCTestCase {
    private func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    private func fixture() -> MobileRepositoryFixtureService { .init(sessionId: "repo-session") }
    func testExactReadEnvelopesAndNoHiddenMutation() async throws {
        let fixture = fixture(); let snapshot = try await fixture.status()
        let fake = MobileRepositoryTestTransport()
        fake.response = try json(snapshot)
        let service = MobileRepositoryService(sessionId: snapshot.sessionId, transport: fake)
        _ = try await service.status()
        XCTAssertEqual(fake.calls.first?.0, "mobileRepository/status")
        XCTAssertEqual(fake.calls.first?.1, .obj(["args": .obj(["request": .obj(["sessionId": .text(snapshot.sessionId)])])]))
        let file = snapshot.files[0]
        fake.response = try json(await fixture.diff(snapshot: snapshot, file: file, staged: false))
        _ = try await service.diff(snapshot: snapshot, file: file, staged: false)
        XCTAssertEqual(fake.calls.last?.0, "mobileRepository/diff")
        XCTAssertEqual(fake.calls.last?.1["args"]["request"], .obj(["sessionId": .text(snapshot.sessionId), "version": .text(snapshot.version), "path": .text(file.path), "staged": .bool(false)]))
        fake.response = try json(await fixture.pulls(snapshot: snapshot, state: "open"))
        _ = try await service.pulls(snapshot: snapshot, state: "open")
        XCTAssertEqual(fake.calls.last?.1["args"]["request"], .obj(["sessionId": .text(snapshot.sessionId), "state": .text("open"), "limit": .number(100)]))
        fake.response = try json(await fixture.pull(snapshot: snapshot, number: 42))
        _ = try await service.pull(snapshot: snapshot, number: 42)
        XCTAssertEqual(fake.calls.last?.1["args"]["request"], .obj(["sessionId": .text(snapshot.sessionId), "number": .number(42)]))
        XCTAssertEqual(fake.calls.count, 4)
        XCTAssertFalse(fake.calls.contains { $0.0.hasSuffix("mutate") || $0.0.hasSuffix("Mutate") })
        XCTAssertEqual(fake.resourceCalls, 0)
    }
    func testWrongSessionFileVersionAndSourcePathFailClosed() async throws {
        let fixture = fixture(); let snapshot = try await fixture.status(); let fake = MobileRepositoryTestTransport()
        fake.response = try json(snapshot)
        let wrong = MobileRepositoryService(sessionId: "other-session", transport: fake)
        do { _ = try await wrong.status(); XCTFail() } catch { XCTAssertEqual(error as? MobileRepositoryError, .scope) }
        fake.calls = []
        do { _ = try await wrong.diff(snapshot: snapshot, file: snapshot.files[0], staged: false); XCTFail() } catch {}
        XCTAssertTrue(fake.calls.isEmpty)
        let service = MobileRepositoryService(sessionId: snapshot.sessionId, transport: fake)
        let diff = try await fixture.diff(snapshot: snapshot, file: snapshot.files[0], staged: false)
        var raw = try json(diff).object!
        for (key, value) in [("path", JSONValue.text("unrelated.swift")), ("version", .text("stale")), ("sessionId", .text("other"))] {
            var bad = raw; bad[key] = value; fake.response = .obj(bad)
            do { _ = try await service.diff(snapshot: snapshot, file: snapshot.files[0], staged: false); XCTFail() } catch { XCTAssertEqual(error as? MobileRepositoryError, .scope) }
        }
        raw["binary"] = .number(0); fake.response = .obj(raw)
        do { _ = try await service.diff(snapshot: snapshot, file: snapshot.files[0], staged: false); XCTFail() } catch { XCTAssertEqual(error as? MobileRepositoryError, .invalid) }
    }
    func testStrictDTOCapabilitiesBoundsPathsAndURLs() async throws {
        let snapshot = try await fixture().status()
        var raw = try json(snapshot).object!
        var caps = raw["capabilities"]!.object!; caps["writes"] = .number(1); raw["capabilities"] = .obj(caps)
        XCTAssertThrowsError(try MobileRepositoryValidation.decode(MobileRepositoryStatus.self, .obj(raw)))
        for path in ["../secret", "/private/key", "a/../b", "a//b", "a\\b", "-x\n"] { XCTAssertThrowsError(try MobileRepositoryValidation.path(path)) }
        let repo = MobileRepositoryFixtureService.identity
        _ = try repo.url(number: 42, supplied: "https://github.com/t3-demo/native-fixture/pull/42")
        for url in ["http://github.com/t3-demo/native-fixture/pull/42", "javascript:alert(1)", "https://github.com.evil.test/t3-demo/native-fixture/pull/42", "https://github.com/other/repo/pull/42", "https://github.com/t3-demo/native-fixture/pull/43", "https://user:secret@github.com/t3-demo/native-fixture/pull/42", "https://github.com/t3-demo/native-fixture/pull/42?redirect=x", "file:///private/key"] { XCTAssertThrowsError(try repo.url(number: 42, supplied: url)) }
        raw = try json(snapshot).object!; raw["files"] = .array(Array(repeating: raw["files"]!.array[0], count: 2001))
        let oversized = try MobileRepositoryValidation.decode(MobileRepositoryStatus.self, .obj(raw))
        XCTAssertThrowsError(try oversized.validate(session: snapshot.sessionId))
    }
    func testImmutableUUIDVersionAndNoAutomaticReplay() async throws {
        let snapshot = try await fixture().status(); let fake = MobileRepositoryTestTransport()
        let service = MobileRepositoryService(sessionId: snapshot.sessionId, transport: fake)
        let uuid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let operation = try MobileRepositoryOperation(snapshot: snapshot, action: "commit", fields: ["message": .text("Keep this draft"), "runHooks": .bool(false)], requestId: uuid)
        XCTAssertEqual(operation.request["version"], .text(snapshot.version))
        XCTAssertEqual(operation.request["requestId"], .text(uuid.uuidString))
        fake.failure = NativeRPCError(message: "offline")
        do { _ = try await service.submit(operation); XCTFail() } catch { XCTAssertEqual(error as? MobileRepositoryError, .uncertain) }
        do { _ = try await service.submit(operation); XCTFail() } catch { XCTAssertEqual(error as? MobileRepositoryError, .uncertain) }
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].0, "mobileRepository/mutate")
        XCTAssertEqual(fake.calls[0].1, operation.envelope)
        XCTAssertEqual(fake.calls[0].1["args"]["request"]["message"], .text("Keep this draft"))
        XCTAssertEqual(operation.id, uuid)
    }
    func testPRScopeAndCASOnEveryRemoteAction() async throws {
        let fixture = fixture(); let snapshot = try await fixture.status(); let detail = try await fixture.pull(snapshot: snapshot, number: 42)
        for action in ["comment", "approve", "requestChanges", "reviewComment", "merge"] {
            let fields: [String: JSONValue] = action == "merge" ? ["method": .text("squash")] : ["body": .text("Reviewed")]
            let operation = try MobileRepositoryOperation(snapshot: snapshot, action: action, fields: fields, pull: detail)
            XCTAssertEqual(operation.endpoint, "mobileRepository/pullMutate")
            XCTAssertEqual(operation.request["number"], .number(42))
            XCTAssertEqual(operation.request["expectedHead"], .text(detail.item.head))
            XCTAssertEqual(operation.request["version"], .text(snapshot.version))
            XCTAssertEqual(operation.request["repository"], .obj(["owner": .text(detail.repository.owner), "name": .text(detail.repository.name)]))
        }
        let operation = try MobileRepositoryOperation(snapshot: snapshot, action: "create", fields: ["title": .text("New review"), "body": .text("Description"), "head": .text("feature/native-review"), "base": .text("main"), "draft": .bool(true)])
        XCTAssertEqual(operation.request["expectedHead"], .text(snapshot.head!))
        XCTAssertEqual(operation.request["draft"], .bool(true))
        XCTAssertThrowsError(try MobileRepositoryOperation(snapshot: snapshot, action: "comment", fields: ["body": .text("x")]))
        XCTAssertThrowsError(try MobileRepositoryOperation(snapshot: snapshot, action: "reset", fields: [:]))
        XCTAssertThrowsError(try MobileRepositoryOperation(snapshot: snapshot, action: "push", fields: ["force": .bool(true)]))
        XCTAssertThrowsError(try MobileRepositoryOperation(snapshot: snapshot, action: "removeWorktree", fields: ["path": .text("/unlisted/path")]))
    }
    func testControllerCancelRefreshNeverMutatesAndUncertainLocks() async throws {
        let fixture = fixture(); let snapshot = try await fixture.status(); let fake = MobileRepositoryTestTransport(); fake.response = try json(snapshot)
        let service = MobileRepositoryService(sessionId: snapshot.sessionId, transport: fake); let controller = MobileRepositoryController(service: service)
        await controller.refresh()
        controller.prepare(action: "push"); XCTAssertNotNil(controller.confirmation)
        controller.confirmation = nil
        XCTAssertEqual(fake.calls.count, 1)
        controller.prepare(action: "push"); fake.failure = CancellationError()
        let success = await controller.confirm()
        XCTAssertFalse(success); XCTAssertTrue(controller.writeLocked)
        controller.prepare(action: "push"); XCTAssertNil(controller.confirmation)
        XCTAssertEqual(fake.calls.count, 2)
        fake.failure = nil
        await controller.refresh()
        XCTAssertTrue(controller.writeLocked)
        XCTAssertEqual(fake.calls.count, 3)
    }
    func testGitLineRangeIdentityAndXMLEscaping() throws {
        let patch = try MobileRepositoryPatch("@@ -4,2 +4,3 @@\n same\n-old\n+new\n+extra\n")
        XCTAssertEqual(patch.lines[1].old, 4); XCTAssertEqual(patch.lines[1].new, 4)
        XCTAssertEqual(patch.lines[2].old, 5); XCTAssertNil(patch.lines[2].new)
        XCTAssertEqual(patch.lines[4].new, 6)
        XCTAssertThrowsError(try MobileRepositoryPatch("@@ -1,2 +1,2 @@\n short\n"))
        let target = MobileRepositoryReviewTarget(sessionId: "s<&\"'", version: "content<&\"'", ref: "head<&\"'", path: "a<&\"'.swift", staged: true, side: "new", start: 4, end: 6)
        let xml = try target.xml(comment: "</git_review_comment> & \"'")
        XCTAssertTrue(xml.contains("version=\"content&lt;&amp;&quot;&apos;\""))
        XCTAssertTrue(xml.contains("ref=\"head&lt;&amp;&quot;&apos;\""))
        XCTAssertTrue(xml.contains("line_start=\"4\" line_end=\"6\""))
        XCTAssertTrue(xml.contains("&lt;/git_review_comment&gt; &amp; &quot;&apos;"))
        XCTAssertFalse(xml.contains("seq=")); XCTAssertFalse(xml.contains("turn="))
    }
    func testDraftGoesToCapturedSessionWithoutPrompt() async throws {
        let fake = MobileRepositoryTestTransport(); let store = NativeStore(transport: fake, restoreCredentials: false)
        let a = SessionRow(.obj(["sessionId": .text("a")]))!; let b = SessionRow(.obj(["sessionId": .text("b")]))!
        store.sessions = [a, b]; store.selected = b
        let target = MobileRepositoryReviewTarget(sessionId: "a", version: "actual-content-version", ref: "HEAD-sha", path: "file.swift", staged: false, side: "old", start: 1, end: 3)
        XCTAssertTrue(store.appendReviewDraft(try target.xml(comment: "Review only"), for: target.sessionId))
        XCTAssertEqual(store.draft, ""); XCTAssertTrue(fake.calls.isEmpty)
        await store.choose(a)
        XCTAssertTrue(store.draft.contains("actual-content-version"))
        XCTAssertFalse(fake.calls.contains { $0.0.contains("prompt") || $0.0.contains("Mutate") || $0.0.contains("mutate") })
    }
    func testTypedFixtureHasTwoPullsBinaryDiffCommentsChecksAndNoTransport() async throws {
        let fixture = fixture(); let snapshot = try await fixture.status()
        try snapshot.validate(session: snapshot.sessionId)
        XCTAssertTrue(snapshot.files.contains(where: \.binary)); XCTAssertFalse(snapshot.branches.isEmpty); XCTAssertEqual(snapshot.worktrees.count, 2)
        let binary = snapshot.files.first(where: \.binary)!
        let diff = try await fixture.diff(snapshot: snapshot, file: binary, staged: true)
        XCTAssertTrue(diff.binary); XCTAssertTrue(diff.patch.isEmpty)
        let list = try await fixture.pulls(snapshot: snapshot, state: "open")
        XCTAssertEqual(list.items.count, 2)
        let detail = try await fixture.pull(snapshot: snapshot, number: 42)
        try detail.validate(snapshot: snapshot, number: 42)
        XCTAssertFalse(detail.comments.isEmpty); XCTAssertFalse(detail.checks.isEmpty); XCTAssertFalse(detail.files.isEmpty)
    }
    func testMissingCapabilityAndConflictCannotConstructWrites() async throws {
        let snapshot = try await fixture().status()
        for capability in ["git", "writes"] {
            var raw = try json(snapshot).object!; var caps = raw["capabilities"]!.object!
            caps[capability] = .bool(false); raw["capabilities"] = .obj(caps)
            let denied = try MobileRepositoryValidation.decode(MobileRepositoryStatus.self, .obj(raw))
            XCTAssertThrowsError(try MobileRepositoryOperation(snapshot: denied, action: "push"))
        }
        var raw = try json(snapshot).object!; var files = raw["files"]!.array; var file = files[0].object!
        file["status"] = .text("conflict"); files[0] = .obj(file); raw["files"] = .array(files)
        let conflicted = try MobileRepositoryValidation.decode(MobileRepositoryStatus.self, .obj(raw))
        XCTAssertThrowsError(try MobileRepositoryOperation(snapshot: conflicted, action: "stage", fields: ["paths": .array([.text(snapshot.files[0].path)])]))
    }
    func testSyntheticStageUnstageCommitAndExplicitReturnedWorktree() async throws {
        let fixture = fixture(); var snapshot = try await fixture.status()
        let path = "Notes/New note.md"
        let staged = try await fixture.submit(MobileRepositoryOperation(snapshot: snapshot, action: "stage", fields: ["paths": .array([.text(path)])]))
        snapshot = staged.snapshot!
        XCTAssertTrue(snapshot.files.first(where: { $0.path == path })!.staged)
        let unstaged = try await fixture.submit(MobileRepositoryOperation(snapshot: snapshot, action: "unstage", fields: ["paths": .array([.text(path)])]))
        snapshot = unstaged.snapshot!
        XCTAssertTrue(snapshot.files.first(where: { $0.path == path })!.unstaged)
        let committed = try await fixture.submit(MobileRepositoryOperation(snapshot: snapshot, action: "commit", fields: ["message": .text("Synthetic commit"), "runHooks": .bool(false)]))
        snapshot = committed.snapshot!
        XCTAssertFalse(snapshot.files.contains { $0.path == "Assets/Preview.png" })
        XCTAssertTrue(snapshot.files.contains { $0.path == path })
        let worktree = try await fixture.submit(MobileRepositoryOperation(snapshot: snapshot, action: "createWorktree", fields: ["name": .text("feature/new-review")]))
        XCTAssertEqual(worktree.worktreePath, "/synthetic/feature/new-review")
        XCTAssertTrue(worktree.snapshot!.worktrees.contains { $0.path == worktree.worktreePath })
        try worktree.snapshot!.validate(session: snapshot.sessionId)
    }
    func testCancelledReadsDoNotTurnIntoWrites() async throws {
        let fixture = fixture(); let fake = MobileRepositoryTestTransport(); fake.response = try json(await fixture.status())
        let service = MobileRepositoryService(sessionId: "repo-session", transport: fake)
        let task = Task { try await service.status() }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail("Expected cancellation") }
        XCTAssertFalse(fake.calls.contains { $0.0.hasSuffix("mutate") || $0.0.hasSuffix("Mutate") })
    }
}

@MainActor private final class MobileRepositoryTestTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var calls: [(String, JSONValue)] = []
    var resourceCalls = 0
    var response: JSONValue = .null
    var failure: Error?
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue { calls.append((endpoint, payload)); if let failure { throw failure }; return response }
    func resource(_ path: String, query: [String: String]) async throws -> JSONValue { resourceCalls += 1; throw MobileRepositoryError.unavailable }
    func openStream() {}
    func sendFrame(_ value: JSONValue) async throws {}
    func closeStream() {}
}
