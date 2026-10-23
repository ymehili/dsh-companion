import SwiftUI
import UIKit

/// Conversation-surface colors: DSH's own DeepSeek-blue/neutral-bluish palette
/// (DSHTheme) mapped onto the T3 Code mobile conversation hierarchy
/// (THIRD-PARTY-NOTICES.md). Replaces the former ChatGPT-style pure-black canvas
/// and indigo user bubble. Every color resolves for light/dark and Increase Contrast.
enum ChatAppearance {
    /// Conversation canvas (`--dsw-alias-bg-base`).
    static let canvas = DSHTheme.canvas
    /// Right-aligned user bubble (deepseek-50 / deepseek-900).
    static let userBubble = DSHTheme.userBubble
    static let userText = DSHTheme.label
    /// Composer, floating status capsule and latest-arrow surface (T3 composer-surface).
    static let surface = tone(light: 0xFFFFFF, dark: 0x212226, contrastLight: 0xFFFFFF, contrastDark: 0x2A2B30)
    /// Inline approval/question cards (T3 card-alt).
    static let card = tone(light: 0xF5F6F8, dark: 0x1D1E22, contrastLight: 0xECEEF2, contrastDark: 0x25262B)
    /// Option rows and inputs inside cards (T3 input).
    static let input = tone(light: 0xFFFFFF, dark: 0x27282D, contrastLight: 0xFFFFFF, contrastDark: 0x303137)
    /// Hairlines around composer, cards and capsules.
    static let border = DSHTheme.separator
    /// Pressed/inline-control fill (T3 subtle).
    static let subtle = DSHTheme.hover
    /// Thumbnail placeholders, +N chips, chevron wells (T3 subtle-strong).
    static let subtleStrong = tone(light: 0x0F1115, dark: 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.12)
    /// Destructive Stop/Decline (DSH failed tone, not a foreign red).
    static let danger = DSHTheme.statusFailed
    /// Composer shadow (T3 `shadow-[0_6px_28px] shadow-adaptive-black-a15-a35`).
    static let shadow = tone(light: 0x000000, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.35)

    private static func tone(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1,
                             contrastLight: UInt32? = nil, contrastDark: UInt32? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let highContrast = traits.accessibilityContrast == .high
            let hex = isDark ? (highContrast ? contrastDark ?? dark : dark) : (highContrast ? contrastLight ?? light : light)
            var alpha = isDark ? darkAlpha : lightAlpha
            if highContrast && alpha < 1 { alpha = min(1, alpha * 1.8) }
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }
}

/// T3 Code mobile geometry (upstream pin 2fae0f9). Uniwind rem is 14, so one
/// Tailwind spacing step is 3.5pt; bracketed upstream pixel values are literal.
enum T3Metric {
    static let step: CGFloat = 3.5
    static func steps(_ count: CGFloat) -> CGFloat { count * step }

    // ThreadComposer.tsx / ComposerToolbar.tsx explicit literals.
    static let composerHorizontalPadding: CGFloat = 12
    static let collapsedRadius: CGFloat = 27
    static let expandedRadius: CGFloat = 26
    static let expandedMinHeight: CGFloat = 140
    static let expandedPaddingTop: CGFloat = 14
    static let expandedPaddingBottom: CGFloat = 6
    static let collapsedPaddingVertical: CGFloat = 2
    static let collapsedEditorHeight: CGFloat = 36
    static let collapsedEditorInset: CGFloat = 4
    static let expandedEditorInset: CGFloat = 14
    static let expandedEditorMin: CGFloat = 72
    static let expandedEditorMax: CGFloat = 160
    static let editorVerticalPadding: CGFloat = 4
    static let toolbarHeight: CGFloat = 44
    static let actionTarget: CGFloat = 44
    static let actionCircle: CGFloat = 30
    static let attachmentTile: CGFloat = 72
    static let attachmentRadius: CGFloat = 16
    static let compactThumb: CGFloat = 30
    static let compactThumbRadius: CGFloat = 8

    // Tailwind-derived steps.
    static let inlineControlHeight = steps(11)   // h-11 = 38.5
    static let capsuleHeight = steps(11)         // floating-working-control CONTROL_HEIGHT
    static let capsuleGap: CGFloat = 8           // CONTROL_GAP
    static let workRowHeight: CGFloat = 28       // THREAD_WORK_ROW_MIN_HEIGHT
    static let workDetailMaxHeight = steps(60)   // max-h-60 = 210
    static let cardRadius: CGFloat = 20          // rounded-[20px]
    static let bubbleRadius: CGFloat = 20        // rounded-[20px]
    static let controlRadius = steps(4)          // rounded-2xl = 14
}

/// Changes placement, not TextField identity, when focus expands the composer.
/// Subviews, all unary and always present: attach, editor, compact thumbnails,
/// model control, send/stop. Native text editing, focus and keyboard stay with
/// SwiftUI/UIKit; only frames move.
///
/// Collapsed (T3 radius-27 pill): `[+ 44][editor 36 (4pt insets)][thumbs][send 44]`.
/// Expanded (radius 26, min 140): editor 72…160 with 14pt insets, a 3.5pt gap,
/// then a 44pt toolbar `[+] … [model ▾][send]`.
struct ChatComposerLayout: Layout {
    let expanded: Bool

    private func editorHeight(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        guard expanded else { return T3Metric.collapsedEditorHeight }
        let fit = subviews[1].sizeThatFits(ProposedViewSize(width: max(40, width - 2 * T3Metric.expandedEditorInset), height: nil)).height
        return min(max(fit, T3Metric.expandedEditorMin), T3Metric.expandedEditorMax)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        guard subviews.count == 5 else { return CGSize(width: width, height: T3Metric.toolbarHeight) }
        let height = expanded ? editorHeight(width, subviews) + T3Metric.steps(1) + T3Metric.toolbarHeight : T3Metric.toolbarHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let target = T3Metric.actionTarget
        let square = ProposedViewSize(width: target, height: target)
        let hidden = ProposedViewSize(width: 0, height: 0)
        if expanded {
            let editor = editorHeight(bounds.width, subviews)
            let toolbarY = bounds.minY + editor + T3Metric.steps(1)
            subviews[1].place(at: CGPoint(x: bounds.minX + T3Metric.expandedEditorInset, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: max(40, bounds.width - 2 * T3Metric.expandedEditorInset), height: editor))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: toolbarY), anchor: .topLeading, proposal: square)
            subviews[4].place(at: CGPoint(x: bounds.maxX - target, y: toolbarY), anchor: .topLeading, proposal: square)
            // T3 right-aligns the model control against the send action.
            let available = max(0, bounds.width - 2 * target)
            let model = subviews[3].sizeThatFits(ProposedViewSize(width: available, height: target))
            let modelWidth = min(model.width, available)
            subviews[3].place(at: CGPoint(x: bounds.maxX - target - modelWidth, y: toolbarY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: modelWidth, height: target))
            subviews[2].place(at: CGPoint(x: bounds.minX + target, y: toolbarY), anchor: .topLeading, proposal: hidden)
        } else {
            let thumbs = subviews[2].sizeThatFits(.unspecified)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: square)
            subviews[4].place(at: CGPoint(x: bounds.maxX - target, y: bounds.minY), anchor: .topLeading, proposal: square)
            subviews[2].place(at: CGPoint(x: bounds.maxX - target - thumbs.width, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: thumbs.width, height: thumbs.height))
            let editorX = bounds.minX + target + T3Metric.collapsedEditorInset
            let editorWidth = max(40, bounds.maxX - target - thumbs.width - T3Metric.collapsedEditorInset - editorX)
            subviews[1].place(at: CGPoint(x: editorX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: editorWidth, height: T3Metric.collapsedEditorHeight))
            subviews[3].place(at: CGPoint(x: bounds.maxX - target, y: bounds.midY), anchor: .center, proposal: hidden)
        }
    }
}

/// Proposes a fraction of the available width and right-aligns the child, so a
/// hugging bubble never exceeds T3's 85% while short text stays compact.
struct TrailingFractionLayout: Layout {
    var fraction: CGFloat = 0.85

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 * fraction }, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let limit = bounds.width * fraction
        let size = child.sizeThatFits(ProposedViewSize(width: limit, height: nil))
        child.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                    proposal: ProposedViewSize(width: min(size.width, limit), height: size.height))
    }
}
