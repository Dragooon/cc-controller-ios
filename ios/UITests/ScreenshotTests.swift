import XCTest

final class ScreenshotTests: XCTestCase {
    func testSessionsAndSelectedSessionScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832"
        let bearer = environment["TEST_RUNNER_BEARER"] ?? ""
        let schemes = ["light", "dark"]
        let sizes = [("default", "UICTContentSizeCategoryLarge"), ("accessibilityXL", "UICTContentSizeCategoryAccessibilityXL")]
        let only = environment["TEST_RUNNER_ONLY"]
        print("Screenshot server: \(server), bearer length: \(bearer.count)")

        for scheme in schemes {
            for (sizeName, sizeValue) in sizes {
                let app = XCUIApplication(bundleIdentifier: "com.example.cc-controller")
                app.launchArguments = [
                    "-CCServer", server,
                    "-CCColorScheme", scheme,
                    "-UIPreferredContentSizeCategoryName", sizeValue,
                ]
                app.launchEnvironment["CCBearer"] = bearer
                app.launch()
                addUIInterruptionMonitor(withDescription: "Local Network") { alert in
                    if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
                    return false
                }
                app.tap()

                let sessionsTitle = app.staticTexts["Sessions"]
                let sessionsNavigationBar = app.navigationBars["Sessions"]
                XCTAssertTrue(sessionsTitle.waitForExistence(timeout: 15) || sessionsNavigationBar.exists, "Sessions list did not load; detail=\(errorDetail(in: app))")
                if only == nil || only == "sessions" {
                    attach(named: "sessions-\(scheme)-\(sizeName)")
                }

                let selectedRow = app.descendants(matching: .any).matching(identifier: "session-staff-account-exclusions").firstMatch
                XCTAssertTrue(selectedRow.waitForExistence(timeout: 10), "Fixture session row did not load; detail=\(errorDetail(in: app))")
                selectedRow.tap()
                let selectedName = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
                XCTAssertTrue(selectedName.waitForExistence(timeout: 10), "Selected session detail did not load")
                if only == nil || only == "session-detail" {
                    attach(named: "session-detail-\(scheme)-\(sizeName)")
                }
                app.terminate()
            }
        }
    }

    private func errorDetail(in app: XCUIApplication) -> String {
        let error = app.descendants(matching: .any).matching(identifier: "connection-error").firstMatch
        let detail = app.descendants(matching: .any).matching(identifier: "connection-error-detail").firstMatch
        let visible = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "Can't reach")).firstMatch
        let errorText = error.exists ? error.label : (visible.exists ? visible.label : "no-error-label")
        let detailText = detail.exists ? detail.label : "no-detail-label"
        let hierarchy = app.debugDescription.split(separator: "\n").map(String.init).filter { $0.localizedCaseInsensitiveContains("reach") || $0.localizedCaseInsensitiveContains("decode") || $0.localizedCaseInsensitiveContains("http") }
        return "\(errorText) / \(detailText) / \(hierarchy.joined(separator: " | "))"
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
