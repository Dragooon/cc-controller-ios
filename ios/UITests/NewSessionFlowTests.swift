import Foundation
import XCTest

@MainActor
final class NewSessionFlowTests: FixtureFlowTestSupport {
    func testNewSessionCreateOpensSession() throws {
        let app = launch()
        openNewSession(app)
        addScreenshot(named: "new-session-default")

        app.buttons["new-session-folder"].tap()
        let folder = app.buttons["new-session-folder-new-project-0"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "New session folder did not load")
        folder.tap()
        enterPrompt("Start the project", in: app)
        app.buttons["new-session-send"].tap()

        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Created session did not open")
        XCTAssertEqual(title.label, "new-project-0")
    }

    func testNewSessionClaudeStyleGreetingComposerAndDefaultAgent() async throws {
        let app = launch()
        openNewSession(app)

        let greeting = app.staticTexts["new-session-greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 15), "New session greeting did not load")
        XCTAssertTrue(greeting.label.contains(", Alex"), "Greeting did not use the fixture owner name: \(greeting.label)")

        let prompt = app.textFields["new-session-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "New session prompt did not load")
        XCTAssertTrue(prompt.placeholderValue?.hasPrefix("Chat with") == true, "Prompt placeholder was not Claude-style")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 15), "New session keyboard did not appear")
        let composer = app.descendants(matching: .any).matching(identifier: "new-session-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "New session composer card did not load")
        XCTAssertLessThanOrEqual(abs(composer.frame.maxY - keyboard.frame.minY), 40, "Composer was not attached to the keyboard")
        addScreenshot(named: "new-chat-page-keyboard-up")
        greeting.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10), "New session keyboard did not dismiss")
        addScreenshot(named: "new-chat-page-keyboard-down")
        prompt.tap()

        app.buttons["new-session-agent"].tap()
        let defaultAgent = app.buttons["new-session-agent-default"]
        XCTAssertTrue(defaultAgent.waitForExistence(timeout: 10), "Resolved Default agent menu item did not appear")
        XCTAssertTrue(defaultAgent.label.contains("Default"), "Default menu item had no subtitle: \(defaultAgent.label)")
        XCTAssertFalse(app.buttons["new-session-agent-builder"].exists, "Resolved agent was duplicated in the menu")
        defaultAgent.tap()

        prompt.tap()
        prompt.typeText("Start a Claude-style session")
        app.buttons["new-session-send"].tap()
        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Created session did not open")
        let requests = try await getFixtureJSON(path: "/fixture/create-requests")
        let latest = try XCTUnwrap((requests["requests"] as? [[String: Any]])?.last)
        XCTAssertNil(latest["agent"] as? String, "Default agent should be sent as nil")
    }

    func testNewSessionClaudeStyleScreenshots() throws {
        let app = launch()
        openNewSession(app)
        let greeting = app.staticTexts["new-session-greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 15), "New session greeting did not load")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 15), "New session keyboard did not appear")
        addScreenshot(named: "new-chat-page-screenshot-keyboard-up")
        greeting.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 10), "New session keyboard did not dismiss")
        addScreenshot(named: "new-chat-page-screenshot-keyboard-down")
    }

    func testNewSessionFolderPickerSelectsRecentFolder() throws {
        let app = launch()
        openNewSession(app)
        app.buttons["new-session-folder"].tap()
        let folder = app.buttons["new-session-folder-new-project-1"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "New session folder did not load")
        addScreenshot(named: "new-session-folder-picker")
        folder.tap()
        XCTAssertTrue(app.buttons["new-session-send"].waitForExistence(timeout: 10), "Folder menu did not close")
        XCTAssertTrue(app.buttons["new-session-folder"].label.contains("new-project-1"))
    }

    func testNewSessionUntrustedFolderError() async throws {
        let app = launch()
        openNewSession(app)
        try await postFixture("/fixture/new-session-error/untrusted_folder")
        enterPrompt("Try the untrusted folder", in: app)
        app.buttons["new-session-send"].tap()

        let error = app.staticTexts["Open this folder in a terminal once and accept the trust prompt, then try again."]
        XCTAssertTrue(error.waitForExistence(timeout: 15), "Untrusted folder error did not appear inline")
        addScreenshot(named: "new-session-error")
        XCTAssertTrue(app.buttons["new-session-send"].isEnabled, "Composer did not stay editable after the error")
    }

    func testNewSessionOtherFolderPathEntry() throws {
        let app = launch()
        openNewSession(app)
        app.buttons["new-session-folder"].tap()
        let other = app.buttons["Other folder…"]
        XCTAssertTrue(other.waitForExistence(timeout: 10), "Other folder menu item did not appear")
        other.tap()
        let path = app.textFields["new-session-other-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 10), "Other folder path field did not appear")
        path.tap()
        path.typeText("/tmp")
        XCTAssertEqual(path.value as? String, "/tmp")
        addScreenshot(named: "new-session-other-folder")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["new-session-send"].waitForExistence(timeout: 10), "Other folder sheet did not close")
        XCTAssertTrue(app.buttons["new-session-folder"].label.contains("tmp"))
    }

    func testNewSessionMacCreateSendsFolderAndAgentAndReopensWithValues() async throws {
        let app = launch()
        openNewSession(app)
        app.buttons["new-session-folder"].tap()
        app.buttons["new-session-folder-new-project-1"].tap()
        app.buttons["new-session-agent"].tap()
        let reviewer = app.buttons["new-session-agent-reviewer"]
        XCTAssertTrue(reviewer.waitForExistence(timeout: 10), "Claude reviewer agent did not load")
        reviewer.tap()
        enterPrompt("Review the project", in: app)
        app.buttons["new-session-send"].tap()

        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Created session did not open")
        let requests = try await getFixtureJSON(path: "/fixture/create-requests")
        let latest = try XCTUnwrap((requests["requests"] as? [[String: Any]])?.last)
        XCTAssertTrue((latest["cwd"] as? String)?.hasSuffix("/projects/new-project-1") == true)
        XCTAssertEqual(latest["agent"] as? String, "reviewer")

        let back = app.buttons["BackButton"]
        if back.exists { back.tap() }
        XCTAssertTrue(app.buttons["new-session"].waitForExistence(timeout: 15), "Sessions list did not reappear")
        app.buttons["new-session"].tap()
        XCTAssertTrue(app.buttons["new-session-folder"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["new-session-folder"].label.contains("new-project-1"))
        XCTAssertTrue(app.buttons["new-session-agent"].label.contains("Reviewer"))
        let sendFrame = app.buttons["new-session-send"].frame
        let agentFrame = app.buttons["new-session-agent"].frame
        XCTAssertFalse(sendFrame.intersects(agentFrame), "Send button overlaps the agent chip")
        XCTAssertLessThanOrEqual(
            sendFrame.maxX,
            app.windows.firstMatch.frame.maxX + 24,
            "Send button is not at the trailing edge of the sheet"
        )
    }

    func testAsleepRowWakesAndOpensSession() async throws {
        let app = launch()
        try await postFixture("/fixture/sleeping-seed")
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

    func testAsleepRowCopiesAttachCommand() async throws {
        let app = launch()
        try await postFixture("/fixture/sleeping-seed")
        revealAsleep(in: app)
        let row = app.buttons["sleeping-session-sleeping-dune"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Sleeping session row did not load")
        row.press(forDuration: 1)
        let copy = app.buttons["Copy attach command"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "Attach command context menu item did not appear")
        copy.tap()
    }

    func testEmptySessionsNewSessionButton() async throws {
        try await postFixture("/fixture/clear-sessions")
        let app = launch()
        let emptyButton = app.buttons["empty-new-session"]
        XCTAssertTrue(emptyButton.waitForExistence(timeout: 30), "Empty sessions action did not load")
        emptyButton.tap()
        XCTAssertTrue(app.buttons["new-session-send"].waitForExistence(timeout: 15), "Empty-state New session button did not open the composer")
    }

    func testBackgroundSessionInspectorShowsOpenOnMac() throws {
        let app = launch()
        openNewSession(app)
        enterPrompt("Inspect this session", in: app)
        app.buttons["new-session-send"].tap()
        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Created background session did not open")
        app.buttons["session-info"].tap()
        for _ in 0..<4 { app.swipeUp() }

        let row = app.buttons["inspector-open-on-mac"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Open on Mac inspector row did not load")
        XCTAssertTrue(row.label.contains("Copy attach command"))
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

    private func enterPrompt(_ text: String, in app: XCUIApplication) {
        let prompt = app.textFields["new-session-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "New session prompt did not load")
        prompt.tap()
        prompt.typeText(text)
    }

    private func getFixtureJSON(path: String) async throws -> [String: Any] {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        let url = try XCTUnwrap(URL(string: "\(value)\(path)"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
        XCTAssertTrue(app.buttons["new-session-send"].waitForExistence(timeout: 15), "New session sheet did not open")
        XCTAssertTrue(app.buttons["new-session-folder"].waitForExistence(timeout: 15), "New session folder chip did not load")
    }
}
