import XCTest

@MainActor
final class MockScreenshotTests: XCTestCase {
    private var auditLines: [String] = []

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testDesignMocks() throws {
        let environment = ProcessInfo.processInfo.environment
        let requested = environment["TEST_RUNNER_MOCKS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let defaultScreens = ["sessions", "sessions-empty", "sessions-offline", "sessions-reconnecting"]
        let screens = requested?.isEmpty == false ? requested! : defaultScreens
            .filter { defaultScreens.contains($0) }
        let schemes = ["light", "dark"]

        for screen in screens {
            let sizes = ["sessions", "settings", "onboarding-pair", "session-idle", "session-working", "session-approvals"].contains(screen)
                ? [("default", "UICTContentSizeCategoryLarge"), ("accessibilityXL", "UICTContentSizeCategoryAccessibilityXL")]
                : [("default", "UICTContentSizeCategoryLarge")]
            for scheme in schemes {
                for (size, category) in sizes {
                    capture(screen: screen, scheme: scheme, size: size, category: category)
                }
            }
        }
    }

    private func capture(screen: String, scheme: String, size: String, category: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CCMock", screen,
            "-CCColorScheme", scheme,
            "-UIPreferredContentSizeCategoryName", category,
        ]
        app.launch()

        let ready = app.descendants(matching: .any).matching(identifier: "mock-ready").firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 15), "Mock \(screen) did not load")
        if ready.exists {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "\(screen)-\(scheme)-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)

            if screen == "settings" {
                for _ in 0..<8 { app.swipeUp() }
                let bottomAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                bottomAttachment.name = "settings-bottom-\(scheme)-\(size)"
                bottomAttachment.lifetime = .keepAlways
                add(bottomAttachment)
            }

            if screen == "inspector" {
                app.swipeUp()
                let largeAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                largeAttachment.name = "inspector-large-\(scheme)-\(size)"
                largeAttachment.lifetime = .keepAlways
                add(largeAttachment)

                app.swipeUp()
                let largeScrollAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                largeScrollAttachment.name = "inspector-large-scroll-\(scheme)-\(size)"
                largeScrollAttachment.lifetime = .keepAlways
                add(largeScrollAttachment)
            }

            if screen == "session-idle" {
                let scrollView = app.scrollViews.firstMatch
                for _ in 0..<8 {
                    scrollView.swipeDown()
                }
                let topAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                topAttachment.name = "session-idle-top-\(scheme)-\(size)"
                topAttachment.lifetime = .keepAlways
                add(topAttachment)
            }
        }

        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append("\(screen)-\(scheme)-\(size): \(issue)")
                return true
            }
        } catch {
            auditLines.append("\(screen)-\(scheme)-\(size): audit failed: \(error)")
        }
        app.terminate()
    }
}
