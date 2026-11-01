import XCTest

/// Every way to open and close the sidebar on the open Duo, in one launch.
final class SidebarGesturesJourneyFlowTests: JourneyTestCase {
    override var posture: DuoPosture { .unfolded }

    func testSidebarGesturesJourney() throws {
        let app = launchSignedIn(session: "long-session")
        defer { app.terminate() }
        let sizeClass = app.element(identifier: "horizontal-size-class")
        XCTAssertTrue(sizeClass.waitToExist(timeout: 30), "Size-class probe did not load")
        XCTAssertEqual(sizeClass.label, "regular", "The open Duo was not regular width")
        let sidebar = app.sessionsList
        XCTAssertTrue(sidebar.waitToExist(timeout: 75), "Sessions list did not load")
        let toggle = app.buttons["sidebar-toggle"]
        let scroll = app.transcriptScroll
        XCTAssertTrue(scroll.waitToExist(timeout: 20), "Transcript did not load")
        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitToExist(timeout: 20), "Newest entry did not load")

        // A swipe on the composer doesn't open the sidebar, and one on the transcript does, without scrolling it.
        toggle.tap()
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "Toggle did not hide the sidebar")
        let composer = app.composer
        XCTAssertTrue(composer.waitToExist(timeout: 20), "Composer did not load")
        let composerStart = composer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        composerStart.press(forDuration: 0.1, thenDragTo: composerStart.withOffset(CGVector(dx: 240, dy: 0)))
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "A swipe on the composer opened the sidebar")
        let topBeforeSwipe = newest.frame.minY
        let middle = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.1, thenDragTo: middle.withOffset(CGVector(dx: 240, dy: 0)))
        let swipeOpened = sidebar.waitToExist(timeout: 20)
        print("SIDEBAR_SWIPE_METRICS \(app.element(identifier: "regular-layout-metrics").label)")
        XCTAssertTrue(swipeOpened, "Swiping right across the transcript did not open the sidebar")
        settle(1)
        addScreenshot(named: "sidebar-swipe-across-detail")
        XCTAssertEqual(newest.frame.minY, topBeforeSwipe, accuracy: 1, "Opening the sidebar scrolled the transcript")

        // A finger doesn't rest before it swipes, so these flicks move as soon as they touch.
        let window = app.windows.firstMatch
        let width = window.frame.width
        let middleY = window.frame.height * 0.5
        func flick(fromX: CGFloat, toX: CGFloat) {
            let origin = window.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: fromX, dy: middleY)).press(
                forDuration: 0,
                thenDragTo: origin.withOffset(CGVector(dx: toX, dy: middleY)),
                withVelocity: .fast,
                thenHoldForDuration: 0
            )
        }
        let sidebarWidth = sidebar.frame.width
        flick(fromX: sidebarWidth + 300, toX: sidebarWidth + 40)
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "A left flick on the detail did not close the sidebar")
        flick(fromX: 3, toX: min(320, width * 0.5))
        XCTAssertTrue(sidebar.waitToExist(timeout: 10), "A right flick from the edge did not open the sidebar")
        settle(1)
        flick(fromX: sidebarWidth * 0.8, toX: 20)
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "A left flick on the sidebar did not close it")
        flick(fromX: min(400, width * 0.5), toX: min(400, width * 0.5) + 260)
        XCTAssertTrue(sidebar.waitToExist(timeout: 10), "A right flick across the detail did not open the sidebar")
        settle(1)

        // With the sidebar closed: a vertical swipe scrolls, a left swipe doesn't open it, and the edge does.
        toggle.tap()
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "Toggle did not hide the sidebar")
        let edgeStrip = app.element(identifier: "sidebar-edge-strip")
        XCTAssertTrue(edgeStrip.exists, "Leading edge strip was not there")
        XCTAssertTrue(newest.isHittable, "Newest entry was not on screen before the swipe")
        scroll.swipeDown(velocity: .fast)
        XCTAssertFalse(newest.isHittable, "A vertical swipe did not move the transcript")
        middle.press(
            forDuration: 0.1,
            thenDragTo: middle.withOffset(CGVector(dx: -160, dy: 0)),
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "A left swipe on the transcript opened the sidebar")
        let leadingEdge = edgeStrip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        leadingEdge.press(forDuration: 0.1, thenDragTo: leadingEdge.withOffset(CGVector(dx: 160, dy: 0)))
        addScreenshot(named: "sidebar-swipe-mid-drag")
        // On a stalled runner the synthesized drag can arrive too slowly to count as a swipe, so it gets a second go.
        if !sidebar.waitToExist(timeout: 5) {
            print("EDGE_SWIPE needed a second attempt")
            leadingEdge.press(forDuration: 0.1, thenDragTo: leadingEdge.withOffset(CGVector(dx: 160, dy: 0)))
        }
        XCTAssertTrue(sidebar.waitToExist(timeout: 10), "An edge swipe did not open the sidebar")
        settle(1)
        addScreenshot(named: "sidebar-swipe-open")

        // A tap at a row's leading edge opens the session, rather than being taken for a swipe.
        let otherSession = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(otherSession.waitToExist(timeout: 20), "The other session was not listed")
        let closeStrip = app.element(identifier: "sidebar-close-strip")
        XCTAssertTrue(closeStrip.waitToExist(timeout: 10), "Sidebar close strip was not there")
        otherSession.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: closeStrip.frame.minX + 30 - otherSession.frame.midX, dy: 0))
            .tap()
        XCTAssertTrue(
            pollUntil(timeout: 20) { app.selectedSessionName.exists && app.selectedSessionName.label == "Approval Flow Light Mode" },
            "A tap at the row's leading edge did not open the session"
        )

        // A vertical swipe on the list leaves the sidebar open, a left swipe closes it, and a short edge swipe doesn't count.
        sidebar.swipeUp()
        settle(2)
        XCTAssertTrue(sidebar.exists, "A vertical swipe on the list closed the sidebar")
        sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)))
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 20), "A left swipe did not close the sidebar")
        addScreenshot(named: "sidebar-swipe-closed")
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)),
            withVelocity: .slow,
            thenHoldForDuration: 0
        )
        XCTAssertTrue(sidebar.waitToDisappear(timeout: 10), "A short edge swipe opened the sidebar")

        // The search field at the sidebar's leading edge still takes a tap.
        toggle.tap()
        XCTAssertTrue(sidebar.waitToExist(timeout: 20), "Toggle did not reopen the sidebar")
        let searchField = app.textFields["sessions-search-field"]
        XCTAssertTrue(searchField.waitToExist(timeout: 20), "Sidebar search field did not load")
        searchField.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitToExist(timeout: 10), "A tap at the field's leading edge did not focus it")
    }
}
