import XCTest

@MainActor
final class SmokeFlowTests: XCTestCase {
    func testAppOpensOnLiveSessions() {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832"
        let bearer = environment["TEST_RUNNER_BEARER"] ?? ""
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        app.launchEnvironment["CCBearer"] = bearer
        app.launch()

        let needsYou = app.staticTexts["Needs you"]
        XCTAssertTrue(needsYou.waitForExistence(timeout: 60), "Needs you section did not load")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "smoke-sessions"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        var auditLines: [String] = []
        do {
            try app.performAccessibilityAudit { issue in
                auditLines.append(String(describing: issue))
                return true
            }
        } catch {
            auditLines.append("Accessibility audit failed: \(error)")
        }
        let audit = XCTAttachment(data: Data(auditLines.joined(separator: "\n").utf8), uniformTypeIdentifier: "public.plain-text")
        audit.name = "smoke-audit.txt"
        audit.lifetime = .keepAlways
        add(audit)
    }

    func testKeychainSelfTest() {
        let app = XCUIApplication()
        app.launchArguments = ["-CCKeychainSelfTest"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Keychain OK"].waitForExistence(timeout: 60), "Keychain self-test did not pass")
    }
}
