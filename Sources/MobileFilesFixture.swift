import Foundation
import UIKit

/// Entirely generated, never reads the host filesystem or user's photo library.
@MainActor
final class MobileFilesFixtureTransport: NativeTransport {
    var credential: String?
    var onFrame: ((JSONValue) -> Void)?
    var onDisconnect: (() -> Void)?
    static let root = "/synthetic/Files"
    static let codec = MobileFileByteCodec { value, cap in
        guard case .array(let values) = value["fixtureBytes"] else { throw MobileFileFailure.malformed }
        return try MobileFileByteCodec.checkedBytes(values, cap: cap)
    }
    private let sources: [String: String] = [
        "README.md": "# Native Files\n\nSynthetic workspace — no real files are copied.\n\nBrowse Sources, select text, or preview the generated image and PDF.\nFiles are read-only: the host has no structured edit/write API.",
        "Sources/Welcome.swift": (1...370).map { "// Synthetic source line \($0)\nlet sample\($0) = \($0)" }.joined(separator: "\n"),
        "Limited/example.txt": "This listing demonstrates an explicitly truncated folder.",
        "Unavailable.txt": ""
    ]
    private lazy var binaries: [String: Data] = {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).image { ctx in
            UIColor(red: 0.25, green: 0.46, blue: 0.9, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            ("Synthetic Files preview" as NSString).draw(at: CGPoint(x: 50, y: 175), withAttributes: [.font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.white])
        }.pngData() ?? Data()
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 520)).pdfData { context in
            context.beginPage()
            ("Synthetic PDF\n\nAuthorized byte preview fixture." as NSString).draw(in: CGRect(x: 30, y: 50, width: 340, height: 400), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
        return ["Preview.png": image, "Guide.pdf": pdf]
    }()
    func openStream() {}
    func closeStream() {}
    func sendFrame(_ value: JSONValue) async throws { throw MobileFileFailure.malformed }
    func rpc(_ endpoint: String, _ payload: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        let args = payload["args"]
        let path = args["path"].string == "." ? "" : (args["path"].string ?? "")
        if endpoint == "workspaceFiles/list" {
            let folders: [String: [(String, String)]] = [
                "": [("Sources", "directory"), ("Empty", "directory"), ("Limited", "directory"), ("README.md", "file"), ("Preview.png", "file"), ("Guide.pdf", "file"), ("Unavailable.txt", "file"), ("Unsupported link", "other")],
                "Sources": [("Welcome.swift", "file")], "Empty": [], "Limited": [("example.txt", "file")]
            ]
            guard let children = folders[path] else { throw MobileFileFailure(message: "Synthetic folder not found.") }
            return .obj(["path": .text(path), "entries": .array(children.map { .obj(["name": .text($0.0), "type": .text($0.1)]) }), "truncated": .bool(path == "Limited")])
        }
        if path == "Unavailable.txt" { throw MobileFileFailure(message: "Synthetic permission error. This file is intentionally unavailable.") }
        let bytes = sources[path].map { Data($0.utf8) } ?? binaries[path]
        guard let bytes else { throw MobileFileFailure(message: "Synthetic file not found.") }
        var result: [String: JSONValue] = ["absolutePath": .text(Self.root + "/" + path), "version": .text("synthetic-v1"), "bytes": .number(Double(bytes.count))]
        switch endpoint {
        case "workspaceFiles/stat": break
        case "workspaceFiles/read":
            guard let source = sources[path], let offset = args["range"]["offset"].integer, let limit = args["range"]["limit"].integer else { throw MobileFileFailure.malformed }
            let lines = source.components(separatedBy: "\n")
            let page = Array(lines.dropFirst(offset - 1).prefix(limit))
            result["offset"] = .number(Double(offset)); result["text"] = .text(page.joined(separator: "\n"))
            result["lines"] = .number(Double(page.count)); result["eof"] = .bool(offset - 1 + page.count >= lines.count)
        case "workspaceFiles/readBytes":
            guard let offset = args["options"]["range"]["offset"].integer, let length = args["options"]["range"]["length"].integer else { throw MobileFileFailure.malformed }
            let chunk = bytes.dropFirst(offset).prefix(length)
            result["offset"] = .number(Double(offset)); result["eof"] = .bool(offset + chunk.count >= bytes.count)
            result["fixtureBytes"] = .array(chunk.map { .number(Double($0)) })
        default: throw MobileFileFailure.malformed
        }
        return .obj(result)
    }
}
