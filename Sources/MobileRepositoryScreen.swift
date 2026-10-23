import SwiftUI

/// Public thread entry point. The caller owns NavigationStack and supplies NativeStore in Environment.
/// returnWorkspace is invoked ONLY by an explicit Open button for a validated, returned worktree path.
public struct MobileRepositoryScreen: View {
    public let sessionId: String
    private let returnWorkspace: ((String) -> Void)?
    @Environment(NativeStore.self) private var store
    @State private var controller: MobileRepositoryController?
    @State private var scopeIssue = false
    public init(sessionId: String, returnWorkspace: ((String) -> Void)? = nil) { self.sessionId = sessionId; self.returnWorkspace = returnWorkspace }
    public var body: some View {
        Group {
            if let controller { MobileRepositoryContent(controller: controller, returnWorkspace: store.usesFixture ? nil : returnWorkspace) }
            else if scopeIssue { ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark", description: Text("Choose an active user workspace conversation. No repository was queried.")) }
            else { ProgressView("Opening repository…") }
        }
        .navigationTitle("Git").navigationBarTitleDisplayMode(.inline)
        .task(id: sessionId) {
            scopeIssue = false
            guard store.sessions.contains(where: { $0.id == sessionId && !$0.isSubagent }), !store.workspaceState.archived.contains(sessionId) else { controller = nil; scopeIssue = true; return }
            guard controller?.service.sessionId != sessionId else { return }
            controller = nil
            // Branch before ever reading the Store gateway: fixture mode has no production transport.
            let service: any MobileRepositoryServing
            if store.usesFixture { service = MobileRepositoryFixtureService(sessionId: sessionId) }
            else { service = MobileRepositoryService(sessionId: sessionId, transport: store.gateway) }
            let next = MobileRepositoryController(service: service); controller = next
            await next.refresh()
        }
        .accessibilityIdentifier("mobile-repository")
    }
}

struct MobileRepositoryContent: View {
    @Bindable var controller: MobileRepositoryController
    let returnWorkspace: ((String) -> Void)?
    @Environment(NativeStore.self) private var store
    @State private var form: MobileRepositoryFormKind?
    private var owns: Bool { store.sessions.contains { $0.id == controller.service.sessionId && !$0.isSubagent } && !store.workspaceState.archived.contains(controller.service.sessionId) }
    private var canWrite: Bool { owns && controller.snapshot?.writable == true && !controller.busy && !controller.writeLocked }
    var body: some View {
        List {
            if store.usesFixture { Section { Label("Synthetic repository · no file, process, or network access", systemImage: "testtube.2").font(.caption) } }
            MobileRepositoryIssue(controller: controller)
            if let snapshot = controller.snapshot {
                Section {
                    LabeledContent("Project", value: snapshot.rootLabel)
                    LabeledContent("Branch", value: snapshot.branch ?? "Detached / unborn")
                    if let head = snapshot.head { Text(String(head.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if !snapshot.capabilities.git { Text("Git capability unavailable. Configure the repository adapter on your Mac.").foregroundStyle(.orange) }
                    if !snapshot.writable { Text("Writes unavailable: ownership, capability, or conflict preconditions are not satisfied.").font(.footnote).foregroundStyle(.secondary) }
                    if let repo = snapshot.github { Text("\(repo.owner)/\(repo.name)").font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Repository") }
                fileSection(snapshot, staged: true)
                fileSection(snapshot, staged: false)
                Section("Actions") {
                    Button("Commit staged changes…") { form = .commit }.disabled(!canWrite || !snapshot.files.contains(where: \.staged)).accessibilityIdentifier("repository-commit")
                    Button("Create branch…") { form = .createBranch }.disabled(!canWrite)
                    Button("Create worktree…") { form = .createWorktree }.disabled(!canWrite || !snapshot.capabilities.worktrees)
                    ForEach(["fetch", "pull", "push"], id: \.self) { action in
                        Button("\(action.capitalized)…") { controller.prepare(action: action) }.disabled(!canWrite).accessibilityIdentifier("repository-\(action)")
                    }
                }
                Section("Branches") {
                    ForEach(snapshot.branches) { branch in
                        HStack {
                            Image(systemName: branch.current ? "checkmark.circle.fill" : "arrow.triangle.branch")
                            Text(branch.name); Spacer()
                            if branch.remote { Text("Remote").font(.caption).foregroundStyle(.secondary) }
                            else if !branch.current { Button("Switch…") { controller.prepare(action: "switchBranch", fields: ["name": .text(branch.name)]) }.disabled(!canWrite) }
                        }
                    }
                }
                Section("Worktrees") {
                    ForEach(snapshot.worktrees) { tree in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(tree.branch ?? "Detached", systemImage: tree.current ? "folder.fill" : "folder")
                            Text(tree.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            if tree.current { Text("Current worktree").font(.caption) }
                            else if tree.locked { Label("Locked", systemImage: "lock").font(.caption) }
                            else { Button("Remove worktree…", role: .destructive) { controller.prepare(action: "removeWorktree", fields: ["path": .text(tree.path)]) }.disabled(!canWrite || !snapshot.capabilities.worktrees) }
                        }
                    }
                    if let path = controller.returnedWorkspace {
                        Text("Worktree created. No thread has been created.").font(.footnote)
                        if let returnWorkspace { Button("Open new worktree") {
                            guard owns, snapshot.worktrees.contains(where: { $0.path == path }) else { return }
                            returnWorkspace(path)
                        }.disabled(!owns || !snapshot.worktrees.contains(where: { $0.path == path })).accessibilityIdentifier("repository-open-returned-worktree") }
                        else { Text("Open-in-thread integration is not connected.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section { Text("Git actions use the captured content/index/HEAD version. Network actions run only after confirmation. No force, reset, discard, or automatic retry.").font(.footnote).foregroundStyle(.secondary) }
            } else if !controller.busy { Section { Text("Repository status is unavailable, not an empty repository.").foregroundStyle(.secondary) } }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(MobileSurface.sheet).tint(DSHTheme.accent)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await controller.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(controller.busy).accessibilityLabel("Refresh repository").accessibilityIdentifier("repository-refresh") } }
        .sheet(item: $form) { kind in MobileRepositoryForm(kind: kind, controller: controller) }
        .modifier(MobileRepositoryConfirmation(controller: controller, permitted: owns, active: form == nil))
    }
    private func fileSection(_ snapshot: MobileRepositoryStatus, staged: Bool) -> some View {
        let files = snapshot.files.filter { staged ? $0.staged : $0.unstaged }
        return Section(staged ? "Staged · \(files.count)" : "Unstaged · \(files.count)") {
            if files.isEmpty { Text("No \(staged ? "staged" : "unstaged") files").font(.footnote).foregroundStyle(.secondary) }
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 7) {
                    NavigationLink {
                        MobileRepositoryDiffScreen(service: controller.service, snapshot: snapshot, file: file, staged: staged)
                    } label: {
                        HStack {
                            Image(systemName: file.binary ? "doc.richtext" : "doc.text")
                            VStack(alignment: .leading) { Text(file.path).font(.subheadline); Text(file.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text("+\(file.added.map(String.init) ?? "—")").foregroundStyle(.green); Text("−\(file.deleted.map(String.init) ?? "—")").foregroundStyle(.red)
                        }.font(.caption)
                    }.accessibilityIdentifier("repository-file-\(staged ? "staged" : "unstaged")-\(file.path)")
                    Button(staged ? "Unstage…" : "Stage…") { controller.prepare(action: staged ? "unstage" : "stage", fields: ["paths": .array([.text(file.path)])]) }.buttonStyle(.borderless).font(.caption).disabled(!canWrite)
                }
            }
        }
    }
}

struct MobileRepositoryIssue: View {
    let controller: MobileRepositoryController
    var body: some View {
        if controller.busy { Section { ProgressView("Repository request…") } }
        if let issue = controller.issue { Section { Text(issue).font(.footnote).foregroundStyle(controller.writeLocked ? .orange : .secondary).accessibilityIdentifier("repository-issue") } }
        if controller.writeLocked { Section { Label("Write locked after uncertain delivery. No replay is available. Inspect state on your Mac before starting a new operation.", systemImage: "lock.shield").font(.footnote) } }
    }
}
struct MobileRepositoryConfirmation: ViewModifier {
    @Bindable var controller: MobileRepositoryController
    var permitted: Bool
    var active = true
    func body(content: Content) -> some View {
        content.confirmationDialog("Confirm repository action", isPresented: Binding(get: { active && controller.confirmation != nil }, set: { if active && !$0 { controller.confirmation = nil } }), titleVisibility: .visible, presenting: controller.confirmation) { captured in
            Button("Confirm \(captured.title)", role: captured.title == "removeWorktree" ? .destructive : nil) {
                guard permitted else { controller.confirmation = nil; return }
                Task { _ = await controller.confirm(captured) }
            }.accessibilityIdentifier("repository-confirm-write")
            Button("Cancel", role: .cancel) { controller.confirmation = nil }
        } message: { captured in
            Text(captured.confirmationText)
        }
    }
}
enum MobileRepositoryFormKind: String, Identifiable { case commit, createBranch, createWorktree; var id: String { rawValue } }
struct MobileRepositoryForm: View {
    let kind: MobileRepositoryFormKind
    @Bindable var controller: MobileRepositoryController
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var base = ""
    @State private var runHooks = false
    @State private var hooksChosen = false
    @Environment(NativeStore.self) private var store
    private var owns: Bool { store.sessions.contains { $0.id == controller.service.sessionId && !$0.isSubagent } && !store.workspaceState.archived.contains(controller.service.sessionId) }
    var body: some View {
        NavigationStack {
            Form {
                Section(kind == .commit ? "Commit message" : "Branch name") {
                    if kind == .commit { TextEditor(text: $text).frame(minHeight: 120).accessibilityIdentifier("repository-commit-message") }
                    else { TextField("feature/name", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled() }
                }
                if kind == .commit {
                    Section("Hooks — explicit choice required") {
                        Picker("Hook execution", selection: $hooksChosen) { Text("Choose…").tag(false); Text("I have chosen below").tag(true) }
                        Toggle("Run repository hooks", isOn: $runHooks)
                        Text("Hooks execute repository-owned programs on your Mac. Turning this off explicitly requests no hooks; the adapter may refuse.").font(.footnote)
                    }
                } else { Section("Optional base") { TextField("Current HEAD", text: $base).textInputAutocapitalization(.never).autocorrectionDisabled() } }
                if let issue = controller.issue { Text(issue).font(.footnote).foregroundStyle(.orange) }
                Section {
                    Button("Review and confirm…") {
                        var fields: [String: JSONValue] = kind == .commit ? ["message": .text(text), "runHooks": .bool(runHooks)] : ["name": .text(text)]
                        if kind != .commit, !base.isEmpty { fields["base"] = .text(base) }
                        controller.prepare(action: kind.rawValue, fields: fields)
                    }.disabled(!owns || controller.snapshot?.writable != true || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (kind == .commit && !hooksChosen) || controller.busy || controller.writeLocked)
                    Text("Text is retained while this form stays open, including failed or uncertain requests.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle(kind == .commit ? "Commit" : kind == .createBranch ? "Create branch" : "Create worktree")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(controller.busy) } }
                .modifier(MobileRepositoryConfirmation(controller: controller, permitted: owns))
        }.interactiveDismissDisabled(controller.busy)
            .onAppear {
                guard let saved = controller.formDrafts[kind.rawValue] else { return }
                text = saved["text"]?.string ?? ""; base = saved["base"]?.string ?? ""
                runHooks = saved["runHooks"]?.bool ?? false; hooksChosen = saved["hooksChosen"]?.bool ?? false
            }
            .onChange(of: ["text": JSONValue.text(text), "base": .text(base), "runHooks": .bool(runHooks), "hooksChosen": .bool(hooksChosen)]) { _, saved in
                controller.formDrafts[kind.rawValue] = saved
            }
    }
}
