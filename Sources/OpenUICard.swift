import SwiftUI
import UIKit
import WebKit

/// Assistant answer renderer. Identical to `NativeMarkdown` unless the answer has a
/// top-level ```openui fence; only those fences become sandboxed OpenUI cards and the
/// surrounding Markdown keeps the native renderer. The full app UI stays native.
struct NativeAssistantMarkdown: View, Equatable {
    let text: String
    var streaming = false
    /// Committed answers of a session may stage confirmed actions; live text never can.
    var sessionId: String? = nil

    var body: some View {
        if let segments = OpenUIContent.segments(for: text, cache: !streaming) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let blocks):
                        NativeMarkdownBlocks(blocks: blocks, cacheable: !streaming, listDepth: 0, spacing: 12)
                    case .card(let source, let closed):
                        // An unterminated fence is incomplete even after commit: render it as streaming, never actionable.
                        let incomplete = OpenUIContent.isIncomplete(streaming: streaming, closed: closed)
                        OpenUICard(source: source, streaming: incomplete, sessionId: incomplete ? nil : sessionId)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(DSHTheme.accent)
            .environment(\.openURL, OpenURLAction { url in MarkdownInline.safeLink(url) == nil ? .discarded : .systemAction })
        } else {
            NativeMarkdown(text: text, streaming: streaming)
        }
    }
}

enum OpenUICardFailure: Equatable {
    case unavailable, timeout, load, terminated, render
    /// The bundled frame speaks a different bridge protocol than this build.
    case incompatible
    /// `window.dshOpenUIUpdate` was missing or threw while delivering the card.
    case update

    var message: String {
        switch self {
        case .unavailable: return "Interactive cards aren’t available in this build. Showing the card source."
        case .timeout: return "The card took too long to load. Showing its source."
        case .load: return "The card couldn’t load. Showing its source."
        case .terminated: return "The card stopped unexpectedly. Showing its source."
        case .render: return "This card couldn’t be displayed. Showing its source."
        case .incompatible: return "This build’s card renderer is incompatible. Showing the card source."
        case .update: return "The card couldn’t be updated. Showing its source."
        }
    }

    /// Reloading the same bundled assets can't fix a missing or mismatched renderer.
    var retryable: Bool { self != .unavailable && self != .incompatible }
}

/// One sandboxed OpenUI card. Loading, timeout and every failure fall back to the
/// native source view; actions are only forwarded for committed, non-streaming text.
struct OpenUICard: View {
    static let loadTimeout: Duration = .seconds(10)
    let source: String
    let streaming: Bool
    var sessionId: String?
    var cardId: String?
    var catalog: String
    @State private var initialUIState: OpenUIJSONState
    @Environment(OpenUIActionInbox.self) private var inbox: OpenUIActionInbox?
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = 17
    @State private var ready = false
    @State private var failure: OpenUICardFailure?
    @State private var height: CGFloat
    @State private var scrolls = false
    @State private var attempt = 0
    @State private var copiedNotice: UUID?

    init(source: String, streaming: Bool, sessionId: String? = nil, cardId: String? = nil, catalog: String = "chat-v1") {
        self.source = source
        self.streaming = streaming
        self.sessionId = sessionId
        self.cardId = cardId
        self.catalog = catalog
        let restored = !streaming ? sessionId.flatMap { session in cardId.flatMap {
            OpenUIStateStore.shared.restore(sessionId: session, cardId: $0, source: source, catalog: catalog)
        } } : nil
        _initialUIState = State(initialValue: restored ?? .empty)
        _height = State(initialValue: OpenUIHeightCache.height(for: source) ?? OpenUICardLayout.placeholderHeight)
        _failure = State(initialValue: OpenUIResources.document == nil ? .unavailable : nil)
    }

    private var state: OpenUICardState {
        OpenUICardState(response: source, isStreaming: streaming, dark: colorScheme == .dark, catalog: catalog,
                        initialState: initialUIState, theme: OpenUITheme(fontSize: Double(bodyFontSize)))
    }
    private var actionable: Bool { sessionId != nil && !streaming }

    var body: some View {
        Group {
            if let failure {
                fallback(failure)
            } else {
                OpenUIWebView(state: state, actionable: actionable, scrolls: scrolls) { handle($0) }
                    .id(attempt)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if !ready {
                            HStack(spacing: T3Metric.steps(2)) {
                                ProgressView()
                                Text("Loading card…").font(.footnote).foregroundStyle(DSHTheme.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(ChatAppearance.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("openui-card-loading")
                        }
                    }
                    .task(id: attempt) {
                        do { try await Task.sleep(for: Self.loadTimeout) } catch { return }
                        if !ready && failure == nil { failure = .timeout }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openui-card")
        .overlay(alignment: .topTrailing) {
            if copiedNotice != nil {
                Label("Copied", systemImage: "checkmark")
                    .font(.caption.weight(.medium)).padding(8)
                    .background(.regularMaterial, in: Capsule()).padding(8)
                    .accessibilityIdentifier("openui-copy-status")
            }
        }
        .task(id: copiedNotice) {
            guard copiedNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedNotice = nil
        }
    }

    private func handle(_ event: OpenUIWebEvent) {
        switch event {
        case .ready: ready = true
        case .height(let reported):
            let frame = OpenUICardLayout.frame(for: reported)
            if abs(frame.height - height) > 0.5 { height = frame.height }
            if scrolls != frame.scrolls { scrolls = frame.scrolls }
            if !streaming { OpenUIHeightCache.store(frame.height, for: source) }
        case .action(let action):
            guard actionable, let sessionId else { return }
            inbox?.stage(action, sessionId: sessionId)
        case .copy(let text):
            guard failure == nil, actionable else { return }
            UIPasteboard.general.string = text
            copiedNotice = UUID()
        case .state(let state):
            guard failure == nil, actionable, let sessionId, let cardId else { return }
            OpenUIStateStore.shared.store(state, sessionId: sessionId, cardId: cardId, source: source, catalog: catalog)
        case .failed(let reason):
            failure = reason
        }
    }

    private func fallback(_ reason: OpenUICardFailure) -> some View {
        VStack(alignment: .leading, spacing: T3Metric.steps(2)) {
            HStack(alignment: .firstTextBaseline, spacing: T3Metric.steps(2)) {
                Label(reason.message, systemImage: "rectangle.dashed")
                    .font(.footnote).foregroundStyle(DSHTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if reason.retryable {
                    Button("Retry") {
                        if let sessionId, let cardId {
                            initialUIState = OpenUIStateStore.shared.restore(sessionId: sessionId, cardId: cardId, source: source, catalog: catalog) ?? .empty
                        }
                        ready = false; failure = nil; attempt += 1
                    }
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: T3Metric.actionTarget, minHeight: T3Metric.actionTarget)
                        .accessibilityIdentifier("openui-card-retry")
                }
            }
            NativeCodeBlock(language: OpenUIContent.language, code: source)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openui-card-fallback")
    }
}

/// Bounded height memory so a re-created card (scrolling, commit after streaming)
/// starts at its last laid-out size instead of jumping from a placeholder.
enum OpenUIHeightCache {
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 200
        return cache
    }()
    static func height(for source: String) -> CGFloat? { cache.object(forKey: source as NSString).map { CGFloat($0.doubleValue) } }
    static func store(_ height: CGFloat, for source: String) { cache.setObject(NSNumber(value: Double(height)), forKey: source as NSString) }
}

/// Logical WebKit CSS pixels follow the native preferred body size, including Dynamic Type.
struct OpenUITheme: Equatable {
    var fontSize: Double
    var fontFamily = "system-ui"
    var payload: [String: Any] { ["fontSize": "\(fontSize)px", "fontFamily": fontFamily] }
}

/// The exact `window.dshOpenUIUpdate` payload.
struct OpenUICardState: Equatable {
    var response: String
    var isStreaming: Bool
    var dark: Bool
    var catalog = "chat-v1"
    var initialState: OpenUIJSONState = .empty
    var theme: OpenUITheme? = nil
    var loadingLabel = "Generating card…"
    var errorLabel = "This card couldn’t be displayed."
    var sourceLabel = "Card source"

    var payload: [String: Any] {
        var value: [String: Any] = ["response": response, "isStreaming": isStreaming, "dark": dark,
                                  "catalog": catalog, "initialState": initialState.object,
                                  "labels": ["loading": loadingLabel, "error": errorLabel, "source": sourceLabel]]
        if let theme { value["theme"] = theme.payload }
        return value
    }
}

enum OpenUIWebEvent: Equatable {
    case ready
    case height(Double)
    case action(OpenUIActionEvent)
    case state(OpenUIJSONState)
    case copy(String)
    case failed(OpenUICardFailure)
}

/// Native bridge protocol 2: every lifecycle, height, action, copy and state
/// message carries `protocol: 2`. The update function keeps its existing name.
enum OpenUIBridgeProtocol {
    static let version = 2

    enum Envelope: Equatable {
        /// A current-protocol message, parsed by `OpenUIBridgeMessage`.
        case message(OpenUIBridgeMessage)
        /// A `ready`/`error` lifecycle message without `protocol: 2`: fail now instead of waiting for the load timeout.
        case incompatible
        /// Malformed, unknown, or mismatched non-lifecycle messages: never acted on.
        case ignored
    }

    static func classify(_ body: Any) -> Envelope {
        guard let object = body as? [String: Any], let type = object["type"] as? String else { return .ignored }
        guard isCurrent(object["protocol"]) else { return type == "ready" || type == "error" ? .incompatible : .ignored }
        return OpenUIBridgeMessage.parse(object).map(Envelope.message) ?? .ignored
    }

    /// Exactly the number 2: not a string, boolean or other version.
    static func isCurrent(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == Double(version)
    }
}

/// Evaluates a script in the card page; the result decides whether the update was delivered.
typealias OpenUIScriptCompletion = @MainActor @Sendable (Result<Any, Error>) -> Void
typealias OpenUIScriptEvaluator = (_ script: String, _ completion: @escaping OpenUIScriptCompletion) -> Void

struct OpenUIWebView: UIViewRepresentable {
    let state: OpenUICardState
    let actionable: Bool
    let scrolls: Bool
    let onEvent: @MainActor (OpenUIWebEvent) -> Void

    func makeCoordinator() -> OpenUIWebController { OpenUIWebController() }
    func makeUIView(context: Context) -> WKWebView {
        let controller = context.coordinator
        apply(to: controller)
        controller.start()
        return controller.webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) { apply(to: context.coordinator) }
    static func dismantleUIView(_ webView: WKWebView, coordinator: OpenUIWebController) { coordinator.tearDown() }

    private func apply(to controller: OpenUIWebController) {
        controller.onEvent = onEvent
        controller.actionable = actionable
        if controller.webView.scrollView.isScrollEnabled != scrolls { controller.webView.scrollView.isScrollEnabled = scrolls }
        controller.update(state)
    }
}

/// Shared WebKit policy: one memory-only website data store, a compiled content
/// rule list that blocks every non-local load, and no popups/media/data detectors.
@MainActor enum OpenUIWebEnvironment {
    static let ruleListIdentifier = "dsh.openui.local-only.v1"
    /// Everything is blocked except the bundled file document/resources and inline data/blob URLs.
    static let encodedRules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
    """
    static let dataStore = WKWebsiteDataStore.nonPersistent()
    private static var compiled: WKContentRuleList?
    private static var compiling: [CheckedContinuation<WKContentRuleList, Error>]?

    static func ruleList() async throws -> WKContentRuleList {
        if let compiled { return compiled }
        return try await withCheckedThrowingContinuation { continuation in
            if compiling != nil { compiling?.append(continuation); return }
            compiling = [continuation]
            guard let store = WKContentRuleListStore.default() else {
                finish(.failure(NativeRPCError(message: "Content rule store unavailable"))); return
            }
            store.compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: encodedRules) { list, error in
                // The completion queue is not annotated; hop explicitly instead of assuming main.
                Task { @MainActor in
                    if let list { compiled = list; finish(.success(list)) }
                    else { finish(.failure(error ?? NativeRPCError(message: "Content rules failed to compile"))) }
                }
            }
        }
    }
    private static func finish(_ result: Result<WKContentRuleList, Error>) {
        let waiting = compiling ?? []; compiling = nil
        for continuation in waiting { continuation.resume(with: result) }
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = false
        return configuration
    }
}

@MainActor private final class OpenUIScriptProxy: NSObject, WKScriptMessageHandler {
    weak var controller: OpenUIWebController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        controller?.receive(message)
    }
}

/// Owns one card's WKWebView and enforces the bridge contract natively:
/// bundled document only, main-frame protocol-2 messages only, ready-gated
/// updates that must evaluate successfully, throttled streaming updates and
/// non-streaming, rate-limited actions.
@MainActor final class OpenUIWebController: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let handlerName = "openui"
    static let streamingUpdateInterval: Duration = .milliseconds(80)
    static let actionInterval: Duration = .seconds(1)
    static let stateInterval: Duration = .milliseconds(200)
    let webView: WKWebView
    let document: URL?
    var onEvent: ((OpenUIWebEvent) -> Void)?
    var actionable = false
    /// Test seam; `nil` evaluates in the card page's world.
    var evaluateScript: OpenUIScriptEvaluator?
    private(set) var isReady = false
    private(set) var isFailed = false
    private(set) var deliveredState: OpenUICardState?
    private var desiredState: OpenUICardState?
    private var initialLoadPending = true
    private var started = false
    private var pushing = false
    private var lastAction: ContinuousClock.Instant?
    private var pushTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var pendingUIState: OpenUIJSONState?
    private var lastUIState: OpenUIJSONState?
    private var tornDown = false
    private let proxy = OpenUIScriptProxy()

    init(document: URL? = OpenUIResources.document) {
        self.document = document
        let configuration = OpenUIWebEnvironment.configuration()
        configuration.userContentController.add(proxy, contentWorld: .page, name: Self.handlerName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        proxy.controller = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.scrollsToTop = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.accessibilityIdentifier = "openui-card-web"
    }

    func start() {
        guard !started else { return }
        started = true
        guard let document else { fail(.unavailable); return }
        Task { @MainActor [weak self] in
            do {
                let rules = try await OpenUIWebEnvironment.ruleList()
                guard let self, !self.isFailed, !self.tornDown, self.initialLoadPending else { return }
                self.webView.configuration.userContentController.add(rules)
                self.webView.loadFileURL(document, allowingReadAccessTo: document.deletingLastPathComponent())
            } catch {
                // Fail closed: never load the card without its network block list.
                self?.fail(.unavailable)
            }
        }
    }

    func update(_ state: OpenUICardState) {
        guard !tornDown, desiredState != state else { return }
        if desiredState?.response != state.response || desiredState?.catalog != state.catalog {
            stateTask?.cancel(); stateTask = nil; pendingUIState = nil; lastUIState = nil
        }
        desiredState = state
        pushIfNeeded()
    }

    func tearDown() {
        guard !tornDown else { return }
        // Commit a final coalesced value when a lazy transcript row unmounts.
        flushUIState()
        tornDown = true
        stateTask?.cancel(); stateTask = nil
        pushTask?.cancel(); pushTask = nil
        onEvent = nil
        proxy.controller = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    /// Calls `window.dshOpenUIUpdate(payload)`; evaluates to `true` only when the frame's
    /// function exists and returned without throwing.
    static func updateScript(for state: OpenUICardState) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: state.payload, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "typeof window.dshOpenUIUpdate === 'function' ? (window.dshOpenUIUpdate(\(json)), true) : false"
    }

    private func pushIfNeeded() {
        guard isReady, !isFailed, !tornDown, !pushing, let state = desiredState, state != deliveredState else { return }
        guard let script = Self.updateScript(for: state) else { fail(.update); return }
        pushing = true
        let completion: OpenUIScriptCompletion = { [weak self] result in
            guard let self, !self.isFailed, !self.tornDown else { return }
            guard case .success(let value) = result, (value as? Bool) == true else {
                // A missing or throwing update would leave a blank or stale card: show the native source instead.
                self.pushing = false
                self.fail(.update)
                return
            }
            self.deliveredState = state
            guard state.isStreaming, self.desiredState != state else { self.pushing = false; self.pushIfNeeded(); return }
            // Coalesce token-rate streaming updates; the latest full text always wins.
            self.pushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.streamingUpdateInterval)
                guard let self, !Task.isCancelled else { return }
                self.pushing = false; self.pushIfNeeded()
            }
        }
        if let evaluateScript { evaluateScript(script, completion) }
        else { webView.evaluateJavaScript(script, in: nil, in: .page, completionHandler: completion) }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, let document else { return }
        let frame = message.frameInfo
        guard OpenUINavigationPolicy.acceptsMessage(mainFrame: frame.isMainFrame, originProtocol: frame.securityOrigin.protocol,
                                                    documentURL: frame.request.url ?? webView.url, document: document) else { return }
        handle(message.body)
    }

    /// Validated bridge input (already main-frame/document checked). Only
    /// protocol-2 messages are acted on; a mismatched ready/error fails visibly.
    func handle(_ body: Any) {
        guard !isFailed, !tornDown else { return }
        let message: OpenUIBridgeMessage
        switch OpenUIBridgeProtocol.classify(body) {
        case .message(let parsed): message = parsed
        case .incompatible: fail(.incompatible); return
        case .ignored: return
        }
        switch message {
        case .ready:
            guard !isReady else { return }
            isReady = true
            onEvent?(.ready)
            pushIfNeeded()
        case .height(let value):
            onEvent?(.height(value))
        case .action(let event):
            guard isReady, actionable, let delivered = deliveredState, !delivered.isStreaming, desiredState?.isStreaming == false else { return }
            let now = ContinuousClock.now
            if let lastAction, now - lastAction < Self.actionInterval { return }
            lastAction = now
            onEvent?(.action(event))
        case .copy(let text):
            guard acceptsUIState else { return }
            let now = ContinuousClock.now
            if let lastAction, now - lastAction < Self.actionInterval { return }
            lastAction = now
            onEvent?(.copy(text))
        case .state(let state):
            guard acceptsUIState else { return }
            pendingUIState = state == lastUIState ? nil : state
            guard pendingUIState != nil else { return }
            guard stateTask == nil else { return }
            // One bounded timer, not polling: newest full object wins during rapid edits.
            stateTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: Self.stateInterval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.stateTask = nil
                self.flushUIState()
            }
        case .error:
            fail(.render)
        }
    }

    private var acceptsUIState: Bool {
        isReady && !isFailed && !tornDown && actionable && deliveredState?.isStreaming == false && desiredState?.isStreaming == false
            && deliveredState?.response == desiredState?.response && deliveredState?.catalog == desiredState?.catalog
    }

    private func flushUIState() {
        defer { pendingUIState = nil }
        guard acceptsUIState, let state = pendingUIState, state != lastUIState else { return }
        lastUIState = state
        onEvent?(.state(state))
    }

    private func fail(_ reason: OpenUICardFailure) {
        guard !isFailed else { return }
        isFailed = true
        pushTask?.cancel()
        stateTask?.cancel(); stateTask = nil; pendingUIState = nil
        webView.stopLoading()
        onEvent?(.failed(reason))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let document, !isFailed,
              OpenUINavigationPolicy.allows(navigationAction.request.url, mainFrame: navigationAction.targetFrame?.isMainFrame == true,
                                            document: document, initialLoadPending: initialLoadPending) else {
            decisionHandler(.cancel); return
        }
        initialLoadPending = false
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard let document, !isFailed,
              OpenUINavigationPolicy.acceptsMessage(mainFrame: navigationResponse.isForMainFrame, originProtocol: "file",
                                                    documentURL: navigationResponse.response.url, document: document) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !isReady { fail(.load) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !isReady { fail(.load) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(.terminated) }

    // MARK: WKUIDelegate — no windows, dialogs, menus, pickers or capture.

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) { completionHandler() }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) { completionHandler(nil) }

    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) { completionHandler(nil) }
}

/// Holds at most one staged card action awaiting the user's explicit confirmation.
@MainActor @Observable final class OpenUIActionInbox {
    var staged: OpenUIStagedAction?
    func stage(_ event: OpenUIActionEvent, sessionId: String) {
        guard staged == nil else { return }
        staged = OpenUIStagedAction(sessionId: sessionId, event: event)
    }
}

struct OpenUIStagedAction: Identifiable, Equatable {
    let id = UUID()
    let sessionId: String
    let event: OpenUIActionEvent
}
