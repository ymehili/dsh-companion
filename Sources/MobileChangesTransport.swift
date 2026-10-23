import Foundation

struct MobileChangesRequest {
    let path: String
    let query: [String: String]
    init(path: String, query: [String: String]) throws {
        let required: Set<String> = path == "/api/changes.summary" ? ["sessionId", "seq"] : ["sessionId", "seq", "index"]
        guard ["/api/changes.summary", "/api/changes.diff"].contains(path), Set(query.keys) == required,
              let session = query["sessionId"], !session.isEmpty, session.utf8.count <= 256,
              let seq = query["seq"].flatMap(Int.init), seq >= 0, seq <= 9_007_199_254_740_991 else { throw NativeRPCError(message: "Invalid change-review coordinates.") }
        if let raw = query["index"] { guard let index = Int(raw), index >= 0, index <= 9_007_199_254_740_991 else { throw NativeRPCError(message: "Invalid change-review file index.") } }
        self.path = path; self.query = query
    }
    var url: URL {
        var url = URLComponents(string: BridgeHTTP.origin + path)!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
}

extension NativeGateway {
    func resource(_ path: String, query: [String: String]) async throws -> JSONValue {
        guard let credential else { throw NativeRPCError(message: "Pair this iPhone with your Mac first.") }
        let coordinate = try MobileChangesRequest(path: path, query: query)
        var request = URLRequest(url: coordinate.url); request.timeoutInterval = 20
        request.setValue(BridgeHTTP.origin, forHTTPHeaderField: "Origin")
        request.setValue("\(BridgeHTTP.cookieName)=\(credential)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await http.session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw NativeRPCError(message: "No change-review response from your Mac.") }
        if response.statusCode == 401 || response.statusCode == 403 { throw NativeRPCError(message: "Pair this iPhone again to review changes.", requiresPairing: true) }
        if response.statusCode == 404 { throw NativeRPCError(message: "These turn changes are no longer available on your Mac. Turn recordings are not durable Git checkpoints.") }
        guard response.statusCode == 200, data.count <= 8 * 1024 * 1024 else { throw NativeRPCError(message: "The Mac could not return this change review within the native limit.") }
        return try await Task.detached(priority: .userInitiated) { try JSONDecoder().decode(JSONValue.self, from: data) }.value
    }
}
