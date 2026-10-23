import SwiftUI
import PhotosUI
import UIKit

/// One page per upward user gesture. Layout, keyboard and initial positioning
/// never arm paging; another gesture (or explicit retry) is required afterwards.
struct AutoHistoryTrigger {
    private var armed = false
    mutating func beginGesture() { armed = true }
    mutating func endGesture() { armed = false }
    mutating func shouldLoad(before: CGFloat, after: CGFloat, userScrolling: Bool, eligible: Bool) -> Bool {
        guard armed, userScrolling, after < before, after <= 240 else { return false }
        // An attempted gesture while busy/failed is consumed too: a later
        // layout change must not turn that old intent into a fresh request.
        armed = false
        return eligible
    }
}

private struct HistoryAnchorRestore {
    let id: Int
    let offset: CGFloat
    let preservesBottom: Bool
    let session: String
    let generation: UUID
    let intent: Int
    let revision: Int
}

private struct HistoryItemGeometry: Equatable {
    let frame: CGRect
    let revision: Int
}

private struct ChatViewport: Equatable {
    let height: CGFloat
    let visibleHeight: CGFloat
    let bottomInset: CGFloat
    let topInset: CGFloat
}

/// T3 Code mobile conversation hierarchy (THIRD-PARTY-NOTICES.md) on DSH data:
/// unboxed transcript, inline grouped work, a floating status capsule, inline
/// approval/question cards and a single mounted composer whose TextField keeps
/// its identity while `ChatComposerLayout` moves it between pill and panel.
struct NativeConversation: View {
    let sessionId: String
    var draftWorkspaceTitle: String? = nil
    @Environment(NativeStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var photos: [PhotosPickerItem] = []
    #if DEBUG
    @State private var fixturePhotoBatch = 0
    #endif
    @State private var showComposerModel = false
    @State private var restoreFocusAfterModel = false
    @State private var scrollID: Int?
    @State private var atBottom = true
    @State private var geometryAtBottom = true
    @State private var userScrolling = false
    @State private var historyTrigger = AutoHistoryTrigger()
    @State private var historyGestureActive = false
    /// If a page starts in the middle of consecutive tool rows, keep the mounted
    /// work group's ID when older tools join it (rather than changing its anchor).
    @State private var stableWorkIDs: Set<Int> = []
    @State private var historyItemFrames: [Int: CGRect] = [:]
    @State private var historyVisibleTop: CGFloat = 0
    @State private var historyVisibleHeight: CGFloat = 640
    @State private var scrollIntentRevision = 0
    @State private var historyRestore: HistoryAnchorRestore?
    @State private var expandedWork: Set<String> = []
    @State private var collapsedQuestionID: String?
    @State private var containerHeight: CGFloat = 640
    /// Coalesces a double tap that lands before the first dispatch reaches the Store.
    @State private var dispatchPending = false
    /// A card action waits here for explicit confirmation; it is never sent directly.
    @State private var openUIActions = OpenUIActionInbox()
    @FocusState private var composerFocused: Bool

    private var current: Bool { store.selected?.id == sessionId }
    private var draftPhotos: [DraftPhoto] { store.attachments.photos(in: sessionId) }
    private var loadingPhoto: Bool { store.attachments.isLoading(sessionId) }
    private var hasDraftContent: Bool { !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftPhotos.isEmpty }
    /// T3 new-task stays expanded; existing threads expand only for focus/model.
    private var composerExpanded: Bool { draftWorkspaceTitle != nil || composerFocused || showComposerModel }
    private var running: Bool { current && store.conversation.running }
    private var readOnlySession: Bool { store.selected?.isSubagent == true }
    private var showsStop: Bool { running && !hasDraftContent && !store.sending }
    private var actionDisabled: Bool {
        !current || !store.connected || store.sending
            || (showsStop ? readOnlySession : (!store.canSend || store.hasFailedMessage(sessionId) || loadingPhoto || !hasDraftContent))
    }
    /// Long-press choice is offered only when both real dispatch modes apply.
    private var offersFollowUpChoice: Bool { running && !showsStop && !actionDisabled }
    private var sessionApprovals: [ApprovalCard] { store.approvals.filter { $0.sessionId == sessionId } }
    private var sessionQuestions: [NativeQuestionCard] { store.questions.filter { $0.sessionId == sessionId } }
    private var activeQuestion: NativeQuestionCard? { sessionQuestions.first }
    private var composerHidden: Bool { activeQuestion != nil }

    var body: some View {
        VStack(spacing: 0) {
            content
                .environment(openUIActions)
                .sheet(item: $openUIActions.staged) { action in OpenUIActionConfirmation(action: action) }
        }
            .background(ChatAppearance.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
            .sheet(isPresented: $showComposerModel, onDismiss: {
                // T3 restores the keyboard after the composer's settings sheet closes.
                if restoreFocusAfterModel, !composerHidden, current { composerFocused = true }
                restoreFocusAfterModel = false
            }) { DSHModelPicker() }
            .task { if store.models.isEmpty { await store.loadModels() } }
            .onDisappear {
                composerFocused = false
                scrollIntentRevision += 1
                historyTrigger.endGesture(); historyGestureActive = false; historyRestore = nil
            }
            .onChange(of: store.historyGeneration) { _, _ in
                historyTrigger.endGesture(); historyGestureActive = false; historyRestore = nil
            }
            .onChange(of: photos) { _, chosen in
                guard !chosen.isEmpty else { return }
                store.importPhotos(chosen.map { item in PhotoImportInput { try await item.loadTransferable(type: Data.self) } }, for: sessionId)
                photos = []
            }
            .onChange(of: sessionId) { _, _ in
                photos = []; atBottom = true; scrollID = nil; expandedWork = []; collapsedQuestionID = nil; openUIActions.staged = nil
                historyTrigger.endGesture(); historyGestureActive = false; historyRestore = nil; stableWorkIDs = []; historyItemFrames = [:]
                scrollIntentRevision += 1
            }
            .onChange(of: composerHidden) { _, hidden in if hidden { composerFocused = false } }
    }

    // MARK: Transcript

    @ViewBuilder private var content: some View {
        let entries = current ? store.conversation.entries : []
        if !current || (store.conversationLoad == .loading && entries.isEmpty) {
            ProgressView("Loading conversation…").frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("conversation-loading")
        } else if case .failed(let message) = store.conversationLoad, entries.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t load conversation", systemImage: "exclamationmark.bubble")
            } description: { Text(message) } actions: {
                Button("Retry") { Task { await store.retryConversation() } }
            }.accessibilityIdentifier("conversation-load-error")
        } else {
            VStack(spacing: 0) {
                if case .failed(let message) = store.conversationLoad {
                    HStack(spacing: T3Metric.steps(2)) {
                        Label(message, systemImage: "exclamationmark.triangle").font(.footnote).lineLimit(3)
                        Spacer(minLength: 0)
                        Button("Retry") { Task { await store.retryConversation() } }.font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(DSHTheme.secondary)
                    .padding(.horizontal, T3Metric.steps(4)).padding(.vertical, T3Metric.steps(2))
                }
                transcript(entries)
            }
        }
    }

    private func transcript(_ entries: [ChatEntry]) -> some View {
        let items = TranscriptItem.group(entries, events: store.conversation.events, running: store.conversation.running,
                                         finalCards: store.conversation.finalAnswerCards, preservingWorkIDs: stableWorkIDs)
        let status = floatingStatus
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.conversation.hasMore {
                        HStack {
                            Spacer(minLength: 0)
                            if store.historyLoading {
                                ProgressView("Loading earlier messages…").accessibilityIdentifier("history-loading")
                            } else if let issue = store.historyError {
                                Text(issue)
                                Button("Retry") { loadOlder(items, retry: true) }
                                    .frame(minWidth: T3Metric.actionTarget, minHeight: T3Metric.actionTarget)
                                    .accessibilityIdentifier("history-retry")
                            } else {
                                Text("Scroll up for earlier messages")
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.footnote).foregroundStyle(DSHTheme.secondary)
                        .frame(minHeight: T3Metric.actionTarget)
                        .padding(.bottom, T3Metric.steps(3))
                    }
                    ForEach(items) { item in
                        Group {
                            switch item {
                            case .message(let entry, let footer, let cards):
                                NativeMessage(entry: entry, time: entry.time, sessionId: sessionId, showsFooter: footer, finalCards: cards).equatable()
                                    .accessibilityElement(children: .contain).accessibilityIdentifier("chat-message-\(entry.id)")
                                    .padding(.bottom, Self.spacing(after: entry, footer: footer))
                            case .work(let id, let rows, let live):
                                ToolWorkGroup(groupID: id, rows: rows, live: live, expanded: expandedWork) { key in
                                    if expandedWork.contains(key) { expandedWork.remove(key) } else { expandedWork.insert(key) }
                                }
                                .padding(.bottom, T3Metric.steps(2))
                            }
                        }
                        .id(item.id)
                        .onGeometryChange(for: HistoryItemGeometry.self) {
                            HistoryItemGeometry(frame: $0.frame(in: .named("history-viewport")), revision: store.conversation.transcriptRevision)
                        } action: {
                            historyItemFrames[item.id] = $0.frame
                            restoreHistoryAnchor(item.id, proxy: proxy)
                        }
                        .onDisappear { historyItemFrames[item.id] = nil }
                    }
                    if !store.conversation.streamingReasoning.isEmpty || !store.conversation.streamingText.isEmpty {
                        VStack(alignment: .leading, spacing: T3Metric.steps(3)) {
                            if !store.conversation.streamingReasoning.isEmpty {
                                TranscriptDisclosure(symbol: "brain", title: "Thinking…") {
                                    NativeMarkdown(text: store.conversation.streamingReasoning, streaming: true).foregroundStyle(DSHTheme.secondary)
                                }
                            }
                            if !store.conversation.streamingText.isEmpty {
                                NativeAssistantMarkdown(text: store.conversation.streamingText, streaming: true)
                            }
                        }
                        .padding(.horizontal, T3Metric.steps(1))
                        .padding(.bottom, T3Metric.steps(3))
                        .id(-2)
                    }
                    if entries.isEmpty && store.conversationLoad.isLoaded && store.conversation.attempt == nil {
                        if let draftWorkspaceTitle { MobileDraftHero(workspace: draftWorkspaceTitle) }
                        else { ContentUnavailableView("Start a conversation", systemImage: "bubble.left.and.text.bubble.right", description: Text("Messages run in this workspace on your Mac.")) }
                    }
                    Color.clear.frame(height: 1).id(-1)
                }
                .scrollTargetLayout()
                .padding().frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "history-viewport")
            .accessibilityIdentifier("conversation-scroll")
            .contentMargins(.bottom, status == nil ? 0 : T3Metric.capsuleHeight + T3Metric.capsuleGap, for: .scrollContent)
            .scrollPosition(id: $scrollID, anchor: .top)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(atBottom ? .bottom : .top, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height || geometry.visibleRect.maxY >= geometry.contentSize.height - 70
            } action: { _, visible in
                geometryAtBottom = visible
                // Viewport/lazy-layout transients must not change follow intent.
                // Only a user's scroll (or explicit Latest action) re-enables it.
                if userScrolling { atBottom = visible }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { before, after in
                let eligible = current && store.conversationLoad.isLoaded && store.conversation.hasMore
                    && store.connected && !store.historyLoading && store.historyError == nil
                if historyTrigger.shouldLoad(before: before, after: after, userScrolling: historyGestureActive, eligible: eligible) {
                    loadOlder(items)
                }
            }
            .onScrollGeometryChange(for: ChatViewport.self) { geometry in
                ChatViewport(height: geometry.containerSize.height, visibleHeight: geometry.visibleRect.height, bottomInset: geometry.contentInsets.bottom, topInset: geometry.contentInsets.top)
            } action: { before, after in
                if before.height != after.height || before.bottomInset != after.bottomInset || before.topInset != after.topInset { historyRestore = nil }
                // Both the named coordinate origin and containerSize describe
                // the usable viewport; safe-area insets must not be subtracted twice.
                historyVisibleTop = 0
                historyVisibleHeight = after.height
                guard before != after, atBottom, !userScrolling, !store.historyLoading else { return }
                // Keyboard/safe-area/composer/capsule changes don't mutate transcriptRevision.
                // Re-anchor after the new viewport has been laid out, not on a keyboard timer.
                Task { @MainActor in
                    await Task.yield()
                    guard atBottom, !userScrolling, !store.historyLoading else { return }
                    proxy.scrollTo(-1, anchor: .bottom)
                }
            }
            .onScrollPhaseChange { before, phase in
                if phase == .tracking { historyTrigger.beginGesture(); historyGestureActive = false; scrollIntentRevision += 1; historyRestore = nil }
                if phase == .interacting {
                    if before != .tracking && before != .decelerating { historyTrigger.beginGesture() }
                    historyGestureActive = true
                }
                if phase == .idle { historyTrigger.endGesture(); historyGestureActive = false }
                switch phase {
                case .tracking, .interacting, .decelerating:
                    userScrolling = true
                    if phase == .interacting && composerFocused { composerFocused = false }
                    if !geometryAtBottom { atBottom = false }
                case .idle:
                    let finishedUserScroll = userScrolling
                    userScrolling = false
                    if finishedUserScroll && geometryAtBottom { atBottom = true }
                default: break
                }
            }
            .overlay(alignment: .bottom) {
                ConversationFloatingControl(status: status, showsLatest: !atBottom, retry: {
                    Task { await store.connect(force: true) }
                }, latest: {
                    scrollIntentRevision += 1; historyRestore = nil
                    scrollID = -1
                    proxy.scrollTo(-1, anchor: .bottom); atBottom = true
                })
                // The dock's 6pt top padding completes T3's 8pt capsule-to-composer gap.
                .padding(.bottom, 2)
            }
            .onChange(of: store.conversation.transcriptRevision) { _, _ in if atBottom && !store.historyLoading { proxy.scrollTo(-1, anchor: .bottom) } }
            .onChange(of: store.conversation.streamingText) { _, _ in if atBottom { proxy.scrollTo(-1, anchor: .bottom) } }
            .task(id: sessionId) { proxy.scrollTo(-1, anchor: .bottom) }
        }
    }

    private func loadOlder(_ items: [TranscriptItem], retry: Bool = false) {
        guard current, !store.historyLoading else { return }
        for item in items { if case .work(let id, _, _) = item { stableWorkIDs.insert(id) } }
        atBottom = false
        let id = sessionId, context = store.historyGeneration
        Task { @MainActor in
            guard store.selected?.id == id, store.historyGeneration == context else { return }
            await store.older(retry: retry, willPrepend: {
                // Capture immediately before mutation, not before the network
                // await: the reader may have moved while the page was loading.
                let top = historyVisibleTop
                if !atBottom, let row = historyItemFrames.filter({ $0.value.maxY > top && $0.value.minY < top + historyVisibleHeight })
                    .min(by: { $0.value.minY < $1.value.minY }) {
                    // Older tools are inserted before existing expanded rows.
                    // Keeping this group's bottom keeps those semantic rows (and
                    // any expanded details) stationary, rather than its header.
                    let workTail = stableWorkIDs.contains(row.key) && expandedWork.contains("group-\(row.key)")
                    historyRestore = HistoryAnchorRestore(id: row.key, offset: workTail ? row.value.maxY : row.value.minY,
                                                         preservesBottom: workTail, session: id, generation: context,
                                                         intent: scrollIntentRevision, revision: store.conversation.transcriptRevision)
                }
            })
        }
    }

    private func restoreHistoryAnchor(_ laidOutID: Int, proxy: ScrollViewProxy) {
        guard let anchor = historyRestore, anchor.id == laidOutID,
              store.conversation.transcriptRevision != anchor.revision else { return }
        historyRestore = nil
        guard store.selected?.id == anchor.session, store.historyGeneration == anchor.generation,
              scrollIntentRevision == anchor.intent, store.conversation.transcriptRevision == anchor.revision + 1, !atBottom else { return }
        // Wait for the target's actual new layout, not a timer/Task.yield: the
        // lazy stack may not have incorporated the page on that first task turn.
        guard let frame = historyItemFrames[anchor.id] else { return }
        let offset = anchor.preservesBottom ? anchor.offset - frame.height : anchor.offset
        let space = historyVisibleHeight - frame.height
        guard abs(space) > 1 else { return } // Never force a viewport-sized row to zero.
        let fraction = offset / space
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(anchor.id, anchor: UnitPoint(x: 0.5, y: fraction)) }
    }

    private static func spacing(after entry: ChatEntry, footer: Bool) -> CGFloat {
        switch entry.role {
        case "user": return T3Metric.steps(5)
        case "assistant": return footer ? T3Metric.steps(5) : T3Metric.steps(3)
        default: return T3Metric.steps(3)
        }
    }

    /// T3 priority: connection, loading, a pending interaction blocking the
    /// agent, then working. Nothing is shown when connected, loaded and idle.
    private var floatingStatus: ConversationStatus? {
        if !store.connected {
            return store.connecting ? .connecting(store.status) : .unavailable(store.status)
        }
        guard current else { return nil }
        if store.conversationLoad == .loading && !store.conversation.entries.isEmpty { return .loading("Updating conversation…") }
        guard store.conversation.running else { return nil }
        if !sessionApprovals.isEmpty { return .waiting("Waiting for approval", symbol: "hand.raised.fill") }
        if activeQuestion != nil { return .waiting("Waiting for your answer", symbol: "questionmark.bubble.fill") }
        return .working
    }

    // MARK: Bottom dock

    private var dock: some View {
        let question = activeQuestion
        return VStack(spacing: T3Metric.steps(3)) {
            notices
            if let issue = store.draftSaveErrors[sessionId] {
                Text(issue).font(.footnote).foregroundStyle(DSHTheme.statusAttention).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("draft-save-error")
            }
            if !store.draftsLoaded { ProgressView("Restoring your drafts…").font(.footnote) }
            if let approval = sessionApprovals.first {
                InlineApprovalCard(card: approval, remaining: sessionApprovals.count - 1).id(approval.id)
            }
            ZStack(alignment: .bottom) {
                // Hidden, never destroyed: the composer keeps its draft, editor
                // identity and selection while a question owns the slot.
                composer
                    .frame(height: question == nil ? nil : 0, alignment: .bottom)
                    .opacity(question == nil ? 1 : 0)
                    .allowsHitTesting(question == nil)
                    .accessibilityHidden(question != nil)
                if let question, let index = sessionQuestions.firstIndex(of: question) {
                    NativeInlineQuestionSlot(card: question, position: index + 1, total: sessionQuestions.count,
                                             collapsed: Binding(get: { collapsedQuestionID == question.id },
                                                                set: { collapsedQuestionID = $0 ? question.id : nil }),
                                             maxHeight: max(240, containerHeight * 0.62))
                        .id(question.id)
                }
            }
            if let note = readOnlyNote {
                Text(note).font(.footnote).foregroundStyle(DSHTheme.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, T3Metric.steps(2))
            }
        }
        .padding(.horizontal, T3Metric.composerHorizontalPadding)
        .padding(.top, composerExpanded ? 8 : 6)
        .padding(.bottom, composerExpanded ? 8 : 6)
        .frame(maxWidth: 760 + 2 * T3Metric.composerHorizontalPadding)
        .frame(maxWidth: .infinity)
        .background {
            // T3 `from-screen/0 via-screen/60 to-screen/90` backdrop.
            LinearGradient(stops: [
                .init(color: ChatAppearance.canvas.opacity(0), location: 0),
                .init(color: ChatAppearance.canvas.opacity(0.6), location: 0.45),
                .init(color: ChatAppearance.canvas.opacity(0.9), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }

    private var readOnlyNote: String? {
        guard current, store.connected, store.conversationLoad.isLoaded, let row = store.selected else { return nil }
        if row.isSubagent { return "Subagent sessions can’t receive messages from iPhone." }
        if store.workspaceState.archived.contains(row.id) { return "This session is archived on your Mac." }
        return nil
    }

    @ViewBuilder private var notices: some View {
        if let warning = store.deliveryWarnings[sessionId] {
            ComposerNotice {
                Label(warning, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(DSHTheme.statusAttention)
                DisclosureGroup("Unconfirmed message") {
                    Text(store.failedMessageText(sessionId).flatMap { $0.isEmpty ? nil : $0 } ?? "Photo message")
                        .font(.footnote).foregroundStyle(DSHTheme.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote).tint(DSHTheme.secondary)
                HStack {
                    Button("Retry message") { Task { await store.retryFailedMessage(sessionId) } }
                        .disabled(!store.connected || store.sending)
                    Spacer(minLength: 0)
                    Menu("More") {
                        Button("Copy original text", systemImage: "doc.on.doc") { UIPasteboard.general.string = store.failedMessageText(sessionId) ?? "" }
                        Button("Discard local failed message", role: .destructive) { store.discardFailedMessage(sessionId) }
                    }
                }
                .font(.footnote.weight(.semibold)).buttonStyle(.borderless).tint(DSHTheme.accent)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("delivery-warning")
        }
        if let issue = store.photoImportErrors[sessionId] {
            ComposerNotice {
                Label(issue, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(DSHTheme.statusAttention)
                    .accessibilityIdentifier("photo-import-error")
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        let expanded = composerExpanded
        let shape = RoundedRectangle(cornerRadius: expanded ? T3Metric.expandedRadius : T3Metric.collapsedRadius, style: .continuous)
        let hasAttachments = !draftPhotos.isEmpty || loadingPhoto
        return VStack(alignment: .leading, spacing: 0) {
            if expanded && hasAttachments {
                PhotoAttachmentsView(photos: draftPhotos, loading: loadingPhoto, remove: { id in
                    store.removeDraftPhoto(sessionId, photoID: id)
                }, cancel: {
                    store.cancelPhotoImport(sessionId); photos = []
                })
                .padding(.horizontal, T3Metric.expandedEditorInset)
                .padding(.bottom, T3Metric.steps(2.5))
                .transition(.opacity)
            }
            ChatComposerLayout(expanded: expanded) {
                attachButton
                editor(Binding(get: { store.savedDraftText(sessionId) }, set: { store.updateDraftText($0, for: sessionId) }), expanded: expanded)
                ZStack {
                    if !expanded && hasAttachments {
                        CompactPhotoAttachments(photos: draftPhotos, loading: loadingPhoto) { if current { composerFocused = true } }
                    }
                }
                modelControl
                    .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
                actionButton
            }
        }
        .padding(.top, expanded ? T3Metric.expandedPaddingTop : T3Metric.collapsedPaddingVertical)
        .padding(.bottom, expanded ? T3Metric.expandedPaddingBottom : T3Metric.collapsedPaddingVertical)
        .frame(minHeight: expanded ? T3Metric.expandedMinHeight : nil, alignment: .top)
        .background(ChatAppearance.surface, in: shape)
        .overlay(shape.strokeBorder(ChatAppearance.border, lineWidth: 0.5))
        .shadow(color: ChatAppearance.shadow, radius: 14, y: 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: expanded)
        .accessibilityElement(children: .contain).accessibilityIdentifier("chat-composer-surface")
    }

    private var attachGlyph: some View {
        Image(systemName: "plus").font(.system(size: 20, weight: .regular)).foregroundStyle(DSHTheme.label)
            .frame(width: T3Metric.actionTarget, height: T3Metric.actionTarget).contentShape(Rectangle())
    }
    private var nativePhotoPicker: some View {
        PhotosPicker(selection: $photos, maxSelectionCount: max(1, store.photoLimits.maxCount - draftPhotos.count), selectionBehavior: .ordered, matching: .images) { attachGlyph }
    }
    private var attachButton: some View {
        Group {
            #if DEBUG
            if store.usesSyntheticPhotoPicker {
                Button {
                    store.importPhotos(NativePhotoImportFixture.inputs(batch: fixturePhotoBatch), for: sessionId)
                    fixturePhotoBatch += 1
                } label: { attachGlyph }
            } else { nativePhotoPicker }
            #else
            nativePhotoPicker
            #endif
        }
        .buttonStyle(.plain)
        .disabled(!current || !store.draftsLoaded || loadingPhoto || !store.photoLimits.acceptsJPEG || draftPhotos.count >= store.photoLimits.maxCount)
        .opacity(!current || loadingPhoto || !store.photoLimits.acceptsJPEG || draftPhotos.count >= store.photoLimits.maxCount ? 0.45 : 1)
        .accessibilityLabel("Attach photos").accessibilityHint("Select multiple photos in order, up to \(store.photoLimits.maxCount) total")
    }

    private func editor(_ text: Binding<String>, expanded: Bool) -> some View {
        TextField("Ask your agent…", text: text, axis: .vertical)
            .font(.body)
            .lineLimit(expanded ? 1...6 : 1...1)
            .textFieldStyle(.plain)
            .focused($composerFocused)
            .disabled(!current || !store.draftsLoaded || store.removingLocalDrafts.contains(sessionId))
            .accessibilityIdentifier("nativeComposer")
            .padding(.vertical, expanded ? T3Metric.editorVerticalPadding : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: expanded ? .topLeading : .leading)
            .background {
                // Taps on the editor's empty band focus it, as on T3's full-height editor.
                Color.clear.contentShape(Rectangle()).onTapGesture { if current { composerFocused = true } }
            }
    }

    private var modelControl: some View {
        Button {
            restoreFocusAfterModel = composerFocused
            showComposerModel = true
        } label: {
            ComposerModelLabel(title: store.currentModelLabel)
        }
        .buttonStyle(ComposerInlineButtonStyle())
        .disabled(!store.connected || !current)
        .accessibilityLabel("Choose model")
        .accessibilityValue(store.currentModelLabel)
    }

    private var actionButton: some View {
        let stop = showsStop
        let defaultMode = running ? store.followUpMode : "queue"
        let kind: ComposerActionGlyph.Kind = stop ? .stop : (store.sending ? .sending : (running ? (defaultMode == "steer" ? .steer : .queue) : .send))
        return Button { perform(stopIntent: stop, mode: defaultMode) } label: {
            ComposerActionGlyph(kind: kind, disabled: actionDisabled)
        }
        .buttonStyle(.plain)
        .disabled(actionDisabled)
        .contextMenu {
            if offersFollowUpChoice {
                Button { perform(stopIntent: false, mode: "steer") } label: {
                    Label { Text("Steer now"); Text("Change direction at the next step") } icon: {
                        Image(systemName: store.followUpMode == "steer" ? "checkmark" : "arrow.turn.left.up")
                    }
                }
                Button { perform(stopIntent: false, mode: "queue") } label: {
                    Label { Text("Queue"); Text("Send after the current turn") } icon: {
                        Image(systemName: store.followUpMode == "queue" ? "checkmark" : "list.number")
                    }
                }
            }
        }
        .accessibilityLabel(stop ? "Stop agent" : (running ? (defaultMode == "steer" ? "Steer agent" : "Queue message") : "Send message"))
        .accessibilityHint(offersFollowUpChoice ? "Touch and hold to choose Steer now or Queue for this message" : "")
    }

    /// Captures intent, dispatch mode and the ordered photo bytes on the tap,
    /// before any suspension; the Store owns delivery and exact-ID retries.
    private func perform(stopIntent: Bool, mode: String) {
        guard !dispatchPending else { return }
        let id = sessionId
        let images = draftPhotos.map(\.data)
        dispatchPending = true
        Task {
            defer { dispatchPending = false }
            if stopIntent { if store.selected?.id == id { await store.stop() } }
            else { _ = await store.send(for: id, images: images, mode: mode) }
        }
    }
}

// MARK: Transcript model

enum TranscriptItem: Identifiable {
    /// `cards` are the completed turn's prepared `openui_card` results; non-empty
    /// only on that turn's final assistant reply (see `OpenUITurnLedger`).
    case message(ChatEntry, footer: Bool, cards: [OpenUIFinalCard] = [])
    case work(id: Int, rows: [ToolWorkRow], live: Bool)

    var id: Int {
        switch self {
        case .message(let entry, _, _): return entry.id
        case .work(let id, _, _): return id
        }
    }

    /// Groups consecutive tool rows and marks the terminal assistant answer of
    /// each settled turn (T3 `terminalAssistantMessageIds`). The tail turn is
    /// unsettled while the session reports it is running. Final-answer cards
    /// come from the cached ledger by reply seq (an O(1) lookup per row); tool
    /// work groups never receive card data.
    static func group(_ entries: [ChatEntry], events: [Int: JSONValue], running: Bool,
                      finalCards: [Int: [OpenUIFinalCard]] = [:], preservingWorkIDs: Set<Int> = []) -> [TranscriptItem] {
        var rows: [TranscriptItem] = []
        var tools: [ChatEntry] = []
        var lastAssistant: Int?
        func flushTools() {
            guard let first = tools.first else { return }
            let id = tools.first(where: { preservingWorkIDs.contains($0.id) })?.id ?? first.id
            rows.append(.work(id: id, rows: ToolWork.rows(tools, events: events), live: false))
            tools.removeAll()
        }
        func settleTurn() {
            if let index = lastAssistant, case .message(let entry, _, let cards) = rows[index] { rows[index] = .message(entry, footer: true, cards: cards) }
            lastAssistant = nil
        }
        for entry in entries {
            if entry.tool != nil { tools.append(entry); continue }
            flushTools()
            if entry.role == "user" || entry.role == "context" { settleTurn() }
            let cards = entry.role == "assistant" ? finalCards[entry.id] ?? [] : []
            rows.append(.message(entry, footer: false, cards: cards))
            if entry.role == "assistant" && !entry.text.isEmpty { lastAssistant = rows.count - 1 }
        }
        flushTools()
        if running {
            if case .work(let id, let work, _)? = rows.last { rows[rows.count - 1] = .work(id: id, rows: work, live: true) }
        } else {
            settleTurn()
        }
        return rows
    }
}

// MARK: Messages

struct NativeMessage: View, Equatable {
    let entry: ChatEntry
    var time: Double? = nil
    var sessionId: String? = nil
    /// Settled terminal assistant answer: show the copy/share/time footer.
    var showsFooter = false
    /// Prepared cards of a completed turn; only its final assistant reply has any.
    var finalCards: [OpenUIFinalCard] = []

    var body: some View {
        Group {
            if entry.role == "user" {
                userMessage
            } else if entry.role == "context" {
                TranscriptDisclosure(symbol: "text.badge.plus", title: [entry.contextTitle, entry.contextLabel].compactMap { $0 }.joined(separator: " · "),
                                     subtitle: entry.contextSummary) {
                    NativeMarkdown(text: entry.text).foregroundStyle(DSHTheme.secondary)
                }
            } else if entry.tool != nil {
                TranscriptDisclosure(symbol: ToolWork.symbol(for: entry.tool ?? ""), title: entry.text) {
                    Text(entry.detail ?? "No text output").font(.system(.caption, design: .monospaced)).foregroundStyle(DSHTheme.secondary).textSelection(.enabled)
                }
            } else {
                assistantMessage
            }
        }
        .tint(DSHTheme.secondary)
    }

    /// T3 user bubble: right-aligned, radius 20, max 85%, time and copy below.
    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: T3Metric.steps(1)) {
            if let sessionId, !entry.imageReferences.isEmpty {
                ForEach(entry.imageReferences) { reference in
                    HStack { Spacer(minLength: 64); ChatAttachmentImage(reference: reference, sessionId: sessionId).frame(maxWidth: 240) }
                }
            }
            if !entry.text.isEmpty || entry.imageReferences.isEmpty {
                TrailingFractionLayout(fraction: 0.85) {
                    VStack(alignment: .leading, spacing: T3Metric.steps(2)) {
                        if !entry.text.isEmpty {
                            Text(NativeMarkdownCache.inline(entry.text, cache: true))
                                .font(.callout).lineSpacing(4)
                                .foregroundStyle(ChatAppearance.userText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if entry.imageReferences.isEmpty {
                            ForEach(Array(entry.images.enumerated()), id: \.offset) { _, name in
                                Label(name, systemImage: "photo").font(.caption).foregroundStyle(DSHTheme.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, T3Metric.steps(3.5)).padding(.vertical, T3Metric.steps(2.5))
                    .background(ChatAppearance.userBubble, in: RoundedRectangle(cornerRadius: T3Metric.bubbleRadius, style: .continuous))
                }
                .environment(\.openURL, OpenURLAction { url in MarkdownInline.safeLink(url) == nil ? .discarded : .systemAction })
            }
            MessageMeta(time: time, copyText: entry.text)
                .padding(.trailing, T3Metric.steps(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Unboxed assistant answer; the footer appears only once the turn settles.
    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: T3Metric.steps(3)) {
            if !entry.reasoning.isEmpty {
                TranscriptDisclosure(symbol: "brain", title: "Thinking") {
                    NativeMarkdown(text: entry.reasoning).foregroundStyle(DSHTheme.secondary)
                }
            }
            if !entry.text.isEmpty {
                if entry.role == "assistant" { NativeAssistantMarkdown(text: entry.text, sessionId: sessionId) }
                else { NativeMarkdown(text: entry.text) }
            }
            if let sessionId, !entry.imageReferences.isEmpty {
                ForEach(entry.imageReferences) { reference in ChatAttachmentImage(reference: reference, sessionId: sessionId) }
            } else {
                ForEach(Array(entry.images.enumerated()), id: \.offset) { _, name in
                    Label(name, systemImage: "photo").font(.caption).foregroundStyle(DSHTheme.secondary)
                }
            }
            if entry.role == "assistant" && !finalCards.isEmpty {
                OpenUIFinalAnswerCards(cards: finalCards, replyID: entry.id, sessionId: sessionId)
            }
            if showsFooter && !entry.text.isEmpty {
                HStack(spacing: T3Metric.steps(1)) {
                    ChatMessageActions(text: entry.text).fixedSize(horizontal: true, vertical: false)
                    MessageMeta(time: time, copyText: nil)
                    Spacer(minLength: 0)
                }
                // Align the first 44pt target's glyph with the text edge.
                .padding(.leading, -14).padding(.vertical, -6)
            }
        }
        .padding(.horizontal, T3Metric.steps(1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A completed turn's prepared `openui_card` results, mounted only inside that
/// turn's final assistant answer (below its text, above its footer). Each card is
/// the existing committed sandbox with its native-source fallback; actions still
/// require the confirmation sheet. The title is literal native text.
struct OpenUIFinalAnswerCards: View {
    let cards: [OpenUIFinalCard]
    let replyID: Int
    var sessionId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: T3Metric.steps(4)) {
            ForEach(cards) { item in
                VStack(alignment: .leading, spacing: T3Metric.steps(2)) {
                    if item.card.catalog == "chat-v1" {
                        Text(verbatim: item.card.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(DSHTheme.secondary)
                            .textSelection(.enabled)
                    }
                    OpenUICard(source: item.card.source, streaming: false, sessionId: sessionId, cardId: item.id, catalog: item.card.catalog)
                        .id([sessionId ?? "", item.id, item.card.catalog, item.card.source])
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("openui-final-card-\(item.id)")
            }
        }
        .padding(.vertical, T3Metric.steps(1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openui-final-answer-\(replyID)")
    }
}

/// Time (from the durable event) and an optional copy action.
private struct MessageMeta: View {
    let time: Double?
    let copyText: String?
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 13

    var body: some View {
        HStack(spacing: T3Metric.steps(1)) {
            if let time {
                Text(Date(timeIntervalSince1970: time / 1000).formatted(date: .omitted, time: .shortened))
                    .font(.system(size: size, weight: .medium)).monospacedDigit()
                    .foregroundStyle(DSHTheme.secondary)
            }
            if let copyText, !copyText.isEmpty { MessageCopyButton(text: copyText) }
        }
    }
}

private struct MessageCopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = text; copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DSHTheme.tertiary)
                .frame(width: T3Metric.actionTarget, height: T3Metric.actionTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A 28pt layout footprint (T3) that keeps the 44pt touch target.
        .padding(-8)
        .accessibilityLabel(copied ? "Copied" : "Copy message")
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
        }
    }
}

/// Compact work-log style disclosure for thinking, context and stray tool rows.
private struct TranscriptDisclosure<Content: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var subtitleSize: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = T3Metric.workRowHeight

    var body: some View {
        VStack(alignment: .leading, spacing: T3Metric.steps(1)) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: T3Metric.steps(1.5)) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DSHTheme.tertiary)
                        .frame(width: T3Metric.steps(6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: labelSize)).foregroundStyle(DSHTheme.secondary).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.system(size: subtitleSize)).foregroundStyle(DSHTheme.tertiary).lineLimit(2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    T3DisclosureChevron(expanded: expanded)
                }
                .padding(.horizontal, T3Metric.steps(0.5))
                .frame(minHeight: rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(T3WorkRowButtonStyle())
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                content()
                    .padding(.leading, T3Metric.steps(7.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
    }
}
