import XCTest

@MainActor
final class InspectorFlowTests: XCTestCase {
    private var auditLines: [String] = []

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testSubagentPush() throws {
        let app = launch()
        openStaffSession(app)

        let engineer = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "engineer")).firstMatch
        XCTAssertTrue(engineer.waitForExistence(timeout: 15), "Engineer subagent card did not load")
        engineer.tap()

        let subagentNavigationBar = app.navigationBars["engineer"]
        XCTAssertTrue(subagentNavigationBar.waitForExistence(timeout: 15), "Subagent screen did not load")
        XCTAssertTrue(subagentNavigationBar.buttons.element(boundBy: 0).exists, "Subagent back button did not load")
        attach(named: "subagent-pushed")
        audit(app: app, name: "subagent-pushed")

        subagentNavigationBar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Staff Account Exclusions Atlas Monitoring"].waitForExistence(timeout: 15))
    }

    func testInspectorSheet() throws {
        let app = launch()
        openStaffSession(app)

        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 15), "Session info button did not load")
        info.tap()

        XCTAssertTrue(app.staticTexts["Status"].waitForExistence(timeout: 15), "Inspector Status section did not load")
        attach(named: "inspector-medium")
        audit(app: app, name: "inspector-medium")

        let picker = app.buttons["approval-mode-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "Approval mode picker did not load")
        picker.tap()
        let terminal = app.buttons["Terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Terminal mode was not offered")
        terminal.tap()
        XCTAssertEqual(picker.value as? String, "Terminal")

        picker.tap()
        let auto = app.buttons["Auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 10), "Auto mode was not offered")
        auto.tap()
        XCTAssertEqual(picker.value as? String, "Auto")
        attach(named: "inspector-auto")
        audit(app: app, name: "inspector-auto")

        app.swipeDown()
        XCTAssertFalse(app.staticTexts["Status"].exists, "Inspector sheet did not close")
    }

    private func launch() -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832"]
        app.launchEnvironment["CCBearer"] = environment["TEST_RUNNER_BEARER"] ?? ""
        app.launch()
        return app
    }

    private func openStaffSession(_ app: XCUIApplication) {
        let staffRow = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(staffRow.waitForExistence(timeout: 75), "Staff session row did not load")
        staffRow.tap()
        XCTAssertTrue(
            app.staticTexts["Staff Account Exclusions Atlas Monitoring"].waitForExistence(timeout: 15),
            "Staff session did not open"
        )
    }

    private func audit(app: XCUIApplication, name: String) {
        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append("\(name): \(issue)")
                return true
            }
        } catch {
            auditLines.append("\(name): audit failed: \(error)")
        }
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
