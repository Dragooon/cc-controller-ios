import XCTest

/// The Mac can't be reached while Mustafar can, as when the Mac's relay host drops off: Face ID still unlocks the
/// app, Mustafar goes live, and the Mac shows "Can't reach" with Retry instead of holding the unlock back.
@MainActor
final class UnreachableMacUnlockFlowTests: JourneyTestCase {
    private let lockTitle = "Code is locked"
    /// Nothing listens here, so every request to the Mac fails to connect.
    private let unreachableMac = "http://127.0.0.1:1"

    func testUnlockOpensMustafarWhileTheMacIsUnreachable() async throws {
        // A failure before the end must not leave a second controller for the rest of the slice.
        addTeardownBlock { @MainActor in
            let cleanup = XCUIApplication()
            cleanup.launchArguments = ["-CCResetControllers"]
            cleanup.launch()
            cleanup.terminate()
        }
        let tlsPort = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_TLS_PORT")
        let tlsPin = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_TLS_PIN")
        let controlURL = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_CONTROL_URL")

        // Pair the Mac with Face ID, as on a fresh install.
        var app = launch(server: requiredRunnerVariable("TEST_RUNNER_SERVER_URL"), fresh: true)
        try await setBiometricEnrollment(true)
        try await reachFaceID(app)
        app.buttons["Turn on Face ID"].tap()
        try await completeFaceID(app, until: app.staticTexts["Sessions"], "Onboarding did not load Sessions")
        dismissNotificationAuthorizationPromptIfPresent(in: XCUIApplication(bundleIdentifier: "com.apple.springboard"))

        // Add Mustafar over its pinned TLS address, with its own Face ID sign-in.
        try await addMustafar(in: app, tlsPort: tlsPort, tlsPin: tlsPin, controlURL: controlURL)
        app.terminate()

        // Relaunch with the Mac on an address nothing answers, then lock and unlock with Face ID.
        app = launch(server: unreachableMac, fresh: false)
        defer { app.terminate() }
        let probe = app.element(identifier: "controller-connections")
        let lockScreen = app.staticTexts[lockTitle]
        XCTAssertTrue(pollUntil(timeout: 45) { probe.exists || lockScreen.exists }, "Relaunch showed neither the list nor the lock screen")
        if probe.exists {
            openSettings(in: app)
            app.buttons["Lock now"].tap()
            XCTAssertTrue(lockScreen.waitToExist(timeout: 10), "Lock now did not show the lock screen")
            let unlock = app.buttons["Unlock with Face ID"]
            XCTAssertTrue(unlock.waitToExist(timeout: 10), "Unlock button did not appear")
            unlock.tap()
        }
        try await completeFaceID(app, until: probe, timeout: 45, "Face ID did not unlock with the Mac unreachable")
        XCTAssertFalse(lockScreen.exists, "The lock screen stayed up while Mustafar was reachable")

        // Mustafar is live, and the Mac says it can't be reached.
        XCTAssertTrue(
            pollUntil(timeout: 45) { probe.value as? String == "mac=offline,mustafar=live" },
            "Mustafar did not go live beside the unreachable Mac: \(probe.value ?? "none")"
        )
        let macHeader = app.element(identifier: "controller-section-mac")
        XCTAssertTrue(macHeader.waitToExist(timeout: 20), "The Mac had no status header")
        XCTAssertEqual(macHeader.value as? String, "unreachable", "The Mac's header did not say it can't be reached")
        let relay = app.buttons["session-dune-relay"]
        XCTAssertTrue(bringIntoView(relay, in: app.sessionsList), "Mustafar's sessions were not listed")
        addScreenshot(named: "unreachable-mac-unlocked")

        // Retry tries the Mac again and leaves the app open when it still can't be reached.
        let retry = app.buttons["controller-retry-mac"]
        XCTAssertTrue(bringIntoView(retry, in: app.sessionsList, swipeDown: true), "The Mac's header had no Retry")
        retry.tap()
        settle(3)
        XCTAssertFalse(lockScreen.exists, "Retry on the unreachable Mac locked the app")
        XCTAssertTrue(
            pollUntil(timeout: 20) { macHeader.value as? String == "unreachable" },
            "Retry changed the Mac's state though it still can't be reached: \(macHeader.value ?? "none")"
        )
        XCTAssertTrue(
            pollUntil(timeout: 20) { probe.value as? String == "mac=offline,mustafar=live" },
            "Retry disturbed Mustafar: \(probe.value ?? "none")"
        )
    }

    private func launch(server: String, fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        if fresh {
            app.launchArguments += ["-CCOnboarding", "-CCResetCache", "-CCResetControllers"]
        }
        if let scheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !scheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", scheme]
        }
        configureTranscriptEngine(app)
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func addMustafar(in app: XCUIApplication, tlsPort: String, tlsPin: String, controlURL: String) async throws {
        openSettings(in: app)
        let addButton = app.element(identifier: "settings-add-controller")
        reveal(addButton, in: app)
        addButton.tap()

        let name = app.element(identifier: "add-controller-name")
        XCTAssertTrue(name.waitToExist(timeout: 10), "Add controller did not open")
        name.tap()
        name.typeText("Mustafar")
        let addresses = app.element(identifier: "add-controller-addresses")
        addresses.tap()
        addresses.typeText("127.0.0.1:\(tlsPort)")
        app.element(identifier: "add-controller-connect").tap()

        let codeElement = app.element(identifier: "add-controller-pairing-code")
        XCTAssertTrue(codeElement.waitToExist(timeout: 30), "Pairing code did not appear")
        let code = codeElement.label.replacingOccurrences(of: " ", with: "")
        try await approveSecondPairing(code, check: String(tlsPin.lowercased().prefix(8)), controlURL: controlURL)

        let faceIDButton = app.element(identifier: "add-controller-face-id")
        XCTAssertTrue(faceIDButton.waitToExist(timeout: 20), "Pair confirmation did not reach Face ID")
        faceIDButton.tap()
        let row = app.element(identifier: "settings-controller-mustafar")
        try await completeFaceID(app, until: row, timeout: 45, retry: faceIDButton, "Add controller did not finish after Face ID")
        XCTAssertTrue(pollUntil(timeout: 45) { row.value as? String == "Live" }, "Mustafar did not go live: \(row.value ?? "none")")
    }

    private func approveSecondPairing(_ code: String, check: String, controlURL: String) async throws {
        let url = try XCTUnwrap(URL(string: "\(controlURL)/fixture/approve-pairing"))
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

    private func openSettings(in app: XCUIApplication) {
        let button = app.buttons["Settings"]
        XCTAssertTrue(button.waitToExist(timeout: 30), "Settings button did not appear")
        button.tap()
        XCTAssertTrue(app.element(identifier: "settings-address").waitToExist(timeout: 10), "Settings did not open")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isSafelyHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "\(element) was not found after scrolling")
    }

    private func bringIntoView(_ element: XCUIElement, in container: XCUIElement, swipeDown: Bool = false) -> Bool {
        if element.exists && element.isHittable { return true }
        for _ in 0..<8 {
            if swipeDown { container.swipeDown() } else { container.swipeUp() }
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }
}
