import Foundation
import Observation
import WebKit
import UIKit

struct ApprovalCard: Identifiable {
    let id: String
    let sessionId: String
    let tool: String
    let reason: String
}

@MainActor @Observable
final class NativeStore {
    var paired = false
    /// Memory-only media cache identity; rotates when this device authorizes again.
    var imageAuthorizationScope = UUID()
    var sessions: [SessionRow] = []
    var selected: SessionRow?
    var conversation = Conversation()
    var conversationLoad: ConversationLoadState = .idle
    var approvals: [ApprovalCard] = []
    var status = "Disconnected"
    var error: String?
    var pairingError: String?
    var modelError: String?
    var connectionIssue: String?
    var deliveryWarnings: [String: String] = [:]
    var busy = false
    var draft = ""
    var localDraftRecords: [String: NativeDraftRecord] = [:]
    var unsentSessions: Set<String> = []
    var draftsLoaded = true
    var draftLoadIssues: [String] = []
    var draftSaveErrors: [String: String] = [:]
    var removingLocalDrafts: Set<String> = []
    private let draftVault: (any NativeDraftPersisting)?
    private let requiresDurableDrafts: Bool
    private var draftRevisions: [String: UInt64] = [:]
    private var draftRevisionConflicts: Set<String> = []
    @ObservationIgnored private var draftLoadTask: Task<Void, Never>?
    @ObservationIgnored private var draftWriteTasks: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private var draftDebounceTasks: [String: Task<Void, Never>] = [:]
    var connected = false
    var connecting = false
    var connectionDeadline: Duration = .seconds(15)
    /// A page belongs to one exact selected follow/baseline, never just a session ID.
    private(set) var historyGeneration = UUID()
    private var historyRequest: UUID?
    var historyLoading: Bool { historyRequest != nil }
    private(set) var historyError: String?
    enum HistoryResult: Equatable { case loaded, end, failed, superseded, unavailable, busy }
    private func resetHistory() {
        historyGeneration = UUID(); historyRequest = nil; historyError = nil
    }
    var inboxThreads: [String: JSONValue] = [:]
    var inboxAvailable = false
    var inboxHasSnapshot = false
    var inboxLoading = false
    var inboxError: String?
    var inboxReplica = InboxReplica()
    var workspaceState = WorkspaceReplica()
    var workspaceIssue: String?
    private var workspaceStream = ""
    var inboxWatchTask: Task<Void, Never>?
    var inboxWatchGeneration = UUID()
    var desktopProjections: [String: JSONValue] = [:]
    var models: [NativeModelChoice] = []
    var modelLoading = false
    var deciding: Set<String> = []
    var liveQuestions: [NativeQuestionCard] = []
    var questionSubmitting: Set<String> = []
    var questionErrors: [String: String] = [:]
    let questionDraftBook = NativeQuestionDrafts()
    let questionLeaseBook = NativeQuestionLeases()
    func questionPresentationKey(_ card: NativeQuestionCard) -> String { "\(imageAuthorizationScope.uuidString):\(card.sessionId):\(card.callId ?? card.id)" }
    private var questionWaitStreams: [String: String] = [:]
    private var submittedQuestionKeys: Set<String> = []
    private func questionKey(_ card: NativeQuestionCard) -> String { card.callId.map { "\(card.sessionId):\($0)" } ?? card.id }
    var questions: [NativeQuestionCard] {
        var result = liveQuestions
        for sessionId in desktopProjections.keys.sorted() {
            for pending in desktopProjections[sessionId]?["userQuestions"]["active"].array ?? [] {
                guard pending["state"].string == "continued", let callId = pending["callId"].string,
                      !result.contains(where: { $0.sessionId == sessionId && $0.callId == callId }),
                      let card = NativeQuestionCard(id: "continued:\(sessionId):\(callId)", sessionId: sessionId, request: pending, continued: true) else { continue }
                result.append(card)
            }
        }
        return result.filter { !submittedQuestionKeys.contains(questionKey($0)) }
    }
    var attachments = AttachmentDrafts()
    var photoImportErrors: [String: String] = [:]
    @ObservationIgnored var photoImportTasks: [String: Task<Void, Never>] = [:]
    private struct PendingPrompt: Sendable {
        let requestID: String; let text: String; let images: [Data]; let mode: String; let clientTimeZone: String?
    }
    var photoLimits: PhotoLimits { PhotoLimits(currentProjection["imageLimits"]) }
    var followUpMode = "steer"
    func setFollowUpMode(_ mode: String) {
        guard ["queue", "steer"].contains(mode) else { return }
        followUpMode = mode
        if restoreCredentials { UserDefaults.standard.set(mode, forKey: "dsh.mobile.followUpMode") }
    }
    private var sendingRequests: [String: String] = [:]
    private var failedPrompts: [String: PendingPrompt] = [:]
    private var receivedRequestIDs: [String] = []
    var sending: Bool { selected.map { sendingRequests[$0.id] != nil } ?? false }
    func hasFailedMessage(_ id: String) -> Bool { failedPrompts[id] != nil }
    var canSend: Bool { draftsLoaded && connected && conversationLoad.isLoaded && workspaceState.ready && selected?.isSubagent != true && selected.map { !workspaceState.archived.contains($0.id) } == true }
    let gateway: any NativeTransport
    private let pairingClient: any NativePairingClient
    private let restoreCredentials: Bool
    private var eventStream = ""
    private var followStream = ""
    private var controlStream = ""
    private var projectionSequences: [String: Int] = [:]
    private var clientId: String?
    private var reconnectTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    @ObservationIgnored private var followOpeningTask: Task<Void, Error>?
    private struct AuxiliarySubscription {
        let generation: UUID
        let endpoint: String
        let onEvent: (JSONValue) -> Void
        let onClose: (String?) -> Void
        var opening: Task<Void, Error>?
    }
    @ObservationIgnored private var auxiliaryStreams: [String: AuxiliarySubscription] = [:]
    private var generation = UUID()
    private var foreground = true
    private var started = false
    private var retryAttempt = 0
    private var drafts: [String: String] = [:]
    @discardableResult func appendReviewDraft(_ text: String, for sessionId: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 128 * 1024,
              let row = sessions.first(where: { $0.id == sessionId }), !row.isSubagent, !workspaceState.archived.contains(sessionId) else { return false }
        let previous = selected?.id == sessionId ? draft : (drafts[sessionId] ?? "")
        let next = previous + (previous.isEmpty ? "" : "\n\n") + text
        guard next.utf8.count <= 512 * 1024 else { return false }
        drafts[sessionId] = next
        if selected?.id == sessionId { draft = next }
        return true
    }
    private var retries = PromptRetries()
    private var rebaselinePending = false
    private var pendingCreate: (id: String, cwd: String?)?
    var usesFixture: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-native-ui-fixture") || ProcessInfo.processInfo.arguments.contains("-native-onboarding-fixture")
        #else
        return false
        #endif
    }
    /// UI QA: -native-ui-fixture -native-photo-fixture. Each Attach photos tap
    /// imports synthetic JPEGs through the actual store importer: 2 then 1.
    /// Focus nativeComposer to inspect attachment-count/remove-photo-N. No Photos library.
    var usesSyntheticPhotoPicker: Bool {
        #if DEBUG
        return usesFixture && (ProcessInfo.processInfo.arguments.contains("-native-photo-fixture") || ProcessInfo.processInfo.arguments.contains("-native-photo-import-fixture"))
        #else
        return false
        #endif
    }
    init(transport: (any NativeTransport)? = nil, pairingClient: (any NativePairingClient)? = nil,
         credential: String? = nil, restoreCredentials: Bool = true, draftVault: (any NativeDraftPersisting)? = nil) {
        #if DEBUG
        let flags = ProcessInfo.processInfo.arguments
        if transport == nil && flags.contains("-native-ui-fixture") && flags.contains("-native-auto-history-fixture") { gateway = AutoHistoryFixtureTransport() }
        else if transport == nil && flags.contains("-native-ui-fixture") && flags.contains("-native-history-image-fixture") { gateway = ChatMediaFixtureTransport() }
        else if transport == nil && flags.contains("-native-ui-fixture") && flags.contains("-native-question-fixture") { gateway = NativeQuestionFixtureTransport() }
        else { gateway = transport ?? NativeGateway() }
        #else
        gateway = transport ?? NativeGateway()
        #endif
        self.pairingClient = pairingClient ?? BridgeHTTP()
        self.restoreCredentials = restoreCredentials
        var fixtureMode = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        fixtureMode = fixtureMode || flags.contains("-native-ui-fixture") || flags.contains("-native-onboarding-fixture")
        #endif
        let wantsDisk = restoreCredentials && !fixtureMode
        var chosenVault = draftVault
        var vaultInitIssue: String?
        if chosenVault == nil && wantsDisk {
            var limits = NativeDraftVaultLimits()
            limits.maxRecords = 4096; limits.maxTotalBytes = 256 * 1024 * 1024
            limits.maxRecordBytes = 128 * 1024 * 1024; limits.maxImages = 40
            do { chosenVault = try NativeDraftVault.applicationSupport(origin: BridgeHTTP.origin, limits: limits) }
            catch { vaultInitIssue = "Offline draft storage is unavailable. Keep this app open until the issue is resolved." }
        }
        self.draftVault = chosenVault
        requiresDurableDrafts = wantsDisk || chosenVault != nil
        draftsLoaded = chosenVault == nil
        if let vaultInitIssue { draftLoadIssues = [vaultInitIssue] }
        if restoreCredentials, let mode = UserDefaults.standard.string(forKey: "dsh.mobile.followUpMode"), ["steer", "queue"].contains(mode) { followUpMode = mode }
        gateway.onFrame = { [weak self] in self?.receive($0) }
        gateway.onDisconnect = { [weak self] in self?.disconnected() }
        #if DEBUG
        if usesFixture {
            let flags = ProcessInfo.processInfo.arguments
            if flags.contains("-native-ui-fixture") { installFixture() }
            if flags.contains("-native-question-fixture") {
                clientId = "fixture-client"
                if flags.contains("-native-question-draft-fixture") { drafts["fixture-native"] = "Keep my separate draft" }
                if let card = NativeQuestionCard(id: "fixture-question", sessionId: "fixture-native", request: NativeQuestionFixtureTransport.request) { liveQuestions = [card] }
            }
            if flags.contains("-native-offline-draft-fixture") {
                let id = "fixture-offline-draft"
                drafts[id] = "Saved offline draft"; unsentSessions.insert(id)
                let pending = NativePendingDraft(requestID: "fixture-unconfirmed-request", text: "Original unconfirmed message", images: [], mode: "steer", clientTimeZone: "UTC")
                failedPrompts[id] = PendingPrompt(requestID: pending.requestID, text: pending.text, images: pending.images, mode: pending.mode, clientTimeZone: pending.clientTimeZone)
                localDraftRecords[id] = NativeDraftRecord(origin: BridgeHTTP.origin, sessionId: id, workspace: "/synthetic/project", title: "Offline task", unsent: true, text: "Saved offline draft", photos: [], pending: pending, updatedAt: Date())
            }
            if flags.contains("-native-sending-fixture") { sendingRequests["fixture-native"] = "fixture-request" }
            if flags.contains("-native-pair-error-fixture") { pairingError = "This QR expired. Create a fresh invitation on your Mac." }
            return
        }
        #endif
        gateway.credential = credential ?? (restoreCredentials ? DeviceCredential.load() : nil)
        paired = gateway.credential != nil
    }
    func start() async {
        guard !started else { return }
        started = true
        await loadDraftsIfNeeded()
        guard !usesFixture else { return }
        if restoreCredentials, gateway.credential == nil, !UserDefaults.standard.bool(forKey: "nativeCookieMigrationAttempted") {
            UserDefaults.standard.set(true, forKey: "nativeCookieMigrationAttempted")
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            if let cookie = cookies.first(where: { $0.name == BridgeHTTP.cookieName && $0.domain == "dsh.ymehili.com" && $0.isSecure && ($0.expiresDate ?? .distantFuture) > Date() }) {
                do { try DeviceCredential.save(cookie.value); gateway.credential = cookie.value; paired = true }
                catch { pairingError = error.localizedDescription }
            }
        }
        if paired { await connect() }
    }
    @discardableResult func pair(_ link: String) async -> Bool {
        guard !busy else { return false }
        busy = true; pairingError = nil
        defer { busy = false }
        do {
            gateway.credential = try await pairingClient.pair(link)
            imageAuthorizationScope = UUID()
            questionDraftBook.reset(); questionLeaseBook.reset()
            liveQuestions.removeAll(); questionErrors.removeAll(); questionWaitStreams.removeAll(); submittedQuestionKeys.removeAll()
            paired = true
            Task { await connect(force: true) }
            return true
        } catch { pairingError = error.localizedDescription; return false }
    }
    func connect(force: Bool = false) async {
        guard paired, foreground, !usesFixture, force || (!connecting && !connected) else { return }
        followOpeningTask?.cancel(); followOpeningTask = nil
        stopInboxUpdates(); readyTask?.cancel(); followTask?.cancel(); reconnectTask?.cancel(); reconnectTask = nil
        closeAllAuxiliaryStreams("The Mac connection was restarted. Reattach to continue.")
        liveQuestions.removeAll(); questionWaitStreams.removeAll()
        resetHistory()
        generation = UUID(); let current = generation
        gateway.closeStream(); clientId = nil; connected = false; connecting = true
        status = "Connecting…"
        do {
            try await refreshSessions()
            guard current == generation, foreground else { return }
            eventStream = UUID().uuidString; controlStream = UUID().uuidString
            let events = eventStream, control = controlStream
            readyTask = Task { [weak self] in
                do { try await Task.sleep(for: self?.connectionDeadline ?? .seconds(15)) } catch { return }
                guard let self, self.generation == current, !self.connected else { return }
                self.connectionIssue = "Your Mac did not finish connecting. Retrying…"
                self.disconnected()
            }
            gateway.openStream()
            try await open(events, "$events", .obj(["args": .obj([:])]))
            guard current == generation else { return }
            try await open(control, "session/control", .obj(["args": .obj([:])]))
            guard current == generation else { return }
            workspaceStream = UUID().uuidString; workspaceIssue = nil
            try await open(workspaceStream, "workspace/follow", .obj(["args": .obj([:])]))
            guard current == generation else { return }
            if let selected { try await follow(selected.id) }
        } catch {
            guard current == generation else { return }
            connecting = false; connectionIssue = error.localizedDescription
            if (error as? NativeRPCError)?.requiresPairing == true {
                readyTask?.cancel(); status = "Authorization needed — pair again"
            } else { disconnected() }
        }
    }
    func refreshSessions() async throws {
        let result = try await gateway.rpc("session/list", .obj(["args": .obj(["_request": .obj([:])])]))
        sessions = result["items"].array.compactMap(SessionRow.init).sorted { $0.updatedAt > $1.updatedAt }
        var projected = desktopProjections
        for item in result["items"].array {
            if let id = item["sessionId"].string {
                let seq = item["projections"]["asOfSeq"].integer ?? -1
                if seq >= (projectionSequences[id] ?? -1) { projected[id] = item["projections"]["values"]; projectionSequences[id] = seq }
            }
        }
        desktopProjections = projected
        if let id = selected?.id {
            if let row = sessions.first(where: { $0.id == id }) { selected = row }
            else { removeSession(id) }
        }
        // Shelf sync runs independently after the live connection is ready.
    }
    func choose(_ row: SessionRow) async {
        await loadDraftsIfNeeded()
        if selected?.id == row.id && (conversationLoad.isLoaded || (conversationLoad == .loading && !followStream.isEmpty && (connected || connecting))) { return }
        if let old = selected { drafts[old.id] = draft; scheduleDraftSave(old.id) }
        resetHistory()
        draft = drafts[row.id] ?? ""; selected = row
        conversation = Conversation(); conversation.running = row.running
        conversationLoad = .loading
        #if DEBUG
        if usesFixture {
            let flags = ProcessInfo.processInfo.arguments
            if flags.contains("-native-loading-fixture") { return }
            if flags.contains("-native-offline-fixture") { connected = false; conversationLoad = .failed("Your Mac is offline. Reconnect to load this session."); return }
            if gateway is AutoHistoryFixtureTransport {
                followStream = UUID().uuidString
                conversation.accept(AutoHistoryFixtureTransport.snapshot)
            } else if !row.id.hasPrefix("fixture-draft-") { fixtureConversation() }
            conversationLoad = .loaded; return
        }
        #endif
        do { try await follow(row.id) }
        catch { if selected?.id == row.id { conversationLoad = .failed("Couldn’t load this conversation. \(error.localizedDescription)") } }
    }
    func retryConversation() async {
        guard let id = selected?.id else { return }
        if !connected { await connect(force: true); return }
        do { try await follow(id) } catch { conversationLoad = .failed(error.localizedDescription) }
    }
    func openAuxiliaryStream(_ endpoint: String, args: JSONValue, onEvent: @escaping (JSONValue) -> Void, onClose: @escaping (String?) -> Void) async throws -> String {
        guard connected, foreground, !usesFixture else { throw NativeRPCError(message: "Reconnect before opening this tool.") }
        guard ["terminal/attach", "terminal/retain", "workspaceFiles/changes", "job/list", "job/follow", "account/watch", "account/watchExpiry"].contains(endpoint) else { throw NativeRPCError(message: "Unsupported tool stream.") }
        let id = UUID().uuidString, current = generation
        auxiliaryStreams[id] = AuxiliarySubscription(generation: current, endpoint: endpoint, onEvent: onEvent, onClose: onClose)
        let opening = Task { @MainActor [weak self] in
            guard let self, self.generation == current, self.auxiliaryStreams[id] != nil else { throw CancellationError() }
            try await self.open(id, endpoint, .obj(["args": args]))
        }
        auxiliaryStreams[id]?.opening = opening
        do {
            try await opening.value
            guard generation == current, auxiliaryStreams[id] != nil else { throw CancellationError() }
            auxiliaryStreams[id]?.opening = nil
            return id
        } catch {
            if let subscription = auxiliaryStreams.removeValue(forKey: id) { subscription.onClose(error is CancellationError ? nil : error.localizedDescription) }
            throw error
        }
    }
    func sendAuxiliaryInput(_ id: String, value: JSONValue) async throws {
        guard connected, foreground, let subscription = auxiliaryStreams[id], subscription.generation == generation,
              subscription.endpoint == "terminal/attach", ["write", "resize"].contains(value["type"].string ?? ""),
              let sequence = value["sequence"].integer, sequence >= 0 else { throw NativeRPCError(message: "This terminal is no longer writable. Reattach to continue.") }
        try await gateway.sendFrame(.obj(["type": .text("item"), "streamId": .text(id), "value": value]))
    }
    func closeAuxiliaryStream(_ id: String) async {
        guard let subscription = auxiliaryStreams.removeValue(forKey: id) else { return }
        subscription.opening?.cancel()
        if subscription.generation == generation { try? await gateway.sendFrame(.obj(["type": .text("cancel"), "streamId": .text(id)])) }
    }
    private func closeAllAuxiliaryStreams(_ reason: String) {
        let subscriptions = Array(auxiliaryStreams.values); auxiliaryStreams.removeAll()
        for subscription in subscriptions { subscription.opening?.cancel(); subscription.onClose(reason) }
    }
    private func open(_ id: String, _ endpoint: String, _ payload: JSONValue) async throws {
        try Task.checkCancellation()
        try await gateway.sendFrame(.obj(["type": .text("open"), "streamId": .text(id), "endpoint": .text(endpoint), "payload": payload]))
    }
    private func follow(_ id: String) async throws {
        guard selected?.id == id else { return }
        guard connected || connecting else { throw NativeRPCError(message: "Your Mac is offline. Reconnect to load this conversation.") }
        resetHistory()
        followOpeningTask?.cancel(); followTask?.cancel(); conversationLoad = .loading
        let previous = followStream, next = UUID().uuidString, connection = generation
        followStream = next
        followTask = Task { [weak self] in
            do { try await Task.sleep(for: self?.connectionDeadline ?? .seconds(15)) } catch { return }
            guard let self, self.generation == connection, self.followStream == next, self.selected?.id == id, self.conversationLoad == .loading else { return }
            self.conversationLoad = .failed("Loading timed out. Try this conversation again.")
            self.followOpeningTask?.cancel()
        }
        // A split-view transition may cancel SwiftUI's detail .task. The selected
        // session owns this load, not the transient detail view task.
        let opening = Task { @MainActor [weak self] in
            guard let self else { return }
            if !previous.isEmpty { try? await self.gateway.sendFrame(.obj(["type": .text("cancel"), "streamId": .text(previous)])) }
            try Task.checkCancellation()
            guard self.generation == connection, self.followStream == next, self.selected?.id == id else { return }
            try await self.open(next, "session/follow", .obj(["args": .obj(["request": .obj([
                "address": .obj(["kind": .text("session"), "sessionId": .text(id)]), "assistantStream": .bool(true), "maxMessages": .number(60)
            ])])]))
        }
        followOpeningTask = opening
        do {
            try await opening.value
            if generation == connection, followStream == next { followOpeningTask = nil }
        } catch {
            guard generation == connection, followStream == next, selected?.id == id else { return }
            followOpeningTask = nil
            // Do not replace a deliberate cancellation/deadline with Swift error 1.
            if error is CancellationError { return }
            throw error
        }
    }
    @discardableResult func older(retry: Bool = false, willPrepend: (() -> Void)? = nil) async -> HistoryResult {
        guard !historyLoading else { return .busy }
        guard foreground, connected, conversationLoad.isLoaded, let id = selected?.id,
              conversation.hasMore, historyError == nil || retry else { return .unavailable }
        guard let before = conversation.events.keys.min(), before > 0 else {
            conversation.hasMore = false; return .end
        }
        let stream = followStream, connection = generation, context = historyGeneration, request = UUID()
        historyRequest = request; historyError = nil
        // A superseded response must not clear the new selection's loading state.
        defer { if historyRequest == request { historyRequest = nil } }
        func isCurrent() -> Bool {
            foreground && connected && selected?.id == id && followStream == stream
                && generation == connection && historyGeneration == context && historyRequest == request
        }
        do {
            let page = try await gateway.rpc("session/page", .obj(["args": .obj(["request": .obj([
                "address": .obj(["kind": .text("session"), "sessionId": .text(id)]),
                "throughSeq": .number(Double(conversation.cursor)), "beforeSeq": .number(Double(before)), "maxMessages": .number(60)
            ])])]))
            guard isCurrent() else { return .superseded }
            // Only strictly older, valid events can extend this snapshot. Empty,
            // duplicate or invalid non-progress pages terminate paging even if a
            // faulty peer keeps advertising hasMore. Never overwrite live events.
            let rawRecords = page["records"].array
            let records = rawRecords.filter {
                guard case .number(let seq) = $0["event"]["seq"], seq.isFinite,
                      seq >= 0, seq < Double(before), seq.rounded(.towardZero) == seq else { return false }
                return $0["event"]["type"].string?.isEmpty == false
            }
            guard !records.isEmpty else { conversation.hasMore = false; return .end }
            let seqs = records.compactMap { $0["event"]["seq"].integer }
            guard records.count == rawRecords.count, seqs.last == before - 1,
                  zip(seqs, seqs.dropFirst()).allSatisfy({ $0.1 == $0.0 + 1 }) else {
                throw NativeRPCError(message: "Earlier history was not contiguous.")
            }
            willPrepend?()
            conversation.prepend(records)
            conversation.hasMore = page["hasMore"].bool == true && (conversation.events.keys.min() ?? 0) > 0
            return conversation.hasMore ? .loaded : .end
        } catch {
            guard isCurrent() else { return .superseded }
            historyError = "Couldn’t load earlier messages. Try again."
            return .failed
        }
    }
    func send(for id: String, image: Data? = nil) async -> Bool {
        await send(for: id, images: image.map { [$0] } ?? [])
    }
    func send(for id: String, images: [Data], mode: String? = nil) async -> Bool {
        await loadDraftsIfNeeded()
        guard selected?.id == id, canSend, sendingRequests[id] == nil, failedPrompts[id] == nil, !attachments.isLoading(id),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return false }
        do { try photoLimits.validate(images) } catch { self.error = error.localizedDescription; return false }
        guard draft.utf8.count <= 1024 * 1024 else { error = "This message exceeds the offline draft text limit. Shorten it before sending."; return false }
        return await dispatch(text: draft, images: images, mode: mode, to: id, consumesDraft: true)
    }
    /// Sends an immutable, already-confirmed text (an OpenUI card action) through the
    /// same request-ID reservation, durable pending save, delivery and explicit-retry
    /// path as the composer — without reading, clearing or attaching the editable
    /// draft text or its photos. No automatic replay; one unconfirmed message per session.
    func sendStagedText(_ text: String, for id: String, mode: String? = nil) async -> Bool {
        await loadDraftsIfNeeded()
        guard selected?.id == id, canSend, sendingRequests[id] == nil, failedPrompts[id] == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1024 * 1024 else { return false }
        return await dispatch(text: text, images: [], mode: mode, to: id, consumesDraft: false)
    }
    private func dispatch(text: String, images: [Data], mode: String?, to id: String, consumesDraft: Bool) async -> Bool {
        let dispatchMode = mode ?? (conversation.running ? followUpMode : "queue")
        guard ["steer", "queue"].contains(dispatchMode) else { return false }
        let prompt = PendingPrompt(requestID: retries.prepare(session: id, text: text, images: images), text: text, images: images, mode: dispatchMode, clientTimeZone: TimeZone.current.identifier)
        // Reserve the immutable payload and durably save BEFORE any network send.
        sendingRequests[id] = prompt.requestID; failedPrompts[id] = prompt
        if consumesDraft { draft = ""; drafts[id] = ""; attachments.remove(id) }
        guard await persistDraftNow(id) else {
            if sendingRequests[id] == prompt.requestID { sendingRequests[id] = nil }
            deliveryWarnings[id] = "Not sent: the iPhone could not save this message safely. Keep the app open and retry after resolving the draft storage issue. Your next draft is separate."
            return false
        }
        return await deliver(prompt, to: id)
    }
    func retryFailedMessage(_ id: String) async {
        await loadDraftsIfNeeded()
        guard connected, sendingRequests[id] == nil, let prompt = failedPrompts[id] else { return }
        sendingRequests[id] = prompt.requestID
        guard await persistDraftNow(id) else { if sendingRequests[id] == prompt.requestID { sendingRequests[id] = nil }; return }
        _ = await deliver(prompt, to: id)
    }
    func discardFailedMessage(_ id: String) {
        if let prompt = failedPrompts.removeValue(forKey: id) { retries.acknowledged(session: id, id: prompt.requestID) }
        deliveryWarnings.removeValue(forKey: id); scheduleDraftSave(id)
    }
    func failedMessageText(_ id: String) -> String? { failedPrompts[id]?.text }
    private func deliver(_ prompt: PendingPrompt, to id: String) async -> Bool {
        sendingRequests[id] = prompt.requestID
        defer { if sendingRequests[id] == prompt.requestID { sendingRequests.removeValue(forKey: id) } }
        do {
            let content = await Task.detached(priority: .userInitiated) {
                var parts: [JSONValue] = []
                if !prompt.text.isEmpty { parts.append(.obj(["type": .text("text"), "text": .text(prompt.text)])) }
                for (index, image) in prompt.images.enumerated() {
                    parts.append(.obj(["type": .text("image"), "mediaType": .text("image/jpeg"), "data": .text(image.base64EncodedString()), "name": .text("iPhone photo \(index + 1).jpg")]))
                }
                return parts
            }.value
            var request: [String: JSONValue] = ["requestId": .text(prompt.requestID), "sessionId": .text(id), "mode": .text(prompt.mode), "content": .array(content)]
            if let zone = prompt.clientTimeZone { request["clientTimeZone"] = .text(zone) }
            let response = try await gateway.rpc("session/prompt", .obj(["args": .obj(["request": .obj(request)])]))
            guard response["accepted"].bool == true else { throw NativeRPCError(message: "No acknowledgement from DSH.") }
            markDelivered(prompt.requestID, session: id)
            return true
        } catch {
            if receivedRequestIDs.contains(prompt.requestID) { markDelivered(prompt.requestID, session: id); return true }
            failedPrompts[id] = prompt
            deliveryWarnings[id] = "Delivery hasn’t been confirmed. Retry safely with the same request ID, or check the conversation before discarding. Your new draft is separate."
            _ = await persistDraftNow(id)
            return false
        }
    }
    private func markDelivered(_ request: String, session: String) {
        retries.acknowledged(session: session, id: request)
        if failedPrompts[session]?.requestID == request { failedPrompts.removeValue(forKey: session); deliveryWarnings.removeValue(forKey: session) }
        if sendingRequests[session] == request { sendingRequests.removeValue(forKey: session) }
        unsentSessions.remove(session); scheduleDraftSave(session)
    }
    private func noteReceipt(_ event: JSONValue, session: String) {
        guard event["type"].string == "user/message", let request = event["data"]["source"]["rpcId"].string else { return }
        if !receivedRequestIDs.contains(request) { receivedRequestIDs.append(request); if receivedRequestIDs.count > 256 { receivedRequestIDs.removeFirst() } }
        markDelivered(request, session: session)
    }
    func stop() async {
        guard let id = selected?.id, selected?.isSubagent != true, connected else { return }
        do { _ = try await gateway.rpc("session/cancel", .obj(["args": .obj(["request": .obj(["sessionId": .text(id)])])])) }
        catch { self.error = error.localizedDescription }
    }
    func create(workspace: String? = nil, inheritCurrentWorkspace: Bool = true) async -> String? {
        await loadDraftsIfNeeded()
        guard connected, !busy else { if !connected { error = "Reconnect to your Mac before creating a session." }; return nil }
        busy = true; defer { busy = false }
        do {
            let cwd = workspace ?? (inheritCurrentWorkspace && selected?.cwd.isEmpty == false ? selected?.cwd : nil)
            #if DEBUG
            if usesFixture {
                let id = "fixture-draft-\(UUID().uuidString)"
                if let row = SessionRow(.obj(["sessionId": .text(id), "updatedAt": .number(Date().timeIntervalSince1970 * 1000), "running": .bool(false), "blank": .bool(true), "cwd": .text(cwd ?? "/workspace/default-workspace"), "projections": .obj(["values": .obj(["title": .text("New thread")])])])) {
                    sessions.insert(row, at: 0)
                    return id
                }
                return nil
            }
            #endif
            if pendingCreate?.cwd != cwd || pendingCreate == nil { pendingCreate = (UUID().uuidString, cwd) }
            var request: [String: JSONValue] = ["sessionId": .text(pendingCreate!.id)]
            if let cwd { request["cwd"] = .text(cwd) }
            let result = try await gateway.rpc("session/create", .obj(["args": .obj(["request": .obj(request)])]))
            pendingCreate = nil
            try await refreshSessions()
            if let id = result["sessionId"].string, let row = sessions.first(where: { $0.id == id }) { return row.id }
            error = "Session created. Refresh the list to open it."
        } catch { self.error = error.localizedDescription }
        return nil
    }
    @discardableResult func submitAnswers(_ card: NativeQuestionCard, answers: [NativeQuestionAnswer]) async -> Bool {
        guard connected, let clientId, questions.contains(where: { $0 == card }), !questionSubmitting.contains(card.id),
              let ordered = card.validatedAnswers(answers) else { return false }
        questionSubmitting.insert(card.id); questionErrors[card.id] = nil
        defer { questionSubmitting.remove(card.id) }
        let answer = JSONValue.obj(["answers": .array(ordered.map(\.wire))])
        do {
            if card.continued {
                guard let callId = card.callId else { return false }
                let accepted = try await gateway.rpc("userQuestions/answer", .obj(["args": .obj(["agentId": .text(card.sessionId), "callId": .text(callId), "answer": answer])]))
                guard accepted.bool == true else { questionErrors[card.id] = "This question is no longer accepting answers. Refresh the conversation."; return false }
            } else {
                _ = try await gateway.rpc("$events/result", .obj(["args": .obj(["clientId": .text(clientId), "eventId": .text(card.id), "outcome": .obj(["kind": .text("result"), "value": answer])])]))
            }
            submittedQuestionKeys.insert(questionKey(card)); liveQuestions.removeAll { $0.id == card.id }
            await setQuestionVisible(card, visible: false)
            return true
        } catch { questionErrors[card.id] = "Couldn’t send this answer. Reconnect or try again; your choices are retained."; return false }
    }
    func setQuestionVisible(_ card: NativeQuestionCard, visible: Bool) async {
        if !visible {
            if let stream = questionWaitStreams.removeValue(forKey: card.id) { try? await gateway.sendFrame(.obj(["type": .text("cancel"), "streamId": .text(stream)])) }
            return
        }
        guard connected, !card.continued, card.timed, let callId = card.callId,
              questions.contains(where: { $0 == card }), questionWaitStreams[card.id] == nil else { return }
        let stream = UUID().uuidString, connection = generation, scope = imageAuthorizationScope
        questionWaitStreams[card.id] = stream
        do { try await open(stream, "userQuestions/attachWait", .obj(["args": .obj(["agentId": .text(card.sessionId), "callId": .text(callId)])])) }
        catch {
            guard generation == connection, imageAuthorizationScope == scope, questionWaitStreams[card.id] == stream else { return }
            questionWaitStreams[card.id] = nil; questionErrors[card.id] = "Couldn’t keep this question open. Reconnect to refresh its status."
        }
    }
    private func delegateEvent(_ id: String) {
        guard let clientId, connected else { return }
        Task { _ = try? await gateway.rpc("$events/result", .obj(["args": .obj(["clientId": .text(clientId), "eventId": .text(id), "outcome": .obj(["kind": .text("next")])])])) }
    }
    func decide(_ card: ApprovalCard, allow: Bool) async {
        guard let clientId, approvals.contains(where: { $0.id == card.id }), connected, !deciding.contains(card.id) else { return }
        deciding.insert(card.id); defer { deciding.remove(card.id) }
        do {
            _ = try await gateway.rpc("$events/result", .obj(["args": .obj(["clientId": .text(clientId), "eventId": .text(card.id), "outcome": .obj(["kind": .text("result"), "value": .text(allow ? "allowed-once" : "rejected")])])]))
            approvals.removeAll { $0.id == card.id }
        } catch { self.error = error.localizedDescription }
    }
    func setForeground(_ active: Bool) async {
        let wasForeground = foreground; foreground = active
        if active {
            if started, paired, !wasForeground || (!connected && !connecting && reconnectTask == nil) { await connect() }
        } else if wasForeground {
            resetHistory()
            closeAllAuxiliaryStreams("The app left the foreground. Reattach to continue.")
            let closingGeneration = UUID(); generation = closingGeneration
            followOpeningTask?.cancel(); followOpeningTask = nil
            await flushDrafts(allowBackgroundTime: true)
            guard !foreground, generation == closingGeneration else { return }
            if let clientId, connected {
                for card in liveQuestions {
                    _ = try? await gateway.rpc("$events/result", .obj(["args": .obj(["clientId": .text(clientId), "eventId": .text(card.id), "outcome": .obj(["kind": .text("next")])])]))
                }
            }
            guard !foreground, generation == closingGeneration else { return }
            liveQuestions.removeAll(); questionWaitStreams.removeAll()
            generation = UUID(); reconnectTask?.cancel(); reconnectTask = nil; readyTask?.cancel(); followTask?.cancel()
            stopInboxUpdates(); gateway.closeStream(); clientId = nil; connected = false; connecting = false; status = "Paused"
        }
    }
    private func disconnected() {
        resetHistory()
        closeAllAuxiliaryStreams("The Mac disconnected. Reattach to continue.")
        followOpeningTask?.cancel(); followOpeningTask = nil
        liveQuestions.removeAll(); questionWaitStreams.removeAll()
        stopInboxUpdates(); readyTask?.cancel(); followTask?.cancel(); gateway.closeStream()
        eventStream = ""; followStream = ""; controlStream = ""; rebaselinePending = false
        connected = false; connecting = false; clientId = nil
        status = foreground ? "Reconnecting…" : "Paused"
        guard foreground, reconnectTask == nil else { return }
        let delay = min(30, pow(2, Double(retryAttempt + 1))); retryAttempt += 1
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.reconnectTask = nil; await self.connect()
        }
    }
    private func removeSession(_ id: String) {
        let preserve = hasDraftWork(id) || localDraftRecords[id] != nil
        if preserve { scheduleDraftSave(id) }
        cancelPhotoImport(id); photoImportErrors[id] = nil
        if !preserve { attachments.remove(id) }
        sessions.removeAll { $0.id == id }
        if selected?.id == id {
            resetHistory()
            drafts[id] = draft; draft = ""; selected = nil
            followOpeningTask?.cancel(); followOpeningTask = nil
            followTask?.cancel(); followStream = ""; conversation = Conversation(); conversationLoad = .idle
        }
    }
    private func receive(_ frame: JSONValue) {
        guard let stream = frame["streamId"].string else { return }
        if let subscription = auxiliaryStreams[stream] {
            guard subscription.generation == generation else { return }
            switch frame["type"].string {
            case "item": subscription.onEvent(frame["value"])
            case "end", "error":
                auxiliaryStreams[stream] = nil
                subscription.onClose(frame["type"].string == "error" ? (frame["error"]["message"].string ?? "The tool stream failed.") : nil)
            default: break
            }
            return
        }
        if let cardId = questionWaitStreams.first(where: { $0.value == stream })?.key {
            if frame["type"].string == "end" || frame["type"].string == "error" { questionWaitStreams[cardId] = nil }
            return
        }
        guard stream == eventStream || stream == followStream || stream == controlStream || stream == workspaceStream else { return }
        if stream == workspaceStream {
            if frame["type"].string == "item" { workspaceState.accept(frame["value"]); workspaceIssue = nil }
            else { workspaceStream = ""; workspaceIssue = "Couldn’t sync the Mac’s session visibility. Reconnect to retry." }
            return
        }
        if stream == controlStream {
            guard frame["type"].string == "item" else { controlStream = ""; return }
            let value = frame["value"]; var projected = desktopProjections
            if value["type"].string == "baseline" {
                for (id, baseline) in value["value"]["projections"].object ?? [:] {
                    let seq = baseline["asOfSeq"].integer ?? -1
                    if seq >= (projectionSequences[id] ?? -1) { projected[id] = baseline["values"]; projectionSequences[id] = seq }
                }
            } else if value["type"].string == "projection", let id = value["sessionId"].string, let key = value["key"].string, let seq = value["seq"].integer, seq >= (projectionSequences[id] ?? -1) {
                var fields = projected[id]?.object ?? [:]; fields[key] = value["value"]; projected[id] = .obj(fields); projectionSequences[id] = seq
                if key == "title" { let title = value["value"].string ?? "Untitled conversation"; if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].title = title }; if selected?.id == id { selected?.title = title } }
            }
            desktopProjections = projected; return
        }
        if frame["type"].string == "error" || frame["type"].string == "end" {
            if stream == followStream {
                resetHistory()
                followTask?.cancel(); followStream = ""
                // A log stream ending does not stop the Mac's agent. Keep its last
                // status so Stop remains available; api-session/status is authoritative.
                conversationLoad = .failed(frame["error"]["message"].string ?? "This session’s live updates ended. Retry or select another conversation.")
            } else { disconnected() }
            return
        }
        guard frame["type"].string == "item" else { return }
        let value = frame["value"]
        if stream == followStream {
            if value["type"].string == "snapshot" {
                resetHistory()
                followTask?.cancel(); conversationLoad = .loaded; rebaselinePending = false
                if let id = selected?.id {
                    let seq = value["projections"]["asOfSeq"].integer ?? -1
                    if seq >= (projectionSequences[id] ?? -1) { desktopProjections[id] = value["projections"]["values"]; projectionSequences[id] = seq }
                }
            }
            if let id = selected?.id {
                if value["type"].string == "snapshot" { for record in value["records"].array { noteReceipt(record["event"], session: id) } }
                else if value["type"].string == "event" { noteReceipt(value["event"], session: id) }
            }
            conversation.accept(value)
            if conversation.needsBaseline, !rebaselinePending, let id = selected?.id {
                rebaselinePending = true
                Task { do { try await follow(id) } catch { rebaselinePending = false; conversationLoad = .failed(error.localizedDescription) } }
            }
            return
        }
        switch value["type"].string {
        case "ready":
            readyTask?.cancel(); clientId = value["clientId"].string; connected = clientId != nil; connecting = false
            if connected { retryAttempt = 0; connectionIssue = nil; status = "Connected to your Mac"; approvals = []; startInboxUpdates() }
        case "cancel":
            approvals.removeAll { $0.id == value["eventId"].string }
            if let id = value["eventId"].string {
                if let card = liveQuestions.first(where: { $0.id == id }) { Task { await self.setQuestionVisible(card, visible: false) } }
                liveQuestions.removeAll { $0.id == id }; questionErrors[id] = nil
            }
        case "waterfall":
            guard let id = value["eventId"].string else { return }
            if value["event"].string == "approval/request", let session = value["agentId"].string {
                if !approvals.contains(where: { $0.id == id }) {
                    let display = value["request"]["displayReason"], language = Locale.current.language.languageCode?.identifier ?? "en"
                    approvals.append(ApprovalCard(id: id, sessionId: session, tool: value["request"]["toolName"].string ?? "Tool action", reason: display[language].string ?? display["en"].string ?? display.string ?? value["request"]["reason"].string ?? "This action needs permission on your Mac."))
                }
            } else if value["event"].string == "user-questions/request", let session = value["agentId"].string,
                      let card = NativeQuestionCard(id: id, sessionId: session, request: value["request"]) {
                liveQuestions.removeAll { $0.id == id }; liveQuestions.append(card)
            } else {
                // Unsupported waterfalls must delegate rather than silently block
                // the Mac's answer channel forever.
                delegateEvent(id)
            }
        case "emit":
            let args = value["args"].array
            switch value["event"].string {
            case "api-session/status":
                if args.count >= 2, let id = args[0].string { if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].running = args[1].bool ?? false }; if selected?.id == id { conversation.running = args[1].bool ?? false } }
            case "api-session/activity":
                if args.count >= 2, let id = args[0].string, let time = args[1].number, let index = sessions.firstIndex(where: { $0.id == id }) {
                    var row = sessions.remove(at: index)
                    // SessionRow preserves immutable metadata; patch the wire summary below.
                    row = SessionRow(.obj(["sessionId": .text(row.id), "updatedAt": .number(time), "running": .bool(row.running), "cwd": .text(row.cwd), "origin": row.isSubagent ? .text("subagent") : .null, "projections": .obj(["values": .obj(["title": .text(row.title)])])])) ?? row
                    sessions.append(row); sessions.sort { $0.updatedAt > $1.updatedAt }
                }
            case "api-session/added":
                if let value = args.first, let row = SessionRow(value) { sessions.removeAll { $0.id == row.id }; sessions.append(row); sessions.sort { $0.updatedAt > $1.updatedAt }; desktopProjections[row.id] = value["projections"]["values"] }
            case "api-session/removed": if let id = args.first?.string { removeSession(id) }
            case "api-session/error": if args.count >= 2, args[0].string == selected?.id { error = args[1].string ?? "Agent error" }
            default: break
            }
        default: break
        }
    }
}

@MainActor extension NativeStore {
    /// Store-owned restore cannot be cancelled by a transient route task.
    func loadDraftsIfNeeded() async {
        if draftsLoaded { return }
        if let draftLoadTask { await draftLoadTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.draftsLoaded = true; self.draftLoadTask = nil }
            guard let vault = self.draftVault else { return }
            let snapshot = await vault.load()
            self.draftRevisions = snapshot.revisions
            self.draftLoadIssues.append(contentsOf: snapshot.issues)
            for (id, record) in snapshot.records {
                guard id == record.sessionId, record.origin == BridgeHTTP.origin else {
                    self.draftLoadIssues.append("A saved draft does not belong to this Mac connection."); continue
                }
                self.localDraftRecords[id] = record; self.drafts[id] = record.text
                self.attachments.restore(id, photos: record.photos.map { DraftPhoto(id: $0.id, data: $0.data) })
                if record.unsent { self.unsentSessions.insert(id) }
                if let pending = record.pending, ["queue", "steer"].contains(pending.mode) {
                    self.failedPrompts[id] = PendingPrompt(requestID: pending.requestID, text: pending.text, images: pending.images, mode: pending.mode, clientTimeZone: pending.clientTimeZone)
                    self.deliveryWarnings[id] = "Saved message delivery is unconfirmed. Open the conversation to check, or explicitly retry with its original request ID. Nothing is sent automatically."
                }
            }
            if let id = self.selected?.id { self.draft = self.drafts[id] ?? "" }
        }
        draftLoadTask = task; await task.value
    }

    func updateDraftText(_ text: String, for id: String) {
        guard draftsLoaded, !removingLocalDrafts.contains(id) else { return }
        drafts[id] = text
        if selected?.id == id { draft = text }
        scheduleDraftSave(id)
    }
    func savedDraftText(_ id: String) -> String { selected?.id == id ? draft : (drafts[id] ?? localDraftRecords[id]?.text ?? "") }
    var savedUnsentDrafts: [NativeDraftRecord] {
        localDraftRecords.values.filter { record in record.unsent || !sessions.contains(where: { $0.id == record.sessionId }) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    func markUnsentDraft(_ id: String) { unsentSessions.insert(id); scheduleDraftSave(id) }
    func draftSnapshot(_ id: String) -> NativeDraftRecord {
        let row = sessions.first { $0.id == id }, previous = localDraftRecords[id]
        let pending = failedPrompts[id].map { NativePendingDraft(requestID: $0.requestID, text: $0.text, images: $0.images, mode: $0.mode, clientTimeZone: $0.clientTimeZone) }
        return NativeDraftRecord(origin: BridgeHTTP.origin, sessionId: id, workspace: row?.cwd ?? previous?.workspace,
                                 title: row?.title ?? previous?.title, unsent: unsentSessions.contains(id), text: savedDraftText(id),
                                 photos: attachments.photos(in: id).map { NativeDraftPhoto(id: $0.id, data: $0.data) }, pending: pending, updatedAt: Date())
    }
    func hasDraftWork(_ id: String) -> Bool {
        !savedDraftText(id).isEmpty || !attachments.photos(in: id).isEmpty || attachments.isLoading(id) || failedPrompts[id] != nil
            || desktopProjections[id]?["modelSelection"]["next"] != nil && desktopProjections[id]?["modelSelection"]["next"] != .null
    }
    func scheduleDraftSave(_ id: String) {
        guard draftsLoaded, !removingLocalDrafts.contains(id) else { return }
        let record = draftSnapshot(id)
        if record.unsent || !record.text.isEmpty || !record.photos.isEmpty || record.pending != nil { localDraftRecords[id] = record }
        else { localDraftRecords[id] = nil }
        draftDebounceTasks[id]?.cancel()
        draftDebounceTasks[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.draftDebounceTasks[id] = nil
            _ = await self.persistDraftNow(id)
        }
    }
    @discardableResult func persistDraftNow(_ id: String) async -> Bool {
        await loadDraftsIfNeeded()
        draftDebounceTasks.removeValue(forKey: id)?.cancel()
        let record = draftSnapshot(id)
        let empty = !record.unsent && record.text.isEmpty && record.photos.isEmpty && record.pending == nil
        if empty { localDraftRecords[id] = nil } else { localDraftRecords[id] = record }
        guard let vault = draftVault else {
            if requiresDurableDrafts { draftSaveErrors[id] = "Couldn’t save this draft on the iPhone. Keep the app open. The message has not been sent."; return false }
            return true
        }
        if empty && draftRevisions[id] == nil { return true }
        guard !draftRevisionConflicts.contains(id) else { return false }
        guard (draftRevisions[id] ?? 0) < UInt64.max else { draftSaveErrors[id] = "Draft storage revision is exhausted. Keep this draft open; it has not been replaced."; return false }
        let revision = (draftRevisions[id] ?? 0) + 1
        draftRevisions[id] = revision
        let previous = draftWriteTasks[id]
        let task = Task { @MainActor [weak self] () -> Bool in
            if let previous { _ = await previous.value }
            do {
                let saved = try await (empty ? vault.remove(sessionId: id, revision: revision) : vault.save(record: record, revision: revision))
                guard saved else {
                    self?.draftRevisionConflicts.insert(id)
                    if self?.draftRevisions[id] == revision { self?.draftSaveErrors[id] = "Another saved copy is newer. Your edits remain in this app; copy them before reopening it. No message was sent." }
                    return false
                }
                if self?.draftRevisions[id] == revision { self?.draftSaveErrors[id] = nil }
                return true
            } catch {
                if self?.draftRevisions[id] == revision { self?.draftSaveErrors[id] = "Couldn’t save this draft on the iPhone: \(error.localizedDescription). Keep the app open; no data was discarded." }
                return false
            }
        }
        draftWriteTasks[id] = task
        let result = await task.value
        if draftRevisions[id] == revision { draftWriteTasks[id] = nil }
        return result
    }
    func flushDrafts(allowBackgroundTime: Bool = false) async {
        var background = UIBackgroundTaskIdentifier.invalid
        if allowBackgroundTime, restoreCredentials, !usesFixture, draftVault != nil { background = UIApplication.shared.beginBackgroundTask(withName: "Save offline drafts", expirationHandler: nil) }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        await loadDraftsIfNeeded()
        for task in draftDebounceTasks.values { task.cancel() }; draftDebounceTasks.removeAll()
        var ids = Set(localDraftRecords.keys).union(unsentSessions).union(failedPrompts.keys)
        if let id = selected?.id { drafts[id] = draft; ids.insert(id) }
        for id in ids { _ = await persistDraftNow(id) }
    }
    func removeDraftPhoto(_ id: String, photoID: UUID) {
        guard !removingLocalDrafts.contains(id) else { return }
        attachments.remove(id, photoID: photoID); scheduleDraftSave(id)
    }
    @discardableResult func removeLocalDraft(_ id: String) async -> Bool {
        await loadDraftsIfNeeded()
        guard sendingRequests[id] == nil, !attachments.isLoading(id), !removingLocalDrafts.contains(id) else {
            draftSaveErrors[id] = "Wait for the current send or photo import before discarding this local draft."; return false
        }
        removingLocalDrafts.insert(id); defer { removingLocalDrafts.remove(id) }
        draftDebounceTasks.removeValue(forKey: id)?.cancel()
        if let previous = draftWriteTasks[id] { _ = await previous.value }
        guard (draftRevisions[id] ?? 0) < UInt64.max else { draftSaveErrors[id] = "Draft revision exhausted; the saved copy was kept."; return false }
        let revision = (draftRevisions[id] ?? 0) + 1
        if let vault = draftVault {
            do {
                guard try await vault.remove(sessionId: id, revision: revision) else { draftSaveErrors[id] = "A newer local draft exists; it was not discarded."; return false }
            } catch { draftSaveErrors[id] = "Couldn’t discard the saved copy: \(error.localizedDescription)"; return false }
        } else if requiresDurableDrafts { draftSaveErrors[id] = "Draft storage is unavailable; the local copy was kept."; return false }
        draftRevisions[id] = revision
        localDraftRecords[id] = nil; drafts[id] = nil; attachments.remove(id); unsentSessions.remove(id)
        if let pending = failedPrompts.removeValue(forKey: id) { retries.acknowledged(session: id, id: pending.requestID) }
        deliveryWarnings[id] = nil; draftSaveErrors[id] = nil
        if selected?.id == id { draft = "" }
        return true
    }
    func leaveNewDraft(_ id: String) async {
        if !hasDraftWork(id) { unsentSessions.remove(id) }
        _ = await persistDraftNow(id)
    }
    func clearSelectionForSidebar() {
        resetHistory()
        if let id = selected?.id { drafts[id] = draft; scheduleDraftSave(id) }
        followOpeningTask?.cancel(); followOpeningTask = nil; followTask?.cancel()
        if !followStream.isEmpty { let old = followStream; Task { try? await gateway.sendFrame(.obj(["type": .text("cancel"), "streamId": .text(old)])) } }
        followStream = ""; selected = nil; draft = ""; conversation = Conversation(); conversationLoad = .idle
    }
}

#if DEBUG
/// Explicit in-process UI fixture; it cannot reach any host, credentials, models,
/// provider, disk vault or Photos library. Only session/page is implemented.
@MainActor private final class AutoHistoryFixtureTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    private var requests = 0
    func openStream() {}
    func closeStream() {}
    func sendFrame(_ value: JSONValue) async throws {}
    static func records(_ range: Range<Int>) -> [JSONValue] {
        range.map { seq in
            let event: JSONValue
            if (22...25).contains(seq) {
                event = .obj(["seq": .number(Double(seq)), "type": .text("tool/call"), "data": .obj(["name": .text("Synthetic work \(seq)"), "arguments": .text("{}")])])
            } else {
                event = .obj(["seq": .number(Double(seq)), "type": .text("assistant/message"), "surfaceOp": .text("append"), "data": .obj(["message": .obj(["content": .array([.obj(["type": .text("text"), "text": .text("History message \(seq)\n\n" + String(repeating: "Controlled paging keeps the current reading position. ", count: 3))])])])])])
            }
            return .obj(["type": .text("event"), "event": event])
        }
    }
    static var snapshot: JSONValue {
        .obj(["type": .text("snapshot"), "cursor": .number(35), "hasMore": .bool(true), "records": .array(records(24..<36)), "assistantStream": .obj(["revision": .number(0)])])
    }
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        guard endpoint == "session/page", let before = payload["args"]["request"]["beforeSeq"].integer else {
            throw NativeRPCError(message: "Unsupported synthetic history operation")
        }
        requests += 1
        try await Task.sleep(for: .seconds(2))
        if requests == 1 && ProcessInfo.processInfo.arguments.contains("-native-auto-history-error-fixture") {
            throw NativeRPCError(message: "Controlled page failure")
        }
        let lower = max(0, before - 12)
        return .obj(["records": .array(Self.records(lower..<before)), "hasMore": .bool(lower > 0)])
    }
}
#endif
