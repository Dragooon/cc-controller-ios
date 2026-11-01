import XCTest

/// Jump to latest from history that has just been paged in, on the folded Duo. Apart from the long session's journey
/// because of a known app bug: the transcript snaps far up, then takes minutes to crawl back down, which would cost the core tier a couple of minutes.
final class JumpAfterPagingJourneyFlowTests: JourneyTestCase {
    func testJumpAfterPagingJourney() async throws {
        let app = launchSignedIn(session: "long-session", arguments: ["-CCFixtureInitialTranscriptTail", "20"])
        defer { app.terminate() }
        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitToExist(timeout: 30), "Newest entry did not load on the short first page")
        _ = pageBackPastFirstPage(in: app)
        XCTAssertTrue(app.jumpToLatest.waitToExist(timeout: 10), "Jump to latest did not show")
        app.jumpToLatest.tap()
        // It sometimes works, so this can't be strict. Remove the expectation when the bug is fixed.
        XCTExpectFailure("Jump to latest after paging lands far above the newest entry", options: .nonStrict()) {
            XCTAssertTrue(pollUntil(timeout: 5) { newest.exists && newest.isHittable }, "Jump to latest did not show the newest entry")
        }
    }
}
