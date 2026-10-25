import XCTest

@MainActor
final class MultiControllerFlowTests: XCTestCase {
    func testExtraControllerReachesLiveWithoutChangingPrimarySessionsList() throws {
        let app = XCUIApplication()
        let extra = try JSONSerialization.data(withJSONObject: [[
            "id": "mustafar",
            "name": "Mustafar",
            "server": requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_URL"),
        ]])
        app.launchArguments = [
            "-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL"),
            "-CCExtraControllers", String(decoding: extra, as: UTF8.self),
        ]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        app.launchEnvironment["CCExtraControllerBearer_mustafar"] = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_BEARER")
        if let colorScheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !colorScheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", colorScheme]
        }
        dismissLeftoverNotificationPrompt()
        app.launch()
        defer { app.terminate() }

        let probe = app.descendants(matching: .any)
            .matching(identifier: "controller-connections")
            .firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 75), "Controller connection probe did not load")
        let liveStates = "mac=live,mustafar=live"
        let live = NSPredicate(format: "value == %@", liveStates)
        expectation(for: live, evaluatedWith: probe)
        waitForExpectations(timeout: 75)
        XCTAssertEqual(probe.value as? String, liveStates)

        let sessions = app.descendants(matching: .any)
            .matching(identifier: "sessions-list")
            .firstMatch
        XCTAssertTrue(sessions.waitForExistence(timeout: 20), "Primary sessions list did not load")
        XCTAssertTrue(
            app.buttons["session-staff-account-exclusions"].waitForExistence(timeout: 20),
            "Primary session was not visible"
        )
        XCTAssertFalse(app.staticTexts["Mustafar"].exists, "Extra controller leaked into the single-controller sessions list")
    }
}
