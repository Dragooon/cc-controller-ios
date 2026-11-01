import XCTest

/// The folded session list and what each row can do, in one launch.
final class SessionsListJourneyFlowTests: JourneyTestCase {
    func testSessionsListJourney() async throws {
        // The Dune turn would otherwise change that row while the journey swipes it.
        try await postFixture("/fixture/disable-live-event")
        try await postFixture("/fixture/sleeping-seed")
        let app = launchSignedIn()
        defer { app.terminate() }

        // It opens on the live sessions. This is the journey with the accessibility audit.
        XCTAssertTrue(app.staticTexts["Recents"].waitToExist(timeout: 60), "Recents did not load")
        let waiting = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(waiting.waitToExist(timeout: 75), "Session waiting on an approval was not listed")
        addScreenshot(named: "sessions-list")
        try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .textClipped])) { issue in
            guard let element = issue.element else { return false }
            // The rail's clock and battery ring are drawn over the part of a row that runs under it, and the audit
            // measures them against the row's own colours. Text never reaches the rail.
            if issue.auditType == .contrast, element.frame.maxX > 382 { return true }
            print("ACCESSIBILITY_ISSUE \(issue.compactDescription) type=\(element.elementType.rawValue) identifier=\(element.identifier) label=\(element.label) frame=\(element.frame)")
            return false
        }

        // Rows show their title and agent with a status glyph, and nothing else.
        let working = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(working.waitToExist(timeout: 20), "Working session was not listed")
        XCTAssertEqual(app.element(identifier: "session-title-pull-up-agentic-uw").label, "Pull Up Agentic UW")
        XCTAssertEqual(app.element(identifier: "session-agent-pull-up-agentic-uw").label, "agentic-uw")
        XCTAssertTrue(app.element(identifier: "session-status-pull-up-agentic-uw").exists, "Working row had no status glyph")
        let idle = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(idle.waitToExist(timeout: 20), "Idle session was not listed")
        let idleTitle = app.element(identifier: "session-title-dune-part-three-imax-tickets")
        XCTAssertEqual(idleTitle.label, "Dune Part Three IMAX tickets")
        XCTAssertEqual(app.element(identifier: "session-agent-dune-part-three-imax-tickets").label, "dune")
        for leak in ["idle", "ctx", "thinking"] {
            XCTAssertFalse(idle.label.contains(leak), "\(leak) leaked into the row: \(idle.label)")
        }
        XCTAssertTrue(app.element(identifier: "session-status-dune-part-three-imax-tickets").exists, "Idle row had no status glyph")
        XCTAssertLessThanOrEqual(idle.frame.height, 60, "Idle row was too tall")
        XCTAssertGreaterThanOrEqual(idleTitle.frame.minX - idle.frame.minX, 34, "Title left no room for the status glyph")

        // A working session reads as working, and one waiting on you as unread until you open it.
        // Approvals live in the session, not here.
        XCTAssertEqual(working.value as? String, "working")
        XCTAssertEqual(waiting.value as? String, "unread")
        XCTAssertFalse(app.staticTexts["Needs you"].exists, "The list still has a Needs you section")
        XCTAssertFalse(app.buttons["Allow"].exists, "An approval card is still in the list")
        let opened = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(opened.waitToExist(timeout: 20), "Staff session was not listed")
        XCTAssertEqual(opened.value as? String, "unread", "A session waiting on an approval was not unread")
        openSession("staff-account-exclusions", in: app)
        goBackToSessions(in: app)
        XCTAssertTrue(pollUntil(timeout: 10) { opened.value as? String == "read" }, "A waiting session stayed unread after it was opened")

        // Search opens inside the column.
        app.buttons["sessions-search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitToExist(timeout: 20), "Search field did not load")
        XCTAssertTrue(app.sessionsList.frame.contains(search.frame), "Search field left the column: field=\(search.frame), list=\(app.sessionsList.frame)")
        addScreenshot(named: "sessions-search")
        app.buttons["Close"].tap()
        XCTAssertTrue(idle.waitToExist(timeout: 10), "Rows did not come back after search")

        // Pin from a leading swipe, unpin from the menu.
        idle.swipeRight()
        let pin = app.buttons["session-pin-dune-part-three-imax-tickets"]
        XCTAssertTrue(pin.waitToExist(timeout: 10), "Pin action did not appear")
        pin.tap()
        let pinned = app.element(identifier: "sessions-pinned-header")
        XCTAssertTrue(pinned.waitToExist(timeout: 10), "Pinned section did not appear")
        XCTAssertTrue(idle.waitToExist(timeout: 10), "Pinned row was not listed")
        XCTAssertLessThan(idle.frame.minY, app.staticTexts["Recents"].frame.minY, "Pinned row was not above Recents")
        addScreenshot(named: "sessions-pinned")
        idle.press(forDuration: 1)
        let unpin = app.buttons["session-unpin-dune-part-three-imax-tickets"]
        XCTAssertTrue(unpin.waitToExist(timeout: 10), "Unpin action did not appear")
        unpin.tap()
        XCTAssertTrue(pinned.waitToDisappear(timeout: 10), "Pinned section stayed after unpinning")
        XCTAssertTrue(idle.waitToExist(timeout: 10), "Unpinned row did not return to Recents")

        // Archive from a trailing swipe, undo it, archive again, then unarchive from the section.
        idle.swipeLeft()
        let archive = app.buttons["session-archive-dune-part-three-imax-tickets"]
        XCTAssertTrue(archive.waitToExist(timeout: 10), "Archive action did not appear")
        archive.tap()
        let undo = app.buttons["archive-undo"]
        XCTAssertTrue(undo.waitToExist(timeout: 10), "Undo did not appear")
        undo.tap()
        XCTAssertTrue(idle.waitToExist(timeout: 10), "Undo did not restore the row")
        idle.swipeLeft()
        XCTAssertTrue(archive.waitToExist(timeout: 10), "Archive action did not come back")
        archive.tap()
        let archivedHeader = app.buttons["archived-section-header"]
        for _ in 0..<4 where !archivedHeader.exists { app.sessionsList.swipeUp() }
        XCTAssertTrue(archivedHeader.waitToExist(timeout: 10), "Archived section did not appear")
        archivedHeader.tap()
        addScreenshot(named: "sessions-archive-expanded")
        XCTAssertTrue(idle.waitToExist(timeout: 10), "Archived row did not appear")
        idle.swipeLeft()
        let unarchive = app.buttons["session-unarchive-dune-part-three-imax-tickets"]
        XCTAssertTrue(unarchive.waitToExist(timeout: 10), "Archived row did not offer Unarchive")
        unarchive.tap()
        XCTAssertTrue(idle.waitToExist(timeout: 10), "Unarchive did not restore the row")

        // Waking a sleeping session opens it, ending it from the menu puts it back to sleep, and it can be archived.
        let sleeping = app.buttons["sleeping-session-sleeping-dune"]
        for _ in 0..<8 where !sleeping.exists { app.sessionsList.swipeUp() }
        XCTAssertTrue(sleeping.waitToExist(timeout: 20), "Sleeping session was not listed")
        sleeping.tap()
        XCTAssertTrue(app.selectedSessionName.waitToExist(timeout: 30), "Woken session did not open")
        XCTAssertEqual(app.selectedSessionName.label, "Sleeping Dune")
        goBackToSessions(in: app)
        let woken = app.buttons["session-sleeping-dune"]
        for _ in 0..<8 where !woken.exists { app.sessionsList.swipeUp() }
        XCTAssertTrue(woken.waitToExist(timeout: 20), "Woken session was not listed")
        woken.press(forDuration: 1)
        let end = app.buttons["session-end-sleeping-dune"]
        XCTAssertTrue(end.waitToExist(timeout: 10), "End session action did not appear")
        end.tap()
        XCTAssertTrue(app.staticTexts["End this session?"].waitToExist(timeout: 10), "End confirmation did not appear")
        app.buttons["End session"].tap()
        XCTAssertTrue(sleeping.waitToExist(timeout: 20), "Ended session did not go back to sleep")
        sleeping.swipeLeft()
        let archiveSleeping = app.buttons["session-archive-sleeping-dune"]
        XCTAssertTrue(archiveSleeping.waitToExist(timeout: 10), "Sleeping session had no archive action")
        archiveSleeping.tap()
        XCTAssertTrue(app.buttons["archive-undo"].waitToExist(timeout: 10), "Archiving the sleeping session did not complete")
        XCTAssertTrue(sleeping.waitToDisappear(timeout: 10), "Archived sleeping session stayed in Recents")
    }
}
