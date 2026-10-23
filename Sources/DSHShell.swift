import SwiftUI

/// Native phone tabs and push navigation. Session loading belongs to NativeStore,
/// so replacing a navigation view task cannot cancel the selected conversation.
struct DSHShell: View {
    @Environment(NativeStore.self) private var store
    @SceneStorage("dsh.lastSessionID") private var lastSessionID = ""
    @State private var selection: String?
    @State private var path: [String] = []
    @State private var restored = false
    @State private var showPairing = false
    @State private var showApprovals = false
    @State private var showQuestions = false
    @State private var showInfo = false
    @State private var showActivity = false
    @State private var showModels = false
    @State private var showSettings = false
    @State private var queueSessionID: String?
    @State private var showNewThread = false
    @State private var newThreadOrigin: String?
    @State private var newThreadCommitted = false
    private enum HomeTab: Hashable { case threads, compose }
    private var tabSelection: Binding<HomeTab> {
        Binding(get: { .threads }, set: { if $0 == .compose { newThread() } })
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                TabView(selection: tabSelection) {
                    Tab("Threads", systemImage: "text.bubble", value: HomeTab.threads) { threadStack }
                    Tab(value: HomeTab.compose, role: .search) { Color.clear } label: { Label("New chat", systemImage: "square.and.pencil") }
                }
            } else {
                TabView(selection: tabSelection) {
                    threadStack.tabItem { Label("Threads", systemImage: "text.bubble") }.tag(HomeTab.threads)
                    Color.clear.tabItem { Label("New chat", systemImage: "square.and.pencil") }.tag(HomeTab.compose)
                }
            }
        }
        .tint(DSHTheme.accent)
        .sheet(isPresented: Binding(get: { queueSessionID != nil }, set: { if !$0 { queueSessionID = nil } })) {
            if let id = queueSessionID {
                NavigationStack { MobileQueue(sessionId: id).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { queueSessionID = nil } } } }
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSettings) { MobileSettings().presentationDetents([.fraction(0.92), .large]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $showNewThread, onDismiss: restoreAfterNewThread) {
            MobileNewThread(onOpen: { id in
                newThreadCommitted = true; selection = id; showNewThread = false
            }).presentationDetents([.fraction(0.92), .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                NativePairing().navigationTitle("Pair iPhone").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close", systemImage: "xmark") { showPairing = false }.labelStyle(.iconOnly) } }
            }.presentationDetents([.fraction(0.92), .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showApprovals) { NativeApprovals() }
        .sheet(isPresented: $showQuestions) { NativeQuestionsSheet() }
        .sheet(isPresented: $showInfo) { DSHConversationInfo() }
        .sheet(isPresented: $showModels) { DSHModelPicker() }
        .sheet(isPresented: $showActivity) { if let id = store.selected?.id { ChatActivityView(sessionId: id) } }
        .alert("Couldn’t complete this action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: selection) { _, id in
            if let id { lastSessionID = id; if path.last != id { path = [id] } }
        }
        .onChange(of: path) { _, values in if values.isEmpty { selection = nil } }
        .onChange(of: store.sessions.map(\.id)) { _, ids in
            if let id = path.last, !ids.contains(id), store.localDraftRecords[id] == nil { path = []; selection = nil }
            if !restored, !ids.isEmpty {
                restored = true
                if !lastSessionID.isEmpty, ids.contains(lastSessionID) { selection = lastSessionID }
            }
        }
        .onChange(of: store.paired) { _, paired in if paired { showPairing = false } }
    }

    private var threadStack: some View {
        NavigationStack(path: $path) {
            Group {
                if store.paired || !store.localDraftRecords.isEmpty {
                    DSHSidebar(selection: $selection, onNew: newThread,
                               onPair: { showPairing = true }, onApprovals: { showApprovals = true },
                               onQuestions: { showQuestions = true }, onSettings: { showSettings = true })
                } else {
                    ContentUnavailableView {
                        Label("Connect your Mac", systemImage: "desktopcomputer")
                    } description: {
                        Text("Your agents and projects stay on your Mac. Pair this iPhone to pick up your work.")
                    } actions: {
                        Button("Pair this iPhone", systemImage: "qrcode.viewfinder") { showPairing = true }.buttonStyle(.borderedProminent)
                    }
                    .navigationTitle("Threads").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { showSettings = true } } }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let row = store.sessions.first(where: { $0.id == id }) {
                    NativeConversation(sessionId: id, draftWorkspaceTitle: store.unsentSessions.contains(id) ? store.workspaceState.title(for: id, cwd: row.cwd) : nil)
                        .navigationTitle(row.title)
                        .navigationBarTitleDisplayMode(.inline).toolbarRole(.editor)
                        .toolbar(.hidden, for: .tabBar)
                        .toolbar { threadHeader(id); sessionActions }
                        .task(id: id) {
                            guard path.last == id else { return }
                            await store.choose(row)
                        }
                } else {
                    NativeOfflineDraftEditor(sessionId: id).toolbar(.hidden, for: .tabBar)
                }
            }
        }
    }
    @ToolbarContentBuilder private func threadHeader(_ id: String) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.sessions.first(where: { $0.id == id })?.title ?? "Thread").font(.system(size: 17, weight: .bold)).lineLimit(1)
                if let row = store.sessions.first(where: { $0.id == id }) {
                    Text("\(store.workspaceState.title(for: id, cwd: row.cwd)) · Your Mac").font(.caption2).foregroundStyle(DSHTheme.secondary).lineLimit(1)
                }
            }.frame(maxWidth: 250, alignment: .leading)
        }
    }
    @ToolbarContentBuilder private var sessionActions: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                if let id = path.last {
                    Button("Queued messages", systemImage: "list.number") { queueSessionID = id }.accessibilityIdentifier("thread-queue-action")
                }
                Button("New thread", systemImage: "square.and.pencil", action: newThread)
                Button("Choose model", systemImage: "cpu") { showModels = true }.disabled(!store.connected).accessibilityIdentifier("session-model-action")
                Button("Activity & trajectory", systemImage: "waveform.path") { showActivity = true }
                Button("Thread details", systemImage: "info.circle") { showInfo = true }
                if store.conversation.running { Button("Stop agent", systemImage: "stop.fill", role: .destructive) { Task { await store.stop() } }.disabled(!store.connected) }
                Button("Questions (\(store.questions.count))", systemImage: "questionmark.bubble") { showQuestions = true }
                Button("Approvals (\(store.approvals.count))", systemImage: "hand.raised") { showApprovals = true }
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            } label: { Label("Session actions", systemImage: "ellipsis") }
        }
    }
    private func newThread() {
        guard store.paired else { showPairing = true; return }
        newThreadOrigin = store.selected?.id; newThreadCommitted = false; showNewThread = true
    }
    private func restoreAfterNewThread() {
        guard !newThreadCommitted else { return }
        if let previous = newThreadOrigin, let row = store.sessions.first(where: { $0.id == previous }) { Task { await store.choose(row) } }
        else { store.clearSelectionForSidebar() }
    }
}
