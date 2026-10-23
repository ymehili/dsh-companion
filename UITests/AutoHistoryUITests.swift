import XCTest

final class AutoHistoryUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func launch(error: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-native-ui-fixture", "-native-auto-history-fixture"]
        if error { app.launchArguments += ["-native-auto-history-error-fixture"] }
        app.launch()
        let session = element(app, "session-fixture-native")
        XCTAssertTrue(session.waitForExistence(timeout: 10)); session.tap()
        XCTAssertTrue(element(app, "nativeComposer").waitForExistence(timeout: 10))
        return app
    }
    private func scrollToHistory(_ app: XCUIApplication, until id: String) {
        let scroll = app.scrollViews["conversation-scroll"]
        for _ in 0..<12 {
            if element(app, id).exists { return }
            // Slow deliberate upward reading gesture, not a programmatic scroll.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element(app, id).waitForExistence(timeout: 5))
    }
    func testInitialLatestDoesNotPageAndUpwardGestureAutomaticallyLoads() {
        let app = launch()
        let tail = element(app, "chat-message-35")
        XCTAssertTrue(tail.waitForExistence(timeout: 5)); XCTAssertTrue(tail.isHittable)
        XCTAssertFalse(element(app, "history-loading").exists)
        XCTAssertFalse(element(app, "chat-message-12").exists)
        XCTAssertFalse(app.buttons["Earlier messages"].exists)
        XCTAssertFalse(app.buttons["latest-messages"].exists)
        scrollToHistory(app, until: "history-loading")
        XCTAssertTrue(element(app, "history-loading").waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["latest-messages"].exists)
        // A page prepended above the user, not a jump to the newest message.
        XCTAssertFalse(tail.isHittable)
        app.scrollViews["conversation-scroll"].swipeDown()
        XCTAssertTrue(element(app, "chat-message-21").waitForExistence(timeout: 5))
        app.buttons["latest-messages"].tap()
        let latestVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tail.exists && tail.isHittable }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [latestVisible], timeout: 5), .completed)
    }
    func testExpandedWorkAndDetailRetainExistingToolPixelPositions() {
        let app = launch(error: true)
        scrollToHistory(app, until: "history-retry")
        let retry = app.buttons["history-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        let group = element(app, "tool-group-24")
        app.buttons["2 tool calls"].tap()
        let tool = app.buttons["Synthetic work 24"]
        XCTAssertTrue(tool.waitForExistence(timeout: 5)); tool.tap()
        let row24 = element(app, "tool-row-seq-24"), row25 = element(app, "tool-row-seq-25")
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in row24.exists && row24.frame.height > 80 }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
        let before24 = row24.frame.minY, before25 = row25.frame.minY, oldHeight = group.frame.height
        retry.tap()
        XCTAssertTrue(element(app, "history-loading").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "history-loading").waitForNonExistence(timeout: 10))
        XCTAssertTrue(row24.isHittable); XCTAssertTrue(row25.isHittable)
        XCTAssertGreaterThan(group.frame.height, oldHeight + 30)
        XCTAssertEqual(row24.frame.minY, before24, accuracy: 5, "Existing expanded tool must stay at the same pixel position")
        XCTAssertEqual(row25.frame.minY, before25, accuracy: 5, "The older rows must not push existing tools down")
        XCTAssertEqual(tool.value as? String, "Expanded")
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Expanded tools retain existing row positions after prepend"; capture.lifetime = .keepAlways; add(capture)
    }
    func testErrorRequiresRetryAndPrependPreservesToolAnchorAndNextDraft() {
        let app = launch(error: true)
        let field = element(app, "nativeComposer")
        field.tap(); field.typeText("Separate next draft")
        scrollToHistory(app, until: "history-retry")
        let retry = app.buttons["history-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "history-loading").exists)
        let group = element(app, "tool-group-24")
        XCTAssertTrue(group.exists); XCTAssertTrue(group.isHittable)
        let beforeY = group.frame.minY
        retry.tap()
        XCTAssertTrue(element(app, "history-loading").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "history-loading").waitForNonExistence(timeout: 10))
        XCTAssertTrue(group.exists); XCTAssertTrue(group.isHittable)
        XCTAssertEqual(group.frame.minY, beforeY, accuracy: 5, "Prepending tools must keep the same visible group and pixel offset")
        XCTAssertFalse(app.buttons["history-retry"].exists)
        XCTAssertEqual(field.value as? String, "Separate next draft")
        XCTAssertFalse(element(app, "chat-message-35").isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Synthetic older-history tool anchor after retry"; capture.lifetime = .keepAlways; add(capture)
    }
}
