import XCTest

/// Explicit human scope: no Git, branches/worktrees or Pull Requests in this app.
final class T3NonGitScopeTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-native-ui-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["session-fixture-native"].waitForExistence(timeout: 10)); return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testNoGitOrPullsEntryPointsAndCoreToolsRemain() {
        let app = launch()
        XCTAssertTrue(app.tabBars.buttons["Threads"].exists)
        XCTAssertFalse(app.tabBars.buttons["Pulls"].exists)
        XCTAssertFalse(app.tabBars.buttons["Pull Requests"].exists)
        capture(app, "DSH native home with Git and Pull Requests excluded")
        app.buttons["session-fixture-native"].tap()
        XCTAssertTrue(app.buttons["Session actions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["thread-files-action"].exists)
        XCTAssertFalse(app.buttons["thread-terminal-action"].exists)
        app.buttons["Session actions"].tap()
        XCTAssertFalse(app.buttons["Git & worktrees"].exists)
        XCTAssertFalse(app.buttons["thread-repository-action"].exists)
        XCTAssertFalse(app.buttons["Create pull request"].exists)
        XCTAssertFalse(app.buttons["Review changes"].exists)
        XCTAssertFalse(app.buttons["thread-review-action"].exists)
        XCTAssertTrue(app.buttons["Queued messages"].exists)
        capture(app, "DSH thread actions without repository or PR controls")
    }
    func testProjectRegistrationIsIndependentOfGit() {
        let app = launch(); app.buttons["sidebar-settings-button"].tap()
        let projects = app.buttons["settings-projects"]
        for _ in 0..<3 { if projects.isHittable { break }; app.swipeUp() }
        projects.tap()
        let add = app.buttons["projects-add"]; XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        let field = app.descendants(matching: .any).matching(identifier: "project-editor-value").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("/synthetic/non-git-project")
        app.buttons["project-editor-save"].tap()
        XCTAssertTrue(app.staticTexts["non-git-project"].waitForExistence(timeout: 5))
    }
}
