import XCTest

final class ScreenshotTests: XCTestCase {
    func testSessionsAndSelectedSessionScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        let server = (environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832")
            .replacingOccurrences(of: "127.0.0.1", with: "localhost")
        let bearer = environment["TEST_RUNNER_BEARER"] ?? ""
        let schemes = ["light", "dark"]
        let sizes = [("default", "UICTContentSizeCategoryLarge"), ("accessibilityXL", "UICTContentSizeCategoryAccessibilityXL")]
        let only = environment["TEST_RUNNER_ONLY"]
        print("Screenshot server: \(server), bearer length: \(bearer.count)")

        for scheme in schemes {
            for (sizeName, sizeValue) in sizes {
                let app = XCUIApplication()
                app.launchArguments = [
                    "-CCServer", server,
                    "-CCBearer", bearer,
                    "-CCColorScheme", scheme,
                    "-UIPreferredContentSizeCategoryName", sizeValue,
                ]
                app.launch()
                addUIInterruptionMonitor(withDescription: "Local Network") { alert in
                    if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
                    return false
                }
                app.tap()

                let sessions = app.navigationBars["Sessions"]
                XCTAssertTrue(sessions.waitForExistence(timeout: 15), "Sessions list did not load")
                if only == nil || only == "sessions" {
                    attach(named: "sessions-\(scheme)-\(sizeName)")
                }

                let selectedRow = app.buttons.matching(identifier: "session-staff-account-exclusions").firstMatch
                XCTAssertTrue(selectedRow.waitForExistence(timeout: 10), "Fixture session row did not load")
                selectedRow.tap()
                let selectedName = app.staticTexts["selected-session-name"]
                XCTAssertTrue(selectedName.waitForExistence(timeout: 10), "Selected session detail did not load")
                if only == nil || only == "session-detail" {
                    attach(named: "session-detail-\(scheme)-\(sizeName)")
                }
                app.terminate()
            }
        }
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
