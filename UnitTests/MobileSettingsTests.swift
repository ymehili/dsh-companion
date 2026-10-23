import XCTest
@testable import DSHCompanion

@MainActor final class MobileSettingsTests: XCTestCase {
    private func description(_ rpc: MobileSettingsFixtureRPC) async throws -> MobileSettingsNamespace {
        let result = try await rpc.call("settings/describe", [:])
        return try MobileSettingsNamespace(XCTUnwrap(result["namespaces"].array.first))
    }
    func testDescribeHasNoImplicitWritesDiscoveryOrActivation() async throws {
        let rpc = MobileSettingsFixtureRPC()
        _ = try await description(rpc)
        XCTAssertEqual(rpc.calls, ["settings/describe"])
    }
    func testSchemasteryReferenceEnvelopeAndNestedStruct() throws {
        let schema: JSONValue = .obj(["uid": .number(1), "refs": .obj([
            "1": .obj(["type": .text("object"), "dict": .obj(["nested": .number(2)])]),
            "2": .obj(["type": .text("object"), "dict": .obj(["enabled": .number(3)])]),
            "3": .obj(["type": .text("boolean")])
        ])])
        let fields = try MobileSettingsSchema.fields(schema, secrets: [])
        XCTAssertEqual(fields.map(\.path), [["nested", "enabled"]])
        XCTAssertEqual(fields.first?.kind, .boolean)
        XCTAssertThrowsError(try fields[0].validate(.text("true")))
    }
    func testMalformedAndRecursiveSchemaRejected() {
        XCTAssertThrowsError(try MobileSettingsSchema.fields(.obj(["uid": .number(9), "refs": .obj([:])]), secrets: []))
        let recursive: JSONValue = .obj(["uid": .number(1), "refs": .obj(["1": .obj(["type": .text("object"), "dict": .obj(["again": .number(1)])])])])
        XCTAssertThrowsError(try MobileSettingsSchema.fields(recursive, secrets: []))
    }
    func testRevisionMustBeSafeNonnegativeInteger() async throws {
        let ns = try await description(MobileSettingsFixtureRPC())
        for revision in [JSONValue.number(-1), .number(1.5), .string("3")] {
            var raw = try XCTUnwrap(ns.raw.object); raw["revision"] = revision
            XCTAssertThrowsError(try MobileSettingsNamespace(.obj(raw)))
        }
    }
    func testAllMutationsRequireConfirmationAndCapturedRevision() async throws {
        let rpc = MobileSettingsFixtureRPC()
        let ns = try await description(rpc)
        let field = try XCTUnwrap(ns.fields.first { $0.path == ["enabled"] })
        XCTAssertThrowsError(try ns.mutation(field: field, value: .bool(true), confirmed: false))
        XCTAssertEqual(rpc.calls, ["settings/describe"])
        let args = try ns.mutation(field: field, value: .bool(true), confirmed: true)
        XCTAssertEqual(args["expectedRevision"], .number(Double(ns.revision)))
        XCTAssertEqual(args["ops"]?.array.first?["path"], .array([.text("enabled")]))
        _ = try await rpc.call("settings/mutate", args)
        do { _ = try await rpc.call("settings/mutate", args); XCTFail("Stale edit accepted") }
        catch { XCTAssertEqual(error as? MobileSettingsFailure, .conflict) }
    }
    func testModeEditingUsesDeclaredEnumNotFreeText() async throws {
        let ns = try await description(MobileSettingsFixtureRPC())
        let mode = try XCTUnwrap(ns.fields.first { $0.path == ["mode"] })
        try mode.validate(.text("manual")); try mode.validate(.text("automatic"))
        XCTAssertThrowsError(try mode.validate(.text("invented")))
        XCTAssertThrowsError(try mode.validate(.bool(true)))
    }
    func testNumberBoundsAndTypes() async throws {
        let ns = try await description(MobileSettingsFixtureRPC())
        let field = try XCTUnwrap(ns.fields.first { $0.path == ["limits", "retries"] })
        try field.validate(.number(2))
        for value in [JSONValue.number(-1), .number(11), .number(1.2), .number(.infinity), .text("2")] { XCTAssertThrowsError(try field.validate(value)) }
    }
    func testSecretsCannotUseOrdinaryMutationOrReadBack() throws {
        let raw: JSONValue = .obj(["ns": .text("synthetic"), "revision": .number(1), "applies": .text("live"), "value": .obj([:]), "secrets": .array([.obj(["path": .array([.text("key")]), "set": .bool(true)])]), "schema": .obj(["type": .text("object"), "dict": .obj(["key": .obj(["type": .text("string"), "meta": .obj(["role": .text("secret")])])])])])
        let ns = try MobileSettingsNamespace(raw)
        XCTAssertTrue(ns.fields[0].secret)
        XCTAssertEqual(ns.value(at: ["key"]), .null)
        XCTAssertThrowsError(try ns.mutation(field: ns.fields[0], value: .text("synthetic-placeholder"), confirmed: true))
    }
    func testCredentialFixtureDescribesOnlyStatusAndNeverCopiesValue() async throws {
        let rpc = MobileSettingsFixtureRPC()
        _ = try await rpc.call("credentials/set", ["ref": .text("DEMO_API_KEY"), "value": .text("synthetic-placeholder")])
        let status = try await rpc.call("credentials/describe", ["refs": .array([.text("DEMO_API_KEY")])])
        XCTAssertEqual(status["DEMO_API_KEY"]["configured"], .bool(true))
        XCTAssertEqual(status["DEMO_API_KEY"]["value"], .null)
        XCTAssertFalse(String(data: try JSONEncoder().encode(status), encoding: .utf8)!.contains("synthetic-placeholder"))
        XCTAssertFalse(MobileCredentialEditor.validReference("bad/ref"))
        XCTAssertFalse(MobileCredentialEditor.validReference(""))
        XCTAssertTrue(MobileCredentialEditor.validReference("DEMO_API_KEY"))
    }
    func testSyntheticReadOnlyAndUnavailableCapabilities() async throws {
        let readOnly = MobileSettingsFixtureRPC(scenario: .readOnly)
        let result = try await readOnly.call("settings/describe", [:])
        XCTAssertEqual(result["writable"], .bool(false))
        do { _ = try await readOnly.call("credentials/set", [:]); XCTFail() } catch { }
        let unavailable = MobileSettingsFixtureRPC(scenario: .unavailable)
        do { _ = try await unavailable.call("settings/describe", [:]); XCTFail() } catch { }
    }
    func testScheduleAllSixKindsAndCatalogExpectedStripping() async throws {
        let rpc = MobileSchedulesFixtureRPC()
        let catalog = try await rpc.call("schedule/catalog", [:])
        let records = try catalog.array.map { try MobileScheduleRecord($0) }
        XCTAssertEqual(Set(records.map(\.kind)), Set(["after", "at", "every", "daily", "weekly", "cron"]))
        for record in records {
            XCTAssertEqual(record.original["sessionId"], .null)
            XCTAssertEqual(record.original["status"], .null)
            XCTAssertEqual(record.original["lastDelivery"], .null)
            XCTAssertNotEqual(record.original["scheduledAt"], .null)
        }
    }
    func testScheduleCASRejectsStaleFullRecord() async throws {
        let rpc = MobileSchedulesFixtureRPC()
        let catalog = try await rpc.call("schedule/catalog", [:])
        let record = try MobileScheduleRecord(XCTUnwrap(catalog.array.first))
        var request: [String: JSONValue] = ["sessionId": .text(record.sessionId), "id": .text(record.id), "expected": record.original, "title": .text("New synthetic title")]
        let first = try await rpc.call("schedule/update", ["request": .obj(request)])
        XCTAssertEqual(first["updated"], .bool(true))
        request["title"] = .text("Stale synthetic title")
        let stale = try await rpc.call("schedule/update", ["request": .obj(request)])
        XCTAssertEqual(stale["code"], .text("schedule_conflict"))
    }
    func testScheduleTimingExactWireTypesAndExplicitModeChange() async throws {
        let catalog = try await MobileSchedulesFixtureRPC().call("schedule/catalog", [:])
        let every = try MobileScheduleRecord(XCTUnwrap(catalog.array.first { $0["kind"].string == "every" }))
        var draft = MobileScheduleTimingDraft(record: every)
        draft.everySeconds = "59"; XCTAssertThrowsError(try draft.wireValue())
        draft.everySeconds = "90"; XCTAssertEqual(try draft.wireValue(), .obj(["kind": .text("every"), "every_seconds": .number(90)]))
        draft.kind = "weekly"; draft.weekdays = [1, 7]; draft.timeZone = "Asia/Shanghai"
        let wire = try draft.wireValue()
        XCTAssertEqual(wire["weekly"]["time_zone"], .text("Asia/Shanghai"))
        XCTAssertEqual(wire["weekly"]["weekdays"], .array([.number(1), .number(7)]))
        draft.weekdays = []; XCTAssertThrowsError(try draft.wireValue())
        draft.kind = "cron"; draft.expression = "not cron"; XCTAssertThrowsError(try draft.wireValue())
    }
    func testScheduleHistoryPaginationAndCreationGap() async throws {
        let rpc = MobileSchedulesFixtureRPC()
        let model = MobileSchedulesModel(rpc: rpc)
        await model.load()
        let record = try XCTUnwrap(model.rows.first)
        await model.history(record)
        XCTAssertEqual(model.deliveries.count, 25)
        XCTAssertNotNil(model.nextBefore)
        await model.history(record, more: true)
        XCTAssertEqual(model.deliveries.count, 28)
        XCTAssertNil(model.nextBefore)
        do { _ = try await rpc.call("schedule/create", [:]); XCTFail("Invented create endpoint") } catch { }
    }
    func testProviderLoadDoesNotDiscoverOrWrite() async throws {
        let rpc = MobileSettingsFixtureRPC()
        let controller = MobileProvidersController()
        await controller.load(rpc: rpc)
        XCTAssertEqual(rpc.calls, ["llm/listConfigurableProviders", "account/getState"])
        XCTAssertEqual(controller.account?.status, "signed-out")
        XCTAssertTrue(controller.models.isEmpty)
        await controller.discover(try XCTUnwrap(controller.providers.first))
        XCTAssertEqual(rpc.calls.last, "llm/discoverModels")
        XCTAssertEqual(controller.models["demo"]?.first?.id, "demo-model")
    }
    func testSyntheticEnumEditPersistsWithoutChangingOtherFields() async throws {
        let rpc = MobileSettingsFixtureRPC()
        let before = try await description(rpc)
        let field = try XCTUnwrap(before.fields.first { $0.path == ["mode"] })
        _ = try await rpc.call("settings/mutate", before.mutation(field: field, value: .text("automatic"), confirmed: true))
        let after = try await description(rpc)
        XCTAssertEqual(after.value(at: ["mode"]), .text("automatic"))
        XCTAssertEqual(after.value(at: ["enabled"]), .bool(false))
        XCTAssertEqual(after.revision, before.revision + 1)
    }
    func testScheduleConflictIsVisibleWithoutAutomaticRetry() async throws {
        let rpc = MobileSchedulesFixtureRPC(scenario: .conflictOnce)
        let model = MobileSchedulesModel(rpc: rpc)
        await model.load()
        let original = try XCTUnwrap(model.rows.first)
        let result = await model.update(original, title: "Synthetic title", prompt: original.prompt, timing: nil)
        XCTAssertFalse(result)
        XCTAssertTrue(model.error?.contains("changed") == true)
        XCTAssertEqual(model.rows.first?.original, original.original)
    }
    func testCompleteLicenseFallbackContainsBothNotices() {
        XCTAssertTrue(MobileServerSettingsNotices.fallback.contains("2026 T3 Tools Inc."))
        XCTAssertTrue(MobileServerSettingsNotices.fallback.contains("2019-2022 Miguel de Icaza"))
        XCTAssertTrue(MobileServerSettingsNotices.fallback.contains("THE SOFTWARE IS PROVIDED"))
    }
}
