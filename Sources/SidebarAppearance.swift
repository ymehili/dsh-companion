import SwiftUI
import UIKit

/// T3 Code mobile thread-list metrics (Uniwind rem=14, so one spacing unit = 3.5pt)
/// rendered in the DSH palette. Display only; never changes shelf semantics.
enum SidebarAppearance {
    static let rail = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.085, alpha: 1) : UIColor(red: 0.95, green: 0.955, blue: 0.965, alpha: 1) })
    static let field = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.055) : UIColor(white: 1, alpha: 0.75) })
    static let selected = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.09) : UIColor(white: 0, alpha: 0.055) })
    /// T3 `bg-border-subtle` row hairline.
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.07) })
    static func workspaceTitle(_ value: String) -> String { value == "default-workspace" ? "Default workspace" : value }

    // MARK: Metrics (T3 px-5 py-2.5 rows, ml-5 hairline)

    static let brandWidth: CGFloat = 136
    static let brandHeight: CGFloat = 18
    /// px-5 = 5 × 3.5pt.
    static let leading: CGFloat = 17.5
    static let trailing: CGFloat = 17.5
    /// py-2.5 = 2.5 × 3.5pt.
    static let rowVertical: CGFloat = 8.75
    /// Slim settled/snoozed rows.
    static let slimRowHeight: CGFloat = 44
    static let radius: CGFloat = 10
    /// T3 settled shelf paging.
    static let settledInitial = 10
    static let settledPage = 25

    // MARK: Typography (text styles so Dynamic Type scales)

    /// Title: 16pt medium.
    static let titleFont: Font = .callout.weight(.medium)
    /// Project/workspace first line (13pt).
    static let projectFont: Font = .footnote
    static let metaFont: Font = .caption
    static let statusFont: Font = .caption.weight(.semibold)
    /// Shelf header label 13 medium.
    static let shelfFont: Font = .footnote.weight(.medium)

    // MARK: Status presentation (values come from DesktopInbox)

    static func isCompleted(_ status: String?) -> Bool {
        guard let status else { return false }
        return DSHTheme.statusTone(for: status) == .done
    }

    static func symbol(for status: String) -> String {
        let key = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("approval") { return "hand.raised.fill" }
        if key.hasPrefix("input") || key.hasPrefix("question") { return "questionmark.circle.fill" }
        if key.hasPrefix("limited") { return "hourglass" }
        if key.hasPrefix("woke") { return "bell.fill" }
        if key.hasPrefix("waiting") { return "clock" }
        switch DSHTheme.statusTone(for: status) {
        case .working: return "arrow.triangle.2.circlepath"
        case .attention: return "exclamationmark.circle.fill"
        case .input: return "questionmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle"
        case .neutral: return "circle"
        }
    }

    /// Compact relative time ("now", "5m", "3h", "2d", date) from a ms epoch; nil when unknown.
    static func timeLabel(_ updatedAtMs: Double, now: Date = Date()) -> String? {
        guard updatedAtMs > 0 else { return nil }
        let date = Date(timeIntervalSince1970: updatedAtMs / 1000)
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86400 { return "\(Int(s / 86400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func connectionColor(connected: Bool, status: String) -> Color {
        if connected { return DSHTheme.statusDone }
        let key = status.lowercased()
        if key.hasPrefix("authorization") { return DSHTheme.statusFailed }
        if key.hasPrefix("connecting") || key.hasPrefix("reconnecting") { return DSHTheme.statusAttention }
        return DSHTheme.tertiary
    }
}
