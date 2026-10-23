import XCTest
@testable import DSHCompanion

final class NativeInteractionTests: XCTestCase {
    @MainActor private func setup() async -> (NativeStore, ScriptedTransport) {
        let transport = ScriptedTransport()
        let store = NativeStore(transport: transport, credential: String(repeating: "a", count: 43), restoreCredentials: false)
        await store.start(); return (store, transport)
    }
    @MainActor func testRunningPromptSteersAndRetryKeepsOriginalMode() async {
        let (store, transport) = await setup(); await store.choose(store.sessions[0]); let id = store.selected!.id
        transport.emit("api-session/status", [.text(id), .bool(true)])
        transport.failPrompt = true; store.draft = "Please change direction"
        _ = await store.send(for: id)
        transport.emit("api-session/status", [.text(id), .bool(false)]); transport.failPrompt = false
        await store.retryFailedMessage(id)
        let requests = transport.calls.filter { $0.0 == "session/prompt" }.map { $0.1["args"]["request"] }
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0]["mode"].string, "steer"); XCTAssertEqual(requests[1], requests[0])
        await store.setForeground(false)
    }
    @MainActor func testIdlePromptUsesQueueAdmission() async {
        let (store, transport) = await setup(); await store.choose(store.sessions[0]); store.draft = "Start a fresh turn"
        _ = await store.send(for: store.selected!.id)
        XCTAssertEqual(transport.calls.first(where: { $0.0 == "session/prompt" })?.1["args"]["request"]["mode"].string, "queue")
        await store.setForeground(false)
    }
    @MainActor func testExplicitFollowUpChoiceIsCapturedAndRetriedUnchanged() async {
        let (store, transport) = await setup(); await store.choose(store.sessions[0]); let id = store.selected!.id
        transport.emit("api-session/status", [.text(id), .bool(true)])
        store.setFollowUpMode("queue"); store.draft = "Steer this specific message"
        transport.failPrompt = true
        _ = await store.send(for: id, images: [], mode: "steer")
        store.setFollowUpMode("queue"); transport.failPrompt = false
        await store.retryFailedMessage(id)
        let requests = transport.calls.filter { $0.0 == "session/prompt" }.map { $0.1["args"]["request"] }
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0]["mode"].string, "steer"); XCTAssertEqual(requests[0], requests[1])
        await store.setForeground(false)
    }
    @MainActor func testInvalidFollowUpModeDoesNotClearDraftOrSend() async {
        let (store, transport) = await setup(); await store.choose(store.sessions[0]); store.draft = "Keep this draft"
        let accepted = await store.send(for: store.selected!.id, images: [], mode: "restart")
        XCTAssertFalse(accepted); XCTAssertEqual(store.draft, "Keep this draft")
        XCTAssertTrue(transport.calls.filter { $0.0 == "session/prompt" }.isEmpty)
        await store.setForeground(false)
    }
    private func questionRequest() -> JSONValue {
        .obj(["questions": .array([.obj(["id": .text("q"), "question": .text("Which option?"), "multiSelect": .bool(true), "options": .array([.obj(["label": .text("A")]), .obj(["label": .text("B")])])])]), "wait": .obj(["callId": .text("question-call"), "timed": .bool(true)])])
    }
    @MainActor private func deliverQuestion(_ transport: ScriptedTransport) {
        transport.onFrame?(.obj(["type": .text("item"), "streamId": .text(transport.events), "value": .obj(["type": .text("waterfall"), "eventId": .text("live-question"), "event": .text("user-questions/request"), "agentId": .text("one"), "request": questionRequest()])]))
    }
    @MainActor func testLiveQuestionAnswersExactWaterfallAndCancelsClaim() async {
        let (store, transport) = await setup(); deliverQuestion(transport)
        let card = store.questions[0]; XCTAssertTrue(card.questions[0].multiSelect)
        await store.setQuestionVisible(card, visible: true)
        XCTAssertEqual(transport.sent.last?["endpoint"].string, "userQuestions/attachWait")
        transport.failAnswer = true
        let failed = await store.submitAnswers(card, answers: [.init(id: "q", selected: ["B","A"])])
        XCTAssertFalse(failed); XCTAssertEqual(store.questions.count, 1); XCTAssertNotNil(store.questionErrors[card.id])
        transport.failAnswer = false
        let sent = await store.submitAnswers(card, answers: [.init(id: "q", selected: ["B","A"])])
        XCTAssertTrue(sent); XCTAssertTrue(store.questions.isEmpty)
        let result = transport.calls.last(where: { $0.0 == "$events/result" })!.1["args"]
        XCTAssertEqual(result["eventId"].string, "live-question"); XCTAssertEqual(result["outcome"]["kind"].string, "result")
        XCTAssertEqual(result["outcome"]["value"]["answers"].array[0]["selected"].array, [.text("A"),.text("B")])
        XCTAssertEqual(transport.sent.last?["type"].string, "cancel")
        await store.setForeground(false)
    }
    @MainActor func testContinuedQuestionUsesOwningSessionNotSelectedChat() async {
        let (store, transport) = await setup(); await store.choose(store.sessions[1])
        store.desktopProjections["one"] = .obj(["userQuestions": .obj(["active": .array([.obj(["callId": .text("continued-call"), "state": .text("continued"), "questions": questionRequest()["questions"]])])])])
        let card = store.questions[0]
        let ok = await store.submitAnswers(card, answers: [.init(id: "q", selected: ["A"])])
        XCTAssertTrue(ok); XCTAssertTrue(store.questions.isEmpty)
        let request = transport.calls.last(where: { $0.0 == "userQuestions/answer" })!.1["args"]
        XCTAssertEqual(request["agentId"].string, "one"); XCTAssertEqual(request["callId"].string, "continued-call")
        XCTAssertTrue(transport.calls.filter { $0.0 == "session/prompt" }.isEmpty)
        await store.setForeground(false)
    }
    @MainActor func testBackgroundDelegatesLiveQuestionsWithoutAnswering() async {
        let (store, transport) = await setup(); deliverQuestion(transport)
        await store.setForeground(false)
        XCTAssertTrue(store.liveQuestions.isEmpty)
        let result = transport.calls.last(where: { $0.0 == "$events/result" })!.1["args"]
        XCTAssertEqual(result["outcome"]["kind"].string, "next")
        XCTAssertTrue(transport.calls.filter { $0.0 == "session/prompt" }.isEmpty)
    }
}
