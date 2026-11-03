import XCTest

/// Everything that can ask you something from inside a session, in one launch on the folded Duo.
final class ApprovalsAndQuestionsJourneyFlowTests: JourneyTestCase {
    private let conversationDecisionPath = "/fixture/peer-conversation/decision"

    func testApprovalsAndQuestionsJourney() async throws {
        let app = launchSignedIn()
        defer { app.terminate() }
        openSession("approval-flow-light-mode", in: app)

        // An approval names the tool, who's asking and the command, and takes the composer's place.
        XCTAssertTrue(app.staticTexts["Bash"].waitToExist(timeout: 20), "Approval card did not show Bash")
        XCTAssertTrue(app.staticText(containing: "engineer wants to run this").exists, "Approval card did not name the engineer")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'git status --short' AND label CONTAINS[c] 'approval flow'")).firstMatch.exists,
            "Approval card did not show the command"
        )
        XCTAssertFalse(app.composer.exists, "Composer stayed up with an approval pending")
        addScreenshot(named: "approval-card")

        // This short transcript has nothing to jump to, even with the card up.
        XCTAssertTrue(
            app.staticTexts["The session is ready to ask the owner before running the verification command."].waitToExist(timeout: 20),
            "Short transcript did not load"
        )
        XCTAssertFalse(app.jumpToLatest.exists, "Jump to latest showed on a short transcript")

        // Allow takes the card away and brings the composer back.
        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.waitToExist(timeout: 10), "Allow did not load")
        allow.tap()
        XCTAssertTrue(allow.waitToDisappear(timeout: 30), "Allow did not go away after the decision")
        XCTAssertTrue(app.composer.waitToExist(timeout: 30), "Composer did not return after Allow")

        // A peer's request shows the sender and offers only Allow and Deny.
        try await postFixture("/fixture/peer-conversation")
        let request = app.element(identifier: "peer-conversation-request")
        XCTAssertTrue(request.waitToExist(timeout: 20), "Peer request did not appear")
        XCTAssertTrue(request.label.contains("Stockade"), "Peer request left out the sender's controller")
        XCTAssertTrue(request.label.contains("wants to message"), "Peer request left out its sentence")
        XCTAssertTrue(app.element(identifier: "peer-conversation-preview").exists, "Peer request had no message preview")
        XCTAssertFalse(app.buttons["Allow for this session"].exists, "Peer request offered a session-wide Allow")
        let peerAllow = app.buttons["approval-approval-flow-light-mode-allow"]
        XCTAssertTrue(peerAllow.exists, "Peer request did not offer Allow")
        XCTAssertTrue(app.buttons["approval-approval-flow-light-mode-deny"].exists, "Peer request did not offer Deny")
        addScreenshot(named: "approval-peer-card")
        peerAllow.tap()
        XCTAssertTrue(peerAllow.waitToDisappear(timeout: 30), "Allow did not settle the peer request")
        var settled = false
        for _ in 0..<120 {
            let decision = try await fixtureJSON(conversationDecisionPath)["decision"] as? String
            if decision == "allow" { settled = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(settled, "The fixture did not get the peer decision")

        // A terminal approval with no pane to answer from offers only the attach command.
        // This route clears earlier approvals, so it comes after them.
        try await postFixture("/fixture/terminal-approvals")
        XCTAssertTrue(app.staticTexts["rm -f /tmp/fixture-scratch"].waitToExist(timeout: 30), "Terminal approval's command did not show")
        XCTAssertTrue(app.staticTexts["Waiting in the session on your Mac"].waitToExist(timeout: 5), "Pane-less card did not say it's waiting")
        XCTAssertFalse(app.buttons["approval-approval-flow-light-mode-allow"].exists, "Pane-less approval showed Allow")
        XCTAssertFalse(app.buttons["approval-approval-flow-light-mode-deny"].exists, "Pane-less approval showed Deny")
        let attach = app.buttons["approval-approval-flow-light-mode-attach"]
        XCTAssertTrue(attach.waitToExist(timeout: 10), "Pane-less card did not offer the attach command")
        attach.tap()
        XCTAssertTrue(app.buttons["Attach command copied"].waitToExist(timeout: 5), "Copying the attach command did not confirm")
        addScreenshot(named: "approval-pane-less")

        // With a pane, a terminal approval keeps Allow and Deny.
        goBackToSessions(in: app)
        openSession("pull-up-agentic-uw", in: app)
        XCTAssertTrue(app.buttons["approval-pull-up-agentic-uw-allow"].waitToExist(timeout: 30), "Pane approval lost Allow")
        XCTAssertTrue(app.buttons["approval-pull-up-agentic-uw-deny"].exists, "Pane approval lost Deny")
        goBackToSessions(in: app)

        // A session waiting on a question needs you, and the question replaces the composer.
        try await postFixture("/fixture/question-flow")
        let questionRow = app.buttons["session-question-flow"]
        XCTAssertTrue(questionRow.waitToExist(timeout: 30), "Question session was not listed")
        XCTAssertTrue(pollUntil(timeout: 20) { questionRow.value as? String == "needsYou" }, "A session waiting on a question was not unread")
        openSession("question-flow", in: app)
        let questionText = app.element(identifier: "question-text")
        XCTAssertTrue(waitForLabel(questionText, "Choose one letter.", timeout: 20), "The first question did not show")
        let firstChip = app.element(identifier: "question-chip-0")
        XCTAssertEqual(firstChip.value as? String, "Not answered")
        XCTAssertFalse(app.composer.exists, "Composer stayed up with a question pending")

        // A single-select answer moves on; a multi-select waits for Send.
        app.element(identifier: "question-option-A").tap()
        XCTAssertTrue(waitForLabel(questionText, "Choose letters."), "Answering did not move to the next question")
        XCTAssertTrue(pollUntil(timeout: 5) { firstChip.value as? String == "Answered" }, "The first question's chip did not say Answered")
        app.element(identifier: "question-option-A").tap()
        app.element(identifier: "question-option-C").tap()
        XCTAssertEqual(app.element(identifier: "question-option-C").value as? String, "Selected")
        let send = app.buttons["question-send"]
        XCTAssertTrue(send.isEnabled, "Send answers stayed off with every question answered")
        addScreenshot(named: "question-complete")
        send.tap()
        XCTAssertTrue(app.element(identifier: "command-toast").waitToExist(timeout: 15), "Answered toast did not appear")
        XCTAssertTrue(questionText.waitToDisappear(timeout: 30), "The question stayed after sending")
        var answers = try await fixtureAnswers()
        XCTAssertEqual(answers, ["Choose one letter.": "A", "Choose letters.": "A, C"])

        // The transcript records the answers, and the row opens them.
        let answeredRow = row("One · A; Many · A, C", in: app)
        XCTAssertTrue(answeredRow.waitToExist(timeout: 30), "Transcript did not show the answers")
        answeredRow.tap()
        XCTAssertTrue(app.element(identifier: "question-sheet").waitToExist(timeout: 10), "The row did not open the answers")
        addScreenshot(named: "question-sheet")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.element(identifier: "question-sheet").waitToDisappear(timeout: 10), "The answers sheet did not close")

        // Other takes a typed answer, and the chips switch between questions.
        try await postFixture("/fixture/question-flow")
        XCTAssertTrue(waitForLabel(questionText, "Choose one letter.", timeout: 20), "The second question card did not show")
        app.element(identifier: "question-other").tap()
        let other = app.element(identifier: "question-other-field")
        XCTAssertTrue(other.waitToExist(timeout: 10), "Other did not open its field")
        other.typeText("Z\n")
        let answeredChip = app.element(identifier: "question-chip-0")
        XCTAssertTrue(pollUntil(timeout: 5) { answeredChip.value as? String == "Answered" }, "The first question's chip did not say Answered")
        app.element(identifier: "question-chip-1").tap()
        XCTAssertTrue(waitForLabel(questionText, "Choose letters."), "The chip did not switch questions")
        app.element(identifier: "question-option-B").tap()
        send.tap()
        XCTAssertTrue(questionText.waitToDisappear(timeout: 30), "The question stayed after sending")
        answers = try await fixtureAnswers()
        XCTAssertEqual(answers, ["Choose one letter.": "Z", "Choose letters.": "B"])
        XCTAssertTrue(row("One · Z; Many · B", in: app).waitToExist(timeout: 30), "Transcript did not show the typed answer")

        // Skip declines, and the composer comes back.
        try await postFixture("/fixture/question-flow")
        XCTAssertTrue(waitForLabel(questionText, "Choose one letter.", timeout: 20), "The third question card did not show")
        XCTAssertFalse(send.isEnabled, "Send answers was on before any answer")
        app.buttons["question-skip"].tap()
        XCTAssertTrue(questionText.waitToDisappear(timeout: 30), "The question stayed after Skip")
        XCTAssertTrue(app.composer.waitToExist(timeout: 30), "Composer did not return after Skip")
        XCTAssertTrue(row("One · Declined; Many · Declined", in: app).waitToExist(timeout: 30), "Transcript did not show the skip")
    }

    private func fixtureAnswers() async throws -> [String: String] {
        try await fixtureJSON("/fixture/question-answers")["answers"] as? [String: String] ?? [:]
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        return pollUntil(timeout: timeout) { predicate.evaluate(with: element) }
    }

    // Every run of the fixture adds another question to the same transcript, so match the row by its text.
    private func row(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "question-row", value))
            .firstMatch
    }
}
