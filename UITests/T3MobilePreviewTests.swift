import XCTest

/// Integrated synthetic-data previews; never points at a real Mac session.
final class T3MobilePreviewTests: XCTestCase {
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-native-ui-fixture"] + flags; app.launch(); return app
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
    func testT3ThreadsAndSettingsFlow() {
        let app = launch()
        XCTAssertTrue(app.buttons["session-fixture-native"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["New chat"].exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        capture(app, "T3-derived DSH native Threads home")
        app.buttons["sidebar-settings-button"].tap()
        XCTAssertTrue(app.buttons["settings-appearance"].waitForExistence(timeout: 5))
        capture(app, "T3-derived DSH grouped settings sheet")
        app.buttons["settings-appearance"].tap()
        XCTAssertTrue(app.buttons["appearance-system"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearance-dark"].exists)
    }
    func testT3NewThreadChoosesWorkspaceAndRetainsTypedDraft() {
        let app = launch(); XCTAssertTrue(app.tabBars.buttons["New chat"].waitForExistence(timeout: 10))
        app.tabBars.buttons["New chat"].tap()
        let workspace = app.buttons["new-thread-default-workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5)); capture(app, "T3-derived choose project sheet")
        workspace.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "nativeComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        capture(app, "T3-derived new thread draft before sending")
        composer.tap(); composer.typeText("Keep this unsent project draft")
        app.buttons["new-thread-cancel"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'local-draft-'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue((composer.value as? String ?? "").contains("Keep this unsent project draft"))
    }
    func testT3ConversationKeyboardAndNativeBack() {
        let app = launch(); let thread = app.buttons["session-fixture-native"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10)); thread.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "nativeComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        capture(app, "T3-derived DSH conversation compact composer")
        composer.tap(); composer.typeText("Explain this change before editing")
        capture(app, "T3-derived DSH expanded composer and keyboard")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.4)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.4)))
        XCTAssertTrue(app.buttons["session-fixture-native"].waitForExistence(timeout: 5))
    }
    func testT3ConversationDarkPreview() {
        let app = launch(["-native-dark-fixture"])
        let thread = app.buttons["session-fixture-native"]; XCTAssertTrue(thread.waitForExistence(timeout: 10)); thread.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nativeComposer").firstMatch.waitForExistence(timeout: 5))
        capture(app, "T3-derived DSH dark conversation")
    }
}
