import Foundation
import Observation

/// Only locally authored messages enter this type. RPC descriptions and Host message payloads are untrusted.
private struct MobileSchedulesSafeError: Error {
    let message: String
}

/// Kept losslessly: update's expected value is the entire original Record, not an id/revision.
struct MobileScheduleRecord: Identifiable, Equatable {
    let original: JSONValue
    let sessionId: String
    let status: String
    let lastDelivery: JSONValue
    var id: String { original["id"].string ?? "" }
    var title: String { original["title"].string ?? "" }
    var prompt: String { original["prompt"].string ?? "" }
    var kind: String { original["kind"].string ?? "" }
    var scheduledAt: String { original["scheduledAt"].string ?? "" }

    init(_ value: JSONValue, sessionId: String? = nil) throws {
        guard var record = value.object,
              let binding = sessionId ?? value["sessionId"].string, !binding.isEmpty,
              ["id", "kind", "title", "prompt", "scheduledAt"].allSatisfy({ value[$0].string != nil }),
              ["after", "at", "every", "daily", "weekly", "cron"].contains(value["kind"].string ?? "") else {
            throw MobileSchedulesSafeError(message: "Host returned an incompatible schedule record.")
        }
        let kind = value["kind"].string ?? ""
        let validTiming: Bool
        switch kind {
        // These fields are schema numbers. Preserve finite values without coercion to integers.
        case "after": validTiming = value["afterSeconds"].number?.isFinite == true
        case "every": validTiming = value["everySeconds"].number?.isFinite == true
        case "daily": validTiming = value["time"].string != nil && value["timeZone"].string != nil
        case "weekly":
            if case .array(let days) = value["weekdays"] {
                let isoDays = days.compactMap(\.integer)
                validTiming = value["time"].string != nil && value["timeZone"].string != nil &&
                    !days.isEmpty && isoDays.count == days.count && Set(isoDays).count == days.count &&
                    isoDays.allSatisfy { (1...7).contains($0) }
            } else { validTiming = false }
        case "cron": validTiming = value["expression"].string != nil && value["timeZone"].string != nil
        default: validTiming = true
        }
        guard validTiming else { throw MobileSchedulesSafeError(message: "Host returned an incomplete schedule timing record.") }
        if sessionId == nil {
            guard ["active", "inactive"].contains(value["status"].string ?? "") else {
                throw MobileSchedulesSafeError(message: "Host returned an incompatible schedule status.")
            }
        }
        self.sessionId = binding
        status = value["status"].string ?? "active"
        lastDelivery = value["lastDelivery"]
        // Catalog-only properties are not members of the strict expected Record schema.
        record.removeValue(forKey: "sessionId")
        record.removeValue(forKey: "status")
        record.removeValue(forKey: "lastDelivery")
        original = .object(record)
    }

    static func numberText(_ value: JSONValue) -> String {
        if let integer = value.integer { return String(integer) }
        if let number = value.number, number.isFinite { return String(number) }
        return "Unavailable"
    }

    var timingSummary: String {
        switch kind {
        case "after": return "After \(Self.numberText(original["afterSeconds"])) seconds"
        case "at": return "One time"
        case "every": return "Every \(Self.numberText(original["everySeconds"])) seconds"
        case "daily": return "Daily · \(original["time"].string ?? "") · \(original["timeZone"].string ?? "")"
        case "weekly": return "Weekly · ISO days \(original["weekdays"].array.compactMap(\.integer).map(String.init).joined(separator: ", ")) · \(original["time"].string ?? "") · \(original["timeZone"].string ?? "")"
        case "cron": return "\(original["expression"].string ?? "") · \(original["timeZone"].string ?? "")"
        default: return kind
        }
    }
}

struct MobileScheduleDelivery: Identifiable {
    let raw: JSONValue
    var id: String { raw["messageId"].string ?? "" }
}

struct MobileScheduleTimingDraft {
    var kind = "at"
    var date = Date()
    var clock = Date()
    var timeZone = "UTC"
    var everySeconds = "3600"
    var weekdays: Set<Int> = [1]
    var expression = "0 9 * * *"

    init(record: MobileScheduleRecord) {
        kind = record.kind == "after" ? "at" : record.kind
        date = Self.parseInstant(record.scheduledAt) ?? Date()
        timeZone = record.original["timeZone"].string ?? "UTC"
        if record.original["everySeconds"].number != nil { everySeconds = MobileScheduleRecord.numberText(record.original["everySeconds"]) }
        weekdays = Set(record.original["weekdays"].array.compactMap(\.integer))
        if weekdays.isEmpty { weekdays = [1] }
        expression = record.original["expression"].string ?? "0 9 * * *"
        let formatter = Self.formatter("HH:mm:ss.SSS", zone: timeZone)
        clock = formatter.date(from: record.original["time"].string ?? "09:00:00.000") ?? date
    }

    static func formatter(_ format: String, zone: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
    static func parseInstant(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func wireValue() throws -> JSONValue {
        guard timeZone == "UTC" || (timeZone.contains("/") && TimeZone(identifier: timeZone) != nil) else {
            throw MobileSchedulesSafeError(message: "Choose UTC or a valid IANA Area/Location time zone.")
        }
        let time = Self.formatter("HH:mm:ss.SSS", zone: timeZone).string(from: clock)
        switch kind {
        case "at":
            guard date > Date() else { throw MobileSchedulesSafeError(message: "Choose a future date and time.") }
            return .obj(["kind": .text("at"), "at": .obj([
                "date": .text(Self.formatter("yyyy-MM-dd", zone: timeZone).string(from: date)),
                "time": .text(Self.formatter("HH:mm:ss.SSS", zone: timeZone).string(from: date)),
                "time_zone": .text(timeZone)
            ])])
        case "every":
            guard let seconds = Double(everySeconds), seconds.isFinite, seconds.rounded() == seconds,
                  seconds >= 60, seconds <= 9_007_199_254_740_991 else {
                throw MobileSchedulesSafeError(message: "Interval must be a whole number of seconds, at least 60 and within the safe integer range.")
            }
            return .obj(["kind": .text("every"), "every_seconds": .number(seconds)])
        case "daily": return .obj(["kind": .text("daily"), "daily": .obj(["time": .text(time), "time_zone": .text(timeZone)])])
        case "weekly":
            guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw MobileSchedulesSafeError(message: "Select at least one weekday.")
            }
            return .obj(["kind": .text("weekly"), "weekly": .obj(["time": .text(time), "time_zone": .text(timeZone), "weekdays": .array(weekdays.sorted().map { .number(Double($0)) })])])
        case "cron":
            let rule = expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rule.split(whereSeparator: \.isWhitespace).count == 5 else {
                throw MobileSchedulesSafeError(message: "Cron requires five fields: minute hour day-of-month month day-of-week. Host validates the expression.")
            }
            return .obj(["kind": .text("cron"), "cron": .obj(["expression": .text(rule), "time_zone": .text(timeZone)])])
        default: throw MobileSchedulesSafeError(message: "Unsupported timing type.")
        }
    }
}

@MainActor @Observable
final class MobileSchedulesModel {
    let rpc: any MobileSettingsRPC
    var rows: [MobileScheduleRecord] = []
    var loading = false
    var mutating = false
    var error: String?
    var notice: String?
    var sessionFilter = ""
    var deliveries: [MobileScheduleDelivery] = []
    var nextBefore: String?
    var historyNote: String?
    var historyError: String?
    var historyLoading = false
    private var loadGeneration = UUID()
    private var historyGeneration = UUID()
    private var historyIdentity = ""

    init(rpc: any MobileSettingsRPC) { self.rpc = rpc }

    func load(sessionId: String = "") async {
        let token = UUID()
        loadGeneration = token
        loading = true
        error = nil
        sessionFilter = sessionId
        defer { if loadGeneration == token { loading = false } }
        do {
            let value: JSONValue
            if sessionId.isEmpty { value = try await rpc.call("schedule/catalog", [:]) }
            else { value = try await rpc.call("schedule/list", ["request": .obj(["sessionId": .text(sessionId)])]) }
            guard case .array(let values) = value else { throw MobileSchedulesSafeError(message: "Host returned an incompatible schedules list.") }
            let parsed = try values.map { try MobileScheduleRecord($0, sessionId: sessionId.isEmpty ? nil : sessionId) }
            guard loadGeneration == token else { return }
            rows = parsed
        } catch {
            guard loadGeneration == token else { return }
            self.error = Self.safeMessage(error, fallback: "Schedules could not be loaded. Check the connection and retry.")
        }
    }

    func update(_ record: MobileScheduleRecord, title: String, prompt: String, timing: MobileScheduleTimingDraft?) async -> Bool {
        guard !mutating else { return false }
        mutating = true
        error = nil
        defer { mutating = false }
        do {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 120, !prompt.isEmpty else {
                throw MobileSchedulesSafeError(message: "Provide a nonempty title (up to 120 characters) and reminder instruction.")
            }
            var request: [String: JSONValue] = ["sessionId": .text(record.sessionId), "id": .text(record.id), "expected": record.original, "title": .text(title), "prompt": .text(prompt)]
            if let timing { request["change"] = try timing.wireValue() }
            let result = try await rpc.call("schedule/update", ["request": .obj(request)])
            if let code = result["code"].string {
                // Never display result.message or an unrecognized code: either could contain private payloads.
                throw MobileSchedulesSafeError(message: Self.explanation(code))
            }
            guard result["updated"].bool != nil, result["record"].object != nil else {
                throw MobileSchedulesSafeError(message: "Host returned an incompatible update result. Refresh before retrying.")
            }
            notice = result["updated"].bool == true ? "Schedule saved." : "No changes; Host kept the existing record."
            await load(sessionId: sessionFilter)
            return true
        } catch {
            self.error = Self.safeMessage(error, fallback: "Schedule update could not be confirmed. Refresh before retrying; the Host may have received the request.")
            return false
        }
    }

    func delete(_ record: MobileScheduleRecord) async -> Bool {
        guard !mutating else { return false }
        mutating = true
        error = nil
        defer { mutating = false }
        do {
            // Delete has NO expected/CAS field. Do not imply this protects against concurrent edits.
            let result = try await rpc.call("schedule/delete", ["request": .obj(["sessionId": .text(record.sessionId), "id": .text(record.id)])])
            guard let deleted = result["deleted"].bool else { throw MobileSchedulesSafeError(message: "Host returned an incompatible delete result. Refresh before retrying.") }
            guard deleted else { throw MobileSchedulesSafeError(message: Self.explanation(result["code"].string ?? "")) }
            notice = "Schedule deleted. Already queued messages are unchanged."
            await load(sessionId: sessionFilter)
            return true
        } catch {
            self.error = Self.safeMessage(error, fallback: "Schedule deletion could not be confirmed. Refresh before retrying; the Host may have received the request.")
            return false
        }
    }

    func history(_ record: MobileScheduleRecord, more: Bool = false) async {
        let identity = "\(record.sessionId):\(record.id)"
        if more { guard !historyLoading, historyIdentity == identity, nextBefore != nil else { return } }
        let token = UUID()
        historyGeneration = token
        historyIdentity = identity
        historyLoading = true
        historyError = nil
        if !more { deliveries = []; nextBefore = nil; historyNote = nil }
        defer { if historyGeneration == token { historyLoading = false } }
        do {
            var request: [String: JSONValue] = ["sessionId": .text(record.sessionId), "id": .text(record.id), "limit": .number(25)]
            if more, let nextBefore { request["before"] = .text(nextBefore) }
            let result = try await rpc.call("schedule/history", ["request": .obj(request)])
            guard historyGeneration == token else { return }
            if let code = result["code"].string { throw MobileSchedulesSafeError(message: Self.explanation(code)) }
            guard case .array(let records) = result["records"] else { throw MobileSchedulesSafeError(message: "Host returned an incompatible delivery history.") }
            deliveries += records.map { MobileScheduleDelivery(raw: $0) }
            nextBefore = result["nextBefore"].string
            var notes = ["Retention: \(result["retention"]["days"].integer ?? 0) days, up to \(result["retention"]["records"].integer ?? 0) records."]
            if result["earlierRecordsUnavailable"].bool == true { notes.append("Earlier records may be unavailable; missing receipts are not reconstructed.") }
            if result["earlierRecordsPruned"].bool == true { notes.append("Earlier saved records were pruned.") }
            historyNote = notes.joined(separator: " ")
        } catch {
            if historyGeneration == token { historyError = Self.safeMessage(error, fallback: "Delivery history could not be loaded. Check the connection and retry.") }
        }
    }

    private static func safeMessage(_ error: Error, fallback: String) -> String {
        // Transport errors are intentionally opaque; even localizedDescription may include request data.
        (error as? MobileSchedulesSafeError)?.message ?? fallback
    }

    private static func explanation(_ code: String) -> String {
        switch code {
        case "schedule_conflict": return "schedule_conflict: The record changed since editing began. Refresh and reopen it; your draft has not overwritten it."
        case "schedule_ended": return "schedule_ended: This schedule is inactive and cannot be edited."
        case "schedule_not_found": return "schedule_not_found: The schedule no longer exists in its original thread."
        case "delivery_cursor_not_found": return "delivery_cursor_not_found: The saved history cursor is unavailable. Reload history from the beginning."
        case "invalid_prompt": return "invalid_prompt: Host refused the reminder title or instruction. Check both fields."
        case "invalid_selector": return "invalid_selector: Host refused the schedule binding. Refresh before retrying."
        case "invalid_rule": return "invalid_rule: Host refused the timing rule. Check the expression and timing fields."
        case "invalid_time_zone": return "invalid_time_zone: Choose a supported UTC or IANA time zone."
        case "not_future": return "not_future: Choose a future date and time."
        case "time_out_of_range": return "time_out_of_range: The target is outside the Host's supported date range."
        case "frequency_too_high": return "frequency_too_high: Choose a less frequent reminder rule."
        case "subagent_session": return "subagent_session: Schedules bound to a delegated child thread cannot be edited."
        case "internal_error": return "internal_error: Host could not complete the schedule operation. Refresh before retrying."
        default: return "Host refused this schedule operation. Refresh and check the schedule before retrying."
        }
    }
}
