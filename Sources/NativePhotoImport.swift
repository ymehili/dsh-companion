import Foundation

/// A picker-owned source, consumed on the main actor. Only its bytes cross to
/// the background image decoder; no Photos identifiers or original bytes persist.
struct PhotoImportInput {
    let load: @MainActor () async throws -> Data?
}

extension NativeStore {
    /// Import lifetime belongs to the session draft, not to a transient composer
    /// `.task`. System picker dismissal/view reconstruction must not cancel it.
    @MainActor func importPhotos(_ inputs: [PhotoImportInput], for sessionId: String) {
        guard !inputs.isEmpty else { return }
        cancelPhotoImport(sessionId)
        let limits = PhotoLimits(desktopProjections[sessionId]?["imageLimits"] ?? .null), token = attachments.begin(sessionId)
        photoImportErrors[sessionId] = nil
        photoImportTasks[sessionId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.attachments.finish(sessionId, token: token, data: nil) { self.photoImportTasks[sessionId] = nil }
            }
            var failures: [String] = []
            for (index, input) in inputs.enumerated() {
                guard !Task.isCancelled, self.attachments.isCurrent(sessionId, token: token) else { return }
                do {
                    guard let source = try await input.load() else { throw NativeRPCError(message: "The photo library didn’t return this image. If it is stored in iCloud, download it in Photos and select it again.") }
                    try Task.checkCancellation()
                    let data = try await Task.detached(priority: .userInitiated) { try ImagePreparation.jpeg(source, limits: limits) }.value
                    try Task.checkCancellation()
                    guard self.attachments.isCurrent(sessionId, token: token) else { return }
                    if try self.attachments.append(sessionId, token: token, data: data, limits: limits) { self.scheduleDraftSave(sessionId) }
                } catch {
                    guard !Task.isCancelled, self.attachments.isCurrent(sessionId, token: token) else { return }
                    failures.append("Photo \(index + 1): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                self.photoImportErrors[sessionId] = failures.prefix(3).joined(separator: "\n") + "\nSelect the missing photos again to retry."
            }
        }
    }
    @MainActor func cancelPhotoImport(_ sessionId: String) {
        photoImportTasks.removeValue(forKey: sessionId)?.cancel()
        attachments.cancelLoading(sessionId)
    }
}
