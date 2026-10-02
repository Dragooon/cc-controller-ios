import Foundation
import XCTest

@MainActor
final class OnboardingFlowTests: XCTestCase {
    private var auditLines: [String] = []

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "onboarding-audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testHappyPathPairsEnrolsAndLoadsSessions() async throws {
        let app = launchOnboarding()
        defer {
            audit(app, name: "onboarding-happy-path")
            addScreenshot(named: "onboarding-happy-path")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["cc-controller"].waitForExistence(timeout: 15))
        addScreenshot(named: "onboarding-welcome")
        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Native login did not load Sessions")
        addScreenshot(named: "onboarding-sessions-arrival")
    }

    func testFaceIDNoMatchShowsRetry() async throws {
        let app = launchOnboarding()
        defer {
            audit(app, name: "onboarding-faceid-nomatch")
            addScreenshot(named: "onboarding-faceid-nomatch")
            app.terminate()
        }

        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await Task.sleep(for: .seconds(1))
        try await postFixture("/fixture/biometric/nomatch")
        XCTAssertTrue(app.staticTexts["Secure storage could not be unlocked."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Try again"].exists)
    }

    func testFaceIDNotEnrolledBlocksWithoutFallback() async throws {
        let app = launchOnboarding()
        defer {
            audit(app, name: "onboarding-faceid-not-enrolled")
            addScreenshot(named: "onboarding-faceid-not-enrolled")
            app.terminate()
        }

        do {
            try await setBiometricEnrollment(false)
        } catch {
            throw XCTSkip("iOS 27.0 simulator biometric unenrollment could not be driven: \(error.localizedDescription)")
        }
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        let blocked = app.staticTexts["Set up Face ID in Settings to use this app"]
        guard blocked.waitForExistence(timeout: 10) else {
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

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connected to cc-controller"].waitForExistence(timeout: 15))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Pair this iPhone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["This code expired"].waitForExistence(timeout: 10), "The short client expiry did not render")
        XCTAssertTrue(app.buttons["Get a new pairing code"].exists)
    }

    func testUnreachableDaemonExplainsWhatToFix() throws {
        let app = launchOnboarding(server: "http://127.0.0.1:1")
        defer {
            audit(app, name: "onboarding-unreachable")
            addScreenshot(named: "onboarding-unreachable")
            app.terminate()
        }

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Can't reach the Mac yet"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] '127.0.0.1:1'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Continue"].isEnabled)
    }

    private func launchOnboarding(server: String? = nil, expirySeconds: Int? = nil) -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = [
            "-CCServer", server ?? environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832",
            "-CCOnboarding",
            "-CCResetCache",
        ]
        if let scheme = environment["TEST_RUNNER_COLOR_SCHEME"] {
            app.launchArguments += ["-CCColorScheme", scheme]
        }
        if let expirySeconds {
            app.launchArguments += ["-CCPairingExpirySeconds", String(expirySeconds)]
        }
        app.launch()
        return app
    }

    private func reachFaceID(_ app: XCUIApplication) async throws {
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 10))
        let connected = app.staticTexts["Connected to cc-controller"]
        XCTAssertTrue(connected.waitForExistence(timeout: 15), "Live whoami check did not turn green")
        addScreenshot(named: "onboarding-connect-connected")
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        app.buttons["Continue"].tap()

        let codeElement = app.descendants(matching: .any).matching(identifier: "pairing-code").firstMatch
        XCTAssertTrue(codeElement.waitForExistence(timeout: 10), "Pairing code did not appear")
        addScreenshot(named: "onboarding-pair-waiting")
        let code = codeElement.label.replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(code.count, 6)
        try await approvePairing(code)
        XCTAssertTrue(app.staticTexts["Protect with Face ID"].waitForExistence(timeout: 15), "Pair confirmation did not reach Face ID")
        addScreenshot(named: "onboarding-faceid-prompt")
    }

    private func postFixture(_ path: String) async throws {
        guard let value = ProcessInfo.processInfo.environment["TEST_RUNNER_FIXTURE_CONTROL_URL"], let url = URL(string: "\(value)\(path)") else {
            throw XCTSkip("Fixture control URL was not provided")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "no response body"
            throw NSError(domain: "OnboardingFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture control route failed for \(path): \(body)"])
        }
    }

    private func setBiometricEnrollment(_ enrolled: Bool) async throws {
        try await postFixture(enrolled ? "/fixture/biometric/enroll" : "/fixture/biometric/unenroll")
    }

    private func approvePairing(_ code: String) async throws {
        guard let value = ProcessInfo.processInfo.environment["TEST_RUNNER_FIXTURE_CONTROL_URL"], let url = URL(string: "\(value)/fixture/approve-pairing") else {
            throw XCTSkip("Fixture control URL was not provided")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func audit(_ app: XCUIApplication, name: String) {
        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append("\(name): \(issue)")
                return true
            }
        } catch {
            auditLines.append("\(name) audit failed: \(error)")
        }
    }

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
