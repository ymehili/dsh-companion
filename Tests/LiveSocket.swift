import Foundation

@main
struct LiveSocketProbe {
    static func main() async throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let config = try JSONDecoder().decode(JSONValue.self, from: input)
        guard let cookie = config["cookie"].string, let id = config["sessionId"].string else { throw NativeRPCError(message: "Missing private probe inputs") }
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:19387/api/remote.mux")!)
        request.setValue("http://127.0.0.1:19387", forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        let control = config["control"].bool == true
        let payload: JSONValue = control ? .obj(["args": .obj([:])]) : .obj(["args": .obj(["request": .obj(["address": .obj(["kind": .text("session"), "sessionId": .text(id)]), "assistantStream": .bool(true), "maxMessages": .number(config["audit"].bool == true ? 60 : 5)])])])
        let frame = JSONValue.obj(["type": .text("open"), "streamId": .text("native-readonly-probe"), "endpoint": .text(control ? "session/control" : "session/follow"), "payload": payload])
        try await socket.send(.string(String(data: JSONEncoder().encode(frame), encoding: .utf8)!))
        let received = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                let message = try await socket.receive()
                let data: Data
                switch message { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: throw NativeRPCError(message: "Unknown frame") }
                var envelope = try JSONDecoder().decode(JSONValue.self, from: data).object ?? [:]
                envelope["__probeBytes"] = .number(Double(data.count))
                return .obj(envelope)
            }
            group.addTask { try await Task.sleep(for: .seconds(20)); socket.cancel(with: .goingAway, reason: nil); throw NativeRPCError(message: "Probe timed out") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        if control {
            guard received["type"].string == "item", received["value"]["type"].string == "baseline" else { throw NativeRPCError(message: "Host did not send configuration baseline") }
            print("Native control stream baseline verified; session count: \(received["value"]["value"]["projections"].object?.count ?? 0)")
            return
        }
        guard received["type"].string == "item", received["value"]["type"].string == "snapshot" else { throw NativeRPCError(message: "Host did not send expected snapshot") }
        var conversation = Conversation(); conversation.accept(received["value"])
        var roles: [String: JSONValue] = [:]
        for role in Set(conversation.entries.map(\.role)) { roles[role] = .number(Double(conversation.entries.filter { $0.role == role }.count)) }
        let safe = JSONValue.obj(["snapshot": .bool(true), "wireBytes": received["__probeBytes"], "recordCount": .number(Double(conversation.events.count)), "renderedEntries": .number(Double(conversation.entries.count)), "roles": .obj(roles), "hasMore": .bool(conversation.hasMore), "formatVersion": received["value"]["header"]["version"]])
        print(String(data: try JSONEncoder().encode(safe), encoding: .utf8)!)
    }
}
