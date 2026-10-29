import Foundation
import XCTest

@MainActor
final class NewSessionFlowTests: FixtureFlowTestSupport {
    func testReturnsToNewChatAfterLongBackground() async throws {
        try await postFixture("/fixture/clear-approvals")
        let app = launch(resumeNewChatAfterSeconds: 2)
        defer { app.terminate() }

        let session = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(session.waitForExistence(timeout: 30), "Fixture session did not load")
        session.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
                .waitForExistence(timeout: 20),
            "Fixture session did not open"
        )

        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(3))
        app.activate()

        XCTAssertTrue(
            app.staticTexts["new-session-greeting"].waitForExistence(timeout: 15),
            "Returning after the threshold did not open New session"
        )
    }

    func testPendingApprovalStaysOnSessionAfterLongBackground() async throws {
        try await postFixture("/fixture/terminal-approvals")
        let app = launch(resumeNewChatAfterSeconds: 2)
        defer { app.terminate() }

        let session = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(session.waitForExistence(timeout: 30), "Fixture session did not load")
        session.tap()
        let approval = app.buttons["approval-pull-up-agentic-uw-allow"]
        XCTAssertTrue(approval.waitForExistence(timeout: 20), "Fixture approval did not load")

        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(3))
        app.activate()

        XCTAssertTrue(approval.waitForExistence(timeout: 15), "Pending approval session did not remain open")
        XCTAssertFalse(app.staticTexts["new-session-greeting"].exists, "Pending approval was replaced by New session")
    }

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
        addScreenshot(named: "new-session-created-session")
    }

    func testNewSessionClaudeStyleGreetingComposerAndDefaultAgent() async throws {
        let app = launch()
        openNewSession(app)

        let greeting = app.staticTexts["new-session-greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 15), "New session greeting did not load")
        XCTAssertTrue(
            greeting.label.contains(", Alex") || greeting.label == "Hello, night owl",
            "Greeting did not use the fixture owner name: \(greeting.label)"
        )

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
        addScreenshot(named: "new-session-list-after-back")
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

    func testSleepingRowWakesAndOpensSession() async throws {
        let app = launch()
        try await postFixture("/fixture/sleeping-seed")
        revealRecents(in: app)
        let recents = app.staticTexts["Recents"]
        XCTAssertTrue(recents.waitForExistence(timeout: 30), "Recents section did not load")
        addScreenshot(named: "sessions-recents")
        let row = app.buttons["sleeping-session-sleeping-dune"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Sleeping session row did not load")
        row.tap()

        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Woken session did not open")
        XCTAssertEqual(title.label, "Sleeping Dune")
    }

    func testSleepingRowShowsHistoryWhileWakeIsHeld() async throws {
        let app = launch()
        try await postFixture("/fixture/sleeping-seed")
        try await setWakeBehaviour(delayMs: 3_000)
        revealRecents(in: app)
        let row = app.buttons["sleeping-session-sleeping-dune"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Sleeping session row did not load")
        row.tap()

        let reply = app.staticTexts["I found a short list of IMAX sessions and left the final choice to you."]
        XCTAssertTrue(reply.waitForExistence(timeout: 1.5), "Sleeping transcript did not open before wake completed")
        let waking = app.descendants(matching: .any).matching(identifier: "session-waking").firstMatch
        let visibleDeadline = Date().addingTimeInterval(0.8)
        while !reply.isHittable && Date() < visibleDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(reply.isHittable, "Sleeping transcript row was not visible during the held wake")
        XCTAssertTrue(waking.exists, "Wake did not remain in progress after the sleeping transcript opened")
        addScreenshot(named: "wake-open-held")

        let composer = app.textFields["composer-text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Composer did not stay visible while waking")
        let send = app.buttons["composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send button did not appear while waking")
        XCTAssertFalse(send.isEnabled, "Send was enabled before the session became live")

        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send button did not remain available after wake")
        composer.tap()
        composer.typeText("Wake test")
        XCTAssertTrue(send.isEnabled, "Send did not become enabled after wake")
        XCTAssertEqual(reply.label, "I found a short list of IMAX sessions and left the final choice to you.")
        addScreenshot(named: "wake-open-live")
    }

    func testSleepingRowCopiesAttachCommand() async throws {
        let app = launch()
        try await postFixture("/fixture/sleeping-seed")
        revealRecents(in: app)
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

    private func revealRecents(in app: XCUIApplication) {
        let recents = app.staticTexts["Recents"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 where !recents.exists {
            list.swipeUp()
        }
    }

    private func enterPrompt(_ text: String, in app: XCUIApplication) {
        let prompt = app.textFields["new-session-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "New session prompt did not load")
        prompt.tap()
        prompt.typeText(text)
    }

    private func setWakeBehaviour(delayMs: Int) async throws {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        let url = try XCTUnwrap(URL(string: "\(value)/fixture/wake-behaviour"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["delayMs": delayMs])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "WakeOpenFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "fixture request failed"])
        }
    }

    private func getFixtureJSON(path: String) async throws -> [String: Any] {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        let url = try XCTUnwrap(URL(string: "\(value)\(path)"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func launch(resumeNewChatAfterSeconds: TimeInterval? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        if let resumeNewChatAfterSeconds {
            app.launchArguments += ["-CCResumeNewChatAfterSeconds", String(resumeNewChatAfterSeconds)]
        }
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
        XCTAssertTrue(app.buttons["new-session-send"].waitForExistence(timeout: 15), "New session screen did not open")
        XCTAssertTrue(app.staticTexts["new-session-title"].waitForExistence(timeout: 15), "New session title did not load")
        XCTAssertFalse(app.buttons["Cancel"].exists, "Embedded new session showed a Cancel button")
        XCTAssertTrue(app.buttons["new-session-folder"].waitForExistence(timeout: 15), "New session folder chip did not load")
    }
}
