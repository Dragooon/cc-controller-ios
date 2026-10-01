import XCTest

@MainActor
final class TranscriptFlowTests: XCTestCase {
    private var auditLines: [String] = []

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "transcript-audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testToolGroupAndDetailSheet() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "tool-detail")
            app.terminate()
        }
        let richSession = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(richSession.waitForExistence(timeout: 75), "Rich fixture session did not load")
        richSession.tap()

        let toolGroup = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Ran' AND label CONTAINS[c] 'tools'")
        ).firstMatch
        XCTAssertTrue(toolGroup.waitForExistence(timeout: 20), "Tool group did not load")
        toolGroup.tap()

        let bash = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Bash'"))
            .firstMatch
        XCTAssertTrue(bash.waitForExistence(timeout: 15), "Expanded Bash row did not load")
        bash.tap()

        let output = app.staticTexts["OUTPUT"]
        XCTAssertTrue(output.waitForExistence(timeout: 15), "Tool detail output section did not load")
        attach(named: "transcript-tool-sheet")

        let close = app.navigationBars.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Tool detail close button did not load")
        close.tap()
        XCTAssertTrue(toolGroup.waitForExistence(timeout: 10), "Transcript did not return after closing tool detail")
    }

    func testPagingAndJumpToLatest() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "paging")
            app.terminate()
        }
        let longSession = app.buttons["session-long-session"]
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        longSession.tap()

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10), "Transcript scroll view did not load")

        let initialPromptCount = promptCount(in: app)
        let older = app.staticTexts["Long-session prompt 100: inspect the next checkpoint."]
        for _ in 0..<24 {
            scrollView.swipeDown()
            if older.exists || promptCount(in: app) > initialPromptCount {
                break
            }
        }
        XCTAssertTrue(
            older.waitForExistence(timeout: 20) || promptCount(in: app) > initialPromptCount,
            "Paging did not reveal older history or grow the loaded transcript"
        )
        attach(named: "transcript-paging")

        let jump = app.buttons["Jump to latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 10), "Jump to latest did not appear")
        attach(named: "transcript-jump-to-latest")
        jump.tap()
        XCTAssertTrue(newest.waitForExistence(timeout: 15), "Jump to latest did not reveal newest entry")
        XCTAssertTrue(newest.isHittable, "Jump to latest did not make newest entry visible")
    }

    private func promptCount(in app: XCUIApplication) -> Int {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Long-session prompt '")
        ).count
    }

    private func launchFixture() -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832"
        let bearer = environment["TEST_RUNNER_BEARER"] ?? ""
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        app.launchEnvironment["CCBearer"] = bearer
        app.launch()
        return app
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
