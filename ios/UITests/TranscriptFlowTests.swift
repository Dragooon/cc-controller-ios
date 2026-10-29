import XCTest

@MainActor
final class TranscriptFlowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try await restartFixtureIfConfigured()
    }

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
        XCTAssertTrue(revealInTranscript(toolGroup, in: app), "Tool group did not load")
        let transcriptScroll = transcriptScroll(in: app)
        transcriptScroll.swipeDown()
        for _ in 0..<4 where !toolGroup.isHittable {
            transcriptScroll.swipeDown()
        }
        XCTAssertTrue(toolGroup.isHittable, "Tool group did not become tappable")
        for _ in 0..<3 {
            transcriptScroll.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(revealInTranscript(toolGroup, in: app), "Tool group did not return after fast swipes")
        for _ in 0..<4 where !toolGroup.isHittable {
            transcriptScroll.swipeDown()
        }
        XCTAssertTrue(toolGroup.isHittable, "Tool group did not become tappable after fast swipes")
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
        XCTAssertTrue(revealInTranscript(resultRow, in: app), "Subagent result row did not load")
        let transcriptScroll = transcriptScroll(in: app)
        for _ in 0..<4 where !resultRow.isHittable {
            transcriptScroll.swipeDown()
        }
        XCTAssertTrue(resultRow.isHittable, "Subagent result row did not become tappable")
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

    func testCompactionDividerOpensLongSummary() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "compaction-divider")
            app.terminate()
        }
        let session = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(session.waitForExistence(timeout: 75), "Compaction fixture session did not load")
        session.tap()

        let divider = app.buttons["compaction-divider"]
        XCTAssertTrue(divider.waitForExistence(timeout: 20), "Compaction divider did not load")
        XCTAssertTrue(
            divider.label.range(of: #"^Context compacted [0-2][0-9]:[0-5][0-9]$"#, options: .regularExpression) != nil,
            "Compaction divider caption was not a short timestamped label: \(divider.label)"
        )
        let summaryMarker = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "COMPACTION_SUMMARY_MARKER")
        ).firstMatch
        XCTAssertFalse(summaryMarker.exists, "Compaction summary leaked into the transcript")
        let transcriptScroll = transcriptScroll(in: app)
        scrollTowardOlderContent(until: divider, in: transcriptScroll)
        XCTAssertTrue(waitForHittable(divider, timeout: 10), "Compaction divider was not visible")
        attach(named: "compaction-caption")
        divider.tap()

        XCTAssertTrue(
            app.navigationBars["Context compacted"].waitForExistence(timeout: 15),
            "Compaction summary sheet did not open"
        )
        XCTAssertTrue(summaryMarker.waitForExistence(timeout: 15), "Compaction summary did not load in the sheet")
    }

    func testOpeningPerformance() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "opening-performance")
            app.terminate()
        }
        let search = openSessionSearch(in: app)
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
        let search = openSessionSearch(in: app)
        search.typeText("Long session")

        let longSession = app.buttons["session-long-session"]
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        longSession.tap()
        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        attach(named: "collection-long-session-open")
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
        let search = openSessionSearch(in: app)
        search.typeText("Long session")

        let longSession = app.buttons["session-long-session"]
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        longSession.tap()
        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let stackGeneration = app.staticTexts["transcript-stack-generation"]
        XCTAssertTrue(stackGeneration.waitForExistence(timeout: 10), "Transcript stack generation probe did not load")
        let generationBeforeSend = stackGeneration.label
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Transcript composer did not load")
        composer.tap()
        composer.typeText("scroll-stability-send")
        app.buttons["composer-send"].tap()
        let sentMessage = app.staticTexts["scroll-stability-send"]
        XCTAssertTrue(sentMessage.waitForExistence(timeout: 15), "Sent message did not land in the transcript")
        try await Task.sleep(for: .seconds(3))

        XCTAssertEqual(
            stackGeneration.label,
            generationBeforeSend,
            "Transcript stack rebuilt while the new message was appended"
        )
        XCTAssertTrue(newest.isHittable, "Newest long-session entry is not visible after sending")
        XCTAssertFalse(app.buttons["Jump to latest"].exists, "Sending moved the transcript away from the bottom")
        let paths = try await fixtureRequestPaths()
        XCTAssertFalse(paths.contains { $0.contains("before=") }, "Sending unexpectedly paged before the loaded window: \(paths)")
        attach(named: "collection-after-send")
    }

    func testRegistryBlipDoesNotShowSpinnerOrMoveMiddle() async throws {
        let app = launchFixture(initialTranscriptTail: 20)
        defer {
            audit(app: app, name: "registry-blip-middle")
            app.terminate()
        }
        let search = openSessionSearch(in: app)
        search.typeText("Long session")

        let longSession = app.buttons["session-long-session"]
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        longSession.tap()
        let initialRow = app.staticTexts["Long-session prompt 499: inspect the next checkpoint."]
        XCTAssertTrue(initialRow.waitForExistence(timeout: 30), "Newest long-session row did not load")
        let visibleRow = app.staticTexts["Long-session prompt 485: inspect the next checkpoint."]
        let scrollView = transcriptScroll(in: app)
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
        let app = launchFixture(openingSession: "long-session", initialTranscriptTail: 20)
        defer {
            audit(app: app, name: "paging")
            app.terminate()
        }

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let jump = app.buttons["Jump to latest"]
        XCTAssertFalse(jump.exists, "Jump to latest is visible while the long session is bottom-anchored")
        let scrollView = transcriptScroll(in: app)
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10), "Transcript scroll view did not load")

        let older = app.staticTexts["Long-session prompt 485: inspect the next checkpoint."]
        var sawJump = false
        for _ in 0..<80 {
            scrollView.swipeDown(velocity: .fast)
            sawJump = sawJump || jump.exists
            if older.exists && older.isHittable { break }
        }
        XCTAssertTrue(sawJump, "Jump to latest did not appear while paging through older history")
        XCTAssertTrue(
            older.waitForExistence(timeout: 20),
            "Paging did not load prompt 485 below the initial boundary of 490"
        )
        XCTAssertTrue(older.isHittable, "Paging did not make prompt 485 visible")

        let initialPrompt = app.staticTexts["Long-session prompt 490: inspect the next checkpoint."]
        XCTAssertTrue(initialPrompt.isHittable, "Initial prompt 490 is no longer visible after paging")
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

    func testScrollGuardCorrectsInjectedOvershoot() async throws {
        let app = launchFixture(initialTranscriptTail: 20, scrollGuardOvershoot: true)
        defer {
            audit(app: app, name: "scroll-guard-overshoot")
            app.terminate()
        }

        let longSession = findLongSession(in: app)
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        longSession.tap()
        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")

        let status = app.staticTexts["scroll-diagnostics-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 2), "Scroll diagnostic status did not load")
        let deadline = Date().addingTimeInterval(2)
        while status.label != "count=1 kind=overshoot recovered=true" && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(status.label, "count=1 kind=overshoot recovered=true", "Unexpected scroll diagnostic status")
        XCTAssertTrue(newest.isHittable, "Newest transcript row was not visible after overshoot correction")
    }

    func testSmallScrollUpKeepsPlace() async throws {
        let app = launchFixture(openingSession: "long-session")
        defer {
            audit(app: app, name: "small-scroll-up")
            app.terminate()
        }

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let scrollView = transcriptScroll(in: app)
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
        var app = launchFixture(resetCache: true, initialTranscriptTail: 20)
        let longSession = findLongSession(in: app)
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        let coldStart = Date()
        longSession.tap()
        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 15), "Cold transcript did not load")
        let coldInApp = try await firstRowsMilliseconds(in: app)
        print("INSTANT_OPEN_COLD_MS \(Int(Date().timeIntervalSince(coldStart) * 1000))")
        print("INSTANT_OPEN_COLD_IN_APP_MS \(String(format: "%.1f", coldInApp))")
        let coldScroll = transcriptScroll(in: app)
        XCTAssertTrue(coldScroll.waitForExistence(timeout: 10), "Cold transcript scroll view did not load")
        let cacheSeedRow = app.staticTexts["Long-session prompt 485: inspect the next checkpoint."]
        for _ in 0..<80 where !cacheSeedRow.isHittable {
            coldScroll.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(cacheSeedRow.waitForExistence(timeout: 20), "Paging did not fill the cache with a middle row")
        XCTAssertTrue(app.navigationBars.buttons["Sessions"].waitForExistence(timeout: 10), "Sessions back button did not load")
        app.navigationBars.buttons["Sessions"].tap()
        XCTAssertTrue(longSession.waitForExistence(timeout: 10), "Long session did not return to the list")
        app.terminate()

        app = launchFixture(resetCache: false, initialTranscriptTail: 20)
        let warmSession = findLongSession(in: app)
        XCTAssertTrue(warmSession.waitForExistence(timeout: 75), "Long fixture session did not load after relaunch")
        let warmStart = Date()
        warmSession.tap()
        let warmNewest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(warmNewest.waitForExistence(timeout: 0.5), "Cached transcript was not visible before delayed response")
        let warmInApp = try await firstRowsMilliseconds(in: app)
        print("INSTANT_OPEN_WARM_MS \(Int(Date().timeIntervalSince(warmStart) * 1000))")
        print("INSTANT_OPEN_WARM_IN_APP_MS \(String(format: "%.1f", warmInApp))")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "session-loading").firstMatch.exists, "Warm open showed the loading view")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(warmNewest.isHittable, "Bottom row was not visible after fresh transcript merge")
        app.terminate()

        app = launchFixture(resetCache: false, initialTranscriptTail: 20)
        let middleSession = findLongSession(in: app)
        XCTAssertTrue(middleSession.waitForExistence(timeout: 75), "Long fixture session did not load for middle-scroll check")
        middleSession.tap()
        let cachedRow = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(cachedRow.waitForExistence(timeout: 1), "Cached transcript was not visible for middle-scroll check")
        let scrollView = transcriptScroll(in: app)
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
        XCTAssertNotEqual(
            rowLabel,
            "Long-session prompt 499: inspect the next checkpoint.",
            "Middle-scroll check did not move off the newest cached row"
        )
        print("INSTANT_OPEN_MIDDLE_ROW \(rowLabel)")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(app.staticTexts[rowLabel].isHittable, "Fresh merge moved the cached middle row")
    }

    func testCurrentCacheReopensWithoutSyncingGlyph() async throws {
        let app = launchFixture(resetCache: true, initialTranscriptTail: 20)
        defer {
            audit(app: app, name: "current-cache-no-glyph")
            app.terminate()
        }

        let session = findLongSession(in: app)
        XCTAssertTrue(session.waitForExistence(timeout: 75), "Long session did not load")
        session.tap()
        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Initial transcript did not load")

        let back = app.navigationBars.buttons["Sessions"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Sessions back button did not load")
        back.tap()
        XCTAssertTrue(session.waitForExistence(timeout: 10), "Long session did not return to the list")
        session.tap()

        let loading = app.descendants(matching: .any).matching(identifier: "session-loading").firstMatch
        let deadline = Date().addingTimeInterval(1.5)
        var sawVisibleRow = false
        while Date() < deadline {
            XCTAssertFalse(loading.exists, "A current cache showed the syncing glyph")
            sawVisibleRow = sawVisibleRow || (newest.exists && newest.isHittable)
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(sawVisibleRow, "Current cached rows were not visible during the polling window")
    }

    func testChangedSessionReopensThroughSyncingGlyph() async throws {
        var app = launchFixture(resetCache: true, initialTranscriptTail: 20)
        let fixtureControlURL = ProcessInfo.processInfo.environment["TEST_RUNNER_FIXTURE_CONTROL_URL"]
        addTeardownBlock { [fixtureControlURL] in
            guard let fixtureControlURL,
                  let url = URL(string: "\(fixtureControlURL)/fixture/transcript-delay") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"ms":0}"#.utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
        defer {
            audit(app: app, name: "changed-session-syncing-glyph")
            app.terminate()
        }

        let originalText = "Checkpoint 499 is complete; the fixture remains responsive."
        let session = findLongSession(in: app)
        XCTAssertTrue(session.waitForExistence(timeout: 75), "Long session did not load")
        session.tap()
        XCTAssertTrue(app.staticTexts[originalText].waitForExistence(timeout: 30), "Initial transcript did not load")

        let back = app.navigationBars.buttons["Sessions"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Sessions back button did not load")
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 5), "Session detail did not disappear after navigating back")
        XCTAssertTrue(session.waitForExistence(timeout: 10), "Long session did not return to the list")
        try await Task.sleep(for: .seconds(1))
        app.terminate()

        let marker = "Fixture transcript changed while away."
        try await postFixtureJSON("/fixture/transcript-delay", body: ["ms": 3000])
        try await postFixtureJSON(
            "/fixture/transcript-change",
            body: ["sessionId": "long-session", "text": marker]
        )

        app = launchFixture(resetCache: false, initialTranscriptTail: 20)
        let reopenedSession = findLongSession(in: app)
        XCTAssertTrue(reopenedSession.waitForExistence(timeout: 75), "Long session did not load after relaunch")
        reopenedSession.tap()

        let loading = app.descendants(matching: .any).matching(identifier: "session-loading").firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 2), "Changed session did not show the syncing glyph")
        XCTAssertEqual(loading.label, "Loading messages")
        let staleNewest = app.staticTexts[originalText]
        let loadingDeadline = Date().addingTimeInterval(2)
        while loading.exists && Date() < loadingDeadline {
            XCTAssertFalse(staleNewest.exists, "Cached newest row was visible before the transcript became current")
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(loading.waitForNonExistence(timeout: 8), "Syncing glyph did not clear after the delayed transcript")
        let changedEntry = app.staticTexts[marker]
        XCTAssertTrue(changedEntry.waitForExistence(timeout: 10), "Newest changed entry did not render")
        XCTAssertTrue(changedEntry.isHittable, "Newest changed entry is not visible")
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

    func testKeyboardBottomStaysPinnedThroughReconnectAndDelayedDelivery() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "keyboard-reconnect-delivery")
            app.terminate()
        }
        let longSession = findLongSession(in: app)
        XCTAssertTrue(longSession.waitForExistence(timeout: 75), "Long fixture session did not load")
        longSession.tap()

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Transcript composer did not load")
        composer.tap()
        let marker = "keyboard-reconnect-\(UUID().uuidString)"
        composer.typeText(marker + String(repeating: " wrap", count: 30))
        app.buttons["composer-send"].tap()

        let pending = app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "Delayed delivery did not show a pending prompt")
        XCTAssertTrue(waitForNonExistence(of: pending, timeout: 15), "Pending prompt did not become delivered")
        let delivered = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 15), "Delayed delivered prompt did not render")
        XCTAssertTrue(waitForHittable(delivered, timeout: 15), "Delayed delivered prompt was not visible at the bottom")
        XCTAssertFalse(app.buttons["Jump to latest"].exists, "Reconnect and delayed delivery moved the transcript away from the bottom")
        let paths = try await fixtureRequestPaths()
        XCTAssertTrue(paths.contains { $0.contains("tail=400") }, "Delayed delivery did not exercise reconnect refetch: \(paths)")
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

    func testRunningSpinnerDoesNotReflowTranscript() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "spinner-transcript-reflow")
            app.terminate()
        }

        let liveRow = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(liveRow.waitForExistence(timeout: 30), "Working underwriting session did not load")
        liveRow.tap()

        let paragraphText = "I am checking the active underwriting run while the agents continue. The latest model routing and fixture coverage checks are still running while the owner reviews the newest underwriting decision evidence."
        XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 20), "Working underwriting transcript did not load")
        guard let paragraph = app.staticTexts.allElementsBoundByIndex.first(where: { $0.label == paragraphText }) else {
            XCTFail("Working underwriting assistant paragraph did not load")
            return
        }
        var samples: [CGRect] = []
        for _ in 0..<30 {
            samples.append(paragraph.frame)
            try await Task.sleep(for: .milliseconds(100))
        }
        let minLeading = samples.map(\.minX).min() ?? 0
        let maxLeading = samples.map(\.minX).max() ?? 0
        let minTrailing = samples.map(\.maxX).min() ?? 0
        let maxTrailing = samples.map(\.maxX).max() ?? 0
        let minTop = samples.map(\.minY).min() ?? 0
        let maxTop = samples.map(\.minY).max() ?? 0
        let minBottom = samples.map(\.maxY).min() ?? 0
        let maxBottom = samples.map(\.maxY).max() ?? 0
        let minHeight = samples.map(\.height).min() ?? 0
        let maxHeight = samples.map(\.height).max() ?? 0
        print("SPINNER_TRANSCRIPT_FRAMES samples=\(samples.count) leading=\(minLeading)...\(maxLeading) trailing=\(minTrailing)...\(maxTrailing) top=\(minTop)...\(maxTop) bottom=\(minBottom)...\(maxBottom) height=\(minHeight)...\(maxHeight)")
        XCTAssertLessThanOrEqual(maxLeading - minLeading, 1, "Spinner changed transcript paragraph leading edge: \(samples)")
        XCTAssertLessThanOrEqual(maxTrailing - minTrailing, 1, "Spinner changed transcript paragraph trailing edge: \(samples)")
        XCTAssertLessThanOrEqual(maxTop - minTop, 1, "Spinner changed transcript paragraph top edge: \(samples)")
        XCTAssertLessThanOrEqual(maxBottom - minBottom, 1, "Spinner changed transcript paragraph bottom edge: \(samples)")
        XCTAssertLessThanOrEqual(maxHeight - minHeight, 1, "Spinner changed transcript paragraph wrapping: \(samples)")
    }

    private func scrollTowardOlderContent(until element: XCUIElement, in scrollView: XCUIElement) {
        for _ in 0..<4 {
            guard !element.isHittable else { return }
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
        }
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

    private func postFixtureJSON(_ path: String, body: [String: Any]) async throws {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)\(path)") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "no response body"
            throw NSError(domain: "FixtureFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture request failed for \(path): \(responseBody)"])
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

    private func firstRowsMilliseconds(in app: XCUIApplication) async throws -> Double {
        let performance = app.staticTexts["transcript-performance"]
        XCTAssertTrue(performance.waitForExistence(timeout: 10), "Transcript performance probe did not load")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let label = performance.label
            if let value = label.split(separator: " ")
                .first(where: { $0.hasPrefix("first_rows=") })
                .flatMap({ Double($0.dropFirst("first_rows=".count)) }) {
                return value
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Transcript first_rows phase did not load: \(performance.label)")
        throw NSError(domain: "TranscriptFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Transcript first_rows phase did not load"])
    }

    private func findLongSession(in app: XCUIApplication) -> XCUIElement {
        let search = openSessionSearch(in: app)
        search.typeText("Long session")
        return app.buttons["session-long-session"]
    }

    private func launchFixture(
        openingSession: String? = nil,
        resetCache: Bool = true,
        initialTranscriptTail: Int? = nil,
        scrollGuardOvershoot: Bool = false
    ) -> XCUIApplication {
        let server = requiredRunnerVariable("TEST_RUNNER_SERVER_URL")
        let bearer = requiredRunnerVariable("TEST_RUNNER_BEARER")
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        if let openingSession { app.launchArguments += ["-CCSession", openingSession] }
        if resetCache { app.launchArguments.append("-CCResetCache") }
        if let initialTranscriptTail {
            app.launchArguments += ["-CCFixtureInitialTranscriptTail", String(initialTranscriptTail)]
        }
        if scrollGuardOvershoot {
            app.launchArguments.append("-CCScrollGuardTestOvershoot")
        }
        configureTranscriptEngine(app)
        app.launchEnvironment["CCBearer"] = bearer
        configureLiveIndicatorAnimations(app)
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

@MainActor
private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"),
        object: element
    )
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
}

@MainActor
private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if element.exists && element.isHittable { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
}
