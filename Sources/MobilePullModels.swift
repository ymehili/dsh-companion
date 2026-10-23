import Foundation

struct MobilePullSummary: Codable, Equatable, Identifiable {
    let number: Int
    let title: String
    let state: String
    let draft: Bool
    let author: String
    let url: String
    let head: String
    let base: String
    let updatedAt: String
    var id: Int { number }
    func validate(repository: MobileRepositoryIdentity) throws {
        _ = try repository.url(number: number, supplied: url)
        try MobileRepositoryValidation.text(title, max: 4096)
        try MobileRepositoryValidation.text(author, max: 256)
        try MobileRepositoryValidation.text(updatedAt, max: 128)
        try MobileRepositoryValidation.ref(head)
        try MobileRepositoryValidation.ref(base)
        guard ["open", "closed", "merged"].contains(state) else { throw MobileRepositoryError.invalid }
    }
}
struct MobilePullList: Codable {
    let sessionId: String
    let repository: MobileRepositoryIdentity
    let items: [MobilePullSummary]
    let hasMore: Bool
    func validate(snapshot: MobileRepositoryStatus) throws {
        guard sessionId == snapshot.sessionId, repository == snapshot.github, items.count <= 100,
              Set(items.map(\.number)).count == items.count else { throw MobileRepositoryError.scope }
        try repository.validate()
        try items.forEach { try $0.validate(repository: repository) }
    }
}
struct MobilePullFile: Codable, Identifiable {
    let path: String
    let status: String
    let added: Int
    let deleted: Int
    let patch: String?
    var id: String { path }
}
struct MobilePullComment: Codable, Identifiable {
    let id: String
    let author: String
    let body: String
    let createdAt: String
}
struct MobilePullCheck: Codable {
    let name: String
    let state: String
}
struct MobilePullDetail: Codable {
    let sessionId: String
    let repository: MobileRepositoryIdentity
    let item: MobilePullSummary
    let body: String
    let files: [MobilePullFile]
    let comments: [MobilePullComment]
    let checks: [MobilePullCheck]
    let mergeable: String
    func validate(snapshot: MobileRepositoryStatus, number: Int) throws {
        guard sessionId == snapshot.sessionId, repository == snapshot.github, item.number == number,
              files.count <= 1000, comments.count <= 1000, checks.count <= 500,
              Set(files.map(\.path)).count == files.count, Set(comments.map(\.id)).count == comments.count else { throw MobileRepositoryError.scope }
        try item.validate(repository: repository)
        try MobileRepositoryValidation.text(body, max: 512_000, empty: true, multiline: true)
        try MobileRepositoryValidation.text(mergeable, max: 100)
        for f in files {
            try MobileRepositoryValidation.path(f.path)
            try MobileRepositoryValidation.text(f.status, max: 100)
            try MobileRepositoryValidation.count(f.added); try MobileRepositoryValidation.count(f.deleted)
            if let patch = f.patch { try MobileRepositoryValidation.text(patch, max: 1_000_000, empty: true, multiline: true) }
        }
        for c in comments {
            try MobileRepositoryValidation.text(c.id, max: 256)
            try MobileRepositoryValidation.text(c.author, max: 256)
            try MobileRepositoryValidation.text(c.body, max: 128_000, empty: true, multiline: true)
            try MobileRepositoryValidation.text(c.createdAt, max: 128)
        }
        for c in checks { try MobileRepositoryValidation.text(c.name); try MobileRepositoryValidation.text(c.state, max: 100) }
    }
}
