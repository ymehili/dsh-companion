import Foundation
import Observation

/// Immutable confirmation payload. A failed/ambiguous submission is never automatically retried.
struct MobileRepositoryOperation: Identifiable, Equatable {
    let id: UUID
    let endpoint: String
    let request: JSONValue
    let title: String
    init(snapshot: MobileRepositoryStatus, action: String, fields: [String: JSONValue] = [:], pull: MobilePullDetail? = nil, requestId: UUID = UUID()) throws {
        try snapshot.validate(session: snapshot.sessionId)
        guard snapshot.writable else { throw MobileRepositoryError.permission }
        let gitActions: Set<String> = ["stage", "unstage", "commit", "createBranch", "switchBranch", "createWorktree", "removeWorktree", "fetch", "pull", "push"]
        let pullActions: Set<String> = ["create", "comment", "approve", "requestChanges", "reviewComment", "merge"]
        var required: Set<String> = []
        if gitActions.contains(action) {
            endpoint = "mobileRepository/mutate"
            switch action {
            case "stage", "unstage":
                required = ["paths"]
                guard case .array(let paths) = fields["paths"], !paths.isEmpty, paths.count <= 2000, Set(paths.compactMap(\.string)).count == paths.count else { throw MobileRepositoryError.invalid }
                for p in paths {
                    guard let path = p.string, snapshot.files.contains(where: { $0.path == path && (action == "stage" ? $0.unstaged : $0.staged) }) else { throw MobileRepositoryError.scope }
                }
            case "commit":
                required = ["message", "runHooks"]
                guard let message = fields["message"]?.string, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fields["runHooks"]?.bool != nil, snapshot.files.contains(where: \.staged) else { throw MobileRepositoryError.invalid }
                try MobileRepositoryValidation.text(message, max: 16_384, multiline: true)
            case "createBranch", "createWorktree":
                required = fields["base"] == nil ? ["name"] : ["name", "base"]
                guard let name = fields["name"]?.string else { throw MobileRepositoryError.invalid }
                try MobileRepositoryValidation.ref(name)
                if let base = fields["base"]?.string { try MobileRepositoryValidation.ref(base) }
                if action == "createWorktree", !snapshot.capabilities.worktrees { throw MobileRepositoryError.permission }
            case "switchBranch":
                required = ["name"]
                guard let name = fields["name"]?.string, snapshot.branches.contains(where: { $0.name == name && !$0.remote && !$0.current }) else { throw MobileRepositoryError.scope }
            case "removeWorktree":
                required = ["path"]
                guard snapshot.capabilities.worktrees, let path = fields["path"]?.string,
                      snapshot.worktrees.contains(where: { $0.path == path && !$0.current && !$0.locked }) else { throw MobileRepositoryError.permission }
            default: break
            }
        } else if pullActions.contains(action) {
            endpoint = "mobileRepository/pullMutate"
            guard snapshot.capabilities.github, let repository = snapshot.github else { throw MobileRepositoryError.permission }
            if action == "create" {
                required = ["title", "body", "head", "base", "draft"]
                guard let title = fields["title"]?.string, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let body = fields["body"]?.string, let head = fields["head"]?.string, let base = fields["base"]?.string,
                      fields["draft"]?.bool != nil, head != base, snapshot.head != nil else { throw MobileRepositoryError.invalid }
                try MobileRepositoryValidation.text(title, max: 4096)
                try MobileRepositoryValidation.text(body, max: 128_000, empty: true, multiline: true)
                try MobileRepositoryValidation.ref(head); try MobileRepositoryValidation.ref(base)
                guard head == snapshot.branch, snapshot.branches.contains(where: { $0.name == head && !$0.remote && $0.current }) else { throw MobileRepositoryError.scope }
            } else {
                guard let pull else { throw MobileRepositoryError.scope }
                try pull.validate(snapshot: snapshot, number: pull.item.number)
                guard pull.repository == repository, MobileRepositoryValidation.sha(pull.item.head), pull.item.state == "open" else { throw MobileRepositoryError.permission }
                if action == "merge" {
                    required = ["method"]
                    guard ["merge", "squash", "rebase"].contains(fields["method"]?.string ?? ""), !pull.item.draft,
                          pull.mergeable.lowercased() == "mergeable" || pull.mergeable.lowercased() == "clean" else { throw MobileRepositoryError.conflict }
                } else {
                    required = ["body"]
                    guard let body = fields["body"]?.string, action == "approve" || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MobileRepositoryError.invalid }
                    try MobileRepositoryValidation.text(body, max: 128_000, empty: action == "approve", multiline: true)
                }
            }
        } else { throw MobileRepositoryError.invalid }
        guard Set(fields.keys) == required else { throw MobileRepositoryError.invalid }
        var request = fields
        request["sessionId"] = .text(snapshot.sessionId)
        request["version"] = .text(snapshot.version)
        request["requestId"] = .text(requestId.uuidString)
        request["action"] = .text(action)
        if endpoint.hasSuffix("pullMutate"), let repository = snapshot.github {
            request["repository"] = .obj(["owner": .text(repository.owner), "name": .text(repository.name)])
            request["expectedHead"] = .text(pull?.item.head ?? snapshot.head ?? "")
            if let pull { request["number"] = .number(Double(pull.item.number)) }
        }
        self.request = .obj(request); id = requestId; title = action
    }
    var envelope: JSONValue { .obj(["args": .obj(["request": request])]) }
    var confirmationText: String {
        var lines: [String] = []
        for key in ["paths", "path", "name", "number", "title", "head", "base", "method", "draft", "runHooks", "message", "body", "expectedHead"] {
            let value = request[key]
            let label: String
            switch value {
            case .string(let text): label = String(text.prefix(500)) + (text.count > 500 ? "… (preview)" : "")
            case .array(let values): label = values.compactMap(\.string).joined(separator: ", ")
            case .bool(let flag): label = flag ? "Yes" : "No"
            case .number(let number): label = String(Int(number))
            default: continue
            }
            lines.append("\(key): \(label)")
        }
        lines.append("Snapshot: \(request["version"].string ?? "")")
        lines.append("Request: \(id.uuidString)")
        lines.append("No force/discard or automatic replay. Network actions contact the remote.")
        return lines.joined(separator: "\n")
    }
}

struct MobileRepositoryMutationResult {
    let snapshot: MobileRepositoryStatus?
    let worktreePath: String?
    let number: Int?
}
@MainActor protocol MobileRepositoryServing: AnyObject {
    var sessionId: String { get }
    func status() async throws -> MobileRepositoryStatus
    func diff(snapshot: MobileRepositoryStatus, file: MobileRepositoryFile, staged: Bool) async throws -> MobileRepositoryDiff
    func pulls(snapshot: MobileRepositoryStatus, state: String) async throws -> MobilePullList
    func pull(snapshot: MobileRepositoryStatus, number: Int) async throws -> MobilePullDetail
    func submit(_ operation: MobileRepositoryOperation) async throws -> MobileRepositoryMutationResult
}

@MainActor final class MobileRepositoryService: MobileRepositoryServing {
    let sessionId: String
    private let transport: any NativeTransport
    private var submitted: Set<UUID> = []
    init(sessionId: String, transport: any NativeTransport) { self.sessionId = sessionId; self.transport = transport }
    private func call(_ method: String, _ fields: [String: JSONValue]) async throws -> JSONValue {
        try MobileRepositoryValidation.text(sessionId, max: 256)
        var request = fields; request["sessionId"] = .text(sessionId)
        do {
            let result = try await transport.rpc("mobileRepository/\(method)", .obj(["args": .obj(["request": .obj(request)])]))
            try Task.checkCancellation()
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeRPCError {
            switch error.code {
            case "repository/conflict": throw MobileRepositoryError.conflict
            case "repository/permission": throw MobileRepositoryError.permission
            case "repository/auth-required": throw MobileRepositoryError.auth
            case "repository/uncertain": throw MobileRepositoryError.uncertain
            case "repository/invalid-request", "repository/too-large": throw MobileRepositoryError.invalid
            default: throw MobileRepositoryError.unavailable
            }
        } catch { throw MobileRepositoryError.unavailable }
    }
    func status() async throws -> MobileRepositoryStatus {
        let value = try await call("status", [:])
        let status = try MobileRepositoryValidation.decode(MobileRepositoryStatus.self, value)
        try status.validate(session: sessionId); return status
    }
    func diff(snapshot: MobileRepositoryStatus, file: MobileRepositoryFile, staged: Bool) async throws -> MobileRepositoryDiff {
        try snapshot.validate(session: sessionId)
        guard snapshot.files.contains(file), staged ? file.staged : file.unstaged else { throw MobileRepositoryError.scope }
        let value = try await call("diff", ["version": .text(snapshot.version), "path": .text(file.path), "staged": .bool(staged)])
        let diff = try MobileRepositoryValidation.decode(MobileRepositoryDiff.self, value)
        try diff.validate(snapshot: snapshot, file: file); return diff
    }
    func pulls(snapshot: MobileRepositoryStatus, state: String) async throws -> MobilePullList {
        try snapshot.validate(session: sessionId)
        guard snapshot.capabilities.github, snapshot.github != nil else { throw MobileRepositoryError.auth }
        guard ["open", "closed", "all"].contains(state) else { throw MobileRepositoryError.invalid }
        let value = try await call("pulls", ["state": .text(state), "limit": .number(100)])
        let list = try MobileRepositoryValidation.decode(MobilePullList.self, value)
        try list.validate(snapshot: snapshot); return list
    }
    func pull(snapshot: MobileRepositoryStatus, number: Int) async throws -> MobilePullDetail {
        try snapshot.validate(session: sessionId)
        guard snapshot.capabilities.github, snapshot.github != nil, (1...10_000_000).contains(number) else { throw MobileRepositoryError.permission }
        let value = try await call("pull", ["number": .number(Double(number))])
        let detail = try MobileRepositoryValidation.decode(MobilePullDetail.self, value)
        try detail.validate(snapshot: snapshot, number: number); return detail
    }
    func submit(_ operation: MobileRepositoryOperation) async throws -> MobileRepositoryMutationResult {
        guard operation.request["sessionId"].string == sessionId, submitted.insert(operation.id).inserted else { throw MobileRepositoryError.uncertain }
        let value: JSONValue
        do { value = try await transport.rpc(operation.endpoint, operation.envelope) }
        catch { throw MobileRepositoryError.uncertain }
        // A cancelled write may already have completed; do not turn cancellation into retry permission.
        guard !Task.isCancelled, value["accepted"].bool == true else { throw MobileRepositoryError.uncertain }
        if operation.endpoint == "mobileRepository/mutate" {
            let snapshot = try MobileRepositoryValidation.decode(MobileRepositoryStatus.self, value["snapshot"])
            try snapshot.validate(session: sessionId)
            var path: String?
            if value["worktreePath"] != .null {
                guard operation.request["action"].string == "createWorktree", let returned = value["worktreePath"].string,
                      snapshot.worktrees.contains(where: { $0.path == returned }), returned.hasPrefix("/") else { throw MobileRepositoryError.uncertain }
                path = returned
            }
            return MobileRepositoryMutationResult(snapshot: snapshot, worktreePath: path, number: nil)
        }
        guard let number = value["number"].integer, (1...10_000_000).contains(number), operation.request["number"].integer.map({ $0 == number }) ?? true else { throw MobileRepositoryError.uncertain }
        if let url = value["url"].string {
            let identity = try MobileRepositoryValidation.decode(MobileRepositoryIdentity.self, operation.request["repository"])
            _ = try identity.url(number: number, supplied: url)
        }
        return MobileRepositoryMutationResult(snapshot: nil, worktreePath: nil, number: number)
    }
}

@MainActor @Observable final class MobileRepositoryController {
    let service: any MobileRepositoryServing
    private(set) var snapshot: MobileRepositoryStatus?
    private(set) var busy = false
    private(set) var issue: String?
    private(set) var writeLocked = false
    var confirmation: MobileRepositoryOperation?
    // Session-owned, memory-only drafts survive sheet closure, including uncertain delivery.
    var formDrafts: [String: [String: JSONValue]] = [:]
    private(set) var returnedWorkspace: String?
    private var generation = UUID()
    init(service: any MobileRepositoryServing) { self.service = service }
    func refresh() async {
        guard !busy else { return }
        busy = true; issue = nil; let token = UUID(); generation = token
        defer { if generation == token { busy = false } }
        do {
            let next = try await service.status(); try Task.checkCancellation()
            guard token == generation else { return }; snapshot = next
        } catch is CancellationError {} catch { snapshot = nil; issue = error.localizedDescription }
    }
    func prepare(action: String, fields: [String: JSONValue] = [:], pull: MobilePullDetail? = nil) {
        guard !busy, !writeLocked, let snapshot else { return }
        do { confirmation = try MobileRepositoryOperation(snapshot: snapshot, action: action, fields: fields, pull: pull) }
        catch { issue = error.localizedDescription }
    }
    func confirm(_ captured: MobileRepositoryOperation? = nil) async -> Bool {
        guard !busy, !writeLocked, let operation = captured ?? confirmation,
              operation.request["sessionId"].string == service.sessionId,
              operation.request["version"].string == snapshot?.version else { return false }
        confirmation = nil; busy = true; writeLocked = true; issue = nil
        defer { busy = false }
        do {
            let result = try await service.submit(operation)
            if let next = result.snapshot { snapshot = next } else { snapshot = nil }
            returnedWorkspace = result.worktreePath
            // Explicit refresh is required after every remote write; never reload network automatically.
            writeLocked = false
            issue = result.number.map { "Submitted for pull request #\($0). Refresh explicitly to view remote state." }
            return true
        } catch {
            issue = error.localizedDescription
            // No retry button for writes, including cancellation. Form text remains owned by its screen.
            return false
        }
    }
}
