import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Loads historical images only via the authenticated, session-scoped RPC.
/// Deliberately not Equatable: environment and task identity must remain live.
struct ChatAttachmentImage: View {
    let reference: ChatImageReference
    let sessionId: String
    @Environment(NativeStore.self) private var store
    @State private var loaded: LoadedChatImage?
    @State private var failed = false
    @State private var retry = 0
    @State private var generation = UUID()
    @State private var displayedKey: LoadKey?

    private struct LoadKey: Equatable, Sendable {
        let authorizationScope: UUID
        let sessionId: String
        let reference: ChatImageReference
        let maxBytes: Int
        let retry: Int
    }
    private var key: LoadKey {
        // Read the projection for this session, not a potentially different selection.
        let host = store.desktopProjections[sessionId]?["imageLimits"]["maxImageBytes"].integer ?? 8 * 1024 * 1024
        return LoadKey(authorizationScope: store.imageAuthorizationScope, sessionId: sessionId, reference: reference,
                       maxBytes: min(max(0, host), 20 * 1024 * 1024), retry: retry)
    }
    private var label: String {
        "\(reference.name ?? "Image attachment"), \(reference.width) by \(reference.height) pixels"
    }
    private var ratio: CGFloat {
        min(3, max(0.4, CGFloat(reference.width) / CGFloat(max(1, reference.height))))
    }

    var body: some View {
        let current = key
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.secondary.opacity(0.1))
            if displayedKey == current, let loaded {
                Image(uiImage: loaded.image)
                    .resizable().scaledToFit()
                    .accessibilityLabel(label).accessibilityIdentifier("loaded-chat-image")
            } else if displayedKey == current, failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Image unavailable").font(.caption)
                    Button("Retry") { retry += 1 }
                        .accessibilityLabel("Retry \(reference.name ?? "image attachment")")
                }
            } else {
                ProgressView("Loading image…").font(.caption)
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: 360)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .task(id: current) { await load(current) }
        .onDisappear { generation = UUID() }
    }

    @MainActor private func load(_ key: LoadKey) async {
        let token = UUID()
        generation = token
        displayedKey = key
        loaded = nil
        failed = false
        do {
            try Task.checkCancellation()
            guard !key.sessionId.isEmpty, key.reference.bytes > 0,
                  key.reference.bytes <= key.maxBytes,
                  ChatImageDecoder.allowedTypes[key.reference.mediaType] != nil else { throw ImageFailure.invalid }
            ChatImageCache.shared.retainAuthorizationScope(key.authorizationScope)
            let cacheKey = ChatImageCache.Key(authorizationScope: key.authorizationScope, sessionId: key.sessionId, attachmentId: key.reference.attachmentId)
            if let cached = ChatImageCache.shared.value(for: cacheKey, reference: key.reference, maxBytes: key.maxBytes) {
                guard generation == token, !Task.isCancelled else { return }
                loaded = cached
                return
            }
            let response = try await store.gateway.rpc("session/attachment", .obj([
                "args": .obj(["request": .obj([
                    "sessionId": .text(key.sessionId), "attachmentId": .text(key.reference.attachmentId)
                ])])
            ]))
            try Task.checkCancellation()
            guard let returned = ChatImageReference(attachment: response["attachment"], contentIndex: key.reference.contentIndex),
                  returned.attachmentId == key.reference.attachmentId,
                  returned.mediaType == key.reference.mediaType,
                  returned.bytes == key.reference.bytes,
                  returned.width == key.reference.width, returned.height == key.reference.height,
                  returned.bytes <= key.maxBytes,
                  let base64 = response["data"].string else { throw ImageFailure.invalid }
            let worker = Task.detached(priority: .utility) {
                try ChatImageDecoder.decode(base64, reference: returned, maxBytes: key.maxBytes)
            }
            let decoded = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard generation == token, key.authorizationScope == store.imageAuthorizationScope else { return }
            ChatImageCache.shared.insert(decoded, for: cacheKey, reference: returned)
            loaded = decoded
        } catch {
            // Never surface server messages (which can contain private identifiers).
            guard generation == token, !Task.isCancelled else { return }
            failed = true
        }
    }
}

private enum ImageFailure: Error { case invalid }

/// Immutable decoded thumbnail crosses the worker boundary; UIKit image is never mutated.
struct LoadedChatImage: @unchecked Sendable {
    let image: UIImage
    let cost: Int
}

enum ChatImageDecoder {
    static let allowedTypes = ["image/jpeg": UTType.jpeg.identifier, "image/png": UTType.png.identifier,
                               "image/webp": UTType.webP.identifier, "image/gif": UTType.gif.identifier]
    static func decode(_ base64: String, reference: ChatImageReference, maxBytes: Int) throws -> LoadedChatImage {
        try Task.checkCancellation()
        let limit = min(maxBytes, 20 * 1024 * 1024)
        guard reference.bytes > 0, reference.bytes <= limit,
              let expectedType = allowedTypes[reference.mediaType] else { throw ImageFailure.invalid }
        // Strict plain base64: reject whitespace/data URLs and bound before allocation.
        let count = base64.utf8.count
        guard count == ((reference.bytes + 2) / 3) * 4,
              let data = Data(base64Encoded: base64), data.count == reference.bytes,
              data.count <= limit else { throw ImageFailure.invalid }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), type as String == expectedType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              // Bound hostile/decompression-heavy sources independently of compressed size.
              width.doubleValue <= 100_000, height.doubleValue <= 100_000,
              width.doubleValue * height.doubleValue <= 100_000_000,
              width.intValue == reference.width, height.intValue == reference.height,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1440,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageFailure.invalid }
        try Task.checkCancellation()
        return LoadedChatImage(image: UIImage(cgImage: thumbnail), cost: thumbnail.bytesPerRow * thumbnail.height)
    }
}

/// No disk cache, credentials, URL keys or global in-flight work. LRU bounded by
/// decoded bytes and entry count; keyed by store authorization epoch + session + attachment ID.
@MainActor private final class ChatImageCache {
    struct Key: Hashable { let authorizationScope: UUID; let sessionId: String; let attachmentId: String }
    private var authorizationScope: UUID?
    func retainAuthorizationScope(_ scope: UUID) {
        guard authorizationScope != scope else { return }
        entries.removeAll(); order.removeAll(); cost = 0; authorizationScope = scope
    }
    private struct Entry {
        let image: LoadedChatImage
        let reference: ChatImageReference
    }
    static let shared = ChatImageCache()
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var cost = 0
    private let limit = 32 * 1024 * 1024

    func value(for key: Key, reference: ChatImageReference, maxBytes: Int) -> LoadedChatImage? {
        guard let entry = entries[key], entry.reference.attachmentId == reference.attachmentId,
              entry.reference.mediaType == reference.mediaType, entry.reference.bytes == reference.bytes,
              entry.reference.width == reference.width, entry.reference.height == reference.height,
              reference.bytes <= maxBytes else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return entry.image
    }
    func insert(_ image: LoadedChatImage, for key: Key, reference: ChatImageReference) {
        if let old = entries.removeValue(forKey: key) { cost -= old.image.cost }
        order.removeAll { $0 == key }
        guard image.cost <= limit else { return }
        while cost + image.cost > limit || entries.count >= 24 {
            guard !order.isEmpty else { break }
            let oldest = order.removeFirst()
            if let old = entries.removeValue(forKey: oldest) { cost -= old.image.cost }
        }
        entries[key] = Entry(image: image, reference: reference)
        order.append(key); cost += image.cost
    }
}
