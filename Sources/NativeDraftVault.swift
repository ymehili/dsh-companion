import Foundation
import CryptoKit
import Darwin

struct NativeDraftPhoto: Codable, Equatable, Sendable {
    let id: UUID
    let data: Data
}

/// An immutable retry DTO: never derive mode or image bytes from current UI state.
struct NativePendingDraft: Codable, Equatable, Sendable {
    let requestID: String
    let text: String
    let images: [Data]
    let mode: String
    let clientTimeZone: String?
    init(requestID: String, text: String, images: [Data], mode: String, clientTimeZone: String? = nil) {
        self.requestID = requestID; self.text = text; self.images = images; self.mode = mode; self.clientTimeZone = clientTimeZone
    }
}

struct NativeDraftRecord: Codable, Equatable, Sendable {
    let origin: String
    let sessionId: String
    let workspace: String?
    let title: String?
    let unsent: Bool
    let text: String
    /// User draft JPEG bytes, not provider upload identifiers.
    let photos: [NativeDraftPhoto]
    let pending: NativePendingDraft?
    let updatedAt: Date
}

struct NativeDraftVaultSnapshot: Equatable, Sendable {
    let records: [String: NativeDraftRecord]
    /// Includes deletion tombstones; callers must restore these before allocating revisions.
    let revisions: [String: UInt64]
    let issues: [String]
}

protocol NativeDraftPersisting: Sendable {
    func load() async -> NativeDraftVaultSnapshot
    /// False means stale (including an equal revision); other failures throw visibly.
    func save(record: NativeDraftRecord, revision: UInt64) async throws -> Bool
    func remove(sessionId: String, revision: UInt64) async throws -> Bool
}

struct NativeDraftVaultLimits: Sendable {
    var maxRecords = 256 // Includes tombstones: never evict revision history.
    var maxTotalBytes = 64 * 1024 * 1024
    var maxRecordBytes = 12 * 1024 * 1024 // Encoded envelope bytes, including base64 overhead.
    var maxImages = 16 // Combined draft + pending images.
    var maxImageBytes = 8 * 1024 * 1024
    var maxTextBytes = 1 * 1024 * 1024
    var maxIdentifierBytes = 4096
}

enum NativeDraftVaultError: Error, LocalizedError, Sendable {
    case invalid(String)
    case unsafePath(String)
    case damaged(String)
    case quota(String)
    case io(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let s): return "Invalid draft: \(s)"
        case .unsafePath(let s): return "Unsafe draft vault path: \(s)"
        case .damaged(let s): return "Draft preserved but unavailable: \(s)"
        case .quota(let s): return "Draft vault limit exceeded: \(s)"
        case .io(let s): return "Draft vault I/O failed: \(s)"
        }
    }
}

/// No filesystem work occurs in initialization. All I/O runs on this non-main actor.
/// A per-origin advisory lock also serializes independent vault actors/processes.
actor NativeDraftVault: NativeDraftPersisting {
    private struct Payload: Codable {
        let origin: String
        let sessionId: String
        let revision: UInt64
        let record: NativeDraftRecord? // nil is a durable tombstone
    }
    private struct Envelope: Codable {
        let schema: Int
        let checksum: String
        let payload: Data
    }
    private struct Scan {
        var records: [String: NativeDraftRecord] = [:]
        var revisions: [String: UInt64] = [:]
        var issues: [String] = []
        var blocked: Set<String> = []
        var sizes: [String: Int] = [:]
    }
    private let rootFolderURL: URL
    private let origin: String
    private let limits: NativeDraftVaultLimits
    private var folder: URL {
        // Resolve trusted parent aliases (e.g. iOS /var -> /private/var) lazily,
        // but retain the root leaf so prepare still rejects a symlink root.
        rootFolderURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(rootFolderURL.lastPathComponent, isDirectory: true)
            .appendingPathComponent(Self.hash(Data(origin.utf8)), isDirectory: true)
    }

    init(rootFolderURL: URL, origin: String, limits: NativeDraftVaultLimits = .init()) throws {
        guard rootFolderURL.isFileURL, rootFolderURL.path.hasPrefix("/"), rootFolderURL.pathComponents.count > 1,
              rootFolderURL.host == nil || rootFolderURL.host == "" || rootFolderURL.host == "localhost",
              rootFolderURL.query == nil, rootFolderURL.fragment == nil,
              !rootFolderURL.pathComponents.contains(".."), !rootFolderURL.pathComponents.contains(".") else {
            throw NativeDraftVaultError.unsafePath("expected an absolute local directory")
        }
        try Self.validateLimits(limits)
        self.rootFolderURL = rootFolderURL
        self.origin = try Self.normalizedOrigin(origin)
        self.limits = limits
    }

    static func validateLimits(_ limits: NativeDraftVaultLimits) throws {
        guard limits.maxRecords > 0, limits.maxTotalBytes > 0, limits.maxRecordBytes > 0,
              limits.maxRecordBytes < Int.max, limits.maxImages >= 0, limits.maxImageBytes > 0,
              limits.maxTextBytes > 0, limits.maxIdentifierBytes > 0 else {
            throw NativeDraftVaultError.invalid("invalid limits")
        }
    }

    /// Resolves the conventional location only; does not read or create it.
    static func applicationSupport(origin: String, limits: NativeDraftVaultLimits = .init()) throws -> NativeDraftVault {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NativeDraftVaultError.io("Application Support unavailable")
        }
        return try NativeDraftVault(rootFolderURL: base.appendingPathComponent("NativeDraftVault", isDirectory: true), origin: origin, limits: limits)
    }

    static func normalizedOrigin(_ value: String) throws -> String {
        guard let c = URLComponents(string: value), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", let rawHost = c.host, !rawHost.isEmpty,
              rawHost.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }),
              !rawHost.hasPrefix("."), !rawHost.hasSuffix("."), !rawHost.contains(".."),
              c.port == nil || (1...65535).contains(c.port!) else {
            throw NativeDraftVaultError.invalid("origin must be a credential-free HTTPS host origin")
        }
        let host = rawHost.lowercased()
        guard host.split(separator: ".").allSatisfy({ $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }), host.count <= 253 else {
            throw NativeDraftVaultError.invalid("invalid origin host")
        }
        return "https://" + host + (c.port == nil || c.port == 443 ? "" : ":\(c.port!)")
    }

    func load() async -> NativeDraftVaultSnapshot {
        do {
            guard try prepare(create: false) else { return .init(records: [:], revisions: [:], issues: []) }
            let lock = try acquireLock()
            defer { flock(lock, LOCK_UN); close(lock) }
            let state = try scan()
            return .init(records: state.records, revisions: state.revisions, issues: state.issues)
        } catch { return .init(records: [:], revisions: [:], issues: [error.localizedDescription]) }
    }

    func save(record: NativeDraftRecord, revision: UInt64) async throws -> Bool {
        try validate(record)
        return try persist(sessionId: record.sessionId, record: record, revision: revision)
    }

    func remove(sessionId: String, revision: UInt64) async throws -> Bool {
        try validateIdentifier(sessionId)
        return try persist(sessionId: sessionId, record: nil, revision: revision)
    }

    private func persist(sessionId: String, record: NativeDraftRecord?, revision: UInt64) throws -> Bool {
        _ = try prepare(create: true)
        let lock = try acquireLock()
        defer { flock(lock, LOCK_UN); close(lock) }
        let state = try scan()
        let name = filename(sessionId)
        guard !state.blocked.contains(name) else { throw NativeDraftVaultError.damaged(name) }
        guard revision > (state.revisions[sessionId] ?? 0) else { return false }
        let payload = try JSONEncoder().encode(Payload(origin: origin, sessionId: sessionId, revision: revision, record: record))
        let data = try JSONEncoder().encode(Envelope(schema: 1, checksum: Self.hash(payload), payload: payload))
        guard data.count <= limits.maxRecordBytes else { throw NativeDraftVaultError.quota("record bytes") }
        guard state.sizes[name] != nil || state.sizes.count < limits.maxRecords else { throw NativeDraftVaultError.quota("records including tombstones") }
        let otherBytes = state.sizes.filter { $0.key != name }.values.reduce(0) { partial, next in
            partial > limits.maxTotalBytes - min(next, limits.maxTotalBytes) ? limits.maxTotalBytes : partial + next
        }
        guard data.count <= limits.maxTotalBytes, otherBytes <= limits.maxTotalBytes - data.count else { throw NativeDraftVaultError.quota("total bytes") }
        let target = folder.appendingPathComponent(name)
        try assertSafe(target, directory: false, allowMissing: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: target, options: options)
        try protect(target)
        try synchronize(target, directory: false)
        try synchronize(folder, directory: true)
        return true
    }

    private func filename(_ sid: String) -> String { Self.hash(Data(sid.utf8)) + ".draft" }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= limits.maxIdentifierBytes, !value.contains("\0") else { throw NativeDraftVaultError.invalid("identifier") }
    }

    private func validate(_ r: NativeDraftRecord) throws {
        try Self.validateRecord(r, origin: origin, limits: limits)
    }

    static func validateRecord(_ r: NativeDraftRecord, origin: String, limits: NativeDraftVaultLimits) throws {
        func validateIdentifier(_ value: String) throws {
            guard !value.isEmpty, value.utf8.count <= limits.maxIdentifierBytes, !value.contains("\0") else { throw NativeDraftVaultError.invalid("identifier") }
        }
        guard r.origin == origin else { throw NativeDraftVaultError.invalid("record origin differs from vault") }
        try validateIdentifier(r.sessionId)
        guard r.updatedAt.timeIntervalSince1970.isFinite else { throw NativeDraftVaultError.invalid("date") }
        for text in [r.text, r.title ?? "", r.workspace ?? "", r.pending?.text ?? ""] {
            guard text.utf8.count <= limits.maxTextBytes else { throw NativeDraftVaultError.quota("text bytes") }
        }
        let images = r.photos.map(\.data) + (r.pending?.images ?? [])
        guard images.count <= limits.maxImages else { throw NativeDraftVaultError.quota("image count") }
        guard images.allSatisfy({ $0.count <= limits.maxImageBytes }) else { throw NativeDraftVaultError.quota("image bytes") }
        if let pending = r.pending {
            try validateIdentifier(pending.requestID)
            guard pending.mode == "queue" || pending.mode == "steer" else { throw NativeDraftVaultError.invalid("pending mode") }
        }
    }

    /// Logical quarantine: preserve every suspect byte in place and block that target.
    private func scan() throws -> Scan {
        var state = Scan()
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in entries {
            let name = entry.lastPathComponent
            if name == ".lock" { continue } // Validated and held by acquireLock.
            do {
                try assertSafe(entry, directory: false, allowMissing: false)
                let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
                let size = (attributes[.size] as? NSNumber)?.intValue ?? limits.maxTotalBytes
                state.sizes[name] = size
                guard name.count == 70, name.hasSuffix(".draft"), name.dropLast(6).allSatisfy({ "0123456789abcdef".contains($0) }) else { throw NativeDraftVaultError.damaged("unexpected file \(name)") }
                guard size <= limits.maxRecordBytes else { throw NativeDraftVaultError.quota("oversized stored record \(name)") }
                let fd = open(entry.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw NativeDraftVaultError.io("cannot safely read \(name)") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: limits.maxRecordBytes + 1) ?? Data()
                guard data.count <= limits.maxRecordBytes else { throw NativeDraftVaultError.quota("stored record bytes") }
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.schema == 1, envelope.checksum == Self.hash(envelope.payload) else { throw NativeDraftVaultError.damaged("schema/checksum \(name)") }
                let payload = try JSONDecoder().decode(Payload.self, from: envelope.payload)
                guard payload.origin == origin, filename(payload.sessionId) == name, payload.revision > 0 else { throw NativeDraftVaultError.damaged("scope/revision \(name)") }
                try validateIdentifier(payload.sessionId)
                if let record = payload.record {
                    guard record.sessionId == payload.sessionId else { throw NativeDraftVaultError.damaged("session mismatch \(name)") }
                    try validate(record)
                    state.records[payload.sessionId] = record
                }
                state.revisions[payload.sessionId] = payload.revision
            } catch {
                state.blocked.insert(name)
                // Unknown/symlink sizes must conservatively block new quota-consuming writes.
                if state.sizes[name] == nil { state.sizes[name] = limits.maxTotalBytes }
                state.issues.append("\(name): \(error.localizedDescription)")
            }
        }
        if state.sizes.count > limits.maxRecords { state.issues.append("Draft vault exceeds record limit; no records were evicted.") }
        if state.sizes.values.reduce(0.0, { $0 + Double($1) }) > Double(limits.maxTotalBytes) { state.issues.append("Draft vault exceeds byte limit; no records were evicted.") }
        return state
    }

    private func prepare(create: Bool) throws -> Bool {
        // Check every existing ancestor, not just the leaf. No symlink traversal.
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        let components = Array(folder.pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            path.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(path.path, &info) == 0 {
                // iOS Foundation may canonicalize /private/var back to /var.
                // Permit ONLY the verified root-owned system alias, and ONLY
                // above the vault root + host directory (never at either leaf).
                if index < components.count - 2, Self.isTrustedSystemVarAlias(path) { continue }
                try assertSafe(path, directory: true, allowMissing: false)
            } else if errno == ENOENT {
                if !create { return false }
                do { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
                catch { try assertSafe(path, directory: true, allowMissing: false) } // Another vault may have created it.
                try assertSafe(path, directory: true, allowMissing: false)
                try protect(path)
            } else { throw NativeDraftVaultError.io("cannot inspect directory") }
        }
        if create { try protect(folder) }
        return true
    }

    static func isTrustedSystemVarAlias(_ url: URL) -> Bool {
        guard url.path == "/var" else { return false }
        var link = stat(), destination = stat()
        guard lstat("/var", &link) == 0, link.st_uid == 0,
              link.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else { return false }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = readlink("/var", &buffer, buffer.count - 1)
        guard length > 0, length < buffer.count else { return false }
        buffer[length] = 0
        let target = String(cString: buffer)
        guard target == "/private/var" || target == "private/var",
              lstat("/private/var", &destination) == 0, destination.st_uid == 0,
              destination.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return false }
        return true
    }

    private func assertSafe(_ url: URL, directory: Bool, allowMissing: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if allowMissing && errno == ENOENT { return }
            throw NativeDraftVaultError.unsafePath("cannot inspect \(url.lastPathComponent)")
        }
        let kind = info.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(directory ? S_IFDIR : S_IFREG) else { throw NativeDraftVaultError.unsafePath("non-\(directory ? "directory" : "regular file") \(url.lastPathComponent)") }
        if !directory && info.st_nlink != 1 { throw NativeDraftVaultError.unsafePath("hard-linked record") }
    }

    private func acquireLock() throws -> Int32 {
        let url = folder.appendingPathComponent(".lock")
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw NativeDraftVaultError.unsafePath("lock file") }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
                throw NativeDraftVaultError.unsafePath("nonregular lock")
            }
            guard flock(fd, LOCK_EX) == 0 else { throw NativeDraftVaultError.io("lock acquisition") }
            try protect(url)
            return fd
        } catch { close(fd); throw error }
    }

    private func synchronize(_ url: URL, directory: Bool) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw NativeDraftVaultError.io("cannot sync vault entry") }
        defer { close(fd) }
        var result: Int32
        repeat { result = fsync(fd) } while result != 0 && errno == EINTR
        guard result == 0 else { throw NativeDraftVaultError.io("cannot sync vault entry") }
    }

    private func protect(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
