import Foundation
import Observation

/// Immutable authorization captured at the user's gesture, never reconstructed during retry.
struct MobileLifecycleCommand: Equatable {
    let commandId: String
    let epoch: String
    let ids: [String]
    let versions: [String: Int]
    let records: [String: JSONValue]
    let action: MobileLifecycleAction
    let arguments: JSONValue
    var request: JSONValue {
        .obj(["commandId": .text(commandId), "epoch": .text(epoch), "ids": .array(ids.map(JSONValue.text)),
              "versions": .obj(versions.mapValues { .number(Double($0)) }), "action": .text(action.rawValue), "args": arguments])
    }
}

enum MobileLifecycleAction: String, CaseIterable {
    case settle, unsettle, wake, pin, unpin, snooze
    case markUnread = "mark-unread", autoSettle = "auto-settle", reorderPin = "reorder-pin"
}

struct MobileLifecycleUndo {
    let token: String
    let epoch: String
    let expiresAt: Double
    let versions: [String: Int]
}

struct MobileLifecyclePreview: Equatable {
    let autoSettle: Int
    let total: Int
    let days: Double?
}

struct MobileLifecycleSettingsPatch {
    var activated: Bool? = nil
    /// Outer nil means unchanged; inner nil means Never.
    var autoSettleAfterDays: Double?? = nil
    var json: JSONValue {
        var fields: [String: JSONValue] = [:]
        if let activated { fields["activated"] = .bool(activated) }
        if let days = autoSettleAfterDays { fields["autoSettleAfterDays"] = days.map(JSONValue.number) ?? .null }
        return .obj(fields)
    }
}

@MainActor @Observable
final class MobileLifecycleService {
    private let transport: any NativeTransport
    private let now: () -> Double
    private let uuid: () -> String
    private var fixture: MobileLifecycleFixture?
    private(set) var replica = InboxReplica()
    private(set) var undoOffer: MobileLifecycleUndo?
    private(set) var retryCommand: MobileLifecycleCommand?
    private(set) var busy = false
    var message: String?
    var onMerge: ((JSONValue) -> Bool)?
    var currentSnapshot: (() -> JSONValue)?

    init(transport: any NativeTransport, fixtureSnapshot: JSONValue? = nil,
         now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }, uuid: @escaping () -> String = { UUID().uuidString }) {
        self.transport = transport; self.now = now; self.uuid = uuid
        if let fixtureSnapshot {
            fixture = MobileLifecycleFixture(snapshot: fixtureSnapshot, now: now)
            _ = replica.apply(fixtureSnapshot)
        }
    }

    static func snapshot(epoch: String, revision: Int, activated: Bool, threads: [String: JSONValue]) -> JSONValue {
        .obj(["full": .bool(true), "epoch": .text(epoch), "revision": .number(Double(revision)),
              "settings": .obj(["activated": .bool(activated)]), "threads": .obj(threads)])
    }

    func synchronize(_ snapshot: JSONValue) { _ = replica.apply(snapshot) }
    private func readCurrent() { if let value = currentSnapshot?() { synchronize(value) } }
    private func call(_ endpoint: String, request: JSONValue? = nil) async throws -> JSONValue {
        let payload: JSONValue = .obj(["args": request.map { .obj(["request": $0]) } ?? .obj([:])])
        if let fixture { return try fixture.rpc(endpoint, payload) }
        return try await transport.rpc(endpoint, payload)
    }
    @discardableResult func refresh() async throws -> JSONValue {
        let value = try await call("threadInbox/snapshot")
        guard replica.apply(value) else { throw NativeRPCError(message: "The Mac returned an incompatible lifecycle snapshot.") }
        _ = onMerge?(value)
        return value
    }
    func capture(id: String, action: MobileLifecycleAction, arguments: JSONValue = .obj([:])) throws -> MobileLifecycleCommand {
        readCurrent()
        guard replica.activated, let epoch = replica.epoch else { throw NativeRPCError(message: "Thread Inbox is disabled. Enable it explicitly in Inbox settings first.") }
        guard !id.isEmpty, id.count <= 256, let record = replica.threads[id], let version = record["version"].integer else {
            throw NativeRPCError(message: "Sync this thread before changing it.")
        }
        if action == .snooze {
            guard let until = arguments["until"].number, until.isFinite, until > now() else { throw NativeRPCError(message: "Choose a future wake time.") }
        }
        return MobileLifecycleCommand(commandId: uuid(), epoch: epoch, ids: [id], versions: [id: version], records: [id: record], action: action, arguments: arguments)
    }
    func unchanged(_ command: MobileLifecycleCommand) -> Bool {
        readCurrent()
        return command.epoch == replica.epoch && command.ids.allSatisfy { replica.threads[$0] == command.records[$0] }
    }
    private func mergeCommand(_ result: JSONValue) async throws {
        readCurrent()
        guard result["epoch"].string == replica.epoch else {
            _ = try await refresh()
            throw NativeRPCError(message: "The Mac restarted. Review the refreshed thread and try the action again.")
        }
        var fields = result.object ?? [:]; fields["full"] = .bool(false)
        let delta = JSONValue.obj(fields)
        guard replica.apply(delta) else { _ = try await refresh(); return }
        _ = onMerge?(delta)
    }
    func execute(_ command: MobileLifecycleCommand) async throws {
        guard !busy else { throw NativeRPCError(message: "A thread action is already in progress.") }
        guard unchanged(command) else {
            retryCommand = nil
            _ = try await refresh()
            throw NativeRPCError(message: "Thread activity changed. Review the refreshed thread, then choose the action again.")
        }
        busy = true; retryCommand = nil; undoOffer = nil
        defer { busy = false }
        do {
            let result = try await call("threadInbox/apply", request: command.request)
            try await mergeCommand(result)
            if let token = result["undoToken"].string, let expiry = result["undoExpiresAt"].number, expiry > now() {
                let versions = (result["threads"].object ?? [:]).compactMapValues { $0["version"].integer }
                undoOffer = MobileLifecycleUndo(token: token, epoch: command.epoch, expiresAt: min(expiry, now() + 5000), versions: versions)
            }
        } catch {
            // Code is optional on older bridges; never elevate a denied principal or silently re-authorize CAS.
            let text = error.localizedDescription.lowercased()
            let code = (error as? NativeRPCError)?.code?.lowercased() ?? ""
            if code.contains("conflict") || text.contains("changed") || text.contains("restarted") || text.contains("conflict") {
                _ = try? await refresh()
                throw NativeRPCError(message: "Thread changed. Shelves refreshed; choose the action again to authorize a new command.")
            }
            if code.contains("denied") || text.contains("denied") || text.contains("not authorized") {
                throw NativeRPCError(message: "This connection is not authorized to change threads. No permissions were changed.")
            }
            // Only an ambiguous transport failure offers exact-command retry; business refusals do not.
            if error is URLError, unchanged(command) { retryCommand = command }
            throw error
        }
    }
    var canUndo: Bool {
        guard let offer = undoOffer, offer.expiresAt > now(), offer.epoch == replica.epoch else { return false }
        return offer.versions.allSatisfy { replica.threads[$0.key]?["version"].integer == $0.value }
    }
    func expireUndo() { if !canUndo { undoOffer = nil } }
    func undo() async throws {
        readCurrent()
        guard !busy, canUndo, let offer = undoOffer else { undoOffer = nil; throw NativeRPCError(message: "Undo expired or the thread changed.") }
        busy = true; undoOffer = nil
        defer { busy = false }
        do { let result = try await callUndoResult(offer); try await mergeCommand(result) }
        catch { _ = try? await refresh(); throw error }
    }
    private func callUndoResult(_ offer: MobileLifecycleUndo) async throws -> JSONValue {
        try await call("threadInbox/undo", request: .obj(["token": .text(offer.token)]))
    }
    func preview() async throws -> MobileLifecyclePreview {
        let value = try await call("threadInbox/preview", request: .obj([:]))
        guard let count = value["autoSettle"].integer, let total = value["total"].integer else { throw NativeRPCError(message: "Incompatible Inbox preview.") }
        return MobileLifecyclePreview(autoSettle: count, total: total, days: value["days"].number)
    }
    func configure(_ patch: MobileLifecycleSettingsPatch) async throws {
        _ = try await call("threadInbox/configure", request: patch.json)
        _ = try await refresh()
    }
    func rename(sessionId: String, title: String) async throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NativeRPCError(message: "Enter a thread title.") }
        let value = try await call("session/rename", request: .obj(["sessionId": .text(sessionId), "title": .text(title)]))
        guard let renamed = value["title"].string else { throw NativeRPCError(message: "Rename was not confirmed by the Mac.") }
        return renamed
    }
    func fork(sessionId: String, atSeq: Int? = nil) async throws -> String {
        var request: [String: JSONValue] = ["sessionId": .text(sessionId)]
        if let atSeq {
            guard atSeq >= 0 else { throw NativeRPCError(message: "Choose a completed conversation sequence.") }
            request["atSeq"] = .number(Double(atSeq))
        }
        let value = try await call("session/fork", request: .obj(request))
        guard let id = value["sessionId"].string, !id.isEmpty else { throw NativeRPCError(message: "The Mac did not confirm a conversation fork.") }
        return id
    }
    /// Archive never retries by stopping activity, and is deliberately not called Delete.
    func archive(sessionId: String) async throws -> [String] {
        let value = try await call("workspace/archiveSession", request: .obj(["sessionId": .text(sessionId), "stopActivity": .bool(false)]))
        guard case .array(let values) = value["archivedSessionIds"], values.allSatisfy({ $0.string != nil }) else { throw NativeRPCError(message: "Archive was not confirmed by the Mac.") }
        return values.compactMap { $0.string }
    }
}

/// Exact lexical midpoint used by the custom host. Never used to reorder queued prompts.
enum MobileLifecycleOrder {
    static func between(_ before: String?, _ after: String?) throws -> String {
        for key in [before, after].compactMap({ $0 }) {
            guard !key.isEmpty, key.count <= 2048, key.last != "a", key.utf8.allSatisfy({ (97...122).contains($0) }) else { throw NativeRPCError(message: "Invalid thread order key.") }
        }
        let a = before ?? "", b = after ?? ""
        guard b.isEmpty || a < b else { throw NativeRPCError(message: "Order neighbors changed.") }
        return midpoint(a, b)
    }
    private static func midpoint(_ a: String, _ b: String) -> String {
        let aa = Array(a.utf8), bb = Array(b.utf8)
        if !bb.isEmpty {
            var n = 0
            while n < bb.count && (n < aa.count ? aa[n] : 97) == bb[n] { n += 1 }
            if n > 0 { return String(decoding: bb.prefix(n), as: UTF8.self) + midpoint(String(decoding: aa.dropFirst(n), as: UTF8.self), String(decoding: bb.dropFirst(n), as: UTF8.self)) }
        }
        let lo = aa.first.map { Int($0) - 97 } ?? 0, hi = bb.first.map { Int($0) - 97 } ?? 26
        if hi - lo > 1 { return String(UnicodeScalar(97 + Int((Double(lo + hi) / 2).rounded()))!) }
        if bb.count > 1 { return String(decoding: bb.prefix(1), as: UTF8.self) }
        return String(UnicodeScalar(97 + lo)!) + midpoint(String(decoding: aa.dropFirst(), as: UTF8.self), "")
    }
}
