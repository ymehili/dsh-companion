import XCTest

final class T3LifecycleSettingsTests: XCTestCase {
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-native-ui-fixture"] + flags; app.launch()
        XCTAssertTrue(app.buttons["session-fixture-native"].waitForExistence(timeout: 10)); return app
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = title; item.lifetime = .keepAlways; add(item)
    }
    private func settings(_ app: XCUIApplication) { app.buttons["sidebar-settings-button"].tap() }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 { if element.isHittable { return }; app.swipeUp() }
    }
    func testExplicitPinAndUndoUseSyntheticLifecycle() {
        let app = launch(); let row = app.buttons["session-fixture-native"]
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 5)); app.buttons["Pin"].tap()
        let undo = app.buttons["lifecycle-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        capture(app, "Explicit synthetic thread pin with versioned Undo")
        undo.tap()
        XCTAssertTrue(app.buttons["session-fixture-native"].waitForExistence(timeout: 5))
    }
    func testBasicSettingsKeepOnlyCoreRoutesInSyntheticService() {
        let app = launch(); settings(app)
        for identifier in ["settings-providers", "settings-server", "settings-schedules"] {
            XCTAssertFalse(app.buttons[identifier].exists)
        }
        for title in ["Server", "Providers and accounts", "Server settings", "Schedules"] {
            XCTAssertFalse(app.staticTexts[title].exists)
        }

        app.buttons["settings-connection"].tap()
        XCTAssertTrue(app.buttons["settings-reconnect"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings-reconnect"].isEnabled)
        XCTAssertFalse(app.buttons["settings-pair"].isEnabled)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let appearance = app.buttons["settings-appearance"]; reveal(appearance, in: app); appearance.tap()
        XCTAssertTrue(app.buttons["appearance-system"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearance-system"].isSelected)
        app.buttons["appearance-dark"].tap()
        XCTAssertTrue(app.buttons["appearance-dark"].isSelected)
        app.buttons["appearance-system"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let followups = app.buttons["settings-followups"]; reveal(followups, in: app); followups.tap()
        XCTAssertTrue(app.buttons["followup-steer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["followup-steer"].isSelected)
        app.buttons["followup-queue"].tap()
        XCTAssertTrue(app.buttons["followup-queue"].isSelected)
        app.buttons["followup-steer"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let projects = app.buttons["settings-projects"]; reveal(projects, in: app); projects.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let about = app.buttons["settings-about"]; reveal(about, in: app); about.tap()
        XCTAssertTrue(app.buttons["settings-licenses"].waitForExistence(timeout: 5))
        app.buttons["settings-licenses"].tap()
        XCTAssertTrue(app.navigationBars["Third-party licenses"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "MIT License")).firstMatch.exists)
        capture(app, "Basic DSH settings retain full bundled third-party licenses")
    }
    func testInlineAndModalQuestionShareAnswersAndKeepComposerDraft() {
        let app = launch(["-native-question-fixture", "-native-question-retry-fixture", "-native-question-draft-fixture"])
        app.buttons["session-fixture-native"].tap()
        let collapse = app.buttons["inline-question-collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5)); collapse.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "nativeComposer").firstMatch
        XCTAssertFalse(composer.exists) // T3 question bar continues to own the slot.
        app.buttons["Session actions"].tap(); app.buttons["Questions (1)"].tap()
        let first = app.buttons["question-option-direction-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        let detail = app.buttons["question-option-details-0"]; reveal(detail, in: app); detail.tap()
        let submit = app.buttons["question-submit"]; reveal(submit, in: app); XCTAssertTrue(submit.isEnabled); submit.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "choices are retained")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(first.isSelected)
        reveal(submit, in: app); submit.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5)); XCTAssertTrue((composer.value as? String ?? "").contains("Keep my separate draft"))
        capture(app, "Question answers sent without losing the separate conversation draft")
    }
}
