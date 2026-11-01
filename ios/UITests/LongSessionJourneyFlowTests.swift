import XCTest

/// Reading a 500-message session on the folded Duo: opening at the bottom, staying there, and paging back.
final class LongSessionJourneyFlowTests: JourneyTestCase {
    private let newestText = "Checkpoint 499 is complete; the fixture remains responsive."

    func testLongSessionJourney() async throws {
        var app = launchSignedIn()
        defer { app.terminate() }
        openSession("long-session", in: app)

        // Opening reports its phases, and first rows arrive within budget.
        let performance = app.staticTexts["transcript-performance"]
        XCTAssertTrue(performance.waitToExist(timeout: 60), "Transcript performance probe did not load")
        let opened = performance.label
        let firstRows = try XCTUnwrap(
            opened.split(separator: " ")
                .first(where: { $0.hasPrefix("first_rows=") })
                .flatMap { Double($0.dropFirst("first_rows=".count)) },
            "Opening phases did not report first_rows: \(opened)"
        )
        XCTAssertLessThan(firstRows, 3000, "Transcript first_rows regressed: \(opened)")
        print("TRANSCRIPT_PERF_BEFORE \(opened)")

        // A usage update reaches the open session.
        try await postFixture("/fixture/usage-update")
        XCTAssertTrue(pollUntil(timeout: 10) { performance.label != opened }, "Usage update did not reach the open session")

        // It opens at the bottom and a registry event doesn't move it or refetch anything big.
        let newest = app.staticTexts[newestText]
        let composer = app.composer
        XCTAssertTrue(newest.waitToExist(timeout: 30), "Newest long-session entry did not load")
        XCTAssertTrue(composer.waitToExist(timeout: 10), "Composer did not load")
        addScreenshot(named: "long-session-open")
        try await postFixture("/fixture/registry-event")
        settle(2)
        XCTAssertTrue(newest.isHittable, "Newest entry left the screen after a registry event")
        XCTAssertLessThanOrEqual(newest.frame.maxY, composer.frame.minY, "Newest entry was not above the composer")
        XCTAssertFalse(app.jumpToLatest.exists, "A registry event moved the transcript off the bottom")
        var paths = try await fixtureRequestPaths()
        XCTAssertFalse(paths.contains { $0.contains("before=") }, "Opening paged before the loaded window: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("tail=400") }, "A registry event fetched an oversized tail: \(paths)")

        // A small scroll up keeps its place and pages nothing.
        let prompts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'Long-session prompt '"))
        let rowBefore = try XCTUnwrap(prompts.allElementsBoundByIndex.first(where: \.isHittable), "No transcript row was on screen")
        let rowLabel = rowBefore.label
        let middle = app.transcriptScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 150)))
        settle(2)
        XCTAssertTrue(app.staticTexts[rowLabel].isHittable, "The row on screen before a small scroll moved away")
        paths = try await fixtureRequestPaths()
        XCTAssertFalse(paths.contains { $0.contains("before=") }, "A small scroll paged earlier: \(paths)")
        if app.jumpToLatest.waitToExist(timeout: 2) {
            app.jumpToLatest.tap()
            XCTAssertTrue(app.jumpToLatest.waitToDisappear(timeout: 10), "Jump to latest did not go away")
        }

        // A send appends without rebuilding the transcript, through the reconnect it causes.
        let generation = app.staticTexts["transcript-stack-generation"]
        XCTAssertTrue(generation.waitToExist(timeout: 10), "Stack generation probe did not load")
        let generationBeforeSend = generation.label
        sendComposer("scroll-stability-send", in: app)
        let sent = app.staticTexts["scroll-stability-send"]
        XCTAssertTrue(sent.waitToExist(timeout: 15), "Sent message did not land in the transcript")
        settle(2)
        XCTAssertEqual(generation.label, generationBeforeSend, "The transcript rebuilt while the message was appended")
        XCTAssertTrue(sent.isHittable, "The sent message was not on screen")
        XCTAssertFalse(app.jumpToLatest.exists, "Sending moved the transcript off the bottom")

        // With the keyboard up, a long message stays pinned through its reconnect and slow delivery.
        let refetchesBefore = try await fixtureRequestPaths().filter { $0.contains("tail=400") }.count
        let marker = "keyboard-reconnect-\(UUID().uuidString)"
        sendComposer(marker + String(repeating: " wrap", count: 30), in: app)
        let pending = app.pendingPrompt(message: marker)
        let delivered = app.staticText(containing: marker)
        // A stall after the tap can outlast the held delivery, so the prompt may already be delivered.
        XCTAssertTrue(pollUntil(timeout: 10) { pending.exists || delivered.exists }, "Slow delivery did not show a pending bubble")
        XCTAssertTrue(pending.waitToDisappear(timeout: 15), "Pending bubble did not become delivered")
        XCTAssertTrue(delivered.waitToExist(timeout: 15), "Delivered message did not render")
        XCTAssertTrue(pollUntil(timeout: 15) { delivered.exists && delivered.isHittable }, "Delivered message was not at the bottom")
        XCTAssertFalse(app.jumpToLatest.exists, "Reconnect and slow delivery moved the transcript off the bottom")
        let deadline = Date().addingTimeInterval(15 * flowTimeScale())
        var refetches = refetchesBefore
        while refetches <= refetchesBefore, Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            refetches = try await fixtureRequestPaths().filter { $0.contains("tail=400") }.count
        }
        XCTAssertGreaterThan(refetches, refetchesBefore, "Slow delivery did not exercise the reconnect refetch")
        app.terminate()

        // With a short first page, scrolling back loads older history and offers a jump.
        app = launchSignedIn(session: "long-session", arguments: ["-CCFixtureInitialTranscriptTail", "20"])
        XCTAssertTrue(newest.waitToExist(timeout: 30), "Newest entry did not load on the short first page")
        XCTAssertFalse(app.jumpToLatest.exists, "Jump to latest showed at the bottom")
        let older = pageBackPastFirstPage(in: app)
        XCTAssertTrue(app.jumpToLatest.exists, "Jump to latest did not show while paged back")
        addScreenshot(named: "long-session-paged")

        // A registry blip in the middle shows no spinner and doesn't move the row.
        let blip = Task { try? await postFixtureRoute("/fixture/registry-blip") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(app.element(identifier: "session-loading").exists, "A registry blip showed a spinner over the transcript")
        XCTAssertTrue(older.isHittable, "A registry blip moved the row on screen")
        _ = await blip.value
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(older.isHittable, "The row on screen didn't stay after the registry reconcile")

        // Jump to latest goes back to the bottom, above the composer.
        XCTAssertTrue(app.jumpToLatest.waitToExist(timeout: 10), "Jump to latest did not show")
        app.jumpToLatest.tap()
        XCTAssertTrue(app.jumpToLatest.waitToDisappear(timeout: 10), "Jump to latest did not go away after the tap")
        XCTAssertTrue(pollUntil(timeout: 5) { newest.exists && newest.isHittable }, "Jump to latest did not show the newest entry")
        XCTAssertLessThanOrEqual(newest.frame.maxY, composer.frame.minY, "Newest entry was not above the composer")
    }
}
