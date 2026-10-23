#if DEBUG
import UIKit

/// Explicit UI-test-only transfer sources. Never reads the user's Photos library.
@MainActor enum NativePhotoImportFixture {
    static func inputs(batch: Int) -> [PhotoImportInput] {
        (0..<(batch == 0 ? 2 : 1)).map { index in
            let bytes = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).jpegData(withCompressionQuality: 0.8) { context in
                (index == 0 ? UIColor.systemBlue : UIColor.systemTeal).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            }
            return PhotoImportInput {
                try await Task.sleep(for: .milliseconds(150))
                return bytes
            }
        }
    }
}
#endif
