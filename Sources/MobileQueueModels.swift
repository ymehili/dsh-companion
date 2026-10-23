import Foundation

/// The IDs are Host occurrence IDs, never locally regenerated prompt/request IDs.
enum MobileQueueKind: String, CaseIterable, Sendable {
    case queued = "next-turn", steering = "next-step"
    var label: String { self == .queued ? "Queued" : "Steering" }
}

struct MobileQueueItem: Identifiable, Equatable, Sendable {
    let sessionId: String
    let id: String
    let kind: MobileQueueKind
    let content: JSONValue
    let source: JSONValue
    var text: String { content.array.compactMap { $0["type"].string == "text" ? $0["text"].string : nil }.joined() }
    var canEdit: Bool { !content.array.isEmpty && content.array.allSatisfy { $0["type"].string == "text" && $0["text"].string != nil } }
    var images: [ChatImageReference] {
        ChatImageReference.references(in: content).filter {
            ["image/png", "image/jpeg", "image/webp", "image/gif"].contains($0.mediaType)
                && $0.bytes <= 20 * 1024 * 1024 && $0.width <= 100_000 && $0.height <= 100_000
                && Double($0.width) * Double($0.height) <= 100_000_000
        }
    }
    var nonTextCount: Int { content.array.filter { $0["type"].string != "text" }.count }
}

struct MobileQueueSnapshot: Equatable, Sendable {
    let sessionId: String
    let items: [MobileQueueItem]
    static let maximumRows = 500
    static let maximumTextBytes = 128 * 1024
    static func validId(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    init(sessionId: String, projection: JSONValue) throws {
        guard Self.validId(sessionId), let inbox = projection["inbox"].object else { throw MobileQueueFailure.unavailable }
        var result: [MobileQueueItem] = []
        var ids = Set<String>()
        var count = 0
        for kind in MobileQueueKind.allCases {
            guard let value = inbox[kind.rawValue], case .array(let rows) = value else { throw MobileQueueFailure.invalidSnapshot }
            count += rows.count
            guard count <= Self.maximumRows else { throw MobileQueueFailure.invalidSnapshot }
            for row in rows {
                guard let id = row["id"].string, Self.validId(id), ids.insert(id).inserted,
                      case .array(let content) = row["content"], content.count <= 128,
                      let sourceKind = row["source"]["kind"].string else { throw MobileQueueFailure.invalidSnapshot }
                // Projections can also contain internal/system/tool occurrences. Never expose those.
                guard sourceKind == "user" else { continue }
                var bytes = 0
                for block in content {
                    guard let type = block["type"].string, !type.isEmpty else { throw MobileQueueFailure.invalidSnapshot }
                    if type == "text" {
                        guard let text = block["text"].string else { throw MobileQueueFailure.invalidSnapshot }
                        bytes += text.utf8.count
                        guard bytes <= Self.maximumTextBytes else { throw MobileQueueFailure.invalidSnapshot }
                    }
                }
                result.append(MobileQueueItem(sessionId: sessionId, id: id, kind: kind, content: row["content"], source: row["source"]))
            }
        }
        self.sessionId = sessionId
        items = result
    }
}

enum MobileQueueAction: Equatable, Sendable {
    case edit(String), remove, steer
    var wire: JSONValue {
        switch self {
        case .edit(let text): return .obj(["kind": .text("edit"), "content": .array([.obj(["type": .text("text"), "text": .text(text)])])])
        case .remove: return .obj(["kind": .text("remove")])
        case .steer: return .obj(["kind": .text("steer")])
        }
    }
    func validate(for item: MobileQueueItem) throws {
        switch self {
        case .edit(let text):
            guard item.canEdit else { throw MobileQueueFailure.nonTextEdit }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= MobileQueueSnapshot.maximumTextBytes else { throw MobileQueueFailure.invalidText }
        case .steer: guard item.kind == .queued else { throw MobileQueueFailure.steerUnavailable }
        case .remove: break
        }
    }
}

enum MobileQueueFailure: Error, LocalizedError, Equatable {
    case unavailable, invalidSnapshot, boundary, invalidText, nonTextEdit, alreadyStarted, changed, steerUnavailable, rejected, transport
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Queue is unavailable. Refresh when your Mac is connected."
        case .invalidSnapshot: return "Queue data could not be verified. Actions are disabled; refresh to try again."
        case .boundary: return "This message does not belong to this session."
        case .invalidText: return "Enter a nonempty message (up to 128 KB)."
        case .nonTextEdit: return "Text-only editing would discard attachments or other content. This message cannot be edited here."
        case .alreadyStarted: return "Message already started or was removed. Your edit is kept here to copy; it will not be sent as a new message."
        case .changed: return "This queued message changed on your Mac. Your edit is kept here; cancel and reopen to edit the current version."
        case .steerUnavailable: return "This turn no longer accepts steering. Refresh the queue."
        case .rejected: return "Your Mac did not accept this queue change. Refresh before retrying."
        case .transport: return "Queue change failed. Your text is kept; refresh or retry when connected."
        }
    }
}
