import XCTest

/// Sleeping sessions on the folded Duo, and coming back to the app after a long time away.
final class SleepingAndResumeJourneyFlowTests: JourneyTestCase {
    func testSleepingAndResumeJourney() async throws {
        try await postFixture("/fixture/sleeping-seed")
        // Held long enough that the history shows while the wake is still going, on slow runners too.
        try await postFixtureJSON("/fixture/wake-behaviour", body: ["delayMs": Int(3_000 * flowTimeScale())])
        try await postFixture("/fixture/clear-approvals")
        let app = launchSignedIn(arguments: ["-CCResumeNewChatAfterSeconds", "2"])
        defer { app.terminate() }

        // A sleeping row's menu offers the attach command.
        let recents = app.staticTexts["Recents"]
        XCTAssertTrue(recents.waitToExist(timeout: 30), "Recents did not load")
        let row = app.buttons["sleeping-session-sleeping-dune"]
        for _ in 0..<8 where !row.exists { app.sessionsList.swipeUp() }
        XCTAssertTrue(row.waitToExist(timeout: 30), "Sleeping row did not load")
        addScreenshot(named: "sleeping-recents")
        row.press(forDuration: 1)
        let copy = app.buttons["Copy attach command"]
        XCTAssertTrue(copy.waitToExist(timeout: 10), "Copy attach command did not appear")
        copy.tap()
        XCTAssertTrue(copy.waitToDisappear(timeout: 10), "The menu did not close")

        // Tapping it opens the history straight away, while the wake is still going, with Send off.
        row.tap()
        let reply = app.staticTexts["I found a short list of IMAX sessions and left the final choice to you."]
        XCTAssertTrue(reply.waitToExist(timeout: 3), "History did not open before the wake finished")
        XCTAssertTrue(pollUntil(timeout: 1, scaled: false) { reply.isHittable }, "History's row was not on screen during the wake")
        XCTAssertTrue(app.element(identifier: "session-waking").exists, "The wake was not still going when the history opened")
        addScreenshot(named: "sleeping-wake-held")
        let composer = app.composer
        XCTAssertTrue(composer.waitToExist(timeout: 5), "Composer did not stay up during the wake")
        let send = app.buttons["composer-send"]
        XCTAssertTrue(send.waitToExist(timeout: 5), "Send did not show during the wake")
        XCTAssertFalse(send.isEnabled, "Send was on before the session went live")

        // Once it's awake, the same screen becomes a live session.
        XCTAssertEqual(app.selectedSessionName.label, "Sleeping Dune")
        XCTAssertTrue(app.element(identifier: "session-waking").waitToDisappear(timeout: 30), "The wake did not finish")
        typeInComposer("Wake test", in: app)
        XCTAssertTrue(pollUntil(timeout: 10) { send.isEnabled }, "Send did not come on after the wake")
        XCTAssertEqual(reply.label, "I found a short list of IMAX sessions and left the final choice to you.")
        addScreenshot(named: "sleeping-wake-live")

        // Coming back after longer than the threshold opens a new chat.
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(3))
        app.activate()
        XCTAssertTrue(app.staticTexts["new-session-greeting"].waitToExist(timeout: 15), "Coming back after the threshold did not open New session")
        addScreenshot(named: "sleeping-resume-new-chat")
    }
}
