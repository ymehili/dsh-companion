import Foundation
import Observation

@MainActor protocol MobileQueueServing: AnyObject {
    var sessionId: String { get }
    func update(_ item: MobileQueueItem, action: MobileQueueAction) async throws
    /// Cold projection read; never selects, resumes, prompts, or resolves an Agent.
    func readProjection() async throws -> JSONValue
}

@MainActor final class MobileQueueService: MobileQueueServing {
    let sessionId: String
    private let transport: any NativeTransport
    init(sessionId: String, transport: any NativeTransport) {
        self.sessionId = sessionId
        self.transport = transport
    }
    func update(_ item: MobileQueueItem, action: MobileQueueAction) async throws {
        guard MobileQueueSnapshot.validId(sessionId), item.sessionId == sessionId,
              MobileQueueSnapshot.validId(item.id) else { throw MobileQueueFailure.boundary }
        try action.validate(for: item)
        let request: JSONValue = .obj(["sessionId": .text(sessionId), "itemId": .text(item.id), "action": action.wire])
        do {
            let response = try await transport.rpc("session/updateQueue", .obj(["args": .obj(["request": request])]))
            guard response["accepted"].bool == true else { throw MobileQueueFailure.rejected }
        } catch let error as MobileQueueFailure { throw error }
        catch {
            // Inspect only known error markers; never echo raw Host text/identifiers or log content.
            let message = (error as? NativeRPCError)?.message ?? ""
            if message.contains("session/queue-item-not-found") || message.contains("queued item is no longer pending") {
                throw MobileQueueFailure.alreadyStarted
            }
            if message.contains("session/steer-unavailable") || message.contains("current turn no longer accepts steering") {
                throw MobileQueueFailure.steerUnavailable
            }
            throw MobileQueueFailure.transport
        }
    }
    func readProjection() async throws -> JSONValue {
        guard MobileQueueSnapshot.validId(sessionId) else { throw MobileQueueFailure.boundary }
        do {
            let result = try await transport.rpc("session/projections", .obj(["args": .obj(["request": .obj(["sessionId": .text(sessionId)])])]))
            let values = result["values"]
            _ = try MobileQueueSnapshot(sessionId: sessionId, projection: values)
            return values
        } catch let error as MobileQueueFailure { throw error }
        catch { throw MobileQueueFailure.unavailable }
    }
}

struct MobileQueueEdit: Equatable {
    let item: MobileQueueItem
    var text: String
}

@MainActor @Observable final class MobileQueueController {
    let sessionId: String
    private let service: any MobileQueueServing
    private(set) var snapshot: MobileQueueSnapshot?
    private(set) var pending: Set<String> = []
    private(set) var errors: [String: MobileQueueFailure] = [:]
    private(set) var issue: MobileQueueFailure?
    private(set) var refreshing = false
    private var projectionRevision = 0
    var editing: MobileQueueEdit?
    init(service: any MobileQueueServing) { self.service = service; sessionId = service.sessionId }

    func receive(_ projection: JSONValue) {
        projectionRevision += 1
        do { snapshot = try MobileQueueSnapshot(sessionId: sessionId, projection: projection); issue = nil }
        catch { snapshot = nil; issue = (error as? MobileQueueFailure) ?? .invalidSnapshot }
        if let edit = editing, snapshot != nil {
            if let current = snapshot?.items.first(where: { $0.id == edit.item.id }) {
                if current.content != edit.item.content { errors[edit.item.id] = .changed }
            } else { errors[edit.item.id] = .alreadyStarted }
        }
    }
    func beginEdit(_ item: MobileQueueItem) {
        guard item.sessionId == sessionId, !pending.contains(item.id), item.canEdit,
              snapshot?.items.contains(item) == true else { return }
        errors[item.id] = nil
        editing = MobileQueueEdit(item: item, text: item.text)
    }
    func saveEdit() async {
        guard let captured = editing else { return }
        if await perform(captured.item, action: .edit(captured.text)), editing?.item == captured.item {
            editing = nil
        }
    }
    @discardableResult func perform(_ item: MobileQueueItem, action: MobileQueueAction) async -> Bool {
        // All target/action values are captured before suspension, independent of selected session.
        guard item.sessionId == sessionId else { errors[item.id] = .boundary; return false }
        guard !pending.contains(item.id) else { return false }
        guard issue == nil, let snapshot else { errors[item.id] = issue ?? .unavailable; return false }
        guard let current = snapshot.items.first(where: { $0.id == item.id }) else {
            errors[item.id] = .alreadyStarted; return false
        }
        guard current == item else { errors[item.id] = .changed; return false }
        do { try action.validate(for: current) }
        catch { errors[item.id] = (error as? MobileQueueFailure) ?? .rejected; return false }
        let capturedItem = current, capturedAction = action
        pending.insert(item.id); errors[item.id] = nil
        defer { pending.remove(item.id) }
        do {
            try await service.update(capturedItem, action: capturedAction)
            // No optimistic deletion/replay: the authoritative projection updates the rows.
            return true
        } catch {
            let failure = (error as? MobileQueueFailure) ?? .transport
            errors[item.id] = failure
            if failure == .alreadyStarted { await refresh() }
            return false
        }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let revision = projectionRevision
        do {
            let projection = try await service.readProjection()
            // A live control-stream update received during this read wins over its response.
            if revision == projectionRevision { receive(projection) }
        } catch {
            if revision == projectionRevision { issue = (error as? MobileQueueFailure) ?? .unavailable }
        }
    }
}

/// Positive synthetic graph. No NativeTransport, gateway, data URL, provider, or model access.
@MainActor final class MobileQueueFixtureService: MobileQueueServing {
    let sessionId: String
    private var projection: JSONValue
    init(sessionId: String) {
        self.sessionId = sessionId
        projection = Self.graph
    }
    static var graph: JSONValue {
        func row(_ id: String, _ text: String) -> JSONValue {
            .obj(["id": .text(id), "content": .array([.obj(["type": .text("text"), "text": .text(text)])]), "source": .obj(["kind": .text("user"), "rpcId": .text("fixture-\(id)")])])
        }
        return .obj(["inbox": .obj([
            "next-turn": .array([row("fixture-queue-1", "Review the navigation changes."), row("fixture-queue-2", "Then add focused tests for the queue.")]),
            "next-step": .array([row("fixture-steering-1", "Keep the changes scoped to mobile.")])
        ])])
    }
    func readProjection() async throws -> JSONValue { projection }
    func update(_ item: MobileQueueItem, action: MobileQueueAction) async throws {
        guard item.sessionId == sessionId else { throw MobileQueueFailure.boundary }
        try action.validate(for: item)
        var inbox = projection["inbox"].object ?? [:]
        var rows = inbox[item.kind.rawValue]?.array ?? []
        guard let index = rows.firstIndex(where: { $0["id"].string == item.id }) else { throw MobileQueueFailure.alreadyStarted }
        switch action {
        case .edit:
            var row = rows[index].object ?? [:]
            row["content"] = action.wire["content"]; rows[index] = .obj(row)
        case .remove: rows.remove(at: index)
        case .steer:
            let row = rows.remove(at: index)
            inbox[MobileQueueKind.steering.rawValue] = .array((inbox[MobileQueueKind.steering.rawValue]?.array ?? []) + [row])
        }
        inbox[item.kind.rawValue] = .array(rows)
        projection = .obj(["inbox": .obj(inbox)])
    }
}
