import XCTest

@MainActor
final class QuestionFlowTests: FixtureFlowTestSupport {
    func testAnswerSingleAndMultiSelect() async throws {
        let app = try await openQuestionSession()
        defer { app.terminate() }

        let firstChip = element(app, "question-chip-0")
        XCTAssertEqual(firstChip.value as? String, "Not answered")
        XCTAssertFalse(element(app, "composer-text").exists, "Composer must be replaced while a question is pending")
        addScreenshot(named: "question-card-first")

        element(app, "question-option-A").tap()
        let questionText = element(app, "question-text")
        XCTAssertTrue(waitForLabel(questionText, "Choose letters."), "Single-select answer did not advance to the next question")
        XCTAssertEqual(firstChip.value as? String, "Answered")

        element(app, "question-option-A").tap()
        element(app, "question-option-C").tap()
        XCTAssertEqual(element(app, "question-option-C").value as? String, "Selected")
        let send = app.buttons["question-send"]
        XCTAssertTrue(send.isEnabled, "Send answers stayed disabled with every question answered")
        addScreenshot(named: "question-card-complete")
        send.tap()

        XCTAssertTrue(element(app, "command-toast").waitToExist(timeout: 15), "Answered toast did not appear")
        XCTAssertTrue(
            element(app, "question-text").waitToDisappear(timeout: 30),
            "Question text did not leave after sending"
        )
        let answers = try await fixtureAnswers()
        XCTAssertEqual(answers, ["Choose one letter.": "A", "Choose letters.": "A, C"])

        let row = questionRow(app, "One · A; Many · A, C")
        XCTAssertTrue(row.waitToExist(timeout: 30), "Transcript row did not show the answers")
        row.tap()
        XCTAssertTrue(element(app, "question-sheet").waitToExist(timeout: 10), "Question sheet did not open from the transcript row")
        addScreenshot(named: "question-sheet")
        audit(app, name: "question-answered")
    }

    func testOtherAnswer() async throws {
        let app = try await openQuestionSession()
        defer { app.terminate() }

        element(app, "question-other").tap()
        let field = element(app, "question-other-field")
        XCTAssertTrue(field.waitToExist(timeout: 10), "Other did not open the answer field")
        field.typeText("Z\n")
        XCTAssertEqual(element(app, "question-chip-0").value as? String, "Answered")

        element(app, "question-chip-1").tap()
        XCTAssertTrue(waitForLabel(element(app, "question-text"), "Choose letters."), "Chip did not switch questions")
        element(app, "question-option-B").tap()
        app.buttons["question-send"].tap()

        XCTAssertTrue(
            element(app, "question-text").waitToDisappear(timeout: 30),
            "Question text did not leave after sending"
        )
        let answers = try await fixtureAnswers()
        XCTAssertEqual(answers, ["Choose one letter.": "Z", "Choose letters.": "B"])
        XCTAssertTrue(questionRow(app, "One · Z; Many · B").waitToExist(timeout: 30), "Transcript row did not show the typed answer")
    }

    func testSkip() async throws {
        let app = try await openQuestionSession()
        defer { app.terminate() }

        XCTAssertFalse(app.buttons["question-send"].isEnabled, "Send answers was enabled before any answer")
        app.buttons["question-skip"].tap()

        XCTAssertTrue(
            element(app, "question-text").waitToDisappear(timeout: 30),
            "Question text did not leave after Skip"
        )
        XCTAssertTrue(element(app, "composer-text").waitToExist(timeout: 30), "Composer did not return after Skip")
        XCTAssertTrue(questionRow(app, "One · Declined; Many · Declined").waitToExist(timeout: 30), "Transcript row did not show the skip")
    }

    private func openQuestionSession() async throws -> XCUIApplication {
        try await postFixture("/fixture/question-flow")
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()

        let session = app.buttons["session-question-flow"]
        XCTAssertTrue(session.waitToExist(timeout: 75), "Question flow session did not load")
        XCTAssertTrue(
            pollUntil(timeout: 20) { session.value as? String == "unread" },
            "A session waiting on a question was not unread"
        )
        addScreenshot(named: "question-sessions-list")
        session.tap()

        XCTAssertTrue(
            waitForLabel(element(app, "question-text"), "Choose one letter.", timeout: 20),
            "Initial question text did not appear"
        )
        return app
    }

    private func fixtureAnswers() async throws -> [String: String] {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)/fixture/question-answers") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["answers"] as? [String: String] ?? [:]
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 10) -> Bool {
        wait(for: NSPredicate(format: "label == %@", label), on: element, timeout: timeout)
    }

    // Every run of the shared fixture adds another question to the same transcript, so match the row by its text.
    private func questionRow(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "question-row", value))
            .firstMatch
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) { predicate.evaluate(with: element) }
    }
}
