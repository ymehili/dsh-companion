import SwiftUI

/// Creates an empty host session only after a workspace is chosen. No agent turn
/// starts until the user presses Send in the real, session-scoped composer.
struct MobileNewThread: View {
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onOpen: (String) -> Void
    @State private var query = ""
    @State private var draftID: String?
    @State private var chosenTitle = "Default workspace"
    private var workspaces: [(path: String, title: String)] {
        var seen: Set<String> = []
        var result: [(path: String, title: String)] = []
        let ids = store.workspaceState.order + store.workspaceState.items.keys.filter { !store.workspaceState.order.contains($0) }.sorted()
        for item in ids.compactMap({ store.workspaceState.items[$0] }) {
            if let path = item["path"].string, !path.isEmpty, seen.insert(path).inserted {
                result.append((path, item["title"].string ?? URL(fileURLWithPath: path).lastPathComponent))
            }
        }
        for row in store.sessions where !row.cwd.isEmpty && !row.isSubagent {
            if seen.insert(row.cwd).inserted { result.append((row.cwd, store.workspaceState.title(for: row.id, cwd: row.cwd))) }
        }
        return result.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            Group {
                if let id = draftID {
                    NativeConversation(sessionId: id, draftWorkspaceTitle: chosenTitle)
                        .task(id: id) {
                            if let row = store.sessions.first(where: { $0.id == id }) { await store.choose(row) }
                        }
                        .onChange(of: store.conversation.entries.count) { _, _ in
                            if store.selected?.id == id, store.conversation.entries.contains(where: { $0.role == "user" }) { onOpen(id) }
                        }
                } else {
                    MobilePage {
                        if !store.connected { Label("Reconnect to your Mac to start a thread", systemImage: "wifi.slash").font(.footnote).foregroundStyle(DSHTheme.secondary) }
                        MobileSection(title: "Workspaces", footer: "Projects already present on your Mac. A new thread stays empty until you send a message.") {
                            ForEach(workspaces, id: \.path) { workspace in
                                Button { choose(workspace.path, title: workspace.title) } label: {
                                    MobileRow(title: workspace.title, symbol: "folder", subtitle: workspace.path)
                                }.buttonStyle(.plain).disabled(!store.connected || store.busy)
                                    .accessibilityIdentifier("new-thread-workspace-\(workspace.path)")
                            }
                            if query.isEmpty {
                                Button { choose(nil, title: "Default workspace") } label: {
                                    MobileRow(title: "Mac default workspace", symbol: "desktopcomputer", subtitle: "Use your Mac’s default location")
                                }.buttonStyle(.plain).disabled(!store.connected || store.busy)
                                    .accessibilityIdentifier("new-thread-default-workspace")
                            }
                        }
                        NavigationLink { MobileProjects(onChoose: { choose($0.path, title: $0.title) }) } label: {
                            MobileRow(title: "Manage projects", symbol: "folder.badge.plus", subtitle: "Register an existing directory on your Mac")
                        }.accessibilityIdentifier("new-thread-manage-projects")
                        if store.busy { ProgressView("Creating thread…").frame(maxWidth: .infinity) }
                    }
                    .searchable(text: $query, prompt: "Search projects")
                }
            }
            .navigationTitle(draftID == nil ? "Choose project" : "New thread").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { cancel() }.accessibilityIdentifier("new-thread-cancel") }
                ToolbarItem(placement: .topBarTrailing) {
                    if let id = draftID { Button("Open thread") { onOpen(id) }.accessibilityIdentifier("new-thread-open") }
                }
            }
        }.tint(DSHTheme.accent).accessibilityIdentifier("new-thread-sheet")
            .interactiveDismissDisabled(draftID != nil)
    }
    private func choose(_ cwd: String?, title: String) {
        Task { @MainActor in
            if let id = await store.create(workspace: cwd, inheritCurrentWorkspace: false) { store.markUnsentDraft(id); chosenTitle = title; draftID = id }
        }
    }
    private func cancel() {
        Task { @MainActor in
            if let id = draftID { await store.leaveNewDraft(id) }
            dismiss()
        }
    }
}

struct MobileDraftHero: View {
    let workspace: String
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 26
    var body: some View {
        VStack(spacing: 8) {
            Text("What should we build\nin \(workspace)?").font(.system(size: size, weight: .medium)).multilineTextAlignment(.center)
            Label("on Your Mac", systemImage: "desktopcomputer").font(.callout).foregroundStyle(DSHTheme.secondary)
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 72).padding(.bottom, 236)
            .accessibilityIdentifier("new-thread-hero")
    }
}
