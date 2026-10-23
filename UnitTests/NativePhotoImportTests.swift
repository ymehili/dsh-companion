import XCTest
import UIKit
@testable import DSHCompanion

@MainActor private final class PhotoLoadGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Data?, Never>?
    init(_ started: XCTestExpectation) { self.started = started }
    func load() async -> Data? {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func resume(_ data: Data?) { continuation?.resume(returning: data); continuation = nil }
}

final class NativePhotoImportTests: XCTestCase {
    @MainActor private func image() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
    }
    @MainActor func testDelayedPhotoOutlivesPickerViewTaskAndStaysInOriginalSession() async {
        let store = NativeStore(transport: ScriptedTransport(), restoreCredentials: false)
        let ready = expectation(description: "Photo transfer started"), gate = PhotoLoadGate(ready)
        let viewTask = Task { @MainActor in
            store.importPhotos([PhotoImportInput { await gate.load() }], for: "one")
            try? await Task.sleep(for: .seconds(60)) // cancelled with the simulated picker view
        }
        await fulfillment(of: [ready], timeout: 3)
        let job = store.photoImportTasks["one"]
        viewTask.cancel(); await viewTask.value
        store.selected = SessionRow(.obj(["sessionId": .text("two"), "updatedAt": .number(0), "running": .bool(false)]))
        gate.resume(image()); await job?.value
        XCTAssertEqual(store.attachments.photos(in: "one").count, 1)
        XCTAssertTrue(store.attachments.photos(in: "two").isEmpty)
        XCTAssertFalse(store.attachments.isLoading("one")); XCTAssertNil(store.photoImportErrors["one"])
    }
    @MainActor func testCancelledOldPhotoCannotEraseOrJoinReplacementBatch() async {
        let store = NativeStore(transport: ScriptedTransport(), restoreCredentials: false)
        let ready = expectation(description: "Old transfer started"), gate = PhotoLoadGate(ready)
        store.importPhotos([PhotoImportInput { await gate.load() }], for: "one")
        await fulfillment(of: [ready], timeout: 3)
        let old = store.photoImportTasks["one"]
        store.cancelPhotoImport("one")
        let bytes = image()
        store.importPhotos([PhotoImportInput { bytes }], for: "one")
        let replacement = store.photoImportTasks["one"]
        gate.resume(bytes); await old?.value; await replacement?.value
        XCTAssertEqual(store.attachments.photos(in: "one").count, 1)
        XCTAssertFalse(store.attachments.isLoading("one")); XCTAssertNil(store.photoImportTasks["one"])
    }
    @MainActor func testMissingLibraryDataProducesVisibleScopedIssueNotSilentDrop() async {
        let store = NativeStore(transport: ScriptedTransport(), restoreCredentials: false)
        store.importPhotos([PhotoImportInput { nil }], for: "one")
        let job = store.photoImportTasks["one"]; await job?.value
        XCTAssertTrue(store.attachments.photos(in: "one").isEmpty)
        XCTAssertFalse(store.attachments.isLoading("one"))
        XCTAssertTrue(store.photoImportErrors["one"]?.contains("photo library") == true)
        XCTAssertNil(store.photoImportErrors["two"])
    }
}
