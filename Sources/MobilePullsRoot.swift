import SwiftUI

/// Public Pulls tab root; owns its NavigationStack. Requires .environment(NativeStore).
/// No session is selected or scanned implicitly. The user chooses a project and explicitly opens it.
public struct MobilePullsRoot: View {
    @Environment(NativeStore.self) private var store
    @State private var projectSession: String?
    public init() {}
    private var projects: [SessionRow] {
        var seen = Set<String>()
        return store.sessions.filter { !$0.isSubagent && !store.workspaceState.archived.contains($0.id) && !$0.cwd.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.cwd).inserted }
    }
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Project", selection: $projectSession) {
                        Text("Choose project…").tag(String?.none)
                        ForEach(projects) { row in Text(store.workspaceState.title(for: row.id, cwd: row.cwd)).tag(Optional(row.id)) }
                    }.accessibilityIdentifier("pulls-project-picker")
                    if let row = projects.first(where: { $0.id == projectSession }) {
                        NavigationLink { MobilePullProject(sessionId: row.id) } label: { Label("Open project pull requests", systemImage: "arrow.triangle.pull") }.accessibilityIdentifier("pulls-open-project")
                        Text(store.workspaceState.title(for: row.id, cwd: row.cwd)).font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Repository scope") } footer: { Text("Only this explicitly opened project is queried. No cross-project scans or automatic GitHub discovery.") }
                if projects.isEmpty { Section { ContentUnavailableView("No user projects", systemImage: "folder", description: Text("Open a workspace conversation first. Private repositories are never probed to populate this screen.")) } }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(MobileSurface.sheet)
                .navigationTitle("Pull Requests").tint(DSHTheme.accent)
                .accessibilityIdentifier("mobile-pulls-root")
        }
    }
}

struct MobilePullProject: View {
    let sessionId: String
    @Environment(NativeStore.self) private var store
    @State private var controller: MobileRepositoryController?
    var body: some View {
        Group {
            if let controller { MobilePullListScreen(controller: controller) }
            else { ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark", description: Text("This project must belong to an active user conversation.")) }
        }.navigationTitle("Pull Requests").navigationBarTitleDisplayMode(.inline)
            .task(id: sessionId) {
                guard store.sessions.contains(where: { $0.id == sessionId && !$0.isSubagent }), !store.workspaceState.archived.contains(sessionId) else { controller = nil; return }
                guard controller?.service.sessionId != sessionId else { return }
                let service: any MobileRepositoryServing
                if store.usesFixture { service = MobileRepositoryFixtureService(sessionId: sessionId) }
                else { service = MobileRepositoryService(sessionId: sessionId, transport: store.gateway) }
                let next = MobileRepositoryController(service: service); controller = next
                // Explicit project-open loads only local repository status. GitHub reads require the Open/Refresh button.
                await next.refresh()
            }
    }
}
struct MobilePullListScreen: View {
    @Bindable var controller: MobileRepositoryController
    @Environment(NativeStore.self) private var store
    @State private var list: MobilePullList?
    @State private var state = "open"
    @State private var query = ""
    @State private var drafts = "all"
    @State private var busy = false
    @State private var issue: String?
    @State private var creating = false
    private var rows: [MobilePullSummary] {
        (list?.items ?? []).filter {
            (query.isEmpty || "\($0.number) \($0.title) \($0.author)".localizedCaseInsensitiveContains(query)) && (drafts == "all" || (drafts == "draft" ? $0.draft : !$0.draft))
        }
    }
    var body: some View {
        List {
            MobileRepositoryIssue(controller: controller)
            Section {
                if let snapshot = controller.snapshot {
                    Text(snapshot.rootLabel).font(.headline)
                    if let repository = snapshot.github { Text("\(repository.owner)/\(repository.name)").font(.subheadline).foregroundStyle(.secondary) }
                    else { Text("No authorized GitHub repository was returned. Configure its remote and access on your Mac.").font(.footnote).foregroundStyle(.orange) }
                    Button(list == nil ? "Open pull requests" : "Refresh pull requests") { Task { await load() } }.disabled(busy || controller.busy || !snapshot.capabilities.github).accessibilityIdentifier("pulls-explicit-refresh")
                    NavigationLink("Repository and worktrees") { MobileRepositoryContent(controller: controller, returnWorkspace: nil).navigationTitle("Git") }
                } else { Button("Refresh repository setup") { Task { await controller.refresh() } }.disabled(controller.busy) }
                Picker("State", selection: $state) { Text("Open").tag("open"); Text("Closed").tag("closed"); Text("All").tag("all") }.pickerStyle(.segmented).accessibilityIdentifier("pulls-state-filter")
                Picker("Drafts", selection: $drafts) { Text("All pull requests").tag("all"); Text("Ready for review").tag("ready"); Text("Drafts").tag("draft") }.accessibilityIdentifier("pulls-draft-filter")
                Text("State changes take effect on your next explicit refresh. Search and draft filters run locally.").font(.caption).foregroundStyle(.secondary)
            }
            if busy { Section { ProgressView("Loading pull requests…") } }
            if let issue { Section { Text(issue).font(.footnote).foregroundStyle(.orange) } }
            if let list {
                Section("\(rows.count) pull requests") {
                    if rows.isEmpty { Text("No matching pull requests in the last explicitly loaded result.").foregroundStyle(.secondary) }
                    ForEach(rows) { item in
                        if let snapshot = controller.snapshot {
                            NavigationLink { MobilePullDetailScreen(controller: controller, snapshot: snapshot, number: item.number) } label: { MobilePullRow(item: item) }.accessibilityIdentifier("pulls-row-\(item.number)")
                        }
                    }
                    if list.hasMore { Text("First 100 results only. Refine the state/search filter or open GitHub explicitly from a pull request.").font(.footnote).foregroundStyle(.secondary) }
                }
            } else if !busy { Section { Text("GitHub has not been queried. Tap Open pull requests to request remote data.").font(.footnote).foregroundStyle(.secondary) } }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(MobileSurface.sheet).tint(DSHTheme.accent)
        .searchable(text: $query, prompt: "Title, author, or number").accessibilityIdentifier("pulls-list")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("Create pull request").accessibilityIdentifier("pulls-create").disabled(controller.snapshot?.writable != true || controller.snapshot?.capabilities.github != true || controller.writeLocked || controller.busy) } }
        .sheet(isPresented: $creating) { MobilePullActionForm(controller: controller, detail: nil, action: "create") }
    }
    private func load() async {
        guard !busy, !controller.busy, let snapshot = controller.snapshot,
              store.sessions.contains(where: { $0.id == snapshot.sessionId && !$0.isSubagent }), !store.workspaceState.archived.contains(snapshot.sessionId) else { return }
        busy = true; issue = nil; let requestedState = state
        defer { busy = false }
        do {
            let next = try await controller.service.pulls(snapshot: snapshot, state: requestedState)
            try Task.checkCancellation(); list = next
        } catch is CancellationError {} catch { list = nil; issue = error.localizedDescription }
    }
}
struct MobilePullRow: View {
    let item: MobilePullSummary
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.state == "merged" ? "arrow.triangle.merge" : item.draft ? "circle.dashed" : "arrow.triangle.pull").foregroundStyle(item.draft ? Color.secondary : item.state == "merged" ? .purple : .green)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text("#\(item.number) · \(item.author) · \(item.draft ? "Draft" : item.state.capitalized)").font(.caption).foregroundStyle(.secondary)
                Text("\(item.head.prefix(12)) → \(item.base)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}
