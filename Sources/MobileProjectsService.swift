import Foundation

struct MobileProject: Identifiable, Equatable {
    let id: String
    let path: String
    let title: String
    let sessions: [String]
    let wire: JSONValue
    init(_ value: JSONValue) throws {
        guard let id = value["workspaceId"].string, Self.identifier(id), let path = value["path"].string, Self.absolute(path),
              let title = value["title"].string, !title.isEmpty, title.utf8.count <= 4096,
              case .array(let entries) = value["sessionIds"], entries.count <= 100_000 else { throw NativeRPCError(message: "The Mac returned an invalid project registration.") }
        let sessions = entries.compactMap(\.string)
        guard sessions.count == entries.count, Set(sessions).count == sessions.count, sessions.allSatisfy(Self.identifier) else { throw NativeRPCError(message: "The Mac returned invalid project membership.") }
        self.id = id; self.path = path; self.title = title; self.sessions = sessions; wire = value
    }
    static func identifier(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    static func absolute(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 16_384 && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }
}

@MainActor protocol MobileProjectsServing {
    func create(path: String) async throws -> MobileProject
    func rename(_ project: MobileProject, title: String) async throws -> MobileProject
    func remove(_ project: MobileProject) async throws
    func reorder(_ project: MobileProject, before: String?) async throws -> [String]
}

@MainActor final class MobileProjectsService: MobileProjectsServing {
    private let transport: any NativeTransport
    init(_ transport: any NativeTransport) { self.transport = transport }
    private func call(_ method: String, _ request: [String: JSONValue]) async throws -> JSONValue {
        try await transport.rpc("workspace/" + method, .obj(["args": .obj(["request": .obj(request)])]))
    }
    func create(path: String) async throws -> MobileProject {
        guard MobileProject.absolute(path) else { throw NativeRPCError(message: "Enter an absolute existing directory path on your Mac.") }
        let value = try await call("create", ["path": .text(path)])
        guard value["created"].bool != nil else { throw NativeRPCError(message: "Project registration was not confirmed.") }
        return try MobileProject(value["workspace"])
    }
    func rename(_ project: MobileProject, title: String) async throws -> MobileProject {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 4096 else { throw NativeRPCError(message: "Enter a project name up to 4 KB.") }
        let value = try await call("rename", ["workspaceId": .text(project.id), "title": .text(title)])
        let next = try MobileProject(value["workspace"])
        guard next.id == project.id, next.path == project.path, next.title == title else { throw NativeRPCError(message: "The renamed project did not match this registration.") }
        return next
    }
    func remove(_ project: MobileProject) async throws {
        let value = try await call("delete", ["workspaceId": .text(project.id)])
        guard value["deleted"].bool == true else { throw NativeRPCError(message: "Project removal was not confirmed.") }
    }
    func reorder(_ project: MobileProject, before: String?) async throws -> [String] {
        guard before != project.id, before.map(MobileProject.identifier) ?? true else { throw NativeRPCError(message: "Choose a different project position.") }
        var args: [String: JSONValue] = ["workspaceId": .text(project.id)]
        if let before { args["beforeWorkspaceId"] = .text(before) }
        let value = try await call("insertBefore", args)
        guard case .array(let rows) = value["workspaceIds"] else { throw NativeRPCError(message: "Project order was not confirmed.") }
        let ids = rows.compactMap(\.string)
        guard ids.count == rows.count, Set(ids).count == ids.count, ids.contains(project.id), ids.allSatisfy(MobileProject.identifier) else { throw NativeRPCError(message: "The Mac returned an invalid project order.") }
        return ids
    }
}

/// Explicitly synthetic state, never a fallback for a failed live request.
@MainActor final class MobileProjectsFixture: MobileProjectsServing {
    private var rows: [String: MobileProject]
    private var order: [String]
    init(_ projects: [MobileProject]) { rows = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) }); order = projects.map(\.id) }
    func create(path: String) async throws -> MobileProject {
        guard MobileProject.absolute(path) else { throw NativeRPCError(message: "Enter an absolute synthetic Mac path.") }
        if let row = rows.values.first(where: { $0.path == path }) { return row }
        let row = try MobileProject(.obj(["workspaceId": .text("fixture-project-" + UUID().uuidString), "path": .text(path), "title": .text(URL(fileURLWithPath: path).lastPathComponent), "sessionIds": .array([])]))
        rows[row.id] = row; order.append(row.id); return row
    }
    func rename(_ project: MobileProject, title: String) async throws -> MobileProject {
        guard rows[project.id] == project, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeRPCError(message: "The synthetic project changed.") }
        var fields = project.wire.object!; fields["title"] = .text(title.trimmingCharacters(in: .whitespacesAndNewlines))
        let row = try MobileProject(.obj(fields)); rows[row.id] = row; return row
    }
    func remove(_ project: MobileProject) async throws { guard rows[project.id] == project else { throw NativeRPCError(message: "The synthetic project changed.") }; rows[project.id] = nil; order.removeAll { $0 == project.id } }
    func reorder(_ project: MobileProject, before: String?) async throws -> [String] {
        guard rows[project.id] == project, before != project.id, before == nil || rows[before!] != nil else { throw NativeRPCError(message: "The synthetic project order changed.") }
        order.removeAll { $0 == project.id }; order.insert(project.id, at: before.flatMap { order.firstIndex(of: $0) } ?? order.count); return order
    }
}
