import XCTest

/// Everything the composer's commands do, in one launch of one session on the folded Duo.
final class CommandsJourneyFlowTests: JourneyTestCase {
    private let noRouteMessage = "Commands need the cc-controller plugin in this session. Run /reload-plugins in its terminal"

    func testCommandsJourney() async throws {
        let app = launchSignedIn()
        defer { app.terminate() }
        openSession("pull-up-agentic-uw", in: app)
        let field = app.composer
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
        XCTAssertEqual(field.typedText, "/compact ", "Suggestion did not replace the composer text")
        emptyComposer(in: app)

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
        sendComposer("/context", in: app)
        let alert = app.alerts["Commands unavailable"]
        XCTAssertTrue(alert.waitToExist(timeout: 10), "No-route alert did not appear")
        alert.buttons["OK"].tap()
        emptyComposer(in: app)

        // A queued command shows a toast.
        try await postFixture("/fixture/command-queued")
        sendComposer("/compact", in: app)
        let toast = app.element(identifier: "command-toast")
        XCTAssertTrue(
            pollUntil(timeout: 10) { toast.exists && toast.label.contains("Runs when the current turn ends.") },
            "Queued command toast did not appear"
        )

        // A command's output opens its own sheet, with the keyboard out of the way.
        try await postFixture("/fixture/command-output")
        sendComposer("/context", in: app)
        XCTAssertTrue(app.navigationBars["/context"].waitToExist(timeout: 10), "Output sheet did not open")
        XCTAssertEqual(app.keyboards.count, 0, "Keyboard stayed up over the output sheet")
        XCTAssertTrue(app.staticTexts["Context use: 42%"].waitToExist(timeout: 10), "Command output did not render")
        addScreenshot(named: "command-output-sheet")
        app.buttons["Done"].tap()

        // /clear moves to the new session ID and stays on screen.
        sendComposer("/clear", in: app)
        XCTAssertTrue(
            pollUntil(timeout: 10) { app.selectedSessionName.value as? String == "pull-up-agentic-uw-cleared" },
            "Session screen did not follow the rotated session ID"
        )
        XCTAssertTrue(pollUntil(timeout: 10) { field.typedText == "" }, "Composer was not empty after /clear")
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

    private func commandRequests() async throws -> [String] {
        let requests = try await fixtureJSON("/fixture/command-requests")["requests"] as? [[String: Any]] ?? []
        return requests.compactMap { $0["text"] as? String }
    }
}
