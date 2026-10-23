import SwiftUI
import UIKit
import ImageIO

/// Expanded-composer attachment strip (T3 `ComposerAttachmentStrip`): 72pt
/// tiles, radius 16, 8.75pt gap, a 22pt remove badge with a 44pt hit target.
/// Photos are the store-owned session draft; this view only renders and asks
/// the store to remove or cancel.
struct PhotoAttachmentsView: View {
    let photos: [DraftPhoto]
    let loading: Bool
    let remove: (UUID) -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: T3Metric.steps(2.5)) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    DraftPhotoThumbnail(photo: photo, side: T3Metric.attachmentTile, radius: T3Metric.attachmentRadius)
                        .overlay(alignment: .topTrailing) {
                            RemoveBadge(label: "Remove photo \(index + 1)") { remove(photo.id) }
                                .accessibilityIdentifier("remove-photo-\(index)")
                        }
                }
                if loading {
                    RoundedRectangle(cornerRadius: T3Metric.attachmentRadius, style: .continuous)
                        .fill(ChatAppearance.subtleStrong)
                        .frame(width: T3Metric.attachmentTile, height: T3Metric.attachmentTile)
                        .overlay { LoadingGlyph(reduceMotion: reduceMotion) }
                        .overlay(alignment: .topTrailing) { RemoveBadge(label: "Cancel loading", action: cancel) }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Preparing photos")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: T3Metric.attachmentTile)
        .overlay(alignment: .topLeading) { AttachmentCountLabel(count: photos.count, loading: loading) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo-attachments")
    }
}

/// Collapsed-composer preview (T3 compact thumbnails): up to three 30pt tiles,
/// radius 8, 3.5pt gap, then a +N chip. Tapping focuses the editor, which
/// expands the composer to the editable strip. Removal stays explicit there.
struct CompactPhotoAttachments: View {
    let photos: [DraftPhoto]
    let loading: Bool
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var chipSize: CGFloat = 12

    var body: some View {
        Button(action: open) {
            HStack(spacing: T3Metric.steps(1)) {
                ForEach(photos.prefix(3)) { photo in
                    DraftPhotoThumbnail(photo: photo, side: T3Metric.compactThumb, radius: T3Metric.compactThumbRadius)
                }
                if photos.count > 3 {
                    Text("+\(photos.count - 3)")
                        .font(.system(size: chipSize, weight: .bold)).monospacedDigit()
                        .foregroundStyle(DSHTheme.secondary)
                        .frame(width: T3Metric.compactThumb, height: T3Metric.compactThumb)
                        .background(ChatAppearance.subtleStrong, in: RoundedRectangle(cornerRadius: T3Metric.steps(2), style: .continuous))
                }
                if loading {
                    RoundedRectangle(cornerRadius: T3Metric.compactThumbRadius, style: .continuous)
                        .fill(ChatAppearance.subtleStrong)
                        .frame(width: T3Metric.compactThumb, height: T3Metric.compactThumb)
                        .overlay { LoadingGlyph(reduceMotion: reduceMotion).controlSize(.mini) }
                }
            }
            .padding(.leading, T3Metric.steps(1))
            .frame(height: T3Metric.actionTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AttachmentCountLabel.text(count: photos.count, loading: loading))
        .accessibilityHint("Opens the message editor to review or remove photos")
        .accessibilityIdentifier("compact-attachments")
        .overlay(alignment: .topLeading) { AttachmentCountLabel(count: photos.count, loading: loading) }
    }
}

/// Keeps the established `attachment-count` static-text element in both
/// composer states without adding a visible label T3 does not show.
private struct AttachmentCountLabel: View {
    let count: Int
    let loading: Bool
    static func text(count: Int, loading: Bool) -> String {
        let base = "\(count) \(count == 1 ? "photo" : "photos") attached"
        return loading ? base + ", preparing more" : base
    }
    var body: some View {
        Text(Self.text(count: count, loading: loading))
            .font(.caption2).foregroundStyle(.clear)
            .frame(width: 1, height: 1).clipped()
            .allowsHitTesting(false)
            .accessibilityLabel(Self.text(count: count, loading: loading))
            .accessibilityIdentifier("attachment-count")
    }
}

private struct RemoveBadge: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.55), in: Circle())
                .padding(4)
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct LoadingGlyph: View {
    let reduceMotion: Bool
    var body: some View {
        if reduceMotion {
            Image(systemName: "photo.badge.arrow.down").foregroundStyle(DSHTheme.tertiary).accessibilityHidden(true)
        } else {
            ProgressView().accessibilityHidden(true)
        }
    }
}

/// Downsampled off the main thread; never decodes the full JPEG per render.
struct DraftPhotoThumbnail: View {
    let photo: DraftPhoto
    let side: CGFloat
    let radius: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(ChatAppearance.subtleStrong)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: side * 0.32)).foregroundStyle(DSHTheme.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .accessibilityHidden(true)
        .task(id: photo.id) {
            image = await DraftThumbnailCache.thumbnail(for: photo, pixels: Int((side * displayScale).rounded(.up)))
        }
    }
}

@MainActor private enum DraftThumbnailCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        return cache
    }()

    static func thumbnail(for photo: DraftPhoto, pixels: Int) async -> UIImage? {
        let key = "\(photo.id.uuidString)-\(pixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let data = photo.data
        let decoded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, pixels),
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        if let decoded, !Task.isCancelled { cache.setObject(decoded, forKey: key) }
        return decoded
    }
}
