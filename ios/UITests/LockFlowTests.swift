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

    func testUnlockExpiresWhileActiveAndKeepsDraft() async throws {
        let app = launchOnboarding(maxUnlockAge: 8)
        defer {
            audit(app, name: "lock-active-expiry")
            app.terminate()
        }

        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await completeFaceID(app, until: app.staticTexts["Sessions"], "Onboarding did not load Sessions")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        waitForNotificationAuthorizationPrompt(in: springboard).buttons["Don’t Allow"].tap()

        let session = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(session.waitForExistence(timeout: 30), "Fixture session did not load")
        session.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "Composer did not load")
        let draft = "draft survives biometric lock"
        composer.tap()
        composer.typeText(draft)

        XCTAssertTrue(app.staticTexts["cc-controller is locked"].waitForExistence(timeout: 15), "Unlock age did not expire while active")
        try await completeFaceID(app, until: composer, "Face ID did not unlock after active expiry")
        XCTAssertEqual(composer.value as? String, draft, "Composer draft was lost across the lock")
    }

    func testColdLaunchAfterUnlockWindowLocksAndCancelShowsMessage() async throws {
        let onboarding = launchOnboarding(maxUnlockAge: 5)
        try await setBiometricEnrollment(true)
        try await reachFaceID(onboarding)
        onboarding.buttons["Turn on Face ID"].tap()
        try await completeFaceID(onboarding, until: onboarding.staticTexts["Sessions"], "Onboarding did not load Sessions")
        onboarding.terminate()
        try await Task.sleep(for: .seconds(6))

        let app = launchCold(maxUnlockAge: 5)
        defer {
            audit(app, name: "lock-cold-launch-after-window")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["Code is locked"].waitForExistence(timeout: 15), "Cold launch after the unlock window did not show the lock screen")
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

    func testColdRelaunchWithinUnlockWindowSkipsFaceID() async throws {
        let onboarding = launchOnboarding()
        try await setBiometricEnrollment(true)
        try await reachFaceID(onboarding)
        onboarding.buttons["Turn on Face ID"].tap()
        try await completeFaceID(onboarding, until: onboarding.staticTexts["Sessions"], "Onboarding did not load Sessions")
        onboarding.terminate()

        let app = launchCold()
        defer {
            audit(app, name: "lock-cold-launch-within-window")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 15), "Cold launch within the unlock window did not open Sessions")
        XCTAssertTrue(app.buttons["session-pull-up-agentic-uw"].waitForExistence(timeout: 30), "Cold launch did not restore the fixture session list")
        XCTAssertFalse(app.staticTexts["cc-controller is locked"].exists, "Cold launch within the unlock window showed the lock screen")
    }
}
