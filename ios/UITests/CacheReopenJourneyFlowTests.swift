import XCTest

/// Reopening a long session from its cache on the folded Duo, as it is and after it has changed.
final class CacheReopenJourneyFlowTests: JourneyTestCase {
    private let newestText = "Checkpoint 499 is complete; the fixture remains responsive."
    private let shortFirstPage = ["-CCFixtureInitialTranscriptTail", "20"]

    func testCacheReopenJourney() async throws {
        // Filling the cache: open, page back past the first page, return to the list.
        var app = launchSignedIn(resetCache: true, arguments: shortFirstPage)
        defer { app.terminate() }
        openSession("long-session", in: app)
        let newest = app.staticTexts[newestText]
        XCTAssertTrue(newest.waitToExist(timeout: 30), "Cold transcript did not load")
        let cold = try await firstRowsMilliseconds(in: app)
        print("INSTANT_OPEN_COLD_IN_APP_MS \(String(format: "%.1f", cold))")
        let older = app.staticTexts["Long-session prompt 485: inspect the next checkpoint."]
        for _ in 0..<80 where !older.isSafelyHittable { app.transcriptScroll.swipeDown(velocity: .fast) }
        XCTAssertTrue(older.waitToExist(timeout: 20), "Paging did not fill the cache with a middle row")
        goBackToSessions(in: app)

        // A session that hasn't changed reopens from the cache with no syncing glyph, even in the same launch.
        openSession("long-session", in: app)
        let loading = app.element(identifier: "session-loading")
        let deadline = Date().addingTimeInterval(1.5)
        var sawRow = false
        while Date() < deadline {
            XCTAssertFalse(loading.exists, "A current cache showed the syncing glyph")
            sawRow = sawRow || (newest.exists && newest.isHittable)
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(sawRow, "Cached rows were not on screen while checking for the glyph")
        goBackToSessions(in: app)
        app.terminate()

        // A cold launch shows the cache before a slow response, and the merge doesn't move a row in the middle.
        let scale = flowTimeScale()
        try await postFixtureJSON("/fixture/transcript-delay", body: ["ms": Int(2000 * scale)])
        app = launchSignedIn(resetCache: false, arguments: shortFirstPage)
        openSession("long-session", in: app)
        XCTAssertTrue(newest.waitToExist(timeout: 1), "Cached transcript did not show before the slow response")
        XCTAssertFalse(loading.exists, "A warm open showed the loading view")
        let warm = try await firstRowsMilliseconds(in: app)
        print("INSTANT_OPEN_WARM_IN_APP_MS \(String(format: "%.1f", warm))")
        for _ in 0..<4 { app.transcriptScroll.swipeDown(velocity: .fast) }
        let prompts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'Long-session prompt '"))
        let rowLabel = try XCTUnwrap(prompts.allElementsBoundByIndex.first(where: \.isHittable), "No cached middle row was on screen").label
        XCTAssertNotEqual(rowLabel, "Long-session prompt 499: inspect the next checkpoint.", "Scrolling did not leave the newest row")
        try await Task.sleep(for: .seconds(Int(2 * scale) + 1))
        XCTAssertTrue(app.staticTexts[rowLabel].isHittable, "The fresh merge moved a cached row in the middle")
        app.terminate()

        // A session that changed while away shows the glyph rather than stale rows, until it's current.
        let marker = "Fixture transcript changed while away."
        try await postFixtureJSON("/fixture/transcript-delay", body: ["ms": Int(3000 * scale)])
        try await postFixtureJSON("/fixture/transcript-change", body: ["sessionId": "long-session", "text": marker])
        app = launchSignedIn(resetCache: false, arguments: shortFirstPage)
        openSession("long-session", in: app)
        XCTAssertTrue(loading.waitToExist(timeout: 2 * scale), "A changed session did not show the syncing glyph")
        XCTAssertEqual(loading.label, "Loading messages")
        // The original row stays in the current transcript too, so it only counts as stale while the glyph is still up.
        let loadingDeadline = Date().addingTimeInterval(2 * scale)
        while loading.exists && Date() < loadingDeadline {
            let staleVisible = newest.exists
            XCTAssertFalse(staleVisible && loading.exists, "A stale row showed before the transcript was current")
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(loading.waitToDisappear(timeout: 8 * scale), "The syncing glyph did not clear")
        let changed = app.staticTexts[marker]
        XCTAssertTrue(changed.waitToExist(timeout: 10), "The changed entry did not render")
        XCTAssertTrue(changed.isHittable, "The changed entry was not on screen")
    }

    private func firstRowsMilliseconds(in app: XCUIApplication) async throws -> Double {
        let performance = app.staticTexts["transcript-performance"]
        XCTAssertTrue(performance.waitToExist(timeout: 10), "Transcript performance probe did not load")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let value = performance.label.split(separator: " ")
                .first(where: { $0.hasPrefix("first_rows=") })
                .flatMap { Double($0.dropFirst("first_rows=".count)) }
            if let value { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("first_rows did not load: \(performance.label)")
        return 0
    }
}
