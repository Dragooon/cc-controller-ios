import XCTest

@MainActor
final class AppCommandsFlowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try await restartFixtureIfConfigured()
    }

    func testRenameSuggestionFillsComposer() throws {
        let app = launchFixture()
        defer { app.terminate() }
        openSession(id: "session-pull-up-agentic-uw", in: app)

        let field = composerField(in: app)
        field.tap()
        field.typeText("/re")
        let rename = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] '/rename,'")).firstMatch
        XCTAssertTrue(rename.waitToExist(timeout: 10), "Rename suggestion did not load")
        XCTAssertTrue(waitForStableFrame(rename), "Rename suggestion frame did not stabilize before tap")
        rename.tap()

        XCTAssertEqual(field.value as? String, "/rename ")
    }

    func testModelSheetSendsSelectedModel() async throws {
        let app = launchFixture()
        defer { app.terminate() }
        openSession(id: "session-pull-up-agentic-uw", in: app)

        let field = composerField(in: app)
        field.tap()
        field.typeText("/mo")
        let modelSuggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] '/model,'")).firstMatch
        XCTAssertTrue(modelSuggestion.waitToExist(timeout: 10), "Model suggestion did not load")
        XCTAssertTrue(waitForStableFrame(modelSuggestion), "Model suggestion frame did not stabilize before tap")
        modelSuggestion.tap()

        XCTAssertTrue(app.navigationBars["Model"].waitToExist(timeout: 10), "Model sheet did not open")
        let firstOption = app.buttons["model-option-claude-fable-5-1[1m]"]
        let secondOption = app.buttons["model-option-claude-fable-5-2[1m]"]
        XCTAssertTrue(firstOption.waitToExist(timeout: 10), "First model option did not load")
        XCTAssertTrue(app.images["current-model-claude-fable-5-1[1m]"].exists, "Current model checkmark was not on Fable 5.1")
        XCTAssertFalse(app.images["current-model-claude-fable-5-2[1m]"].exists, "Fable 5.2 was incorrectly checked")
        addScreenshot(named: "model-sheet")
        secondOption.tap()
        XCTAssertTrue(app.navigationBars["Model"].waitToDisappear(timeout: 10), "Model sheet did not dismiss")

        let requests = try await commandRequests()
        XCTAssertTrue(requests.contains { $0.text == "/model claude-fable-5-2[1m]" }, "Selected model was not sent: \(requests)")

        field.tap()
        field.typeText("/mo")
        let reopenedModelSuggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] '/model,'")).firstMatch
        XCTAssertTrue(waitForStableFrame(reopenedModelSuggestion), "Reopened model suggestion frame did not stabilize before tap")
        reopenedModelSuggestion.tap()
        XCTAssertTrue(app.navigationBars["Model"].waitToExist(timeout: 10), "Model sheet did not reopen")
        XCTAssertTrue(app.images["current-model-claude-fable-5-2[1m]"].waitToExist(timeout: 10), "Current model checkmark did not move to Fable 5.2")
        addScreenshot(named: "model-sheet-after-select")
    }

    func testModelSelectionFailureShowsInlineError() async throws {
        let app = launchFixture()
        defer { app.terminate() }
        try await postFixture("/fixture/command-no-route")
        openSession(id: "session-pull-up-agentic-uw", in: app)

        let field = composerField(in: app)
        field.tap()
        field.typeText("/mo")
        let modelSuggestion = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] '/model,'")).firstMatch
        XCTAssertTrue(waitForStableFrame(modelSuggestion), "Model suggestion frame did not stabilize before tap")
        modelSuggestion.tap()
        XCTAssertTrue(app.navigationBars["Model"].waitToExist(timeout: 10), "Model sheet did not open")
        app.buttons["model-option-claude-fable-5-2[1m]"].tap()

        let error = app.staticTexts["Commands need the cc-controller plugin in this session. Run /reload-plugins in its terminal, or restart it."]
        XCTAssertTrue(error.waitToExist(timeout: 10), "Model selection error did not render inline")
        XCTAssertTrue(app.navigationBars["Model"].exists, "Model sheet dismissed after selection failure")
        addScreenshot(named: "model-sheet-error")
    }

    func testCommandOutputShowsOutputSheet() throws {
        let app = launchFixture()
        defer { app.terminate() }
        openSession(id: "session-pull-up-agentic-uw", in: app)

        let field = composerField(in: app)
        field.tap()
        field.typeText("/context")
        tapSend(in: app)

        XCTAssertTrue(app.navigationBars["/context"].waitToExist(timeout: 10), "Output sheet did not open")
        XCTAssertEqual(app.keyboards.count, 0, "Keyboard remained visible over the output sheet")
        XCTAssertTrue(app.staticTexts["Context use: 42%"].waitToExist(timeout: 10), "Command output did not render")
        addScreenshot(named: "command-output-sheet")
        app.buttons["Done"].tap()
    }

    func testQueuedCommandShowsToast() async throws {
        let app = launchFixture()
        defer { app.terminate() }
        try await postFixture("/fixture/command-queued")
        openSession(id: "session-pull-up-agentic-uw", in: app)

        let field = composerField(in: app)
        field.tap()
        field.typeText("/compact")
        tapSend(in: app)

        // One query for the toast and its text: it can time out between two separate ones.
        let toast = app.descendants(matching: .any)
            .matching(identifier: "command-toast")
            .matching(NSPredicate(format: "label CONTAINS %@", "Runs when the current turn ends."))
            .firstMatch
        XCTAssertTrue(toast.waitToExist(timeout: 10), "Queued command toast did not appear")
        addScreenshot(named: "command-queued-toast")
    }

    func testCommandWithoutRouteShowsAlert() async throws {
        let app = launchFixture()
        defer { app.terminate() }
        try await postFixture("/fixture/command-no-route")
        openSession(id: "session-pull-up-agentic-uw", in: app)

        let field = composerField(in: app)
        field.tap()
        field.typeText("/context")
        tapSend(in: app)

        let alert = app.alerts["Commands unavailable"]
        XCTAssertTrue(alert.waitToExist(timeout: 10), "No-route alert did not appear")
        XCTAssertTrue(alert.staticTexts["Commands need the cc-controller plugin in this session. Run /reload-plugins in its terminal, or restart it."].exists)
        addScreenshot(named: "commands-unavailable-alert")
        alert.buttons["OK"].tap()
    }

    func testClearKeepsScreenOpenOnRotatedSession() async throws {
        let app = launchFixture()
        defer { app.terminate() }
        openSession(id: "session-pull-up-agentic-uw", in: app)

        let field = composerField(in: app)
        field.tap()
        field.typeText("/clear")
        tapSend(in: app)

        let selectedSession = app.staticTexts["selected-session-name"]
        XCTAssertTrue(
            pollUntil(timeout: 10) { selectedSession.value as? String == "pull-up-agentic-uw-cleared" },
            "Session screen did not follow the rotated session id"
        )
        XCTAssertTrue(waitForValue(of: composerField(in: app), equalTo: "", timeout: 10), "Composer was not empty after clear")
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL"), "-CCResetCache"]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func openSession(id: String, in app: XCUIApplication) {
        let row = app.buttons[id]
        XCTAssertTrue(row.waitToExist(timeout: 75), "Fixture session \(id) did not load")
        row.tap()
        XCTAssertTrue(composerField(in: app).waitToExist(timeout: 20), "Composer did not load")
    }

    private func composerField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
    }

    private func tapSend(in app: XCUIApplication) {
        let send = app.buttons["composer-send"]
        if send.exists {
            send.tap()
        } else {
            app.buttons["composer-queue"].tap()
        }
    }

    private func postFixture(_ path: String) async throws {
        let base = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        var request = URLRequest(url: URL(string: "\(base)\(path)")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func commandRequests() async throws -> [(sessionID: String, text: String)] {
        let base = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        let (data, response) = try await URLSession.shared.data(from: URL(string: "\(base)/fixture/command-requests")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let requests = value?["requests"] as? [[String: Any]] ?? []
        return requests.compactMap { request in
            guard let sessionID = request["sessionID"] as? String, let text = request["text"] as? String else { return nil }
            return (sessionID, text)
        }
    }

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForValue(of element: XCUIElement, equalTo value: String, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) { element.value as? String == value }
    }
}
