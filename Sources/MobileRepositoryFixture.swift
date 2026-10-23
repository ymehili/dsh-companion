import Foundation

/// Entirely typed, in-memory service. Never owns a Store, transport, URLSession, file, or process handle.
@MainActor final class MobileRepositoryFixtureService: MobileRepositoryServing {
    let sessionId: String
    private var revision = 1
    private var submitted: Set<UUID> = []
    private var stagedPaths: Set<String> = ["Assets/Preview.png"]
    private var committedPaths: Set<String> = []
    private var branch = "feature/native-review"
    private var extraBranches: [String] = []
    private var extraWorktrees: [MobileRepositoryWorktree] = []
    private var removed: Set<String> = []
    private var remoteComments: [Int: [MobilePullComment]] = [:]
    private var created: (title: String, body: String, head: String, base: String, draft: Bool)?
    private var merged = false
    static let head = String(repeating: "a", count: 40)
    static let identity = MobileRepositoryIdentity(owner: "t3-demo", name: "native-fixture")
    init(sessionId: String) { self.sessionId = sessionId }
    private func snapshot() -> MobileRepositoryStatus {
        let originals: [MobileRepositoryFile] = [
            .init(path: "Sources/Review.swift", oldPath: nil, status: .modified, staged: false, unstaged: true, added: 3, deleted: 1, binary: false),
            .init(path: "Assets/Preview.png", oldPath: nil, status: .added, staged: true, unstaged: false, added: nil, deleted: nil, binary: true),
            .init(path: "Notes/New note.md", oldPath: nil, status: .untracked, staged: false, unstaged: true, added: 2, deleted: 0, binary: false)
        ]
        let files = originals.filter { !committedPaths.contains($0.path) }.map { f in
            MobileRepositoryFile(path: f.path, oldPath: f.oldPath, status: f.status == .untracked && stagedPaths.contains(f.path) ? .added : f.status, staged: stagedPaths.contains(f.path), unstaged: !stagedPaths.contains(f.path), added: f.added, deleted: f.deleted, binary: f.binary)
        }
        return MobileRepositoryStatus(sessionId: sessionId, version: "synthetic-content-index-head-\(revision)", rootLabel: "Native fixture · synthetic", head: Self.head, branch: branch, files: files,
            branches: (["main", "feature/native-review"] + extraBranches).map { .init(name: $0, current: $0 == branch, remote: false) } + [.init(name: "origin/main", current: false, remote: true)],
            worktrees: ([.init(path: "/synthetic/native-fixture", branch: branch, head: Self.head, current: true, locked: false), .init(path: "/synthetic/review-worktree", branch: "review", head: Self.head, current: false, locked: false)] + extraWorktrees).filter { !removed.contains($0.path) },
            github: Self.identity, capabilities: .init(git: true, github: true, worktrees: true, writes: true))
    }
    func status() async throws -> MobileRepositoryStatus { try Task.checkCancellation(); return snapshot() }
    func diff(snapshot: MobileRepositoryStatus, file: MobileRepositoryFile, staged: Bool) async throws -> MobileRepositoryDiff {
        guard snapshot.sessionId == sessionId, snapshot.version == self.snapshot().version, snapshot.files.contains(file), staged ? file.staged : file.unstaged else { throw MobileRepositoryError.conflict }
        try Task.checkCancellation()
        return .init(sessionId: sessionId, version: snapshot.version, path: file.path,
                     patch: file.binary ? "" : "diff --git a/\(file.path) b/\(file.path)\n--- a/\(file.path)\n+++ b/\(file.path)\n@@ -1,2 +1,4 @@\n import SwiftUI\n-let label = \"Review\"\n+let label = \"Native review\"\n+// Keep comments local\n+let enabled = true\n", binary: file.binary, truncated: false)
    }
    private func summary(_ number: Int, title: String, draft: Bool = false, base: String = "main") -> MobilePullSummary {
        .init(number: number, title: title, state: number == 42 && merged ? "merged" : "open", draft: draft, author: number == 42 ? "alex-demo" : "sam-demo", url: "https://github.com/t3-demo/native-fixture/pull/\(number)", head: Self.head, base: base, updatedAt: "2026-01-15T10:00:00Z")
    }
    func pulls(snapshot: MobileRepositoryStatus, state: String) async throws -> MobilePullList {
        try snapshot.validate(session: sessionId); try Task.checkCancellation()
        guard ["open", "closed", "all"].contains(state) else { throw MobileRepositoryError.invalid }
        var items = [summary(42, title: "Native repository review"), summary(43, title: "Polish grouped pull request surfaces", draft: true)]
        if let created { items.append(summary(44, title: created.title, draft: created.draft, base: created.base)) }
        if state != "all" { items = items.filter { state == "open" ? $0.state == "open" : $0.state != "open" } }
        return .init(sessionId: sessionId, repository: Self.identity, items: items, hasMore: false)
    }
    func pull(snapshot: MobileRepositoryStatus, number: Int) async throws -> MobilePullDetail {
        let list = try await pulls(snapshot: snapshot, state: "all")
        guard let item = list.items.first(where: { $0.number == number }) else { throw MobileRepositoryError.invalid }
        return .init(sessionId: sessionId, repository: Self.identity, item: item, body: number == 44 ? (created?.body ?? "") : "## Summary\nA fully synthetic native review fixture.\n\n- Grouped file surfaces\n- Local draft comments\n\nNo real repository or GitHub account is accessed.", files: [.init(path: "Sources/Review.swift", status: "modified", added: 3, deleted: 1, patch: "@@ -1 +1 @@\n-old\n+native\n"), .init(path: "Assets/Preview.png", status: "added", added: 0, deleted: 0, patch: nil)], comments: [.init(id: "fixture-comment-1", author: "sam-demo", body: "Please keep the review draft local until explicitly submitted.", createdAt: "2026-01-15T09:00:00Z")] + (remoteComments[number] ?? []), checks: [.init(name: "Native unit tests", state: "success"), .init(name: "Review policy", state: "pending")], mergeable: "mergeable")
    }
    func submit(_ operation: MobileRepositoryOperation) async throws -> MobileRepositoryMutationResult {
        guard operation.request["sessionId"].string == sessionId, submitted.insert(operation.id).inserted else { throw MobileRepositoryError.uncertain }
        guard operation.request["version"].string == snapshot().version else { throw MobileRepositoryError.conflict }
        try Task.checkCancellation()
        let r = operation.request
        let action = r["action"].string ?? ""
        if operation.endpoint.hasSuffix("pullMutate") {
            guard r["expectedHead"].string == Self.head else { throw MobileRepositoryError.conflict }
            let number = r["number"].integer ?? 44
            switch action {
            case "create": created = (r["title"].string ?? "", r["body"].string ?? "", r["head"].string ?? "", r["base"].string ?? "", r["draft"].bool ?? true)
            case "comment", "approve", "requestChanges", "reviewComment": remoteComments[number, default: []].append(.init(id: operation.id.uuidString, author: "you-demo", body: "\(action): \(r["body"].string ?? "")", createdAt: "2026-01-15T10:01:00Z"))
            case "merge": merged = true
            default: throw MobileRepositoryError.invalid
            }
            return .init(snapshot: nil, worktreePath: nil, number: number)
        }
        var returned: String?
        switch action {
        case "stage": stagedPaths.formUnion(r["paths"].array.compactMap(\.string))
        case "unstage": stagedPaths.subtract(r["paths"].array.compactMap(\.string))
        case "commit": committedPaths.formUnion(stagedPaths); stagedPaths.removeAll()
        case "createBranch": if let name = r["name"].string { extraBranches.append(name) }
        case "switchBranch": branch = r["name"].string ?? branch
        case "createWorktree":
            let name = r["name"].string ?? "review"
            let path = "/synthetic/\(name)"
            extraWorktrees.append(.init(path: path, branch: name, head: Self.head, current: false, locked: false)); returned = path
        case "removeWorktree": if let path = r["path"].string { removed.insert(path) }
        case "fetch", "pull", "push": break
        default: throw MobileRepositoryError.invalid
        }
        revision += 1
        return .init(snapshot: snapshot(), worktreePath: returned, number: nil)
    }
}
