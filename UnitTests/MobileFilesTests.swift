import XCTest
@testable import DSHCompanion

@MainActor
final class MobileFilesTests: XCTestCase {
    private func listing(_ names: [(String, String)], path: String = "", truncated: Bool = false) -> JSONValue {
        .obj(["path": .text(path), "truncated": .bool(truncated), "entries": .array(names.map { .obj(["name": .text($0.0), "type": .text($0.1)]) })])
    }
    private func identity(path: String = "/workspace/a.swift", version: String = "v1", bytes: Int = 2) -> JSONValue {
        .obj(["absolutePath": .text(path), "version": .text(version), "bytes": .number(Double(bytes))])
    }
    private func page(offset: Int = 1, lines: Int = 2, text: String = "a\nb", eof: Bool = true, version: String = "v1") -> JSONValue {
        var result = identity(version: version).object!
        result["offset"] = .number(Double(offset)); result["lines"] = .number(Double(lines)); result["text"] = .text(text); result["eof"] = .bool(eof)
        return .obj(result)
    }
    private func setup(codec: MobileFileByteCodec = .unavailable) throws -> (MobileFilesService, MobileFilesTestTransport) {
        let transport = MobileFilesTestTransport()
        return (try MobileFilesService(sessionId: "actual-session-id", workspaceRoot: "/workspace", transport: transport, byteCodec: codec), transport)
    }
    private func file(_ service: MobileFilesService, _ transport: MobileFilesTestTransport) async throws -> MobileFileEntry {
        transport.result = listing([("a.swift", "file")])
        return try await service.list().entries[0]
    }
    func testRelativePathBoundary() {
        for path in ["/etc/passwd", "../x", "a/../x", "a//b", "a/", ".", "a/./b", "a\\b", "a\0b", "https:x", "C:/x"] {
            XCTAssertFalse(MobileFilePath.relative(path), path)
        }
        XCTAssertTrue(MobileFilePath.relative("Sources/Hello world.swift"))
        XCTAssertTrue(MobileFilePath.relative(""))
        XCTAssertNil(MobileFilePath.root("/workspace/../other"))
        XCTAssertNil(MobileFilePath.root("//workspace"))
        XCTAssertNil(MobileFilePath.root("relative"))
        XCTAssertEqual(MobileFilePath.absolute(root: "/workspace", relative: "a"), "/workspace/a")
    }
    func testExactDirectArgsAndUnmodifiedScopeIdentity() async throws {
        let (service, transport) = try setup()
        let entry = try await file(service, transport)
        XCTAssertEqual(transport.calls[0].0, "workspaceFiles/list")
        XCTAssertEqual(transport.calls[0].1, .obj(["args": .obj(["workspaceFileScopeId": .text("actual-session-id"), "path": .text(".")])]))
        transport.result = identity()
        let source = try await service.stat(entry)
        transport.result = page()
        let read = try await service.text(entry, offset: 1, identity: source)
        XCTAssertEqual(read.numberedLines.map { $0.0 }, [1, 2])
        XCTAssertEqual(read.nextOffset, 3)
        XCTAssertEqual(transport.calls.last?.1["args"]["range"], .obj(["offset": .number(1), "limit": .number(160)]))
        XCTAssertEqual(transport.calls.last?.1["args"]["request"], .null)
    }
    func testUnlistedFilesAndDirectoriesNeverDispatch() async throws {
        let (service, transport) = try setup()
        let forged = MobileFileEntry(path: "secret", name: "secret", kind: .file, size: nil)
        do { _ = try await service.stat(forged); XCTFail("Unlisted read") } catch { XCTAssertEqual(error as? MobileFileFailure, .boundary) }
        do { _ = try await service.list("unknown"); XCTFail("Unlisted directory") } catch { XCTAssertEqual(error as? MobileFileFailure, .boundary) }
        XCTAssertTrue(transport.calls.isEmpty)
    }
    func testMaliciousBasenamesInvalidateListing() async throws {
        for name in ["../escape", "a/b", "a\\b", ".", "..", "", "bad\0name"] {
            let (service, transport) = try setup(); transport.result = listing([(name, "file")])
            do { _ = try await service.list(); XCTFail(name) } catch { }
        }
    }
    func testDuplicateAndUnknownEntryTypesRejected() async throws {
        let (service, transport) = try setup()
        for value in [listing([("a", "file"), ("a", "file")]), listing([("a", "symlink")])] {
            transport.result = value
            do { _ = try await service.list(); XCTFail("Malformed listing accepted") } catch { }
        }
    }
    func testDirectoryCanonicalPathMismatchCannotAuthorizeChildren() async throws {
        let (service, transport) = try setup()
        transport.result = listing([("alias", "directory")]); _ = try await service.list()
        transport.result = listing([("a.swift", "file")], path: "elsewhere")
        do { _ = try await service.list("alias"); XCTFail("Alias accepted") } catch { XCTAssertEqual(error as? MobileFileFailure, .boundary) }
        let before = transport.calls.count
        do { _ = try await service.stat(.init(path: "alias/a.swift", name: "a.swift", kind: .file, size: nil)); XCTFail() } catch { }
        XCTAssertEqual(transport.calls.count, before)
    }
    func testOtherKindsRemainDisabled() async throws {
        let (service, transport) = try setup(); transport.result = listing([("socket", "other")], truncated: true)
        let result = try await service.list()
        XCTAssertTrue(result.truncated)
        let before = transport.calls.count
        do { _ = try await service.stat(result.entries[0]); XCTFail() } catch { }
        XCTAssertEqual(transport.calls.count, before)
    }
    func testStatOutsideWorkspaceOrPrefixSiblingRefusesBeforeRead() async throws {
        for path in ["/workspace-other/a.swift", "/private/a.swift", "/workspace/sub/../a.swift"] {
            let (service, transport) = try setup(); let entry = try await file(service, transport)
            transport.result = identity(path: path)
            do { _ = try await service.stat(entry); XCTFail(path) } catch { XCTAssertEqual(error as? MobileFileFailure, .boundary) }
            XCTAssertEqual(transport.calls.map { $0.0 }, ["workspaceFiles/list", "workspaceFiles/stat"])
        }
    }
    func testTextOffsetsEmptyLineAndNoProgressValidation() async throws {
        let (service, transport) = try setup(); let entry = try await file(service, transport)
        let source = try MobileFileIdentity(identity(), expectedPath: "/workspace/a.swift")
        transport.result = page(offset: 161, lines: 1, text: "", eof: true)
        let blank = try await service.text(entry, offset: 161, identity: source)
        XCTAssertEqual(blank.lines, 1); XCTAssertEqual(blank.numberedLines.first?.0, 161); XCTAssertEqual(blank.nextOffset, 162)
        transport.result = page(lines: 0, text: "", eof: true)
        let emptyPage = try await service.text(entry, offset: 1, identity: source)
        XCTAssertEqual(emptyPage.numberedLines.count, 0)
        for bad in [page(offset: 2), page(lines: 0, text: "", eof: false), page(lines: 1, text: "a\nb"), page(lines: 161)] {
            transport.result = bad
            do { _ = try await service.text(entry, offset: 1, identity: source); XCTFail("Bad page accepted") } catch { }
        }
    }
    func testVersionAndSourceMismatchDoNotExposeText() async throws {
        let (service, transport) = try setup(); let entry = try await file(service, transport)
        let source = try MobileFileIdentity(identity(), expectedPath: "/workspace/a.swift")
        transport.result = page(version: "new-version")
        do { _ = try await service.text(entry, offset: 1, identity: source); XCTFail() } catch { XCTAssertEqual(error as? MobileFileFailure, .changed) }
        var bad = page().object!; bad["absolutePath"] = .text("/outside/a.swift"); transport.result = .obj(bad)
        do { _ = try await service.text(entry, offset: 1, identity: source); XCTFail() } catch { XCTAssertEqual(error as? MobileFileFailure, .boundary) }
    }
    func testByteCodecIsExplicitAndRejectsBase64FractionalAndOverflow() throws {
        XCTAssertThrowsError(try MobileFileByteCodec.unavailable.decode(.obj(["data": .text("AAEC")]), 3))
        XCTAssertThrowsError(try MobileFileByteCodec.unavailable.decode(.obj(["data": .null]), 3))
        let invalidBytes: [[JSONValue]] = [[.number(-1)], [.number(256)], [.number(1.5)], [.string("1")], [.bool(true)]]
        for values in invalidBytes {
            XCTAssertThrowsError(try MobileFileByteCodec.checkedBytes(values, cap: 3))
        }
        XCTAssertThrowsError(try MobileFileByteCodec.checkedBytes([.number(1), .number(2)], cap: 1))
        XCTAssertEqual(try MobileFileByteCodec.checkedBytes([.number(0), .number(127), .number(255)], cap: 3), Data([0, 127, 255]))
    }
    func testAuthorizedBytePagingHonorsCapsAndOffsets() async throws {
        let codec = MobileFileByteCodec { value, cap in
            guard case .array(let bytes) = value["testBytes"] else { throw MobileFileFailure.malformed }
            return try MobileFileByteCodec.checkedBytes(bytes, cap: cap)
        }
        let (service, transport) = try setup(codec: codec); let entry = try await file(service, transport)
        let size = MobileFilesService.byteChunk + 3
        let source = try MobileFileIdentity(identity(bytes: size), expectedPath: "/workspace/a.swift")
        transport.handler = { endpoint, payload in
            XCTAssertEqual(endpoint, "workspaceFiles/readBytes")
            let range = payload["args"]["options"]["range"]
            let offset = range["offset"].integer!, length = range["length"].integer!
            XCTAssertLessThanOrEqual(length, MobileFilesService.byteChunk)
            XCTAssertNil(payload["args"]["options"].object?["baseFile"])
            var result = self.identity(bytes: size).object!
            result["offset"] = .number(Double(offset)); result["eof"] = .bool(offset + length == size)
            result["testBytes"] = .array(Array(repeating: .number(42), count: length)); return .obj(result)
        }
        let bytes = try await service.media(entry, identity: source)
        XCTAssertEqual(bytes.count, size); XCTAssertEqual(bytes.last, 42)
        XCTAssertEqual(transport.calls.suffix(2).map { $0.1["args"]["options"]["range"]["offset"].integer! }, [0, MobileFilesService.byteChunk])
    }
    func testMediaSizeAndTruncationFailClosed() async throws {
        let (service, transport) = try setup(codec: .init { _, _ in Data([1]) })
        let entry = try await file(service, transport)
        let tooLarge = try MobileFileIdentity(identity(bytes: MobileFilesService.mediaCap + 1), expectedPath: "/workspace/a.swift")
        let before = transport.calls.count
        do { _ = try await service.media(entry, identity: tooLarge); XCTFail() } catch { }
        XCTAssertEqual(transport.calls.count, before)
        let source = try MobileFileIdentity(identity(bytes: 2), expectedPath: "/workspace/a.swift")
        var response = identity(bytes: 2).object!; response["offset"] = .number(0); response["eof"] = .bool(false); transport.result = .obj(response)
        do { _ = try await service.media(entry, identity: source); XCTFail("Partial bytes accepted") } catch { }
    }
    func testTransportErrorIsPropagatedForRetry() async throws {
        let (service, transport) = try setup()
        transport.handler = { _, _ in throw MobileFileFailure(message: "Permission denied") }
        do { _ = try await service.list(); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, "Permission denied") }
        transport.handler = nil; transport.result = listing([])
        let retried = try await service.list(); XCTAssertTrue(retried.entries.isEmpty)
    }
    func testSyntheticFixtureCoversTextPagingEmptyTruncatedAndMedia() async throws {
        let fixture = MobileFilesFixtureTransport()
        let service = try MobileFilesService(sessionId: "fixture", workspaceRoot: MobileFilesFixtureTransport.root, transport: fixture, byteCodec: MobileFilesFixtureTransport.codec)
        let root = try await service.list()
        XCTAssertTrue(root.entries.contains { $0.name == "README.md" })
        let empty = try await service.list("Empty"); XCTAssertTrue(empty.entries.isEmpty)
        let limited = try await service.list("Limited"); XCTAssertTrue(limited.truncated)
        let sources = try await service.list("Sources"), swift = sources.entries[0]
        let source = try await service.stat(swift)
        let first = try await service.text(swift, offset: 1, identity: source)
        XCTAssertFalse(first.eof); XCTAssertEqual(first.lines, 160)
        let second = try await service.text(swift, offset: first.nextOffset, identity: source); XCTAssertEqual(second.offset, 161)
        let image = root.entries.first { $0.name == "Preview.png" }!
        let imageSource = try await service.stat(image), imageBytes = try await service.media(image, identity: imageSource)
        XCTAssertEqual(Array(imageBytes.prefix(4)), [137, 80, 78, 71])
        let pdf = root.entries.first { $0.name == "Guide.pdf" }!
        let pdfSource = try await service.stat(pdf), pdfBytes = try await service.media(pdf, identity: pdfSource)
        XCTAssertEqual(String(data: pdfBytes.prefix(4), encoding: .ascii), "%PDF")
    }
}

@MainActor
private final class MobileFilesTestTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var calls: [(String, JSONValue)] = []
    var result: JSONValue = .null
    var handler: ((String, JSONValue) throws -> JSONValue)?
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        calls.append((endpoint, payload)); return try handler?(endpoint, payload) ?? result
    }
    func openStream() {}
    func closeStream() {}
    func sendFrame(_ value: JSONValue) async throws { XCTFail("Files must not open terminal or streams") }
}
