import SwiftUI
import UIKit

/// Read-only native selection surface; never opens the keyboard or changes a draft.
struct ChatTextSelection: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SelectableChatText(text: text)
                .navigationTitle("Select text").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Copy all", systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
                }
        }
    }
}
private struct SelectableChatText: UIViewRepresentable {
    let text: String
    final class Coordinator { var source: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .systemBackground
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.dataDetectorTypes = []
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 28, right: 16)
        view.accessibilityIdentifier = "chat-selectable-text"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        guard context.coordinator.source != text else { return }
        context.coordinator.source = text
        view.text = text
    }
}
