import XCTest
@testable import DSHCompanion

@MainActor final class MobileReviewTests: XCTestCase {
    private let record = MobileReviewRecord(sessionId: "review-session", seq: 81, turn: 2)
    func testEventsAreScopedAndUseWorkspaceEventSequenceNotTurn() {
        let events: [Int: JSONValue] = [
            10: .obj(["type": .text("turn/start"), "seq": .number(10), "data": .obj(["turn": .number(2)])]),
            81: .obj(["type": .text("workspace/changes"), "seq": .number(81), "data": .obj(["turn": .number(2)])]),
            90: .obj(["type": .text("turn/end"), "seq": .number(90), "data": .obj(["turn": .number(2)])]),
            92: .obj(["type": .text("workspace/changes"), "seq": .number(91), "data": .obj(["turn": .number(3)])])
        ]
        XCTAssertEqual(MobileReviewRecord.loaded(sessionId: record.sessionId, selectedId: record.sessionId, events: events), [record])
        XCTAssertTrue(MobileReviewRecord.loaded(sessionId: record.sessionId, selectedId: "other", events: events).isEmpty)
        XCTAssertTrue(MobileReviewRecord.loaded(sessionId: record.sessionId, selectedId: nil, events: events).isEmpty)
    }
    func testExactResourceCoordinatesAndNoRPC() async throws {
        let fake = MobileReviewTestTransport()
        let service = MobileReviewService(sessionId: record.sessionId, transport: fake)
        let summary = try await service.summary(record)
        XCTAssertEqual(fake.calls[0].0, "/api/changes.summary")
        XCTAssertEqual(fake.calls[0].1, ["sessionId": record.sessionId, "seq": "81"])
        let diff = try await service.diff(summary.files[0], summary: summary)
        XCTAssertEqual(diff.hunks[0].lines[1].old, 2)
        XCTAssertNil(diff.hunks[0].lines[1].new)
        XCTAssertEqual(fake.calls[1].0, "/api/changes.diff")
        XCTAssertEqual(fake.calls[1].1, ["sessionId": record.sessionId, "seq": "81", "index": "0"])
        XCTAssertEqual(fake.rpcCount, 0)
    }
    func testOtherSessionAndForgedFileAreRejectedBeforeDispatch() async throws {
        let fake = MobileReviewTestTransport()
        let service = MobileReviewService(sessionId: record.sessionId, transport: fake)
        do { _ = try await service.summary(.init(sessionId: "other", seq: 81, turn: 2)); XCTFail() } catch { XCTAssertEqual(error as? MobileReviewFailure, .boundary) }
        XCTAssertTrue(fake.calls.isEmpty)
        let summary = try await service.summary(record)
        let forged = MobileReviewFile(index: 0, path: "other.swift", display: "other.swift", added: 2, deleted: 1, binary: false, oversized: false)
        do { _ = try await service.diff(forged, summary: summary); XCTFail() } catch { XCTAssertEqual(error as? MobileReviewFailure, .boundary) }
        XCTAssertEqual(fake.calls.count, 1)
    }
    func testRefusalsRemainRefusalsAndFixtureEmptyError() async throws {
        let fixture = MobileReviewFixtureTransport()
        let service = MobileReviewService(sessionId: record.sessionId, transport: fixture)
        for (seq, turn, kind) in [(81, 2, "binary"), (37, 1, "oversized")] {
            let summary = try await service.summary(.init(sessionId: record.sessionId, seq: seq, turn: turn))
            let diff = try await service.diff(summary.files[1], summary: summary)
            XCTAssertEqual(diff.kind, kind); XCTAssertTrue(diff.hunks.isEmpty)
        }
        fixture.mode = .empty
        let empty = try await service.summary(record)
        XCTAssertTrue(empty.files.isEmpty)
        fixture.mode = .error
        do { _ = try await service.summary(record); XCTFail() } catch { XCTAssertEqual(error as? MobileReviewFailure, .unavailable) }
    }
    func testPathMismatchAndHunkValidationLimits() async throws {
        let fixture = MobileReviewFixtureTransport()
        let raw = try await fixture.resource("/api/changes.diff", query: ["sessionId": record.sessionId, "seq": "81", "index": "0"])
        let summary = try await MobileReviewService(sessionId: record.sessionId, transport: fixture).summary(record)
        let file = summary.files[0]
        var object = raw.object!
        object["path"] = .text("unrelated.swift")
        XCTAssertThrowsError(try MobileReviewDiff(.obj(object), file: file))
        for (key, value) in [("oldStart", JSONValue.number(-1)), ("newLines", .number(9)), ("oldStart", .number(0)), ("oldLines", .number(10_000_001))] {
            object = raw.object!; var hunk = raw["hunks"].array[0].object!; hunk[key] = value; object["hunks"] = .array([.obj(hunk)])
            XCTAssertThrowsError(try MobileReviewDiff(.obj(object), file: file))
        }
        let invalidLines: [[JSONValue]] = [[.text("?invalid")], [.text("+embedded\nline")], [.text("\\ invalid marker")], [.text("+" + String(repeating: "x", count: 32_768))], Array(repeating: .text("+x"), count: 20_001)]
        for lines in invalidLines {
            object = raw.object!; var hunk = raw["hunks"].array[0].object!; hunk["lines"] = .array(lines); object["hunks"] = .array([.obj(hunk)])
            XCTAssertThrowsError(try MobileReviewDiff(.obj(object), file: file))
        }
        object = raw.object!; object["hunks"] = .array(Array(repeating: raw["hunks"].array[0], count: 1001))
        XCTAssertThrowsError(try MobileReviewDiff(.obj(object), file: file))
    }
    func testSummaryCountPathTurnAndFileLimit() async throws {
        let fixture = MobileReviewFixtureTransport()
        let raw = try await fixture.resource("/api/changes.summary", query: ["sessionId": record.sessionId, "seq": "81"])
        for (key, value) in [("turn", JSONValue.number(81)), ("total", .number(0)), ("added", .number(-1)), ("deleted", .number(0.5))] {
            var object = raw.object!; object[key] = value
            XCTAssertThrowsError(try MobileReviewSummary(.obj(object), record: record))
        }
        var object = raw.object!; object["files"] = .array(Array(repeating: raw["files"].array[0], count: 501))
        XCTAssertThrowsError(try MobileReviewSummary(.obj(object), record: record))
        object = raw.object!; var file = raw["files"].array[0].object!; file["path"] = .text("bad\npath"); object["files"] = .array([.obj(file)])
        XCTAssertThrowsError(try MobileReviewSummary(.obj(object), record: record))
    }
    func testRangeCoordinatesImmutableAndXMLEscaped() throws {
        let target = try MobileReviewTarget(record: .init(sessionId: "s<&\"'", seq: 81, turn: 2), path: "a<&\"'.swift", side: "old", start: 12, end: 4)
        XCTAssertEqual(target.start, 4); XCTAssertEqual(target.end, 12)
        XCTAssertEqual(target.label, "L4–L12")
        let xml = try target.xml(comment: "</review_comment> & \"'\nKeep this")
        XCTAssertTrue(xml.contains("session_id=\"s&lt;&amp;&quot;&apos;\""))
        XCTAssertTrue(xml.contains("path=\"a&lt;&amp;&quot;&apos;.swift\""))
        XCTAssertTrue(xml.contains("line_start=\"4\" line_end=\"12\""))
        XCTAssertTrue(xml.contains("&lt;/review_comment&gt; &amp; &quot;&apos;"))
        XCTAssertFalse(xml.contains("\n</review_comment> &"))
        XCTAssertThrowsError(try target.xml(comment: " \n"))
        XCTAssertThrowsError(try target.xml(comment: String(repeating: "x", count: 16_385)))
        XCTAssertThrowsError(try MobileReviewTarget(record: record, path: "file", side: "new", start: 0, end: 2))
    }
    func testDraftAppendUsesCapturedSessionAndDoesNotPrompt() async throws {
        let fake = MobileReviewTestTransport()
        let store = NativeStore(transport: fake, restoreCredentials: false)
        let a = SessionRow(.obj(["sessionId": .text("a")]))!
        let b = SessionRow(.obj(["sessionId": .text("b")]))!
        store.sessions = [a, b]; store.selected = b
        let target = try MobileReviewTarget(record: .init(sessionId: "a", seq: 81, turn: 2), path: "file.swift", side: "new", start: 1, end: 2)
        XCTAssertTrue(store.appendReviewDraft(try target.xml(comment: "Check this"), for: target.record.sessionId))
        XCTAssertEqual(store.draft, "")
        await store.choose(a)
        XCTAssertTrue(store.draft.contains("Check this"))
        XCTAssertTrue(fake.calls.isEmpty); XCTAssertEqual(fake.rpcCount, 0)
    }
}

@MainActor private final class MobileReviewTestTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    var calls: [(String, [String: String])] = []
    var rpcCount = 0
    private let fixture = MobileReviewFixtureTransport()
    func resource(_ path: String, query: [String: String]) async throws -> JSONValue { calls.append((path, query)); return try await fixture.resource(path, query: query) }
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue { rpcCount += 1; throw MobileReviewFailure.boundary }
    func openStream() {}
    func closeStream() {}
    func sendFrame(_ value: JSONValue) async throws { throw MobileReviewFailure.boundary }
}
