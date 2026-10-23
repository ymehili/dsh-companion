import Foundation

/// Synthetic resource-only fixture. No gateway, disk reads, RPC or live recorder involved.
@MainActor final class MobileReviewFixtureTransport: NativeTransport {
    enum Mode: String, CaseIterable { case recorded = "Recorded", empty = "Empty", error = "Unavailable" }
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var mode: Mode = .recorded
    static func records(_ sessionId: String) -> [MobileReviewRecord] {
        [MobileReviewRecord(sessionId: sessionId, seq: 81, turn: 2), MobileReviewRecord(sessionId: sessionId, seq: 37, turn: 1)]
    }
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue { throw MobileReviewFailure.boundary }
    func resource(_ path: String, query: [String: String]) async throws -> JSONValue {
        guard let session = query["sessionId"], !session.isEmpty, let seq = query["seq"].flatMap(Int.init), [37, 81].contains(seq) else { throw MobileReviewFailure.boundary }
        if mode == .error { throw MobileReviewFailure.unavailable }
        let turn = seq == 81 ? 2 : 1
        if path == "/api/changes.summary" {
            guard Set(query.keys) == ["sessionId", "seq"] else { throw MobileReviewFailure.boundary }
            if mode == .empty { return .obj(["turn": .number(Double(turn)), "files": .array([]), "total": .number(0), "added": .number(0), "deleted": .number(0)]) }
            return .obj(["turn": .number(Double(turn)), "files": .array([
                .obj(["path": .text("Sources/Welcome.swift"), "display": .text("Sources/Welcome.swift"), "added": .number(2), "deleted": .number(1)]),
                .obj(["path": .text("Assets/demo.bin"), "display": .text("Assets/demo.bin"), "added": .number(0), "deleted": .number(0), seq == 81 ? "binary" : "oversized": .bool(true)])
            ]), "total": .number(2), "added": .number(2), "deleted": .number(1)])
        }
        guard path == "/api/changes.diff", Set(query.keys) == ["sessionId", "seq", "index"], let index = query["index"].flatMap(Int.init), [0, 1].contains(index) else { throw MobileReviewFailure.boundary }
        if index == 1 { return .obj(["kind": .text(seq == 81 ? "binary" : "oversized"), "path": .text("Assets/demo.bin"), "display": .text("Assets/demo.bin")]) }
        return .obj(["kind": .text("text"), "path": .text("Sources/Welcome.swift"), "display": .text("Sources/Welcome.swift"), "before": .bool(true), "after": .bool(true), "coarse": .bool(seq == 37), "hunks": .array([
            .obj(["oldStart": .number(1), "oldLines": .number(3), "newStart": .number(1), "newLines": .number(4), "lines": .array([" struct Welcome {", "-    let title = \"Hello\"", "+    let title = \"Welcome back\"", "+    let subtitle = \"A synthetic review fixture — horizontally scroll to read long lines.\"", " }"].map(JSONValue.text))])
        ])])
    }
    func openStream() {}
    func sendFrame(_ value: JSONValue) async throws { throw MobileReviewFailure.boundary }
    func closeStream() {}
}
