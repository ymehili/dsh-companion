import Foundation
import CoreFoundation
import CryptoKit

/// Assistant-only OpenUI cards. Only a top-level fenced block whose first info
/// token is exactly lower-case `openui` becomes a card; every other block, and
/// any `openui` fence nested in a list or quote, stays native Markdown. Reasoning,
/// context and user text never go through this path (see `NativeAssistantMarkdown`).
/// Mirrors dsh-openui/src/core.js `splitOpenUI` limits (8 cards, 256 KiB source).
enum OpenUISegment: Equatable {
    case markdown([MarkdownBlock])
    /// Raw OpenUI Lang source exactly as fenced; `closed` is false while the fence is unterminated.
    case card(source: String, closed: Bool)
}

enum OpenUIContent {
    static let language = "openui"
    static let maxCardBytes = 262_144
    static let maxCardsPerMessage = 8

    /// Cheap precheck so ordinary answers keep the unchanged NativeMarkdown path.
    /// Live text or an unterminated fence is incomplete: no actions (desktop parity).
    static func isIncomplete(streaming: Bool, closed: Bool) -> Bool { streaming || !closed }

    static func mayContainCard(_ text: String) -> Bool { text.contains(language) }

    static func segments(_ blocks: [MarkdownBlock]) -> [OpenUISegment] {
        var result: [OpenUISegment] = []
        var pending: [MarkdownBlock] = []
        var cards = 0
        for block in blocks {
            if case .code(let language, let code, let closed) = block, language == Self.language,
               code.utf8.count <= maxCardBytes, cards < maxCardsPerMessage {
                if !pending.isEmpty { result.append(.markdown(pending)); pending = [] }
                result.append(.card(source: code, closed: closed))
                cards += 1
            } else {
                pending.append(block)
            }
        }
        if !pending.isEmpty { result.append(.markdown(pending)) }
        return result
    }

    static func segments(for text: String, cache: Bool) -> [OpenUISegment]? {
        guard mayContainCard(text) else { return nil }
        let segments = segments(NativeMarkdownCache.blocks(for: text, cache: cache))
        return segments.contains(where: { if case .card = $0 { return true } else { return false } }) ? segments : nil
    }
}

/// A validated `continue_conversation` card action. The exact text sent is
/// `OpenUI card action:\n` + the compact JSON of the full raw event, so every
/// form value or hidden context is visible in the confirmation sheet.
struct OpenUIActionEvent: Equatable, Sendable {
    static let maxBytes = 16_384
    static let allowedType = "continue_conversation"
    static let prefix = "OpenUI card action:\n"

    /// Canonical compact JSON (sorted keys) of the raw event.
    let json: String
    /// Same content, pretty-printed for the confirmation sheet only.
    let displayJSON: String
    let humanFriendlyMessage: String?
    /// Readable values are a convenience, never a replacement for the exact event in Details.
    let valuesSummary: String

    var messageText: String { Self.prefix + json }
    var displayText: String { Self.prefix + displayJSON }

    init?(raw: Any) {
        guard let event = raw as? [String: Any], (event["type"] as? String) == Self.allowedType,
              JSONSerialization.isValidJSONObject(event),
              let compact = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes]),
              compact.count <= Self.maxBytes, let json = String(data: compact, encoding: .utf8) else { return nil }
        let pretty = (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? json
        self.json = json
        self.displayJSON = pretty
        let message = (event["humanFriendlyMessage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        humanFriendlyMessage = message?.isEmpty == false ? message : nil
        let values = event.filter { $0.key != "type" && $0.key != "humanFriendlyMessage" }
        valuesSummary = Self.describe(values)
    }

    private static func describe(_ value: Any, depth: Int = 0) -> String {
        if value is NSNull { return "Not set" }
        if let string = value as? String { return string.isEmpty ? "(empty)" : string }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "Yes" : "No") : number.stringValue
        }
        guard depth < 8 else { return "More values in Details" }
        if let object = value as? [String: Any] {
            return object.keys.sorted().map { key in
                let label: String
                switch key {
                case "formState": label = "Form values"
                case "formName": label = "Form"
                case "params": label = "Context"
                default: label = key
                }
                let rendered = describe(object[key]!, depth: depth + 1)
                return "\(label): \(rendered.isEmpty ? "(none)" : rendered)"
            }.joined(separator: "\n")
        }
        if let array = value as? [Any] { return array.map { describe($0, depth: depth + 1) }.joined(separator: ", ") }
        return "See Details"
    }
}

/// Bounded, canonical JSON object emitted by local controls. No executable/native values.
struct OpenUIJSONState: Equatable, Sendable {
    static let maxBytes = 16_384
    static let empty = OpenUIJSONState(raw: [String: Any]())!
    let json: String
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:] }

    init?(raw: Any) {
        guard let object = raw as? [String: Any] else { return nil }
        var nodes = 0, bytes = 0
        func bounded(_ value: Any, depth: Int) -> Bool {
            nodes += 1
            guard depth <= 32, nodes <= 8192 else { return false }
            if let text = value as? String { bytes += text.utf8.count; return bytes <= Self.maxBytes }
            if let number = value as? NSNumber { return number.doubleValue.isFinite }
            if value is NSNull { return true }
            if let object = value as? [String: Any] {
                return object.allSatisfy { bounded($0.key, depth: depth + 1) && bounded($0.value, depth: depth + 1) }
            }
            if let array = value as? [Any] { return array.allSatisfy { bounded($0, depth: depth + 1) } }
            return false
        }
        guard bounded(object, depth: 0), JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= Self.maxBytes, let json = String(data: data, encoding: .utf8) else { return nil }
        self.json = json
    }
}

/// Device-local preferences, not a credential store or a cross-device conversation event.
/// Bounded on disk and keyed by the exact session/call pair, with source/catalog invalidation.
@MainActor final class OpenUIStateStore {
    static let shared = OpenUIStateStore()
    static let maxRecords = 64
    static let maxStoredBytes = 1_048_576
    static let storageKey = "dsh.openui.local-state.v1"
    private struct Record: Codable { let fingerprint: String; let json: String; let updated: Double }
    private let defaults: UserDefaults
    private var records: [String: Record] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), data.count <= Self.maxStoredBytes,
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data), decoded.count <= Self.maxRecords {
            records = decoded.filter { key, record in
                key.count == 64 && record.fingerprint.count == 64 && record.updated.isFinite && Self.state(record.json) != nil
            }
        }
    }

    func restore(sessionId: String, cardId: String, source: String, catalog: String) -> OpenUIJSONState? {
        guard let record = records[Self.hash([sessionId, cardId])], record.fingerprint == Self.hash([catalog, source]) else { return nil }
        return Self.state(record.json)
    }

    func store(_ state: OpenUIJSONState, sessionId: String, cardId: String, source: String, catalog: String) {
        let key = Self.hash([sessionId, cardId]), fingerprint = Self.hash([catalog, source])
        if records[key]?.json == state.json && records[key]?.fingerprint == fingerprint { return }
        records[key] = Record(fingerprint: fingerprint, json: state.json, updated: Date().timeIntervalSince1970)
        while records.count > Self.maxRecords { evictOldest() }
        while let data = try? JSONEncoder().encode(records) {
            if data.count <= Self.maxStoredBytes { defaults.set(data, forKey: Self.storageKey); return }
            guard !records.isEmpty else { return }
            evictOldest()
        }
    }

    private func evictOldest() { if let key = records.min(by: { $0.value.updated < $1.value.updated })?.key { records.removeValue(forKey: key) } }
    private static func state(_ json: String) -> OpenUIJSONState? {
        guard json.utf8.count <= OpenUIJSONState.maxBytes, let raw = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }
        return OpenUIJSONState(raw: raw)
    }
    private static func hash(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Messages from frame.js via `window.webkit.messageHandlers.openui`.
enum OpenUIBridgeMessage: Equatable {
    case ready
    case height(Double)
    case action(OpenUIActionEvent)
    case state(OpenUIJSONState)
    case copy(String)
    case error(String)

    static func parse(_ body: Any) -> OpenUIBridgeMessage? {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return nil }
        switch type {
        case "ready": return .ready
        case "height":
            guard let value = (message["height"] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return .height(value)
        case "action":
            guard let raw = message["event"], let event = OpenUIActionEvent(raw: raw) else { return nil }
            return .action(event)
        case "copy":
            guard let text = message["text"] as? String, !text.isEmpty, text.utf8.count <= 16_384 else { return nil }
            return .copy(text)
        case "state":
            guard let raw = message["state"], let state = OpenUIJSONState(raw: raw) else { return nil }
            return .state(state)
        case "error":
            return .error(String((message["message"] as? String ?? "error").prefix(200)))
        default: return nil
        }
    }
}

/// Fit the answer's content into the native transcript, never a nested scroll view.
/// The shared frame rejects content beyond the same 12,000-point safety budget.
enum OpenUICardLayout {
    static let minHeight: CGFloat = 44
    static let maxHeight: CGFloat = 12_000
    static let placeholderHeight: CGFloat = 120

    static func frame(for reported: Double) -> (height: CGFloat, scrolls: Bool) {
        let value = CGFloat(reported)
        return (min(max(value, minHeight), maxHeight), false)
    }
}

/// Only the bundled shell document may load, once, in the main frame. Links,
/// redirects, reloads, subframes, popups and any other navigation are cancelled.
enum OpenUINavigationPolicy {
    static func allows(_ url: URL?, mainFrame: Bool, document: URL, initialLoadPending: Bool) -> Bool {
        guard mainFrame, initialLoadPending, let url, url.isFileURL, url.query == nil, url.fragment == nil else { return false }
        return url.standardizedFileURL.resolvingSymlinksInPath().path == document.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Script messages are accepted only from the main frame of the bundled document.
    static func acceptsMessage(mainFrame: Bool, originProtocol: String, documentURL: URL?, document: URL) -> Bool {
        guard mainFrame, originProtocol == "file" else { return false }
        guard let documentURL, documentURL.query == nil, documentURL.fragment == nil else { return false }
        return documentURL.isFileURL && documentURL.standardizedFileURL.resolvingSymlinksInPath().path == document.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum OpenUIResources {
    static var document: URL? { Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "OpenUI") }
}
