import XCTest

/// What the folded Duo says when it can't connect, can't pair, or can't trust what it reached.
/// These need nothing but a fresh launch each, so the fixture restarts once for all of them.
final class ConnectionEdgesJourneyFlowTests: JourneyTestCase {
    private let unreachable = "http://127.0.0.1:1"

    func testConnectionEdgesJourney() async throws {
        // Settings explains an unreachable Mac and says what it can't know.
        var app = launchSignedIn(server: unreachable)
        defer { app.terminate() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitToExist(timeout: 30), "Settings button did not appear")
        settings.tap()
        XCTAssertTrue(app.element(identifier: "settings-address").waitToExist(timeout: 10), "Settings did not open")
        expectValue(app, "settings-address", equals: "127.0.0.1:1")
        expectValue(app, "settings-latency", equals: "Unreachable")
        let help = app.element(identifier: "settings-unreachable-help")
        XCTAssertTrue(help.waitToExist(timeout: 10), "Unreachable help did not appear")
        XCTAssertEqual(help.label, "Code can't reach 127.0.0.1:1. Check that Termius is forwarding 127.0.0.1:1 and the Mac is awake.")
        app.element(identifier: "settings-test-connection").tap()
        expectValue(app, "settings-test-result", matches: "Can't reach the Mac, tested at .+")
        expectValue(app, "settings-device-name", equals: "Unavailable")
        expectValue(app, "settings-device-paired", equals: "Unavailable")
        // The test result pushes this row off the folded display, and the form only builds rows near the screen.
        reveal(app.element(identifier: "settings-device-expiry"), in: app)
        expectValue(app, "settings-device-expiry", equals: "Unavailable")
        addScreenshot(named: "edges-settings-unreachable")
        let devicesError = app.element(identifier: "settings-devices-error")
        reveal(devicesError, in: app)
        XCTAssertTrue(devicesError.label.contains("Couldn't load paired devices"), devicesError.label)
        let retry = app.element(identifier: "settings-devices-retry")
        reveal(retry, in: app)
        XCTAssertTrue(retry.isHittable, "Paired devices error had no Retry")
        reveal(app.element(identifier: "settings-api-version"), in: app)
        expectValue(app, "settings-app-version", matches: "[0-9]+(\\.[0-9]+)* \\([0-9]+\\)")
        expectValue(app, "settings-daemon-version", equals: "Unavailable")
        expectValue(app, "settings-api-version", equals: "Unavailable")
        app.terminate()

        // A second controller that can't be reached gets a status row with Retry, not a section for the live one.
        app = launchSignedIn(arguments: unreachableExtraController, environment: ["CCExtraControllerBearer_mustafar": "unreachable-controller"])
        XCTAssertTrue(app.buttons["session-staff-account-exclusions"].waitToExist(timeout: 75), "Primary session did not load")
        let header = app.element(identifier: "controller-section-mustafar")
        for _ in 0..<8 where !(header.exists && header.isHittable) { app.sessionsList.swipeUp() }
        XCTAssertTrue(header.exists, "Unreachable controller had no status row")
        XCTAssertTrue(pollUntil(timeout: 30) { ["offline", "reconnecting"].contains(header.value as? String ?? "") }, "Status row did not say it was down")
        XCTAssertTrue(app.buttons["controller-retry-mustafar"].exists, "Status row had no Retry")
        XCTAssertFalse(app.element(identifier: "controller-section-mac").exists, "The live controller had a section")
        addScreenshot(named: "edges-offline-header")
        app.terminate()

        // Onboarding against an unreachable Mac says what to fix and won't continue.
        app = launchOnboarding(server: unreachable)
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitToExist(timeout: 10), "Connect screen did not load")
        XCTAssertTrue(app.staticTexts["Can't reach the Mac yet"].waitToExist(timeout: 12), "Unreachable state did not show")
        XCTAssertTrue(app.staticTexts["Check that Termius is forwarding localhost:47832 and the Mac is awake."].waitToExist(timeout: 12), "Unreachable state did not say what to check")
        XCTAssertTrue(app.staticText(containing: "127.0.0.1:1").exists, "Unreachable state did not name the address")
        XCTAssertFalse(app.buttons["Continue"].isEnabled, "Continue was on with no connection")
        addScreenshot(named: "edges-onboarding-unreachable")
        app.terminate()

        // A pairing code that expires offers a new one.
        app = launchOnboarding(expirySeconds: 2)
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Connected to cc-controller"].waitToExist(timeout: 15), "Connection did not go green")
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Pair this iPhone"].waitToExist(timeout: 10), "Pair screen did not load")
        let expired = app.staticTexts["This code expired"]
        XCTAssertTrue(expired.waitToExist(timeout: 10), "The short expiry did not show")
        addScreenshot(named: "edges-pair-expired")
        let code = app.element(identifier: "pairing-code")
        let oldCode = code.label
        app.buttons["Get a new pairing code"].tap()
        XCTAssertTrue(pollUntil(timeout: 10) { code.label != oldCode }, "The code did not change")
        XCTAssertEqual(code.label.replacingOccurrences(of: " ", with: "").count, 6)
        XCTAssertTrue(pollUntil(timeout: 10) { !expired.exists }, "The new code still said expired")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Expires in")).firstMatch.waitToExist(timeout: 10), "The new code had no expiry")
        app.terminate()

        // Sessions load through the relay, with its pin.
        let relayPort = requiredRunnerVariable("TEST_RUNNER_RELAY_PORT")
        let relayPin = requiredRunnerVariable("TEST_RUNNER_RELAY_PIN")
        app = launchRelay(endpoint: "https://127.0.0.1:\(relayPort)", pin: relayPin, bearer: try await currentBearer())
        XCTAssertTrue(app.staticTexts["Sessions"].waitToExist(timeout: 30), "Sessions did not load through the relay")
        XCTAssertTrue(app.buttons["session-staff-account-exclusions"].waitToExist(timeout: 30), "Rows did not load through the relay")
        addScreenshot(named: "edges-relay-sessions")
        app.terminate()

        // A pin that doesn't match warns that the Mac's identity changed.
        app = launchRelay(endpoint: "https://127.0.0.1:\(relayPort)", pin: String(repeating: "0", count: 64), bearer: try await currentBearer())
        XCTAssertTrue(app.staticTexts["Your Mac's identity changed"].waitToExist(timeout: 20), "A wrong pin did not warn")
        XCTAssertTrue(
            app.staticText(containing: "The relay presented a different key from the one this iPhone paired with. Someone may be intercepting the connection, or the Mac's relay key was reset."].exists,
            "The warning did not explain itself"
        )
        addScreenshot(named: "edges-relay-identity-changed")
        app.terminate()

        // An unreachable relay shows up in diagnostics.
        app = launchRelay(endpoint: "https://127.0.0.1:1", onboarding: true)
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Can't reach your Mac"].waitToExist(timeout: 20), "Relay failure did not show")
        XCTAssertTrue(app.staticTexts["Not reachable"].waitToExist(timeout: 15), "Diagnostics did not show Not reachable")
        app.terminate()

        // Pairing through a relay shows the check command with the relay's own key. The daemon limits pending
        // pairings, and the expired code step used them up.
        try await restartFixtureIfConfigured()
        app = launchRelay(endpoint: "https://127.0.0.1:\(relayPort)", onboarding: true)
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Connected to cc-controller"].waitToExist(timeout: 20), "Relay connection did not go green")
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Pair this iPhone"].waitToExist(timeout: 15), "Relay pair screen did not load")
        let check = String(relayPin.prefix(8)).uppercased()
        let command = app.element(identifier: "pairing-command")
        XCTAssertTrue(command.waitToExist(timeout: 5), "Pairing command did not show")
        XCTAssertTrue(command.label.hasSuffix("\(check.prefix(4)) \(check.dropFirst(4))"), "Pairing command had the wrong check: \(command.label)")
        addScreenshot(named: "edges-relay-pairing")
        app.terminate()

        // A security screen, so it stays a real step: with no Face ID enrolled, nothing gets past it.
        addTeardownBlock { try? await postFixtureRoute("/fixture/biometric/enroll") }
        try await setBiometricEnrollment(false)
        app = launchOnboarding()
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        let blocked = app.staticTexts["Set up Face ID in Settings to use this app."]
        XCTAssertTrue(blocked.waitToExist(timeout: 10), "No Face ID enrolled did not block onboarding")
        XCTAssertTrue(app.buttons["Try again"].exists, "The blocked screen had no Try again")
        XCTAssertFalse(app.staticTexts["Sessions"].exists, "Sessions showed with no Face ID enrolled")
        addScreenshot(named: "edges-faceid-not-enrolled")
    }

    private var unreachableExtraController: [String] {
        let extra = try! JSONSerialization.data(withJSONObject: [["id": "mustafar", "name": "Mustafar", "server": "http://127.0.0.1:9"]])
        return ["-CCExtraControllers", String(decoding: extra, as: UTF8.self)]
    }

    /// A restart gives the fixture a new bearer, and the relay's TLS hides the header the web proxy would rewrite.
    private func currentBearer() async throws -> String {
        guard let supervisor = ProcessInfo.processInfo.environment["TEST_RUNNER_FIXTURE_SUPERVISOR_URL"], !supervisor.isEmpty else {
            return requiredRunnerVariable("TEST_RUNNER_BEARER")
        }
        let (data, _) = try await URLSession.shared.data(from: try XCTUnwrap(URL(string: "\(supervisor)/supervisor/bearer")))
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(body?["bearer"] as? String, "Fixture supervisor returned no bearer")
    }

    private func launchRelay(endpoint: String, pin: String? = nil, bearer: String? = nil, onboarding: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCRelayEndpoints", endpoint]
        if let pin { app.launchArguments += ["-CCRelayPin", pin] }
        if onboarding { app.launchArguments += ["-CCOnboarding", "-CCResetCache"] }
        if let bearer { app.launchEnvironment["CCBearer"] = bearer }
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists, "\(element) was not found after scrolling")
    }

    private func expectValue(_ app: XCUIApplication, _ identifier: String, equals expected: String) {
        let element = app.element(identifier: identifier)
        XCTAssertTrue(pollUntil(timeout: 15) { element.exists && element.value as? String == expected }, "Expected \(identifier) == \(expected); found \(String(describing: element.exists ? element.value : "no element"))")
    }

    private func expectValue(_ app: XCUIApplication, _ identifier: String, matches pattern: String) {
        let element = app.element(identifier: identifier)
        let predicate = NSPredicate(format: "value MATCHES %@", pattern)
        XCTAssertTrue(pollUntil(timeout: 15) { element.exists && predicate.evaluate(with: element) }, "Expected \(identifier) to match \(pattern); found \(String(describing: element.exists ? element.value : "no element"))")
    }
}
