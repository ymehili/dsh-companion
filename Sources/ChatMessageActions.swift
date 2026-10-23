import SwiftUI
import UIKit

struct ChatMessageActions: View {
    let text: String
    @State private var copied = false
    @State private var selectText = false
    var body: some View {
        HStack(spacing: 0) {
            Button {
                UIPasteboard.general.string = text; copied = true
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44) }
                .accessibilityLabel(copied ? "Copied" : "Copy response")
            ShareLink(item: text) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("Share response")
            Menu {
                Button("Select text", systemImage: "text.cursor") { selectText = true }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Response actions")
            Spacer(minLength: 0)
        }.font(.system(size: 15)).foregroundStyle(.secondary).buttonStyle(.borderless).tint(.secondary)
        .sheet(isPresented: $selectText) { ChatTextSelection(text: text) }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
        }
    }
}
