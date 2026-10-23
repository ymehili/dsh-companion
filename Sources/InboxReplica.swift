import Foundation

/// A last-good replica of the Mac's inbox lifecycle. Transport failures never
/// reset this state or invent shelf membership from session age.
struct InboxReplica {
    private(set) var epoch: String?
    private(set) var revision = -1
    private(set) var activated = false
    private(set) var threads: [String: JSONValue] = [:]
    var hasSnapshot: Bool { epoch != nil && revision >= 0 }

    @discardableResult
    mutating func apply(_ value: JSONValue) -> Bool {
        guard let epoch = value["epoch"].string, !epoch.isEmpty,
              let revision = value["revision"].integer, revision >= 0,
              let threads = value["threads"].object,
              let full = value["full"].bool else { return false }
        if full {
            if epoch == self.epoch && revision < self.revision { return false }
            guard let activated = value["settings"]["activated"].bool else { return false }
            self.epoch = epoch
            self.revision = revision
            self.activated = activated
            self.threads = threads
            return true
        }
        guard epoch == self.epoch, revision >= self.revision, hasSnapshot else { return false }
        self.revision = revision
        if let activated = value["settings"]["activated"].bool { self.activated = activated }
        for (id, record) in threads { self.threads[id] = record }
        return true
    }
    var watchRequest: JSONValue? {
        guard let epoch, hasSnapshot else { return nil }
        return .obj(["epoch": .text(epoch), "revision": .number(Double(revision))])
    }
}
