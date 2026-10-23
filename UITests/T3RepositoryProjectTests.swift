import XCTest

final class T3RepositoryProjectTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-native-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["session-fixture-native"].waitForExistence(timeout: 10)); return app
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 { if element.isHittable { return }; app.swipeUp() }
    }
    private func openPulls(_ app: XCUIApplication) {
        app.tabBars.buttons["Pulls"].tap()
        let picker = app.buttons["pulls-project-picker"]; XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        app.buttons["Default workspace"].tap()
        app.buttons["pulls-open-project"].tap()
        let load = app.buttons["pulls-explicit-refresh"]; XCTAssertTrue(load.waitForExistence(timeout: 5)); load.tap()
        XCTAssertTrue(app.buttons["pulls-row-42"].waitForExistence(timeout: 5))
    }
    func testProjectRegistrationAndNativeEditor() {
        let app = launch(); app.buttons["sidebar-settings-button"].tap()
        let projects = app.buttons["settings-projects"]; reveal(projects, app: app); projects.tap()
        let add = app.buttons["projects-add"]; XCTAssertTrue(add.waitForExistence(timeout: 5))
        capture(app, "T3-adapted registered Mac projects")
        add.tap()
        let value = app.descendants(matching: .any).matching(identifier: "project-editor-value").firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5)); value.tap(); value.typeText("/synthetic/new-project")
        app.buttons["project-editor-save"].tap()
        XCTAssertTrue(app.staticTexts["new-project"].waitForExistence(timeout: 5))
        capture(app, "Synthetic project registered without creating files or starting an agent")
    }
    func testPullsTabLoadsOnlyExplicitProjectAndShowsDetail() {
        let app = launch(); openPulls(app)
        capture(app, "Native Pull Requests tab and scoped repository list")
        app.buttons["pulls-row-42"].tap()
        XCTAssertTrue(app.buttons["pulls-review-menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Native repository review"].exists)
        capture(app, "Native Pull Request details, files, discussion and review")
        XCTAssertEqual(app.webViews.count, 0)
    }
    func testPullReviewRetainsBodyAcrossExplicitConfirmation() {
        let app = launch(); openPulls(app); app.buttons["pulls-row-42"].tap()
        app.buttons["pulls-review-menu"].tap(); app.buttons["Comment"].tap()
        let body = app.textViews["pulls-action-body"]; reveal(body, app: app); XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.tap(); body.typeText("Synthetic review only; no GitHub account was accessed.")
        let review = app.buttons["pulls-action-review-confirm"]; reveal(review, app: app); review.tap()
        // Native iOS confirmation sheets expose a button and nested label with
        // the same AX id. This is one action, not two confirmation presenters.
        let confirm = app.buttons["repository-confirm-write"].firstMatch; XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture(app, "Explicit version-bound synthetic Pull Request comment confirmation")
        confirm.tap()
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue((body.value as? String ?? "").contains("Synthetic review only"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Submitted for pull request #42")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Close"].tap(); app.buttons["pulls-detail-refresh"].tap()
        let posted = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "comment: Synthetic review only")).firstMatch
        reveal(posted, app: app); XCTAssertTrue(posted.waitForExistence(timeout: 5))
    }
    func testGitDiffCommentOnlyAppendsCapturedDraft() {
        let app = launch(); app.buttons["session-fixture-native"].tap()
        app.buttons["Session actions"].tap(); app.buttons["Git & worktrees"].tap()
        let file = app.buttons["repository-file-unstaged-Sources/Review.swift"]; reveal(file, app: app)
        XCTAssertTrue(file.waitForExistence(timeout: 5)); capture(app, "Native Git index, working tree, branches and worktrees")
        file.tap()
        let line = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'repository-diff-line-' AND label CONTAINS 'new 1' ")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5)); capture(app, "Git working-tree diff with source-bound native line review")
        line.tap()
        let comment = app.textViews["repository-review-comment"]; XCTAssertTrue(comment.waitForExistence(timeout: 5)); comment.tap(); comment.typeText("Keep this Git review context in my draft.")
        app.buttons["repository-add-local-comment"].tap()
        XCTAssertTrue(app.staticTexts["repository-draft-added"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
        let composer = app.descendants(matching: .any).matching(identifier: "nativeComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5)); XCTAssertTrue((composer.value as? String ?? "").contains("Keep this Git review context in my draft."))
    }
}
