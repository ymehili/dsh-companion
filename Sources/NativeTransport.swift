import Foundation

/// Main-actor delivery; a disconnect invalidates the stream and requires a fresh baseline.
@MainActor
protocol NativeTransport: AnyObject {
    var credential: String? { get set }
    var onFrame: ((JSONValue) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }

    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue
    func resource(_ path: String, query: [String: String]) async throws -> JSONValue
    func openStream()
    func sendFrame(_ value: JSONValue) async throws
    func closeStream()
}

extension NativeTransport {
    func resource(_ path: String, query: [String: String]) async throws -> JSONValue {
        throw NativeRPCError(message: "This connection does not expose the requested resource.")
    }
}
