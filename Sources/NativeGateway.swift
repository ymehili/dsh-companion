import Foundation

@MainActor
final class NativeGateway: NativeTransport {
    let http = BridgeHTTP()
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pongTimeout: Task<Void, Never>?
    private var generation = UUID()
    private var pendingPing: UUID?

    private static let maximumMessageSize = 16 * 1024 * 1024
    private static let heartbeatInterval: Duration = .seconds(20)
    private static let pongTimeoutInterval: Duration = .seconds(10)

    deinit {
        reader?.cancel()
        heartbeat?.cancel()
        pongTimeout?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        guard let credential else { throw NativeRPCError(message: "Pair this iPhone with your Mac first.") }
        let id = UUID().uuidString
        var request = URLRequest(url: URL(string: BridgeHTTP.origin + "/api/" + endpoint)!)
        request.httpMethod = "POST"
        if endpoint == "threadInbox/watch" { request.timeoutInterval = 45 }
        request.setValue(BridgeHTTP.origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(BridgeHTTP.cookieName)=\(credential)", forHTTPHeaderField: "Cookie")
        let requestEnvelope = Wire.request(endpoint: endpoint, payload: payload, id: id)
        request.httpBody = try await Task.detached(priority: .userInitiated) { try JSONEncoder().encode(requestEnvelope) }.value
        try Task.checkCancellation()
        let (data, response) = try await http.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NativeRPCError(message: "No response from your Mac.") }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw NativeRPCError(message: "This device is no longer authorized. Pair again using a fresh QR from your Mac.", requiresPairing: true)
        }
        guard response.statusCode == 200 else { throw NativeRPCError(message: "Your Mac is unavailable (HTTP \(response.statusCode)). Keep DSH open and your Mac awake.") }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        let value = try await Task.detached(priority: .userInitiated) { try NativeRPCBody.decode(data, contentType: contentType, rpcID: id) }.value
        try Task.checkCancellation()
        return value
    }

    func openStream() {
        closeStream()
        guard let credential else { return }
        let current = generation
        var request = URLRequest(url: URL(string: BridgeHTTP.origin.replacingOccurrences(of: "https://", with: "wss://") + "/api/remote.mux")!)
        request.setValue(BridgeHTTP.origin, forHTTPHeaderField: "Origin")
        request.setValue("\(BridgeHTTP.cookieName)=\(credential)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 3600
        let socket = http.session.webSocketTask(with: request)
        socket.maximumMessageSize = Self.maximumMessageSize
        self.socket = socket
        socket.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard !Task.isCancelled, self?.isCurrent(socket, current) == true else { return }
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default:
                        // An unreadable frame may contain durable updates; never skip it.
                        self?.streamFailed(socket, current)
                        return
                    }
                    let frame = try await Self.decode(data)
                    guard !Task.isCancelled, self?.isCurrent(socket, current) == true else { return }
                    self?.onFrame?(frame)
                }
            } catch {
                // Malformed JSON is a data gap, not an ignorable frame. The owner
                // reconnects/rebaselines; concurrent receive/ping/send failures coalesce.
                if !Task.isCancelled { self?.streamFailed(socket, current) }
            }
        }
        heartbeat = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: Self.heartbeatInterval)
                    guard !Task.isCancelled, self?.isCurrent(socket, current) == true else { return }
                    self?.beginPing(socket, current)
                }
            } catch { /* Closing a stream cancels its heartbeat. */ }
        }
    }

    func sendFrame(_ value: JSONValue) async throws {
        guard let socket else { throw NativeRPCError(message: "The live connection is offline.") }
        let current = generation
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw NativeRPCError(message: "Could not encode the live update.")
        }
        try Task.checkCancellation()
        do {
            try await socket.send(.string(string))
        } catch {
            if !Task.isCancelled { streamFailed(socket, current) }
            throw error
        }
        guard isCurrent(socket, current) else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func closeStream() {
        // Invalidate first: neither a late pong nor a completed decode may reach
        // callbacks after a close/reopen. Explicit closes never notify disconnect.
        generation = UUID()
        pendingPing = nil
        reader?.cancel()
        reader = nil
        heartbeat?.cancel()
        heartbeat = nil
        pongTimeout?.cancel()
        pongTimeout = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func isCurrent(_ socket: URLSessionWebSocketTask, _ current: UUID) -> Bool {
        generation == current && self.socket === socket
    }

    private func streamFailed(_ socket: URLSessionWebSocketTask, _ current: UUID) {
        guard isCurrent(socket, current) else { return }
        closeStream()
        onDisconnect?()
    }

    private func beginPing(_ socket: URLSessionWebSocketTask, _ current: UUID) {
        guard isCurrent(socket, current), pendingPing == nil else { return }
        let ping = UUID()
        pendingPing = ping
        // A separate cancellable watchdog does not await sendPing's callback.
        // A missing callback therefore cannot strand a continuation or TaskGroup.
        pongTimeout = Task { [weak self] in
            do { try await Task.sleep(for: Self.pongTimeoutInterval) }
            catch { return }
            guard !Task.isCancelled, self?.pendingPing == ping else { return }
            self?.streamFailed(socket, current)
        }
        socket.sendPing { [weak self] error in
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(socket, current), self.pendingPing == ping else { return }
                self.pendingPing = nil
                self.pongTimeout?.cancel()
                self.pongTimeout = nil
                if failed { self.streamFailed(socket, current) }
            }
        }
    }

    private nonisolated static func decode(_ data: Data) async throws -> JSONValue {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
