import XCTest
import UIKit
@testable import DSHCompanion

final class ChatImageTests: XCTestCase {
    @MainActor private func sample() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
    }
    private func reference(_ data: Data, type: String = "image/jpeg", width: Int = 160) -> ChatImageReference {
        ChatImageReference(attachment: .obj(["attachmentId": .text("fixture-image"), "mediaType": .text(type), "bytes": .number(Double(data.count)), "width": .number(Double(width)), "height": .number(120), "name": .text("Synthetic image.jpg")]), contentIndex: 1)!
    }
    @MainActor func testValidHistoricalImageDecodesBoundedThumbnail() throws {
        let data = sample(), ref = reference(data)
        let result = try ChatImageDecoder.decode(data.base64EncodedString(), reference: ref, maxBytes: data.count)
        XCTAssertEqual(result.image.size.width, 160)
        XCTAssertEqual(result.image.size.height, 120)
        XCTAssertGreaterThan(result.cost, 0)
    }
    @MainActor func testHistoricalImageRejectsWrongTypeDimensionsAndLimit() {
        let data = sample()
        XCTAssertThrowsError(try ChatImageDecoder.decode(data.base64EncodedString(), reference: reference(data, type: "image/png"), maxBytes: data.count))
        XCTAssertThrowsError(try ChatImageDecoder.decode(data.base64EncodedString(), reference: reference(data, width: 159), maxBytes: data.count))
        XCTAssertThrowsError(try ChatImageDecoder.decode(data.base64EncodedString(), reference: reference(data), maxBytes: data.count - 1))
        XCTAssertThrowsError(try ChatImageDecoder.decode(data.base64EncodedString(), reference: reference(data, type: "image/svg+xml"), maxBytes: data.count))
    }
    @MainActor func testHistoricalImageRejectsDataURLWhitespaceAndWrongBytes() {
        let data = sample(), ref = reference(data)
        XCTAssertThrowsError(try ChatImageDecoder.decode("data:image/jpeg;base64," + data.base64EncodedString(), reference: ref, maxBytes: data.count))
        XCTAssertThrowsError(try ChatImageDecoder.decode(data.base64EncodedString() + "\n", reference: ref, maxBytes: data.count))
        XCTAssertThrowsError(try ChatImageDecoder.decode(Data([1,2,3]).base64EncodedString(), reference: ref, maxBytes: data.count))
    }
}
