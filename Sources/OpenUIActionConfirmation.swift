import SwiftUI

/// Explicit confirmation for a staged OpenUI card action. Shows the exact text that
/// will be sent, and only Send dispatches it — through the Store's immutable staged
/// text path, so the composer draft and its photos are never read, cleared or sent.
struct OpenUIActionConfirmation: View {
    let action: OpenUIStagedAction
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var issue: String?

    /// Why Send is unavailable right now, or nil when the store would accept it.
    private var blockedReason: String? {
        if store.selected?.id != action.sessionId { return "Open this conversation to send the card action." }
        if !store.connected { return "Reconnect to your Mac to send the card action." }
        if store.hasFailedMessage(action.sessionId) { return "Resolve the unconfirmed message in this conversation first." }
        if store.sending { return "Another message is still sending." }
        if !store.canSend { return "This conversation can’t receive messages right now." }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: T3Metric.steps(3)) {
                    Text("A card in this conversation wants to send this message to your agent. Nothing is sent until you tap Send.")
                        .font(.subheadline).foregroundStyle(DSHTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary = action.event.humanFriendlyMessage {
                        Text(summary).font(.headline).foregroundStyle(DSHTheme.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("openui-action-summary")
                    }
                    if !action.event.valuesSummary.isEmpty {
                        Text(action.event.valuesSummary)
                            .font(.subheadline).foregroundStyle(DSHTheme.label)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Form and context values")
                            .accessibilityIdentifier("openui-action-values")
                    }
                    DisclosureGroup("Details — exact message") {
                        Text(action.event.messageText)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(DSHTheme.label)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(T3Metric.steps(3))
                            .background(ChatAppearance.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ChatAppearance.border, lineWidth: 0.5))
                            .accessibilityLabel("Message to send")
                            .accessibilityValue(action.event.messageText)
                            .accessibilityIdentifier("openui-action-text")
                    }
                    .accessibilityIdentifier("openui-action-details")
                    Label("Your draft and photos stay in the composer.", systemImage: "square.and.pencil")
                        .font(.footnote).foregroundStyle(DSHTheme.tertiary)
                    if let note = issue ?? blockedReason {
                        Label(note, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(DSHTheme.statusAttention)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("openui-action-issue")
                    }
                }
                .padding()
            }
            .background(ChatAppearance.canvas)
            .navigationTitle("Send card action?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(sending).accessibilityIdentifier("openui-action-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() }
                    else {
                        Button("Send") { send() }
                            .disabled(blockedReason != nil)
                            .accessibilityIdentifier("openui-action-send")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(sending)
    }

    private func send() {
        guard !sending, blockedReason == nil else { return }
        sending = true; issue = nil
        let text = action.event.messageText, id = action.sessionId
        Task { @MainActor in
            let sent = await store.sendStagedText(text, for: id)
            sending = false
            // An unconfirmed or unsaved payload is retained by the Store; its Retry
            // lives in the conversation's delivery notice, so the sheet can close.
            if sent || store.failedMessageText(id) == text { dismiss() }
            else { issue = blockedReason ?? "The card action wasn’t sent. Check the conversation and try again." }
        }
    }
}
