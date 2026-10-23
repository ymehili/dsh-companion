import SwiftUI

/// Registrations, not filesystem deletion or fabricated project archive/pin.
struct MobileProjects: View {
    @Environment(NativeStore.self) private var store
    @State private var service: (any MobileProjectsServing)?
    @State private var editing: ProjectEdit?
    @State private var removing: MobileProject?
    @State private var busy = false
    @State private var issue: String?
    var onChoose: ((MobileProject) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private struct ProjectEdit: Identifiable { let project: MobileProject?; var id: String { project?.id ?? "new-project" } }
    private var projects: [MobileProject] {
        let values = store.workspaceState.items.compactMapValues { try? MobileProject($0) }
        let ids = store.workspaceState.order + values.keys.filter { !store.workspaceState.order.contains($0) }.sorted()
        return ids.compactMap { values[$0] }
    }
    var body: some View {
        List {
            if store.usesFixture { Section { Label("Preview · synthetic Mac project registrations", systemImage: "testtube.2").font(.footnote) } }
            if let issue { Section { Text(issue).font(.footnote).foregroundStyle(.red) } }
            Section {
                ForEach(projects) { project in
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(DSHTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.title).font(.body)
                            Text(project.path).font(.caption).foregroundStyle(DSHTheme.secondary).lineLimit(2)
                            Text("\(project.sessions.count) threads").font(.caption).foregroundStyle(DSHTheme.tertiary)
                        }
                        Spacer(minLength: 0)
                        if onChoose != nil { Button("Choose") { onChoose?(project); dismiss() }.buttonStyle(.borderless).disabled(busy) }
                    }.frame(minHeight: 49).accessibilityIdentifier("project-row-\(project.id)")
                        .contextMenu {
                            if let onChoose { Button("Use for new thread", systemImage: "square.and.pencil") { onChoose(project); dismiss() } }
                            Button("Rename…", systemImage: "pencil") { editing = ProjectEdit(project: project) }.disabled(busy)
                            Button("Remove registration…", systemImage: "folder.badge.minus", role: .destructive) { removing = project }.disabled(busy)
                        }
                        .swipeActions(allowsFullSwipe: false) { Button("Remove", role: .destructive) { removing = project }.disabled(busy) }
                }.onMove(perform: move)
                if projects.isEmpty { Text("No registered projects. Add an existing Mac directory to begin.").foregroundStyle(DSHTheme.secondary) }
            } header: { Text("Projects on your Mac") } footer: {
                Text("Removing a project only removes its registration. Files and conversations stay on your Mac.")
            }
            Section {
                Button { editing = ProjectEdit(project: nil) } label: { Label("Add project", systemImage: "folder.badge.plus").frame(minHeight: 44) }
                    .disabled(busy || (!store.connected && !store.usesFixture)).accessibilityIdentifier("projects-add")
            }
        }
        .scrollContentBackground(.hidden).background(MobileSurface.sheet)
        .navigationTitle("Projects").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(busy || projects.isEmpty) } }
        .task { prepare() }
        .sheet(item: $editing) { edit in
            MobileProjectEditor(project: edit.project) { value in
                guard let service, !busy else { throw NativeRPCError(message: "Wait for the current project operation.") }
                try authorize(edit.project)
                busy = true; defer { busy = false }
                let result: MobileProject
                if let project = edit.project { result = try await service.rename(project, title: value) }
                else { result = try await service.create(path: value) }
                store.workspaceState.accept(.obj(["type": .text("upsert"), "workspace": result.wire])); issue = nil
            }.presentationDetents([.fraction(0.75), .large]).presentationDragIndicator(.visible)
        }
        .confirmationDialog("Remove project registration?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let project = removing {
                Button("Remove registration", role: .destructive) {
                    removing = nil
                    Task { @MainActor in
                        do {
                            try authorize(project); guard let service, !busy else { return }; busy = true; defer { busy = false }
                            try await service.remove(project)
                            store.workspaceState.accept(.obj(["type": .text("remove"), "workspaceId": .text(project.id)])); issue = nil
                        } catch { issue = error.localizedDescription }
                    }
                }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("Only the project’s registration is removed. No files or threads are deleted and no running agent is stopped.") }
        .accessibilityElement(children: .contain).accessibilityIdentifier("mobile-projects")
    }
    private func authorize(_ project: MobileProject?) throws {
        guard store.connected || store.usesFixture else { throw NativeRPCError(message: "Reconnect before changing project registrations.") }
        if let project {
            guard store.workspaceState.items[project.id] == project.wire else { throw NativeRPCError(message: "This project changed. Cancel and reopen the current registration.") }
        }
    }
    private func prepare() {
        guard service == nil else { return }
        if store.usesFixture {
            if store.workspaceState.items.isEmpty {
                var seen = Set<String>()
                for row in store.sessions where !row.isSubagent && MobileProject.absolute(row.cwd) && seen.insert(row.cwd).inserted {
                    let project = JSONValue.obj(["workspaceId": .text("fixture-project-" + String(seen.count)), "path": .text(row.cwd), "title": .text(store.workspaceState.title(for: row.id, cwd: row.cwd)), "sessionIds": .array(store.sessions.filter { $0.cwd == row.cwd && !$0.isSubagent }.map { .text($0.id) })])
                    store.workspaceState.accept(.obj(["type": .text("upsert"), "workspace": project]))
                }
            }
            service = MobileProjectsFixture(projects)
        } else { service = MobileProjectsService(store.gateway) }
    }
    private func move(_ source: IndexSet, _ destination: Int) {
        guard source.count == 1, let index = source.first, projects.indices.contains(index), !busy else { return }
        let captured = projects, project = captured[index]
        var next = captured; next.move(fromOffsets: source, toOffset: destination)
        guard let moved = next.firstIndex(where: { $0.id == project.id }) else { return }
        let before = moved + 1 < next.count ? next[moved + 1].id : nil
        Task { @MainActor in
            do {
                try authorize(project); guard let service, !busy else { return }; busy = true; defer { busy = false }
                let ids = try await service.reorder(project, before: before)
                guard Set(ids) == Set(projects.map(\.id)) else { throw NativeRPCError(message: "The project list changed. Reopen Projects to review its current order.") }
                store.workspaceState.accept(.obj(["type": .text("order"), "workspaceIds": .array(ids.map(JSONValue.text))])); issue = nil
            } catch { issue = error.localizedDescription }
        }
    }
}

private struct MobileProjectEditor: View {
    let project: MobileProject?
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var busy = false
    @State private var error: String?
    init(project: MobileProject?, save: @escaping (String) async throws -> Void) {
        self.project = project; self.save = save; _value = State(initialValue: project?.title ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(project == nil ? "Existing Mac directory" : "Project name") {
                    TextField(project == nil ? "/Users/you/Projects/example" : "Name", text: $value, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("project-editor-value")
                }
                Text(project == nil ? "This registers a directory that already exists on your Mac. It does not create files, start an agent, or access this iPhone’s files." : "Changes the project label on your Mac. Its path and files are unchanged.").font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("project-editor-error") }
            }.navigationTitle(project == nil ? "Add project" : "Rename project").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "Saving…" : "Save") {
                            let captured = value
                            Task { @MainActor in busy = true; defer { busy = false }; do { try await save(captured); dismiss() } catch { self.error = error.localizedDescription } }
                        }.disabled(busy || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("project-editor-save")
                    }
                }
        }.interactiveDismissDisabled(busy)
    }
}
