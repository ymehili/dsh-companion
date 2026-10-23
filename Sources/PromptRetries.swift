import Foundation
import CryptoKit

/// Explicit retries reuse the same admission ID for the same ordered payload.
struct PromptRetries {
    private var pending: [String: (fingerprint: String, id: String)] = [:]
    mutating func prepare(session: String, text: String, image: Data?) -> String {
        prepare(session: session, text: text, images: image.map { [$0] } ?? [])
    }
    mutating func prepare(session: String, text: String, images: [Data]) -> String {
        var hash = SHA256()
        func length(_ count: Int) -> Data { var value = UInt64(count).bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        let body = Data(text.utf8)
        hash.update(data: length(body.count)); hash.update(data: body)
        hash.update(data: length(images.count))
        for image in images { hash.update(data: length(image.count)); hash.update(data: image) }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if let old = pending[session], old.fingerprint == fingerprint { return old.id }
        let id = UUID().uuidString
        pending[session] = (fingerprint, id)
        return id
    }
    mutating func acknowledged(session: String, id: String) {
        if pending[session]?.id == id { pending.removeValue(forKey: session) }
    }
}
