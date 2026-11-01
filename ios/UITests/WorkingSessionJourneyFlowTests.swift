import XCTest

/// A session that's busy: queueing onto it, the queue's actions and Stop, in one launch on the folded Duo.
final class WorkingSessionJourneyFlowTests: JourneyTestCase {
    func testWorkingSessionJourney() async throws {
        let app = launchSignedIn()
        defer { app.terminate() }

        // The fixture's Dune turn starts 30 s after it boots. There's no route to start it sooner yet.
        let row = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(row.waitToExist(timeout: 30), "Dune session row did not load")
        XCTAssertTrue(pollUntil(timeout: 45) { row.value as? String == "working" }, "Dune did not start working")
        openSession("dune-part-three-imax-tickets", in: app)

        // New content at the bottom doesn't offer a jump.
        XCTAssertTrue(app.staticTexts["Find three good seats for Dune Part Three IMAX."].waitToExist(timeout: 20), "Dune transcript did not load")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'working '")).firstMatch.waitToExist(timeout: 15),
            "Working status did not load"
        )
        XCTAssertFalse(app.jumpToLatest.exists, "Jump to latest showed after a live append at the bottom")

        // A message sent while working queues under the working indicator, then delivers and clears.
        let field = app.composer
        XCTAssertTrue(pollUntil(timeout: 10) { field.placeholderValue == "Queue for after this turn…" }, "Composer did not offer to queue")
        let glass = app.otherElements["Message composer"]
        let glassHeight = glass.frame.height
        let fieldHeight = field.frame.height
        let delivered = "dune-part-three-imax-tickets"
        typeInComposer(delivered, in: app)
        try await postFixture("/fixture/tail-only")
        app.buttons["composer-queue"].tap()
        let queued = app.pendingPrompt(message: delivered, status: "Queued")
        let indicator = app.element(identifier: "live-activity-row")
        XCTAssertTrue(
            pollUntil(timeout: 10) {
                guard let prompt = try? queued.snapshot(), let activity = try? indicator.snapshot() else { return false }
                return prompt.frame.maxY <= activity.frame.minY
            },
            "Queued message did not sit above the working indicator"
        )
        addScreenshot(named: "working-queued")
        XCTAssertTrue(app.staticTexts[delivered].waitToExist(timeout: 15), "Queued message did not render")
        XCTAssertTrue(queued.waitToDisappear(timeout: 10), "Queued caption did not clear after delivery")
        XCTAssertTrue(pollUntil(timeout: 10) { field.value as? String == "" }, "Composer did not clear after queueing")
        XCTAssertLessThanOrEqual(abs(field.frame.height - fieldHeight), 2, "Composer field did not reset")
        XCTAssertLessThanOrEqual(abs(glass.frame.height - glassHeight), 2, "Composer glass did not reset")
        XCTAssertTrue(app.staticText(containing: "ctx 6%").waitToExist(timeout: 10), "Subtitle did not show ctx 6%")

        // Dune holds a delivery for a minute from here on, so a queued message stays put to act on.
        // A tap offers the actions, and Dismiss removes it.
        let tapped = "queued-tap-\(UUID().uuidString)"
        sendComposer(tapped, in: app)
        let tappedPending = app.pendingPrompt(message: tapped, status: "Queued")
        XCTAssertTrue(tappedPending.waitToExist(timeout: 10), "Queued message did not render")
        tappedPending.tap()
        XCTAssertTrue(app.buttons["Copy"].waitToExist(timeout: 5), "Queued message did not offer Copy")
        XCTAssertTrue(app.buttons["Edit message"].exists, "Queued message did not offer Edit message")
        XCTAssertTrue(app.buttons["Dismiss"].exists, "Queued message did not offer Dismiss")
        addScreenshot(named: "working-queued-actions")
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(tappedPending.waitToDisappear(timeout: 5), "Dismissed message stayed")

        // A long press does the same.
        let pressed = "queued-press-\(UUID().uuidString)"
        sendComposer(pressed, in: app)
        let pressedPending = app.pendingPrompt(message: pressed, status: "Queued")
        XCTAssertTrue(pressedPending.waitToExist(timeout: 10), "Second queued message did not render")
        pressedPending.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Dismiss"].waitToExist(timeout: 5), "Long press did not offer Dismiss")
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(pressedPending.waitToDisappear(timeout: 5), "Long-press dismissed message stayed")

        // Stop sends an escape to the session and raises no error.
        app.buttons["composer-stop"].tap()
        let escaped = try await waitForEscape(sessionID: "dune-part-three-imax-tickets")
        XCTAssertTrue(escaped, "Stop did not send escape")
        XCTAssertFalse(app.alerts.firstMatch.exists, "An idle Stop response showed an error alert")
    }

    private func waitForEscape(sessionID: String) async throws -> Bool {
        let deadline = Date().addingTimeInterval(10 * flowTimeScale())
        repeat {
            let requests = try await fixtureJSON("/fixture/key-requests")["requests"] as? [[String: Any]] ?? []
            if requests.contains(where: { $0["sessionID"] as? String == sessionID && $0["key"] as? String == "escape" }) { return true }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }
}
