import Foundation

/// A session-authorized image reference, never a URL or inline image payload.
struct ChatImageReference: Equatable, Sendable, Identifiable {
    struct Dimensions: Equatable, Sendable {
        let width: Int
        let height: Int
    }
    let attachmentId: String
    let mediaType: String
    let bytes: Int
    let width: Int
    let height: Int
    let name: String?
    let originalDimensions: Dimensions?
    /// Position in the original content array (including non-image blocks).
    let contentIndex: Int
    var id: String { "\(contentIndex):\(attachmentId)" }

    init?(attachment: JSONValue, contentIndex: Int) {
        guard let id = attachment["attachmentId"].string, !id.isEmpty,
              let mime = attachment["mediaType"].string,
              let bytes = attachment["bytes"].integer, bytes > 0,
              let width = attachment["width"].integer, width > 0,
              let height = attachment["height"].integer, height > 0 else { return nil }
        self.attachmentId = id
        self.mediaType = mime
        self.bytes = bytes
        self.width = width
        self.height = height
        self.name = attachment["name"].string
        if let w = attachment["originalDimensions"]["width"].integer, w > 0,
           let h = attachment["originalDimensions"]["height"].integer, h > 0 {
            originalDimensions = Dimensions(width: w, height: h)
        } else { originalDimensions = nil }
        self.contentIndex = contentIndex
    }

    static func references(in content: JSONValue) -> [Self] {
        content.array.enumerated().compactMap { index, block in
            guard block["type"].string == "image" else { return nil }
            return Self(attachment: block["attachment"], contentIndex: index)
        }
    }
}
