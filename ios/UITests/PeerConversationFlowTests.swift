import Foundation
import XCTest

@MainActor
final class PeerConversationFlowTests: FixtureFlowTestSupport {
    func testPeerConversationCardShowsOnlyAllowAndDenyAndAllowSettles() async throws {
        try await postFixture("/fixture/peer-conversation")
        let app = launchSignedIn()
        defer { app.terminate() }
        openApprovalSession(in: app)

        let request = element(app, "peer-conversation-request")
        XCTAssertTrue(request.waitForExistence(timeout: 20), "Peer conversation request did not appear")
        XCTAssertTrue(request.label.contains("Stockade"), "Request omitted the sender controller")
        XCTAssertTrue(request.label.contains("wants to message"), "Request omitted the conversation sentence")
        XCTAssertTrue(element(app, "peer-conversation-preview").exists, "Message preview did not appear")
        XCTAssertFalse(app.buttons["Allow for this session"].exists, "Peer conversation offered a session-scoped Allow")

        let allow = app.buttons["approval-approval-flow-light-mode-allow"]
        let deny = app.buttons["approval-approval-flow-light-mode-deny"]
        XCTAssertTrue(allow.exists, "Peer conversation did not offer Allow")
        XCTAssertTrue(deny.exists, "Peer conversation did not offer Deny")
        allow.tap()
        XCTAssertTrue(allow.waitForNonExistence(timeout: 30), "Allow did not settle the peer conversation")
        try await waitForDecision("allow")
    }

    func testPeerConversationDenySettlesIt() async throws {
        try await postFixture("/fixture/peer-conversation")
        let app = launchSignedIn()
        defer { app.terminate() }
        openApprovalSession(in: app)

        let deny = app.buttons["approval-approval-flow-light-mode-deny"]
        XCTAssertTrue(deny.waitForExistence(timeout: 20), "Peer conversation Deny did not appear")
        XCTAssertFalse(app.buttons["Allow for this session"].exists, "Peer conversation offered a session-scoped Allow")
        deny.tap()
        XCTAssertTrue(deny.waitForNonExistence(timeout: 30), "Deny did not settle the peer conversation")
        try await waitForDecision("deny")
    }

    func testSettingsListsAndRevokesPeerConversation() async throws {
        let app = launchSignedIn()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30), "Settings button did not load")
        app.buttons["Settings"].tap()
        XCTAssertTrue(element(app, "settings-address").waitForExistence(timeout: 10), "Settings did not open")
        let controller = element(app, "settings-controller-mac")
        reveal(controller, in: app, "Controller list did not load")
        controller.tap()

        let section = app.staticTexts["Conversations with other controllers"]
        reveal(section, in: app, "Peer conversations section did not load")
        let row = element(app, "peer-conversation-\(conversationID)")
        reveal(row, in: app, "Open peer conversation did not appear")
        let revoke = element(app, "peer-conversation-revoke-\(conversationID)")
        XCTAssertTrue(revoke.exists, "Peer conversation did not offer Revoke")
        revoke.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Revoke", "peer-conversation-revoke-\(conversationID)")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Revoke confirmation did not appear")
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "Revoked conversation remained in Settings")
    }

    private let conversationID = "74dca0e9cd297800"

    private func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        if let scheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !scheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", scheme]
        }
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func openApprovalSession(in app: XCUIApplication) {
        let session = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(session.waitForExistence(timeout: 75), "Approval fixture session did not load")
        session.tap()
    }

    private func waitForDecision(_ expected: String) async throws {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)/fixture/peer-conversation/decision") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        for _ in 0..<120 {
            let (data, _) = try await URLSession.shared.data(from: url)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if object?["decision"] as? String == expected { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("Fixture did not report peer conversation decision \(expected)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls a lazy Form until the element is on screen, waiting for rows that load late.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, _ message: String, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        var swipes = 0
        while !(element.exists && element.isHittable) && Date() < deadline {
            if swipes < 8 {
                app.swipeUp()
                swipes += 1
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
        }
        XCTAssertTrue(element.exists && element.isHittable, message)
    }
}
