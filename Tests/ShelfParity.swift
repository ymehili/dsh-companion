import Foundation

@main
struct ShelfParityProbe {
    static func main() async throws {
        let config = try JSONDecoder().decode(JSONValue.self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard let cookie = config["cookie"].string else { throw NativeRPCError(message: "Missing private probe input") }
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:19387/api/remote.mux")!)
        request.setValue("http://127.0.0.1:19387", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 16 * 1024 * 1024; socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        let message: JSONValue = .obj(["type": .text("open"), "streamId": .text("workspace-parity-probe"), "endpoint": .text("workspace/follow"), "payload": .obj(["args": .obj([:])])])
        try await socket.send(.string(String(data: JSONEncoder().encode(message), encoding: .utf8)!))
        let frame = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                let response = try await socket.receive()
                let data: Data
                switch response { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: throw NativeRPCError(message: "Unknown workspace frame") }
                return try JSONDecoder().decode(JSONValue.self, from: data)
            }
            group.addTask { try await Task.sleep(for: .seconds(15)); socket.cancel(with: .goingAway, reason: nil); throw NativeRPCError(message: "Workspace baseline timed out") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard frame["type"].string == "item", frame["value"]["type"].string == "baseline" else { throw NativeRPCError(message: "No workspace baseline") }
        var workspace = WorkspaceReplica(); workspace.accept(frame["value"])
        var native: [String: JSONValue] = [:]
        for wire in config["rows"].array {
            guard let row = SessionRow(wire), workspace.visible(row, current: nil) else { continue }
            let projection = wire["projections"]["values"]
            let pending = projection["userQuestions"]["active"].array.map { q in JSONValue.obj(["id": q["callId"], "kind": .text(q["questions"].array.contains(where: { $0["intent"]["kind"].string == "plan-review" }) ? "plan-review" : "question")]) }
            let children = Set(projection["subagentCatalog"].array.compactMap { $0["id"].string })
            let background = config["rows"].array.contains { children.contains($0["sessionId"].string ?? "") && $0["running"].bool == true }
            let record = DesktopInbox.resolvedRecord(config["inbox"]["threads"][row.id], row: row, pinned: workspace.pinned.contains(row.id), backgroundWork: background, pending: pending)
            let shelf = DesktopInbox.section(record: record, running: row.running, now: config["now"].number ?? 0)
            if shelf == "hidden" { continue }
            var ids = native[shelf]?.array ?? []; ids.append(.text(row.id)); native[shelf] = .array(ids)
        }
        // Private IPC to parent probe, which compares IDs in memory and logs counts only.
        let output: JSONValue = .obj(["archived": .array(workspace.archived.sorted().map(JSONValue.text)), "pinned": .array(workspace.pinned.sorted().map(JSONValue.text)), "nativeMembership": .obj(native)])
        print(String(data: try JSONEncoder().encode(output), encoding: .utf8)!)
    }
}
