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
        let transcriptScroll = app.scrollViews.firstMatch
        transcriptScroll.swipeDown()
        for _ in 0..<4 where !toolGroup.isHittable {
            transcriptScroll.swipeDown()
        }
        XCTAssertTrue(toolGroup.isHittable, "Tool group did not become tappable")
        for _ in 0..<3 {
            transcriptScroll.swipeUp(velocity: .fast)
        }
        toolGroup.tap()

        let expandedToolGroup = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Ran' AND label CONTAINS[c] 'tools' AND value == 'Expanded'")
        ).firstMatch
        XCTAssertTrue(expandedToolGroup.waitForExistence(timeout: 10), "Tool group did not expand")

        let bash = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Bash'")
        ).firstMatch
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
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15), "Session search button did not load")
        searchButton.tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Session search did not load")
        search.typeText("Long session")

        let longSession = app.buttons["session-long-session"]
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        longSession.tap()

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let jump = app.buttons["Jump to latest"]
        XCTAssertFalse(jump.exists, "Jump to latest is visible while the long session is bottom-anchored")
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10), "Transcript scroll view did not load")

        let pagingTop = app.descendants(matching: .any).matching(identifier: "transcript-paging-top").firstMatch
        let older = app.staticTexts["Long-session prompt 299: inspect the next checkpoint."]
        var sawJump = false
        for _ in 0..<60 {
            scrollView.swipeDown(velocity: .fast)
            sawJump = sawJump || jump.exists
            if pagingTop.exists || older.exists {
                break
            }
        }
        XCTAssertTrue(sawJump, "Jump to latest did not appear while paging through older history")
        XCTAssertTrue(
            pagingTop.exists || older.exists,
            "Paging did not reach the top row or prompt 299"
        )
        XCTAssertTrue(
            older.waitForExistence(timeout: 20),
            "Paging did not load prompt 299 below the initial boundary of 300"
        )

        let initialPrompt = app.staticTexts["Long-session prompt 300: inspect the next checkpoint."]
        XCTAssertTrue(initialPrompt.isHittable, "Initial prompt 300 is no longer visible after paging")
        XCTAssertTrue(
            scrollView.frame.contains(initialPrompt.frame),
            "Initial prompt 300 is outside the transcript scroll view"
        )
        attach(named: "transcript-paging")

        XCTAssertTrue(jump.waitForExistence(timeout: 10), "Jump to latest did not appear")
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 10), "Jump to latest did not disappear after tapping")
        XCTAssertTrue(newest.isHittable, "Jump to latest did not make newest entry visible")
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Transcript composer did not load")
        XCTAssertLessThanOrEqual(
            newest.frame.maxY,
            composer.frame.minY,
            "Newest checkpoint is not above the composer"
        )
        attach(named: "transcript-jump-to-latest")
    }

    func testSmallScrollUpKeepsPlace() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "small-scroll-up")
            app.terminate()
        }
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15), "Session search button did not load")
        searchButton.tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Session search did not load")
        search.typeText("Long session")

        let longSession = app.buttons["session-long-session"]
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        longSession.tap()

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10), "Transcript scroll view did not load")

        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end.withOffset(CGVector(dx: 0, dy: -150)))
        sleep(3)
        attach(named: "transcript-small-scroll-up")

        let recentPrompt = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Long-session prompt 49'")
        )
        let oldPrompt = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Long-session prompt 30'")
        )
        XCTAssertTrue(
            recentPrompt.allElementsBoundByIndex.contains(where: \.isHittable),
            "Small upward scroll lost the newest prompts"
        )
        XCTAssertFalse(
            oldPrompt.allElementsBoundByIndex.contains(where: \.isHittable),
            "Small upward scroll jumped to the initial page"
        )
    }

    func testJumpHiddenOnShortSession() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "short-session-jump")
            app.terminate()
        }

        let approvalSession = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(approvalSession.waitForExistence(timeout: 75), "Approval fixture session did not load")
        approvalSession.tap()

        let transcript = app.staticTexts["The session is ready to ask the owner before running the verification command."]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20), "Short-session transcript did not load")
        XCTAssertFalse(app.buttons["Jump to latest"].exists, "Jump to latest is visible for a fully visible short transcript")
    }

    func testJumpHiddenAfterLiveAppendAtBottom() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "live-append-jump")
            app.terminate()
        }

        let liveRow = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(liveRow.waitForExistence(timeout: 30), "Dune session row did not load")
        let workingPredicate = NSPredicate(format: "value == %@", "working")
        let workingExpectation = XCTNSPredicateExpectation(predicate: workingPredicate, object: liveRow)
        XCTAssertEqual(
            XCTWaiter.wait(for: [workingExpectation], timeout: 45),
            .completed,
            "Live event did not change Dune session to working"
        )
        liveRow.tap()

        let prompt = app.staticTexts["Find three good seats for Dune Part Three IMAX."]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "Dune transcript did not load")
        let workingStatus = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'working '")
        ).firstMatch
        XCTAssertTrue(workingStatus.waitForExistence(timeout: 15), "Working Dune status did not load")
        XCTAssertFalse(app.buttons["Jump to latest"].exists, "Jump to latest is visible after a live append at the bottom")
    }

    private func promptCount(in app: XCUIApplication) -> Int {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Long-session prompt '")
        ).count
    }

    private func launchFixture() -> XCUIApplication {
        let server = requiredRunnerVariable("TEST_RUNNER_SERVER_URL")
        let bearer = requiredRunnerVariable("TEST_RUNNER_BEARER")
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server, "-CCResetCache"]
        app.launchEnvironment["CCBearer"] = bearer
        dismissLeftoverNotificationPrompt()
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
