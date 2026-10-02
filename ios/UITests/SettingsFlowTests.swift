import Foundation
import XCTest

@MainActor
final class SettingsFlowTests: FixtureFlowTestSupport {
    private let environment = ProcessInfo.processInfo.environment
    private var serverURL: String { requiredRunnerVariable("TEST_RUNNER_SERVER_URL") }
    private let appVersionPattern = "[0-9]+(\\.[0-9]+)* \\([0-9]+\\)"

    func testShowsRealConnectionDeviceAndAboutValues() async throws {
        let bootstrap = try await fixtureJSON("/api/bootstrap")
        let whoAmI = try await fixtureJSON("/api/auth/whoami")
        let deviceList = try await fixtureJSON("/api/devices")
        let devices = try XCTUnwrap(deviceList["devices"] as? [[String: Any]])
        let app = launchSignedIn()
        defer {
            audit(app, name: "settings-values")
            app.terminate()
        }

        openSettings(app)
        try await expectValue(app, "settings-address", equals: serverURL.replacingOccurrences(of: "http://", with: ""))
        try await expectValue(app, "settings-latency", matches: "[0-9]+ ms")
        let device = try XCTUnwrap(whoAmI["device"] as? [String: Any])
        try await expectValue(app, "settings-device-name", equals: try XCTUnwrap(device["name"] as? String))
        let pairedAt = try XCTUnwrap(isoDate(device["pairedAt"]))
        try await expectValue(app, "settings-device-paired", equals: pairedAt.formatted(date: .abbreviated, time: .omitted))
        let expiresAt = try XCTUnwrap(isoDate(whoAmI["sessionExpiresAt"]))
        try await expectValue(app, "settings-device-expiry", equals: "in \(Int(expiresAt.timeIntervalSinceNow / 60) / 60) h")
        addScreenshot(named: "settings-connected-top")

        let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        dragStart.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)))
        reveal(element(app, "settings-unpair"), in: app)
        addScreenshot(named: "settings-this-device")

        let thisDevice = try XCTUnwrap(devices.first { $0["thisDevice"] as? Bool == true }?["name"] as? String)
        let others = devices.filter { $0["thisDevice"] as? Bool != true }.compactMap { $0["name"] as? String }
        XCTAssertEqual(thisDevice, "Fixture iPhone")
        XCTAssertEqual(others, ["Fixture iPad"])
        let thisRow = element(app, "settings-paired-this-device")
        reveal(thisRow, in: app)
        XCTAssertTrue(thisRow.label.contains(thisDevice) && thisRow.label.contains("This iPhone"), thisRow.label)
        let otherRows = app.descendants(matching: .any).matching(identifier: "settings-paired-device")
        XCTAssertEqual(otherRows.count, others.count)
        for name in others {
            XCTAssertTrue(otherRows.allElementsBoundByIndex.contains { $0.label.contains(name) && !$0.label.contains("This iPhone") }, "Missing paired device \(name)")
        }

        let daemon = try XCTUnwrap(bootstrap["daemon"] as? [String: Any])
        let version = try XCTUnwrap(daemon["version"] as? String)
        let commit = try XCTUnwrap(daemon["commit"] as? String)
        let apiVersion = try XCTUnwrap(bootstrap["apiVersion"] as? Int)
        reveal(element(app, "settings-api-version"), in: app)
        try await expectValue(app, "settings-app-version", matches: appVersionPattern)
        try await expectValue(app, "settings-daemon-version", equals: "\(version) (\(commit.prefix(7)))")
        try await expectValue(app, "settings-api-version", equals: String(apiVersion))
        addScreenshot(named: "settings-paired-about")
    }

    func testLatencyStaysLiveOnlyWhileSettingsIsOpenAndForeground() async throws {
        let app = launchSignedIn(probeInterval: 0.5)
        defer {
            audit(app, name: "settings-live-latency")
            app.terminate()
        }

        openSettings(app)
        try await expectValue(app, "settings-latency", matches: "[0-9]+ ms")
        let opened = try await probeCount()
        let live = try await expectProbeCount(
            atLeast: opened + 2,
            "Latency was not re-probed while Settings was open"
        )

        element(app, "settings-test-connection").tap()
        try await expectValue(app, "settings-test-result", matches: "Reachable · [0-9]+ ms, tested at .+")
        let tested = try await probeCount()
        XCTAssertGreaterThan(tested, live, "Test connection did not probe the daemon")
        addScreenshot(named: "settings-test-reachable")

        app.buttons["Done"].tap()
        let closed = await waitUntilGone(element(app, "settings-latency"))
        XCTAssertTrue(closed, "Settings did not close")
        try await expectNoProbes(for: .seconds(2), "after Settings closed")

        openSettings(app)
        try await expectValue(app, "settings-latency", matches: "[0-9]+ ms")
        XCUIDevice.shared.press(.home)
        try await expectNoProbes(for: .seconds(2), "while the app was in the background")

        app.activate()
        try await expectValue(app, "settings-latency", matches: "[0-9]+ ms")
        let resumed = try await probeCount()
        _ = try await expectProbeCount(atLeast: resumed + 2, "Latency did not resume in the foreground")
    }

    func testLockNowKeepsLockScreenVisibleAndUnlocksWithoutAutoPrompt() async throws {
        let app = launchOnboarding(lockInterval: 3)
        defer {
            audit(app, name: "settings-lock-now")
            app.terminate()
        }

        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Onboarding did not load Sessions")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        waitForNotificationAuthorizationPrompt(in: springboard).buttons["Don’t Allow"].tap()

        openSettings(app)
        app.buttons["Lock now"].tap()

        XCTAssertTrue(app.staticTexts["cc-controller is locked"].waitForExistence(timeout: 10), "Lock now did not show the lock screen")
        XCTAssertFalse(app.staticTexts["Sessions"].exists, "Sessions remained visible after Lock now")
        let unlockButton = app.buttons["Unlock with Face ID"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 10), "Lock screen unlock button did not appear")
        XCTAssertEqual(unlockButton.value as? String, "idle", "Lock now unexpectedly started Face ID")
        addScreenshot(named: "settings-lock-now")

        unlockButton.tap()
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Face ID did not unlock after Lock now")
    }

    func testLockIntervalPersistsAfterBackgroundLock() async throws {
        let app = launchOnboarding(lockInterval: 3)
        defer {
            audit(app, name: "settings-lock-interval")
            app.terminate()
        }

        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Onboarding did not load Sessions")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        waitForNotificationAuthorizationPrompt(in: springboard).buttons["Don’t Allow"].tap()

        openSettings(app)
        let picker = element(app, "settings-lock-interval")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Lock interval picker did not appear")
        picker.tap()
        XCTAssertTrue(app.buttons["Immediately"].waitForExistence(timeout: 5), "Immediately option did not appear")
        app.buttons["Immediately"].tap()
        try await expectValue(app, "settings-lock-interval", equals: "Immediately")
        app.buttons["Done"].tap()
        let settingsClosed = await waitUntilGone(element(app, "settings-lock-interval"))
        XCTAssertTrue(settingsClosed, "Settings did not close")

        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(1))
        app.activate()
        XCTAssertTrue(app.staticTexts["cc-controller is locked"].waitForExistence(timeout: 10), "Immediate interval did not lock after backgrounding")
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Face ID did not unlock after interval lock")

        openSettings(app)
        try await expectValue(app, "settings-lock-interval", equals: "Immediately")

        let persistedPicker = element(app, "settings-lock-interval")
        persistedPicker.tap()
        XCTAssertTrue(app.buttons["After 1 hour"].waitForExistence(timeout: 5), "After 1 hour option did not appear")
        app.buttons["After 1 hour"].tap()
        try await expectValue(app, "settings-lock-interval", equals: "After 1 hour")
        app.buttons["Done"].tap()
        let settingsClosedAfterHour = await waitUntilGone(element(app, "settings-lock-interval"))
        XCTAssertTrue(settingsClosedAfterHour, "Settings did not close after choosing one hour")

        openSettings(app)
        try await expectValue(app, "settings-lock-interval", equals: "After 1 hour")
        addScreenshot(named: "settings-lock-interval-persisted")
    }

    func testUnreachableMacExplainsWhatToCheck() async throws {
        let app = launchSignedIn(server: "http://127.0.0.1:1")
        defer {
            audit(app, name: "settings-unreachable")
            app.terminate()
        }

        openSettings(app)
        try await expectValue(app, "settings-address", equals: "127.0.0.1:1")
        try await expectValue(app, "settings-latency", equals: "Unreachable")
        let help = element(app, "settings-unreachable-help")
        XCTAssertTrue(help.waitForExistence(timeout: 10), "Unreachable guidance did not appear")
        XCTAssertEqual(help.label, "cc-controller can't reach 127.0.0.1:1. Check that Termius is forwarding 127.0.0.1:1 and the Mac is awake.")

        element(app, "settings-test-connection").tap()
        try await expectValue(app, "settings-test-result", matches: "Can't reach the Mac, tested at .+")
        try await expectValue(app, "settings-device-name", equals: "Unavailable")
        try await expectValue(app, "settings-device-paired", equals: "Unavailable")
        try await expectValue(app, "settings-device-expiry", equals: "Unavailable")
        addScreenshot(named: "settings-unreachable")

        let devicesError = element(app, "settings-devices-error")
        reveal(devicesError, in: app)
        XCTAssertTrue(devicesError.label.contains("Couldn't load paired devices"), devicesError.label)
        let retry = element(app, "settings-devices-retry")
        reveal(retry, in: app)
        XCTAssertTrue(retry.isHittable, "Paired devices error had no Retry")
        reveal(element(app, "settings-api-version"), in: app)
        try await expectValue(app, "settings-app-version", matches: appVersionPattern)
        try await expectValue(app, "settings-daemon-version", equals: "Unavailable")
        try await expectValue(app, "settings-api-version", equals: "Unavailable")
        addScreenshot(named: "settings-unreachable-bottom")
    }

    func testLockPausesProbingAndUnpairReturnsToOnboarding() async throws {
        var app = launchOnboarding(lockInterval: 3, probeInterval: 0.5)
        defer {
            audit(app, name: "settings-unpair")
            app.terminate()
        }

        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        // A match posted while enrolment is still in flight reached no Face ID prompt in one run, and unlock never finished.
        try await Task.sleep(for: .seconds(2))
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 30), "Onboarding did not load Sessions")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        waitForNotificationAuthorizationPrompt(in: springboard).buttons["Don’t Allow"].tap()

        openSettings(app)
        try await expectValue(app, "settings-latency", matches: "[0-9]+ ms")
        let deviceList = try await fixtureJSON("/api/devices")
        let devices = try XCTUnwrap(deviceList["devices"] as? [[String: Any]])
        let pairedName = try XCTUnwrap(devices.compactMap { $0["name"] as? String }.first { !$0.hasPrefix("Fixture ") })
        try await expectValue(app, "settings-device-name", equals: pairedName)

        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(5))
        app.activate()
        XCTAssertTrue(app.staticTexts["cc-controller is locked"].waitForExistence(timeout: 10), "Foreground interval did not lock the app")
        try await expectNoProbes(for: .seconds(4), "while the app was locked")
        try await postFixture("/fixture/biometric/match")
        XCTAssertTrue(element(app, "settings-latency").waitForExistence(timeout: 20), "Settings was not re-presented after unlock")
        try await expectValue(app, "settings-latency", matches: "[0-9]+ ms")

        let unpair = element(app, "settings-unpair")
        reveal(unpair, in: app)
        unpair.tap()
        XCTAssertTrue(app.staticTexts["Unpair this iPhone?"].waitForExistence(timeout: 5), "Unpair did not ask for confirmation")
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Unpair this iPhone", "settings-unpair")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Confirmation had no Unpair button")
        confirm.tap()
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 20), "Unpair did not return to onboarding")
        let logouts = try await requestCount("POST /api/auth/logout 200")
        XCTAssertEqual(logouts, 1, "Unpair did not log out on the daemon")
        addScreenshot(named: "settings-unpaired-welcome")

        app.terminate()
        app = launchCold()
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 15), "Cold launch after unpair did not show onboarding")
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(app.staticTexts["cc-controller is locked"].exists, "Cold launch after unpair found Keychain credentials")
        XCTAssertTrue(app.buttons["Get started"].exists)
    }

    private func launchSignedIn(server: String? = nil, probeInterval: TimeInterval? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server ?? serverURL]
        if let probeInterval {
            app.launchArguments += ["-CCProbeInterval", String(probeInterval)]
        }
        if let scheme = environment["TEST_RUNNER_COLOR_SCHEME"], !scheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", scheme]
        }
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        let button = app.buttons["Settings"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "Settings button did not appear")
        button.tap()
        XCTAssertTrue(element(app, "settings-address").waitForExistence(timeout: 10), "Settings did not open")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "\(element) was not found after scrolling")
    }

    private func expectValue(_ app: XCUIApplication, _ identifier: String, equals expected: String) async throws {
        try await expect(element(app, identifier), NSPredicate(format: "value == %@", expected), "\(identifier) == \(expected)")
    }

    private func expectValue(_ app: XCUIApplication, _ identifier: String, matches pattern: String) async throws {
        try await expect(element(app, identifier), NSPredicate(format: "value MATCHES %@", pattern), "\(identifier) matches \(pattern)")
    }

    private func expect(_ element: XCUIElement, _ predicate: NSPredicate, _ description: String) async throws {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = await XCTWaiter().fulfillment(of: [expectation], timeout: 15)
        XCTAssertEqual(result, .completed, "Expected \(description); found \(String(describing: element.exists ? element.value : "no element"))")
    }

    private func waitUntilGone(_ element: XCUIElement) async -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return await XCTWaiter().fulfillment(of: [expectation], timeout: 10) == .completed
    }

    private func expectProbeCount(atLeast target: Int, _ message: String) async throws -> Int {
        var count = try await probeCount()
        for _ in 0..<20 {
            if count >= target { break }
            try await Task.sleep(for: .milliseconds(250))
            count = try await probeCount()
        }
        XCTAssertGreaterThanOrEqual(count, target, message)
        return count
    }

    /// Lets any in-flight probe finish, then requires the whoami count to stay flat.
    private func expectNoProbes(for duration: Duration, _ context: String) async throws {
        try await Task.sleep(for: .seconds(1))
        let before = try await probeCount()
        try await Task.sleep(for: duration)
        let after = try await probeCount()
        XCTAssertEqual(after, before, "Latency kept probing \(context)")
    }

    private func probeCount() async throws -> Int {
        try await fixtureRequestCounts().filter { $0.key.hasPrefix("GET /api/auth/whoami ") }.values.reduce(0, +)
    }

    private func requestCount(_ key: String) async throws -> Int {
        try await fixtureRequestCounts()[key] ?? 0
    }

    private func fixtureRequestCounts() async throws -> [String: Int] {
        let control = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(control)/fixture/requests") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
    }

    private func fixtureJSON(_ path: String) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: serverURL + path)))
        request.setValue("Bearer \(requiredRunnerVariable("TEST_RUNNER_BEARER"))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Fixture \(path) failed")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
