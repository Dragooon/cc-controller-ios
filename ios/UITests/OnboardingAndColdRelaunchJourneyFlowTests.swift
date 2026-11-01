import XCTest

/// Pairing a new iPhone on the folded Duo, then what Face ID does on a cold launch.
final class OnboardingAndColdRelaunchJourneyFlowTests: JourneyTestCase {
    func testOnboardingAndColdRelaunchJourney() async throws {
        // The window is long enough for onboarding to finish; a later launch shortens it.
        var app = launchOnboarding()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Code"].waitToExist(timeout: 15), "Welcome did not load")
        addScreenshot(named: "onboarding-welcome")

        // Welcome, connect (with latency), pair code, approve.
        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()

        // Face ID waits for a result, a mismatch explains itself, and retrying succeeds.
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(app.staticTexts["Sessions"].exists, "Sessions appeared before a Face ID result")
        try await postFixture("/fixture/biometric/nomatch")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancel = springboard.buttons["Cancel"].firstMatch
        let inlineMismatch = app.staticTexts["Face ID didn't match. Try again."]
        XCTAssertTrue(pollUntil(timeout: 10) { cancel.exists || inlineMismatch.exists }, "Mismatch did not explain itself")
        if cancel.exists {
            XCTAssertTrue(springboard.alerts["Try Again"].exists, "System prompt did not ask to try again")
            tapCancelUntil(app.staticTexts["Unlock with Face ID to continue."], appears: cancel)
        }
        let tryAgain = app.buttons["Try again"]
        XCTAssertTrue(tryAgain.waitToExist(timeout: 10), "Face ID failure did not offer Try again")
        addScreenshot(named: "onboarding-faceid-failure")
        tryAgain.tap()
        let sessions = app.staticTexts["Sessions"]
        try await completeFaceID(app, until: sessions, "Onboarding did not load Sessions")
        let row = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(row.waitToExist(timeout: 30), "Onboarding did not load a session row")
        addScreenshot(named: "onboarding-sessions-arrival")

        // Notifications are only asked for once sessions are there.
        // iOS doesn't always ask a fresh install again soon after another journey answered, so this can't insist on it.
        let prompt = springboard.alerts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Would Like to Send You Notifications")).firstMatch
        if prompt.waitToExist(timeout: 5) {
            XCTAssertTrue(row.exists, "Session row went away behind the notification prompt")
            addScreenshot(named: "onboarding-notification-prompt")
            prompt.buttons["Don’t Allow"].tap()
        } else {
            print("NOTIFICATION_PROMPT did not appear after onboarding")
        }

        // A cold launch inside the unlock window goes straight back to Sessions.
        app.terminate()
        app = launchCold()
        XCTAssertTrue(app.staticTexts["Sessions"].waitToExist(timeout: 15), "Cold launch inside the window did not open Sessions")
        XCTAssertTrue(app.buttons["session-pull-up-agentic-uw"].waitToExist(timeout: 30), "Cold launch did not restore the session list")
        XCTAssertFalse(app.staticTexts["Code is locked"].exists, "Cold launch inside the window showed the lock screen")

        // Past the window a cold launch locks, and cancelling leaves a message and a way back in.
        app.terminate()
        app = launchCold(maxUnlockAge: 1)
        XCTAssertTrue(app.staticTexts["Code is locked"].waitToExist(timeout: 15), "Cold launch after the window did not show the lock screen")
        try await postFixture("/fixture/biometric/nomatch")
        XCTAssertTrue(cancel.waitToExist(timeout: 10), "Face ID Cancel did not appear")
        tapCancelUntil(app.staticTexts["Unlock with Face ID to continue."], appears: cancel)
        addScreenshot(named: "lock-screen-cancel")
        let unlock = app.buttons["Unlock with Face ID"]
        unlock.tap()
        try await completeFaceID(app, until: app.staticTexts["Sessions"], retry: unlock, "Face ID did not unlock after cancel")
    }

    /// A tap during the "not recognised" shake is swallowed and leaves the prompt up, so tap again until it reports the cancel.
    private func tapCancelUntil(_ message: XCUIElement, appears cancel: XCUIElement) {
        let deadline = Date().addingTimeInterval(10 * flowTimeScale())
        while !message.exists && Date() < deadline {
            if cancel.exists && cancel.isHittable { cancel.tap() }
            _ = message.waitToExist(timeout: 1.5)
        }
        XCTAssertTrue(message.exists, "The cancel message did not appear")
    }
}
