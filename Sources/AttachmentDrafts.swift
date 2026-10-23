import Foundation

struct DraftPhoto: Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data
    init(id: UUID = UUID(), data: Data) { self.id = id; self.data = data }
}

struct AttachmentDrafts {
    private var values: [String: [DraftPhoto]] = [:]
    private var loading: [String: UUID] = [:]
    // Compatibility for existing single-photo tests/callers; the composer uses photos(in:).
    subscript(_ session: String) -> Data? { values[session]?.first?.data }
    func photos(in session: String) -> [DraftPhoto] { values[session] ?? [] }
    mutating func restore(_ session: String, photos: [DraftPhoto]) {
        guard loading[session] == nil, Set(photos.map(\.id)).count == photos.count else { return }
        values[session] = photos
    }
    func isLoading(_ session: String) -> Bool { loading[session] != nil }
    func isCurrent(_ session: String, token: UUID) -> Bool { loading[session] == token }
    mutating func begin(_ session: String) -> UUID {
        let token = UUID(); loading[session] = token; return token
    }
    @discardableResult mutating func append(_ session: String, token: UUID, data: Data, limits: PhotoLimits) throws -> Bool {
        guard loading[session] == token else { return false }
        let next = (values[session] ?? []) + [DraftPhoto(data: data)]
        try limits.validate(next.map(\.data))
        values[session] = next
        return true
    }
    mutating func finish(_ session: String, token: UUID, data: Data?) -> Bool {
        guard loading[session] == token else { return false }
        loading.removeValue(forKey: session)
        if let data { values[session] = [DraftPhoto(data: data)] }
        return true
    }
    mutating func cancelLoading(_ session: String) { loading.removeValue(forKey: session) }
    mutating func remove(_ session: String, photoID: UUID) { values[session]?.removeAll { $0.id == photoID } }
    mutating func remove(_ session: String) {
        loading.removeValue(forKey: session); values.removeValue(forKey: session)
    }
}
