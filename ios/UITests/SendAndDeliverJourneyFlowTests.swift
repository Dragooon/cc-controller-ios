import XCTest

/// Sending a message and what can happen to it, in one launch on the folded Duo.
final class SendAndDeliverJourneyFlowTests: JourneyTestCase {
    func testSendAndDeliverJourney() async throws {
        // Before launch: the fixture's 30 s Dune turn would otherwise take its Send button away.
        try await postFixture("/fixture/disable-live-event")
        let app = launchSignedIn()
        defer { app.terminate() }

        // A send goes to the session now open, and nothing carries over from the one before.
        openSession("long-session", in: app)
        typeInComposer("draft-for-the-long-session", in: app)
        goBackToSessions(in: app)
        openSession("dune-part-three-imax-tickets", in: app)
        let field = app.composer
        XCTAssertTrue(field.waitToExist(timeout: 20), "Dune composer did not load")
        XCTAssertEqual(field.typedText, "", "The long session's draft carried into Dune")
        let target = "send-target-\(UUID().uuidString)"
        sendComposer(target, in: app)
        XCTAssertTrue(app.staticText(containing: target).waitToExist(timeout: 10), "Message did not appear in Dune")
        XCTAssertTrue(pollUntil(timeout: 10) { field.typedText == "" }, "Composer did not clear after the send")
        let reachedDune = try await waitForFixtureRequest("POST /api/sessions/dune-part-three-imax-tickets/message")
        XCTAssertTrue(reachedDune, "The send did not reach Dune")
        let reachedLongSession = try await fixtureRequestCount("POST /api/sessions/long-session/message")
        XCTAssertEqual(reachedLongSession, 0, "The send also reached the long session")
        goBackToSessions(in: app)
        openSession("long-session", in: app)
        XCTAssertTrue(field.waitToExist(timeout: 20), "Long session composer did not load")
        XCTAssertEqual(field.typedText, "draft-for-the-long-session", "The long session lost its draft")
        XCTAssertFalse(app.staticText(containing: target).exists, "Dune's message showed in the long session")
        emptyComposer(in: app)

        // A long message grows the composer, then a send resets it and hides the keyboard.
        let initialHeight = field.frame.height
        XCTAssertGreaterThanOrEqual(field.frame.width, app.transcriptScroll.frame.width - 60, "Composer did not fill the folded width")
        let marker = "composer-sent-\(UUID().uuidString)"
        typeInComposer(marker + String(repeating: " wrap", count: 30), in: app)
        XCTAssertTrue(pollUntil(timeout: 10) { field.frame.height > initialHeight }, "Composer did not grow after wrapping")
        app.buttons["composer-send"].tap()
        let pending = app.pendingPrompt(message: marker)
        XCTAssertTrue(pending.waitToExist(timeout: 10), "Sent message did not appear as a pending bubble")
        XCTAssertTrue(pollUntil(timeout: 10) { field.typedText == "" }, "Composer did not clear after the send")
        XCTAssertLessThanOrEqual(abs(field.frame.height - initialHeight), 2, "Composer did not reset its height")
        XCTAssertTrue(pollUntil(timeout: 3) { app.keyboards.count == 0 }, "Keyboard stayed up after the send")

        // The pending bubble turns into exactly one delivered message.
        XCTAssertTrue(pending.waitToDisappear(timeout: 15), "Pending bubble did not become delivered")
        let delivered = app.staticText(containing: marker)
        XCTAssertTrue(delivered.waitToExist(timeout: 15), "Delivered message did not render")
        XCTAssertTrue(pollUntil(timeout: 15) { delivered.exists && delivered.isHittable }, "Delivered message was not on screen")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).count, 1, "The message showed twice")
        addScreenshot(named: "send-delivered")

        // A failed send stays as a bubble with an inline error, and Retry sends it.
        try await postFixtureJSON("/fixture/message-behaviour", body: ["failNext": true, "status": 500])
        let retried = "optimistic-retry-\(UUID().uuidString)"
        sendComposer(retried, in: app)
        let failed = app.pendingPrompt(message: retried, status: "Not sent · Tap to retry")
        XCTAssertTrue(failed.waitToExist(timeout: 10), "Failed send did not show its inline error")
        failed.tap()
        XCTAssertTrue(app.buttons["Retry"].waitToExist(timeout: 5), "Failed send did not offer Retry")
        addScreenshot(named: "send-failed-actions")
        app.buttons["Retry"].tap()
        XCTAssertTrue(failed.waitToDisappear(timeout: 10), "Retry did not leave the failed state")
        XCTAssertTrue(app.staticText(containing: retried).waitToExist(timeout: 15), "Retried message did not render")

        // A rejected send keeps the message and raises no alert.
        try await postFixture("/fixture/reject-next-send")
        let rejected = "rejected-send-\(UUID().uuidString)"
        sendComposer(rejected, in: app)
        XCTAssertTrue(
            app.pendingPrompt(message: rejected, status: "Not sent · Tap to retry").waitToExist(timeout: 10),
            "Rejected send did not stay as Not sent"
        )
        XCTAssertTrue(pollUntil(timeout: 3) { field.typedText == "" }, "Composer kept the rejected text")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Rejected send also showed an alert")

        // Text typed during a slow send survives the send finishing.
        try await postFixtureJSON("/fixture/message-behaviour", body: ["delayMs": 4_000])
        let held = "held-send-\(UUID().uuidString)"
        sendComposer(held, in: app)
        XCTAssertTrue(pollUntil(timeout: 3) { field.typedText == "" }, "Held send did not clear the composer")
        typeInComposer("while sending", in: app)
        let heldSent = app.pendingPrompt(message: held, status: "Sent")
        let heldDelivered = app.staticText(containing: held)
        XCTAssertTrue(
            pollUntil(timeout: 15) { heldSent.exists || !app.pendingPrompt(message: held).exists && heldDelivered.exists },
            "Held send did not finish"
        )
        XCTAssertEqual(field.typedText, "while sending", "Text typed during the send was wiped when it finished")
        emptyComposer(in: app)

        // Two quick sends stay in order while pending. The fixture holds the first until the second
        // arrives, so typing speed can't deliver it early.
        try await postFixture("/fixture/batch-next-prompts")
        let first = "quick-first-\(UUID().uuidString)"
        let second = "quick-second-\(UUID().uuidString)"
        sendComposer(first, in: app)
        XCTAssertTrue(pollUntil(timeout: 2) { field.typedText == "" }, "First quick send did not clear the composer")
        sendComposer(second, in: app)
        let firstPending = app.pendingPrompt(message: first)
        let secondPending = app.pendingPrompt(message: second)
        XCTAssertTrue(
            pollUntil(timeout: 5) {
                guard let firstFrame = try? firstPending.snapshot().frame,
                      let secondFrame = try? secondPending.snapshot().frame else { return false }
                return firstFrame.minY < secondFrame.minY
            },
            "Two quick sends did not leave two ordered pending bubbles"
        )
        addScreenshot(named: "send-quick-order")
    }
}
