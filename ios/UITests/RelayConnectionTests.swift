import Foundation
import XCTest

@MainActor
final class RelayConnectionTests: FixtureFlowTestSupport {
    private var relayPort: String { requiredRunnerVariable("TEST_RUNNER_RELAY_PORT") }
    private var relayPin: String { requiredRunnerVariable("TEST_RUNNER_RELAY_PIN") }
    private var bearer: String { requiredRunnerVariable("TEST_RUNNER_BEARER") }

    /// A restart gives the fixture a new bearer, and the relay's TLS hides the header the web proxy would rewrite.
    private func currentBearer() async throws -> String {
        guard let supervisor = ProcessInfo.processInfo.environment["TEST_RUNNER_FIXTURE_SUPERVISOR_URL"], !supervisor.isEmpty else {
            return bearer
        }
        guard let url = URL(string: "\(supervisor)/supervisor/bearer") else {
            throw XCTSkip("Fixture supervisor URL was invalid")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(body?["bearer"] as? String, "Fixture supervisor returned no bearer")
    }

    func testLoadsSessionsThroughRelay() async throws {
        let app = launchRelay(pin: relayPin, bearer: try await currentBearer())
        defer {
            addScreenshot(named: "relay-sessions-loaded")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["Sessions"].waitToExist(timeout: 30))
        XCTAssertTrue(app.buttons["session-staff-account-exclusions"].waitToExist(timeout: 30))
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitToExist(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Connection"].waitToExist(timeout: 10))
        addScreenshot(named: "relay-settings-connection")
    }

    func testWrongPinShowsIdentityChanged() throws {
        let app = launchRelay(pin: String(repeating: "0", count: 64), bearer: bearer)
        defer {
            addScreenshot(named: "relay-identity-changed")
            app.terminate()
        }

        XCTAssertTrue(app.staticTexts["Your Mac's identity changed"].waitToExist(timeout: 20))
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
        XCTAssertTrue(app.staticTexts["Can't reach your Mac"].waitToExist(timeout: 20))
        XCTAssertTrue(app.staticTexts["Not reachable"].waitToExist(timeout: 15))
    }

    func testRelayPairingShowsCheckCommand() throws {
        let app = launchRelay(onboarding: true)
        defer {
            addScreenshot(named: "relay-pairing-check-command")
            app.terminate()
        }

        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitToExist(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connected to cc-controller"].waitToExist(timeout: 20))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Pair this iPhone"].waitToExist(timeout: 15))
        let check = String(relayPin.prefix(8)).uppercased()
        let expectedCheck = "\(check.prefix(4)) \(check.dropFirst(4))"
        let command = app.descendants(matching: .any).matching(identifier: "pairing-command").firstMatch
        XCTAssertTrue(command.waitToExist(timeout: 5))
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
