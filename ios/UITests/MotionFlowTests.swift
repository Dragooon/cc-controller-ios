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
        app.buttons["composer-send"].tap()

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

    private func launchMotion(scenario: String) -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let orientation: UIDeviceOrientation = environment["TEST_RUNNER_MOTION_ORIENTATION"] == "landscape"
            ? .landscapeRight
            : .portrait
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

