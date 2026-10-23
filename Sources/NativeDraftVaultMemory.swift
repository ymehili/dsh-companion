import Foundation
import CryptoKit

/// Explicitly injected fixture implementation. Never resolves or reads an app directory.
actor NativeMemoryDraftVault: NativeDraftPersisting {
    private let origin: String
    private let limits: NativeDraftVaultLimits
    private var records: [String: NativeDraftRecord] = [:]
    private var revisions: [String: UInt64] = [:]
    private var sizes: [String: Int] = [:]

    init(origin: String, limits: NativeDraftVaultLimits = .init()) throws {
        try NativeDraftVault.validateLimits(limits)
        self.origin = try NativeDraftVault.normalizedOrigin(origin)
        self.limits = limits
    }

    func load() async -> NativeDraftVaultSnapshot {
        .init(records: records, revisions: revisions, issues: [])
    }

    func save(record: NativeDraftRecord, revision: UInt64) async throws -> Bool {
        try NativeDraftVault.validateRecord(record, origin: origin, limits: limits)
        return try persist(sessionId: record.sessionId, record: record, revision: revision)
    }

    func remove(sessionId: String, revision: UInt64) async throws -> Bool {
        guard !sessionId.isEmpty, sessionId.utf8.count <= limits.maxIdentifierBytes, !sessionId.contains("\0") else {
            throw NativeDraftVaultError.invalid("identifier")
        }
        return try persist(sessionId: sessionId, record: nil, revision: revision)
    }

    private func persist(sessionId: String, record: NativeDraftRecord?, revision: UInt64) throws -> Bool {
        guard revision > (revisions[sessionId] ?? 0) else { return false }
        struct Payload: Encodable {
            let origin: String
            let sessionId: String
            let revision: UInt64
            let record: NativeDraftRecord?
        }
        struct Envelope: Encodable {
            let schema: Int
            let checksum: String
            let payload: Data
        }
        let payload = try JSONEncoder().encode(Payload(origin: origin, sessionId: sessionId, revision: revision, record: record))
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let size = try JSONEncoder().encode(Envelope(schema: 1, checksum: checksum, payload: payload)).count
        guard size <= limits.maxRecordBytes else { throw NativeDraftVaultError.quota("record bytes") }
        guard revisions[sessionId] != nil || revisions.count < limits.maxRecords else { throw NativeDraftVaultError.quota("records including tombstones") }
        let otherBytes = sizes.filter { $0.key != sessionId }.values.reduce(0.0) { $0 + Double($1) }
        guard otherBytes + Double(size) <= Double(limits.maxTotalBytes) else { throw NativeDraftVaultError.quota("total bytes") }
        records[sessionId] = record
        revisions[sessionId] = revision
        sizes[sessionId] = size
        return true
    }
}
