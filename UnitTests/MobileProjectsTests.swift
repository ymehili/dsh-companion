import XCTest
@testable import DSHCompanion

@MainActor private final class ProjectTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var calls: [(String, JSONValue)] = []
    var reply: JSONValue = .null
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue { calls.append((endpoint, payload)); return reply }
    func openStream() {}
    func closeStream() {}
    func sendFrame(_ value: JSONValue) async throws { XCTFail("Project CRUD must not open model/terminal streams") }
}

final class MobileProjectsTests: XCTestCase {
    private func wire(_ id: String = "p1", title: String = "Project", path: String = "/synthetic/Project") -> JSONValue {
        .obj(["workspaceId": .text(id), "path": .text(path), "title": .text(title), "sessionIds": .array([.text("one")])])
    }
    @MainActor func testRegistrationUsesExactExistingDirectoryRequestAndAcceptsAlreadyRegistered() async throws {
        let transport = ProjectTransport(), service = MobileProjectsService(transport)
        transport.reply = .obj(["workspace": wire(), "created": .bool(false)])
        let project = try await service.create(path: "/synthetic/Project")
        XCTAssertEqual(project.id, "p1"); XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(transport.calls[0].0, "workspace/create")
        XCTAssertEqual(transport.calls[0].1, .obj(["args": .obj(["request": .obj(["path": .text("/synthetic/Project")])])]))
    }
    @MainActor func testRenameIsCapturedIDNotSelectedSessionAndCannotChangePath() async throws {
        let transport = ProjectTransport(), service = MobileProjectsService(transport), original = try MobileProject(wire())
        transport.reply = .obj(["workspace": wire(title: "New name")])
        let renamed = try await service.rename(original, title: " New name ")
        XCTAssertEqual(renamed.title, "New name")
        XCTAssertEqual(transport.calls[0].1["args"]["request"]["workspaceId"].string, "p1")
        transport.reply = .obj(["workspace": wire(title: "New name", path: "/synthetic/Other")])
        do { _ = try await service.rename(original, title: "New name"); XCTFail("A path-changing reply was admitted") } catch {}
    }
    @MainActor func testRemovalOnlyDeletesRegistrationNotFilesOrSessions() async throws {
        let transport = ProjectTransport(), service = MobileProjectsService(transport), project = try MobileProject(wire())
        transport.reply = .obj(["deleted": .bool(true)])
        try await service.remove(project)
        XCTAssertEqual(transport.calls.count, 1); XCTAssertEqual(transport.calls[0].0, "workspace/delete")
        XCTAssertEqual(transport.calls[0].1["args"]["request"], .obj(["workspaceId": .text("p1")]))
    }
    @MainActor func testProjectOrderExactMethodOptionalNeighborAndUniqueAcknowledgement() async throws {
        let transport = ProjectTransport(), service = MobileProjectsService(transport), project = try MobileProject(wire())
        transport.reply = .obj(["workspaceIds": .array([.text("p2"), .text("p1")])])
        let ordered = try await service.reorder(project, before: nil)
        XCTAssertEqual(ordered, ["p2", "p1"])
        XCTAssertEqual(transport.calls[0].0, "workspace/insertBefore")
        XCTAssertNil(transport.calls[0].1["args"]["request"].object?["beforeWorkspaceId"])
        _ = try await service.reorder(project, before: "p2")
        XCTAssertEqual(transport.calls[1].1["args"]["request"]["beforeWorkspaceId"].string, "p2")
        transport.reply = .obj(["workspaceIds": .array([.text("p1"), .text("p1")])])
        do { _ = try await service.reorder(project, before: nil); XCTFail("Duplicate order") } catch {}
    }
    @MainActor func testBadInputsNeverDispatch() async throws {
        let transport = ProjectTransport(), service = MobileProjectsService(transport), project = try MobileProject(wire())
        for path in ["", "relative", "https://bad.example/project", "/synthetic/\0bad"] {
            do { _ = try await service.create(path: path); XCTFail("Bad path admitted") } catch {}
        }
        do { _ = try await service.rename(project, title: "   "); XCTFail("Empty rename") } catch {}
        do { _ = try await service.reorder(project, before: project.id); XCTFail("Self order") } catch {}
        XCTAssertTrue(transport.calls.isEmpty)
    }
    func testWorkspaceReplicaPreservesAndValidatesAuthoritativeOrder() {
        var replica = WorkspaceReplica()
        replica.accept(.obj(["type": .text("baseline"), "value": .obj(["items": .array([wire(), wire("p2")]), "archivedSessionIds": .array([]), "pinnedSessionIds": .array([])])]))
        XCTAssertEqual(replica.order, ["p1", "p2"])
        replica.accept(.obj(["type": .text("order"), "workspaceIds": .array([.text("p2"), .text("p1")])]))
        XCTAssertEqual(replica.order, ["p2", "p1"])
        replica.accept(.obj(["type": .text("order"), "workspaceIds": .array([.text("escape")])]))
        XCTAssertEqual(replica.order, ["p2", "p1"])
        replica.accept(.obj(["type": .text("remove"), "workspaceId": .text("p1")]))
        XCTAssertEqual(replica.order, ["p2"])
        replica.accept(.obj(["type": .text("replace"), "value": .obj(["items": .array([wire("p3")]), "archivedSessionIds": .array([]), "pinnedSessionIds": .array([])])]))
        XCTAssertEqual(replica.order, ["p3"]); XCTAssertNil(replica.items["p2"])
    }
    @MainActor func testSyntheticProjectLifecycleNeverNeedsTransport() async throws {
        let original = try MobileProject(wire()), fixture = MobileProjectsFixture([original])
        let created = try await fixture.create(path: "/synthetic/New")
        let renamed = try await fixture.rename(created, title: "Renamed")
        XCTAssertEqual(renamed.title, "Renamed")
        let ordered = try await fixture.reorder(renamed, before: original.id)
        XCTAssertEqual(ordered, [renamed.id, original.id])
        try await fixture.remove(renamed)
        do { _ = try await fixture.rename(renamed, title: "Gone"); XCTFail("Removed registration remained editable") } catch {}
    }
    func testProjectModelRejectsForgedMembershipAndMalformedPaths() {
        XCTAssertThrowsError(try MobileProject(.obj(["workspaceId": .text("p"), "path": .text("relative"), "title": .text("Bad"), "sessionIds": .array([])])))
        var value = wire().object!; value["sessionIds"] = .array([.text("one"), .text("one")])
        XCTAssertThrowsError(try MobileProject(.obj(value)))
    }
}
