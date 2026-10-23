import Foundation

@MainActor
protocol MobileSettingsRPC {
    func call(_ endpoint: String, _ args: [String: JSONValue]) async throws -> JSONValue
}

@MainActor
struct MobileSettingsNativeRPC: MobileSettingsRPC {
    let store: NativeStore
    func call(_ endpoint: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        guard !store.usesFixture else { throw MobileSettingsFailure.invalid("Live settings are disabled in demo mode.") }
        return try await store.gateway.rpc(endpoint, .obj(["args": .obj(args)]))
    }
}

enum MobileSettingsFailure: LocalizedError, Equatable {
    case invalid(String), conflict
    var errorDescription: String? {
        switch self { case .invalid(let message): return message; case .conflict: return "Settings changed elsewhere. Reload before saving again." }
    }
}

struct MobileSettingsField: Identifiable, Equatable {
    enum Kind: Equatable { case boolean, number, string, enumeration([JSONValue]), unsupported }
    let path: [String]
    let kind: Kind
    let schema: JSONValue
    let secret: Bool
    var id: String { path.joined(separator: ".") }
    var title: String { path.last ?? "Value" }
    var credentialReference: Bool { schema["meta"]["role"].string == "credential" || schema["meta"]["role"].string == "credential-ref" }

    func validate(_ value: JSONValue) throws {
        let meta = schema["meta"]
        switch kind {
        case .boolean: guard value.bool != nil else { throw MobileSettingsFailure.invalid("Expected a boolean.") }
        case .number:
            guard let n = value.number, n.isFinite else { throw MobileSettingsFailure.invalid("Enter a finite number.") }
            if let min = meta["min"].number, n < min { throw MobileSettingsFailure.invalid("Value is below the minimum.") }
            if let max = meta["max"].number, n > max { throw MobileSettingsFailure.invalid("Value exceeds the maximum.") }
            if meta["step"].number == 1, n.rounded() != n { throw MobileSettingsFailure.invalid("Enter a whole number.") }
        case .string:
            guard let text = value.string else { throw MobileSettingsFailure.invalid("Expected text.") }
            if let min = meta["min"].integer, text.count < min { throw MobileSettingsFailure.invalid("Text is too short.") }
            if let max = meta["max"].integer, text.count > max { throw MobileSettingsFailure.invalid("Text is too long.") }
        case .enumeration(let options): guard options.contains(value) else { throw MobileSettingsFailure.invalid("Choose a declared option.") }
        case .unsupported: throw MobileSettingsFailure.invalid("This schema type does not yet have a safe native editor.")
        }
    }
}

/// Schemastery serializes a graph as {uid,refs}, not JSON Schema properties.
/// Only understood leaves become editable; no callbacks or transforms execute.
enum MobileSettingsSchema {
    static func fields(_ envelope: JSONValue, secrets: [[String]], value: JSONValue = .null) throws -> [MobileSettingsField] {
        let refs = envelope["refs"].object ?? [:]
        func resolve(_ node: JSONValue) -> JSONValue {
            if let id = node.integer { return refs[String(id)] ?? .null }
            return node
        }
        var result: [MobileSettingsField] = []
        func walk(_ raw: JSONValue, _ path: [String], _ ancestors: Set<Int>, _ depth: Int) throws {
            guard depth < 32 else { throw MobileSettingsFailure.invalid("Schema nesting exceeds the safe editor limit.") }
            let node = resolve(raw)
            guard let type = node["type"].string else { throw MobileSettingsFailure.invalid("Unrecognized settings schema.") }
            var seen = ancestors
            if let id = raw.integer { guard !seen.contains(id) else { throw MobileSettingsFailure.invalid("Recursive schemas are not editable.") }; seen.insert(id) }
            if type == "object", let dict = node["dict"].object {
                for key in dict.keys.sorted() { try walk(dict[key]!, path + [key], seen, depth + 1) }; return
            }
            if type == "dict", let current = path.reduce(value, { $0[$1] }).object, !current.isEmpty {
                for key in current.keys.sorted() { try walk(node["inner"], path + [key], seen, depth + 1) }; return
            }
            if type == "intersect" { for item in node["list"].array { try walk(item, path, seen, depth + 1) }; return }
            let kind: MobileSettingsField.Kind
            switch type {
            case "boolean": kind = .boolean
            case "number": kind = .number
            case "string": kind = .string
            case "union":
                let nodes = node["list"].array.map(resolve)
                kind = !nodes.isEmpty && nodes.allSatisfy { $0["type"].string == "const" } ? .enumeration(nodes.map { $0["value"] }) : .unsupported
            default: kind = .unsupported
            }
            guard !path.isEmpty else { return }
            result.append(.init(path: path, kind: kind, schema: node, secret: secrets.contains(where: { path.starts(with: $0) }) || node["meta"]["role"].string == "secret"))
        }
        let root = envelope["uid"] == .null ? envelope : envelope["uid"]
        try walk(root, [], [], 0)
        guard Set(result.map(\.id)).count == result.count else { throw MobileSettingsFailure.invalid("Ambiguous schema paths are not editable.") }
        return result
    }
}

struct MobileSettingsNamespace: Identifiable, Equatable {
    let raw: JSONValue
    let id: String
    let revision: Int
    let fields: [MobileSettingsField]
    init(_ raw: JSONValue) throws {
        guard let ns = raw["ns"].string, !ns.isEmpty, let revision = raw["revision"].integer, revision >= 0, raw["applies"].string == "live" else { throw MobileSettingsFailure.invalid("Invalid namespace revision or apply mode.") }
        self.raw = raw; id = ns; self.revision = revision
        fields = try MobileSettingsSchema.fields(raw["schema"], secrets: raw["secrets"].array.map { $0["path"].array.compactMap(\.string) }, value: raw["value"])
    }
    func value(at path: [String]) -> JSONValue { path.reduce(raw["value"]) { $0[$1] } }
    func mutation(field: MobileSettingsField, value: JSONValue?, confirmed: Bool) throws -> [String: JSONValue] {
        guard confirmed else { throw MobileSettingsFailure.invalid("Explicit confirmation is required for live settings changes.") }
        guard fields.contains(field), !field.secret else { throw MobileSettingsFailure.invalid("Secret values must use the write-only credential flow.") }
        if let value { try field.validate(value) }
        var op: [String: JSONValue] = ["op": .text(value == nil ? "unset" : "set"), "path": .array(field.path.map(JSONValue.text))]
        if let value { op["value"] = value }
        return ["ns": .text(id), "expectedRevision": .number(Double(revision)), "ops": .array([.obj(op)])]
    }
}

@MainActor
final class MobileSettingsFixtureRPC: MobileSettingsRPC {
    enum Scenario { case normal, readOnly, unavailable, conflict }
    private let scenario: Scenario
    init(scenario: Scenario = .normal) { self.scenario = scenario }
    private var revision = 3
    private var values: JSONValue = .obj(["enabled": .bool(false), "credential": .text("DEMO_API_KEY"), "limits": .obj(["retries": .number(2)]), "mode": .text("manual")])
    private var credentialConfigured = false
    var calls: [String] = []
    func call(_ endpoint: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        calls.append(endpoint)
        if scenario == .unavailable { throw MobileSettingsFailure.invalid("Synthetic unavailable capability.") }
        if scenario == .readOnly && ["settings/mutate", "credentials/set", "credentials/unset"].contains(endpoint) { throw MobileSettingsFailure.invalid("Synthetic permission denied.") }
        switch endpoint {
        case "settings/describe": return .obj(["writable": .bool(scenario != .readOnly), "hasDocument": .bool(true), "namespaces": .array([namespace])])
        case "settings/mutate":
            guard scenario != .conflict, args["expectedRevision"]?.integer == revision else { throw MobileSettingsFailure.conflict }
            let snapshot = try MobileSettingsNamespace(namespace)
            for op in args["ops"]?.array ?? [] {
                let path = op["path"].array.compactMap(\.string)
                guard let field = snapshot.fields.first(where: { $0.path == path }), !field.secret else { throw MobileSettingsFailure.invalid("Unknown synthetic field.") }
                guard ["set", "unset"].contains(op["op"].string ?? "") else { throw MobileSettingsFailure.invalid("Unknown operation.") }
                if op["op"].string == "set" { try field.validate(op["value"]) }
                values = Self.setting(values, path: path[...], value: op["op"].string == "unset" ? nil : op["value"])
            }
            revision += 1; return namespace
        case "credentials/describe": return .obj(["DEMO_API_KEY": .obj(["configured": .bool(credentialConfigured), "writable": .bool(scenario != .readOnly)])])
        case "credentials/set": credentialConfigured = true; return .null
        case "credentials/unset": credentialConfigured = false; return .null
        case "llm/listConfigurableProviders": return .array([.obj(["provider": .text("demo"), "displayName": .text("Demo provider"), "settingsNs": .text("demo-provider"), "settingsPath": .array([]), "nativeAuth": .obj(["env": .array([.text("DEMO_API_KEY")]), "oauth": .bool(false)])])])
        case "llm/discoverModels": return .array([.obj(["id": .text("demo-model"), "name": .text("Synthetic model · no network")])])
        case "account/getState": return .obj(["status": .text("signed-out"), "links": .obj(["usageUrl": .text("https://example.invalid/usage"), "topUpUrl": .text("https://example.invalid/topup")]), "attempt": .null])
        default: throw MobileSettingsFailure.invalid("Synthetic capability unavailable.")
        }
    }
    private static func setting(_ root: JSONValue, path: ArraySlice<String>, value: JSONValue?) -> JSONValue {
        guard let first = path.first else { return value ?? .null }
        var object = root.object ?? [:]
        if path.count == 1 { object[first] = value }
        else { object[first] = setting(object[first] ?? .null, path: path.dropFirst(), value: value) }
        return .obj(object)
    }
    private var namespace: JSONValue {
        .obj(["ns": .text("demo-provider"), "revision": .number(Double(revision)), "applies": .text("live"), "autoGenerate": .bool(true), "secrets": .array([]), "value": values, "schema": .obj(["type": .text("object"), "dict": .obj(["enabled": .obj(["type": .text("boolean")]), "credential": .obj(["type": .text("string"), "meta": .obj(["role": .text("credential-ref")])]), "limits": .obj(["type": .text("object"), "dict": .obj(["retries": .obj(["type": .text("number"), "meta": .obj(["min": .number(0), "max": .number(10), "step": .number(1)])])])]), "mode": .obj(["type": .text("union"), "list": .array([.obj(["type": .text("const"), "value": .text("manual")]), .obj(["type": .text("const"), "value": .text("automatic")])])])])])])
    }
}
