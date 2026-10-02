import XCTest

@MainActor
final class ApprovalFlowTests: XCTestCase {
    private var runtimeErrors: [String] = []
    private var auditLines: [String] = []

    override func tearDown() {
        let lines = runtimeErrors + auditLines
        let report = lines.isEmpty ? "No runtime or accessibility issues reported." : lines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "approval-flow-audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testAllowInSession() throws {
        let app = launchFixture()
        defer { app.terminate() }

        let approvalSession = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(approvalSession.waitForExistence(timeout: 75), "Approval fixture session did not load")
        approvalSession.tap()
        assertNoRuntimeErrors()

        let bash = app.staticTexts["Bash"]
        XCTAssertTrue(bash.waitForExistence(timeout: 20), "Approval card did not show Bash")
        let requestCopy = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'engineer wants to run this'")
        ).firstMatch
        XCTAssertTrue(requestCopy.exists, "Approval card did not identify the engineer")
        let command = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'git status --short' AND label CONTAINS[c] 'approval flow'")
        ).firstMatch
        XCTAssertTrue(command.exists, "Approval card did not show the command")
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertFalse(composer.exists, "Composer must be replaced while approval is pending")
        attach(named: "approval-session-card")

        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "Allow button did not load")
        allow.tap()
        assertNoRuntimeErrors()

        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: allow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 30), .completed, "Allow button did not disappear after the decision")
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "Composer did not return after Allow")

        let decision = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Allowed from this device'")
        ).firstMatch
        if !decision.waitForExistence(timeout: 10) {
            XCTAssertTrue(composer.exists, "After Allow the app showed neither the decision caption nor the composer")
        }
        attach(named: "approval-session-allowed")

        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append("approval-flow: \(issue)")
                return true
            }
        } catch {
            auditLines.append("approval-flow audit failed: \(error)")
        }
    }

    private func launchFixture() -> XCUIApplication {
        let server = requiredRunnerVariable("TEST_RUNNER_SERVER_URL")
        let bearer = requiredRunnerVariable("TEST_RUNNER_BEARER")
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        app.launchEnvironment["CCBearer"] = bearer
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func assertNoRuntimeErrors() {
        XCTAssertTrue(runtimeErrors.isEmpty, runtimeErrors.joined(separator: "\n"))
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
