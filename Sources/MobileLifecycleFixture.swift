import Foundation

/// Explicit synthetic backend. It owns no transport, file, model, agent or host capability.
@MainActor
final class MobileLifecycleFixture {
    private var snapshot: JSONValue
    private let now: () -> Double
    private var receipts: [String: (JSONValue, JSONValue)] = [:]
    private var undos: [String: (before: [String: JSONValue], versions: [String: Int], expiry: Double)] = [:]
    private var archived: [String] = []
    init(snapshot: JSONValue, now: @escaping () -> Double) { self.snapshot = snapshot; self.now = now }
    private func fail(_ message: String) -> NativeRPCError { NativeRPCError(message: message) }
    func rpc(_ endpoint: String, _ payload: JSONValue) throws -> JSONValue {
        let request = payload["args"]["request"]
        switch endpoint {
        case "threadInbox/snapshot": return snapshot
        case "threadInbox/preview":
            return .obj(["autoSettle": .number(0), "total": .number(Double(snapshot["threads"].object?.count ?? 0)), "days": snapshot["settings"]["autoSettleAfterDays"]])
        case "threadInbox/configure":
            var fields = snapshot.object ?? [:], settings = snapshot["settings"].object ?? [:]
            for (key, value) in request.object ?? [:] { settings[key] = value }
            fields["settings"] = .obj(settings); snapshot = .obj(fields)
            return commit([:])
        case "threadInbox/apply": return try apply(request)
        case "threadInbox/undo":
            guard let token = request["token"].string, let entry = undos[token], entry.expiry > now() else { throw fail("The five-second Undo window has ended.") }
            var restored: [String: JSONValue] = [:]
            for (id, before) in entry.before {
                guard snapshot["threads"][id]["version"].integer == entry.versions[id] else { throw fail("Thread changed before Undo.") }
                var record = before.object ?? [:]; record["version"] = .number(Double((entry.versions[id] ?? 0) + 1)); restored[id] = .obj(record)
            }
            undos[token] = nil
            return commit(restored)
        case "session/rename": return .obj(["title": request["title"], "seq": .number(0)])
        case "session/fork": return .obj(["sessionId": .text("fixture-fork-" + UUID().uuidString)])
        case "workspace/archiveSession":
            let id = request["sessionId"].string ?? ""
            guard snapshot["threads"][id]["facts"]["running"].bool != true else { throw fail("This thread is working. Interrupt it first, then try again.") }
            if !archived.contains(id) { archived.append(id) }
            return .obj(["archivedSessionIds": .array(archived.map(JSONValue.text))])
        default: throw fail("This operation is not part of the lifecycle fixture.")
        }
    }
    private func commit(_ changed: [String: JSONValue], extras: [String: JSONValue] = [:]) -> JSONValue {
        var fields = snapshot.object ?? [:], threads = snapshot["threads"].object ?? [:]
        for (id, record) in changed { threads[id] = record }
        let revision = (snapshot["revision"].integer ?? 0) + 1
        fields["threads"] = .obj(threads); fields["revision"] = .number(Double(revision)); snapshot = .obj(fields)
        var result: [String: JSONValue] = ["epoch": snapshot["epoch"], "revision": .number(Double(revision)), "threads": .obj(changed), "settings": snapshot["settings"]]
        result.merge(extras) { _, new in new }
        return .obj(result)
    }
    private func apply(_ request: JSONValue) throws -> JSONValue {
        guard let commandId = request["commandId"].string, request["epoch"] == snapshot["epoch"] else { throw fail("Host restarted; reconnect before changing a thread.") }
        if let previous = receipts[commandId] {
            guard previous.0 == request else { throw fail("Command identity conflict.") }
            return previous.1
        }
        guard snapshot["settings"]["activated"].bool == true else { throw fail("Turn on Thread Inbox mode first.") }
        guard let action = MobileLifecycleAction(rawValue: request["action"].string ?? "") else { throw fail("Unknown action.") }
        let ids = request["ids"].array.compactMap { $0.string }
        var changed: [String: JSONValue] = [:], before: [String: JSONValue] = [:], versions: [String: Int] = [:]
        for id in ids {
            let old = snapshot["threads"][id]
            guard let version = old["version"].integer, request["versions"][id].integer == version else { throw fail("Thread changed on another client.") }
            let facts = old["facts"]
            guard facts["archived"].bool != true, facts["subagent"].bool != true else { throw fail("Manage the visible parent thread instead.") }
            var record = old.object ?? [:]
            func clear(_ keys: [String]) { for key in keys { record.removeValue(forKey: key) } }
            switch action {
            case .settle:
                guard facts["running"].bool != true, facts["queuedHuman"].bool != true, facts["blockingRuntime"].bool != true, facts["pending"].array.isEmpty, (facts["scheduled"].number ?? 0) == 0 else { throw fail("Stop active work and answer open requests before settling.") }
                record["settledOverride"] = .text("settled"); record["settledAt"] = .number(now())
                clear(["unsettledAt", "pinnedAt", "pinOrderKey", "activeOrderKey", "snoozedAt", "snoozedUntil"])
            case .unsettle:
                record["settledOverride"] = .text("active"); record["unsettledAt"] = .number(now()); clear(["settledAt"])
            case .pin:
                if record["settledOverride"]?.string == "settled" { record["settledOverride"] = .text("active"); clear(["settledAt"]); record["unsettledAt"] = .number(now()) }
                record["pinnedAt"] = record["pinnedAt"] ?? .number(now()); clear(["snoozedAt", "snoozedUntil"])
                if let key = request["args"]["orderKey"].string { _ = try MobileLifecycleOrder.between(key, nil); record["pinOrderKey"] = .text(key) }
            case .unpin: clear(["pinnedAt", "pinOrderKey"])
            case .wake: clear(["snoozedAt", "snoozedUntil"])
            case .snooze:
                guard facts["pending"].array.isEmpty, facts["queuedHuman"].bool != true, facts["queuedWork"].bool != true else { throw fail("Threads with pending requests or queued work cannot be snoozed.") }
                guard let until = request["args"]["until"].number, until.isFinite, until > now() else { throw fail("Choose a future wake time.") }
                record["snoozedAt"] = .number(now()); record["snoozedUntil"] = .number(until)
            case .markUnread:
                guard let completed = facts["completedAt"].number else { throw fail("No completed run to mark unread.") }
                record["lastVisitedAt"] = .number(completed - 1)
            case .autoSettle:
                guard let enabled = request["args"]["enabled"].bool else { throw fail("Choose enabled or disabled.") }
                record["autoSettleDisabled"] = .bool(!enabled)
            case .reorderPin:
                guard record["pinnedAt"] != nil, let key = request["args"]["orderKey"].string else { throw fail("This thread is no longer pinned.") }
                _ = try MobileLifecycleOrder.between(key, nil); record["pinOrderKey"] = .text(key)
            }
            record["version"] = .number(Double(version + 1)); before[id] = old; versions[id] = version + 1; changed[id] = .obj(record)
        }
        let token = action == .markUnread ? nil : UUID().uuidString
        let expiry = now() + 5000
        if let token { undos[token] = (before, versions, expiry) }
        let result = commit(changed, extras: ["undoToken": token.map(JSONValue.text) ?? .null, "undoExpiresAt": token == nil ? .null : .number(expiry)])
        receipts[commandId] = (request, result)
        return result
    }
}
