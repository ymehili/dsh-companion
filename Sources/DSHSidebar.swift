import SwiftUI
import UIKit

private struct SidebarEntry: Identifiable {
    let row: SessionRow
    let record: JSONValue
    let shelf: String
    let status: String?
    var id: String { row.id }
}

/// T3 Code mobile thread list (HomeScreen + thread-list-v2 shelves) in the DSH palette,
/// built from native List/Button/Menu/.searchable. Navigation stays system-owned:
/// row taps only update `selection`; the owning NavigationStack routes.
struct DSHSidebar: View {
    @Environment(NativeStore.self) private var store
    @Binding var selection: String?
    let onNew: () -> Void
    let onPair: () -> Void
    let onApprovals: () -> Void
    /// Optional; hidden when nil.
    var onQuestions: (() -> Void)? = nil
    /// Optional; gear and degraded connection status route here. Falls back to a menu when nil.
    var onSettings: (() -> Void)? = nil
    @State private var lifecycle: MobileLifecycleService?
    @State private var showingLifecycleSettings = false
    @State private var lifecycleIssue: String?
    @State private var query = ""
    @State private var discardDraftID: String?
    @State private var draftDiscardIssue: String?
    @State private var limits: [String: Int] = [:]
    @State private var workspaceScope: String? = nil
    @State private var shelfScope: String? = nil
    /// New key: Snoozed/Settled collapsed by default without inheriting the old rail state.
    @AppStorage("dsh.sidebar.t3.collapsedShelves") private var collapsed = "settled,snoozed"
    private let shelves = ["pinned", "inbox", "working", "snoozed", "settled"]
    private let collapsible: Set<String> = ["working", "snoozed", "settled"]
    private let slim: Set<String> = ["snoozed", "settled"]
    private var hasShelves: Bool { store.inboxHasSnapshot && store.inboxAvailable && store.workspaceState.ready }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // Filtering, membership and sort semantics are unchanged; do not edit.
    private func entries() -> [SidebarEntry] {
        store.sessions.compactMap { row in
            guard store.workspaceState.visible(row, current: selection ?? store.selected?.id) else { return nil }
            let workspace = store.workspaceState.title(for: row.id, cwd: row.cwd)
            guard !searching || row.title.localizedCaseInsensitiveContains(query) || workspace.localizedCaseInsensitiveContains(query) || row.cwd.localizedCaseInsensitiveContains(query) else { return nil }
            let record = store.sidebarRecord(for: row)
            let shelf = DesktopInbox.section(record: record, running: row.running)
            guard shelf != "hidden" else { return nil }
            return SidebarEntry(row: row, record: record, shelf: shelf, status: DesktopInbox.status(record: record, running: row.running))
        }
    }
    private func workspace(_ e: SidebarEntry) -> String { store.workspaceState.title(for: e.id, cwd: e.row.cwd) }

    var body: some View {
        // Presentation overlay only: unsent iPhone tasks are not Mac Inbox rows.
        let unscoped = entries().filter { !store.unsentSessions.contains($0.id) }
        let workspaces = Array(Set(unscoped.map(workspace))).sorted()
        // View-only scope narrowing on top of entries(); membership is untouched.
        let all = unscoped.filter { workspaceScope == nil || workspace($0) == workspaceScope }
        List(selection: $selection) {
            Group {
                localDraftsSection
                if workspaces.count > 1 || workspaceScope != nil || hasShelves { scopeChips(workspaces) }
                if !hasShelves || store.inboxError != nil || store.workspaceIssue != nil { syncNotice }
                if hasShelves {
                    ForEach(shelves.filter { shelfScope == nil || $0 == shelfScope }, id: \.self) { shelf in
                        let items = all.filter { $0.shelf == shelf }.sorted { DesktopInbox.precedes($0.record, idA: $0.id, $1.record, idB: $1.id, shelf: shelf) }
                        if !items.isEmpty || ["inbox", "working", "settled"].contains(shelf) {
                            Section {
                                if !collapsible.contains(shelf) || expanded(shelf).wrappedValue {
                                    if items.isEmpty && shelf == "inbox" {
                                        Text("Inbox is clear").font(SidebarAppearance.metaFont).foregroundStyle(DSHTheme.tertiary)
                                            .frame(minHeight: 32).listRowInsets(rowInsets)
                                    }
                                    threadRows(items, shelf: shelf)
                                }
                            } header: { shelfHeader(shelf, count: items.count) }
                        }
                    }
                } else {
                    Section {
                        ForEach(["inbox", "working", "settled"], id: \.self) { shelf in
                            LabeledContent(shelf.capitalized, value: "—")
                                .font(SidebarAppearance.shelfFont).foregroundStyle(DSHTheme.secondary)
                                .frame(minHeight: 32).listRowInsets(rowInsets)
                                .accessibilityIdentifier("shelf-\(shelf)").accessibilityValue("Count unknown")
                        }
                    }
                    if !all.isEmpty {
                        Section { if expanded("all").wrappedValue { threadRows(all, shelf: "all") } }
                            header: { shelfHeader("all", count: all.count, title: "All sessions") }
                    }
                }
                if (searching || workspaceScope != nil) && all.isEmpty {
                    Text(searching ? "No threads matching “\(query)”." : "No threads in this workspace.")
                        .font(.subheadline).foregroundStyle(DSHTheme.secondary)
                        .listRowInsets(EdgeInsets(top: 8, leading: SidebarAppearance.leading, bottom: 8, trailing: SidebarAppearance.trailing))
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 1)
        .environment(\.defaultMinListRowHeight, 32)
        .scrollContentBackground(.hidden)
        .background(SidebarAppearance.rail.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $query, placement: .toolbar, prompt: "Search threads")
        .modifier(MobileCompactSearch())
        .accessibilityIdentifier("sidebar-search")
        .onChange(of: query) { _, _ in limits["settled"] = nil }
        .onChange(of: workspaceScope) { _, _ in limits["settled"] = nil }
        .refreshable { do { try await store.refreshSessions(); await store.refreshInbox() } catch { store.error = error.localizedDescription } }
        .navigationTitle("Threads").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(SidebarAppearance.rail, for: .navigationBar)
        .toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarLeading) { brand }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) { brand }
            }
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingLifecycleSettings = true } label: { Label("Inbox lifecycle", systemImage: "tray") }
                    .disabled(lifecycle == nil || (!store.connected && !store.usesFixture))
                    .accessibilityIdentifier("sidebar-lifecycle-settings")
            }
            ToolbarItem(placement: .topBarTrailing) { settingsButton }
        }
        .background { Button("New thread", action: onNew).keyboardShortcut("n", modifiers: .command).hidden().accessibilityHidden(true) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dsh-sidebar")
        .task { if lifecycle == nil { lifecycle = store.makeMobileLifecycleService() } }
        .onChange(of: store.inboxThreads) { _, _ in
            lifecycle?.synchronize(store.mobileLifecycleSnapshot)
            lifecycle?.expireUndo()
        }
        .onChange(of: store.inboxReplica.epoch) { _, _ in
            lifecycle?.synchronize(store.mobileLifecycleSnapshot)
            lifecycle?.expireUndo()
        }
        .sheet(isPresented: $showingLifecycleSettings) { if let lifecycle { MobileLifecycleSettings(service: lifecycle) } }
        .safeAreaInset(edge: .bottom) {
            if let lifecycle, lifecycle.canUndo {
                HStack {
                    Text("Thread updated").font(.subheadline)
                    Spacer()
                    Button("Undo") {
                        Task { do { try await lifecycle.undo() } catch { lifecycleIssue = error.localizedDescription } }
                    }.accessibilityIdentifier("lifecycle-undo")
                }.padding().background(.regularMaterial)
                    .task(id: lifecycle.undoOffer?.token) {
                        guard let expiry = lifecycle.undoOffer?.expiresAt else { return }
                        let remaining = max(0, expiry - Date().timeIntervalSince1970 * 1000)
                        try? await Task.sleep(for: .milliseconds(Int(remaining) + 1))
                        lifecycle.expireUndo()
                    }
            }
        }
        .alert("Discard local draft?", isPresented: Binding(get: { discardDraftID != nil }, set: { if !$0 { discardDraftID = nil } }), presenting: discardDraftID) { id in
            Button("Discard local draft", role: .destructive) {
                discardDraftID = nil
                Task {
                    if await store.removeLocalDraft(id) {
                        if selection == id { selection = nil }
                    } else { draftDiscardIssue = store.draftSaveErrors[id] ?? "The local draft could not be discarded. It is retained on this iPhone; an in-flight request must finish first." }
                }
            }
            Button("Cancel", role: .cancel) { discardDraftID = nil }
        } message: { _ in
            Text("Only this iPhone’s draft, photos, and saved pending request will be removed. The Mac conversation and any delivered message stay unchanged.")
        }
        .alert("Draft retained", isPresented: Binding(get: { draftDiscardIssue != nil }, set: { if !$0 { draftDiscardIssue = nil } })) {
            Button("OK", role: .cancel) { draftDiscardIssue = nil }
        } message: { Text(draftDiscardIssue ?? "") }
        .alert("Undo not completed", isPresented: Binding(get: { lifecycleIssue != nil }, set: { if !$0 { lifecycleIssue = nil } })) {
            Button("OK", role: .cancel) { lifecycleIssue = nil }
        } message: { Text(lifecycleIssue ?? "") }
    }

    private var rowInsets: EdgeInsets { EdgeInsets(top: 0, leading: SidebarAppearance.leading, bottom: 0, trailing: SidebarAppearance.trailing) }

    // MARK: Toolbar

    /// Compact wordmark plus a connection dot; degraded state taps through to settings.
    private var brand: some View {
        Button { onSettings?() } label: {
            HStack(spacing: 6) {
                DSHBrandWordmark().frame(width: SidebarAppearance.brandWidth, height: SidebarAppearance.brandHeight)
                Circle().fill(SidebarAppearance.connectionColor(connected: store.connected, status: store.status)).frame(width: 6, height: 6)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onSettings == nil)
        .accessibilityLabel("DeepSeek Harness, Mac connection")
        .accessibilityValue(store.status)
        .accessibilityHint(onSettings != nil ? "Opens settings" : "")
        .accessibilityIdentifier("sidebar-connection-status")
    }
    @ViewBuilder private var settingsButton: some View {
        if let onSettings {
            Button(action: onSettings) { Label("Settings", systemImage: "gearshape") }
                .tint(DSHTheme.label).accessibilityIdentifier("sidebar-settings-button")
        } else {
            // No owner-provided settings yet: keep every prior action reachable.
            Menu {
                Text(store.status)
                Button("Reconnect", systemImage: "arrow.clockwise") { Task { await store.connect(force: true) } }
                Button("Pair iPhone", systemImage: "qrcode", action: onPair)
                if let onQuestions { Button("Questions (\(store.questions.count))", systemImage: "questionmark.bubble", action: onQuestions) }
                Button("Approvals (\(store.approvals.count))", systemImage: "hand.raised", action: onApprovals)
            } label: { Label("Settings", systemImage: "gearshape") }
                .tint(DSHTheme.label).accessibilityIdentifier("sidebar-settings-button")
        }
    }

    // MARK: Scope chips (T3 ThreadListFilters; real workspaces only, single Mac)

    private func scopeChips(_ workspaces: [String]) -> some View {
        HStack(spacing: 8) {
            if workspaces.count > 1 || workspaceScope != nil {
                chip(workspaceScope.map(SidebarAppearance.workspaceTitle) ?? "All workspaces", active: workspaceScope != nil, id: "sidebar-scope-workspace") {
                    Button { workspaceScope = nil } label: { checkLabel("All workspaces", on: workspaceScope == nil) }
                    ForEach(workspaces, id: \.self) { w in
                        Button { workspaceScope = w } label: { checkLabel(SidebarAppearance.workspaceTitle(w), on: workspaceScope == w) }
                    }
                }
            }
            if hasShelves {
                chip(shelfScope?.capitalized ?? "All shelves", active: shelfScope != nil, id: "sidebar-scope-shelf") {
                    Button { shelfScope = nil } label: { checkLabel("All shelves", on: shelfScope == nil) }
                    ForEach(shelves, id: \.self) { s in
                        Button { shelfScope = s } label: { checkLabel(s.capitalized, on: shelfScope == s) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: SidebarAppearance.leading, bottom: 3.5, trailing: SidebarAppearance.trailing))
    }
    @ViewBuilder private func checkLabel(_ title: String, on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
    private func chip<C: View>(_ title: String, active: Bool, id: String, @ViewBuilder content: () -> C) -> some View {
        Menu(content: content) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(active ? DSHTheme.label : DSHTheme.secondary)
            .padding(.horizontal, 10.5).frame(minHeight: 30)
            .background(active ? SidebarAppearance.selected : SidebarAppearance.field, in: Capsule())
            .overlay(Capsule().strokeBorder(DSHTheme.separator, lineWidth: 0.5))
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: Sync state (honest unknown/error/retry)

    private var syncNotice: some View {
        Section {
            if !store.workspaceState.ready && store.workspaceIssue == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading Mac visibility…").font(.subheadline).foregroundStyle(DSHTheme.secondary) }
            } else if store.inboxLoading || (!store.inboxHasSnapshot && store.inboxError == nil) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(store.connected ? "Syncing Mac shelves…" : "Connecting to your Mac…").font(.subheadline).foregroundStyle(DSHTheme.secondary) }
            } else if store.inboxHasSnapshot && !store.inboxAvailable {
                Label("Inbox is disabled on your Mac", systemImage: "info.circle").font(.subheadline)
            } else {
                Label(hasShelves ? "Showing last synced shelves" : "Shelves couldn’t sync", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.subheadline)
            }
            if let message = store.workspaceIssue ?? store.inboxError { Text(message).font(.footnote).foregroundStyle(DSHTheme.secondary) }
            if store.workspaceIssue != nil || store.inboxError != nil || (store.inboxHasSnapshot && !store.inboxAvailable) {
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { if store.workspaceIssue != nil { await store.connect(force: true) } else { await store.refreshInbox() } }
                }.font(.subheadline.weight(.medium)).frame(minHeight: 44).disabled(store.inboxLoading).accessibilityIdentifier("retry-inbox-sync")
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: SidebarAppearance.leading, bottom: 2, trailing: SidebarAppearance.trailing))
    }

    // MARK: Local drafts (never Mac shelf membership)

    @ViewBuilder private var localDraftsSection: some View {
        let drafts = store.savedUnsentDrafts.filter { record in
            !searching || NativeOfflineDraftSummary.title(record).localizedCaseInsensitiveContains(query)
                || record.text.localizedCaseInsensitiveContains(query)
                || (record.workspace ?? "").localizedCaseInsensitiveContains(query)
        }
        if !drafts.isEmpty || !store.draftsLoaded || !store.draftLoadIssues.isEmpty {
            Section {
                if !store.draftsLoaded {
                    Label("Loading drafts on this iPhone…", systemImage: "doc.text")
                        .font(SidebarAppearance.metaFont).foregroundStyle(DSHTheme.secondary).listRowInsets(rowInsets)
                }
                ForEach(store.draftLoadIssues, id: \.self) { issue in
                    Text("Some local drafts could not be loaded. Their data is retained. \(issue)")
                        .font(SidebarAppearance.metaFont).foregroundStyle(DSHTheme.secondary)
                        .listRowInsets(rowInsets).accessibilityIdentifier("local-drafts-load-issue")
                }
                ForEach(drafts, id: \.sessionId) { record in
                    localDraftRow(record)
                }
            } header: {
                Text("Drafts on this iPhone").font(SidebarAppearance.shelfFont).foregroundStyle(DSHTheme.secondary)
                    .textCase(nil).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("local-drafts-section")
            }
        }
    }

    private func localDraftRow(_ record: NativeDraftRecord) -> some View {
        Button { selection = record.sessionId } label: {
            VStack(alignment: .leading, spacing: 3.5) {
                Text(NativeOfflineDraftSummary.project(record)).font(SidebarAppearance.projectFont).foregroundStyle(DSHTheme.tertiary).lineLimit(1)
                Text(NativeOfflineDraftSummary.title(record)).font(SidebarAppearance.titleFont).foregroundStyle(DSHTheme.label).lineLimit(2)
                Text(NativeOfflineDraftSummary.detail(record)).font(SidebarAppearance.metaFont).foregroundStyle(DSHTheme.secondary).lineLimit(2)
                if let issue = store.draftSaveErrors[record.sessionId] {
                    Text("Not saved: \(issue)").font(SidebarAppearance.metaFont).foregroundStyle(DSHTheme.statusFailed).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, SidebarAppearance.rowVertical)
            .overlay(alignment: .bottom) { SidebarAppearance.hairline.frame(height: 1 / UIScreen.main.scale) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).listRowInsets(rowInsets).tag(record.sessionId)
        .contextMenu {
            Button("Discard local draft…", systemImage: "trash", role: .destructive) { discardDraftID = record.sessionId }
        }
        .swipeActions(allowsFullSwipe: false) {
            Button("Discard local draft…", systemImage: "trash", role: .destructive) { discardDraftID = record.sessionId }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the draft saved on this iPhone")
        .accessibilityIdentifier("local-draft-\(record.sessionId)")
    }

    // MARK: Rows

    @ViewBuilder private func threadRows(_ items: [SidebarEntry], shelf: String) -> some View {
        let settled = shelf == "settled"
        let limit = limits[shelf] ?? (settled ? SidebarAppearance.settledInitial : 60)
        let page = settled ? SidebarAppearance.settledPage : 60
        let first = Array(items.prefix(limit))
        ForEach(first) { item in thread(item, slim: slim.contains(shelf)) }
        if let selected = items.first(where: { $0.id == selection }), !first.contains(where: { $0.id == selected.id }) { thread(selected, slim: slim.contains(shelf)) }
        if items.count > limit {
            Button("Show \(min(page, items.count - limit)) more") { limits[shelf] = limit + page }
                .font(.footnote.weight(.medium)).tint(DSHTheme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .listRowInsets(rowInsets)
                .accessibilityIdentifier("shelf-\(shelf)-show-more")
        }
    }

    /// T3 row: project + status/time, title (≤2 lines), optional real metadata.
    /// Settled/snoozed collapse to one slim 44pt line.
    private func thread(_ item: SidebarEntry, slim: Bool) -> some View {
        let workspace = SidebarAppearance.workspaceTitle(self.workspace(item))
        let isSelected = (selection ?? store.selected?.id) == item.id
        let time = SidebarAppearance.timeLabel(item.row.updatedAt)
        return Button { selection = item.id } label: {
            VStack(alignment: .leading, spacing: 3.5) {
                if slim {
                    HStack(spacing: 7) {
                        Text(item.row.title).font(SidebarAppearance.titleFont).foregroundStyle(DSHTheme.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        trailing(item, time: time)
                    }
                    .frame(maxWidth: .infinity, minHeight: SidebarAppearance.slimRowHeight - 1, alignment: .leading)
                } else {
                    HStack(spacing: 7) {
                        Text(workspace).font(SidebarAppearance.projectFont).foregroundStyle(DSHTheme.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        trailing(item, time: time)
                    }
                    Text(item.row.title).font(SidebarAppearance.titleFont).foregroundStyle(DSHTheme.label)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if item.row.isSubagent {
                        Text("Subagent").font(SidebarAppearance.metaFont).foregroundStyle(DSHTheme.tertiary)
                    }
                }
            }
            .padding(.vertical, slim ? 0 : SidebarAppearance.rowVertical)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .bottom) { SidebarAppearance.hairline.frame(height: 1 / UIScreen.main.scale) }
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .listRowInsets(rowInsets)
        .tag(item.id)
        .listRowBackground(Rectangle().fill(isSelected ? SidebarAppearance.selected : .clear))
        .listRowSeparator(.hidden)
        .mobileLifecycleActions(row: item.row, record: item.record, service: lifecycle) { selection = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.row.title)
        .accessibilityValue([item.status, workspace, time].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("session-\(item.id)")
    }
    @ViewBuilder private func trailing(_ item: SidebarEntry, time: String?) -> some View {
        HStack(spacing: 5) {
            if let status = item.status {
                if SidebarAppearance.isCompleted(status) {
                    Image(systemName: SidebarAppearance.symbol(for: status)).font(.caption2).foregroundStyle(DSHTheme.statusDone.opacity(0.85))
                } else {
                    Label(status, systemImage: SidebarAppearance.symbol(for: status))
                        .labelStyle(.titleAndIcon).font(SidebarAppearance.statusFont)
                        .foregroundStyle(DSHTheme.statusColor(for: status)).lineLimit(1)
                }
            }
            if let time { Text(time).font(SidebarAppearance.metaFont).monospacedDigit().foregroundStyle(DSHTheme.tertiary) }
        }.fixedSize().layoutPriority(1)
    }

    // MARK: Shelf headers (label 13 medium, count, small chevron, hairline)

    private func shelfHeader(_ shelf: String, count: Int, title: String? = nil) -> some View {
        let name = title ?? shelf.capitalized
        let canToggle = collapsible.contains(shelf) || shelf == "all"
        let open = !canToggle || expanded(shelf).wrappedValue
        return Button { if canToggle { withAnimation(.snappy) { expanded(shelf).wrappedValue.toggle() } } } label: {
            HStack(spacing: 6) {
                Text(name).font(SidebarAppearance.shelfFont).foregroundStyle(DSHTheme.secondary)
                Text("\(count)").font(.footnote).monospacedDigit().foregroundStyle(DSHTheme.tertiary)
                if canToggle {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(DSHTheme.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SidebarAppearance.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .bottom) { SidebarAppearance.hairline.frame(height: 1 / UIScreen.main.scale) }
            .background(SidebarAppearance.rail)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canToggle)
        .textCase(nil)
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) (\(count))")
        .accessibilityValue(canToggle ? (open ? "Expanded" : "Collapsed") : "")
        .accessibilityAddTraits(canToggle ? .isButton : .isHeader)
        .accessibilityIdentifier("shelf-\(shelf)")
    }
    private func expanded(_ shelf: String) -> Binding<Bool> {
        Binding(get: { searching || !collapsed.split(separator: ",").contains(Substring(shelf)) }, set: { value in
            guard !searching else { return }
            var set = Set(collapsed.split(separator: ",").map(String.init))
            if value { set.remove(shelf) } else { set.insert(shelf) }
            collapsed = set.sorted().joined(separator: ",")
        })
    }
}
