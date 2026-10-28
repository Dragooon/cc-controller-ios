import Foundation
import XCTest

@MainActor
final class RelayConnectionTests: FixtureFlowTestSupport {
    private var relayPort: String { requiredRunnerVariable("TEST_RUNNER_RELAY_PORT") }
    private var relayPin: String { requiredRunnerVariable("TEST_RUNNER_RELAY_PIN") }
    private var bearer: String { requiredRunnerVariable("TEST_RUNNER_BEARER") }

    func testLoadsSessionsThroughRelay() throws {
        let app = launchRelay(pin: relayPin, bearer: bearer)
        defer {
            addScreenshot(named: "relay-sessions-loaded")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["session-staff-account-exclusions"].waitForExistence(timeout: 30))
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 10))
        addScreenshot(named: "relay-settings-connection")
    }

    func testWrongPinShowsIdentityChanged() throws {
        let app = launchRelay(pin: String(repeating: "0", count: 64), bearer: bearer)
        defer {
            addScreenshot(named: "relay-identity-changed")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["Your Mac's identity changed"].waitForExistence(timeout: 20))
        let body = app.staticTexts.matching(NSPredicate(format: "label == %@", "The relay presented a different key from the one this iPhone paired with. Someone may be intercepting the connection, or the Mac's relay key was reset.")).firstMatch
        XCTAssertTrue(body.exists)
    }

    func testRelayDiagnosticsShowsUnreachable() throws {
        let app = launchRelay(endpoint: "https://127.0.0.1:1", onboarding: true)
        defer {
            addScreenshot(named: "relay-diagnostics-unreachable")
            app.terminate()
        }

        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Can't reach your Mac"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Not reachable"].waitForExistence(timeout: 15))
    }

    func testRelayPairingShowsCheckCommand() throws {
        let app = launchRelay(onboarding: true)
        defer {
            addScreenshot(named: "relay-pairing-check-command")
            app.terminate()
        }

        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connected to cc-controller"].waitForExistence(timeout: 20))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Pair this iPhone"].waitForExistence(timeout: 15))
        let check = String(relayPin.prefix(8)).uppercased()
        let expectedCheck = "\(check.prefix(4)) \(check.dropFirst(4))"
        let command = app.descendants(matching: .any).matching(identifier: "pairing-command").firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertTrue(command.label.hasSuffix(expectedCheck), "Expected check \(expectedCheck), got \(command.label)")
    }

    private func launchRelay(pin: String? = nil, bearer: String? = nil, endpoint: String? = nil, onboarding: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CCRelayEndpoints", endpoint ?? "https://127.0.0.1:\(relayPort)",
        ]
        if let pin {
            app.launchArguments += ["-CCRelayPin", pin]
        }
        if onboarding {
            app.launchArguments += ["-CCOnboarding", "-CCResetCache"]
        }
        if let bearer {
            app.launchEnvironment["CCBearer"] = bearer
        }
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }
}
