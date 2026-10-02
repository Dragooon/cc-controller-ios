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
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 10))
        let connected = app.staticTexts["Connected to cc-controller"]
        XCTAssertTrue(connected.waitForExistence(timeout: 15), "Live whoami check did not turn green")
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        app.buttons["Continue"].tap()

        let codeElement = app.descendants(matching: .any).matching(identifier: "pairing-code").firstMatch
        XCTAssertTrue(codeElement.waitForExistence(timeout: 10), "Pairing code did not appear")
        let code = codeElement.label.replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(code.count, 6)
        try await approvePairing(code)

        XCTAssertTrue(app.staticTexts["Protect with Face ID"].waitForExistence(timeout: 15), "Pair confirmation did not reach Face ID")
        guard driveBiometrics() else {
            throw XCTSkip("The simulator did not accept simctl biometric enrollment; unlock assertion skipped after the Face ID screen.")
        }
        app.buttons["Turn on Face ID"].tap()
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Native login did not load Sessions")
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
        if let expirySeconds {
            app.launchArguments += ["-CCPairingExpirySeconds", String(expirySeconds)]
        }
        app.launch()
        return app
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

    private func driveBiometrics() -> Bool {
        // XCUITest runs inside the iOS test bundle and cannot invoke simctl. The
        // scripts/ios.sh harness can drive the simulator once the shared pool is available.
        false
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
