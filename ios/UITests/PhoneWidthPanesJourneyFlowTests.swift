import XCTest

/// The open Duo held upright: at phone width the sidebar slides over a detail that doesn't move, and details take over from it.
final class PhoneWidthPanesJourneyFlowTests: JourneyTestCase {
    override var posture: DuoPosture { .unfolded }

    func testPhoneWidthPanesJourney() {
        let app = launchSignedIn(session: "staff-account-exclusions", arguments: ["-CCRegularWidth", "669"])
        defer { app.terminate() }
        let sizeClass = app.element(identifier: "horizontal-size-class")
        XCTAssertTrue(sizeClass.waitToExist(timeout: 30), "Size-class probe did not load")
        XCTAssertEqual(sizeClass.label, "regular", "The open Duo at phone width was not regular")
        let metrics = app.element(identifier: "regular-layout-metrics")
        print("REGULAR_LAYOUT_METRICS \(metrics.value ?? metrics.label)")

        // It opens on the session, with the long title given the whole bar.
        let title = app.selectedSessionName
        XCTAssertTrue(title.waitToExist(timeout: 75), "Session title did not load")
        let sidebar = app.sessionsList
        XCTAssertFalse(sidebar.exists, "The sidebar covered the session it opened with")
        settle(1)
        let titleFrame = title.frame
        XCTAssertGreaterThan(titleFrame.width, 300, "The long title was cut off with room to spare")
        addScreenshot(named: "phone-width-sidebar-closed")

        // The sidebar slides over with no blur, and new session and search stay inside it.
        let toggles = app.buttons.matching(identifier: "sidebar-toggle")
        toggles.firstMatch.tap()
        XCTAssertTrue(sidebar.waitToExist(timeout: 10), "Sidebar did not open")
        settle(1)
        XCTAssertFalse(app.element(identifier: "detail-motion-cover").exists, "An overlay sidebar shouldn't need the blur")
        XCTAssertEqual(toggles.count, 1, "The covered detail's toggle still shows to accessibility")
        let newSession = app.buttons["new-session"]
        XCTAssertTrue(newSession.waitToExist(timeout: 20), "Sidebar's New session did not load")
        XCTAssertTrue(sidebar.frame.contains(newSession.frame), "New session left the sidebar: button=\(newSession.frame), sidebar=\(sidebar.frame)")
        let search = app.textFields["sessions-search-field"]
        XCTAssertTrue(search.waitToExist(timeout: 20), "Sidebar search did not load")
        XCTAssertTrue(sidebar.frame.contains(search.frame), "Search left the sidebar: field=\(search.frame), sidebar=\(sidebar.frame)")
        addScreenshot(named: "phone-width-sidebar-open")

        // Tapping the dimmed detail closes it, and nothing under it has moved.
        let scrim = app.element(identifier: "sidebar-scrim")
        XCTAssertTrue(scrim.waitToExist(timeout: 5), "Scrim did not appear")
        scrim.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "Tapping the dimmed detail did not close the sidebar")
        settle(1)
        XCTAssertEqual(title.frame.minX, titleFrame.minX, accuracy: 1, "The detail moved under the overlay sidebar")
        XCTAssertEqual(title.frame.width, titleFrame.width, accuracy: 1, "The detail resized under the overlay sidebar")

        // Opening a session from it closes it.
        toggles.firstMatch.tap()
        XCTAssertTrue(sidebar.waitToExist(timeout: 10), "Sidebar did not reopen")
        let longSession = app.buttons["session-long-session"]
        XCTAssertTrue(longSession.waitToExist(timeout: 20), "Long session's row did not appear")
        longSession.tap()
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "Opening a session did not close the sidebar")
        XCTAssertTrue(pollUntil(timeout: 30) { title.exists && title.label == "Long session" }, "Long session did not open")

        // Details open over the dimmed detail, and one tap on the toggle swaps them for the sidebar.
        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitToExist(timeout: 30), "Session info did not load")
        info.tap()
        let details = app.element(identifier: "inspector-responses")
        XCTAssertTrue(details.waitToExist(timeout: 15), "Details did not open")
        addScreenshot(named: "phone-width-details")
        toggles.firstMatch.tap()
        XCTAssertTrue(details.waitToDisappear(timeout: 10), "The sidebar opened without closing the details")
        XCTAssertTrue(sidebar.waitToExist(timeout: 20), "Sidebar did not open from the details")
    }
}
