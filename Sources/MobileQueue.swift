import SwiftUI
import UIKit

/// Session-scoped queue sheet. The presenting caller owns the NavigationStack.
struct MobileQueue: View {
    let sessionId: String
    @Environment(NativeStore.self) private var store
    @State private var controller: MobileQueueController?
    private var projection: JSONValue { store.desktopProjections[sessionId] ?? .null }
    var body: some View {
        Group {
            if let controller, controller.sessionId == sessionId {
                MobileQueueList(controller: controller, running: store.usesFixture || store.sessions.first(where: { $0.id == sessionId })?.running == true,
                                mutable: store.usesFixture || canMutate, fixture: store.usesFixture)
            } else { ProgressView("Loading queue…") }
        }
        .navigationTitle("Queued messages")
        .navigationBarTitleDisplayMode(.inline)
        .background(MobileSurface.sheet)
        .task(id: sessionId) {
            // Context-menu/keyboard sheet transitions must not replace a live
            // controller and reset its editor/fixture projection.
            if let controller, controller.sessionId == sessionId { return }
            let service: any MobileQueueServing = store.usesFixture
                ? MobileQueueFixtureService(sessionId: sessionId)
                : MobileQueueService(sessionId: sessionId, transport: store.gateway)
            let next = MobileQueueController(service: service)
            controller = next
            if store.usesFixture { await next.refresh() }
            else { next.receive(projection) }
        }
        .onChange(of: projection) { _, value in
            guard !store.usesFixture, controller?.sessionId == sessionId else { return }
            controller?.receive(value)
        }
        .accessibilityIdentifier("mobile-queue")
    }
    private var canMutate: Bool {
        guard store.connected, let row = store.sessions.first(where: { $0.id == sessionId }) else { return false }
        if row.isSubagent { return projection["subagent"]["mode"].string == "continuable" }
        return true
    }
}

private struct MobileQueueList: View {
    @Bindable var controller: MobileQueueController
    let running: Bool
    let mutable: Bool
    let fixture: Bool
    @State private var removing: MobileQueueItem?
    private var items: [MobileQueueItem] { controller.snapshot?.items ?? [] }
    var body: some View {
        List {
            if fixture {
                Section { Label("Preview · synthetic messages only", systemImage: "testtube.2").font(.footnote).foregroundStyle(DSHTheme.secondary) }
            }
            if let issue = controller.issue {
                Section { Text(issue.localizedDescription).font(.footnote).foregroundStyle(DSHTheme.statusAttention) }
            }
            if !mutable {
                Section { Text("Queue actions are unavailable while disconnected or for this read-only session.").font(.footnote).foregroundStyle(DSHTheme.secondary) }
            }
            if let edit = controller.editing { editor(edit) }
            ForEach(controller.errors.keys.sorted(), id: \.self) { id in
                if !items.contains(where: { $0.id == id }), controller.editing?.item.id != id, let error = controller.errors[id] {
                    Section { Text(error.localizedDescription).font(.footnote).foregroundStyle(DSHTheme.statusAttention) }
                }
            }
            ForEach(MobileQueueKind.allCases, id: \.self) { kind in
                let rows = items.filter { $0.kind == kind }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { item in queueRow(item) }
                    } header: { Text("\(kind.label) · \(rows.count)") }
                }
            }
            if items.isEmpty && controller.issue == nil {
                Section {
                    Label("No queued messages", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .foregroundStyle(DSHTheme.secondary).frame(minHeight: 49)
                }
            }
            Section {
                Text("Order follows your Mac. Reordering and holding or resuming already-queued messages are not supported by this Host API. Editing here does not pause delivery.")
                    .font(.footnote).foregroundStyle(DSHTheme.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(MobileSurface.sheet)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await controller.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(minWidth: 49, minHeight: 49) }
                    .accessibilityLabel("Refresh queue").disabled(controller.refreshing)
            }
        }
        .refreshable { await controller.refresh() }
        .confirmationDialog("Remove queued message?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let captured = removing {
                Button("Remove message", role: .destructive) {
                    removing = nil
                    act(captured, .remove)
                }
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("This removes only this pending message, not the active turn.") }
    }
    private func queueRow(_ item: MobileQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.kind == .queued ? "text.line.first.and.arrowtriangle.forward" : "arrow.turn.up.right")
                    .foregroundStyle(DSHTheme.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text.isEmpty ? "Attached content" : item.text).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.kind.label).font(.caption).foregroundStyle(DSHTheme.secondary)
                }
                if controller.pending.contains(item.id) { ProgressView().accessibilityLabel("Updating message") }
            }
            if !fixture {
                ForEach(item.images.prefix(3)) { image in
                    ChatAttachmentImage(reference: image, sessionId: item.sessionId).frame(maxHeight: 140)
                }
            }
            if item.nonTextCount > 0 {
                Label("\(item.nonTextCount) attachment or non-text part(s) · text editing unavailable", systemImage: "paperclip")
                    .font(.caption).foregroundStyle(DSHTheme.secondary)
            }
            if let failure = controller.errors[item.id], controller.editing?.item.id != item.id {
                Text(failure.localizedDescription).font(.footnote).foregroundStyle(DSHTheme.statusAttention)
            }
        }
        .padding(.vertical, 8).frame(minHeight: 49)
        .contentShape(Rectangle())
        .contextMenu {
            Button { controller.beginEdit(item) } label: { Label("Edit", systemImage: "pencil") }.disabled(disabled(item) || !item.canEdit)
            Button { act(item, .steer) } label: { Label("Steer now", systemImage: "arrow.turn.up.right") }
                .disabled(disabled(item) || !running || item.kind != .queued)
            Button(role: .destructive) { removing = item } label: { Label("Remove", systemImage: "trash") }.disabled(disabled(item))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { removing = item } label: { Label("Remove", systemImage: "trash") }.disabled(disabled(item))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue-row-\(item.id)")
        .accessibilityAction(named: "Edit queued message") { if !disabled(item) && item.canEdit { controller.beginEdit(item) } }
        .accessibilityAction(named: "Remove queued message") { if !disabled(item) { removing = item } }
    }
    private func editor(_ edit: MobileQueueEdit) -> some View {
        Section {
            Text("Editing this queued message only. Your Mac may start it while you edit; saving never sends a new chat message.")
                .font(.footnote).foregroundStyle(DSHTheme.secondary)
            TextEditor(text: Binding(get: { controller.editing?.text ?? "" }, set: { controller.editing?.text = $0 }))
                .frame(minHeight: 140).accessibilityLabel("Queued message text").disabled(controller.pending.contains(edit.item.id))
            if let error = controller.errors[edit.item.id] {
                Text(error.localizedDescription).font(.footnote).foregroundStyle(DSHTheme.statusAttention)
            }
            HStack {
                Button("Cancel", role: .cancel) { controller.editing = nil }.frame(minHeight: 49)
                    .disabled(controller.pending.contains(edit.item.id))
                Spacer()
                Button("Copy text") { UIPasteboard.general.string = controller.editing?.text ?? edit.text }.frame(minHeight: 49)
                Button("Save") {
                    Task {
                        await controller.saveEdit()
                        if controller.editing == nil { await controller.refresh() }
                    }
                }.frame(minHeight: 49)
                    .disabled(!mutable || controller.issue != nil || controller.pending.contains(edit.item.id) || controller.editing?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                              || controller.errors[edit.item.id] == .alreadyStarted || controller.errors[edit.item.id] == .changed)
            }.buttonStyle(.borderless)
        } header: { Text("Edit queued message") }
    }
    private func disabled(_ item: MobileQueueItem) -> Bool { !mutable || controller.issue != nil || controller.pending.contains(item.id) }
    private func act(_ item: MobileQueueItem, _ action: MobileQueueAction) {
        Task { if await controller.perform(item, action: action) { await controller.refresh() } }
    }
}
