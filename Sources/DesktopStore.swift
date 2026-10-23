import Foundation

@MainActor
extension NativeStore {
    var currentProjection: JSONValue { selected.flatMap { desktopProjections[$0.id] } ?? .obj([:]) }
    var currentModel: JSONValue {
        let selection = currentProjection["modelSelection"]
        return selection["next"] == .null ? selection["lastUsed"] : selection["next"]
    }
    var currentModelLabel: String {
        let model = currentModel["model"].string
        if let choice = models.first(where: { $0.model == model && $0.provider == currentModel["provider"].string }) { return choice.name }
        return model ?? "Model"
    }
    var currentPermissionLabel: String {
        guard let value = currentProjection["permissions"]["currentValue"].string else { return "Permissions" }
        switch value {
        case "danger-full-access", "full-access": return "Full access"
        case "workspace-write": return "Workspace write"
        case "read-only": return "Read only"
        default: return value.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
    func sidebarRecord(for row: SessionRow) -> JSONValue {
        let projection = desktopProjections[row.id] ?? .null
        var pending = projection["userQuestions"]["active"].array.map { question in
            JSONValue.obj(["id": question["callId"], "kind": .text(question["questions"].array.contains(where: { $0["intent"]["kind"].string == "plan-review" }) ? "plan-review" : "question")])
        }
        if approvals.contains(where: { $0.sessionId == row.id }) { pending.append(.obj(["id": .text("live:\(row.id)"), "kind": .text("approval")])) }
        let children = Set(projection["subagentCatalog"].array.compactMap { $0["id"].string })
        let background = !children.isEmpty && sessions.contains(where: { children.contains($0.id) && $0.running })
        return DesktopInbox.resolvedRecord(inboxThreads[row.id] ?? .null, row: row, pinned: workspaceState.pinned.contains(row.id), backgroundWork: background, pending: pending)
    }
    func sidebarSection(for row: SessionRow) -> String { DesktopInbox.section(record: sidebarRecord(for: row), running: row.running) }
    func sidebarStatus(for row: SessionRow) -> String? { DesktopInbox.status(record: sidebarRecord(for: row), running: row.running) }
    func refreshInbox() async {
        guard !usesFixture, !inboxLoading else { return }
        inboxLoading = true
        defer { inboxLoading = false }
        do {
            let result = try await gateway.rpc("threadInbox/snapshot", .obj(["args": .obj([:])]))
            try Task.checkCancellation()
            guard acceptInbox(result) else { throw NativeRPCError(message: "The Mac returned an incompatible shelf snapshot.") }
        } catch {
            guard !Task.isCancelled else { return }
            // Never turn a transient error into a different, flat sidebar layout.
            inboxError = "Couldn’t sync shelves from your Mac. Retrying… \(error.localizedDescription)"
        }
    }
    @discardableResult
    func acceptInbox(_ result: JSONValue) -> Bool {
        if !inboxReplica.apply(result) {
            // A concurrent refresh may already have applied a newer revision.
            if result["epoch"].string == inboxReplica.epoch, let revision = result["revision"].integer, revision < inboxReplica.revision { return true }
            return false
        }
        inboxThreads = inboxReplica.threads
        inboxAvailable = inboxReplica.activated
        inboxHasSnapshot = inboxReplica.hasSnapshot
        inboxError = nil
        return true
    }
    func startInboxUpdates() {
        guard !usesFixture, inboxWatchTask == nil else { return }
        let generation = UUID()
        inboxWatchGeneration = generation
        inboxWatchTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.inboxWatchGeneration == generation { self.inboxWatchTask = nil } }
            while !Task.isCancelled && self.inboxWatchGeneration == generation {
                if !self.inboxReplica.hasSnapshot { await self.refreshInbox() }
                guard !Task.isCancelled else { return }
                guard let request = self.inboxReplica.watchRequest else {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    continue
                }
                do {
                    let result = try await self.gateway.rpc("threadInbox/watch", .obj(["args": .obj(["request": request])]))
                    try Task.checkCancellation()
                    guard self.inboxWatchGeneration == generation else { return }
                    if !self.acceptInbox(result) { await self.refreshInbox() }
                    // Protect against an unexpectedly immediate server response loop.
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    guard !Task.isCancelled, self.inboxWatchGeneration == generation else { return }
                    self.inboxError = "Shelf updates paused. Keeping the last Mac snapshot; retrying shortly."
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
    }
    func stopInboxUpdates() {
        inboxWatchGeneration = UUID()
        inboxWatchTask?.cancel()
        inboxWatchTask = nil
    }
    func loadModels() async {
        guard !modelLoading else { return }
        modelLoading = true
        modelError = nil
        defer { modelLoading = false }
        if usesFixture { return }
        do { models = NativeModelChoice.catalog(try await gateway.rpc("session/modelCatalog", .obj(["args": .obj([:])])) ) }
        catch { self.modelError = error.localizedDescription }
    }
    func selectModel(_ choice: NativeModelChoice, effort: String?) async -> Bool {
        guard let id = selected?.id, connected else { return false }
        modelError = nil
        var selection: [String: JSONValue] = ["provider": .text(choice.provider), "model": .text(choice.model)]
        if let effort { selection["reasoningEffort"] = .text(effort) }
        var request = selection
        request["sessionId"] = .text(id)
        do {
            let selected: JSONValue
            if usesFixture { selected = .obj(selection) }
            else { selected = try await gateway.rpc("session/selectModel", .obj(["args": .obj(["request": .obj(request)])]))["selected"] }
            var projection = desktopProjections[id]?.object ?? [:]
            var model = projection["modelSelection"]?.object ?? [:]
            model["next"] = selected
            projection["modelSelection"] = .obj(model)
            desktopProjections[id] = .obj(projection)
            return true
        } catch { self.modelError = error.localizedDescription; return false }
    }
}
