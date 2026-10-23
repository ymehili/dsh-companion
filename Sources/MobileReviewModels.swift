import Foundation

struct MobileReviewRecord: Identifiable, Equatable, Hashable {
    let sessionId: String
    let seq: Int
    let turn: Int
    var id: Int { seq }
    static func loaded(sessionId: String, selectedId: String?, events: [Int: JSONValue]) -> [Self] {
        guard selectedId == sessionId else { return [] }
        return events.compactMap { key, event in
            guard event["type"].string == "workspace/changes", let seq = event["seq"].integer, seq == key, seq >= 0,
                  let turn = event["data"]["turn"].integer, turn >= 0 else { return nil }
            return Self(sessionId: sessionId, seq: seq, turn: turn)
        }.sorted { $0.seq > $1.seq }
    }
}

enum MobileReviewFailure: String, LocalizedError {
    case invalid = "The Mac returned an invalid or over-limit change recording."
    case boundary = "This change does not belong to the selected recording."
    case unavailable = "This recording is unavailable. Host turn recordings are ephemeral, not durable Git checkpoints."
    var errorDescription: String? { rawValue }
}

struct MobileReviewFile: Identifiable, Equatable {
    let index: Int
    let path: String
    let display: String
    let added: Int
    let deleted: Int
    let binary: Bool
    let oversized: Bool
    var id: Int { index }
}

struct MobileReviewSummary {
    let record: MobileReviewRecord
    let files: [MobileReviewFile]
    let total: Int
    let added: Int
    let deleted: Int
    var partial: Bool { total > files.count }
    init(_ value: JSONValue, record: MobileReviewRecord) throws {
        guard value["turn"].integer == record.turn, case .array(let rawFiles) = value["files"], rawFiles.count <= 500 else { throw MobileReviewFailure.invalid }
        total = try MobileReviewValidation.count(value["total"])
        added = try MobileReviewValidation.count(value["added"])
        deleted = try MobileReviewValidation.count(value["deleted"])
        guard total >= rawFiles.count else { throw MobileReviewFailure.invalid }
        var paths = Set<String>()
        files = try rawFiles.enumerated().map { index, raw in
            let path = try MobileReviewValidation.path(raw["path"])
            guard paths.insert(path).inserted else { throw MobileReviewFailure.invalid }
            for flag in ["binary", "oversized"] { guard raw[flag] == .null || raw[flag] == .bool(true) else { throw MobileReviewFailure.invalid } }
            return MobileReviewFile(index: index, path: path, display: try MobileReviewValidation.label(raw["display"]), added: try MobileReviewValidation.count(raw["added"]), deleted: try MobileReviewValidation.count(raw["deleted"]), binary: raw["binary"].bool == true, oversized: raw["oversized"].bool == true)
        }
        self.record = record
    }
}

enum MobileReviewValidation {
    static func count(_ value: JSONValue) throws -> Int {
        guard let n = value.integer, n >= 0, n <= 10_000_000 else { throw MobileReviewFailure.invalid }; return n
    }
    static func label(_ value: JSONValue) throws -> String {
        guard let s = value.string, !s.isEmpty, s.utf8.count <= 4096, !s.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw MobileReviewFailure.invalid }; return s
    }
    static func path(_ value: JSONValue) throws -> String {
        // Recorded paths may be absolute or outside cwd. They are labels, never file/URL authority.
        try label(value)
    }
}

struct MobileReviewLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let old: Int?
    let new: Int?
    var side: String { new == nil ? "old" : "new" }
    var number: Int? { new ?? old }
    var prefix: Character? { text.first }
}
struct MobileReviewHunk: Identifiable {
    let id: Int
    let title: String
    let lines: [MobileReviewLine]
}
struct MobileReviewDiff {
    let kind: String
    let coarse: Bool
    let hunks: [MobileReviewHunk]
    init(_ value: JSONValue, file: MobileReviewFile) throws {
        guard value["path"].string == file.path, value["display"].string == file.display else { throw MobileReviewFailure.boundary }
        guard let kind = value["kind"].string, ["text", "binary", "oversized"].contains(kind) else { throw MobileReviewFailure.invalid }
        self.kind = kind
        if kind != "text" { coarse = false; hunks = []; return }
        guard !file.binary, !file.oversized, value["before"].bool != nil, value["after"].bool != nil,
              let coarse = value["coarse"].bool, case .array(let rawHunks) = value["hunks"], rawHunks.count <= 1000 else { throw MobileReviewFailure.invalid }
        self.coarse = coarse
        var lineCount = 0, bytes = 0
        hunks = try rawHunks.enumerated().map { index, h in
            let os = try MobileReviewValidation.count(h["oldStart"]), ns = try MobileReviewValidation.count(h["newStart"])
            let ol = try MobileReviewValidation.count(h["oldLines"]), nl = try MobileReviewValidation.count(h["newLines"])
            guard (ol == 0 || os > 0), (nl == 0 || ns > 0), case .array(let rawLines) = h["lines"], rawLines.count <= 20_000 else { throw MobileReviewFailure.invalid }
            var old = os, new = ns, oldCount = 0, newCount = 0
            let lines = try rawLines.map { raw -> MobileReviewLine in
                guard let text = raw.string, let prefix = text.first, [" ", "+", "-", "\\"].contains(prefix), !text.contains("\n"), !text.contains("\r"), text.utf8.count <= 32_768 else { throw MobileReviewFailure.invalid }
                if prefix == "\\" && text != "\\ No newline at end of file" { throw MobileReviewFailure.invalid }
                bytes += text.utf8.count; lineCount += 1
                guard bytes <= 2_000_000, lineCount <= 20_000 else { throw MobileReviewFailure.invalid }
                let row = MobileReviewLine(id: lineCount, text: text, old: prefix == " " || prefix == "-" ? old : nil, new: prefix == " " || prefix == "+" ? new : nil)
                if row.old != nil { old += 1; oldCount += 1 }
                if row.new != nil { new += 1; newCount += 1 }
                return row
            }
            guard oldCount == ol, newCount == nl else { throw MobileReviewFailure.invalid }
            return MobileReviewHunk(id: index, title: "@@ -\(os),\(ol) +\(ns),\(nl) @@", lines: lines)
        }
    }
}

@MainActor final class MobileReviewService {
    let sessionId: String
    let transport: any NativeTransport
    init(sessionId: String, transport: any NativeTransport) { self.sessionId = sessionId; self.transport = transport }
    private func query(_ record: MobileReviewRecord) throws -> [String: String] {
        guard record.sessionId == sessionId, !sessionId.isEmpty, sessionId.utf8.count <= 256, record.seq >= 0, record.seq <= 9_007_199_254_740_991, record.turn >= 0, record.turn <= 9_007_199_254_740_991 else { throw MobileReviewFailure.boundary }
        return ["sessionId": sessionId, "seq": String(record.seq)]
    }
    func summary(_ record: MobileReviewRecord) async throws -> MobileReviewSummary {
        let q = try query(record)
        return try MobileReviewSummary(await transport.resource("/api/changes.summary", query: q), record: record)
    }
    func diff(_ file: MobileReviewFile, summary: MobileReviewSummary) async throws -> MobileReviewDiff {
        var q = try query(summary.record)
        guard summary.files.indices.contains(file.index), summary.files[file.index] == file else { throw MobileReviewFailure.boundary }
        q["index"] = String(file.index)
        return try MobileReviewDiff(await transport.resource("/api/changes.diff", query: q), file: file)
    }
}

struct MobileReviewTarget: Identifiable, Equatable {
    let id: UUID
    let record: MobileReviewRecord
    let path: String
    let side: String
    let start: Int
    let end: Int
    init(record: MobileReviewRecord, path: String, side: String, start: Int, end: Int) throws {
        guard !record.sessionId.isEmpty, record.seq >= 0, record.seq <= 9_007_199_254_740_991, record.turn >= 0, record.turn <= 9_007_199_254_740_991, ["old", "new"].contains(side), start > 0, end > 0, max(start, end) <= 10_000_000 else { throw MobileReviewFailure.invalid }
        self.path = try MobileReviewValidation.path(.text(path)); self.record = record; self.side = side
        self.start = min(start, end); self.end = max(start, end); id = UUID()
    }
    var label: String { start == end ? "L\(start)" : "L\(start)–L\(end)" }
    func xml(comment: String) throws -> String {
        guard !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, comment.utf8.count <= 16_384,
              !comment.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 0xFFFE || $0.value == 0xFFFF }) else { throw MobileReviewFailure.invalid }
        return "<review_comment session_id=\"\(Self.escape(record.sessionId))\" seq=\"\(record.seq)\" turn=\"\(record.turn)\" path=\"\(Self.escape(path))\" side=\"\(side)\" line_start=\"\(start)\" line_end=\"\(end)\">\n\(Self.escape(comment))\n</review_comment>"
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
}
