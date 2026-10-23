import Foundation

/// A synthetic terminal service: no process, RPC, network, Agent or shell parser.
/// The only demo command understood is `echo <text>`; all other lines are inert.
@MainActor
final class MobileTerminalFixtureService: MobileTerminalService {
    private var terminals = [MobileTerminalInfo.fixture]
    private var event: ((JSONValue) -> Void)?
    private var close: ((String?) -> Void)?
    private var currentID: String?
    private var sequence = 0
    private var line = ""
    private var screen = "\u{1B}[32mDSH demo terminal\u{1B}[0m\r\nSynthetic fixture • no commands run on your Mac.\r\nTry: echo hello\r\n$ "
    private func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    func rpc(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        switch endpoint {
        case "terminal/list": return try json(terminals)
        case "terminal/environment": return try json(MobileTerminalEnvironment.fixture)
        case "terminal/create":
            let id = args["request"]["id"].string ?? "fixture-new"
            if let existing = terminals.first(where: { $0.id == id }) { return try json(existing) }
            var info = MobileTerminalInfo.fixture; info.id = id; info.title = "Demo shell \(terminals.count + 1)"; terminals.append(info); return try json(info)
        case "terminal/rename":
            if let i = terminals.firstIndex(where: { $0.id == args["id"].string }) { terminals[i].title = args["title"].string ?? terminals[i].title }; return .null
        case "terminal/close": terminals.removeAll { $0.id == args["id"].string }; return .null
        default: throw NativeRPCError(message: "Unsupported fixture operation")
        }
    }
    func attach(args: JSONValue, event: @escaping (JSONValue) -> Void, close: @escaping (String?) -> Void) async throws -> String {
        guard let info = terminals.first(where: { $0.id == args["id"].string }) else { throw NativeRPCError(message: "Demo shell not found") }
        self.event = event; self.close = close; currentID = UUID().uuidString
        event(.obj(["type": .text("snapshot"), "sequence": .number(Double(sequence)), "screen": .text(screen), "info": try json(info), "writable": .bool(true), "inputWindow": .obj(["maxBytes": .number(8192), "frameOverheadBytes": .number(64)])]))
        return currentID!
    }
    func input(_ id: String, value: JSONValue) async throws {
        guard id == currentID else { throw NativeRPCError(message: "Fixture attachment ended") }
        if value["type"].string == "write", let data = value["data"].string {
            var output = ""
            for ch in data {
                if ch == "\r" || ch == "\n" {
                    output += "\r\n"
                    if line.hasPrefix("echo ") { output += String(line.dropFirst(5)) + "\r\n" }
                    else if !line.isEmpty { output += "Demo only: no command executed.\r\n" }
                    output += "$ "; line = ""
                } else if ch == "\u{7F}" || ch == "\u{08}" {
                    if !line.isEmpty { line.removeLast(); output += "\u{08} \u{08}" }
                } else if ch == "\u{03}" { line = ""; output += "^C\r\n$ " }
                else if ch.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) { line.append(ch); output.append(ch) }
            }
            sequence += 1; screen += output
            event?(.obj(["type": .text("output"), "sequence": .number(Double(sequence)), "data": .text(output)]))
        }
        event?(.obj(["type": .text("ack"), "sequence": value["sequence"]]))
    }
    func disconnect(_ id: String) async {
        guard currentID == id else { return }; currentID = nil; event = nil; close = nil
    }
}
