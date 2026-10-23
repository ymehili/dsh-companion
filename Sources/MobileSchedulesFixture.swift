import Foundation

/// Pure in-memory synthetic RPC. Never creates a Native RPC, gateway, Session or Agent.
/// Recurring targets are fixture values, not a local reimplementation of the Host scheduler.
@MainActor
final class MobileSchedulesFixtureRPC: MobileSettingsRPC {
    enum Scenario { case normal, conflictOnce, ended, notFound, cursorMissing, transportFailure }
    private var scenario: Scenario
    private var catalog: [JSONValue]
    private var savedDeliveries: [JSONValue]

    init(scenario: Scenario = .normal) {
        self.scenario = scenario
        let common: [String: JSONValue] = [
            "sessionId": .text("fixture-native"), "status": .text("active"),
            "scheduledAt": .text("2099-01-05T09:00:00.000Z"),
            "prompt": .text("Synthetic reminder. No message will be delivered.")
        ]
        let kinds: [(String, [String: JSONValue])] = [
            ("daily", ["time": .text("09:00:00.000"), "timeZone": .text("Asia/Shanghai")]),
            ("weekly", ["time": .text("10:30:00.000"), "timeZone": .text("America/New_York"), "weekdays": .array([.number(1), .number(3), .number(5)])]),
            ("every", ["everySeconds": .number(3600)]),
            ("at", [:]), ("after", ["afterSeconds": .number(1800)]),
            ("cron", ["expression": .text("0 9 * * 1-5"), "timeZone": .text("UTC")])
        ]
        catalog = kinds.enumerated().map { index, item in
            var row = common
            row["id"] = .text("fixture-schedule-\(item.0)")
            row["title"] = .text("\(item.0.capitalized) fixture reminder")
            row["kind"] = .text(item.0)
            row.merge(item.1) { _, new in new }
            if index == 4 {
                row["status"] = .text("inactive")
                row["scheduledAt"] = .text("2026-01-05T09:00:00.000Z")
            }
            return .obj(row)
        }
        savedDeliveries = (1...28).reversed().map { day in
            .obj(["messageId": .text("fixture-delivery-\(day)"),
                  "scheduledAt": .text(String(format: "2026-01-%02dT09:00:00.000Z", day)),
                  "deliveredAt": .text(String(format: "2026-01-%02dT09:00:01.000Z", day)),
                  "prompt": .text("Synthetic delivered instruction \(day)")])
        }
        if var first = catalog[0].object { first["lastDelivery"] = savedDeliveries[0]; catalog[0] = .obj(first) }
    }

    func call(_ endpoint: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        if scenario == .transportFailure { throw NativeRPCError(message: "Synthetic offline fixture; no network attempted.") }
        if endpoint == "schedule/catalog" { return .array(catalog) }
        let request = args["request"] ?? .null
        let sessionId = request["sessionId"].string ?? ""
        if endpoint == "schedule/list" {
            return .array(try catalog.filter { $0["sessionId"].string == sessionId && $0["status"].string == "active" }.map {
                try MobileScheduleRecord($0).original
            })
        }
        let id = request["id"].string ?? ""
        let index = catalog.firstIndex { $0["id"].string == id && $0["sessionId"].string == sessionId }
        if endpoint == "schedule/history" {
            guard index != nil, scenario != .notFound else { return .obj(["id": .text(id), "code": .text("schedule_not_found")]) }
            var offset = 0
            if let before = request["before"].string {
                guard let cursor = savedDeliveries.firstIndex(where: { $0["messageId"].string == before }), scenario != .cursorMissing else {
                    return .obj(["id": .text(id), "code": .text("delivery_cursor_not_found")])
                }
                offset = cursor + 1
            }
            let limit = request["limit"].integer ?? 25
            guard (1...100).contains(limit) else { throw NativeRPCError(message: "Fixture history limit must be 1...100.") }
            let page = Array(savedDeliveries.dropFirst(offset).prefix(limit))
            var result: [String: JSONValue] = ["id": .text(id), "records": .array(page), "earlierRecordsUnavailable": .bool(true), "earlierRecordsPruned": .bool(true), "retention": .obj(["days": .number(30), "records": .number(100)])]
            if offset + page.count < savedDeliveries.count { result["nextBefore"] = page.last?["messageId"] }
            return .obj(result)
        }
        if endpoint == "schedule/delete" {
            guard let index, scenario != .notFound else { return .obj(["id": .text(id), "deleted": .bool(false), "code": .text("schedule_not_found")]) }
            catalog.remove(at: index)
            return .obj(["id": .text(id), "deleted": .bool(true)])
        }
        if endpoint == "schedule/update" {
            func refusal(_ code: String) -> JSONValue { .obj(["id": .text(id), "updated": .bool(false), "code": .text(code)]) }
            guard let index, scenario != .notFound else { return refusal("schedule_not_found") }
            guard catalog[index]["status"].string == "active", scenario != .ended else { return refusal("schedule_ended") }
            let original = try MobileScheduleRecord(catalog[index]).original
            if scenario == .conflictOnce { scenario = .normal; return refusal("schedule_conflict") }
            guard request["expected"] == original else { return refusal("schedule_conflict") }
            var record = original.object ?? [:]
            for key in ["title", "prompt"] {
                if let text = request[key].string {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, key != "title" || trimmed.count <= 120 else {
                        return .obj(["code": .text("invalid_prompt"), "message": .text("Invalid synthetic title or instruction.")])
                    }
                    record[key] = .text(trimmed)
                }
            }
            if let change = request["change"].object, let kind = change["kind"]?.string {
                for key in ["afterSeconds", "everySeconds", "time", "timeZone", "weekdays", "expression"] { record.removeValue(forKey: key) }
                record["kind"] = .text(kind)
                switch kind {
                case "at":
                    let at = request["change"]["at"]
                    if let instant = at.string { record["scheduledAt"] = .text(instant) }
                    else {
                        let zone = at["time_zone"].string ?? "UTC"
                        let text = "\(at["date"].string ?? "") \(at["time"].string ?? "")"
                        guard let date = MobileScheduleTimingDraft.formatter("yyyy-MM-dd HH:mm:ss.SSS", zone: zone).date(from: text) else {
                            return .obj(["code": .text("invalid_rule"), "message": .text("Invalid fixture date.")])
                        }
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        record["scheduledAt"] = .text(formatter.string(from: date))
                    }
                case "every": record["everySeconds"] = request["change"]["every_seconds"]
                case "daily", "weekly":
                    let timing = request["change"][kind]
                    record["time"] = timing["time"]
                    record["timeZone"] = timing["time_zone"]
                    if kind == "weekly" { record["weekdays"] = timing["weekdays"] }
                case "cron":
                    record["expression"] = request["change"]["cron"]["expression"]
                    record["timeZone"] = request["change"]["cron"]["time_zone"]
                default: return .obj(["code": .text("invalid_rule"), "message": .text("Unsupported fixture timing.")])
                }
            }
            var row = record
            row["sessionId"] = .text(sessionId)
            row["status"] = catalog[index]["status"]
            if catalog[index]["lastDelivery"].object != nil { row["lastDelivery"] = catalog[index]["lastDelivery"] }
            catalog[index] = .obj(row)
            return .obj(["id": .text(id), "updated": .bool(JSONValue.obj(record) != original), "record": .obj(record)])
        }
        throw NativeRPCError(message: "Unsupported synthetic schedules endpoint: \(endpoint). No fallback to live RPC.")
    }
}
