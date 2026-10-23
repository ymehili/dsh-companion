import SwiftUI

/// Session-scoped, user-initiated terminal screen. Merely opening the screen lists
/// existing shells; it never creates a shell, resumes an Agent, or attaches one.
struct MobileTerminal: View {
    let sessionId: String
    @Environment(NativeStore.self) private var store
    @State private var controller: MobileTerminalController?
    var body: some View {
        Group {
            if let controller { MobileTerminalScreen(controller: controller) }
            else { ProgressView("Loading terminals…") }
        }
        .navigationTitle("Terminal").navigationBarTitleDisplayMode(.inline)
        .tint(DSHTheme.accent)
        .task(id: sessionId) {
            if controller?.sessionId != sessionId {
                await controller?.disconnect()
                let service: any MobileTerminalService = store.usesFixture ? MobileTerminalFixtureService() : MobileTerminalNativeService(store)
                controller = MobileTerminalController(sessionId: sessionId, service: service)
                await controller?.refresh()
            }
        }
        .onDisappear { let owner = controller; Task { await owner?.disconnect() } }
    }
}

private struct MobileTerminalScreen: View {
    @Bindable var controller: MobileTerminalController
    @State private var createWarning = false
    @State private var closeWarning = false
    @State private var renameSheet = false
    @State private var title = ""
    @State private var fontSize: CGFloat = 13
    @Environment(NativeStore.self) private var store
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(controller.terminals) { terminal in
                        Button { Task { await controller.select(terminal) } } label: {
                            Label(terminal.title, systemImage: terminal.id == controller.selected?.id ? "checkmark" : "terminal")
                        }.accessibilityIdentifier("terminal-select-\(terminal.id)")
                    }
                    Divider()
                    Button("Refresh shells", systemImage: "arrow.clockwise") { Task { await controller.refresh() } }
                    Button(controller.pendingCreationID == nil ? "New terminal…" : "Retry new terminal…", systemImage: "plus") { createWarning = true }
                } label: {
                    HStack { Image(systemName: "terminal"); Text(controller.selected?.title ?? "Select terminal").lineLimit(1); Image(systemName: "chevron.down").font(.caption) }
                }.accessibilityIdentifier("terminal-selector")
                Spacer(minLength: 0)
                Menu {
                    Button("Smaller text", systemImage: "textformat.size.smaller") { fontSize = max(9, fontSize - 1) }
                    Button("Larger text", systemImage: "textformat.size.larger") { fontSize = min(24, fontSize + 1) }
                    Button("Rename…", systemImage: "pencil") { title = controller.selected?.title ?? ""; renameSheet = true }.disabled(controller.selected == nil)
                    Button("Disconnect", systemImage: "bolt.slash") { Task { await controller.disconnect() } }.disabled(!controller.connected)
                    Button("Close shell…", systemImage: "xmark.circle", role: .destructive) { closeWarning = true }.disabled(controller.selected == nil)
                } label: { Image(systemName: "ellipsis.circle").frame(width: 36, height: 36) }.accessibilityLabel("Terminal options")
            }.font(.subheadline).padding(.horizontal, 17.5).padding(.vertical, 8).background(MobileSurface.card)
            HStack {
                Circle().fill(controller.canInput ? Color.green : DSHTheme.tertiary).frame(width: 6, height: 6)
                Text(controller.status)
                if let selected = controller.selected { Text("· \(selected.shell.name)").lineLimit(1) }
                Spacer()
                if controller.selected != nil && !controller.connected {
                    Button("Reattach") { Task { await controller.retryAttachment() } }.accessibilityIdentifier("terminal-reattach")
                }
            }.font(.caption).foregroundStyle(DSHTheme.secondary).padding(.horizontal, 17.5).padding(.vertical, 8)
            if let issue = controller.issue {
                Text(issue).font(.footnote).foregroundStyle(DSHTheme.label).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(MobileSurface.card)
                    .accessibilityIdentifier("terminal-error")
            }
            if controller.selected != nil {
                MobileTerminalSurface(controller: controller, fontSize: fontSize)
                    .accessibilityIdentifier("terminal-surface")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: "terminal").font(.system(size: 38)).foregroundStyle(DSHTheme.accent)
                        Text("Your Mac’s terminal").font(.title2.weight(.semibold))
                        Text("Select an existing shell, or explicitly create a new one. Leaving this screen disconnects the display without stopping the shell.").foregroundStyle(DSHTheme.secondary)
                        ForEach(controller.terminals) { terminal in
                            Button { Task { await controller.select(terminal) } } label: {
                                MobileRow(title: terminal.title, symbol: "terminal", detail: terminal.state.rawValue, subtitle: terminal.cwd)
                            }.buttonStyle(.plain).background(MobileSurface.card, in: RoundedRectangle(cornerRadius: 24))
                                .accessibilityIdentifier("terminal-open-\(terminal.id)")
                        }
                        Button { createWarning = true } label: { Label(controller.pendingCreationID == nil ? "New terminal" : "Retry new terminal", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).disabled(controller.creating).accessibilityIdentifier("terminal-new")
                        if controller.busy { ProgressView() }
                    }.padding(17.5)
                }
            }
            if store.usesFixture { Text("DEMO · synthetic terminal · no host commands").font(.caption2).foregroundStyle(DSHTheme.secondary).padding(6) }
        }.background(MobileSurface.sheet)
        .alert("Start an unsandboxed shell?", isPresented: $createWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Create shell", role: .destructive) { Task { await controller.createConfirmed() } }
        } message: { Text("This starts a real user shell on your Mac outside the Agent sandbox and approval restrictions. Anything you type runs with your Mac user’s permissions. No command will be sent automatically.") }
        .alert("Close this shell?", isPresented: $closeWarning) {
            Button("Keep running", role: .cancel) {}
            Button("Kill shell", role: .destructive) { Task { await controller.closeConfirmed() } }
        } message: { Text("This terminates the real process and its running commands. To leave it running, go back or choose Disconnect instead.") }
        .alert("Rename terminal", isPresented: $renameSheet) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await controller.rename(title) } }
        }
    }
}
