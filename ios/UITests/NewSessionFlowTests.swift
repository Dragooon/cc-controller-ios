import XCTest

@MainActor
final class NewSessionFlowTests: FixtureFlowTestSupport {
    func testNewSessionCreateOpensSession() throws {
        let app = launch()
        openNewSession(app)
        addScreenshot(named: "new-session-default")

        let folder = app.buttons["new-session-folder-new-project-0"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "New session folder did not load")
        folder.tap()
        app.buttons["new-session-create"].tap()

        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Created session did not open")
        XCTAssertEqual(title.label, "new-project-0")
    }

    func testNewSessionUntrustedFolderError() async throws {
        let app = launch()
        openNewSession(app)
        try await postFixture("/fixture/new-session-error/untrusted_folder")
        app.buttons["new-session-create"].tap()

        let error = app.staticTexts["Open this folder in a terminal once and accept the trust prompt, then try again."]
        XCTAssertTrue(error.waitForExistence(timeout: 15), "Untrusted folder error did not appear inline")
        addScreenshot(named: "new-session-error")
        XCTAssertTrue(app.buttons["new-session-create"].isEnabled, "Create form did not stay editable after the error")
    }

    func testNewSessionOtherFolderPathEntry() throws {
        let app = launch()
        openNewSession(app)
        for _ in 0..<8 { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(app.buttons["new-session-other-folder"].waitForExistence(timeout: 10), "Other folder option did not load")
        app.buttons["new-session-other-folder"].tap()
        for _ in 0..<2 { app.collectionViews.firstMatch.swipeUp() }
        let path = app.textFields["new-session-other-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 10), "Other folder path field did not appear")
        path.tap()
        path.typeText("/tmp")
        XCTAssertEqual(path.value as? String, "/tmp")
        addScreenshot(named: "new-session-other-folder")
    }

    func testAsleepRowWakesAndOpensSession() throws {
        let app = launch()
        revealAsleep(in: app)
        let asleep = app.staticTexts["Asleep"]
        XCTAssertTrue(asleep.waitForExistence(timeout: 30), "Asleep section did not load")
        addScreenshot(named: "sessions-asleep")
        let row = app.buttons["sleeping-session-sleeping-dune"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Sleeping session row did not load")
        row.tap()

        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Woken session did not open")
        XCTAssertEqual(title.label, "Sleeping Dune")
    }

    func testAsleepRowCopiesAttachCommand() throws {
        let app = launch()
        revealAsleep(in: app)
        let row = app.buttons["sleeping-session-sleeping-dune"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Sleeping session row did not load")
        row.press(forDuration: 1)
        let copy = app.buttons["Copy attach command"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "Attach command context menu item did not appear")
        copy.tap()
    }

    func testBackgroundSessionInspectorShowsOpenOnMac() throws {
        let app = launch()
        openNewSession(app)
        app.buttons["new-session-create"].tap()
        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Created background session did not open")
        app.buttons["session-info"].tap()
        for _ in 0..<4 { app.swipeUp() }

        let row = app.buttons["inspector-open-on-mac"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Open on Mac inspector row did not load")
        XCTAssertTrue(row.label.contains("Open on Mac"))
        addScreenshot(named: "inspector-open-on-mac")
        row.tap()
    }

    private func revealAsleep(in app: XCUIApplication) {
        let asleep = app.staticTexts["Asleep"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 where !asleep.exists {
            list.swipeUp()
        }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        if let colorScheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !colorScheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", colorScheme]
        }
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func openNewSession(_ app: XCUIApplication) {
        let button = app.buttons["new-session"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "New session toolbar button did not load")
        button.tap()
        XCTAssertTrue(app.navigationBars["New session"].waitForExistence(timeout: 15), "New session sheet did not open")
        XCTAssertTrue(app.buttons["new-session-create"].waitForExistence(timeout: 15), "New session create button did not load")
        XCTAssertTrue(app.buttons["new-session-folder-new-project-0"].waitForExistence(timeout: 15), "New session folders did not load")
    }

}
