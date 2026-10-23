#if DEBUG
import Foundation

/// Offline, explicitly launched interaction fixtures; never used as a fallback.
@MainActor final class NativeQuestionFixtureTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    private var failedOnce = false
    func openStream() {}
    func closeStream() {}
    func sendFrame(_ value: JSONValue) async throws {}
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        guard endpoint == "$events/result" || endpoint == "userQuestions/answer" else { throw NativeRPCError(message: "Unsupported interaction fixture request") }
        if ProcessInfo.processInfo.arguments.contains("-native-question-retry-fixture") && !failedOnce {
            failedOnce = true; throw NativeRPCError(message: "Synthetic answer failure")
        }
        return .bool(true)
    }
    static var request: JSONValue {
        .obj(["questions": .array([
            .obj(["id": .text("direction"), "header": .text("Choose direction"), "question": .text("Which layout should the agent use?"), "options": .array([.obj(["label": .text("Mac style"), "description": .text("Keep the visible shelves and desktop identity.")]), .obj(["label": .text("Mobile history")])])]),
            .obj(["id": .text("details"), "question": .text("Which details matter most?"), "multiSelect": .bool(true), "options": .array([.obj(["label": .text("Readable titles")]), .obj(["label": .text("Compact footer")])])])
        ])])
    }
}
#endif
