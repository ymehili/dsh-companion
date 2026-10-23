import SwiftUI
import UIKit

@MainActor
extension NativeStore {
    func makeMobileLifecycleService() -> MobileLifecycleService {
        // Fixture data originally predates the versioned replica. Rebaseline only its synthetic records.
        if usesFixture, inboxHasSnapshot, !inboxReplica.hasSnapshot {
            let records = inboxThreads.mapValues { value -> JSONValue in
                var fields = value.object ?? [:]; fields["version"] = .number(0); return .obj(fields)
            }
            let existingIssue = inboxError
            _ = acceptInbox(MobileLifecycleService.snapshot(epoch: "mobile-lifecycle-fixture", revision: 0, activated: inboxAvailable, threads: records))
            inboxError = existingIssue // Seeding versions is not a successful sync.
        }
        let snapshot = mobileLifecycleSnapshot
        let service = MobileLifecycleService(transport: gateway, fixtureSnapshot: usesFixture ? snapshot : nil)
        service.synchronize(snapshot)
        service.currentSnapshot = { [weak self] in self?.mobileLifecycleSnapshot ?? .null }
        service.onMerge = { [weak self] in self?.acceptInbox($0) ?? false }
        return service
    }
    var mobileLifecycleSnapshot: JSONValue {
        guard let epoch = inboxReplica.epoch else { return .null }
        return MobileLifecycleService.snapshot(epoch: epoch, revision: inboxReplica.revision, activated: inboxAvailable, threads: inboxThreads)
    }
    func authorizeLifecycleTarget(_ id: String) throws {
        guard connected || usesFixture else { throw NativeRPCError(message: "Reconnect before changing a thread.") }
        guard let row = sessions.first(where: { $0.id == id }), !row.isSubagent, !workspaceState.archived.contains(id) else {
            throw NativeRPCError(message: "This thread is no longer available. Review the current list.")
        }
    }
    func renameLifecycleTarget(_ id: String, title: String, service: MobileLifecycleService) async throws {
        try authorizeLifecycleTarget(id)
        let result = try await service.rename(sessionId: id, title: title)
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].title = result }
        if selected?.id == id { selected?.title = result }
    }
    func forkLifecycleTarget(_ id: String, service: MobileLifecycleService) async throws -> String {
        try authorizeLifecycleTarget(id)
        let fork = try await service.fork(sessionId: id)
        if usesFixture, var row = sessions.first(where: { $0.id == id }) {
            // Reconstruct identity, not a repository/worktree operation.
            row = SessionRow(.obj(["sessionId": .text(fork), "cwd": .text(row.cwd), "updatedAt": .number(Date().timeIntervalSince1970 * 1000), "projections": .obj(["values": .obj(["title": .text(row.title + " (fork)")])])]))!
            sessions.insert(row, at: 0)
        } else { try await refreshSessions() }
        return fork
    }
    func archiveLifecycleTarget(_ id: String, service: MobileLifecycleService) async throws {
        try authorizeLifecycleTarget(id)
        let archived = try await service.archive(sessionId: id)
        let ids = usesFixture ? Set(archived).union(workspaceState.archived) : Set(archived)
        workspaceState.accept(.obj(["type": .text("archived"), "archivedSessionIds": .array(ids.sorted().map(JSONValue.text))]))
    }
}

private struct MobileLifecycleRowActions: ViewModifier {
    @Environment(NativeStore.self) private var store
    let row: SessionRow
    let record: JSONValue
    let service: MobileLifecycleService?
    let onFork: (String) -> Void
    @State private var editor: String?
    @State private var title = ""
    @State private var wakeTime = Date().addingTimeInterval(3600)
    @State private var confirmation: MobileLifecycleCommand?
    @State private var showingSettle = false
    @State private var showingArchive = false
    @State private var errorMessage: String?
    private var enabled: Bool { service != nil && !service!.busy && (store.connected || store.usesFixture) && !row.isSubagent && !store.workspaceState.archived.contains(row.id) }
    private var lifecycleEnabled: Bool { enabled && store.inboxAvailable && store.inboxHasSnapshot }
    private var settled: Bool { record["settledOverride"].string == "settled" }
    private var pinned: Bool { record["pinnedAt"].number != nil }
    func body(content: Content) -> some View {
        content
            .modifier(MobilePinnedDrag(id: row.id, pinned: pinned))
            .dropDestination(for: String.self) { ids, _ in
                guard pinned, let value = ids.first, ids.count == 1, value.hasPrefix("dsh-pinned-thread:") else { return false }
                reorder(String(value.dropFirst("dsh-pinned-thread:".count)))
                return true
            }
            .contextMenu {
                Group {
                    Button(settled ? "Unsettle" : "Settle", systemImage: settled ? "tray" : "checkmark.circle") { act(settled ? .unsettle : .settle) }.accessibilityIdentifier("lifecycle-settle-\(row.id)")
                    Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") { act(pinned ? .unpin : .pin) }.accessibilityIdentifier("lifecycle-pin-\(row.id)")
                    if record["snoozedUntil"].number != nil { Button("Wake now", systemImage: "sun.max") { act(.wake) } }
                    Menu("Snooze", systemImage: "moon") {
                        Button("For 1 hour") { snooze(Date().addingTimeInterval(3600)) }
                        Button("For 3 hours") { snooze(Date().addingTimeInterval(10800)) }
                        Button("For 1 day") { snooze(Date().addingTimeInterval(86400)) }
                        Button("Choose time…") { wakeTime = Date().addingTimeInterval(3600); editor = "snooze" }
                    }.accessibilityIdentifier("lifecycle-snooze-\(row.id)")
                    Button("Mark unread", systemImage: "circle") { act(.markUnread) }.disabled(record["facts"]["completedAt"].number == nil)
                    Button(record["autoSettleDisabled"].bool == true ? "Allow auto-settle" : "Prevent auto-settle", systemImage: "clock.arrow.circlepath") {
                        act(.autoSettle, arguments: .obj(["enabled": .bool(record["autoSettleDisabled"].bool == true)]))
                    }.accessibilityIdentifier("lifecycle-auto-settle-\(row.id)")
                }.disabled(!lifecycleEnabled)
                Divider()
                Group {
                    Button("Rename…", systemImage: "pencil") { title = row.title; editor = "rename" }.accessibilityIdentifier("lifecycle-rename-\(row.id)")
                    Button("Fork conversation…", systemImage: "arrow.branch") { editor = "fork" }.accessibilityIdentifier("lifecycle-fork-\(row.id)")
                    Button("Archive…", systemImage: "archivebox") { showingArchive = true }.accessibilityIdentifier("lifecycle-archive-\(row.id)")
                }.disabled(!enabled)
                Divider()
                Button("Copy Thread ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.id }
                if !row.cwd.isEmpty { Button("Copy Folder Path", systemImage: "folder") { UIPasteboard.general.string = row.cwd } }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { act(settled ? .unsettle : .settle) } label: { Label(settled ? "Unsettle" : "Settle", systemImage: "checkmark.circle") }.tint(.green).disabled(!lifecycleEnabled)
                Button { act(pinned ? .unpin : .pin) } label: { Label(pinned ? "Unpin" : "Pin", systemImage: "pin") }.tint(.orange).disabled(!lifecycleEnabled)
                Button { editor = "snooze" } label: { Label("Snooze", systemImage: "moon") }.tint(.indigo).disabled(!lifecycleEnabled)
            }
            .confirmationDialog("Settle “\(row.title)” ?", isPresented: $showingSettle, titleVisibility: .visible) {
                Button("Settle thread") { if let confirmation { run { try store.authorizeLifecycleTarget(row.id); try await service?.execute(confirmation) } }; confirmation = nil }
                Button("Cancel", role: .cancel) { confirmation = nil }
            } message: { Text("Stops automatic wakes, disarms its goal, and may cancel running subagent descendants. Jobs and terminals are preserved. This is not archive or delete.") }
            .confirmationDialog("Archive “\(row.title)” ?", isPresented: $showingArchive, titleVisibility: .visible) {
                Button("Archive thread") { guard let service else { return }; run { try await store.archiveLifecycleTarget(row.id, service: service) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Hides this conversation from the active list; does not delete it. Active work is never stopped automatically. If busy, interrupt it separately and try again.") }
            .sheet(isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
                NavigationStack {
                    Form {
                        Text(row.title).font(.headline)
                        if editor == "rename" { TextField("Thread title", text: $title).accessibilityIdentifier("lifecycle-rename-title") }
                        else if editor == "snooze" {
                            DatePicker("Wake time", selection: $wakeTime, in: Date()..., displayedComponents: [.date, .hourAndMinute]).accessibilityIdentifier("lifecycle-wake-time")
                            Text("Choose a future time. Snooze does not pause a running engine.").font(.footnote)
                        } else { Text("Create a conversation fork at the latest completed turn. This does not fork a repository or create a worktree.") }
                    }
                    .navigationTitle(editor == "rename" ? "Rename thread" : editor == "snooze" ? "Snooze thread" : "Fork conversation")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editor = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Confirm") {
                                guard let service else { return }
                                let kind = editor, capturedTitle = title, capturedTime = wakeTime
                                editor = nil
                                if kind == "snooze" { snooze(capturedTime) }
                                else if kind == "rename" { run { try await store.renameLifecycleTarget(row.id, title: capturedTitle, service: service) } }
                                else { run { let id = try await store.forkLifecycleTarget(row.id, service: service); onFork(id) } }
                            }.accessibilityIdentifier("lifecycle-confirm")
                        }
                    }
                }.presentationDetents([.medium, .large])
            }
            .alert("Thread action not completed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                if let command = service?.retryCommand { Button("Retry exact command") { run { try store.authorizeLifecycleTarget(row.id); try await service?.execute(command) } } }
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }
    private func snooze(_ date: Date) { act(.snooze, arguments: .obj(["until": .number(date.timeIntervalSince1970 * 1000)])) }
    private func act(_ action: MobileLifecycleAction, arguments: JSONValue = .obj([:])) {
        guard let service else { return }
        do {
            try store.authorizeLifecycleTarget(row.id)
            var args = arguments
            if action == .pin {
                let last = store.inboxThreads.values.compactMap { $0["pinOrderKey"].string }.max()
                args = .obj(["orderKey": .text(try MobileLifecycleOrder.between(last, nil))])
            }
            let command = try service.capture(id: row.id, action: action, arguments: args)
            if action == .settle { confirmation = command; showingSettle = true }
            else { run { try store.authorizeLifecycleTarget(row.id); try await service.execute(command) } }
        } catch { errorMessage = error.localizedDescription }
    }
    private func reorder(_ source: String) {
        guard source != row.id, lifecycleEnabled, let service else { return }
        do {
            try store.authorizeLifecycleTarget(source)
            let pinnedRows = store.sessions.filter { store.sidebarRecord(for: $0)["pinnedAt"].number != nil && $0.id != source }
                .sorted { DesktopInbox.precedes(store.sidebarRecord(for: $0), idA: $0.id, store.sidebarRecord(for: $1), idB: $1.id, shelf: "pinned") }
            guard let index = pinnedRows.firstIndex(where: { $0.id == row.id }),
                  store.inboxThreads[source]?["pinnedAt"].number != nil else { throw NativeRPCError(message: "Pinned threads changed. Refresh and try again.") }
            let after = store.sidebarRecord(for: pinnedRows[index])["pinOrderKey"].string
            let before = index > 0 ? store.sidebarRecord(for: pinnedRows[index - 1])["pinOrderKey"].string : nil
            // Old native-only pins lack lexical keys. Do not invent a numeric/index order or reorder queues.
            if index > 0 && before == nil { throw NativeRPCError(message: "These older pins have no order keys. Unpin and pin them explicitly before dragging between them.") }
            let key = try MobileLifecycleOrder.between(before, after)
            let command = try service.capture(id: source, action: .reorderPin, arguments: .obj(["orderKey": .text(key)]))
            run { try store.authorizeLifecycleTarget(source); try await service.execute(command) }
        } catch { errorMessage = error.localizedDescription }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { errorMessage = error.localizedDescription } }
    }
}

private struct MobilePinnedDrag: ViewModifier {
    let id: String
    let pinned: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if pinned { content.draggable("dsh-pinned-thread:" + id) } else { content }
    }
}

extension View {
    func mobileLifecycleActions(row: SessionRow, record: JSONValue, service: MobileLifecycleService?, onFork: @escaping (String) -> Void) -> some View {
        modifier(MobileLifecycleRowActions(row: row, record: record, service: service, onFork: onFork))
    }
}

struct MobileLifecycleSettings: View {
    let service: MobileLifecycleService
    @Environment(\.dismiss) private var dismiss
    @State private var preview: MobileLifecyclePreview?
    @State private var issue: String?
    @State private var confirmingEnable = false
    @State private var days = 3
    @State private var never = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Thread Inbox") {
                    Text(service.replica.activated ? "Enabled on your Mac" : "Disabled on your Mac")
                    Button("Preview auto-settle impact") { perform { preview = try await service.preview() } }.accessibilityIdentifier("lifecycle-preview")
                    if let preview { Text("\(preview.autoSettle) of \(preview.total) threads would auto-settle.") }
                    if !service.replica.activated {
                        Button("Enable Thread Inbox…") { confirmingEnable = true }.accessibilityIdentifier("lifecycle-enable")
                    } else {
                        Toggle("Never auto-settle for inactivity", isOn: $never)
                        if !never { Stepper("After \(days) days", value: $days, in: 1...90) }
                        Button("Apply auto-settle policy…") { confirmingEnable = true }
                    }
                    Text("Applying policy may immediately settle eligible threads, disarm goals and cancel subagent descendants. Opening this screen changes nothing.").font(.footnote)
                }
                if let issue { Text(issue).foregroundStyle(.red) }
            }.navigationTitle("Inbox lifecycle")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .confirmationDialog("Apply Inbox policy on your Mac?", isPresented: $confirmingEnable, titleVisibility: .visible) {
                    Button("Apply policy") { perform { try await service.configure(MobileLifecycleSettingsPatch(activated: true, autoSettleAfterDays: .some(never ? nil : Double(days)))) } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("May immediately auto-settle eligible threads. Preview first if unsure.") }
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { issue = error.localizedDescription } } }
}
