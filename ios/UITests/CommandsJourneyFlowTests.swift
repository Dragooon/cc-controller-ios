import XCTest

/// Everything the composer's commands do, in one launch of one session on the folded Duo.
@MainActor
final class CommandsJourneyFlowTests: XCTestCase {
    private let noRouteMessage = "Commands need the cc-controller plugin in this session. Run /reload-plugins in its terminal"

    override func setUp() async throws {
        try await super.setUp()
        try await restartFixtureIfConfigured()
    }

    func testCommandsJourney() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL"), "-CCResetCache"]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        defer { app.terminate() }

        let row = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(row.waitToExist(timeout: 75), "Fixture session did not load")
        row.tap()
        let field = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(field.waitToExist(timeout: 20), "Composer did not load")

        // Suggestions match what's typed and fill the composer.
        field.tap()
        field.typeText("/co")
        let compact = suggestion("/compact", in: app)
        XCTAssertTrue(compact.waitToExist(timeout: 10), "/compact suggestion did not load")
        XCTAssertTrue(suggestion("/cost", in: app).exists, "/cost suggestion did not load")
        XCTAssertFalse(suggestion("/clear", in: app).exists, "/clear must not match /co")
        XCTAssertTrue(waitForStableFrame(compact), "/compact suggestion did not settle before tap")
        compact.tap()
        XCTAssertEqual(field.value as? String, "/compact ", "Suggestion did not replace the composer text")
        emptyComposer(field)

        // The model sheet shows the current model and sends the choice.
        openModelSheet(field: field, in: app)
        XCTAssertTrue(app.images["current-model-claude-fable-5-1[1m]"].waitToExist(timeout: 10), "Current model was not checked")
        XCTAssertFalse(app.images["current-model-claude-fable-5-2[1m]"].exists, "Fable 5.2 was incorrectly checked")
        app.buttons["model-option-claude-fable-5-2[1m]"].tap()
        XCTAssertTrue(app.navigationBars["Model"].waitToDisappear(timeout: 10), "Model sheet did not dismiss")
        let requests = try await commandRequests()
        XCTAssertTrue(requests.contains("/model claude-fable-5-2[1m]"), "Selected model was not sent: \(requests)")

        // With no command route, a model change fails inside the sheet.
        try await postFixture("/fixture/command-no-route")
        openModelSheet(field: field, in: app)
        XCTAssertTrue(app.images["current-model-claude-fable-5-2[1m]"].waitToExist(timeout: 10), "Checkmark did not follow the selection")
        app.buttons["model-option-claude-fable-5-1[1m]"].tap()
        let inlineError = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", noRouteMessage)).firstMatch
        XCTAssertTrue(inlineError.waitToExist(timeout: 10), "Model selection error did not render inline")
        XCTAssertTrue(app.navigationBars["Model"].exists, "Model sheet dismissed after the failure")
        app.navigationBars["Model"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Model"].waitToDisappear(timeout: 10), "Model sheet did not close")

        // Any other command without a route shows an alert.
        send("/context", field: field, in: app)
        let alert = app.alerts["Commands unavailable"]
        XCTAssertTrue(alert.waitToExist(timeout: 10), "No-route alert did not appear")
        alert.buttons["OK"].tap()
        emptyComposer(field)

        // A queued command shows a toast.
        try await postFixture("/fixture/command-queued")
        send("/compact", field: field, in: app)
        let toast = app.descendants(matching: .any)
            .matching(identifier: "command-toast")
            .matching(NSPredicate(format: "label CONTAINS %@", "Runs when the current turn ends."))
            .firstMatch
        XCTAssertTrue(toast.waitToExist(timeout: 10), "Queued command toast did not appear")

        // A command's output opens its own sheet, with the keyboard out of the way.
        try await postFixture("/fixture/command-output")
        send("/context", field: field, in: app)
        XCTAssertTrue(app.navigationBars["/context"].waitToExist(timeout: 10), "Output sheet did not open")
        XCTAssertEqual(app.keyboards.count, 0, "Keyboard stayed up over the output sheet")
        XCTAssertTrue(app.staticTexts["Context use: 42%"].waitToExist(timeout: 10), "Command output did not render")
        app.buttons["Done"].tap()

        // /clear moves to the new session ID and stays on screen.
        send("/clear", field: field, in: app)
        let selectedSession = app.staticTexts["selected-session-name"]
        XCTAssertTrue(
            pollUntil(timeout: 10) { selectedSession.value as? String == "pull-up-agentic-uw-cleared" },
            "Session screen did not follow the rotated session ID"
        )
        XCTAssertTrue(pollUntil(timeout: 10) { field.value as? String == "" }, "Composer was not empty after /clear")
    }

    private func suggestion(_ command: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "\(command),")).firstMatch
    }

    private func openModelSheet(field: XCUIElement, in app: XCUIApplication) {
        field.tap()
        field.typeText("/mo")
        let model = suggestion("/model", in: app)
        XCTAssertTrue(waitForStableFrame(model), "Model suggestion did not settle before tap")
        model.tap()
        XCTAssertTrue(app.navigationBars["Model"].waitToExist(timeout: 10), "Model sheet did not open")
    }

    private func send(_ text: String, field: XCUIElement, in app: XCUIApplication) {
        field.tap()
        field.typeText(text)
        let send = app.buttons["composer-send"]
        if send.exists {
            send.tap()
        } else {
            app.buttons["composer-queue"].tap()
        }
    }

    private func emptyComposer(_ field: XCUIElement) {
        let length = (field.value as? String)?.count ?? 0
        guard length > 0 else { return }
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length))
    }

    private func postFixture(_ path: String) async throws {
        var request = URLRequest(url: URL(string: requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL") + path)!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Fixture route \(path) failed")
    }

    private func commandRequests() async throws -> [String] {
        let base = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(base)/fixture/command-requests")!)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let requests = value?["requests"] as? [[String: Any]] ?? []
        return requests.compactMap { $0["text"] as? String }
    }
}
