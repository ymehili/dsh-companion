import SwiftUI
import UIKit

/// Native DSH surfaces using the measured T3 mobile geometry. Source/license:
/// THIRD-PARTY-NOTICES.md. Colors and identity remain DeepSeek Harness's.
enum MobileSurface {
    static let groupRadius: CGFloat = 24
    static let sheet = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.08, blue: 0.095, alpha: 1)
            : UIColor(red: 0.95, green: 0.955, blue: 0.97, alpha: 1)
    })
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.115, green: 0.12, blue: 0.135, alpha: 1)
            : .white
    })
}

struct MobileSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content
    @ScaledMetric(relativeTo: .footnote) private var sectionSize: CGFloat = 14
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { Text(title).font(.system(size: sectionSize, weight: .medium)).foregroundStyle(DSHTheme.secondary).padding(.horizontal, 7) }
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity)
                .background(MobileSurface.card, in: RoundedRectangle(cornerRadius: MobileSurface.groupRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: MobileSurface.groupRadius, style: .continuous))
            if let footer { Text(footer).font(.system(size: sectionSize)).foregroundStyle(DSHTheme.secondary).padding(.horizontal, 14) }
        }
    }
}

struct MobileRow: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var subtitle: String? = nil
    var disclosure = true
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16
    @ScaledMetric(relativeTo: .footnote) private var detailSize: CGFloat = 14
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 10.5) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(DSHTheme.label).frame(width: 24)
            VStack(alignment: .leading, spacing: 3.5) {
                Text(title).font(.system(size: bodySize)).foregroundStyle(DSHTheme.label)
                if let subtitle { Text(subtitle).font(.system(size: detailSize)).foregroundStyle(DSHTheme.secondary) }
                if typeSize.isAccessibilitySize, let detail { Text(detail).font(.system(size: detailSize)).foregroundStyle(DSHTheme.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize, let detail { Text(detail).font(.system(size: detailSize)).foregroundStyle(DSHTheme.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .trailing) }
            if disclosure { Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(DSHTheme.tertiary) }
        }.padding(.horizontal, 14).padding(.vertical, 10.5).frame(minHeight: subtitle == nil ? 49 : 63).contentShape(Rectangle())
    }
}

struct MobilePage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14, content: content)
                .padding(.horizontal, 17.5).padding(.top, 14).padding(.bottom, 36)
        }.scrollDismissesKeyboard(.interactively).background(MobileSurface.sheet.ignoresSafeArea())
    }
}
