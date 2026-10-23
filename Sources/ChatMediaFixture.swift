#if DEBUG
import Foundation
import UIKit

/// Explicit, offline image-RPC fixture; never substitutes for network failures.
@MainActor final class ChatMediaFixtureTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    private var failedOnce = false
    static let image: Data = {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 320, height: 220), format: format).jpegData(withCompressionQuality: 0.85) { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 220))
            ("Historical image" as NSString).draw(at: CGPoint(x: 32, y: 94), withAttributes: [.font: UIFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: UIColor.white])
        }
    }()
    static var reference: JSONValue { .obj(["attachmentId": .text("synthetic-history-image"), "mediaType": .text("image/jpeg"), "bytes": .number(Double(image.count)), "width": .number(320), "height": .number(220), "name": .text("Synthetic history.jpg")]) }
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        guard endpoint == "session/attachment", payload["args"]["request"]["sessionId"].string == "fixture-native", payload["args"]["request"]["attachmentId"].string == "synthetic-history-image" else { throw NativeRPCError(message: "Unsupported test request") }
        if ProcessInfo.processInfo.arguments.contains("-native-image-retry-fixture") && !failedOnce { failedOnce = true; throw NativeRPCError(message: "Synthetic image failure") }
        return .obj(["attachment": Self.reference, "data": .text(Self.image.base64EncodedString())])
    }
    func openStream() {}
    func closeStream() {}
    func sendFrame(_ value: JSONValue) async throws {}
}
#endif
