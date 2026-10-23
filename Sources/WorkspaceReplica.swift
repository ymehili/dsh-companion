import Foundation

/// Exact workspace/follow read model used by the Mac's session visibility rules.
struct WorkspaceReplica {
    private(set) var ready = false
    private(set) var items: [String: JSONValue] = [:]
    private(set) var order: [String] = []
    private(set) var archived: Set<String> = []
    private(set) var pinned: Set<String> = []
    mutating func accept(_ frame: JSONValue) {
        switch frame["type"].string {
        case "baseline", "replace":
            guard case .array(let rows) = frame["value"]["items"], case .array = frame["value"]["archivedSessionIds"], case .array = frame["value"]["pinnedSessionIds"] else { return }
            let ids = rows.compactMap { $0["workspaceId"].string }
            guard ids.count == rows.count, Set(ids).count == ids.count else { return }
            items = rows.reduce(into: [:]) { result, item in if let id = item["workspaceId"].string { result[id] = item } }
            order = ids
            archived = Set(frame["value"]["archivedSessionIds"].array.compactMap(\.string))
            pinned = Set(frame["value"]["pinnedSessionIds"].array.compactMap(\.string))
            ready = true
        case "upsert":
            if let id = frame["workspace"]["workspaceId"].string { items[id] = frame["workspace"]; if !order.contains(id) { order.append(id) } }
        case "remove": if let id = frame["workspaceId"].string { items.removeValue(forKey: id); order.removeAll { $0 == id } }
        case "order":
            guard case .array(let values) = frame["workspaceIds"] else { return }
            let ids = values.compactMap(\.string)
            guard ids.count == values.count, Set(ids).count == ids.count, ids.allSatisfy({ items[$0] != nil }) else { return }
            order = ids + order.filter { !ids.contains($0) }
        case "archived": archived = Set(frame["archivedSessionIds"].array.compactMap(\.string))
        case "pinned": pinned = Set(frame["pinnedSessionIds"].array.compactMap(\.string))
        default: break
        }
    }
    func visible(_ row: SessionRow, current: String?) -> Bool {
        !row.isSubagent && (!row.blank || row.id == current) && !archived.contains(row.id)
    }
    func title(for session: String, cwd: String) -> String {
        if let workspace = items.values.first(where: { $0["sessionIds"].array.contains(.text(session)) }), let title = workspace["title"].string { return title }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        return folder.isEmpty || folder == "default-workspace" ? "Default workspace" : folder
    }
}
