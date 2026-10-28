import XCTest

@MainActor
final class SessionsListFlowTests: FixtureFlowTestSupport {
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
