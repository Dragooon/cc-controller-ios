import XCTest

@MainActor
final class SmokeFlowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try await restartFixtureIfConfigured()
    }

    func testAppOpensOnLiveSessions() {
        let server = requiredRunnerVariable("TEST_RUNNER_SERVER_URL")
        let bearer = requiredRunnerVariable("TEST_RUNNER_BEARER")
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        app.launchEnvironment["CCBearer"] = bearer
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()

        let needsYou = app.staticTexts["Needs you"]
        XCTAssertTrue(needsYou.waitToExist(timeout: 60), "Needs you section did not load")

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
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()

        XCTAssertTrue(app.staticTexts["Keychain OK"].waitToExist(timeout: 60), "Keychain self-test did not pass")
    }
}
