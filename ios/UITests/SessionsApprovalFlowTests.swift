import XCTest

@MainActor
final class SessionsApprovalFlowTests: XCTestCase {
    private var auditLines: [String] = []

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "sessions-approval-audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testDenyFromSessionsList() throws {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832"
        let bearer = environment["TEST_RUNNER_BEARER"] ?? ""
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        app.launchEnvironment["CCBearer"] = bearer
        dismissLeftoverNotificationPrompt()
        app.launch()
        defer { app.terminate() }

        let needsYou = app.staticTexts["Needs you"]
        XCTAssertTrue(needsYou.waitForExistence(timeout: 75), "Needs you section did not load")
        let staffCard = app.descendants(matching: .any)
            .matching(identifier: "approval-card-staff-account-exclusions")
            .firstMatch
        XCTAssertTrue(staffCard.waitForExistence(timeout: 20), "Staff Read approval card did not load")
        let staffDeny = app.buttons["approval-staff-account-exclusions-deny"]
        XCTAssertTrue(staffDeny.waitForExistence(timeout: 10), "Staff Read Deny button did not load")
        attach(named: "list-approval-card")

        staffDeny.tap()

        let denied = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: staffDeny
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [denied], timeout: 30),
            .completed,
            "Staff Read approval did not leave the Sessions list"
        )
        let bashCard = app.descendants(matching: .any)
            .matching(identifier: "approval-card-approval-flow-light-mode")
            .firstMatch
        XCTAssertTrue(bashCard.waitForExistence(timeout: 15), "Bash approval disappeared with the denied Read approval")
        attach(named: "list-approval-denied")

        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append(String(describing: issue))
                return true
            }
        } catch {
            auditLines.append("Accessibility audit failed: \(error)")
        }
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
