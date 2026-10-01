import XCTest

@MainActor
final class ScreenshotTests: XCTestCase {
    private var auditLines: [String] = []

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testSessionsAndSelectedSessionScreens() throws {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832"
        let bearer = environment["TEST_RUNNER_BEARER"] ?? ""
        let only = environment["TEST_RUNNER_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        let schemes = ["light", "dark"]
        let sizes = [
            ("default", "UICTContentSizeCategoryLarge"),
            ("accessibilityXL", "UICTContentSizeCategoryAccessibilityXL"),
        ]

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

                let needsYou = app.staticTexts["Needs you"]
                let staffRow = app.buttons["session-staff-account-exclusions"]
                let approvalRow = app.buttons["session-approval-flow-light-mode"]
                XCTAssertTrue(needsYou.waitForExistence(timeout: 75), "Needs you section did not load")
                XCTAssertTrue(staffRow.waitForExistence(timeout: 75), "Staff approval row did not load")
                XCTAssertTrue(approvalRow.waitForExistence(timeout: 75), "Approval flow row did not load")

                if only == nil || only == "sessions" {
                    attach(named: "sessions-\(scheme)-\(sizeName)")
                }

                staffRow.tap()
                let selectedName = app.descendants(matching: .any)
                    .matching(identifier: "selected-session-name")
                    .firstMatch
                XCTAssertTrue(selectedName.waitForExistence(timeout: 15), "Selected session title did not load")
                let assistantText = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", "monitoring path is healthy"))
                    .firstMatch
                XCTAssertTrue(assistantText.waitForExistence(timeout: 15), "Rich fixture assistant text did not load")

                if only == nil || only == "session-detail" {
                    attach(named: "session-detail-\(scheme)-\(sizeName)")
                }
                audit(app: app, scheme: scheme, size: sizeName)
                app.terminate()
            }
        }
    }

    private func audit(app: XCUIApplication, scheme: String, size: String) {
        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append("\(scheme)-\(size): \(issue)")
                return true
            }
        } catch {
            auditLines.append("\(scheme)-\(size): audit failed: \(error)")
        }
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
