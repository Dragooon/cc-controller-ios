import XCTest

/// The open Duo's two columns, their shared header and the "needs you" capsule, in one launch.
final class ColumnsAndCapsuleJourneyFlowTests: JourneyTestCase {
    override var posture: DuoPosture { .unfolded }

    func testColumnsAndCapsuleJourney() throws {
        let app = launchSignedIn(session: "staff-account-exclusions", extraControllers: true)
        defer { app.terminate() }
        let sizeClass = app.element(identifier: "horizontal-size-class")
        XCTAssertTrue(sizeClass.waitToExist(timeout: 30), "Size-class probe did not load")
        XCTAssertEqual(sizeClass.label, "regular", "The open Duo was not regular width")
        let title = app.selectedSessionName
        XCTAssertTrue(title.waitToExist(timeout: 75), "Selected session did not open")
        XCTAssertEqual(title.label, "Staff Account Exclusions Atlas Monitoring")
        let sidebar = app.sessionsList
        XCTAssertTrue(sidebar.waitToExist(timeout: 20), "Sessions list was not beside the detail")
        let detail = app.element(identifier: "session-detail-frame")
        XCTAssertTrue(detail.waitToExist(timeout: 30), "Detail did not load")
        assertDetailIsBesideSidebar(detail: detail, in: app)
        assertHeaderAlignment(in: app, sidebarOpen: true)
        addScreenshot(named: "columns-both")

        // Switching sessions keeps both columns.
        let other = app.buttons["session-long-session"]
        XCTAssertTrue(other.waitToExist(timeout: 20), "The other session was not listed")
        other.tap()
        XCTAssertTrue(pollUntil(timeout: 30) { title.exists && title.label == "Long session" }, "Second session did not open")
        XCTAssertTrue(sidebar.exists, "Sessions list went away after switching sessions")
        assertDetailIsBesideSidebar(detail: detail, in: app)

        // New session and search stay inside the sidebar.
        let newSession = app.buttons["new-session"]
        XCTAssertTrue(newSession.waitToExist(timeout: 20), "Sidebar's New session did not load")
        XCTAssertTrue(sidebar.frame.contains(newSession.frame), "New session left the sidebar: button=\(newSession.frame), sidebar=\(sidebar.frame)")
        let search = app.textFields["sessions-search-field"]
        XCTAssertTrue(search.waitToExist(timeout: 20), "Sidebar search did not load")
        XCTAssertTrue(sidebar.frame.contains(search.frame), "Search left the sidebar: field=\(search.frame), sidebar=\(sidebar.frame)")

        // There's one toggle, in the bar of whichever column is showing. Closing widens the detail, behind a blur that lifts.
        let toggles = app.buttons.matching(identifier: "sidebar-toggle")
        XCTAssertEqual(toggles.count, 1, "Expected one sidebar toggle while open")
        let openExtent = extent(of: detail)
        toggles.firstMatch.tap()
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "Sidebar did not close")
        XCTAssertTrue(pollUntil(timeout: 10) { extent(of: detail) > openExtent + 20 }, "Hiding the sidebar did not widen the detail")
        settle(1)
        XCTAssertEqual(toggles.count, 1, "Expected one sidebar toggle while closed")
        XCTAssertTrue(app.element(identifier: "detail-motion-cover").waitToDisappear(timeout: 5), "The blur stayed after the sidebar settled")
        assertHeaderAlignment(in: app)
        let closedExtent = extent(of: detail)
        addScreenshot(named: "columns-sidebar-closed")

        // Only now does the composer have room to hit its readable width, and it stops there.
        let composer = app.composer
        XCTAssertTrue(composer.waitToExist(timeout: 20), "Composer did not load")
        XCTAssertGreaterThan(composer.frame.width, 600, "Composer did not grow into the wider detail")
        XCTAssertLessThanOrEqual(composer.frame.width, 760, "Composer went past its readable width")

        // Scrolled back, a toggle resizes the detail without moving the row on screen.
        let scroll = app.transcriptScroll
        XCTAssertTrue(scroll.waitToExist(timeout: 20), "Transcript did not load")
        for _ in 0..<3 {
            scroll.swipeDown()
            settle(1)
        }
        let prompts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'Long-session prompt '"))
        let row = prompts.allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(row, "No transcript row was on screen after scrolling")
        let rowLabel = row?.label ?? ""
        toggles.firstMatch.tap()
        XCTAssertTrue(sidebar.waitToExist(timeout: 20), "Sidebar did not reopen")
        XCTAssertTrue(pollUntil(timeout: 10) { extent(of: detail) < closedExtent - 20 }, "Showing the sidebar did not narrow the detail")
        settle(1)
        XCTAssertEqual(toggles.count, 1, "Expected one sidebar toggle after reopening")
        assertFrame(toggles.firstMatch.frame, equals: openFrame, "Sidebar toggle moved while reopening")
        assertHeaderAlignment(in: app, sidebarOpen: true)
        XCTAssertTrue(app.staticTexts[rowLabel].waitToExist(timeout: 10), "Transcript row went away across the toggle")
        XCTAssertTrue(app.staticTexts[rowLabel].isHittable, "The toggle moved the transcript")
        XCTAssertFalse(
            app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."].isHittable,
            "The toggle remounted the transcript at the latest row"
        )

        // The capsule shows only with the sidebar hidden, and counts waiting sessions on every controller.
        let probe = app.element(identifier: "controller-connections")
        XCTAssertTrue(pollUntil(timeout: 75) { probe.value as? String == "mac=live,mustafar=live" }, "Both controllers did not go live")
        let capsule = app.buttons["approvals-elsewhere"]
        XCTAssertFalse(capsule.exists, "Capsule showed with the sidebar open")
        toggles.firstMatch.tap()
        XCTAssertTrue(capsule.waitToExist(timeout: 20), "Capsule did not appear after hiding the sidebar")
        // Two Mac approvals, plus Mustafar's writable approval and its Discord one (answered in Discord, still waiting).
        XCTAssertTrue(pollUntil(timeout: 30) { capsule.label == "4 sessions need you" }, "Capsule counted wrong: \(capsule.label)")
        addScreenshot(named: "columns-capsule")
        capsule.tap()
        XCTAssertTrue(sidebar.waitToExist(timeout: 20), "Capsule did not show the sidebar")
        XCTAssertFalse(capsule.exists, "Capsule stayed with the sidebar shown")
    }

    private func assertDetailIsBesideSidebar(detail: XCUIElement, in app: XCUIApplication) {
        guard let detailFrame = layoutFrame(of: detail),
              let sidebarFrame = layoutFrame(of: app.element(identifier: "sessions-list-frame")) else {
            XCTFail("Layout frame probes did not load")
            return
        }
        XCTAssertGreaterThanOrEqual(detailFrame.minX + 1, sidebarFrame.maxX - 1, "Detail overlapped the sidebar: detail=\(detailFrame), sidebar=\(sidebarFrame)")
    }

    private func assertHeaderAlignment(in app: XCUIApplication, sidebarOpen: Bool = false) {
        let toggle = app.buttons["sidebar-toggle"]
        let barButton = app.buttons["session-info"]
        XCTAssertTrue(toggle.waitToExist(timeout: 10), "Sidebar toggle did not load")
        XCTAssertTrue(barButton.waitToExist(timeout: 10), "Session info did not load")
        // The title has a subtitle under it, so the bar's own button marks the row's centre.
        XCTAssertEqual(toggle.frame.midY, barButton.frame.midY, accuracy: 1, "Sidebar toggle and the navigation row were misaligned")
        XCTAssertFalse(toggle.frame.intersects(app.selectedSessionName.frame), "Sidebar toggle overlapped the title")
        guard sidebarOpen else { return }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitToExist(timeout: 10), "Sidebar settings did not load")
        XCTAssertEqual(toggle.frame.midY, settings.frame.midY, accuracy: 1, "Sidebar toggle and settings were misaligned")
    }

    private func layoutFrame(of element: XCUIElement) -> CGRect? {
        let value = (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
        let parts = value.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private func extent(of element: XCUIElement) -> CGFloat {
        layoutFrame(of: element).map { max($0.width, $0.height) } ?? 0
    }

    private func assertFrame(_ actual: CGRect, equals expected: CGRect, _ message: String) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, "\(message): x")
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, "\(message): y")
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, "\(message): width")
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, "\(message): height")
    }
}
