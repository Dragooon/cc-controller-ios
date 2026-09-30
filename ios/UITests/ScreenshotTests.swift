import XCTest

final class ScreenshotTests: XCTestCase {
    func testSessionsAndSelectedSessionScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832"
        let bearer = environment["TEST_RUNNER_BEARER"] ?? ""
        let schemes = ["light", "dark"]
        let sizes = [("default", "UICTContentSizeCategoryLarge"), ("accessibilityXL", "UICTContentSizeCategoryAccessibilityXL")]
        let only = environment["TEST_RUNNER_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        print("Screenshot server: \(server), bearer length: \(bearer.count)")

        for scheme in schemes {
            for (sizeName, sizeValue) in sizes {
                let app = XCUIApplication()
                app.launchArguments = [
                    "-CCServer", server,
                    "-CCColorScheme", scheme,
                    "-UIPreferredContentSizeCategoryName", sizeValue,
                ]
                app.launchEnvironment["CCBearer"] = bearer
                app.launch()

                let selectedRow = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "Staff Account Exclusions Atlas Monitoring")).firstMatch
                let connectionError = app.descendants(matching: .any).matching(identifier: "connection-error").firstMatch
                let deadline = Date().addingTimeInterval(75)
                var nextScroll = Date().addingTimeInterval(2)
                while !selectedRow.exists && !connectionError.exists && Date() < deadline {
                    if Date() >= nextScroll {
                        app.collectionViews.firstMatch.swipeUp()
                        nextScroll = Date().addingTimeInterval(2)
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                guard selectedRow.exists else {
                    attachHierarchy(named: "hierarchy-\(scheme)-\(sizeName)", app: app)
                    XCTFail("Fixture session row did not load; detail=\(errorDetail(in: app)) hierarchy=\(String(app.debugDescription.prefix(12000)))")
                    app.terminate()
                    return
                }
                if only == nil || only == "sessions" {
                    attach(named: "sessions-\(scheme)-\(sizeName)")
                }

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

    private func attachHierarchy(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
