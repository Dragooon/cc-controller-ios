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
                dismissLeftoverNotificationPrompt()
                app.launch()

                let needsYou = app.staticTexts["Needs you"]
                let staffRow = app.buttons["session-staff-account-exclusions"]
                let approvalRow = app.buttons["session-approval-flow-light-mode"]
                XCTAssertTrue(needsYou.waitForExistence(timeout: 75), "Needs you section did not load")
                XCTAssertTrue(staffRow.waitForExistence(timeout: 75), "Staff approval row did not load")

                if only == nil || only == "sessions" {
                    attach(named: "sessions-\(scheme)-\(sizeName)")
                }

                let list = app.collectionViews.firstMatch
                if !approvalRow.exists {
                    for _ in 0..<4 where !approvalRow.exists { list.swipeUp() }
                }
                XCTAssertTrue(approvalRow.waitForExistence(timeout: 15), "Approval flow row did not load")
                for _ in 0..<4 where !staffRow.exists { list.swipeDown() }
                XCTAssertTrue(staffRow.waitForExistence(timeout: 15), "Staff approval row did not return")
                staffRow.tap()
                let selectedName = app.descendants(matching: .any)
                    .matching(identifier: "selected-session-name")
                    .firstMatch
                XCTAssertTrue(selectedName.waitForExistence(timeout: 15), "Selected session title did not load")
                let assistantText = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", "The exclusion is ready for monitored rollout"))
                    .firstMatch
                XCTAssertTrue(assistantText.waitForExistence(timeout: 15), "Final fixture assistant text did not load")

                if only == nil || only == "session-detail" {
                    attach(named: "session-detail-\(scheme)-\(sizeName)")
                }

                let sessionsBackButton = app.navigationBars.buttons["Sessions"]
                XCTAssertTrue(sessionsBackButton.waitForExistence(timeout: 15), "Sessions back button did not load")
                sessionsBackButton.tap()
                let liveRow = app.buttons["session-dune-part-three-imax-tickets"]
                let liveList = app.collectionViews.firstMatch
                XCTAssertTrue(liveList.waitForExistence(timeout: 15), "Sessions list did not return")
                for _ in 0..<5 where !liveRow.exists { liveList.swipeUp() }
                XCTAssertTrue(liveRow.waitForExistence(timeout: 15), "Dune session row did not load")
                let livePredicate = NSPredicate(format: "value == %@", "working")
                let liveExpectation = XCTNSPredicateExpectation(predicate: livePredicate, object: liveRow)
                XCTAssertEqual(XCTWaiter.wait(for: [liveExpectation], timeout: 45), .completed, "Live event did not change Dune session to working")
                if only == nil || only == "sessions" {
                    attach(named: "sessions-live-\(scheme)-\(sizeName)")
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
