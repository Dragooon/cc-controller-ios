import XCTest

@MainActor
final class TerminalApprovalFlowTests: FixtureFlowTestSupport {
    func testPaneLessTerminalApprovalUsesAttachOnlyCard() async throws {
        try await postFixture("/fixture/terminal-approvals")
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        defer { app.terminate() }

        // Approval cards live in the session now, not in the sidebar.
        let paneLessRow = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(paneLessRow.waitToExist(timeout: 75), "Pane-less terminal session was not listed")
        paneLessRow.tap()

        XCTAssertTrue(app.staticTexts["rm -f /tmp/fixture-scratch"].waitToExist(timeout: 30), "Subagent Bash command did not show in compact card")
        XCTAssertTrue(app.staticTexts["Waiting in the session on your Mac"].waitToExist(timeout: 5), "Pane-less card did not show its waiting state")
        XCTAssertFalse(app.buttons["approval-approval-flow-light-mode-allow"].exists, "Pane-less terminal approval must not show Allow")
        XCTAssertFalse(app.buttons["approval-approval-flow-light-mode-deny"].exists, "Pane-less terminal approval must not show Deny")

        let attach = app.buttons["approval-approval-flow-light-mode-attach"]
        XCTAssertTrue(attach.waitToExist(timeout: 10), "Pane-less card did not show Copy attach command")
        attach.tap()
        XCTAssertTrue(app.buttons["Attach command copied"].waitToExist(timeout: 5), "Copy attach command did not confirm")
        addScreenshot(named: "pane-less-terminal-approval")

        let sessionsBackButton = app.navigationBars.buttons["Sessions"]
        XCTAssertTrue(sessionsBackButton.waitToExist(timeout: 10), "Sessions back button did not load")
        sessionsBackButton.tap()
        let paneRow = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(paneRow.waitToExist(timeout: 20), "Pane terminal session was not listed")
        paneRow.tap()

        XCTAssertTrue(app.buttons["approval-pull-up-agentic-uw-allow"].waitToExist(timeout: 30), "Pane terminal approval must keep Allow")
        XCTAssertTrue(app.buttons["approval-pull-up-agentic-uw-deny"].exists, "Pane terminal approval must keep Deny")

    }
}
