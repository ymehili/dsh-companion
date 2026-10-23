import XCTest

final class CoreNativeTests: XCTestCase {
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-native-ui-fixture"] + flags; app.launch(); return app
    }
    private func session(_ app: XCUIApplication, _ id: String = "fixture-native") -> XCUIElement { app.descendants(matching: .any).matching(identifier: "session-\(id)").firstMatch }
    private func open(_ app: XCUIApplication, _ id: String = "fixture-native") {
        let row = session(app, id)
        reveal(row, in: app, towardBottom: false)
        XCTAssertTrue(row.waitForExistence(timeout: 10)); XCTAssertTrue(row.isHittable); row.tap()
    }
    private func chats(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["Threads"]
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(sidebar(app).waitForExistence(timeout: 5))
    }
    private func sidebar(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: "dsh-sidebar").firstMatch }
    private func composer(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: "nativeComposer").firstMatch }
    func testSystemNavigationListAndSegmentedPicker() {
        let app = launch()
        assertShelves(app)
        XCTAssertFalse(app.buttons["Plugins"].exists); XCTAssertFalse(app.buttons["Automation tasks"].exists)
        capture(app, "System sidebar list with Mac shelves")
        open(app)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.segmentedControls.count, 0)
        XCTAssertTrue(app.buttons["Session actions"].exists)
        XCTAssertFalse(app.buttons["Voice input"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        capture(app, "Native controls and conversation")
    }
    func testSystemBackSwipeReturnsFullWidthSidebarAndKeepsDraft() {
        let app = launch(); open(app)
        let field = composer(app); XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("Keep this draft")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.4)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.4)))
        XCTAssertTrue(sidebar(app).waitForExistence(timeout: 5)); assertShelves(app)
        XCTAssertEqual(sidebar(app).frame.width, app.frame.width, accuracy: 1)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        capture(app, "Apple interactive back to full screen Chats")
        open(app); XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "Keep this draft")
    }
    func testCancelledNativeBackSwipeLeavesUsableConversation() {
        let app = launch(); open(app); XCTAssertTrue(composer(app).waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.4))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(composer(app).isHittable)
        app.buttons["Session actions"].tap(); app.buttons["Activity & trajectory"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nativeTrajectory").firstMatch.waitForExistence(timeout: 5))
    }
    func testDraftsStayScopedAcrossNativeNavigation() {
        let app = launch(); open(app)
        let field = composer(app); XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("Unsent text")
        chats(app); open(app, "fixture-other")
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertFalse((field.value as? String ?? "").contains("Unsent text"))
        chats(app); open(app); XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertEqual(field.value as? String, "Unsent text")
    }
    func testSearchSelectionDismissesKeyboard() {
        let app = launch()
        app.buttons["Search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("native")
        open(app); XCTAssertTrue(composer(app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }
    func testLoadingDoesNotPretendToBeAnEmptyNewChat() {
        let app = launch(["-native-loading-fixture"]); open(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "conversation-loading").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Start a conversation"].exists)
        XCTAssertFalse(app.buttons["Send message"].isEnabled)
        capture(app, "Existing chat loading state")
        chats(app); open(app, "fixture-other")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "conversation-loading").firstMatch.waitForExistence(timeout: 5))
        chats(app); open(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "conversation-loading").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Start a conversation"].exists)
    }
    func testOfflineConversationShowsRetryNotEmptyState() {
        let app = launch(["-native-offline-fixture"]); open(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "conversation-load-error").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Start a conversation"].exists)
        XCTAssertFalse(app.buttons["Send message"].isEnabled)
        XCTAssertTrue(app.buttons["Retry"].exists)
    }
    func testComposerKeepsNextDraftSeparateWhileSending() {
        let app = launch(["-native-sending-fixture"]); open(app)
        let field = composer(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertTrue(field.isEnabled)
        field.tap(); field.typeText("My next draft")
        XCTAssertEqual(field.value as? String, "My next draft")
        XCTAssertFalse(app.buttons["Send message"].isEnabled)
    }
    func testTrajectoryAndModelUseNativeControls() {
        let app = launch(); open(app); XCTAssertTrue(composer(app).waitForExistence(timeout: 10))
        app.buttons["Session actions"].tap(); app.buttons["Activity & trajectory"].tap()
        XCTAssertTrue(app.staticTexts["tool/call"].waitForExistence(timeout: 5))
        capture(app, "Native trajectory list")
        app.buttons["Done"].tap(); app.buttons["Session actions"].tap(); app.buttons["session-model-action"].tap()
        XCTAssertTrue(app.staticTexts["Test provider"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["Done"].exists)
        XCTAssertEqual(app.webViews.count, 0)
    }
    func testOnboardingErrorsAreVisible() {
        let app = XCUIApplication(); app.launchArguments = ["-native-onboarding-fixture", "-native-pair-error-fixture"]; app.launch()
        let pair = app.buttons["Pair this iPhone"]; XCTAssertTrue(pair.waitForExistence(timeout: 5)); pair.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pairingError").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scan pairing QR"].exists)
    }
    func testScannerFallbackRemainsNative() {
        let app = XCUIApplication(); app.launchArguments = ["-native-onboarding-fixture"]; app.launch()
        let pair = app.buttons["Pair this iPhone"]; XCTAssertTrue(pair.waitForExistence(timeout: 5)); pair.tap()
        app.buttons["Scan pairing QR"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pairingError").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Paste pairing link"].exists); XCTAssertEqual(app.webViews.count, 0)
    }
    func testShelvesAndUnknownCountsStayExplicit() {
        let app = launch(["-native-inbox-unavailable-fixture"]); assertShelves(app)
        XCTAssertTrue(app.buttons["retry-inbox-sync"].exists)
        capture(app, "Native shelf error and retry")
    }
    func testStaleAndEmptyShelvesStayVisible() {
        let app = launch(["-native-inbox-stale-fixture", "-native-empty-working-fixture"]); assertShelves(app)
        XCTAssertTrue(session(app).exists); XCTAssertFalse(session(app, "fixture-working").exists)
        XCTAssertTrue(app.buttons["retry-inbox-sync"].exists)
    }
    func testShortConversationDoesNotShowFalseJumpToLatest() {
        let app = launch(); open(app)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["latest-messages"].exists)
        capture(app, "Short chat without spurious scroll action")
    }
    func testNativeScrollRecoversFollowAtBottom() {
        let app = launch(["-native-scroll-fixture"]); open(app)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 10))
        let scroll = app.scrollViews["conversation-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        scroll.swipeDown()
        XCTAssertTrue(app.buttons["latest-messages"].waitForExistence(timeout: 5))
        scroll.swipeUp(); scroll.swipeUp()
        XCTAssertTrue(app.buttons["latest-messages"].waitForNonExistence(timeout: 5))
    }
    func testNativeMarkdownCodeAndHeadings() {
        let app = launch(["-native-rich-fixture"]); open(app)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 10))
        let scroll = app.scrollViews["conversation-scroll"]
        scroll.swipeUp()
        XCTAssertTrue(app.buttons["Copy code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Native code block"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        capture(app, "Native selectable code block and heading")
    }
    func testMacStyleDarkSidebarUsesExactVisibilityNot284Inbox() {
        let app = launch(["-native-mac-sidebar-fixture", "-native-dark-fixture"])
        for (shelf, expected) in [("inbox", "5"), ("working", "2"), ("settled", "931")] {
            let header = app.descendants(matching: .any).matching(identifier: "shelf-\(shelf)").firstMatch
            reveal(header, in: app, towardBottom: true)
            XCTAssertTrue(header.waitForExistence(timeout: 5))
            XCTAssertTrue(header.label.contains("(\(expected))"), header.label)
        }
        XCTAssertFalse(session(app, "fixture-blank-1").exists)
        XCTAssertFalse(session(app, "fixture-archived-1").exists)
        capture(app, "Mac-style flat sidebar with 5 Inbox 2 Working 931 Settled")
        open(app); chats(app)
        capture(app, "Mac-style selected row after native navigation")
    }
    func testMultiplePhotoPreviewsRemoveOneAndKeepSessionDrafts() {
        let app = launch(["-native-multi-photo-fixture"]); open(app)
        composer(app).tap()
        let count = app.staticTexts["attachment-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 10)); XCTAssertEqual(count.label, "2 photos attached")
        XCTAssertTrue(app.buttons["remove-photo-1"].exists)
        capture(app, "Two photo attachments in native composer")
        app.buttons["remove-photo-0"].tap()
        XCTAssertEqual(count.label, "1 photo attached")
        chats(app); open(app, "fixture-other")
        XCTAssertFalse(count.exists)
        chats(app); open(app)
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.label, "1 photo attached")
    }
    func testOrderedPhotoImportSelectsTwoThenAddsAnotherBatch() {
        // Controlled async transfer through the real importer, never an unowned
        // simulator/user Photos gallery. Production still uses Apple's picker.
        let app = launch(["-native-photo-fixture"]); open(app); composer(app).tap()
        XCTAssertTrue(app.buttons["Attach photos"].waitForExistence(timeout: 10)); app.buttons["Attach photos"].tap()
        let count = app.staticTexts["attachment-count"]
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2 photos attached'"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [two], timeout: 10), .completed)
        capture(app, "Two ordered synthetic transfers in the native composer")
        app.buttons["Attach photos"].tap()
        let three = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '3 photos attached'"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [three], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["remove-photo-2"].exists)
        capture(app, "Three imported attachments from two separate batches")
    }
    func testChatRedesignPrototypeCanvasAndKeyboard() {
        let app = launch(); open(app)
        let field = composer(app); XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(app.segmentedControls.count, 0)
        XCTAssertFalse(app.buttons["To-dos (2)"].exists)
        XCTAssertFalse(app.staticTexts["Full access"].exists)
        let surface = app.descendants(matching: .any).matching(identifier: "chat-composer-surface").firstMatch
        XCTAssertTrue(surface.exists); XCTAssertLessThan(surface.frame.height, 90)
        capture(app, "Reference-based clean chat prototype")
        field.tap(); field.typeText("A clear message with a compact composer")
        capture(app, "Reference-based composer with keyboard")
        app.scrollViews["conversation-scroll"].swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.buttons["Session actions"].tap(); app.buttons["Activity & trajectory"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nativeTrajectory").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["tool/call"].exists)
    }
    func testChatRedesignPrototypePhotoLayout() {
        let app = launch(["-native-multi-photo-fixture", "-native-dark-fixture"]); open(app)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 10)); composer(app).tap()
        XCTAssertTrue(app.buttons["remove-photo-1"].exists)
        capture(app, "Reference-based dark composer with two attachments")
        app.buttons["remove-photo-0"].tap()
        XCTAssertEqual(app.staticTexts["attachment-count"].label, "1 photo attached")
    }
    func testResponseActionsOfferNativeReadOnlyTextSelection() {
        let app = launch(); open(app)
        let actions = app.buttons["Response actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10)); actions.tap()
        app.buttons["Select text"].tap()
        XCTAssertTrue(app.textViews["chat-selectable-text"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.buttons["Copy all"].exists)
        capture(app, "Native read-only response selection")
    }
    func testHistoricalImageLoadsThroughSessionRPCAndRetries() {
        let app = launch(["-native-history-image-fixture", "-native-image-retry-fixture"]); open(app)
        XCTAssertTrue(composer(app).waitForExistence(timeout: 10))
        let retry = app.buttons["Retry Synthetic history.jpg"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10)); retry.tap()
        let image = app.images["loaded-chat-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertTrue(image.label.contains("320 by 220"))
        capture(app, "Authenticated historical image card after explicit retry")
    }
    func testKeyboardKeepsLatestMessageAboveExpandedComposer() {
        let app = launch(["-native-scroll-fixture"]); open(app)
        let field = composer(app); XCTAssertTrue(field.waitForExistence(timeout: 10))
        let tail = app.descendants(matching: .any).matching(identifier: "chat-message-63").firstMatch
        let surface = app.descendants(matching: .any).matching(identifier: "chat-composer-surface").firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 5))
        field.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tail.exists && tail.frame.maxY <= surface.frame.minY + 2 }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        field.typeText("First line\nSecond line\nThird line\nFourth line")
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tail.exists && tail.frame.maxY <= surface.frame.minY + 2 }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 5), .completed)
        capture(app, "Latest message remains above keyboard and multiline composer")
    }
    func testKeyboardDoesNotJumpAwayFromOlderMessages() {
        let app = launch(["-native-scroll-fixture"]); open(app)
        let field = composer(app); XCTAssertTrue(field.waitForExistence(timeout: 10))
        app.scrollViews["conversation-scroll"].swipeDown(); app.scrollViews["conversation-scroll"].swipeDown()
        XCTAssertTrue(app.buttons["latest-messages"].waitForExistence(timeout: 5))
        field.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["latest-messages"].exists)
        let tail = app.descendants(matching: .any).matching(identifier: "chat-message-63").firstMatch
        XCTAssertFalse(tail.isHittable)
        capture(app, "Keyboard preserves reading older history")
    }
    func testAgentQuestionsAppearAndRetainChoicesOnRetry() {
        let app = launch(["-native-question-fixture", "-native-question-retry-fixture", "-native-question-draft-fixture"]); open(app)
        let card = app.descendants(matching: .any).matching(identifier: "inline-question-card-fixture-question").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertFalse(composer(app).exists) // The question owns the composer, not a chat send.
        let submit = app.buttons["inline-question-submit"]
        XCTAssertTrue(submit.exists); XCTAssertFalse(submit.isEnabled)
        let direction = app.buttons["inline-question-option-direction-0"]
        XCTAssertFalse(direction.isSelected)
        direction.tap()
        XCTAssertFalse(submit.isEnabled) // A partial batch must never submit.
        let detail = app.buttons["inline-question-option-details-0"]
        let questions = card.scrollViews.firstMatch
        if !detail.isHittable { questions.swipeUp() }
        detail.tap(); app.buttons["inline-question-option-details-1"].tap()
        XCTAssertTrue(submit.isEnabled)
        app.buttons["inline-question-collapse"].tap()
        XCTAssertTrue(app.buttons["inline-question-bar"].exists)
        XCTAssertFalse(composer(app).exists)
        app.buttons["inline-question-bar"].tap()
        chats(app); open(app, "fixture-other")
        XCTAssertTrue(composer(app).waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists) // Another session must not inherit the question slot.
        XCTAssertFalse((composer(app).value as? String ?? "").contains("Keep my separate draft"))
        chats(app); open(app)
        XCTAssertTrue(card.waitForExistence(timeout: 5)); XCTAssertTrue(submit.isEnabled)
        app.buttons["Session actions"].tap(); app.buttons["Questions (1)"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "question-card-fixture-question").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["question-option-direction-0"].isSelected)
        let globalSubmit = app.buttons["question-submit"]
        if !globalSubmit.isHittable { app.swipeUp() }
        XCTAssertTrue(globalSubmit.isEnabled)
        app.buttons["Done"].tap()
        XCTAssertTrue(submit.waitForExistence(timeout: 5)); XCTAssertTrue(submit.isEnabled)
        capture(app, "Inline and global questions share explicit choices without submitting")
        submit.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Couldn’t send this answer")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled)
        app.buttons["inline-question-collapse"].tap(); app.buttons["inline-question-bar"].tap()
        XCTAssertTrue(submit.isEnabled) // Failed answer retains the complete batch.
        submit.tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 5))
        XCTAssertEqual(composer(app).value as? String, "Keep my separate draft")
        XCTAssertFalse(card.exists)
        app.buttons["Session actions"].tap(); app.buttons["Questions (0)"].tap()
        XCTAssertTrue(app.staticTexts["All questions answered"].waitForExistence(timeout: 5))
    }
    func testInlineShelvesScrollWithInboxAndNavigate() {
        let app = launch(["-native-sidebar-dock-fixture"])
        XCTAssertTrue(app.buttons["sidebar-settings-button"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sidebar-bottom-shelves").firstMatch.exists)
        let workingHeader = app.descendants(matching: .any).matching(identifier: "shelf-working").firstMatch
        reveal(workingHeader, in: app, towardBottom: true)
        XCTAssertTrue(workingHeader.isHittable)
        if workingHeader.value as? String == "Collapsed" { workingHeader.tap() }
        let working = session(app, "fixture-working")
        reveal(working, in: app, towardBottom: true)
        XCTAssertTrue(working.isHittable); working.tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 5))
        chats(app)
        let settledHeader = app.descendants(matching: .any).matching(identifier: "shelf-settled").firstMatch
        reveal(settledHeader, in: app, towardBottom: true)
        XCTAssertTrue(settledHeader.isHittable)
        if settledHeader.value as? String == "Collapsed" { settledHeader.tap() }
        let settled = session(app, "fixture-settled")
        reveal(settled, in: app, towardBottom: true)
        XCTAssertTrue(settled.isHittable); settled.tap()
        XCTAssertTrue(composer(app).waitForExistence(timeout: 5))
        capture(app, "Working and Settled navigate from inline native shelves")
    }
    func testSidebarNativeSearchNewChatAndSettingsNavigation() {
        let app = launch(); assertShelves(app)
        let search = app.buttons["Search"], create = app.tabBars.buttons["New chat"], settings = app.buttons["sidebar-settings-button"]
        XCTAssertTrue(search.exists); XCTAssertTrue(create.exists); XCTAssertTrue(settings.exists)
        XCTAssertLessThan(search.frame.maxY, app.frame.height * 0.25)
        XCTAssertGreaterThan(create.frame.minY, app.frame.height * 0.75)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        XCTAssertTrue(app.buttons["session-fixture-native"].exists)
        settings.tap(); XCTAssertTrue(app.buttons["settings-connection"].waitForExistence(timeout: 5))
        app.buttons["close-settings"].tap()
        app.buttons["sidebar-connection-status"].tap()
        XCTAssertTrue(app.buttons["settings-connection"].waitForExistence(timeout: 5))
        app.buttons["close-settings"].tap()
        create.tap()
        XCTAssertTrue(app.buttons["new-thread-default-workspace"].waitForExistence(timeout: 5))
        app.buttons["new-thread-cancel"].tap()
        XCTAssertTrue(sidebar(app).waitForExistence(timeout: 5))
        open(app)
        app.buttons["Session actions"].tap()
        XCTAssertTrue(app.buttons["session-model-action"].exists)
        XCTAssertTrue(app.buttons["Questions (0)"].exists); XCTAssertTrue(app.buttons["Approvals (0)"].exists)
        XCTAssertFalse(app.buttons["Files"].exists); XCTAssertFalse(app.buttons["Terminal"].exists)
        app.buttons["Approvals (0)"].tap()
        XCTAssertTrue(app.navigationBars["Approvals"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].exists)
        capture(app, "Native tabs, integrated search, settings and session actions")
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardBottom: Bool) {
        for _ in 0..<16 {
            if element.exists && element.isHittable { return }
            if towardBottom { sidebar(app).swipeUp() } else { sidebar(app).swipeDown() }
        }
    }
    private func assertShelves(_ app: XCUIApplication) {
        XCTAssertTrue(sidebar(app).waitForExistence(timeout: 10))
        for id in ["shelf-inbox", "shelf-working", "shelf-settled"] {
            let header = app.descendants(matching: .any).matching(identifier: id).firstMatch
            reveal(header, in: app, towardBottom: true)
            XCTAssertTrue(header.exists, "Missing \(id)")
        }
        reveal(session(app), in: app, towardBottom: false)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
