import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImagePreparation {
    /// Downsample before decoding; source EXIF/GPS metadata isn't copied.
    static func jpeg(_ data: Data, limits: PhotoLimits = PhotoLimits()) throws -> Data {
        guard limits.acceptsJPEG else { throw NativeRPCError(message: "This host does not accept JPEG photos.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limits.maxDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw NativeRPCError(message: "This photo could not be opened.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw NativeRPCError(message: "This photo could not be prepared.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= limits.perImageBytes else { throw NativeRPCError(message: "The prepared photo exceeds the per-photo size limit.") }
        return output as Data
    }
}
