import Foundation

// Adapter DTOs are decoded strictly, then validated before becoming UI authority.
enum MobileRepositoryError: String, LocalizedError {
    case invalid = "The repository adapter returned invalid or over-limit data."
    case scope = "This repository no longer belongs to the selected project."
    case unavailable = "Repository adapter unavailable. Enable the mobileRepository adapter on your Mac, then explicitly refresh."
    case permission = "This action requires repository ownership and write capability."
    case conflict = "The repository changed or has conflicts. Refresh and review before creating a new action."
    case uncertain = "Delivery is uncertain. This action will not be replayed. Keep your text and inspect the repository before another action."
    case auth = "GitHub access is unavailable. Configure authorization on your Mac, then refresh."
    var errorDescription: String? { rawValue }
}

enum MobileRepositoryValidation {
    static func text(_ value: String, max: Int = 4096, empty: Bool = false, multiline: Bool = false) throws {
        guard (empty || !value.isEmpty), value.utf8.count <= max,
              !value.unicodeScalars.contains(where: { ($0.value < 32 && !(multiline && [9, 10, 13].contains($0.value))) || $0.value == 127 }) else { throw MobileRepositoryError.invalid }
    }
    static func path(_ value: String) throws {
        try text(value)
        guard !value.hasPrefix("/"), !value.contains("\\"), !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw MobileRepositoryError.invalid }
    }
    static func count(_ value: Int) throws { guard (0...10_000_000).contains(value) else { throw MobileRepositoryError.invalid } }
    static func sha(_ value: String) -> Bool { [40, 64].contains(value.count) && value.allSatisfy { $0.isHexDigit && $0.isASCII } }
    static func ref(_ value: String) throws {
        try text(value, max: 1024)
        guard !value.hasPrefix("-"), !value.hasPrefix("/"), !value.hasSuffix("/"), !value.hasSuffix("."), !value.hasSuffix(".lock"), !value.contains(".."), !value.contains("@{"), !value.contains("//"), !value.contains(where: { " ~^:?*[\\".contains($0) }) else { throw MobileRepositoryError.invalid }
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            guard data.count <= 4 * 1024 * 1024 else { throw MobileRepositoryError.invalid }
            return try JSONDecoder().decode(type, from: data)
        } catch { throw MobileRepositoryError.invalid }
    }
}

struct MobileRepositoryIdentity: Codable, Equatable {
    let owner: String
    let name: String
    func validate() throws {
        for part in [owner, name] {
            try MobileRepositoryValidation.text(part, max: 100)
            guard part != ".", part != "..", part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { throw MobileRepositoryError.invalid }
        }
    }
    func url(number: Int, supplied: String) throws -> URL {
        try validate()
        guard number > 0, number <= 10_000_000, let c = URLComponents(string: supplied), c.scheme == "https", c.host == "github.com", c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
              c.percentEncodedPath == "/\(owner)/\(name)/pull/\(number)", let url = c.url else { throw MobileRepositoryError.invalid }
        return url
    }
}
struct MobileRepositoryFile: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case modified, added, deleted, renamed, untracked, conflict }
    let path: String
    let oldPath: String?
    let status: Status
    let staged: Bool
    let unstaged: Bool
    let added: Int?
    let deleted: Int?
    let binary: Bool
    var id: String { path }
    func validate() throws {
        try MobileRepositoryValidation.path(path)
        if let oldPath { try MobileRepositoryValidation.path(oldPath) }
        if let added { try MobileRepositoryValidation.count(added) }
        if let deleted { try MobileRepositoryValidation.count(deleted) }
        guard staged || unstaged else { throw MobileRepositoryError.invalid }
    }
}
struct MobileRepositoryBranch: Codable, Equatable, Identifiable {
    let name: String
    let current: Bool
    let remote: Bool
    var id: String { "\(remote):\(name)" }
}
struct MobileRepositoryWorktree: Codable, Equatable, Identifiable {
    let path: String
    let branch: String?
    let head: String
    let current: Bool
    let locked: Bool
    var id: String { path }
}
struct MobileRepositoryCapabilities: Codable, Equatable {
    let git: Bool
    let github: Bool
    let worktrees: Bool
    let writes: Bool
}
struct MobileRepositoryStatus: Codable, Equatable {
    let sessionId: String
    let version: String
    let rootLabel: String
    let head: String?
    let branch: String?
    let files: [MobileRepositoryFile]
    let branches: [MobileRepositoryBranch]
    let worktrees: [MobileRepositoryWorktree]
    let github: MobileRepositoryIdentity?
    let capabilities: MobileRepositoryCapabilities
    var writable: Bool { capabilities.git && capabilities.writes && !files.contains { $0.status == .conflict } }
    func validate(session: String) throws {
        guard sessionId == session else { throw MobileRepositoryError.scope }
        try MobileRepositoryValidation.text(sessionId, max: 256)
        try MobileRepositoryValidation.text(version, max: 512)
        try MobileRepositoryValidation.text(rootLabel)
        if let head { guard MobileRepositoryValidation.sha(head) else { throw MobileRepositoryError.invalid } }
        if let branch { try MobileRepositoryValidation.ref(branch) }
        guard files.count <= 2000, branches.count <= 1000, worktrees.count <= 200,
              Set(files.map(\.path)).count == files.count, Set(branches.map(\.id)).count == branches.count, Set(worktrees.map(\.path)).count == worktrees.count else { throw MobileRepositoryError.invalid }
        try files.forEach { try $0.validate() }
        for b in branches { try MobileRepositoryValidation.ref(b.name) }
        for w in worktrees {
            try MobileRepositoryValidation.text(w.path)
            guard w.path.hasPrefix("/"), !w.path.split(separator: "/").contains(".."), MobileRepositoryValidation.sha(w.head) else { throw MobileRepositoryError.invalid }
            if let branch = w.branch { try MobileRepositoryValidation.ref(branch) }
        }
        try github?.validate()
    }
}
struct MobileRepositoryDiff: Codable, Equatable {
    let sessionId: String
    let version: String
    let path: String
    let patch: String
    let binary: Bool
    let truncated: Bool
    func validate(snapshot: MobileRepositoryStatus, file: MobileRepositoryFile) throws {
        guard sessionId == snapshot.sessionId, version == snapshot.version, path == file.path, snapshot.files.contains(file), binary == file.binary else { throw MobileRepositoryError.scope }
        try MobileRepositoryValidation.text(patch, max: 2_000_000, empty: true, multiline: true)
    }
}

struct MobileRepositoryReviewTarget: Identifiable {
    let id = UUID()
    let sessionId: String
    let version: String
    let ref: String
    let path: String
    let staged: Bool
    let side: String
    let start: Int
    let end: Int
    func xml(comment: String) throws -> String {
        try MobileRepositoryValidation.text(sessionId, max: 256)
        try MobileRepositoryValidation.text(version, max: 512)
        try MobileRepositoryValidation.path(path)
        try MobileRepositoryValidation.text(comment, max: 16_384, multiline: true)
        guard !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ["old", "new"].contains(side), start > 0, end >= start, end <= 10_000_000 else { throw MobileRepositoryError.invalid }
        let escape = MobileReviewTarget.escape
        return "<git_review_comment session_id=\"\(escape(sessionId))\" version=\"\(escape(version))\" ref=\"\(escape(ref))\" path=\"\(escape(path))\" staged=\"\(staged)\" side=\"\(side)\" line_start=\"\(start)\" line_end=\"\(end)\">\n\(escape(comment))\n</git_review_comment>"
    }
}
