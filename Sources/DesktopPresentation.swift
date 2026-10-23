import Foundation

/// The same shelves as the installed Mac's thread-inbox presentation.
/// Facts/lifecycle come from threadInbox/snapshot, never inferred from thread age.
enum DesktopInbox {
    static func resolvedRecord(_ raw: JSONValue, row: SessionRow, pinned: Bool = false, backgroundWork: Bool = false, pending: [JSONValue] = []) -> JSONValue {
        var record = raw.object ?? [:]
        if raw.object == nil, pinned { record["pinnedAt"] = .number(1) }
        var facts = record["facts"]?.object ?? ["id": .text(row.id), "createdAt": .number(row.updatedAt), "lastSendAt": .number(row.updatedAt), "running": .bool(row.running), "backgroundWork": .bool(backgroundWork), "pending": .array([])]
        var requests = facts["pending"]?.array ?? []
        for request in pending where !requests.contains(where: { $0["id"] == request["id"] || $0["kind"] == request["kind"] }) { requests.append(request) }
        facts["pending"] = .array(requests)
        record["facts"] = .obj(facts)
        return .obj(record)
    }
    static func section(record: JSONValue, running: Bool, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        let facts = record["facts"]
        if facts["archived"].bool == true || facts["deleted"].bool == true || facts["subagent"].bool == true { return "hidden" }
        let pending = facts["pending"].array
        let snoozedAt = record["snoozedAt"].number ?? .infinity
        let raised = !pending.isEmpty || (facts["failedAt"].number ?? -.infinity) > snoozedAt || (facts["completedAt"].number ?? -.infinity) > snoozedAt
        if let until = record["snoozedUntil"].number, until > now, !raised { return "snoozed" }
        if record["settledOverride"].string == "settled" { return "settled" }
        if record["pinnedAt"].number != nil { return "pinned" }
        let active = facts.object == nil ? running : (facts["running"].bool ?? false)
        let working = pending.isEmpty && (facts["failedAt"].number ?? 0) == 0 && (active || facts["backgroundWork"].bool == true)
        return working ? "working" : "inbox"
    }
    static func status(record: JSONValue, running: Bool) -> String? {
        let facts = record["facts"]
        if let first = facts["pending"].array.first { return first["kind"].string == "approval" ? "Approval" : "Input" }
        if (facts.object == nil ? running : (facts["running"].bool ?? false)) || facts["backgroundWork"].bool == true { return "Working" }
        if facts["queuedHuman"].bool == true || facts["queuedWork"].bool == true { return "Waiting" }
        if let failed = facts["failedAt"].number, failed != 0 { return facts["errorCode"].string == "USAGE_LIMIT" ? "Limited" : "Failed" }
        if let until = record["snoozedUntil"].number, section(record: record, running: running) != "settled" {
            let events = [facts["attentionAt"].number, facts["failedAt"].number, facts["completedAt"].number].compactMap { $0 }.filter { $0 > (record["snoozedAt"].number ?? -.infinity) }
            let raised = (facts["failedAt"].number ?? -.infinity) > (record["snoozedAt"].number ?? .infinity) || (facts["completedAt"].number ?? -.infinity) > (record["snoozedAt"].number ?? .infinity)
            let wake = raised ? (events.min() ?? record["snoozedAt"].number) : (until <= Date().timeIntervalSince1970 * 1000 ? until : nil)
            if let wake, (record["lastVisitedAt"].number ?? -.infinity) < wake { return "Woke" }
        }
        if let completed = facts["completedAt"].number, completed >= (facts["lastSendAt"].number ?? facts["createdAt"].number ?? 0) { return "Done" }
        return nil
    }
}

struct NativeModelChoice: Identifiable, Hashable {
    let provider: String
    let providerName: String
    let model: String
    let name: String
    let efforts: [NativeReasoningChoice]
    let defaultEffort: String?
    var id: String { provider + "/" + model }
    static func catalog(_ result: JSONValue) -> [NativeModelChoice] {
        result["groups"].array.flatMap { group -> [NativeModelChoice] in
            guard let provider = group["id"].string else { return [] }
            return group["models"].array.compactMap { model in
                guard let id = model["id"].string else { return nil }
                return NativeModelChoice(provider: provider, providerName: group["name"].string ?? provider, model: id, name: model["name"].string ?? id, efforts: model["reasoning"]["efforts"].array.compactMap { item in
                    guard let id = item["id"].string else { return nil }
                    return NativeReasoningChoice(id: id, name: item["name"].string ?? id)
                }, defaultEffort: model["reasoning"]["defaultEffort"].string)
            }
        }
    }
}
struct NativeReasoningChoice: Identifiable, Hashable { let id: String; let name: String }

extension DesktopInbox {
    static func precedes(_ a: JSONValue, idA: String, _ b: JSONValue, idB: String, shelf: String) -> Bool {
        if shelf == "pinned" {
            let keyA = a["pinOrderKey"].string, keyB = b["pinOrderKey"].string
            if let keyA, let keyB { return keyA == keyB ? idA < idB : keyA < keyB }
            if keyA != nil && keyB == nil { return true }
            if keyA == nil && keyB != nil { return false }
        }
        func order(_ record: JSONValue) -> Double {
            let facts = record["facts"]
            switch shelf {
            case "inbox": return [record["returnedAt"].number, record["unsettledAt"].number, facts["requestedAt"].number, facts["completedAt"].number, facts["lastSendAt"].number, facts["createdAt"].number].compactMap { $0 }.max() ?? 0
            case "snoozed": return record["snoozedUntil"].number ?? 0
            case "settled": return record["settledAt"].number ?? 0
            default: return facts["lastSendAt"].number ?? facts["createdAt"].number ?? 0
            }
        }
        let left = order(a), right = order(b)
        if left != right { return shelf == "snoozed" ? left < right : left > right }
        return idA < idB
    }
}
