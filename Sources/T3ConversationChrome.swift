import SwiftUI
import UIKit

// MARK: Floating status capsule (T3 floating-working-control)

/// Real conversation state only, in T3's priority: connection, loading, a
/// pending interaction that blocks the agent, working. No timers or counts that
/// DSH does not report.
enum ConversationStatus: Equatable {
    case connecting(String)
    case unavailable(String)
    case loading(String)
    case waiting(String, symbol: String)
    case working

    var label: String {
        switch self {
        case .connecting(let text), .unavailable(let text), .loading(let text): return text
        case .waiting(let text, _): return text
        case .working: return "Working"
        }
    }
    var retryable: Bool { if case .unavailable = self { return true }; return false }
}

/// A 38.5pt capsule above the composer plus the jump-to-latest circle when the
/// person has left the end. Finite fades only; Reduce Motion removes them.
struct ConversationFloatingControl: View {
    let status: ConversationStatus?
    let showsLatest: Bool
    let retry: () -> Void
    let latest: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var textSize: CGFloat = 13

    var body: some View {
        HStack(spacing: T3Metric.steps(4)) {
            if let status { capsule(status).transition(.opacity) }
            if showsLatest { latestButton.transition(.opacity) }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: status)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsLatest)
    }

    @ViewBuilder private func capsule(_ status: ConversationStatus) -> some View {
        let content = HStack(spacing: T3Metric.steps(2)) {
            indicator(status)
            Text(status.label)
                .font(.system(size: textSize, weight: .medium))
                .foregroundStyle(DSHTheme.label)
                .lineLimit(1).truncationMode(.tail)
            if status.retryable {
                Text("Retry").font(.system(size: textSize, weight: .semibold)).foregroundStyle(DSHTheme.accent)
            }
        }
        .padding(.horizontal, T3Metric.steps(4))
        .frame(height: T3Metric.capsuleHeight)
        .background(ChatAppearance.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(ChatAppearance.border, lineWidth: 0.5))
        .shadow(color: ChatAppearance.shadow, radius: 6, y: 2)
        if status.retryable {
            Button(action: retry) { content.frame(minHeight: T3Metric.actionTarget).contentShape(Capsule()) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(status.label). Retry connection")
                .accessibilityIdentifier("conversation-status")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("conversation-status")
        }
    }

    @ViewBuilder private func indicator(_ status: ConversationStatus) -> some View {
        switch status {
        case .connecting, .loading:
            if reduceMotion { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold)).foregroundStyle(DSHTheme.tertiary) }
            else { ProgressView().controlSize(.mini) }
        case .unavailable:
            Circle().fill(DSHTheme.statusFailed).frame(width: 8, height: 8)
        case .waiting(_, let symbol):
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(DSHTheme.statusAttention)
        case .working:
            Circle().fill(DSHTheme.statusWorking).frame(width: 8, height: 8)
        }
    }

    private var latestButton: some View {
        Button(action: latest) {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DSHTheme.label)
                .frame(width: T3Metric.capsuleHeight, height: T3Metric.capsuleHeight)
                .background(ChatAppearance.surface, in: Circle())
                .overlay(Circle().strokeBorder(ChatAppearance.border, lineWidth: 0.5))
                .shadow(color: ChatAppearance.shadow, radius: 6, y: 2)
                .frame(width: T3Metric.actionTarget, height: T3Metric.actionTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Latest messages")
        .accessibilityIdentifier("latest-messages")
    }
}

// MARK: Composer controls (T3 ComposerToolbar)

/// 30pt circle inside a 44pt target. Primary uses DeepSeek blue; Stop uses the
/// DSH failed tone. Disabled is a faint blue well, not a gray guess.
struct ComposerActionGlyph: View {
    enum Kind { case send, steer, queue, stop, sending }
    let kind: Kind
    let disabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(fill)
            switch kind {
            case .sending:
                if reduceMotion { Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white) }
                else { ProgressView().controlSize(.small).tint(.white) }
            default:
                Image(systemName: symbol)
                    .font(.system(size: kind == .stop ? 12 : 15, weight: .semibold))
                    .foregroundStyle(disabled ? DSHTheme.accent.opacity(0.55) : .white)
            }
        }
        .frame(width: T3Metric.actionCircle, height: T3Metric.actionCircle)
        .frame(width: T3Metric.actionTarget, height: T3Metric.actionTarget)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch kind {
        case .send, .sending: return "arrow.up"
        case .steer: return "arrow.turn.left.up"
        case .queue: return "list.number"
        case .stop: return "stop.fill"
        }
    }

    private var fill: Color {
        if kind == .stop { return ChatAppearance.danger }
        if kind == .sending { return DSHTheme.accent.opacity(0.6) }
        return disabled ? DSHTheme.accent.opacity(0.15) : DSHTheme.accent
    }
}

/// T3 `ComposerInlineControl`: the actual selected model name with a chevron,
/// h-11 (38.5pt) visual inside the 44pt toolbar row.
struct ComposerModelLabel: View {
    let title: String
    @ScaledMetric(relativeTo: .subheadline) private var textSize: CGFloat = 14
    var body: some View {
        HStack(spacing: T3Metric.steps(2)) {
            Text(title)
                .font(.system(size: textSize, weight: .medium))
                .foregroundStyle(DSHTheme.label)
                .lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DSHTheme.secondary)
        }
        .padding(.horizontal, T3Metric.steps(2))
        .frame(height: T3Metric.inlineControlHeight)
        .frame(height: T3Metric.actionTarget)
        .contentShape(Rectangle())
    }
}

struct ComposerInlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: T3Metric.steps(3), style: .continuous)
                    .fill(configuration.isPressed ? ChatAppearance.subtle : .clear)
                    .frame(height: T3Metric.inlineControlHeight)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: Inline cards (T3 PendingApprovalCard / T3RequestButton)

struct T3RequestButton: View {
    enum Tone { case primary, danger, secondary }
    let title: String
    var tone: Tone = .primary
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .subheadline) private var textSize: CGFloat = 14

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: textSize, weight: tone == .primary ? .heavy : .bold))
                .foregroundStyle(tone == .secondary ? DSHTheme.label : .white)
                .padding(.horizontal, T3Metric.steps(3.5)).padding(.vertical, T3Metric.steps(3))
                .frame(minHeight: T3Metric.actionTarget)
                .background(background, in: RoundedRectangle(cornerRadius: T3Metric.controlRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: T3Metric.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var background: Color {
        switch tone {
        case .primary: return DSHTheme.accent
        case .danger: return ChatAppearance.danger
        case .secondary: return ChatAppearance.subtleStrong
        }
    }
}

/// Selected-session approval above the editor. Only the decisions the DSH
/// backend accepts here: Allow once (`allowed-once`) and Decline (`rejected`).
struct InlineApprovalCard: View {
    let card: ApprovalCard
    let remaining: Int
    @Environment(NativeStore.self) private var store
    @ScaledMetric(relativeTo: .caption) private var microSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var smallSize: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var bodySize: CGFloat = 14
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 18

    var body: some View {
        let deciding = store.deciding.contains(card.id)
        let shape = RoundedRectangle(cornerRadius: T3Metric.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: T3Metric.steps(2.5)) {
            Text(remaining > 0 ? "APPROVAL NEEDED · \(remaining + 1) PENDING" : "APPROVAL NEEDED")
                .font(.system(size: microSize, weight: .bold)).tracking(1.1)
                .foregroundStyle(DSHTheme.secondary)
            Text(card.tool)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(DSHTheme.label)
            Text(card.reason)
                .font(.system(size: bodySize))
                .foregroundStyle(DSHTheme.secondary)
                .lineLimit(8)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !store.connected {
                Text("Reconnect to your Mac to respond.").font(.system(size: smallSize)).foregroundStyle(DSHTheme.tertiary)
            }
            HStack(spacing: T3Metric.steps(2.5)) {
                T3RequestButton(title: "Allow once", tone: .primary) {
                    let decision = card
                    Task { await store.decide(decision, allow: true) }
                }
                .accessibilityIdentifier("approval-allow-\(card.id)")
                T3RequestButton(title: "Decline", tone: .danger) {
                    let decision = card
                    Task { await store.decide(decision, allow: false) }
                }
                .accessibilityIdentifier("approval-decline-\(card.id)")
                if deciding {
                    Text("Sending…").font(.system(size: smallSize)).foregroundStyle(DSHTheme.tertiary)
                }
                Spacer(minLength: 0)
            }
            .disabled(!store.connected || deciding)
        }
        .padding(T3Metric.steps(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatAppearance.card, in: shape)
        .overlay(shape.strokeBorder(ChatAppearance.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval-card-\(card.id)")
    }
}

/// Compact notice above the composer (delivery confirmation, photo import).
struct ComposerNotice<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: T3Metric.controlRadius, style: .continuous)
        VStack(alignment: .leading, spacing: T3Metric.steps(1.5), content: content)
            .padding(.horizontal, T3Metric.steps(4)).padding(.vertical, T3Metric.steps(3))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChatAppearance.card, in: shape)
            .overlay(shape.strokeBorder(ChatAppearance.border, lineWidth: 1))
    }
}
