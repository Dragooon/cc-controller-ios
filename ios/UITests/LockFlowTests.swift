import XCTest

@MainActor
final class LockFlowTests: FixtureFlowTestSupport {
    func testForegroundAfterIntervalLocksAndUnlocks() async throws {
        let app = launchOnboarding(lockInterval: 3)
        defer {
            audit(app, name: "lock-foreground")
            app.terminate()
        }

        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await completeFaceID(app, until: app.staticTexts["Sessions"], "Onboarding did not load Sessions")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notificationPrompt = waitForNotificationAuthorizationPrompt(in: springboard)
        notificationPrompt.buttons["Don’t Allow"].tap()

        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(1))
        app.activate()

        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 10), "App locked before the interval elapsed")
        XCTAssertFalse(app.staticTexts["Code is locked"].exists, "Foreground interval locked the app too early")

        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(5))
        app.activate()

        XCTAssertTrue(app.staticTexts["Code is locked"].waitForExistence(timeout: 10), "Foreground interval did not lock the app")
        let unlockButton = app.buttons["Unlock with Face ID"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 10), "Lock screen button did not appear")
        print("Lock prompt check SpringBoard alert labels: \(springboard.alerts.allElementsBoundByIndex.map(\.label))")
        XCTAssertEqual(unlockButton.value as? String, "authenticating", "Auto-prompt did not mark the lock button authenticating")
        XCTAssertFalse(unlockButton.isEnabled, "Unlock button was enabled during auto-prompt")
        addScreenshot(named: "lock-screen-authenticating")
        try await completeFaceID(app, until: app.staticTexts["Sessions"], "Face ID did not unlock after foreground lock")
    }

    func testColdLaunchLocksAndCancelShowsMessage() async throws {
        let onboarding = launchOnboarding()
        try await setBiometricEnrollment(true)
        try await reachFaceID(onboarding)
        onboarding.buttons["Turn on Face ID"].tap()
        try await completeFaceID(onboarding, until: onboarding.staticTexts["Sessions"], "Onboarding did not load Sessions")
        onboarding.terminate()

        let app = launchCold()
        defer {
            audit(app, name: "lock-cold-launch")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["Code is locked"].waitForExistence(timeout: 15), "Cold launch did not show the lock screen")
        try await postFixture("/fixture/biometric/nomatch")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("Cold-launch prompt check SpringBoard alert labels: \(springboard.alerts.allElementsBoundByIndex.map(\.label))")
        let cancel = springboard.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Face ID Cancel button did not appear")
        cancel.tap()

        XCTAssertTrue(app.staticTexts["Unlock with Face ID to continue."].waitForExistence(timeout: 10), "Cancel message did not appear on the lock screen")
        addScreenshot(named: "lock-screen-cancel")
        app.buttons["Unlock with Face ID"].tap()
        try await completeFaceID(app, until: app.staticTexts["Sessions"], "Face ID did not unlock after cancel")
    }
}
