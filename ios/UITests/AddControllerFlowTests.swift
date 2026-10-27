import XCTest

/// Settings > Add controller against the second fixture's direct TLS listener: pair with the identity check,
/// turn on Face ID, see the controller go live beside the primary, then remove it.
@MainActor
final class AddControllerFlowTests: FixtureFlowTestSupport {
    func testAddDirectTLSControllerPairsGoesLiveAndRemoves() async throws {
        let tlsPort = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_TLS_PORT")
        let tlsPin = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_TLS_PIN")
        let controlURL = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_CONTROL_URL")

        let app = XCUIApplication()
        app.launchArguments = [
            "-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL"),
            "-CCResetControllers",
        ]
        if let scheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !scheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", scheme]
        }
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        dismissLeftoverNotificationPrompt()
        app.launch()
        defer { app.terminate() }

        let probe = element(app, "controller-connections")
        XCTAssertTrue(probe.waitForExistence(timeout: 75), "Controller connection probe did not load")
        try await expectValue(probe, "mac=live", timeout: 75)

        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 30), "Settings button did not appear")
        settingsButton.tap()
        XCTAssertTrue(element(app, "settings-address").waitForExistence(timeout: 10), "Settings did not open")

        let addButton = element(app, "settings-add-controller")
        reveal(addButton, in: app)
        addButton.tap()

        let name = element(app, "add-controller-name")
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Add controller did not open")
        name.tap()
        name.typeText("Mustafar")
        let addresses = element(app, "add-controller-addresses")
        addresses.tap()
        addresses.typeText("127.0.0.1:\(tlsPort)")
        let connect = element(app, "add-controller-connect")
        XCTAssertTrue(connect.isEnabled, "Connect stayed disabled for a valid draft")
        connect.tap()

        let codeElement = element(app, "add-controller-pairing-code")
        XCTAssertTrue(codeElement.waitForExistence(timeout: 30), "Pairing code did not appear")
        let code = codeElement.label.replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(code.count, 6)
        let check = String(tlsPin.lowercased().prefix(8))
        let command = element(app, "add-controller-pairing-command")
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertTrue(command.label.contains(code), "Pairing command did not include the code: \(command.label)")
        XCTAssertTrue(
            command.label.replacingOccurrences(of: " ", with: "").lowercased().hasSuffix(check),
            "Pairing command did not end with the TLS identity check: \(command.label)"
        )
        addScreenshot(named: "add-controller-pairing")
        try await approvePairing(code, check: check, controlURL: controlURL)

        let faceIDButton = element(app, "add-controller-face-id")
        XCTAssertTrue(faceIDButton.waitForExistence(timeout: 20), "Pair confirmation did not reach Face ID")
        faceIDButton.tap()
        let row = element(app, "settings-controller-mustafar")
        try await completeFaceID(app, until: row, timeout: 45, "Add controller did not finish after Face ID")

        try await expectValue(row, "Live", timeout: 45)
        try await expectValue(probe, "mac=live,mustafar=live", timeout: 45)
        addScreenshot(named: "add-controller-live")

        reveal(row, in: app)
        row.tap()
        let remove = element(app, "controller-detail-remove")
        reveal(remove, in: app)
        remove.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Remove Mustafar", "controller-detail-remove")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Remove confirmation did not appear")
        confirm.tap()

        let rowGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        let goneResult = await XCTWaiter().fulfillment(of: [rowGone], timeout: 20)
        XCTAssertEqual(goneResult, .completed, "Removed controller still listed in Settings")
        XCTAssertTrue(element(app, "settings-controller-mac").waitForExistence(timeout: 10), "Primary controller row disappeared")
        try await expectValue(probe, "mac=live", timeout: 20)
    }

    private func approvePairing(_ code: String, check: String, controlURL: String) async throws {
        guard let url = URL(string: "\(controlURL)/fixture/approve-pairing") else {
            throw XCTSkip("Second fixture control URL was invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "check": check])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            200,
            "Second fixture refused the pairing: \(String(decoding: data, as: UTF8.self))"
        )
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

    private func expectValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval) async throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        let result = await XCTWaiter().fulfillment(of: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected \(expected); found \(String(describing: element.exists ? element.value : "no element"))")
    }
}
