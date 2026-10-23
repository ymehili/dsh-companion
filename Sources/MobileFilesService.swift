import Foundation

struct MobileFileFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
    static let malformed = Self(message: "The Mac returned an incompatible file response.")
    static let boundary = Self(message: "This path could not be verified inside the selected workspace.")
    static let changed = Self(message: "The file changed while reading. Reload it to continue.")
}

/// No caller-entered path is used as read authority. Paths must descend from a
/// validated list chain; stat and every page must match the selected source.
enum MobileFilePath {
    static func name(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
        !value.contains("/") && !value.contains("\\") && !value.contains("\0") && !value.contains(":")
    }
    static func relative(_ value: String) -> Bool {
        value.isEmpty || value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { name(String($0)) }
    }
    static func root(_ value: String) -> String? {
        guard value.hasPrefix("/"), !value.contains("\0"), !value.contains("\\") else { return nil }
        if value == "/" { return value }
        let parts = value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ name(String($0)) }) else { return nil }
        return value
    }
    static func absolute(root: String, relative: String) -> String {
        root + (root == "/" ? "" : "/") + relative
    }
    static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
}

struct MobileFileEntry: Identifiable, Equatable, Hashable {
    enum Kind: String, Hashable { case file, directory, other }
    let path: String
    let name: String
    let kind: Kind
    let size: Int?
    var id: String { path }
    var previewable: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "mp3", "m4a", "wav", "aac", "mp4", "mov", "m4v"].contains((name as NSString).pathExtension.lowercased())
    }
}
struct MobileFileListing {
    let path: String
    let entries: [MobileFileEntry]
    let truncated: Bool
}
struct MobileFileIdentity: Equatable {
    let absolutePath: String
    let version: String
    let bytes: Int?
    init(_ value: JSONValue, expectedPath: String) throws {
        guard let path = value["absolutePath"].string, path == expectedPath else { throw MobileFileFailure.boundary }
        guard let version = value["version"].string, !version.isEmpty else { throw MobileFileFailure.malformed }
        if value.object?["bytes"] != nil {
            guard let size = value["bytes"].integer, size >= 0 else { throw MobileFileFailure.malformed }
            bytes = size
        } else { bytes = nil }
        absolutePath = path; self.version = version
    }
}
struct MobileFileTextPage {
    let offset: Int
    let text: String
    let lines: Int
    let eof: Bool
    var nextOffset: Int { offset + lines }
    var numberedLines: [(Int, String)] {
        guard lines > 0 else { return [] }
        return text.components(separatedBy: "\n").enumerated().map { (offset + $0.offset, $0.element) }
    }
}

/// NativeGateway validates the current Host multipart carrier and rehydrates
/// only metadata-referenced byte parts into NativeRPCBody's native-only tag.
/// Never reinterpret arbitrary JSON numbers/base64 as a Host Uint8Array.
struct MobileFileByteCodec {
    let decode: (JSONValue, Int) throws -> Data
    static let unavailable = Self { _, _ in
        throw MobileFileFailure(message: "This Mac connection does not yet preserve authorized binary attachments. Text files remain available; media needs the native binary transport adapter.")
    }
    static let nativeMultipart = Self { value, cap in try NativeRPCBody.bytes(value["data"], cap: cap) }
    static func checkedBytes(_ values: [JSONValue], cap: Int) throws -> Data {
        guard values.count <= cap else { throw MobileFileFailure.malformed }
        return try Data(values.map {
            guard let byte = $0.integer, (0...255).contains(byte) else { throw MobileFileFailure.malformed }
            return UInt8(byte)
        })
    }
}

@MainActor
final class MobileFilesService {
    static let lineLimit = 160
    static let textByteCap = 256 * 1024
    static let byteChunk = 256 * 1024
    static let mediaCap = 8 * 1024 * 1024
    let sessionId: String
    let workspaceRoot: String
    private let transport: any NativeTransport
    private let byteCodec: MobileFileByteCodec
    private var listings: [String: MobileFileListing] = [:]

    init(sessionId: String, workspaceRoot: String, transport: any NativeTransport, byteCodec: MobileFileByteCodec = .unavailable) throws {
        guard !sessionId.isEmpty, let root = MobileFilePath.root(workspaceRoot) else { throw MobileFileFailure.boundary }
        self.sessionId = sessionId; self.workspaceRoot = root; self.transport = transport; self.byteCodec = byteCodec
    }
    private func call(_ method: String, path: String, extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard MobileFilePath.relative(path) else { throw MobileFileFailure.boundary }
        // Current Host lookup wireTypeSymbol is SessionId: no synthesized prefix.
        var args = extra
        args["workspaceFileScopeId"] = .text(sessionId)
        args["path"] = .text(path.isEmpty ? "." : path)
        return try await transport.rpc("workspaceFiles/" + method, .obj(["args": .obj(args)]))
    }
    func list(_ path: String = "") async throws -> MobileFileListing {
        guard MobileFilePath.relative(path) else { throw MobileFileFailure.boundary }
        if !path.isEmpty {
            guard listings[MobileFilePath.parent(path)]?.entries.contains(where: { $0.path == path && $0.kind == .directory }) == true else { throw MobileFileFailure.boundary }
        }
        let value = try await call("list", path: path)
        guard value["path"].string == path, case .array(let children) = value["entries"], let truncated = value["truncated"].bool else { throw MobileFileFailure.boundary }
        var seen = Set<String>()
        let entries = try children.prefix(2000).map { child -> MobileFileEntry in
            guard let name = child["name"].string, MobileFilePath.name(name), seen.insert(name).inserted,
                  let raw = child["type"].string, let kind = MobileFileEntry.Kind(rawValue: raw) else { throw MobileFileFailure.malformed }
            let size = child["size"].integer
            if child.object?["size"] != nil && (size == nil || size! < 0) { throw MobileFileFailure.malformed }
            return MobileFileEntry(path: path.isEmpty ? name : path + "/" + name, name: name, kind: kind, size: size)
        }
        let listing = MobileFileListing(path: path, entries: entries.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }, truncated: truncated || children.count > 2000)
        listings[path] = listing
        // A refreshed parent revokes old descendants until traversed again.
        for key in Array(listings.keys) where !key.isEmpty && key != path && (path.isEmpty || key.hasPrefix(path + "/")) { listings.removeValue(forKey: key) }
        return listing
    }
    private func authorized(_ entry: MobileFileEntry) throws {
        guard entry.kind == .file, MobileFilePath.relative(entry.path),
              listings[MobileFilePath.parent(entry.path)]?.entries.contains(entry) == true else { throw MobileFileFailure.boundary }
    }
    func stat(_ entry: MobileFileEntry) async throws -> MobileFileIdentity {
        try authorized(entry)
        let value = try await call("stat", path: entry.path)
        return try MobileFileIdentity(value, expectedPath: MobileFilePath.absolute(root: workspaceRoot, relative: entry.path))
    }
    func text(_ entry: MobileFileEntry, offset: Int, identity: MobileFileIdentity) async throws -> MobileFileTextPage {
        try authorized(entry)
        guard offset >= 1, offset <= 100_000 else { throw MobileFileFailure(message: "The text preview line limit has been reached.") }
        let value = try await call("read", path: entry.path, extra: ["range": .obj(["offset": .number(Double(offset)), "limit": .number(Double(Self.lineLimit))])])
        try verify(value, identity: identity, entry: entry)
        guard value["offset"].integer == offset, let text = value["text"].string,
              text.utf8.count <= Self.textByteCap, !text.contains("\0"),
              let lines = value["lines"].integer, (0...Self.lineLimit).contains(lines),
              let eof = value["eof"].bool,
              (lines == 0 ? text.isEmpty && eof : text.components(separatedBy: "\n").count == lines),
              eof || lines > 0 else { throw MobileFileFailure.malformed }
        return MobileFileTextPage(offset: offset, text: text, lines: lines, eof: eof)
    }
    private func verify(_ value: JSONValue, identity: MobileFileIdentity, entry: MobileFileEntry) throws {
        let actual = try MobileFileIdentity(value, expectedPath: MobileFilePath.absolute(root: workspaceRoot, relative: entry.path))
        guard actual == identity else { throw MobileFileFailure.changed }
    }
    func media(_ entry: MobileFileEntry, identity: MobileFileIdentity) async throws -> Data {
        try authorized(entry)
        guard let size = identity.bytes, size > 0, size <= Self.mediaCap else {
            throw MobileFileFailure(message: "Native media preview requires a known file size of 1 byte to 8 MB.")
        }
        var data = Data()
        while data.count < size {
            try Task.checkCancellation()
            let length = min(Self.byteChunk, size - data.count)
            let value = try await call("readBytes", path: entry.path, extra: ["options": .obj(["range": .obj(["offset": .number(Double(data.count)), "length": .number(Double(length))])])])
            try verify(value, identity: identity, entry: entry)
            guard value["offset"].integer == data.count, let eof = value["eof"].bool else { throw MobileFileFailure.malformed }
            let chunk = try byteCodec.decode(value, length)
            guard chunk.count == length, eof == (data.count + length == size) else { throw MobileFileFailure.malformed }
            data.append(chunk)
        }
        return data
    }
}
