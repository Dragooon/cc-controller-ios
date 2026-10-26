import XCTest

@MainActor
final class MultiControllerFlowTests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testExtraControllerReachesLiveAndGetsItsOwnSection() throws {
        let app = launch()
        defer { app.terminate() }
        waitForLiveControllers(in: app)

        let sessions = app.descendants(matching: .any)
            .matching(identifier: "sessions-list")
            .firstMatch
        XCTAssertTrue(sessions.waitForExistence(timeout: 20), "Sessions list did not load")
        XCTAssertTrue(
            app.buttons["session-staff-account-exclusions"].waitForExistence(timeout: 20),
            "Primary session was not visible"
        )
        let macSection = sectionHeader("mac", in: app)
        let mustafarSection = sectionHeader("mustafar", in: app)
        XCTAssertTrue(macSection.waitForExistence(timeout: 20), "Mac section header did not load")
        XCTAssertTrue(mustafarSection.waitForExistence(timeout: 20), "Mustafar section header did not load")
        XCTAssertEqual(mustafarSection.value as? String, "live")
        XCTAssertTrue(app.buttons["session-dune-relay"].waitForExistence(timeout: 20), "Mustafar session was not listed")
    }

    func testNeedsYouMergesControllersWithCaptions() throws {
        let app = launch()
        defer { app.terminate() }
        waitForLiveControllers(in: app)

        let mustafarRow = app.buttons["session-discord-triage"]
        XCTAssertTrue(mustafarRow.waitForExistence(timeout: 30), "Mustafar approval session was not listed")
        XCTAssertEqual(mustafarRow.value as? String, "needs_you")
        XCTAssertTrue(mustafarRow.label.contains("Mustafar"), "Mustafar Needs-you row had no controller caption: \(mustafarRow.label)")

        let macRow = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(macRow.waitForExistence(timeout: 20), "Mac approval session was not listed")
        XCTAssertEqual(macRow.value as? String, "needs_you")
        XCTAssertTrue(macRow.label.contains("Mac"), "Mac Needs-you row had no controller caption: \(macRow.label)")

        // Both Needs-you rows sit above the first controller section.
        let macSection = sectionHeader("mac", in: app)
        XCTAssertTrue(macSection.waitForExistence(timeout: 20), "Mac section header did not load")
        XCTAssertLessThan(mustafarRow.frame.minY, macSection.frame.minY, "Mustafar approval was not in the merged Needs-you section")
        XCTAssertLessThan(macRow.frame.minY, macSection.frame.minY, "Mac approval was not in the merged Needs-you section")
        addScreenshot(named: "multi-controller-needs-you")
    }

    func testAllowingMustafarApprovalPostsToTheMustafarController() async throws {
        let app = launch()
        defer { app.terminate() }
        waitForLiveControllers(in: app)

        let allow = app.buttons["approval-discord-triage-allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "Mustafar compact approval card did not load")
        allow.tap()

        let decided = "POST /api/sessions/discord-triage/decision 200"
        var count = 0
        for _ in 0..<40 {
            count = try await requestCounts(controlVariable: "TEST_RUNNER_SECOND_FIXTURE_CONTROL_URL")[decided] ?? 0
            if count > 0 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(count, 1, "The Mustafar fixture did not receive the decision")
        let primaryDecisions = try await requestCounts(controlVariable: "TEST_RUNNER_FIXTURE_CONTROL_URL")
            .filter { $0.key.contains("/decision ") }
        XCTAssertTrue(primaryDecisions.isEmpty, "The decision also reached the primary fixture: \(primaryDecisions)")
    }

    func testStockadeSessionHidesUnsupportedControls() throws {
        let app = launch(sessionID: "mustafar:discord-triage")
        defer { app.terminate() }

        let subtitle = app.descendants(matching: .any)
            .matching(identifier: "selected-session-subtitle")
            .firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 75), "Mustafar session did not open")
        XCTAssertTrue(subtitle.label.hasPrefix("Mustafar · "), "Subtitle was not prefixed with the controller: \(subtitle.label)")

        let allow = app.buttons["approval-discord-triage-allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "Mustafar approval card did not load")
        let caption = app.descendants(matching: .any)
            .matching(identifier: "approval-controller-discord-triage")
            .firstMatch
        XCTAssertTrue(caption.exists, "Approval card did not name its controller")
        XCTAssertFalse(app.buttons["Allow for this session"].exists, "Stockade approval offered session scope")

        let composer = app.descendants(matching: .any)
            .matching(identifier: "composer-text")
            .firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "Composer did not load")
        XCTAssertFalse(app.buttons["Add attachment"].exists, "Composer offered attachments without the files capability")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Model ")).count,
            0,
            "Composer showed a model chip without the commands capability"
        )

        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10), "Session info button did not load")
        info.tap()
        let elapsed = app.descendants(matching: .any).matching(identifier: "inspector-elapsed").firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 20), "Inspector did not open")
        let picker = app.descendants(matching: .any).matching(identifier: "approval-mode-picker").firstMatch
        XCTAssertFalse(picker.exists, "Inspector offered an approval mode without the mode capability")
        addScreenshot(named: "multi-controller-stockade-session")
    }

    func testPeerPromptRendersAsPeerMessage() throws {
        let app = launch(sessionID: "mustafar:dune-relay")
        defer { app.terminate() }

        let peer = app.descendants(matching: .any)
            .matching(identifier: "peer-message")
            .firstMatch
        XCTAssertTrue(peer.waitForExistence(timeout: 75), "Peer prompt did not render as a peer message")
        XCTAssertTrue(peer.label.contains("From Kepler · macbook"), "Peer header was wrong: \(peer.label)")
        XCTAssertTrue(peer.label.contains("Is the Mustafar relay listening on 47834?"), "Peer text was missing: \(peer.label)")
        addScreenshot(named: "multi-controller-peer-message")
    }

    func testApprovalsElsewhereCountsEveryController() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        let app = launch(sessionID: "staff-account-exclusions")
        defer { app.terminate() }

        let sizeClass = app.descendants(matching: .any)
            .matching(identifier: "horizontal-size-class")
            .firstMatch
        XCTAssertTrue(sizeClass.waitForExistence(timeout: 30), "Horizontal size-class probe did not load")
        XCTAssertEqual(sizeClass.label, "regular", "Landscape pool device did not report regular horizontal size class")
        waitForLiveControllers(in: app)

        let capsule = app.buttons["approvals-elsewhere"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 75), "Approvals-elsewhere capsule did not load")
        let both = NSPredicate(format: "label == %@", "2 sessions need you")
        expectation(for: both, evaluatedWith: capsule)
        waitForExpectations(timeout: 30)
        addScreenshot(named: "multi-controller-approvals-elsewhere")
    }

    func testUnreachableControllerShowsOfflineHeader() throws {
        let app = launch(extraServer: "http://127.0.0.1:9", extraBearer: "unreachable-controller")
        defer { app.terminate() }

        XCTAssertTrue(
            app.buttons["session-staff-account-exclusions"].waitForExistence(timeout: 75),
            "Primary session was not visible"
        )
        let header = sectionHeader("mustafar", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 30), "Unreachable controller had no section header")
        let notLive = NSPredicate(format: "value == %@ OR value == %@", "offline", "reconnecting")
        expectation(for: notLive, evaluatedWith: header)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "controller-empty-mustafar").firstMatch.exists,
            "Unreachable controller section had no placeholder row"
        )
        XCTAssertEqual(sectionHeader("mac", in: app).value as? String, "live")
        addScreenshot(named: "multi-controller-offline-header")
    }

    // MARK: Helpers

    private func launch(
        sessionID: String? = nil,
        extraServer: String? = nil,
        extraBearer: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        let extra = try! JSONSerialization.data(withJSONObject: [[
            "id": "mustafar",
            "name": "Mustafar",
            "server": extraServer ?? requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_URL"),
        ]])
        app.launchArguments = [
            "-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL"),
            "-CCExtraControllers", String(decoding: extra, as: UTF8.self),
        ]
        if let sessionID {
            app.launchArguments += ["-CCSession", sessionID]
        }
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        app.launchEnvironment["CCExtraControllerBearer_mustafar"] = extraBearer
            ?? requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_BEARER")
        if let colorScheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !colorScheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", colorScheme]
        }
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func waitForLiveControllers(in app: XCUIApplication) {
        let probe = app.descendants(matching: .any)
            .matching(identifier: "controller-connections")
            .firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 75), "Controller connection probe did not load")
        let liveStates = "mac=live,mustafar=live"
        expectation(for: NSPredicate(format: "value == %@", liveStates), evaluatedWith: probe)
        waitForExpectations(timeout: 75)
        XCTAssertEqual(probe.value as? String, liveStates)
    }

    private func sectionHeader(_ controllerID: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "controller-section-\(controllerID)")
            .firstMatch
    }

    private func requestCounts(controlVariable: String) async throws -> [String: Int] {
        let control = requiredRunnerVariable(controlVariable)
        guard let url = URL(string: "\(control)/fixture/requests") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(payload["counts"] as? [String: Int])
    }

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
