import SwiftUI
import UIKit
#if canImport(SwiftTerm)
import SwiftTerm
#endif

struct MobileTerminalSurface: View {
    let controller: MobileTerminalController
    let fontSize: CGFloat
    @Environment(NativeStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        #if canImport(SwiftTerm)
        MobileTerminalVTView(controller: controller, fontSize: fontSize, steadyCursor: reduceMotion || store.usesFixture)
            .id(controller.renderGeneration)
        #else
        ContentUnavailableView("Terminal renderer unavailable", systemImage: "terminal", description: Text("This build needs the official SwiftTerm package. No plain-text substitute is used for a VT terminal."))
        #endif
    }
}

#if canImport(SwiftTerm)
/// Official SwiftTerm v1.11.0 iOS API. The view owns only VT rendering and
/// keyboard focus; its lifetime is independent from the remote shell process.
private struct MobileTerminalVTView: UIViewRepresentable {
    let controller: MobileTerminalController
    let fontSize: CGFloat
    let steadyCursor: Bool
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
        terminal.terminalDelegate = context.coordinator
        terminal.nativeBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.045, green: 0.05, blue: 0.065, alpha: 1) : UIColor(red: 0.97, green: 0.975, blue: 0.985, alpha: 1) }
        terminal.nativeForegroundColor = .label
        terminal.accessibilityLabel = "Terminal input and output"
        terminal.accessibilityIdentifier = "terminal-native-vt"
        let toolbar = UIToolbar(); toolbar.sizeToFit()
        let items: [(String, String)] = [("Esc", "\u{1B}"), ("Ctrl", ""), ("Tab", "\t"), ("←", "\u{1B}[D"), ("↓", "\u{1B}[B"), ("↑", "\u{1B}[A"), ("→", "\u{1B}[C")]
        toolbar.items = items.map { label, value in
            UIBarButtonItem(title: label, primaryAction: UIAction { [weak owner = context.coordinator, weak terminal, weak toolbar] _ in
                guard let owner else { return }
                if label == "Ctrl" { owner.controller.control.toggle() }
                else {
                    let isArrow = ["←", "↓", "↑", "→"].contains(label)
                    let sequence = isArrow && terminal?.getTerminal().applicationCursor == true ? value.replacingOccurrences(of: "[", with: "O") : value
                    owner.controller.write(sequence)
                }
                toolbar?.items?[1].tintColor = owner.controller.control ? .systemOrange : nil
            })
        } + [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(title: "Done", primaryAction: UIAction { [weak terminal] _ in terminal?.resignFirstResponder() })]
        terminal.inputAccessoryView = toolbar
        return terminal
    }
    func updateUIView(_ terminal: TerminalView, context: Context) {
        if terminal.font.pointSize != fontSize { terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        let coordinator = context.coordinator
        if coordinator.consumed < controller.renderChunks.count {
            for chunk in controller.renderChunks.dropFirst(coordinator.consumed) { terminal.feed(text: chunk) }
            coordinator.consumed = controller.renderChunks.count
        }
        if steadyCursor, terminal.getTerminal().options.cursorStyle != .steadyBlock { terminal.getTerminal().setCursorStyle(.steadyBlock) }
        // Output remains selectable and scrollable in read-only mode. Delegate
        // gates all uplink; no focus is grabbed automatically on attachment.
        terminal.inputAccessoryView?.isUserInteractionEnabled = controller.canInput
        if !controller.canInput { terminal.resignFirstResponder() }
    }
    static func dismantleUIView(_ terminal: TerminalView, coordinator: Coordinator) {
        terminal.terminalDelegate = nil; terminal.resignFirstResponder()
    }
    final class Coordinator: NSObject, TerminalViewDelegate {
        let controller: MobileTerminalController
        var consumed = 0
        init(_ controller: MobileTerminalController) { self.controller = controller }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // UIKit input and our VT feed both run on the main actor. Preserve
            // callback order instead of spawning reorderable Tasks per keystroke.
            MainActor.assumeIsolated { controller.write(String(decoding: data, as: UTF8.self)) }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // UIKit/SwiftTerm layout can call during representable updates.
            Task { @MainActor [weak self] in self?.controller.resize(cols: newCols, rows: newRows) }
        }
        func setTerminalTitle(source: TerminalView, title: String) {} // OSC is not a host rename request.
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {} // Remote OSC never opens arbitrary URLs.
        func clipboardCopy(source: TerminalView, content: Data) {} // No unsolicited OSC clipboard write.
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
#endif
