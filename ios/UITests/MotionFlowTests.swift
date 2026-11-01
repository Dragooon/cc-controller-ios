import XCTest

@MainActor
final class MotionFlowTests: FixtureFlowTestSupport {
    func testK1KeyboardOpen() async throws {
        let app = launchMotion(scenario: "K1")
        defer { app.terminate() }

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Composer did not load")
        composer.tap()
        try await Task.sleep(for: .milliseconds(1_500))
    }

    func testK2KeyboardDismissByTranscriptDrag() async throws {
        let app = launchMotion(scenario: "K2")
        defer { app.terminate() }

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Composer did not load")
        composer.tap()
        try await Task.sleep(for: .milliseconds(1_500))
        let transcript = transcriptScroll(in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "Transcript scroll view did not load")
        let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 180)))
        try await Task.sleep(for: .milliseconds(1_500))
    }

    func testS1SendShort() async throws {
        let app = launchMotion(scenario: "S1")
        defer { app.terminate() }

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Composer did not load")
        composer.tap()
        composer.typeText("Short motion probe message")
        try await postFixture("/fixture/motion-stream")
        if let trigger = ProcessInfo.processInfo.environment["TEST_RUNNER_SAMPLE_TRIGGER"], !trigger.isEmpty {
            FileManager.default.createFile(atPath: trigger, contents: nil)
            try await Task.sleep(for: .milliseconds(600))
        }
        app.buttons["composer-send"].tap()
        // XCUITest queries run on the app's main thread, so nothing may query while the send is measured.
        try await Task.sleep(for: .milliseconds(2_500))

        let echoedPrompt = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Short motion probe message")
        ).firstMatch
        XCTAssertTrue(echoedPrompt.waitForExistence(timeout: 15), "Fixture echo did not reach the transcript")
        let pending = app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch
        XCTAssertTrue(waitForNonExistence(of: pending, timeout: 15), "Prompt was not reconciled into the transcript")
        let reply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Motion probe stream complete.")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "Fixture assistant stream did not finish")
        try await Task.sleep(for: .milliseconds(1_500))
    }

    /// The app sends by itself and nothing queries it, so the trace and CPU sample show only the app's own work.
    func testS3SendUntouched() async throws {
        let app = launchMotion(scenario: "S3")
        defer { app.terminate() }
        try await postFixture("/fixture/motion-stream")
        // The app sends about 25 seconds after it launches and starts the CPU sample itself just before.
        try await Task.sleep(for: .seconds(35))
    }

    func testS2SendMultiline() async throws {
        let app = launchMotion(scenario: "S2")
        defer { app.terminate() }

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Composer did not load")
        composer.tap()
        let message = (1...6).map { "Multiline motion probe line \($0)" }.joined(separator: "\\n")
        composer.typeText(message)
        try await postFixture("/fixture/motion-stream")
        app.buttons["composer-send"].tap()

        let echoedPrompt = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Multiline motion probe line 1")
        ).firstMatch
        XCTAssertTrue(echoedPrompt.waitForExistence(timeout: 15), "Fixture multiline echo did not reach the transcript")
        let pending = app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch
        XCTAssertTrue(waitForNonExistence(of: pending, timeout: 15), "Multiline prompt was not reconciled into the transcript")
        let reply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Motion probe stream complete.")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "Fixture assistant stream did not finish")
        try await Task.sleep(for: .milliseconds(1_500))
    }

    func testH1UnpinnedAppend() async throws {
        let app = launchMotion(scenario: "H1")
        defer { app.terminate() }

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let transcript = transcriptScroll(in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "Transcript scroll view did not load")
        for _ in 0..<3 { transcript.swipeDown(velocity: .slow) }
        try await Task.sleep(for: .milliseconds(1_500))
        try await postFixture("/fixture/motion-history-stream")
        try await Task.sleep(for: .milliseconds(1_500))
    }

    func testP1LoadEarlier() async throws {
        let app = launchMotion(scenario: "P1")
        defer { app.terminate() }

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let transcript = transcriptScroll(in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 10), "Transcript scroll view did not load")
        var pageLoaded = false
        for _ in 0..<30 where !pageLoaded {
            transcript.swipeDown(velocity: .fast)
            try await Task.sleep(for: .milliseconds(100))
            pageLoaded = try await fixtureRequestPaths().contains { path in
                guard let components = URLComponents(string: "http://fixture\(path)"),
                      components.path.hasSuffix("/transcript") else { return false }
                return components.queryItems?.contains { $0.name == "before" } == true
            }
        }
        for _ in 0..<3 {
            transcript.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(pageLoaded, "Earlier transcript page did not load")
        try await Task.sleep(for: .milliseconds(1_500))
    }

    /// Every way the sidebar moves, for the recording: the button, a flick and a slow drag, both ways.
    func testB1SidebarMoves() async throws {
        let app = launchMotion(scenario: "B1")
        defer { app.terminate() }

        let newest = app.staticTexts["Checkpoint 499 is complete; the fixture remains responsive."]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "Newest long-session entry did not load")
        let toggle = app.buttons["sidebar-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Sidebar toggle did not load")
        let window = app.windows.firstMatch
        func drag(from startX: CGFloat, to endX: CGFloat, velocity: XCUIGestureVelocity) {
            window.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5)).press(
                forDuration: 0.01,
                thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.5)),
                withVelocity: velocity,
                thenHoldForDuration: 0
            )
        }
        try await Task.sleep(for: .seconds(2))
        toggle.tap()
        try await Task.sleep(for: .seconds(2))
        toggle.tap()
        try await Task.sleep(for: .seconds(2))
        drag(from: 0.7, to: 0.2, velocity: .fast)
        try await Task.sleep(for: .seconds(2))
        drag(from: 0.003, to: 0.6, velocity: .fast)
        try await Task.sleep(for: .seconds(2))
        drag(from: 0.7, to: 0.2, velocity: .slow)
        try await Task.sleep(for: .seconds(2))
        drag(from: 0.003, to: 0.6, velocity: .slow)
        try await Task.sleep(for: .seconds(2))
    }

    /// The sidebar opens and a session is picked, three times, with nothing querying the app. B2 is the portrait
    /// overlay and B3 the side-by-side sidebar.
    func testB2SessionSwitchOverlay() async throws {
        let app = launchMotion(scenario: "B2")
        defer { app.terminate() }
        try await Task.sleep(for: .seconds(28))
    }

    func testB3SessionSwitchColumns() async throws {
        let app = launchMotion(scenario: "B3")
        defer { app.terminate() }
        try await Task.sleep(for: .seconds(28))
    }

    private func launchMotion(scenario: String) -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let orientation: UIDeviceOrientation = environment["TEST_RUNNER_MOTION_ORIENTATION"] == "landscape"
            ? .landscapeRight
            : .portrait
        SimulatorHinge.applyConfiguredAngle()
        return launchCold(
            openingSession: "long-session",
            motionTraceFile: requiredRunnerVariable("TEST_RUNNER_MOTION_TRACE"),
            motionScenario: scenario,
            motionOrientation: orientation
        )
    }

    private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

