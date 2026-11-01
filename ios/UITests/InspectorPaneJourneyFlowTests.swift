import XCTest

/// The details pane on the open Duo: its sections, its live values and its approval mode.
final class InspectorPaneJourneyFlowTests: JourneyTestCase {
    override var posture: DuoPosture { .unfolded }

    func testInspectorPaneJourney() {
        let app = launchSignedIn(session: "staff-account-exclusions")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Staff Account Exclusions Atlas Monitoring"].waitToExist(timeout: 75), "Staff session did not open")
        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitToExist(timeout: 15), "Session info did not load")

        // A session with no context or usage hides those sections.
        info.tap()
        XCTAssertTrue(app.staticTexts["Status"].waitToExist(timeout: 15), "Status section did not load")
        XCTAssertFalse(app.staticTexts["Context"].exists, "A session with no context showed a Context section")
        XCTAssertFalse(app.staticTexts["Usage"].exists, "A session with no usage showed a Usage section")
        addScreenshot(named: "inspector-pane-staff")

        // The session's subtitle and the pane's elapsed time both tick.
        let subtitle = app.selectedSessionSubtitle
        XCTAssertTrue(subtitle.waitToExist(timeout: 10), "Session subtitle did not load")
        let subtitleBefore = subtitle.label
        XCTAssertTrue(pollUntil(timeout: 3) { subtitle.label != subtitleBefore }, "Session subtitle did not tick")
        let elapsed = app.element(identifier: "inspector-elapsed")
        XCTAssertTrue(elapsed.waitToExist(timeout: 10), "Elapsed row did not load")
        let elapsedBefore = text(of: elapsed)
        XCTAssertTrue(pollUntil(timeout: 3) { text(of: elapsed) != elapsedBefore }, "Elapsed time did not tick")

        // The approval mode can be changed from here.
        let picker = app.buttons["approval-mode-picker"]
        for _ in 0..<4 where !(picker.exists && picker.isHittable) { app.swipeUp() }
        XCTAssertTrue(picker.waitToExist(timeout: 15), "Approval mode picker did not load")
        picker.tap()
        let terminal = app.buttons["Terminal"]
        XCTAssertTrue(terminal.waitToExist(timeout: 10), "Terminal was not offered")
        XCTAssertTrue(pollUntil(timeout: 10) { terminal.exists && terminal.isHittable }, "Terminal could not be tapped")
        terminal.tap()
        XCTAssertTrue(pollUntil(timeout: 15) { picker.value as? String == "Terminal" }, "Approval mode did not become Terminal")
        picker.tap()
        let auto = app.buttons["Auto"]
        XCTAssertTrue(auto.waitToExist(timeout: 10), "Auto was not offered")
        auto.tap()
        XCTAssertTrue(pollUntil(timeout: 15) { picker.value as? String == "Auto" }, "Approval mode did not become Auto")
        addScreenshot(named: "inspector-pane-auto")

        // A subagent row shows its state and opens its screen.
        let engineer = app.buttons["inspector-subagent-agent-done"]
        for _ in 0..<4 where !(engineer.exists && engineer.isHittable) { app.swipeUp() }
        XCTAssertTrue(engineer.waitToExist(timeout: 15), "Subagent row did not load")
        XCTAssertTrue(engineer.label.localizedCaseInsensitiveContains("done"), "Subagent row lost its state: \(engineer.label)")
        engineer.tap()
        let subagentBar = app.navigationBars["engineer"]
        XCTAssertTrue(subagentBar.waitToExist(timeout: 15), "Subagent screen did not load")
        addScreenshot(named: "inspector-pane-subagent")
        app.buttons["BackButton"].tap()
        XCTAssertTrue(subagentBar.waitToDisappear(timeout: 15), "Back did not leave the subagent screen")
        XCTAssertTrue(app.staticTexts["Staff Account Exclusions Atlas Monitoring"].waitToExist(timeout: 15), "Session did not stay on screen after the subagent")

        // A session with context and usage shows them, and the screen reader hears them whole.
        // The pane took the sidebar's room, so the sidebar may still be closed.
        let longSession = app.buttons["session-long-session"]
        if !longSession.isSafelyHittable { app.buttons["sidebar-toggle"].tap() }
        XCTAssertTrue(pollUntil(timeout: 5) { longSession.isSafelyHittable }, "Long session's row could not be tapped")
        longSession.tap()
        XCTAssertTrue(pollUntil(timeout: 30) { app.selectedSessionName.exists && app.selectedSessionName.label == "Long session" }, "Long session did not open")
        if !app.staticTexts["Status"].exists { info.tap() }
        XCTAssertTrue(app.staticTexts["Status"].waitToExist(timeout: 15), "Status section did not load for the long session")
        for name in ["Context", "Usage", "6%", "64k", "1.2k", "97%"] {
            XCTAssertTrue(app.staticTexts[name].waitToExist(timeout: 15), "\(name) did not load for the long session")
        }
        let context = app.element(identifier: "inspector-context")
        XCTAssertTrue(context.waitToExist(timeout: 15), "Context element did not load")
        XCTAssertEqual(context.label, "Context, 6 percent, 64k of 1M tokens")
        let responses = app.element(identifier: "inspector-responses")
        XCTAssertTrue(responses.waitToExist(timeout: 15), "Responses tile did not load")
        XCTAssertEqual(responses.label, "1 Response")
        XCTAssertFalse(app.staticTexts["Messages"].exists, "Usage kept the old Messages label")
        addScreenshot(named: "inspector-pane-long-session")
    }

    private func text(of element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }
}
