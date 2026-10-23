import Foundation

/// The current Mac client-connection HTTP carrier uses multipart/form-data for
/// Typert binary results (metadata + bytes-N parts), not JSON Uint8Array/base64.
/// Only validated sidecars are rehydrated into this native-only tagged value.
enum NativeRPCBody {
    static let byteKey = "$dshNativeBytes"
    static let maximumBytes = 24 * 1024 * 1024
    static func decode(_ data: Data, contentType: String, rpcID: String) throws -> JSONValue {
        guard data.count <= maximumBytes else { throw failure("The Mac response exceeds the native transport limit.") }
        if !contentType.lowercased().hasPrefix("multipart/form-data") {
            let envelope = try JSONDecoder().decode(JSONValue.self, from: data)
            let value = try Wire.response(envelope, id: rpcID)
            guard !containsTag(value) else { throw failure("Unexpected binary tag in a JSON response.") }
            return value
        }
        let pattern = #"(?:^|;)\s*boundary=(?:"([^"]+)"|([^;\s]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)) else { throw failure("Missing binary response boundary.") }
        let group = match.range(at: 1).location == NSNotFound ? 2 : 1
        guard let range = Range(match.range(at: group), in: contentType) else { throw failure("Invalid binary response boundary.") }
        let boundary = String(contentType[range])
        guard (1...70).contains(boundary.utf8.count), boundary.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "'()+_,-./:=?".unicodeScalars.contains($0) }) else { throw failure("Invalid binary response boundary.") }
        let parts = try parse(data, boundary: boundary)
        guard let metadata = parts["metadata"], metadata.count <= 1024 * 1024 else { throw failure("Missing binary metadata.") }
        let envelope = try JSONDecoder().decode(JSONValue.self, from: metadata)
        var value = try Wire.response(envelope, id: rpcID)
        guard !containsTag(value), case .array(let attachments) = envelope["attachments"], !attachments.isEmpty, attachments.count <= 16 else { throw failure("Invalid binary attachment metadata.") }
        var used: Set<String> = ["metadata"]
        for attachment in attachments {
            guard attachment["codec"].string == "bytes", let part = attachment["part"].string,
                  part.hasPrefix("bytes-"), used.insert(part).inserted, let bytes = parts[part],
                  case .array(let path) = attachment["path"], path.count <= 32 else { throw failure("Invalid binary attachment reference.") }
            value = try insert(.obj([byteKey: .text(bytes.base64EncodedString())]), at: path[...], into: value)
        }
        guard used == Set(parts.keys) else { throw failure("Unreferenced binary response parts.") }
        return value
    }
    static func bytes(_ tagged: JSONValue, cap: Int) throws -> Data {
        guard cap >= 0, tagged.object?.count == 1, let text = tagged[byteKey].string,
              text.utf8.count <= ((cap + 2) / 3) * 4,
              let bytes = Data(base64Encoded: text), bytes.count <= cap, bytes.base64EncodedString() == text else { throw failure("Invalid authorized binary result.") }
        return bytes
    }
    private static func insert(_ bytes: JSONValue, at path: ArraySlice<JSONValue>, into value: JSONValue) throws -> JSONValue {
        guard let head = path.first else {
            guard value == .null else { throw failure("Binary result does not refer to a null placeholder.") }
            return bytes
        }
        if let key = head.string, case .object(var fields) = value, let child = fields[key] {
            fields[key] = try insert(bytes, at: path.dropFirst(), into: child); return .obj(fields)
        }
        if case .number(let n) = head, n.isFinite, n.rounded() == n, n >= 0, n < Double(Int.max), case .array(var items) = value, items.indices.contains(Int(n)) {
            items[Int(n)] = try insert(bytes, at: path.dropFirst(), into: items[Int(n)]); return .array(items)
        }
        throw failure("Binary result path does not exist.")
    }
    private static func containsTag(_ value: JSONValue, depth: Int = 0) -> Bool {
        guard depth < 64 else { return true }
        switch value {
        case .object(let fields): return fields[byteKey] != nil || fields.values.contains { containsTag($0, depth: depth + 1) }
        case .array(let items): return items.contains { containsTag($0, depth: depth + 1) }
        default: return false
        }
    }
    private static func parse(_ data: Data, boundary: String) throws -> [String: Data] {
        let initial = Data("--\(boundary)\r\n".utf8), delimiter = Data("\r\n--\(boundary)".utf8), separator = Data("\r\n\r\n".utf8)
        guard data.starts(with: initial) else { throw failure("Invalid binary response framing.") }
        var cursor = initial.count, parts: [String: Data] = [:]
        while true {
            guard parts.count < 17, let headerEnd = data.range(of: separator, in: cursor..<data.count), headerEnd.lowerBound - cursor <= 8192,
                  let headers = String(data: data.subdata(in: cursor..<headerEnd.lowerBound), encoding: .utf8) else { throw failure("Invalid binary part headers.") }
            var disposition: String?
            for line in headers.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { throw failure("Invalid binary part header.") }
                let name = line[..<colon].lowercased()
                if name == "content-disposition" {
                    guard disposition == nil else { throw failure("Duplicate binary disposition.") }
                    disposition = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
                if name == "content-transfer-encoding" { throw failure("Unsupported binary transfer encoding.") }
            }
            guard let disposition, disposition.lowercased().hasPrefix("form-data"),
                  let regex = try? NSRegularExpression(pattern: #"(?:^|;)\s*name="([^"]+)""#),
                  let match = regex.firstMatch(in: disposition, range: NSRange(disposition.startIndex..., in: disposition)),
                  let nameRange = Range(match.range(at: 1), in: disposition) else { throw failure("Missing binary part name.") }
            let name = String(disposition[nameRange])
            guard name == "metadata" || name.hasPrefix("bytes-"), parts[name] == nil else { throw failure("Unexpected or duplicate binary part.") }
            let start = headerEnd.upperBound
            var search = start, found: Range<Data.Index>?
            while let candidate = data.range(of: delimiter, in: search..<data.count) {
                let end = candidate.upperBound
                if end + 2 <= data.count {
                    let suffix = data.subdata(in: end..<(end + 2))
                    if suffix == Data("--".utf8) || suffix == Data("\r\n".utf8) { found = candidate; break }
                }
                search = candidate.upperBound
            }
            guard let found else { throw failure("Truncated binary response.") }
            parts[name] = data.subdata(in: start..<found.lowerBound)
            let end = found.upperBound, suffix = data.subdata(in: end..<(end + 2))
            if suffix == Data("--".utf8) {
                let rest = data.subdata(in: (end + 2)..<data.count)
                guard rest.isEmpty || rest == Data("\r\n".utf8) else { throw failure("Unexpected binary epilogue.") }
                return parts
            }
            cursor = end + 2
        }
    }
    private static func failure(_ message: String) -> NativeRPCError { NativeRPCError(message: message) }
}
