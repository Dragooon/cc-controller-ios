import XCTest

@MainActor
final class LockFlowTests: FixtureFlowTestSupport {
    func testForegroundAfterIntervalLocksAndUnlocks() async throws {
        let app = launchOnboarding(lockInterval: 0)
        defer {
            audit(app, name: "lock-foreground")
            app.terminate()
        }

        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Onboarding did not load Sessions")

        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(2))
        app.activate()

        XCTAssertTrue(app.staticTexts["cc-controller is locked"].waitForExistence(timeout: 10), "Foreground interval did not lock the app")
        try await Task.sleep(for: .seconds(2))
        addScreenshot(named: "lock-screen-idle")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.alerts.firstMatch.waitForExistence(timeout: 10), "Face ID prompt did not start automatically")
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Face ID did not unlock after foreground lock")
    }

    func testColdLaunchLocksAndCancelShowsMessage() async throws {
        let onboarding = launchOnboarding()
        try await setBiometricEnrollment(true)
        try await reachFaceID(onboarding)
        onboarding.buttons["Turn on Face ID"].tap()
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(onboarding.staticTexts["Sessions"].waitForExistence(timeout: 30), "Onboarding did not load Sessions")
        onboarding.terminate()

        let app = launchCold()
        defer {
            audit(app, name: "lock-cold-launch")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["cc-controller is locked"].waitForExistence(timeout: 15), "Cold launch did not show the lock screen")
        try await postFixture("/fixture/biometric/nomatch")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancel = springboard.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Face ID Cancel button did not appear")
        cancel.tap()

        XCTAssertTrue(app.staticTexts["Unlock with Face ID to continue."].waitForExistence(timeout: 10), "Cancel message did not appear on the lock screen")
        addScreenshot(named: "lock-screen-cancel")
        app.buttons["Unlock with Face ID"].tap()
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Face ID did not unlock after cancel")
    }
}
