import XCTest

/// Locking on the folded Duo, by hand, by the interval setting and by age, then unpairing.
final class LockAndUnpairJourneyFlowTests: JourneyTestCase {
    private let lockTitle = "Code is locked"

    func testLockAndUnpairJourney() async throws {
        // Long enough that going to the background and back stays inside it on a slow runner.
        var app = launchOnboarding(lockInterval: 30, probeInterval: 0.5)
        defer { app.terminate() }
        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        let sessions = app.staticTexts["Sessions"]
        try await completeFaceID(app, until: sessions, "Onboarding did not load Sessions")
        dismissNotificationAuthorizationPromptIfPresent(in: XCUIApplication(bundleIdentifier: "com.apple.springboard"))

        // Back within the interval doesn't lock.
        sendToBackground(app)
        try await Task.sleep(for: .seconds(1))
        app.activate()
        XCTAssertTrue(sessions.waitToExist(timeout: 10), "App locked before the interval passed")
        XCTAssertFalse(app.staticTexts[lockTitle].exists, "Interval locked too early")

        // Lock now shows the lock screen without starting Face ID on its own.
        openSettings(in: app)
        app.buttons["Lock now"].tap()
        XCTAssertTrue(app.staticTexts[lockTitle].waitToExist(timeout: 10), "Lock now did not show the lock screen")
        XCTAssertFalse(sessions.exists, "Sessions stayed visible after Lock now")
        let unlock = app.buttons["Unlock with Face ID"]
        XCTAssertTrue(unlock.waitToExist(timeout: 10), "Unlock button did not appear")
        XCTAssertEqual(unlock.value as? String, "idle", "Lock now started Face ID by itself")
        addScreenshot(named: "lock-now")
        unlock.tap()
        // Lock now closes Settings, so unlocking comes back to the list.
        try await completeFaceID(app, until: sessions, "Face ID did not unlock after Lock now")
        openSettings(in: app)

        // Immediately applies on the next backgrounding, and the choice persists.
        let picker = app.element(identifier: "settings-lock-interval")
        XCTAssertTrue(picker.waitToExist(timeout: 10), "Lock interval picker did not appear")
        choose("Immediately", from: picker, in: app)
        XCTAssertTrue(hasValue(picker, "Immediately"), "Lock interval did not become Immediately")

        // Locked from Settings: no probes while locked, and unlocking goes back to Settings.
        sendToBackground(app)
        try await Task.sleep(for: .seconds(1))
        app.activate()
        XCTAssertTrue(app.staticTexts[lockTitle].waitToExist(timeout: 10), "Immediately did not lock after backgrounding")
        XCTAssertEqual(unlock.value as? String, "authenticating", "The lock screen didn't start Face ID by itself")
        XCTAssertFalse(unlock.isEnabled, "Unlock stayed enabled during the automatic prompt")
        addScreenshot(named: "lock-authenticating")
        try await expectNoProbes(for: .seconds(4), "while locked")
        try await completeFaceID(app, until: app.element(identifier: "settings-latency"), timeout: 20, "Settings did not come back after unlock")
        XCTAssertTrue(hasValue(picker, "Immediately"), "Immediately did not persist across the lock")

        // The other way: an hour's interval holds across closing and reopening Settings.
        choose("After 1 hour", from: picker, in: app)
        XCTAssertTrue(hasValue(picker, "After 1 hour"), "Lock interval did not become After 1 hour")
        app.buttons["Done"].tap()
        XCTAssertTrue(pollUntil(timeout: 10) { !picker.exists }, "Settings did not close")
        openSettings(in: app)
        XCTAssertTrue(hasValue(picker, "After 1 hour"), "After 1 hour did not persist")

        // Unpairing asks first, logs out on the daemon and returns to onboarding, including after a relaunch.
        let unpair = app.element(identifier: "settings-unpair")
        for _ in 0..<8 where !(unpair.exists && unpair.isHittable) { app.swipeUp() }
        unpair.tap()
        XCTAssertTrue(app.staticTexts["Unpair this iPhone?"].waitToExist(timeout: 5), "Unpair did not ask first")
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Unpair this iPhone", "settings-unpair")).firstMatch
        XCTAssertTrue(confirm.waitToExist(timeout: 5), "Confirmation had no Unpair button")
        confirm.tap()
        XCTAssertTrue(app.buttons["Get started"].waitToExist(timeout: 20), "Unpair did not return to onboarding")
        let logouts = try await fixtureRequestCounts()["POST /api/auth/logout 200"] ?? 0
        XCTAssertEqual(logouts, 1, "Unpair did not log out on the daemon")
        app.terminate()
        app = launchCold()
        XCTAssertTrue(app.buttons["Get started"].waitToExist(timeout: 15), "Cold launch after unpair did not show onboarding")
        settle(2)
        XCTAssertFalse(app.staticTexts[lockTitle].exists, "Cold launch after unpair found Keychain credentials")
        app.terminate()

        // Unlock age passing while the app is open locks it and keeps a draft. The window has to cover
        // pairing again, opening a session and typing, which took over 24 s on a loaded runner.
        let unlockAge = 40 * flowTimeScale()
        app = launchOnboarding(maxUnlockAge: unlockAge)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await completeFaceID(app, until: app.staticTexts["Sessions"], "Second onboarding did not load Sessions")
        openSession("pull-up-agentic-uw", in: app)
        let draft = "draft survives biometric lock"
        XCTAssertTrue(app.composer.waitToExist(timeout: 20), "Composer did not load")
        typeInComposer(draft, in: app)
        XCTAssertTrue(app.staticTexts[lockTitle].waitToExist(timeout: unlockAge + 5), "Unlock age did not lock the app while it was open")
        try await completeFaceID(app, until: app.composer, "Face ID did not unlock after the age passed")
        XCTAssertEqual(app.composer.typedText, draft, "The draft was lost across the lock")
    }

    private func openSettings(in app: XCUIApplication) {
        let button = app.buttons["Settings"]
        XCTAssertTrue(button.waitToExist(timeout: 30), "Settings button did not appear")
        button.tap()
        XCTAssertTrue(app.element(identifier: "settings-address").waitToExist(timeout: 10), "Settings did not open")
    }

    private func choose(_ option: String, from picker: XCUIElement, in app: XCUIApplication) {
        picker.tap()
        let item = app.buttons[option]
        XCTAssertTrue(item.waitToExist(timeout: 5), "\(option) did not appear")
        // A tap while the menu is still opening is swallowed and leaves the menu up.
        XCTAssertTrue(waitForStableFrame(item), "\(option) did not settle before the tap")
        item.tap()
    }

    private func hasValue(_ element: XCUIElement, _ expected: String) -> Bool {
        pollUntil(timeout: 15) { element.value as? String == expected }
    }

    /// Lets any in-flight probe finish, then requires the whoami count to stay flat.
    private func expectNoProbes(for duration: Duration, _ context: String) async throws {
        try await Task.sleep(for: .seconds(1))
        let before = try await fixtureRequestCount("GET /api/auth/whoami ")
        try await Task.sleep(for: duration)
        let after = try await fixtureRequestCount("GET /api/auth/whoami ")
        XCTAssertEqual(after, before, "Latency kept probing \(context)")
    }
}
