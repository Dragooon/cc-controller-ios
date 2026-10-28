import XCTest

@MainActor
final class SessionsListFlowTests: FixtureFlowTestSupport {
    func testArchiveRecentsSwipeUndoAndUnarchive() async throws {
        let app = launchSignedIn()
        defer { app.terminate() }

        let row = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(row.waitForExistence(timeout: 75), "Recents fixture session was not listed")
        row.swipeLeft()
        let archive = app.buttons["session-archive-dune-part-three-imax-tickets"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "Archive swipe action did not appear")
        addScreenshot(named: "archive-swipe-actions")
        archive.tap()

        let undo = app.buttons["archive-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "Archive undo toast did not appear")
        addScreenshot(named: "archive-undo-toast")
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Undo did not restore the Recents row")

        row.swipeLeft()
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "Archive action did not reappear")
        archive.tap()
        let header = app.buttons["archived-section-header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "Archived section did not appear")
        header.tap()
        addScreenshot(named: "archive-expanded")
        let archivedRow = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(archivedRow.waitForExistence(timeout: 10), "Archived row did not appear")
        archivedRow.swipeLeft()
        let unarchive = app.buttons["session-unarchive-dune-part-three-imax-tickets"]
        XCTAssertTrue(unarchive.waitForExistence(timeout: 10), "Archived row did not expose Unarchive")
        unarchive.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Unarchive did not restore the Recents row")
    }

    func testEndBackgroundFromContextMenuThenArchiveAsleep() async throws {
        try await postFixture("/fixture/sleeping-seed")
        let app = launchSignedIn()
        defer { app.terminate() }

        let sleeping = app.buttons["sleeping-session-sleeping-dune"]
        XCTAssertTrue(sleeping.waitForExistence(timeout: 75), "Seeded sleeping session was not listed")
        sleeping.tap()
        let live = app.buttons["session-sleeping-dune"]
        XCTAssertTrue(live.waitForExistence(timeout: 20), "Seeded session did not wake into Recents")
        app.buttons["BackButton"].tap()
        XCTAssertTrue(live.waitForExistence(timeout: 20), "Woken background session was not listed")
        live.press(forDuration: 1)
        let endAction = app.buttons["session-end-sleeping-dune"]
        XCTAssertTrue(endAction.waitForExistence(timeout: 10), "End session context action did not appear")
        endAction.tap()
        XCTAssertTrue(app.staticTexts["End this session?"].waitForExistence(timeout: 10), "End confirmation dialog did not appear")
        addScreenshot(named: "end-dialog")
        app.buttons["End session"].tap()

        let asleep = app.buttons["sleeping-session-sleeping-dune"]
        XCTAssertTrue(asleep.waitForExistence(timeout: 20), "Ended background session did not appear in Asleep")
        asleep.swipeLeft()
        let archive = app.buttons["session-archive-sleeping-dune"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "Asleep archive action did not appear")
        archive.tap()
        XCTAssertTrue(app.buttons["archive-undo"].waitForExistence(timeout: 10), "Archive of Asleep session did not complete")
        XCTAssertTrue(asleep.waitForNonExistence(timeout: 10), "Archived Asleep session remained in Asleep")
    }

    func testCompactRowsShowTitleAgentAndStatus() throws {
        let app = launchSignedIn()
        defer { app.terminate() }

        let workingRow = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(workingRow.waitForExistence(timeout: 75), "Working fixture session was not listed")
        let workingTitle = app.descendants(matching: .any)
            .matching(identifier: "session-title-pull-up-agentic-uw")
            .firstMatch
        let workingAgent = app.descendants(matching: .any)
            .matching(identifier: "session-agent-pull-up-agentic-uw")
            .firstMatch
        XCTAssertEqual(workingTitle.label, "Pull Up Agentic UW")
        XCTAssertEqual(workingAgent.label, "agentic-uw")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "session-status-pull-up-agentic-uw")
                .firstMatch
                .waitForExistence(timeout: 10),
            "Working session had no trailing status indicator"
        )

        let idleRow = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(idleRow.waitForExistence(timeout: 20), "Idle fixture session was not listed")
        let idleTitle = app.descendants(matching: .any)
            .matching(identifier: "session-title-dune-part-three-imax-tickets")
            .firstMatch
        let idleAgent = app.descendants(matching: .any)
            .matching(identifier: "session-agent-dune-part-three-imax-tickets")
            .firstMatch
        XCTAssertEqual(idleTitle.label, "Dune Part Three IMAX tickets")
        XCTAssertEqual(idleAgent.label, "dune")
        XCTAssertFalse(idleRow.label.contains("idle"), "Idle duration leaked into compact row: \(idleRow.label)")
        XCTAssertFalse(idleRow.label.contains("ctx"), "Context usage leaked into compact row: \(idleRow.label)")
        XCTAssertFalse(idleRow.label.contains("thinking"), "Activity text leaked into compact row: \(idleRow.label)")
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "session-status-dune-part-three-imax-tickets")
                .firstMatch
                .exists,
            "Idle session showed a trailing status indicator"
        )
        print("COMPACT_IDLE_ROW_HEIGHT \(idleRow.frame.height)")
        XCTAssertLessThanOrEqual(idleRow.frame.height, 60, "Idle row exceeded compact height")
        XCTAssertLessThanOrEqual(
            abs(idleTitle.frame.minX - idleRow.frame.minX),
            24,
            "Title was too far from the list cell leading edge"
        )
    }

    private func launchSignedIn() -> XCUIApplication {
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
}
