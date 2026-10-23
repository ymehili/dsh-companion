import Foundation

/// Host-projected limits, bounded for a mobile client's memory/upload footprint.
struct PhotoLimits: Sendable {
    let maxCount: Int
    let perImageBytes: Int
    let totalBytes: Int
    let maxDimension: Int
    let acceptsJPEG: Bool
    init(_ wire: JSONValue = .null) {
        maxCount = min(20, max(1, wire["maxImagesPerMessage"].integer ?? 20))
        perImageBytes = min(8 * 1024 * 1024, max(1, wire["maxImageBytes"].integer ?? 8 * 1024 * 1024))
        totalBytes = min(32 * 1024 * 1024, max(1, wire["maxMessageImageBytes"].integer ?? 32 * 1024 * 1024))
        let pixelSide = Int(sqrt(Double(max(1, wire["maxImagePixels"].integer ?? 64_000_000))))
        maxDimension = min(1600, max(1, wire["maxImageDimension"].integer ?? 1600), pixelSide)
        let types = wire["mediaTypes"].array.compactMap(\.string)
        acceptsJPEG = types.isEmpty || types.contains("image/jpeg")
    }
    func validate(_ images: [Data]) throws {
        guard images.isEmpty || acceptsJPEG else { throw NativeRPCError(message: "This host does not accept JPEG photos.") }
        guard images.count <= maxCount else { throw NativeRPCError(message: "Attach at most \(maxCount) photos to this message.") }
        guard images.allSatisfy({ !$0.isEmpty && $0.count <= perImageBytes }) else { throw NativeRPCError(message: "A photo exceeds the \(perImageBytes / 1024 / 1024) MB per-photo limit.") }
        guard images.reduce(0, { $0 + $1.count }) <= totalBytes else { throw NativeRPCError(message: "Photos exceed the iPhone’s \(totalBytes / 1024 / 1024) MB total attachment limit. Remove a photo or choose smaller images.") }
    }
}
