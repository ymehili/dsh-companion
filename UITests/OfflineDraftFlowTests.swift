import XCTest

/// Synthetic local drafts only. No live Mac, network setup, Send, or retry actions.
final class OfflineDraftFlowTests: XCTestCase {
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-native-ui-fixture"] + flags
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func localDraft(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "local-draft-")).firstMatch
    }

    func testCancelNewTaskSavesLocallyAndResumesWithoutSending() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["New chat"].waitForExistence(timeout: 10))
        app.tabBars.buttons["New chat"].tap()
        let project = app.buttons["new-thread-default-workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "nativeComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let text = "Keep this unsent iPhone project draft"
        composer.tap()
        composer.typeText(text)
        app.buttons["new-thread-cancel"].tap()

        let draft = localDraft(app)
        XCTAssertTrue(draft.waitForExistence(timeout: 5), "Cancel returns Home with a separate iPhone draft row")
        XCTAssertTrue(app.staticTexts["local-drafts-section"].exists)
        let sid = String(draft.identifier.dropFirst("local-draft-".count))
        XCTAssertFalse(app.buttons["session-\(sid)"].exists, "Unsent local task must not also appear in Mac shelves")
        capture(app, "Core release — saved offline draft on the iPhone")
        draft.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue((composer.value as? String ?? "").contains(text))
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    func testOrphanDraftEditsLocallyWithoutSendingOrCreatingAMacSession() {
        let app = launch(["-native-offline-draft-fixture"])
        let row = app.buttons["local-draft-fixture-offline-draft"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let text = app.textViews["offline-draft-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String ?? "").contains("Saved offline draft"))
        capture(app, "Core release — offline editor and original unconfirmed request")
        text.tap(); text.typeText(" — edited on this iPhone")
        XCTAssertFalse(app.buttons["Send"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "fixture-unconfirmed-request")).firstMatch.exists)
        app.buttons["offline-draft-done"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String ?? "").contains("edited on this iPhone"))
    }

    func testLocalDiscardRequiresConfirmationAndLeavesMacRowUnchanged() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["New chat"].waitForExistence(timeout: 10))
        app.tabBars.buttons["New chat"].tap()
        let project = app.buttons["new-thread-default-workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "nativeComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Do not discard without asking")
        app.buttons["new-thread-cancel"].tap()
        let draft = localDraft(app)
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.swipeLeft()
        let discard = app.buttons["Discard local draft…"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Only this iPhone’s draft, photos")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mac conversation and any delivered message stay unchanged")).firstMatch.exists)
        cancel.tap()
        XCTAssertTrue(draft.exists)
        draft.swipeLeft()
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        let confirm = app.buttons["Discard local draft"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(draft.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["session-fixture-native"].exists, "Discard must not delete the Mac conversation")
    }
}
