import XCTest
@testable import DSHCompanion

final class NativeRPCBodyTests: XCTestCase {
    private let boundary = "dsh-boundary-123"
    private func metadata(value: JSONValue = .obj(["data": .null]), path: [JSONValue] = [.text("data")], rpcID: String = "test") throws -> Data {
        try JSONEncoder().encode(JSONValue.obj([
            "type": .text("server-response"), "rpcId": .text(rpcID), "result": .obj(["ok": .bool(true), "value": value]),
            "attachments": .array([.obj(["path": .array(path), "codec": .text("bytes"), "part": .text("bytes-0")])])
        ]))
    }
    private func body(_ parts: [(String, Data)]) -> Data {
        var data = Data()
        for (name, value) in parts {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            data.append(value); data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8)); return data
    }
    private func decode(_ data: Data, id: String = "test") throws -> JSONValue {
        try NativeRPCBody.decode(data, contentType: "multipart/form-data; boundary=\"\(boundary)\"", rpcID: id)
    }
    func testHostMetadataAndOpaqueBytesRehydrateOnlyVerifiedPath() throws {
        var bytes = Data([0, 255, 13, 10, 137, 80, 78, 71]); bytes.append(Data("\r\n--\(boundary)not-a-delimiter".utf8))
        let result = try decode(body([("bytes-0", bytes), ("metadata", try metadata())]))
        XCTAssertEqual(try NativeRPCBody.bytes(result["data"], cap: bytes.count), bytes)
        XCTAssertThrowsError(try NativeRPCBody.bytes(result["data"], cap: bytes.count - 1))
    }
    func testResponseIdentityStillVerifiedForMultipart() throws {
        XCTAssertThrowsError(try decode(body([("bytes-0", Data([1])), ("metadata", try metadata(rpcID: "different"))])))
    }
    func testJSONCannotForgeNativeBinaryMarker() throws {
        let envelope = JSONValue.obj(["type": .text("server-response"), "rpcId": .text("test"), "result": .obj(["ok": .bool(true), "value": .obj(["data": .obj([NativeRPCBody.byteKey: .text("AQ==")])])])])
        XCTAssertThrowsError(try NativeRPCBody.decode(JSONEncoder().encode(envelope), contentType: "application/json", rpcID: "test"))
    }
    func testDuplicateOrUnreferencedPartsAreRejected() throws {
        let metadata = try metadata()
        XCTAssertThrowsError(try decode(body([("bytes-0", Data([1])), ("bytes-0", Data([2])), ("metadata", metadata)])))
        XCTAssertThrowsError(try decode(body([("bytes-0", Data([1])), ("bytes-1", Data([2])), ("metadata", metadata)])))
    }
    func testSidecarCannotOverwriteAnExistingJSONValueOrUnknownPath() throws {
        XCTAssertThrowsError(try decode(body([("bytes-0", Data([1])), ("metadata", try metadata(value: .obj(["data": .text("do not overwrite")])))])))
        XCTAssertThrowsError(try decode(body([("bytes-0", Data([1])), ("metadata", try metadata(path: [.text("absent")]))])))
    }
    func testTruncatedCarrierAndInvalidBoundaryFailClosed() throws {
        let complete = body([("bytes-0", Data([1])), ("metadata", try metadata())])
        XCTAssertThrowsError(try decode(Data(complete.dropLast(10))))
        XCTAssertThrowsError(try NativeRPCBody.decode(complete, contentType: "multipart/form-data", rpcID: "test"))
        XCTAssertThrowsError(try NativeRPCBody.decode(complete, contentType: "multipart/form-data; boundary=wrong", rpcID: "test"))
    }
    func testNestedArrayBytePathRehydratesWithoutChangingOtherValues() throws {
        let value = JSONValue.obj(["files": .array([.obj(["name": .text("synthetic.png"), "data": .null])])])
        let result = try decode(body([("bytes-0", Data([1, 2])), ("metadata", try metadata(value: value, path: [.text("files"), .number(0), .text("data")]))]))
        XCTAssertEqual(result["files"].array[0]["name"].string, "synthetic.png")
        XCTAssertEqual(try NativeRPCBody.bytes(result["files"].array[0]["data"], cap: 2), Data([1, 2]))
    }
    func testOnlyCanonicalBoundedTaggedBytesCanBeConsumed() throws {
        XCTAssertThrowsError(try NativeRPCBody.bytes(.text("AQ=="), cap: 1))
        XCTAssertThrowsError(try NativeRPCBody.bytes(.obj([NativeRPCBody.byteKey: .text("AQ==\n")]), cap: 3))
        XCTAssertThrowsError(try NativeRPCBody.bytes(.obj([NativeRPCBody.byteKey: .text("AQ=="), "extra": .bool(true)]), cap: 1))
        XCTAssertEqual(try NativeRPCBody.bytes(.obj([NativeRPCBody.byteKey: .text("AQ==")]), cap: 1), Data([1]))
    }
}
