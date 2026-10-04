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

    func testAssistantReplyOffersCopyContextMenu() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "assistant-copy-context-menu")
            app.terminate()
        }
        let staffRow = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(staffRow.waitForExistence(timeout: 75), "Staff session row did not load")
        staffRow.tap()

        let assistantText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "The exclusion is ready for monitored rollout"))
            .firstMatch
        XCTAssertTrue(assistantText.waitForExistence(timeout: 15), "Assistant reply did not load")
        XCTAssertTrue(assistantText.isHittable, "Assistant reply is not visible")
        assistantText.press(forDuration: 1.0)

        let copyAction = app.menuItems["Copy"]
        XCTAssertTrue(copyAction.waitForExistence(timeout: 10), "Assistant reply context menu did not offer Copy")
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

    func testSubagentResultSheetAndTranscript() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "subagent-result-sheet")
            app.terminate()
        }
        let session = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(session.waitForExistence(timeout: 75), "Subagent fixture session did not load")
        session.tap()

        let resultRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH[c] 'subagent-result-row-'")
        ).firstMatch
        XCTAssertTrue(resultRow.waitForExistence(timeout: 20), "Subagent result row did not load")
        resultRow.tap()

        let sheetTitle = app.navigationBars["engineer result"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 15), "Subagent result sheet did not load")
        let fullResult = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Audit evidence is complete and the rule is ready")
        ).firstMatch
        XCTAssertTrue(fullResult.waitForExistence(timeout: 15), "Subagent full result did not load")

        let viewTranscript = app.buttons["View transcript"]
        XCTAssertTrue(viewTranscript.waitForExistence(timeout: 10), "View transcript action did not load")
        viewTranscript.tap()
        XCTAssertTrue(
            app.navigationBars["engineer"].waitForExistence(timeout: 15),
            "Subagent transcript did not open"
        )
    }

    func testOpeningPerformance() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "opening-performance")
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

        let performance = app.staticTexts["transcript-performance"]
        XCTAssertTrue(performance.waitForExistence(timeout: 60), "Transcript performance probe did not load")
        let before = performance.label
        XCTAssertTrue(before.contains("first_rows="), "Opening phases were incomplete: \(before)")
        let firstRows = try XCTUnwrap(
            before.split(separator: " ")
                .first(where: { $0.hasPrefix("first_rows=") })
                .flatMap { Double($0.dropFirst("first_rows=".count)) },
            "Opening phases did not report first_rows: \(before)"
        )
        XCTAssertLessThan(firstRows, 3000, "Transcript first_rows regressed: \(before)")
        print("TRANSCRIPT_PERF_BEFORE \(before)")

        try await postFixtureUsageUpdate()
        let deadline = Date().addingTimeInterval(10)
        while performance.label == before && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let after = performance.label
        XCTAssertNotEqual(after, before, "Usage update did not reach the open session")
        print("TRANSCRIPT_PERF_AFTER_USAGE \(after)")
    }

    func testOpeningLongSessionStaysAtBottomAfterReconcile() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "opening-bottom-after-reconnect")
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
        try await postFixture("/fixture/registry-event")
        try await Task.sleep(for: .seconds(3))

        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.exists, "Transcript composer disappeared after reconnect")
        XCTAssertTrue(newest.isHittable, "Newest long-session entry is not visible after reconnect")
        XCTAssertLessThanOrEqual(newest.frame.maxY, composer.frame.minY, "transcript-bottom is not visible after reconnect")
        XCTAssertFalse(app.buttons["Jump to latest"].exists, "Reconnect moved the transcript away from the bottom")
        let paths = try await fixtureRequestPaths()
        XCTAssertFalse(paths.contains { $0.contains("before=") }, "Opening/reconcile unexpectedly paged before the loaded window: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("tail=400") }, "Registry reconcile fetched an oversized tail: \(paths)")
    }

    func testSendingLongSessionKeepsBottomAfterReconnect() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "send-bottom-after-reconnect")
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
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Transcript composer did not load")
        composer.tap()
        composer.typeText("scroll-stability-send")
        app.buttons["composer-send"].tap()
        try await Task.sleep(for: .seconds(3))

        XCTAssertTrue(newest.isHittable, "Newest long-session entry is not visible after sending")
        XCTAssertFalse(app.buttons["Jump to latest"].exists, "Sending moved the transcript away from the bottom")
        let paths = try await fixtureRequestPaths()
        XCTAssertFalse(paths.contains { $0.contains("before=") }, "Sending unexpectedly paged before the loaded window: \(paths)")
    }

    func testRegistryBlipDoesNotShowSpinnerOrMoveMiddle() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "registry-blip-middle")
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
        let initialRow = app.staticTexts["Long-session prompt 499: inspect the next checkpoint."]
        XCTAssertTrue(initialRow.waitForExistence(timeout: 30), "Newest long-session row did not load")
        let visibleRow = app.staticTexts["Long-session prompt 299: inspect the next checkpoint."]
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<80 {
            scrollView.swipeDown(velocity: .fast)
            if visibleRow.exists && visibleRow.isHittable { break }
        }
        XCTAssertTrue(visibleRow.waitForExistence(timeout: 20), "Middle transcript row did not load after user paging")
        XCTAssertTrue(visibleRow.isHittable, "Middle transcript row was not visible before registry blip")

        let blip = Task { try? await postFixture("/fixture/registry-blip") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "session-loading").firstMatch.exists, "Registry blip replaced the loaded transcript with a spinner")
        XCTAssertTrue(visibleRow.isHittable, "Registry blip moved the visible transcript row")
        _ = await blip.value
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(visibleRow.isHittable, "Transcript did not return to the same row after registry reconcile")
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

        let older = app.staticTexts["Long-session prompt 299: inspect the next checkpoint."]
        var sawJump = false
        for _ in 0..<80 {
            scrollView.swipeDown(velocity: .fast)
            sawJump = sawJump || jump.exists
            if older.exists && older.isHittable { break }
        }
        XCTAssertTrue(sawJump, "Jump to latest did not appear while paging through older history")
        XCTAssertTrue(
            older.waitForExistence(timeout: 20),
            "Paging did not load prompt 299 below the initial boundary of 300"
        )
        XCTAssertTrue(older.isHittable, "Paging did not make prompt 299 visible")

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

    func testSmallScrollUpKeepsPlace() async throws {
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
        try await Task.sleep(for: .seconds(3))
        let visibleRows = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Long-session prompt '")
        )
        let rowBefore = try XCTUnwrap(
            visibleRows.allElementsBoundByIndex.first(where: \.isHittable),
            "No long-session transcript row was visible before the small scroll"
        )
        let rowLabel = rowBefore.label

        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end.withOffset(CGVector(dx: 0, dy: 150)))
        try await Task.sleep(for: .seconds(3))
        attach(named: "transcript-small-scroll-up")

        let sameRow = app.staticTexts[rowLabel]
        XCTAssertTrue(sameRow.waitForExistence(timeout: 5), "The row visible before the small scroll disappeared")
        XCTAssertTrue(sameRow.isHittable, "The row visible before the small scroll is no longer visible")
        let paths = try await fixtureRequestPaths()
        XCTAssertFalse(paths.contains { $0.contains("before=") }, "Small upward scroll unexpectedly paged earlier: \(paths)")
    }

    func testWarmOpenRendersCacheBeforeDelayedResponseAndKeepsPlace() async throws {
        var app = launchFixture(resetCache: true)
        let longSession = findLongSession(in: app)
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        let coldStart = Date()
        longSession.tap()
        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 15), "Cold transcript did not load")
        print("INSTANT_OPEN_COLD_MS \(Int(Date().timeIntervalSince(coldStart) * 1000))")
        let coldScroll = app.scrollViews.firstMatch
        XCTAssertTrue(coldScroll.waitForExistence(timeout: 10), "Cold transcript scroll view did not load")
        let cacheSeedRow = app.staticTexts["Long-session prompt 350: inspect the next checkpoint."]
        for _ in 0..<80 where !cacheSeedRow.isHittable {
            coldScroll.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(cacheSeedRow.waitForExistence(timeout: 20), "Paging did not fill the cache with a middle row")
        try await Task.sleep(for: .seconds(6))

        XCTAssertTrue(app.navigationBars.buttons["Sessions"].waitForExistence(timeout: 10), "Sessions back button did not load")
        app.navigationBars.buttons["Sessions"].tap()
        XCTAssertTrue(longSession.waitForExistence(timeout: 10), "Long session did not return to the list")
        app.terminate()

        app = launchFixture(resetCache: false)
        let warmSession = findLongSession(in: app)
        XCTAssertTrue(warmSession.waitForExistence(timeout: 75), "Long fixture session did not load after relaunch")
        let warmStart = Date()
        warmSession.tap()
        let warmNewest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(warmNewest.waitForExistence(timeout: 0.5), "Cached transcript was not visible before delayed response")
        print("INSTANT_OPEN_WARM_MS \(Int(Date().timeIntervalSince(warmStart) * 1000))")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "session-loading").firstMatch.exists, "Warm open showed the loading view")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(warmNewest.isHittable, "Bottom row was not visible after fresh transcript merge")
        app.terminate()

        app = launchFixture(resetCache: false)
        let middleSession = findLongSession(in: app)
        XCTAssertTrue(middleSession.waitForExistence(timeout: 75), "Long fixture session did not load for middle-scroll check")
        middleSession.tap()
        let cachedRow = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(cachedRow.waitForExistence(timeout: 1), "Cached transcript was not visible for middle-scroll check")
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10), "Transcript scroll view did not load")
        let visibleRows = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Long-session prompt '")
        )
        for _ in 0..<4 {
            scrollView.swipeDown(velocity: .fast)
        }
        let rowBeforeMerge = try XCTUnwrap(
            visibleRows.allElementsBoundByIndex.first(where: \.isHittable),
            "No cached middle row was visible before merge"
        )
        let rowLabel = rowBeforeMerge.label
        print("INSTANT_OPEN_MIDDLE_ROW \(rowLabel)")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(app.staticTexts[rowLabel].isHittable, "Fresh merge moved the cached middle row")
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

    private func postFixtureUsageUpdate() async throws {
        try await postFixture("/fixture/usage-update")
    }

    private func postFixture(_ path: String) async throws {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)\(path)") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "no response body"
            throw NSError(domain: "FixtureFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture request failed for \(path): \(body)"])
        }
    }

    private func fixtureRequestPaths() async throws -> [String] {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)/fixture/requests") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "FixtureFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture request log failed"])
        }
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return payload?["paths"] as? [String] ?? []
    }

    private func findLongSession(in app: XCUIApplication) -> XCUIElement {
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15), "Session search button did not load")
        searchButton.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Session search did not load")
        search.typeText("Long session")
        return app.buttons["session-long-session"]
    }

    private func launchFixture(resetCache: Bool = true) -> XCUIApplication {
        let server = requiredRunnerVariable("TEST_RUNNER_SERVER_URL")
        let bearer = requiredRunnerVariable("TEST_RUNNER_BEARER")
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        if resetCache { app.launchArguments.append("-CCResetCache") }
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
