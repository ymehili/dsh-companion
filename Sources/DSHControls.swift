import SwiftUI

struct DSHModelPicker: View {
    var body: some View { NavigationStack { DSHModelList(modal: true) } }
}
struct DSHModelList: View {
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var modal = false
    @State private var saving = false
    private var providers: [String] { Array(Set(store.models.map(\.provider))).sorted() }
    var body: some View {
        List {
            if store.modelLoading { ProgressView("Loading models…") }
            ForEach(providers, id: \.self) { provider in
                Section(store.models.first(where: { $0.provider == provider })?.providerName ?? provider) {
                    ForEach(store.models.filter { $0.provider == provider }) { model in
                        if model.efforts.isEmpty { Button { select(model, effort: nil) } label: { modelRow(model) } }
                        else {
                            Menu {
                                Button("Default") { select(model, effort: model.defaultEffort) }
                                ForEach(model.efforts) { effort in Button(effort.name) { select(model, effort: effort.id) } }
                            } label: { modelRow(model) }
                        }
                    }
                }
            }
            if !store.modelLoading && store.models.isEmpty { ContentUnavailableView("No models available", systemImage: "cpu", description: Text("Check provider settings on your Mac.")) }
            if let error = store.modelError {
                Section { Text(error).foregroundStyle(.red); Button("Retry") { Task { await store.loadModels() } } }
            }
        }
        .disabled(saving || !store.connected)
        .navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
        .toolbar { if modal { Button("Done") { dismiss() } } }
        .overlay { if saving { ProgressView("Updating model…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await store.loadModels() }
    }
    private func modelRow(_ model: NativeModelChoice) -> some View {
        HStack {
            Text(model.name).foregroundStyle(.primary)
            Spacer()
            if store.currentModel["model"].string == model.model && store.currentModel["provider"].string == model.provider { Image(systemName: "checkmark").foregroundStyle(.tint) }
            if !model.efforts.isEmpty { Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func select(_ model: NativeModelChoice, effort: String?) {
        guard !saving else { return }; saving = true
        Task { if await store.selectModel(model, effort: effort) { dismiss() }; saving = false }
    }
}
struct DSHConversationInfo: View {
    @Environment(NativeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    Text(store.selected?.title ?? "New Session").font(.headline)
                    if let cwd = store.selected?.cwd, !cwd.isEmpty { Label(cwd, systemImage: "folder").font(.footnote).textSelection(.enabled) }
                    Label(store.status, systemImage: store.connected ? "checkmark.circle" : "wifi.slash")
                }
                Section {
                    NavigationLink { DSHModelList() } label: { LabeledContent("Model", value: store.currentModelLabel) }.disabled(store.selected == nil)
                    LabeledContent("Permissions", value: store.currentPermissionLabel)
                } header: { Text("Configuration") } footer: { Text("Permission changes and provider configuration are managed on your Mac.") }
                if !store.currentProjection["todos"].array.isEmpty {
                    Section("To-dos") {
                        ForEach(Array(store.currentProjection["todos"].array.enumerated()), id: \.offset) { _, todo in
                            Label(todo["content"].string ?? "", systemImage: todo["status"].string == "completed" ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
                if let objective = store.currentProjection["goal"]["goal"]["objective"].string { Section("Goal") { Text(objective).textSelection(.enabled) } }
            }
            .navigationTitle("Session details").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
struct DSHContextStrips: View {
    @Environment(NativeStore.self) private var store
    @State private var showDetails = false
    private var todos: [JSONValue] { store.currentProjection["todos"].array }
    var body: some View {
        HStack {
            if !todos.isEmpty { Button("To-dos (\(todos.count))", systemImage: "checklist") { showDetails = true } }
            if store.currentProjection["goal"]["goal"]["phase"].string == "active" { Button("Ongoing goal", systemImage: "scope") { showDetails = true } }
            Spacer(minLength: 0)
        }.font(.caption).buttonStyle(.borderless)
        .sheet(isPresented: $showDetails) { DSHConversationInfo() }
    }
}
