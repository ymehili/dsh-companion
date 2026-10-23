import XCTest

/// All screens run with in-memory synthetic services. No host files, shells,
/// queue mutations or model requests are exercised by these integrated cases.
final class T3ToolFlowTests: XCTestCase {
    private func open() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-native-ui-fixture"]; app.launch()
        let thread = app.buttons["session-fixture-native"]; XCTAssertTrue(thread.waitForExistence(timeout: 10)); thread.tap()
        XCTAssertTrue(app.buttons["Session actions"].waitForExistence(timeout: 5)); return app
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }
    func testNativeFilesTextPagingAndImagePreview() {
        let app = open(); app.buttons["thread-files-action"].tap()
        let readme = app.staticTexts["README.md"]; XCTAssertTrue(readme.waitForExistence(timeout: 5))
        capture(app, "T3-derived native workspace Files")
        readme.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "files-source").firstMatch.waitForExistence(timeout: 5))
        capture(app, "T3-derived native source preview")
        back(app)
        let image = app.staticTexts["Preview.png"]; XCTAssertTrue(image.waitForExistence(timeout: 5)); image.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "files-native-preview").firstMatch.waitForExistence(timeout: 8))
        capture(app, "Authorized synthetic image in native QuickLook")
    }
    func testNativeVTTerminalUsesOnlySyntheticShell() {
        let app = open(); app.buttons["thread-terminal-action"].tap()
        let demo = app.buttons["terminal-open-fixture-terminal"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5)); demo.tap()
        // The SwiftUI surface id is on SwiftTerm's real UITextInput view; do not
        // replace its native VoiceOver tree with an artificial test element.
        XCTAssertTrue(app.textViews["terminal-surface"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertFalse(app.staticTexts["Terminal renderer unavailable"].exists)
        XCTAssertTrue(app.staticTexts["DEMO · synthetic terminal · no host commands"].exists)
        capture(app, "Real native VT terminal with synthetic transport")
    }
    func testQueuedMessageEditStaysInQueue() {
        let app = open(); app.buttons["Session actions"].tap(); app.buttons["Queued messages"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "queue-row-fixture-queue-1").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); capture(app, "T3-derived queued and steering messages")
        row.press(forDuration: 1)
        app.buttons["Edit"].tap()
        let field = app.textViews["Queued message text"]; XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(" Include accessibility.")
        capture(app, "Editing one synthetic queued message without sending chat")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Include accessibility.")).firstMatch.waitForExistence(timeout: 5))
    }
    func testReviewLineCommentAppendsOnlyToConversationDraft() {
        let app = open(); app.buttons["Session actions"].tap(); app.buttons["Review changes"].tap()
        let file = app.buttons["review-file-0"]; XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        let line = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Old line")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5)); capture(app, "T3-derived recorded turn change review")
        line.tap()
        let comment = app.textViews["review-comment-text"]; XCTAssertTrue(comment.waitForExistence(timeout: 5))
        comment.tap(); comment.typeText("Please simplify this change before sending.")
        app.buttons["review-add-to-draft"].tap()
        XCTAssertTrue(app.staticTexts["review-added-confirmation"].waitForExistence(timeout: 5))
        back(app)
        let composer = app.descendants(matching: .any).matching(identifier: "nativeComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue((composer.value as? String ?? "").contains("Please simplify this change before sending."))
    }
}
