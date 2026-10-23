import Foundation
import Observation

@MainActor
protocol MobileTerminalService: AnyObject {
    func rpc(_ endpoint: String, args: JSONValue) async throws -> JSONValue
    func attach(args: JSONValue, event: @escaping (JSONValue) -> Void, close: @escaping (String?) -> Void) async throws -> String
    func input(_ id: String, value: JSONValue) async throws
    func disconnect(_ id: String) async
}

@MainActor
final class MobileTerminalNativeService: MobileTerminalService {
    private let store: NativeStore
    init(_ store: NativeStore) { self.store = store }
    func rpc(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        try await store.gateway.rpc(endpoint, .obj(["args": args]))
    }
    func attach(args: JSONValue, event: @escaping (JSONValue) -> Void, close: @escaping (String?) -> Void) async throws -> String {
        try await store.openAuxiliaryStream("terminal/attach", args: args, onEvent: event, onClose: close)
    }
    func input(_ id: String, value: JSONValue) async throws { try await store.sendAuxiliaryInput(id, value: value) }
    func disconnect(_ id: String) async { await store.closeAuxiliaryStream(id) }
}

@MainActor @Observable
final class MobileTerminalController {
    let sessionId: String
    private let service: any MobileTerminalService
    var terminals: [MobileTerminalInfo] = []
    var selected: MobileTerminalInfo?
    var status = "Choose a terminal"
    var issue: String?
    var busy = false
    var creating = false
    var connected = false
    var control = false
    var protocolState = MobileTerminalProtocol()
    var environment = MobileTerminalEnvironment.fixture
    var renderGeneration = UUID()
    /// A bounded journal for a view newly mounted in this attachment. It is never
    /// sent to the host. Overflow requires a fresh recovery snapshot, not VT truncation.
    var renderChunks: [String] = []
    var pendingCreationID: String?
    private var renderedBytes = 0
    private var streamID: String?
    private var epoch = UUID()
    private var commands: [JSONValue] = []
    private var queuedBytes = 0
    private var sending = false
    private var grid: (Int, Int)?
    private var lastGrid: (Int, Int)?
    init(sessionId: String, service: any MobileTerminalService) { self.sessionId = sessionId; self.service = service }
    var canInput: Bool { connected && protocolState.writable && selected?.state == .running }
    private var identityArgs: JSONValue { .obj(["agentId": .text(sessionId), "id": .text(selected?.id ?? "")]) }

    func refresh() async {
        guard !busy else { return }; busy = true; issue = nil
        defer { busy = false }
        do {
            let result = try await service.rpc("terminal/list", args: .obj(["sessionId": .text(sessionId)]))
            terminals = try mobileTerminalDecode(result, as: [MobileTerminalInfo].self)
        } catch { issue = error.localizedDescription }
    }
    /// Called only after the user confirms the unsandboxed-shell warning.
    func createConfirmed() async {
        guard !creating else { return }; creating = true; issue = nil
        defer { creating = false }
        let current = epoch
        let id = pendingCreationID ?? "mobile-\(UUID().uuidString)"; pendingCreationID = id
        do {
            let result = try await service.rpc("terminal/create", args: .obj(["agentId": .text(sessionId), "request": .obj(["id": .text(id), "cols": .number(80), "rows": .number(24)])]))
            guard current == epoch else { return }
            let terminal = try mobileTerminalDecode(result, as: MobileTerminalInfo.self)
            pendingCreationID = nil
            if !terminals.contains(where: { $0.id == terminal.id }) { terminals.append(terminal) }
            await select(terminal)
        } catch { guard current == epoch else { return }; issue = "Could not confirm shell creation. Retry reuses the same shell identity. \(error.localizedDescription)" }
    }
    func select(_ terminal: MobileTerminalInfo) async {
        let current = await disconnect()
        guard epoch == current else { return }
        selected = terminal; status = "Attaching…"; issue = nil
        renderChunks = []; renderedBytes = 0; renderGeneration = UUID()
        do {
            let resolved = try mobileTerminalDecode(try await service.rpc("terminal/environment", args: .obj(["agentId": .text(sessionId)])), as: MobileTerminalEnvironment.self)
            guard epoch == current else { return }
            environment = resolved
            protocolState.maxInputBytes = max(1, environment.maxInputBytes)
            // Even without a carrier window, keep local buffering bounded.
            protocolState.maxWindowBytes = min(max(1024, environment.maxInputBytes + 1024), 1_048_576)
            let id = try await service.attach(args: identityArgs, event: { [weak self] value in
                guard let self, self.epoch == current else { return }; self.receive(value)
            }, close: { [weak self] error in
                guard let self, self.epoch == current else { return }
                self.invalidate(error ?? "Attachment ended. Reattach to continue; input is never replayed.")
            })
            guard epoch == current else { await service.disconnect(id); return }
            streamID = id
            await pump()
        } catch { guard epoch == current else { return }; invalidate(error.localizedDescription) }
    }
    func retryAttachment() async { if let selected { await select(selected) } else { await refresh() } }
    @discardableResult func disconnect() async -> UUID {
        let id = streamID; streamID = nil; epoch = UUID(); let current = epoch
        connected = false; protocolState.reset(); commands = []; queuedBytes = 0; sending = false
        control = false; status = selected == nil ? "Choose a terminal" : "Disconnected"
        grid = nil; lastGrid = nil
        if let id { await service.disconnect(id) }
        return current
    }
    private func invalidate(_ message: String) {
        let id = streamID; streamID = nil; epoch = UUID()
        connected = false; protocolState.reset(); commands = []; queuedBytes = 0; sending = false
        issue = message; status = "Disconnected"
        if let id { Task { await service.disconnect(id) } }
    }
    func receive(_ value: JSONValue) {
        do {
            switch value["type"].string {
            case "snapshot":
                guard protocolState.outputSequence == nil, let sequence = value["sequence"].integer,
                      let screen = value["screen"].string, value["info"]["id"].string == selected?.id else { throw MobileTerminalProtocol.Failure.invalidSequence }
                selected = try mobileTerminalDecode(value["info"], as: MobileTerminalInfo.self)
                try protocolState.baseline(sequence: sequence, writable: value["writable"].bool == true,
                                           maxBytes: value["inputWindow"]["maxBytes"].integer, overhead: value["inputWindow"]["frameOverheadBytes"].integer)
                renderGeneration = UUID(); renderChunks = [screen]; renderedBytes = screen.utf8.count
                connected = true; status = protocolState.writable ? "Connected" : "Read only"
                flushGrid()
            case "output":
                guard let sequence = value["sequence"].integer, let data = value["data"].string else { throw MobileTerminalProtocol.Failure.invalidSequence }
                if try protocolState.output(sequence: sequence) {
                    guard renderedBytes + data.utf8.count <= min(max(environment.maxBufferedBytes, 1_048_576), 8_388_608) else {
                        invalidate("Output recovery buffer is full. Reattach for a fresh screen."); return
                    }
                    renderChunks.append(data); renderedBytes += data.utf8.count
                }
            case "state":
                guard protocolState.outputSequence != nil, value["info"]["id"].string == selected?.id else { throw MobileTerminalProtocol.Failure.missingBaseline }
                selected = try mobileTerminalDecode(value["info"], as: MobileTerminalInfo.self)
                protocolState.writable = value["writable"].bool == true
                if !protocolState.writable { commands = []; queuedBytes = 0 }
                status = selected?.state == .running ? (protocolState.writable ? "Connected" : "Read only") : "Shell \(selected?.state.rawValue ?? "ended")"
            case "ack":
                guard let sequence = value["sequence"].integer else { throw MobileTerminalProtocol.Failure.invalidSequence }
                let refusal = value["refusal"].string
                try protocolState.acknowledge(sequence, refusal: refusal)
                if let refusal { commands = []; queuedBytes = 0; issue = "Input refused: \(refusal). Nothing will be replayed." }
                Task { await pump() }
            default: throw MobileTerminalProtocol.Failure.invalidSequence
            }
        } catch { invalidate("Terminal stream needs a new snapshot (\(error)). Reattach; pending input was discarded.") }
    }
    func write(_ data: String) {
        guard !data.isEmpty, canInput else { return }
        let input = control ? Self.controlInput(data) : data
        control = false
        enqueue(.obj(["type": .text("write"), "data": .text(input)]))
    }
    static func controlInput(_ data: String) -> String {
        guard data.unicodeScalars.count == 1, let first = data.uppercased().unicodeScalars.first, (64...95).contains(first.value), let scalar = UnicodeScalar(first.value & 31) else { return data }
        return String(scalar)
    }
    func resize(cols: Int, rows: Int) {
        let next = (min(max(2, cols), environment.maxCols), min(max(1, rows), environment.maxRows))
        grid = next; flushGrid()
    }
    private func flushGrid() {
        guard canInput, let grid, lastGrid?.0 != grid.0 || lastGrid?.1 != grid.1 else { return }
        lastGrid = grid
        enqueue(.obj(["type": .text("resize"), "cols": .number(Double(grid.0)), "rows": .number(Double(grid.1))]))
    }
    private func enqueue(_ value: JSONValue) {
        let bytes = (try? JSONEncoder().encode(value).count) ?? Int.max
        guard value["data"].string.map({ $0.utf8.count <= protocolState.maxInputBytes }) ?? true,
              bytes <= protocolState.maxWindowBytes,
              queuedBytes + bytes + protocolState.pendingBytes <= protocolState.maxWindowBytes else {
            issue = "Input buffer full or paste too large. This input was not sent; wait for acknowledgment and try again."; return
        }
        commands.append(value); queuedBytes += bytes
        Task { await pump() }
    }
    private func pump() async {
        guard !sending, canInput, let streamID, protocolState.pending.isEmpty else { return }
        guard !commands.isEmpty else { return }
        sending = true; let current = epoch
        let next = commands.removeFirst(); queuedBytes -= (try? JSONEncoder().encode(next).count) ?? 0
        do {
            let value = try protocolState.reserve(next.object ?? [:])
            try await service.input(streamID, value: value)
            guard current == epoch else { return }; sending = false
            if protocolState.pending.isEmpty { await pump() }
        } catch { guard current == epoch else { return }; sending = false; invalidate("Input delivery is uncertain; it will not be replayed. \(error.localizedDescription)") }
    }
    func rename(_ title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selected, !title.isEmpty, title.count <= 120 else { return }
        do {
            try await service.rpc("terminal/rename", args: .obj(["agentId": .text(sessionId), "id": .text(selected.id), "title": .text(title)]))
            self.selected?.title = title
            if let i = terminals.firstIndex(where: { $0.id == selected.id }) { terminals[i].title = title }
        } catch { issue = error.localizedDescription }
    }
    /// Only invoked by the destructive confirmation, never by view disappearance.
    func closeConfirmed() async {
        guard let selected else { return }
        do {
            try await service.rpc("terminal/close", args: identityArgs)
            await disconnect(); terminals.removeAll { $0.id == selected.id }; self.selected = nil
            renderChunks = []; renderGeneration = UUID(); status = "Choose a terminal"
        } catch { issue = error.localizedDescription }
    }
}
