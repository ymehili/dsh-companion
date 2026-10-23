import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import DSHCompanion

final class NativeDraftVaultTests: XCTestCase {
    private let origin = "https://draft.example"
    private var ownedRoot: URL!
    private var tempParent: URL!
    private var rootName: String!

    override func setUpWithError() throws {
        tempParent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        rootName = "NativeDraftVaultTests-" + UUID().uuidString
        ownedRoot = tempParent.appendingPathComponent(rootName, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)
        try verifyOwnedRoot()
    }

    override func tearDownWithError() throws {
        // Never delete a computed path until its real absolute target is verified.
        try verifyOwnedRoot()
        try FileManager.default.removeItem(at: ownedRoot)
        ownedRoot = nil
    }

    private func verifyOwnedRoot() throws {
        let absolute = ownedRoot.standardizedFileURL
        guard absolute.path.hasPrefix(tempParent.path + "/"), absolute.lastPathComponent == rootName,
              rootName.hasPrefix("NativeDraftVaultTests-"),
              absolute.deletingLastPathComponent() == tempParent,
              absolute.resolvingSymlinksInPath().path == absolute.path else {
            throw NativeDraftVaultError.unsafePath("test cleanup refused")
        }
        var info = stat()
        guard lstat(absolute.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw NativeDraftVaultError.unsafePath("test root is not an owned directory")
        }
    }

    private func vault(_ host: String? = nil, limits: NativeDraftVaultLimits = .init()) throws -> NativeDraftVault {
        try NativeDraftVault(rootFolderURL: ownedRoot, origin: host ?? origin, limits: limits)
    }

    private func record(_ sid: String = "session", mode: String = "queue", host: String? = nil, text: String = " \nexact 🦆\r\n ") -> NativeDraftRecord {
        .init(origin: host ?? origin, sessionId: sid, workspace: "/opaque/workspace", title: " Draft ", unsent: true,
              text: text, photos: [.init(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, data: Data([0, 255, 4, 0]))],
              pending: .init(requestID: "request-exact-ID", text: " pending \n", images: [Data([3, 2, 1]), Data([0]), Data([3, 2, 1])], mode: mode),
              updatedAt: Date(timeIntervalSince1970: 1_700_000_000.125))
    }

    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func hostFolder(_ host: String? = nil) -> URL { ownedRoot.appendingPathComponent(digest(host ?? origin), isDirectory: true) }
    private func recordURL(_ sid: String, host: String? = nil) -> URL { hostFolder(host).appendingPathComponent(digest(sid) + ".draft") }

    private func failure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected visible error", file: file, line: line) } catch { }
    }

    func testExactRoundTripBothImmutableModesAndMemoryFake() async throws {
        let disk = try vault()
        let memory = try NativeMemoryDraftVault(origin: origin)
        for mode in ["queue", "steer"] {
            let value = record(mode, mode: mode)
            let saved = try await disk.save(record: value, revision: 7)
            let fakeSaved = try await memory.save(record: value, revision: 7)
            XCTAssertTrue(saved); XCTAssertTrue(fakeSaved)
        }
        let snapshot = await disk.load()
        let fake = await memory.load()
        XCTAssertEqual(snapshot, fake)
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertEqual(snapshot.records["steer"], record("steer", mode: "steer"))
        let restarted = try vault()
        let restored = await restarted.load()
        XCTAssertEqual(snapshot, restored)
    }

    func testStaleWritesTombstonesAndRestartNeverResurrect() async throws {
        let disk = try vault()
        let saved = try await disk.save(record: record(), revision: 10)
        let stale = try await disk.save(record: record(text: "stale"), revision: 9)
        let equal = try await disk.remove(sessionId: "session", revision: 10)
        let removed = try await disk.remove(sessionId: "session", revision: 12)
        XCTAssertTrue(saved); XCTAssertFalse(stale); XCTAssertFalse(equal); XCTAssertTrue(removed)
        let restarted = try vault()
        let resurrection = try await restarted.save(record: record(), revision: 11)
        let secondRemove = try await restarted.remove(sessionId: "session", revision: 12)
        XCTAssertFalse(resurrection); XCTAssertFalse(secondRemove)
        let snapshot = await restarted.load()
        XCTAssertNil(snapshot.records["session"]); XCTAssertEqual(snapshot.revisions["session"], 12)
        let newEdit = try await restarted.save(record: record(text: "new explicit edit"), revision: 13)
        XCTAssertTrue(newEdit)
    }

    func testRevisionMaximumDoesNotOverflowOrWrap() async throws {
        let disk = try vault()
        let removed = try await disk.remove(sessionId: "session", revision: UInt64.max)
        XCTAssertTrue(removed)
        for revision in [UInt64(0), UInt64(1), UInt64.max - 1, UInt64.max] {
            let accepted = try await disk.save(record: record(), revision: revision)
            XCTAssertFalse(accepted)
        }
        let restarted = try vault()
        let state = await restarted.load()
        XCTAssertEqual(state.revisions["session"], UInt64.max); XCTAssertTrue(state.records.isEmpty)
    }

    func testHostNormalizationIsolationAndNoRescope() async throws {
        XCTAssertEqual(try NativeDraftVault.normalizedOrigin("HTTPS://DRAFT.Example:443/"), origin)
        let one = try vault("HTTPS://DRAFT.Example:443/")
        let two = try vault("https://other.example")
        _ = try await one.save(record: record(), revision: 1)
        let other = await two.load()
        XCTAssertTrue(other.records.isEmpty); XCTAssertTrue(other.revisions.isEmpty)
        await failure { _ = try await two.save(record: self.record(), revision: 2) }
        _ = try await two.save(record: record(host: "https://other.example"), revision: 2)
        let first = await one.load()
        XCTAssertEqual(first.records["session"]?.origin, origin)
        let port = try vault("https://draft.example:444")
        let separatePort = await port.load(); XCTAssertTrue(separatePort.records.isEmpty)
        for invalid in ["http://draft.example", "https://user@draft.example", "https://draft.example/path", "https://draft.example?x", "https://draft.example#x", "https://-bad.example", "https://draft.example.", "file:///tmp", "https://draft.example:0"] {
            XCTAssertThrowsError(try NativeDraftVault.normalizedOrigin(invalid), invalid)
        }
    }

    func testCorruptionPreservesBytesBlocksOverwriteAndKeepsValidRecords() async throws {
        let disk = try vault()
        _ = try await disk.save(record: record("broken"), revision: 1)
        _ = try await disk.save(record: record("good"), revision: 2)
        let broken = recordURL("broken")
        let corrupt = Data([0, 255, 0, 5])
        try corrupt.write(to: broken, options: .atomic)
        let state = await disk.load()
        XCTAssertNil(state.records["broken"]); XCTAssertEqual(state.records["good"], record("good"))
        XCTAssertFalse(state.issues.isEmpty)
        await failure { _ = try await disk.save(record: self.record("broken"), revision: 100) }
        await failure { _ = try await disk.remove(sessionId: "broken", revision: 101) }
        XCTAssertEqual(try Data(contentsOf: broken), corrupt)
        _ = try await disk.save(record: record("good", text: "valid edited"), revision: 3)
        let after = await disk.load(); XCTAssertEqual(after.records["good"]?.text, "valid edited")
    }

    func testSchemaChecksumAndPayloadDomainValidation() async throws {
        let disk = try vault()
        for sid in ["schema", "checksum", "domain", "session-mismatch", "mode"] {
            _ = try await disk.save(record: record(sid), revision: 1)
        }
        for sid in ["schema", "checksum", "domain", "session-mismatch", "mode"] {
            let path = recordURL(sid)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            if sid == "schema" { object["schema"] = 999 }
            else if sid == "checksum" { object["checksum"] = String(repeating: "0", count: 64) }
            else {
                let encoded = try XCTUnwrap(object["payload"] as? String)
                let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
                var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                if sid == "domain" { payload["origin"] = "https://other.example" }
                else if sid == "session-mismatch" { payload["sessionId"] = "different" }
                else {
                    var r = try XCTUnwrap(payload["record"] as? [String: Any])
                    var p = try XCTUnwrap(r["pending"] as? [String: Any]); p["mode"] = "send"
                    r["pending"] = p; payload["record"] = r
                }
                let changed = try JSONSerialization.data(withJSONObject: payload)
                object["payload"] = changed.base64EncodedString()
                object["checksum"] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
            }
            try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
        }
        let state = await disk.load()
        XCTAssertEqual(state.issues.count, 5); XCTAssertTrue(state.records.isEmpty)
        await failure { _ = try await disk.save(record: self.record("schema"), revision: 2) }
    }

    func testQuotaFailuresNeverEvictPayloadsAndCountTombstones() async throws {
        var limits = NativeDraftVaultLimits(); limits.maxRecords = 1
        let disk = try vault(limits: limits)
        _ = try await disk.save(record: record(), revision: 1)
        await failure { _ = try await disk.save(record: self.record("second"), revision: 1) }
        let before = await disk.load(); XCTAssertEqual(before.records["session"], record())
        _ = try await disk.remove(sessionId: "session", revision: 2)
        await failure { _ = try await disk.save(record: self.record("second"), revision: 3) }
        let after = await disk.load(); XCTAssertEqual(after.revisions["session"], 2)
        var small = NativeDraftVaultLimits(); small.maxTotalBytes = 10
        let tiny = try vault("https://tiny.example", limits: small)
        await failure { _ = try await tiny.save(record: self.record(host: "https://tiny.example"), revision: 1) }
        var text = NativeDraftVaultLimits(); text.maxTextBytes = 2
        let textVault = try vault(limits: text)
        await failure { _ = try await textVault.save(record: self.record(), revision: 3) }
        var image = NativeDraftVaultLimits(); image.maxImageBytes = 2
        let imageVault = try vault(limits: image)
        await failure { _ = try await imageVault.save(record: self.record(), revision: 3) }
        image.maxImageBytes = 100; image.maxImages = 3
        let countVault = try vault(limits: image)
        await failure { _ = try await countVault.save(record: self.record(), revision: 3) }
        var encoded = NativeDraftVaultLimits(); encoded.maxRecordBytes = 1
        let encodedVault = try vault(limits: encoded)
        await failure { _ = try await encodedVault.save(record: self.record(), revision: 3) }
    }

    func testOpaqueSessionIDsCannotEscapeAndInvalidModesAreRejected() async throws {
        let disk = try vault()
        let hostile = "../../arbitrary/subfolder"
        _ = try await disk.save(record: record(hostile), revision: 1)
        let restored = await disk.load(); XCTAssertEqual(restored.records[hostile], record(hostile))
        let entries = try FileManager.default.contentsOfDirectory(at: hostFolder(), includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(entries.map(\.lastPathComponent)), [digest(hostile) + ".draft", ".lock"])
        await failure { _ = try await disk.save(record: self.record(mode: "send"), revision: 2) }
        await failure { _ = try await disk.remove(sessionId: "", revision: 2) }
        await failure { _ = try await disk.remove(sessionId: "bad\0id", revision: 2) }
        XCTAssertThrowsError(try NativeDraftVault(rootFolderURL: URL(string: "https://draft.example")!, origin: origin))
    }

    func testSymlinkRootAndRecordAreRefusedWithoutTouchingDestination() async throws {
        let destination = ownedRoot.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let link = ownedRoot.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let badRoot = try NativeDraftVault(rootFolderURL: link, origin: origin)
        let state = await badRoot.load(); XCTAssertFalse(state.issues.isEmpty)
        await failure { _ = try await badRoot.save(record: self.record(), revision: 1) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let disk = try vault()
        _ = try await disk.save(record: record("good"), revision: 1)
        let sentinel = ownedRoot.appendingPathComponent("sentinel")
        let sentinelBytes = Data([9, 8, 7]); try sentinelBytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: recordURL("linked"), withDestinationURL: sentinel)
        let linked = await disk.load(); XCTAssertEqual(linked.records["good"], record("good")); XCTAssertFalse(linked.issues.isEmpty)
        await failure { _ = try await disk.save(record: self.record("linked"), revision: 1) }
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
    }

    func testNonDirectoryRootAndLazyInitialization() async throws {
        let future = ownedRoot.appendingPathComponent("not-created", isDirectory: true)
        let lazy = try NativeDraftVault(rootFolderURL: future, origin: origin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: future.path))
        let empty = await lazy.load(); XCTAssertTrue(empty.issues.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: future.path))
        let file = ownedRoot.appendingPathComponent("file")
        try Data([0]).write(to: file)
        let invalid = try NativeDraftVault(rootFolderURL: file, origin: origin)
        let state = await invalid.load(); XCTAssertFalse(state.issues.isEmpty)
        await failure { _ = try await invalid.save(record: self.record(), revision: 1) }
    }

    func testMemoryTombstonesAndConfigurationBounds() async throws {
        let memory = try NativeMemoryDraftVault(origin: origin)
        _ = try await memory.save(record: record(), revision: 4)
        _ = try await memory.remove(sessionId: "session", revision: 6)
        let stale = try await memory.save(record: record(), revision: 5)
        XCTAssertFalse(stale)
        let snapshot = await memory.load()
        XCTAssertEqual(snapshot.revisions["session"], 6); XCTAssertTrue(snapshot.records.isEmpty)
        var invalid = NativeDraftVaultLimits(); invalid.maxRecordBytes = Int.max
        XCTAssertThrowsError(try vault(limits: invalid))
        XCTAssertThrowsError(try NativeMemoryDraftVault(origin: origin, limits: invalid))
        invalid.maxRecordBytes = 1024; invalid.maxRecords = 0
        XCTAssertThrowsError(try vault(limits: invalid))
    }

    func testTrustedSystemAliasNeverPermitsAnAliasAsVaultRoot() async throws {
        var info = stat()
        if lstat("/var", &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
            XCTAssertTrue(NativeDraftVault.isTrustedSystemVarAlias(URL(fileURLWithPath: "/var")))
            let rootAlias = try NativeDraftVault(rootFolderURL: URL(fileURLWithPath: "/var"), origin: origin)
            let result = await rootAlias.load()
            XCTAssertFalse(result.issues.isEmpty, "The system alias exemption must not apply to the vault root itself")
        }
        XCTAssertFalse(NativeDraftVault.isTrustedSystemVarAlias(ownedRoot.appendingPathComponent("var")))
        XCTAssertFalse(NativeDraftVault.isTrustedSystemVarAlias(ownedRoot))
    }

    func testConcurrentActorsAlwaysKeepHighestRevisionAndTombstone() async throws {
        let one = try vault(), two = try vault()
        // Pre-create the shared folder before simultaneous actor access.
        _ = try await one.remove(sessionId: "other", revision: 1)
        let value = record()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in UInt64(1)...UInt64(80) {
                group.addTask {
                    let target = revision.isMultiple(of: 2) ? one : two
                    if revision == 80 { _ = try await target.remove(sessionId: "session", revision: revision) }
                    else { _ = try await target.save(record: value, revision: revision) }
                }
            }
            try await group.waitForAll()
        }
        let restarted = try vault(); let state = await restarted.load()
        XCTAssertEqual(state.revisions["session"], 80); XCTAssertNil(state.records["session"])
        XCTAssertTrue(state.issues.isEmpty)
    }
}
