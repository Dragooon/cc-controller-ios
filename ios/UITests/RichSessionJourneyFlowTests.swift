import XCTest

/// A session with everything in its transcript, and a draft that has to survive looking at all of it.
final class RichSessionJourneyFlowTests: JourneyTestCase {
    func testRichSessionJourney() async throws {
        var app = launchSignedIn()
        defer { app.terminate() }
        openSession("staff-account-exclusions", in: app)

        // Denying the approval brings the composer back. A draft starts here and has to last.
        let deny = app.buttons["Deny"]
        XCTAssertTrue(deny.waitToExist(timeout: 15), "Approval's Deny did not load")
        deny.tap()
        let composer = app.composer
        XCTAssertTrue(composer.waitToExist(timeout: 15), "Composer did not come back after Deny")
        let draft = "draft-survives-\(UUID().uuidString)"
        typeInComposer(draft, in: app)
        XCTAssertEqual(composer.typedText, draft)
        dismissKeyboard(in: app)

        // A long press on a reply offers Copy.
        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "The exclusion is ready for monitored rollout"))
            .firstMatch
        XCTAssertTrue(revealInTranscript(reply, in: app), "Assistant reply did not load")
        for _ in 0..<4 where !reply.isHittable { app.transcriptScroll.swipeDown() }
        XCTAssertTrue(reply.isHittable, "Assistant reply was not on screen")
        reply.press(forDuration: 1.0)
        XCTAssertTrue(app.menuItems["Copy"].waitToExist(timeout: 10), "Reply's menu did not offer Copy")
        dismissMenu(in: app)

        // A tool group survives fast scrolling, expands and opens its detail sheet.
        let toolGroup = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Ran' AND label CONTAINS[c] 'tools'")).firstMatch
        XCTAssertTrue(revealInTranscript(toolGroup, in: app), "Tool group did not load")
        let scroll = app.transcriptScroll
        for _ in 0..<3 { scroll.swipeUp(velocity: .fast) }
        XCTAssertTrue(revealInTranscript(toolGroup, in: app), "Tool group did not come back after fast swipes")
        for _ in 0..<4 where !toolGroup.isHittable { scroll.swipeDown() }
        XCTAssertTrue(toolGroup.isHittable, "Tool group was not tappable after fast swipes")
        toolGroup.tap()
        let expanded = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Ran' AND label CONTAINS[c] 'tools' AND value == 'Expanded'")).firstMatch
        XCTAssertTrue(expanded.waitToExist(timeout: 10), "Tool group did not expand")
        let bash = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'Bash'")).firstMatch
        XCTAssertTrue(bash.waitToExist(timeout: 15), "Expanded Bash row did not load")
        bash.tap()
        XCTAssertTrue(app.staticTexts["OUTPUT"].waitToExist(timeout: 15), "Tool detail's output did not load")
        addScreenshot(named: "rich-tool-sheet")
        // On the rail, not in the navigation bar.
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitToExist(timeout: 10), "Tool detail's Close did not load")
        close.tap()
        XCTAssertTrue(toolGroup.waitToExist(timeout: 10), "Transcript did not come back after closing the sheet")

        // The compaction divider is short, and its summary only shows in its own sheet.
        let divider = app.buttons["compaction-divider"]
        let summary = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "COMPACTION_SUMMARY_MARKER")).firstMatch
        XCTAssertFalse(summary.exists, "Compaction summary leaked into the transcript")
        XCTAssertTrue(revealInTranscript(divider, in: app), "Compaction divider did not load")
        for _ in 0..<12 where !divider.isSafelyHittable {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
        }
        XCTAssertTrue(divider.isSafelyHittable, "Compaction divider was not on screen")
        XCTAssertTrue(
            divider.label.range(of: #"^Context compacted [0-2][0-9]:[0-5][0-9]$"#, options: .regularExpression) != nil,
            "Divider caption was not a short timestamped label: \(divider.label)"
        )
        divider.tap()
        XCTAssertTrue(app.navigationBars["Context compacted"].waitToExist(timeout: 15), "Summary sheet did not open")
        XCTAssertTrue(summary.waitToExist(timeout: 15), "Summary did not load in its sheet")
        addScreenshot(named: "rich-compaction-sheet")
        close.tap()
        XCTAssertTrue(app.navigationBars["Context compacted"].waitToDisappear(timeout: 10), "Summary sheet did not close")

        // A subagent result opens its sheet, then its transcript. Back returns to the session with the draft.
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH[c] 'subagent-result-row-'")).firstMatch
        XCTAssertTrue(revealInTranscript(result, in: app, maxSwipes: 12), "Subagent result row did not load")
        for _ in 0..<4 where !result.isHittable { scroll.swipeDown() }
        XCTAssertTrue(result.isHittable, "Subagent result row was not tappable")
        result.tap()
        XCTAssertTrue(app.navigationBars["engineer result"].waitToExist(timeout: 15), "Subagent result sheet did not load")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "Audit evidence is complete and the rule is ready")).firstMatch.waitToExist(timeout: 15),
            "Subagent's full result did not load"
        )
        let viewTranscript = app.buttons["View transcript"]
        XCTAssertTrue(viewTranscript.waitToExist(timeout: 10), "View transcript did not load")
        viewTranscript.tap()
        XCTAssertTrue(app.navigationBars["engineer"].waitToExist(timeout: 15), "Subagent transcript did not open")
        let backFromSubagent = app.buttons["BackButton"]
        XCTAssertTrue(backFromSubagent.waitToExist(timeout: 10), "Subagent screen had no back button")
        backFromSubagent.tap()
        XCTAssertTrue(composer.waitToExist(timeout: 10), "Composer did not come back after the subagent")
        XCTAssertEqual(composer.typedText, draft, "Draft was lost after the subagent")

        // A subagent card pushes its screen, and the card and draft are there on the way back.
        let card = app.buttons["subagent-card-agent-done"]
        let bottomStack = app.element(identifier: "bottom-stack")
        XCTAssertTrue(bottomStack.waitToExist(timeout: 15), "Bottom stack did not load")
        XCTAssertTrue(revealInTranscript(card, in: app, maxSwipes: 12), "Subagent card did not load")
        var cardClear = false
        for _ in 0..<8 {
            if card.exists, card.frame.maxY <= bottomStack.frame.minY { cardClear = true; break }
            scroll.swipeDown()
        }
        XCTAssertTrue(cardClear, "Subagent card stayed under the bottom stack")
        card.tap()
        XCTAssertTrue(app.navigationBars["engineer"].waitToExist(timeout: 15), "Subagent screen did not load")
        addScreenshot(named: "rich-subagent-pushed")
        backFromSubagent.tap()
        XCTAssertTrue(app.staticTexts["Staff Account Exclusions Atlas Monitoring"].waitToExist(timeout: 15), "Session did not come back after the subagent")
        XCTAssertTrue(app.buttons["subagent-card-agent-done"].waitToExist(timeout: 15), "Subagent card was gone after returning")
        XCTAssertEqual(composer.typedText, draft, "Draft was lost after the subagent card")

        // The draft survives backgrounding, a registry event, and a relaunch.
        sendToBackground(app)
        app.activate()
        XCTAssertTrue(composer.waitToExist(timeout: 10), "Composer did not come back after foregrounding")
        XCTAssertEqual(composer.typedText, draft, "Draft was lost after backgrounding")
        try await postFixture("/fixture/registry-event")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(composer.typedText, draft, "Draft was lost after a registry event")
        // Drafts save with a short debounce, so give that a moment before killing the app.
        try await Task.sleep(for: .seconds(1))
        app.terminate()
        app = launchSignedIn(resetCache: false)
        openSession("staff-account-exclusions", in: app)
        XCTAssertTrue(composer.waitToExist(timeout: 15), "Composer did not load after relaunch")
        XCTAssertEqual(composer.typedText, draft, "Draft was not restored after relaunch")
    }

    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        // A held drag: the keyboard follows the finger out, and a quick swipe only scrolls.
        let start = app.transcriptScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
        XCTAssertTrue(pollUntil(timeout: 5) { app.keyboards.count == 0 }, "Keyboard did not go away")
    }

    private func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(app.menuItems["Copy"].waitToDisappear(timeout: 5), "Reply's menu did not close")
    }
}
