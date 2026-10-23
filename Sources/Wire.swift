import Foundation

indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var integer: Int? {
        guard let value = number, value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else { return nil }
        return Int(value)
    }
    static func text(_ value: String) -> JSONValue { .string(value) }
    static func obj(_ value: [String: JSONValue]) -> JSONValue { .object(value) }
}

struct NativeRPCError: LocalizedError {
    let message: String
    var requiresPairing = false
    var code: String? = nil
    var errorDescription: String? { message }
}

enum Wire {
    static func request(endpoint: String, payload: JSONValue, id: String) -> JSONValue {
        .obj(["type": .text("client-request"), "rpcId": .text(id), "method": .text(endpoint), "payload": payload])
    }
    static func response(_ envelope: JSONValue, id: String) throws -> JSONValue {
        guard envelope["type"].string == "server-response", envelope["rpcId"].string == id,
              let ok = envelope["result"]["ok"].bool else { throw NativeRPCError(message: "DSH returned an incompatible response.") }
        guard ok else {
            throw NativeRPCError(message: envelope["result"]["error"]["message"].string ?? "DSH refused this request.", code: envelope["result"]["error"]["code"].string)
        }
        return envelope["result"]["value"]
    }
}
