import XCTest

/// The open Duo held upright: its regular layout at phone width, where the sidebar and details take turns.
final class PhoneWidthPanesJourneyFlowTests: JourneyTestCase {
    override var posture: DuoPosture { .unfolded }

    func testPhoneWidthPanesJourney() {
        let app = launchSignedIn(session: "long-session", arguments: ["-CCRegularWidth", "669"])
        defer { app.terminate() }
        let sizeClass = app.element(identifier: "horizontal-size-class")
        XCTAssertTrue(sizeClass.waitToExist(timeout: 30), "Size-class probe did not load")
        XCTAssertEqual(sizeClass.label, "regular", "The open Duo at phone width was not regular")
        let sidebar = app.sessionsList
        XCTAssertTrue(sidebar.waitToExist(timeout: 75), "Sessions list did not load")
        let metrics = app.element(identifier: "regular-layout-metrics")
        print("REGULAR_LAYOUT_METRICS \(metrics.value ?? metrics.label)")

        // New session and search stay inside the sidebar, and the header lines up.
        let newSession = app.buttons["new-session"]
        XCTAssertTrue(newSession.waitToExist(timeout: 20), "Sidebar's New session did not load")
        XCTAssertTrue(sidebar.frame.contains(newSession.frame), "New session left the sidebar: button=\(newSession.frame), sidebar=\(sidebar.frame)")
        let search = app.textFields["sessions-search-field"]
        XCTAssertTrue(search.waitToExist(timeout: 20), "Sidebar search did not load")
        XCTAssertTrue(sidebar.frame.contains(search.frame), "Search left the sidebar: field=\(search.frame), sidebar=\(sidebar.frame)")
        assertHeaderAlignment(in: app, sidebarOpen: true)
        addScreenshot(named: "phone-width-sidebar-open")

        // Details take the sidebar's place when both don't fit, and the toggle swaps them back.
        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitToExist(timeout: 30), "Session info did not load")
        info.tap()
        let details = app.element(identifier: "inspector-responses")
        XCTAssertTrue(details.waitToExist(timeout: 15), "Details did not open")
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "Sidebar stayed open beside the details")
        addScreenshot(named: "phone-width-details")
        let toggle = app.buttons["sidebar-toggle"]
        toggle.tap()
        XCTAssertTrue(sidebar.waitToExist(timeout: 20), "Sidebar did not reopen")
        XCTAssertTrue(details.waitToDisappear(timeout: 10), "Details stayed open beside the sidebar")

        // With the sidebar closed the header still lines up, and details open without it having to close.
        toggle.tap()
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "Sidebar did not close")
        settle(1)
        assertHeaderAlignment(in: app)
        addScreenshot(named: "phone-width-sidebar-closed")
        info.tap()
        XCTAssertTrue(details.waitToExist(timeout: 15), "Details did not open with the sidebar closed")
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
}
