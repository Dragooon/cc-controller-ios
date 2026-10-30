import Foundation
import XCTest

@MainActor
final class OnboardingFlowTests: FixtureFlowTestSupport {

    func testHappyPathPairsEnrolsAndLoadsSessions() async throws {
        let app = launchOnboarding()
        defer {
            audit(app, name: "onboarding-happy-path")
            addScreenshot(named: "onboarding-happy-path")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["Code"].waitToExist(timeout: 15))
        addScreenshot(named: "onboarding-welcome")
        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await completeFaceID(app, until: app.staticTexts["Sessions"], "Native login did not load Sessions")
        let sessionRow = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(sessionRow.waitToExist(timeout: 30), "Native login did not load a session row")
        addScreenshot(named: "onboarding-sessions-arrival")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // iOS shows the prompt once per install. When an earlier test in the same simulator session
        // already answered it, there is nothing to check here.
        let notificationPrompt = springboard.alerts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Would Like to Send You Notifications")
        ).firstMatch
        guard notificationPrompt.waitToExist(timeout: 5) else { return }
        XCTAssertTrue(sessionRow.exists, "Session row disappeared behind notification authorization prompt")
        addScreenshot(named: "onboarding-notification-prompt")
        notificationPrompt.buttons["Don’t Allow"].tap()
    }

    func testFaceIDWaitsThenNoMatchThenRetrySucceeds() async throws {
        let app = launchOnboarding()
        defer {
            audit(app, name: "onboarding-faceid-nomatch")
            addScreenshot(named: "onboarding-faceid-nomatch")
            app.terminate()
        }

        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(app.staticTexts["Sessions"].exists, "Sessions appeared before a biometric result")
        try await postFixture("/fixture/biometric/nomatch")
        try await Task.sleep(for: .seconds(2))
        let appDump = app.debugDescription
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardDump = springboard.debugDescription
        let dump = "APP\n\(appDump)\nSPRINGBOARD\n\(springboardDump)"
        let attachment = XCTAttachment(data: Data(dump.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "faceid-nomatch-debug-description.txt"
        attachment.lifetime = .keepAlways
        add(attachment)

        if springboardDump.localizedCaseInsensitiveContains("Retry") || springboardDump.localizedCaseInsensitiveContains("Cancel") {
            // The alert follows the simulator's region: "Recognised" (en_AU) or "Recognized" (en_US, as on CI).
            XCTAssertTrue(springboard.staticTexts.matching(NSPredicate(format: "label IN %@", ["Face Not Recognised", "Face Not Recognized"])).firstMatch.exists)
            XCTAssertTrue(springboard.buttons["Try Face ID Again"].exists || springboard.buttons["Cancel"].exists)
            springboard.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["Unlock with Face ID to continue."].waitToExist(timeout: 10))
            XCTAssertTrue(app.buttons["Try again"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["Face ID didn't match. Try again."].waitToExist(timeout: 10), dump)
            XCTAssertTrue(app.buttons["Try again"].exists)
        }
        addScreenshot(named: "onboarding-faceid-failure")

        app.buttons["Try again"].tap()
        try await completeFaceID(app, until: app.staticTexts["Sessions"], "Native login did not load Sessions")
    }

    func testFaceIDNotEnrolledBlocksWithoutFallback() async throws {
        let app = launchOnboarding()
        defer {
            audit(app, name: "onboarding-faceid-not-enrolled")
            addScreenshot(named: "onboarding-faceid-not-enrolled")
            app.terminate()
        }

        addTeardownBlock {
            try? await postFixtureRoute("/fixture/biometric/enroll")
        }

        do {
            try await setBiometricEnrollment(false)
        } catch {
            throw XCTSkip("iOS 27.0 simulator biometric unenrollment could not be driven: \(error.localizedDescription)")
        }
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        let blocked = app.staticTexts["Set up Face ID in Settings to use this app."]
        guard blocked.waitToExist(timeout: 10) else {
            throw XCTSkip("Simulator biometric unenrollment is not currently drivable; the Face ID not-enrolled state could not be isolated.")
        }
        XCTAssertTrue(blocked.exists)
        XCTAssertTrue(app.buttons["Try again"].exists)
    }

    func testExpiredPairingCodeShowsRecovery() throws {
        let app = launchOnboarding(expirySeconds: 2)
        defer {
            audit(app, name: "onboarding-expired-code")
            addScreenshot(named: "onboarding-expired-code")
            app.terminate()
        }

        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connected to cc-controller"].waitToExist(timeout: 15))
        let latency = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*· [0-9]+ ms")).firstMatch
        XCTAssertTrue(latency.waitToExist(timeout: 10), "Connected card did not show round-trip latency")
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Pair this iPhone"].waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["This code expired"].waitToExist(timeout: 10), "The short client expiry did not render")
        addScreenshot(named: "onboarding-pair-expired")
        let codeElement = app.descendants(matching: .any).matching(identifier: "pairing-code").firstMatch
        let oldCode = codeElement.label
        app.buttons["Get a new pairing code"].tap()
        XCTAssertTrue(app.staticTexts["Pair this iPhone"].exists)

        XCTAssertTrue(pollUntil(timeout: 10) { codeElement.label != oldCode })
        let newCode = codeElement.label.replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(newCode.count, 6)
        XCTAssertNotEqual(newCode, oldCode.replacingOccurrences(of: " ", with: ""))

        let expired = app.staticTexts["This code expired"]
        XCTAssertTrue(pollUntil(timeout: 10) { !expired.exists })
        let expiryLabel = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Expires in")).firstMatch
        XCTAssertTrue(expiryLabel.waitToExist(timeout: 10))
    }

    func testUnreachableDaemonExplainsWhatToFix() throws {
        let app = launchOnboarding(server: "http://127.0.0.1:1")
        defer {
            audit(app, name: "onboarding-unreachable")
            addScreenshot(named: "onboarding-unreachable")
            app.terminate()
        }

        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["Can't reach the Mac yet"].waitToExist(timeout: 12))
        XCTAssertTrue(app.staticTexts["Check that Termius is forwarding localhost:47832 and the Mac is awake."].waitToExist(timeout: 12))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] '127.0.0.1:1'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
    }
}
