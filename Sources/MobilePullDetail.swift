import SwiftUI

struct MobilePullDetailScreen: View {
    @Bindable var controller: MobileRepositoryController
    let snapshot: MobileRepositoryStatus
    let number: Int
    @Environment(NativeStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var detail: MobilePullDetail?
    @State private var busy = false
    @State private var issue: String?
    @State private var action: MobilePullAction?
    @State private var confirmOpen = false
    private var canWrite: Bool {
        detail.map { $0.item.state == "open" && MobileRepositoryValidation.sha($0.item.head) } == true && controller.snapshot?.version == snapshot.version && snapshot.writable && snapshot.capabilities.github && !controller.busy && !controller.writeLocked && store.sessions.contains { $0.id == snapshot.sessionId && !$0.isSubagent } && !store.workspaceState.archived.contains(snapshot.sessionId)
    }
    var body: some View {
        List {
            MobileRepositoryIssue(controller: controller)
            if busy { Section { ProgressView("Loading pull request…") } }
            if let issue { Section { Text(issue).font(.footnote).foregroundStyle(.orange); Button("Retry read") { Task { await load() } } } }
            if let detail {
                Section {
                    MobilePullRow(item: detail.item)
                    Text("\(detail.repository.owner)/\(detail.repository.name)").font(.caption).foregroundStyle(.secondary)
                    Text("Mergeability: \(detail.mergeable)").font(.footnote)
                    Button("Open this pull request on GitHub…") { confirmOpen = true }.accessibilityIdentifier("pulls-open-github")
                    if !MobileRepositoryValidation.sha(detail.item.head) { Text("The adapter has not returned an immutable head SHA. Remote writes are disabled until safe compare-and-swap identity is available.").font(.footnote).foregroundStyle(.orange) }
                }
                Section("Description") { MobilePullMarkdown(text: detail.body.isEmpty ? "No description." : detail.body) }
                Section("Files · \(detail.files.count)") {
                    if detail.files.isEmpty { Text("No changed files.").foregroundStyle(.secondary) }
                    ForEach(detail.files) { file in
                        DisclosureGroup {
                            if let patch = file.patch {
                                ScrollView(.horizontal) { Text(patch).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(.vertical, 8) }
                            } else { Text("Text patch unavailable (binary, oversized, or not supplied by GitHub).").font(.footnote).foregroundStyle(.secondary) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) { Text(file.path).font(.subheadline.monospaced()); Text("\(file.status) · +\(file.added) −\(file.deleted)").font(.caption).foregroundStyle(.secondary) }
                        }.accessibilityIdentifier("pulls-file-\(file.path)")
                    }
                }
                Section("Discussion · \(detail.comments.count)") {
                    if detail.comments.isEmpty { Text("No comments.").foregroundStyle(.secondary) }
                    ForEach(detail.comments) { comment in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(comment.author).font(.subheadline.weight(.semibold)); Spacer(); Text(comment.createdAt).font(.caption2).foregroundStyle(.secondary) }
                            MobilePullMarkdown(text: comment.body)
                        }.padding(.vertical, 5)
                    }
                }
                Section("Checks · \(detail.checks.count)") {
                    if detail.checks.isEmpty { Text("No checks were returned.").foregroundStyle(.secondary) }
                    ForEach(Array(detail.checks.enumerated()), id: \.offset) { _, check in LabeledContent(check.name, value: check.state) }
                }
                Section("Review") {
                    ForEach(["comment", "reviewComment", "approve", "requestChanges", "merge"], id: \.self) { name in
                        Button(MobilePullAction.title(name) + "…") { action = MobilePullAction(id: name) }
                            .disabled(!canWrite || (name == "merge" && (detail.item.draft || !["clean", "mergeable"].contains(detail.mergeable.lowercased()))))
                            .accessibilityIdentifier("pulls-action-\(name)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(MobileSurface.sheet).tint(DSHTheme.accent)
        .navigationTitle("#\(number)").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Comment", systemImage: "bubble.left") { action = .init(id: "comment") }
                    Button("Review with comment", systemImage: "text.bubble") { action = .init(id: "reviewComment") }
                    Button("Approve", systemImage: "checkmark.circle") { action = .init(id: "approve") }
                    Button("Request changes", systemImage: "exclamationmark.bubble") { action = .init(id: "requestChanges") }
                } label: { Label("Review", systemImage: "ellipsis.circle") }.disabled(!canWrite).accessibilityIdentifier("pulls-review-menu")
            }
            ToolbarItem(placement: .topBarTrailing) { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(busy).accessibilityLabel("Refresh pull request").accessibilityIdentifier("pulls-detail-refresh") }
        }
        // Navigating to a numbered PR is an explicit user-open, not a background subscription.
        .task { await load() }
        .sheet(item: $action) { selected in MobilePullActionForm(controller: controller, detail: detail, action: selected.id) }
        .confirmationDialog("Open GitHub?", isPresented: $confirmOpen, titleVisibility: .visible) {
            Button("Open pull request #\(number)") {
                guard !store.usesFixture, let detail, let url = try? detail.repository.url(number: number, supplied: detail.item.url) else { return }
                openURL(url)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(store.usesFixture ? "External navigation is disabled in synthetic fixture mode." : "Only the validated github.com repository and pull request URL will open.") }
        .accessibilityIdentifier("pulls-detail")
    }
    private func load() async {
        guard !busy, store.sessions.contains(where: { $0.id == snapshot.sessionId && !$0.isSubagent }), !store.workspaceState.archived.contains(snapshot.sessionId) else { return }
        busy = true; issue = nil
        defer { busy = false }
        do { let next = try await controller.service.pull(snapshot: snapshot, number: number); try Task.checkCancellation(); detail = next }
        catch is CancellationError {} catch { detail = nil; issue = error.localizedDescription }
    }
}

/// Native attributed Markdown text, never a browser. Host-supplied links are inert; only the separately validated PR button opens URLs.
struct MobilePullMarkdown: View {
    let text: String
    private var attributed: AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs where run.link != nil { value[run.range].link = nil }
        return value
    }
    var body: some View { Text(attributed).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
}
struct MobilePullAction: Identifiable {
    let id: String
    static func title(_ action: String) -> String {
        switch action { case "create": "Create pull request"; case "comment": "Comment"; case "reviewComment": "Review with comment"; case "approve": "Approve"; case "requestChanges": "Request changes"; case "merge": "Merge"; default: "Unavailable action" }
    }
}

struct MobilePullActionForm: View {
    @Bindable var controller: MobileRepositoryController
    let detail: MobilePullDetail?
    let action: String
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var base = "main"
    @State private var head = ""
    @State private var draft = true
    @State private var method = "squash"
    private var owns: Bool { store.sessions.contains { $0.id == controller.service.sessionId && !$0.isSubagent } && !store.workspaceState.archived.contains(controller.service.sessionId) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Captured revision") {
                    if let detail { Text("\(detail.repository.owner)/\(detail.repository.name) #\(detail.item.number)"); Text("Expected head: \(detail.item.head)").font(.caption.monospaced()).textSelection(.enabled) }
                    else { Text("Expected local head: \(controller.snapshot?.head ?? "Unavailable")").font(.caption.monospaced()).textSelection(.enabled) }
                    if action == "create" || action == "comment" { Text("GitHub offers a head preflight, not atomic compare-and-swap for this action. The captured revision is retained; a racing head may require inspection on GitHub.").font(.footnote).foregroundStyle(.secondary) }
                }
                if action == "create" {
                    Section("Pull request") {
                        TextField("Title", text: $title).accessibilityIdentifier("pulls-create-title")
                        TextField("Head branch", text: $head).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("pulls-create-head")
                        TextField("Base branch", text: $base).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("pulls-create-base")
                        Toggle("Create as draft", isOn: $draft).accessibilityIdentifier("pulls-create-draft")
                    }
                }
                if action == "merge" {
                    Section("Merge method") { Picker("Method", selection: $method) { Text("Squash").tag("squash"); Text("Merge commit").tag("merge"); Text("Rebase").tag("rebase") }; Text("The adapter must compare the expected head SHA before merging. No force or automatic merge.").font(.footnote) }
                } else {
                    Section(action == "create" ? "Description" : "Review body") { TextEditor(text: $text).frame(minHeight: 160).accessibilityIdentifier("pulls-action-body") }
                }
                MobileRepositoryIssue(controller: controller)
                Section {
                    Button("Review and confirm…") {
                        guard owns else { return }
                        let fields: [String: JSONValue]
                        if action == "create" { fields = ["title": .text(title), "body": .text(text), "head": .text(head), "base": .text(base), "draft": .bool(draft)] }
                        else if action == "merge" { fields = ["method": .text(method)] }
                        else { fields = ["body": .text(text)] }
                        controller.prepare(action: action, fields: fields, pull: detail)
                    }.disabled(!owns || controller.busy || controller.writeLocked || controller.snapshot?.writable != true || controller.snapshot?.capabilities.github != true || (action != "create" && !MobileRepositoryValidation.sha(detail?.item.head ?? ""))).accessibilityIdentifier("pulls-action-review-confirm")
                    Text("Nothing is sent until you confirm. Draft text is retained in memory for this project while its screen remains open, including uncertain delivery. There is no automatic replay.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle(MobilePullAction.title(action)).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(controller.busy) } }
                .modifier(MobileRepositoryConfirmation(controller: controller, permitted: owns))
                .onAppear {
                    if head.isEmpty { head = controller.snapshot?.branch ?? "" }
                    guard let saved = controller.formDrafts["pull:\(action):\(detail?.item.number ?? 0)"] else { return }
                    title = saved["title"]?.string ?? ""; text = saved["text"]?.string ?? ""
                    head = saved["head"]?.string ?? head; base = saved["base"]?.string ?? "main"
                    draft = saved["draft"]?.bool ?? true; method = saved["method"]?.string ?? "squash"
                }
                .onChange(of: ["title": JSONValue.text(title), "text": .text(text), "head": .text(head), "base": .text(base), "draft": .bool(draft), "method": .text(method)]) { _, saved in
                    controller.formDrafts["pull:\(action):\(detail?.item.number ?? 0)"] = saved
                }
        }.interactiveDismissDisabled(controller.busy)
    }
}
