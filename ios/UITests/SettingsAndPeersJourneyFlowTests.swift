import XCTest

/// Settings on the folded Duo: real values from the daemon, live latency, and peer conversations.
final class SettingsAndPeersJourneyFlowTests: JourneyTestCase {
    private let serverURL = ProcessInfo.processInfo.environment["TEST_RUNNER_SERVER_URL"] ?? ""
    private let conversationID = "74dca0e9cd297800"

    func testSettingsAndPeersJourney() async throws {
        let bootstrap = try await daemonJSON("/api/bootstrap")
        let whoAmI = try await daemonJSON("/api/auth/whoami")
        let deviceList = try await daemonJSON("/api/devices")
        let devices = try XCTUnwrap(deviceList["devices"] as? [[String: Any]])
        let app = launchSignedIn(arguments: ["-CCProbeInterval", "0.5"])
        defer { app.terminate() }
        openSettings(in: app)

        // Connection and device values are the daemon's own.
        expectValue(app, "settings-address", equals: serverURL.replacingOccurrences(of: "http://", with: ""))
        expectValue(app, "settings-latency", matches: "[0-9]+ ms")
        let device = try XCTUnwrap(whoAmI["device"] as? [String: Any])
        expectValue(app, "settings-device-name", equals: try XCTUnwrap(device["name"] as? String))
        let pairedAt = try XCTUnwrap(isoDate(device["pairedAt"]))
        expectValue(app, "settings-device-paired", equals: pairedAt.formatted(date: .abbreviated, time: .omitted))
        let expiresAt = try XCTUnwrap(isoDate(whoAmI["sessionExpiresAt"]))
        expectValue(app, "settings-device-expiry", equals: "in \(Int(expiresAt.timeIntervalSinceNow / 60) / 60) h")
        addScreenshot(named: "settings-connected")

        // Latency keeps probing while Settings is open, and Test connection probes too.
        let opened = try await probeCount()
        let live = try await expectProbeCount(atLeast: opened + 2, "Latency was not probed again while Settings was open")
        app.element(identifier: "settings-test-connection").tap()
        expectValue(app, "settings-test-result", matches: "Reachable · [0-9]+ ms, tested at .+")
        let tested = try await probeCount()
        XCTAssertGreaterThan(tested, live, "Test connection did not probe the daemon")

        // Probing stops when Settings closes and when the app goes to the background, and resumes after.
        app.buttons["Done"].tap()
        XCTAssertTrue(pollUntil(timeout: 10) { !app.element(identifier: "settings-latency").exists }, "Settings did not close")
        try await expectNoProbes("after Settings closed")
        openSettings(in: app)
        expectValue(app, "settings-latency", matches: "[0-9]+ ms")
        XCUIDevice.shared.press(.home)
        try await expectNoProbes("in the background")
        app.activate()
        expectValue(app, "settings-latency", matches: "[0-9]+ ms")
        let resumed = try await probeCount()
        _ = try await expectProbeCount(atLeast: resumed + 2, "Latency did not resume in the foreground")

        // Further down: paired devices and About.
        let drag = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        drag.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)))
        reveal(app.element(identifier: "settings-unpair"), in: app)
        addScreenshot(named: "settings-this-device")
        let thisDevice = try XCTUnwrap(devices.first { $0["thisDevice"] as? Bool == true }?["name"] as? String)
        let others = devices.filter { $0["thisDevice"] as? Bool != true }.compactMap { $0["name"] as? String }
        XCTAssertEqual(thisDevice, "Fixture iPhone")
        XCTAssertEqual(others, ["Fixture iPad"])
        let thisRow = app.element(identifier: "settings-paired-this-device")
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
        reveal(app.element(identifier: "settings-api-version"), in: app)
        expectValue(app, "settings-app-version", matches: "[0-9]+(\\.[0-9]+)* \\([0-9]+\\)")
        expectValue(app, "settings-daemon-version", equals: "\(version) (\(commit.prefix(7)))")
        expectValue(app, "settings-api-version", equals: String(apiVersion))
        addScreenshot(named: "settings-about")

        // A controller's page lists its peer conversations, and one can be revoked.
        let controller = app.element(identifier: "settings-controller-mac")
        revealPatiently(controller, in: app, "Controller list did not load")
        controller.tap()
        revealPatiently(app.staticTexts["Conversations with other controllers"], in: app, "Peer conversations section did not load")
        let row = app.element(identifier: "peer-conversation-\(conversationID)")
        revealPatiently(row, in: app, "Open peer conversation did not appear")
        addScreenshot(named: "settings-peers")
        let revoke = app.element(identifier: "peer-conversation-revoke-\(conversationID)")
        XCTAssertTrue(revoke.exists, "Peer conversation did not offer Revoke")
        revoke.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Revoke", "peer-conversation-revoke-\(conversationID)")).firstMatch
        XCTAssertTrue(confirm.waitToExist(timeout: 10), "Revoke confirmation did not appear")
        confirm.tap()
        XCTAssertTrue(row.waitToDisappear(timeout: 30), "Revoked conversation stayed in Settings")
    }

    private func openSettings(in app: XCUIApplication) {
        let button = app.buttons["Settings"]
        XCTAssertTrue(button.waitToExist(timeout: 30), "Settings button did not appear")
        button.tap()
        XCTAssertTrue(app.element(identifier: "settings-address").waitToExist(timeout: 10), "Settings did not open")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists, "\(element) was not found after scrolling")
    }

    /// Scrolls a lazy Form until the element is on screen, waiting for rows that load late.
    private func revealPatiently(_ element: XCUIElement, in app: XCUIApplication, _ message: String) {
        let deadline = Date().addingTimeInterval(20 * flowTimeScale())
        var swipes = 0
        while !(element.exists && element.isHittable) && Date() < deadline {
            if swipes < 8 {
                app.swipeUp()
                swipes += 1
            } else {
                settle(0.5)
            }
        }
        XCTAssertTrue(element.exists && element.isHittable, message)
    }

    private func expectValue(_ app: XCUIApplication, _ identifier: String, equals expected: String) {
        expect(app.element(identifier: identifier), NSPredicate(format: "value == %@", expected), "\(identifier) == \(expected)")
    }

    private func expectValue(_ app: XCUIApplication, _ identifier: String, matches pattern: String) {
        expect(app.element(identifier: identifier), NSPredicate(format: "value MATCHES %@", pattern), "\(identifier) matches \(pattern)")
    }

    private func expect(_ element: XCUIElement, _ predicate: NSPredicate, _ description: String) {
        let result = pollUntil(timeout: 15) { predicate.evaluate(with: element) }
        XCTAssertTrue(result, "Expected \(description); found \(String(describing: element.exists ? element.value : "no element"))")
    }

    private func probeCount() async throws -> Int {
        try await fixtureRequestCount("GET /api/auth/whoami ")
    }

    private func expectProbeCount(atLeast target: Int, _ message: String) async throws -> Int {
        var count = try await probeCount()
        for _ in 0..<20 where count < target {
            try await Task.sleep(for: .milliseconds(250))
            count = try await probeCount()
        }
        XCTAssertGreaterThanOrEqual(count, target, message)
        return count
    }

    /// Lets any in-flight probe finish, then requires the count to stay flat.
    private func expectNoProbes(_ context: String) async throws {
        try await Task.sleep(for: .seconds(1))
        let before = try await probeCount()
        try await Task.sleep(for: .seconds(2))
        let after = try await probeCount()
        XCTAssertEqual(after, before, "Latency kept probing \(context)")
    }

    private func daemonJSON(_ path: String) async throws -> [String: Any] {
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
