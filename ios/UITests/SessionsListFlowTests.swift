import XCTest

@MainActor
final class SessionsListFlowTests: FixtureFlowTestSupport {
    func testArchiveRecentsSwipeUndoAndUnarchive() async throws {
        let app = launchSignedIn()
        defer { app.terminate() }

        let row = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(row.waitToExist(timeout: 75), "Recents fixture session was not listed")
        row.swipeLeft()
        let archive = app.buttons["session-archive-dune-part-three-imax-tickets"]
        XCTAssertTrue(archive.waitToExist(timeout: 10), "Archive swipe action did not appear")
        addScreenshot(named: "archive-swipe-actions")
        archive.tap()

        let undo = app.buttons["archive-undo"]
        XCTAssertTrue(undo.waitToExist(timeout: 10), "Archive undo toast did not appear")
        addScreenshot(named: "archive-undo-toast")
        undo.tap()
        XCTAssertTrue(row.waitToExist(timeout: 10), "Undo did not restore the Recents row")

        row.swipeLeft()
        XCTAssertTrue(archive.waitToExist(timeout: 10), "Archive action did not reappear")
        archive.tap()
        let header = app.buttons["archived-section-header"]
        XCTAssertTrue(header.waitToExist(timeout: 10), "Archived section did not appear")
        header.tap()
        addScreenshot(named: "archive-expanded")
        let archivedRow = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(archivedRow.waitToExist(timeout: 10), "Archived row did not appear")
        archivedRow.swipeLeft()
        let unarchive = app.buttons["session-unarchive-dune-part-three-imax-tickets"]
        XCTAssertTrue(unarchive.waitToExist(timeout: 10), "Archived row did not expose Unarchive")
        unarchive.tap()
        XCTAssertTrue(row.waitToExist(timeout: 10), "Unarchive did not restore the Recents row")
    }

    func testEndBackgroundFromContextMenuThenArchiveSleepingSession() async throws {
        try await postFixture("/fixture/sleeping-seed")
        let app = launchSignedIn()
        defer { app.terminate() }

        let sleeping = app.buttons["sleeping-session-sleeping-dune"]
        XCTAssertTrue(sleeping.waitToExist(timeout: 75), "Seeded sleeping session was not listed")
        sleeping.tap()
        let title = app.descendants(matching: .any)
            .matching(identifier: "selected-session-name")
            .firstMatch
        XCTAssertTrue(title.waitToExist(timeout: 30), "Woken session did not open")
        XCTAssertEqual(title.label, "Sleeping Dune")
        app.buttons["BackButton"].tap()
        let live = app.buttons["session-sleeping-dune"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 where !live.exists { list.swipeUp() }
        XCTAssertTrue(live.waitToExist(timeout: 20), "Woken background session was not listed in Recents")
        live.press(forDuration: 1)
        let endAction = app.buttons["session-end-sleeping-dune"]
        XCTAssertTrue(endAction.waitToExist(timeout: 10), "End session context action did not appear")
        endAction.tap()
        XCTAssertTrue(app.staticTexts["End this session?"].waitToExist(timeout: 10), "End confirmation dialog did not appear")
        addScreenshot(named: "end-dialog")
        app.buttons["End session"].tap()

        let asleep = app.buttons["sleeping-session-sleeping-dune"]
        XCTAssertTrue(asleep.waitToExist(timeout: 20), "Ended background session did not appear in Recents")
        asleep.swipeLeft()
        let archive = app.buttons["session-archive-sleeping-dune"]
        XCTAssertTrue(archive.waitToExist(timeout: 10), "Sleeping-session archive action did not appear")
        archive.tap()
        XCTAssertTrue(app.buttons["archive-undo"].waitToExist(timeout: 10), "Archive of sleeping session did not complete")
        XCTAssertTrue(asleep.waitToDisappear(timeout: 10), "Archived sleeping session remained in Recents")
    }

    func testCompactRowsShowTitleAgentAndStatus() throws {
        let app = launchSignedIn()
        defer { app.terminate() }

        let workingRow = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(workingRow.waitToExist(timeout: 75), "Working fixture session was not listed")
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
                .waitToExist(timeout: 10),
            "Working session had no leading status indicator"
        )

        let idleRow = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(idleRow.waitToExist(timeout: 20), "Idle fixture session was not listed")
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
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "session-status-dune-part-three-imax-tickets")
                .firstMatch
                .waitToExist(timeout: 10),
            "Idle session had no leading status indicator"
        )
        print("COMPACT_IDLE_ROW_HEIGHT \(idleRow.frame.height)")
        XCTAssertLessThanOrEqual(idleRow.frame.height, 60, "Idle row exceeded compact height")
        XCTAssertGreaterThanOrEqual(
            idleTitle.frame.minX - idleRow.frame.minX,
            34,
            "Title did not leave room for the leading status column"
        )
    }

    private func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        if let colorScheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !colorScheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", colorScheme]
        }
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }
}
