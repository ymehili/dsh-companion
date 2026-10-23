import Foundation

struct MobileTerminalInfo: Codable, Equatable, Identifiable, Sendable {
    struct Shell: Codable, Equatable, Sendable { var path: String; var args: [String]; var name: String }
    enum State: String, Codable, Sendable { case failed, running, exited }
    var id: String
    var title: String
    var shell: Shell
    var cwd: String
    var cols: Int
    var rows: Int
    var state: State
    var exitCode: Int?
    var error: String?
    static let fixture = MobileTerminalInfo(id: "fixture-terminal", title: "Demo shell", shell: Shell(path: "fixture", args: [], name: "Demo"), cwd: "Demo workspace", cols: 80, rows: 24, state: .running)
}

struct MobileTerminalEnvironment: Codable, Sendable {
    var cwd: String
    var maxInputBytes: Int
    var maxBufferedBytes: Int
    var maxCols: Int
    var maxRows: Int
    var scrollback: Int
    static let fixture = Self(cwd: "Demo workspace", maxInputBytes: 4096, maxBufferedBytes: 1_048_576, maxCols: 400, maxRows: 200, scrollback: 1000)
}

/// Attachment-scoped protocol state. Reset always discards unacknowledged input;
/// an ACK means host acceptance, not proof a command completed successfully.
struct MobileTerminalProtocol {
    enum Failure: Error, Equatable { case missingBaseline, outputGap, invalidSequence, inputTooLarge, backpressure, readOnly }
    private(set) var generation = UUID()
    private(set) var outputSequence: Int?
    private(set) var inputSequence = 0
    private(set) var pending: [(sequence: Int, bytes: Int)] = []
    var writable = false
    var maxInputBytes = 4096
    var maxWindowBytes = 4096
    var frameOverheadBytes = 0
    var pendingBytes: Int { pending.reduce(0) { $0 + $1.bytes } }
    mutating func reset() { self = Self() }
    mutating func baseline(sequence: Int, writable: Bool, maxBytes: Int?, overhead: Int?) throws {
        guard sequence >= 0 else { throw Failure.invalidSequence }
        outputSequence = sequence; self.writable = writable
        if let maxBytes { guard maxBytes > 0 else { throw Failure.inputTooLarge }; maxWindowBytes = min(maxBytes, 1_048_576) }
        if let overhead { guard overhead >= 0 else { throw Failure.inputTooLarge }; frameOverheadBytes = overhead }
    }
    mutating func output(sequence: Int) throws -> Bool {
        guard let last = outputSequence else { throw Failure.missingBaseline }
        if sequence <= last { return false }
        guard sequence == last + 1 else { throw Failure.outputGap }
        outputSequence = sequence; return true
    }
    mutating func reserve(_ fields: [String: JSONValue]) throws -> JSONValue {
        guard outputSequence != nil else { throw Failure.missingBaseline }
        guard writable else { throw Failure.readOnly }
        if let data = fields["data"]?.string, data.utf8.count > maxInputBytes { throw Failure.inputTooLarge }
        let next = inputSequence + 1
        var fields = fields; fields["sequence"] = .number(Double(next))
        let value = JSONValue.obj(fields)
        let bytes = try JSONEncoder().encode(value).count + frameOverheadBytes
        guard bytes <= maxWindowBytes else { throw Failure.inputTooLarge }
        guard pendingBytes + bytes <= maxWindowBytes else { throw Failure.backpressure }
        inputSequence = next; pending.append((next, bytes)); return value
    }
    mutating func acknowledge(_ sequence: Int, refusal: String?) throws {
        guard pending.first?.sequence == sequence else { throw Failure.invalidSequence }
        pending.removeFirst()
        if refusal != nil { writable = false }
    }
}

func mobileTerminalDecode<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
}
