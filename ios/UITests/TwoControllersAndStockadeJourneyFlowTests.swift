import XCTest

/// A second controller, running Stockade, on the folded Duo: the merged list and its sessions' limits.
final class TwoControllersAndStockadeJourneyFlowTests: JourneyTestCase {
    private let secondControl = "TEST_RUNNER_SECOND_FIXTURE_CONTROL_URL"

    func testTwoControllersAndStockadeJourney() async throws {
        // The fixture's Dune turn 30 s in counts as a new message, and would move Dune up Recents mid-journey.
        try await postFixture("/fixture/disable-live-event")
        let app = launchSignedIn(extraControllers: true)
        defer { app.terminate() }

        // Both controllers go live, without a section per controller.
        let probe = app.element(identifier: "controller-connections")
        XCTAssertTrue(probe.waitToExist(timeout: 75), "Connection probe did not load")
        XCTAssertTrue(pollUntil(timeout: 75) { probe.value as? String == "mac=live,mustafar=live" }, "Both controllers did not go live: \(probe.value ?? "none")")
        let sessions = app.sessionsList
        XCTAssertTrue(sessions.waitToExist(timeout: 20), "Sessions list did not load")
        XCTAssertFalse(app.element(identifier: "controller-section-mac").exists, "A live controller had its own section")

        // Rows name their controller, and Stockade's rows name the agent too.
        let macWaiting = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(bringIntoView(macWaiting, in: sessions), "Mac's waiting session was not listed")
        XCTAssertEqual(macWaiting.value as? String, "needsYou")
        XCTAssertTrue(macWaiting.label.contains("Mac"), "Mac's waiting row had no controller caption: \(macWaiting.label)")
        addScreenshot(named: "two-controllers-list")
        let mustafarWaiting = app.buttons["session-discord-triage"]
        XCTAssertTrue(bringIntoView(mustafarWaiting, in: sessions), "Mustafar's waiting session was not listed")
        XCTAssertEqual(mustafarWaiting.value as? String, "needsYou")
        XCTAssertTrue(mustafarWaiting.label.contains("Mustafar"), "Mustafar's waiting row had no controller caption: \(mustafarWaiting.label)")
        let relay = app.buttons["session-dune-relay"]
        XCTAssertTrue(bringIntoView(relay, in: sessions), "Mustafar's session was not listed")
        XCTAssertTrue(relay.label.contains("Mustafar"), "Mustafar's session had no controller caption: \(relay.label)")
        let agent = app.element(identifier: "session-agent-dune-relay")
        XCTAssertTrue(bringIntoView(agent, in: sessions), "Stockade session had no agent line")
        XCTAssertEqual(agent.label, "Madge · Mustafar")

        // Recents mixes hosts by your last message, with host captions.
        let recents = app.staticTexts["Recents"]
        XCTAssertTrue(bringIntoView(recents, in: sessions), "Recents did not load")
        let expectedOrder = ["session-recent-review", "session-dune-part-three-imax-tickets"]
        let observedOrder = appearanceOrder(of: expectedOrder, in: sessions)
        XCTAssertEqual(observedOrder, expectedOrder, "Recents did not mix hosts by your last message: \(observedOrder)")
        XCTAssertTrue(app.buttons["session-recent-review"].label.contains("Mustafar"), "Recent row had no Mustafar caption")
        XCTAssertTrue(app.buttons["session-dune-part-three-imax-tickets"].label.contains("Mac"), "Recent row had no Mac caption")
        let pull = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(bringIntoView(pull, in: sessions), "Second Mac session was not listed")
        XCTAssertTrue(pull.label.contains("Mac"), "Second Mac session had no caption: \(pull.label)")
        addScreenshot(named: "two-controllers-recents")

        // A new session on Mustafar uses the host picker and starts with an agent, keeping the draft across the switch.
        app.buttons["new-session"].tap()
        let send = app.buttons["new-session-send"]
        XCTAssertTrue(send.waitToExist(timeout: 15), "New session did not open")
        let host = app.buttons["new-session-host"]
        XCTAssertTrue(host.waitToExist(timeout: 15), "Host picker did not load")
        let prompt = app.textFields["new-session-prompt"]
        XCTAssertTrue(prompt.waitToExist(timeout: 10), "Prompt did not load")
        prompt.tap()
        prompt.typeText("Check the Moonlight build")
        addScreenshot(named: "two-controllers-new-session")
        host.tap()
        let mustafar = app.buttons["Mustafar"]
        XCTAssertTrue(mustafar.waitToExist(timeout: 10), "Mustafar was not offered")
        mustafar.tap()
        let agentPicker = app.buttons["new-session-agent"]
        XCTAssertTrue(agentPicker.waitToExist(timeout: 20), "Agent picker did not load for Mustafar")
        XCTAssertTrue(agentPicker.label.contains("Madge"), "Agent picker did not default to Madge: \(agentPicker.label)")
        XCTAssertFalse(app.buttons["new-session-folder"].exists, "Stockade's New session showed a folder")
        XCTAssertTrue(send.isEnabled, "Send was off after the draft survived the host switch")
        XCTAssertEqual(prompt.value as? String, "Check the Moonlight build", "The draft did not survive the host switch")
        send.tap()
        XCTAssertTrue(app.selectedSessionName.waitToExist(timeout: 30), "Created Stockade session did not open")
        XCTAssertEqual(app.selectedSessionName.label, "Check the Moonlight build")
        var stockade = try await fixtureJSON("/fixture/stockade", control: secondControl)
        let created = try XCTUnwrap(stockade["created"] as? [[String: Any]])
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?["agentId"] as? String, "main")
        XCTAssertEqual(created.first?["text"] as? String, "Check the Moonlight build")
        goBackToSessions(in: app)

        // A Mustafar session names its controller and hides controls it has no capability for.
        XCTAssertTrue(bringIntoView(app.buttons["session-moonlight-build"], in: sessions), "Moonlight session was not listed")
        app.buttons["session-moonlight-build"].tap()
        let subtitle = app.selectedSessionSubtitle
        XCTAssertTrue(subtitle.waitToExist(timeout: 30), "Mustafar session did not open")
        XCTAssertTrue(subtitle.label.hasPrefix("Mustafar · "), "Subtitle did not start with the controller: \(subtitle.label)")
        let allow = app.buttons["approval-moonlight-build-allow"]
        XCTAssertTrue(allow.waitToExist(timeout: 30), "Mustafar's approval did not load")
        XCTAssertTrue(app.element(identifier: "approval-controller-moonlight-build").exists, "Approval did not name its controller")
        XCTAssertFalse(app.buttons["Allow for this session"].exists, "Stockade approval offered session scope")

        // Allow goes to Mustafar's controller and only there, and reaches Stockade.
        allow.tap()
        let decided = try await waitForFixtureRequest("POST /api/sessions/moonlight-build/decision 200", control: secondControl)
        XCTAssertTrue(decided, "Mustafar's fixture did not get the decision")
        let primaryDecisions = try await fixtureRequestCounts().filter { $0.key.contains("/decision ") }
        XCTAssertTrue(primaryDecisions.isEmpty, "The decision also reached the Mac: \(primaryDecisions)")
        stockade = try await fixtureJSON("/fixture/stockade", control: secondControl)
        let decisions = try XCTUnwrap(stockade["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.map { $0["id"] as? String }, ["moonlight-build-approval"], "Stockade did not get the decision")
        XCTAssertEqual(decisions.first?["behaviour"] as? String, "allow")

        // With the approval gone: attachments are on, there's no model chip, and details have no approval mode.
        let composer = app.composer
        XCTAssertTrue(composer.waitToExist(timeout: 30), "Composer did not load")
        XCTAssertTrue(app.buttons["Add attachment"].exists, "Composer did not offer attachments with the files capability")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Model ")).count, 0, "Composer showed a model chip without the commands capability")
        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitToExist(timeout: 10), "Session info did not load")
        XCTAssertTrue(waitForStableFrame(info), "Session info did not settle before the tap")
        info.tap()
        XCTAssertTrue(app.element(identifier: "inspector-elapsed").waitToExist(timeout: 20), "Details did not open")
        XCTAssertFalse(app.element(identifier: "approval-mode-picker").exists, "Details offered an approval mode without the capability")
        addScreenshot(named: "two-controllers-stockade-session")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(app.element(identifier: "inspector-elapsed").waitToDisappear(timeout: 10), "Details did not close")
        goBackToSessions(in: app)

        // A peer's prompt renders as a peer message with the right header.
        // /sudo is suggested on a writable session, toggles with a toast, and is not sent as text.
        XCTAssertTrue(bringIntoView(relay, in: sessions), "Mustafar's session was not listed after going back")
        relay.tap()
        let peer = app.element(identifier: "peer-message")
        XCTAssertTrue(peer.waitToExist(timeout: 30), "Peer's prompt did not render as a peer message")
        XCTAssertTrue(peer.label.contains("From Kepler · macbook"), "Peer header was wrong: \(peer.label)")
        XCTAssertTrue(peer.label.contains("Is the Mustafar direct TLS listener available?"), "Peer text was missing: \(peer.label)")
        addScreenshot(named: "two-controllers-peer-message")
        XCTAssertTrue(composer.waitToExist(timeout: 30), "Composer did not load on the writable Stockade session")
        typeInComposer("/su", in: app)
        XCTAssertTrue(app.buttons["/sudo, Toggle sudo mode"].waitToExist(timeout: 10), "Composer did not suggest /sudo")
        composer.typeText("do")
        let sendButton = app.buttons["composer-send"]
        if sendButton.exists { sendButton.tap() } else { app.buttons["composer-queue"].tap() }
        let toast = app.element(identifier: "command-toast")
        XCTAssertTrue(toast.waitToExist(timeout: 20), "No toast after /sudo")
        XCTAssertEqual(toast.label, "Sudo on")
        XCTAssertTrue(pollUntil(timeout: 20) { app.selectedSessionSubtitle.label.hasSuffix("· sudo") }, "Subtitle did not show sudo")
        stockade = try await fixtureJSON("/fixture/stockade", control: secondControl)
        let sudo = try XCTUnwrap(stockade["sudoRequests"] as? [[String: Any]])
        XCTAssertEqual(sudo.map { $0["sessionId"] as? String }, ["dune-relay"])
        let messages = try XCTUnwrap(stockade["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.isEmpty, "/sudo was sent as message text: \(messages)")
        addScreenshot(named: "two-controllers-sudo")
        goBackToSessions(in: app)

        // A Discord session says to answer in Discord, offers no Allow or Deny, and has no composer.
        XCTAssertTrue(bringIntoView(mustafarWaiting, in: sessions), "Discord session was not listed after going back")
        mustafarWaiting.tap()
        let answerIn = app.element(identifier: "approval-discord-triage-answer-in")
        XCTAssertTrue(answerIn.waitToExist(timeout: 30), "Discord approval did not say where to answer")
        XCTAssertEqual(answerIn.label, "Answer in Discord")
        XCTAssertFalse(app.buttons["approval-discord-triage-allow"].exists, "Discord approval offered Allow")
        XCTAssertFalse(app.buttons["approval-discord-triage-deny"].exists, "Discord approval offered Deny")
        XCTAssertFalse(composer.exists, "Read-only session showed a composer")

        // Its details list who's in it and why it's read-only.
        info.tap()
        let inspector = app.collectionViews.firstMatch
        let people = app.element(identifier: "inspector-participants")
        XCTAssertTrue(bringIntoView(people, in: inspector), "Details had no participants")
        XCTAssertTrue(people.label.contains("sam, riley"), "Participants were wrong: \(people.label)")
        let access = app.element(identifier: "inspector-access")
        XCTAssertTrue(bringIntoView(access, in: inspector), "Details had no access row")
        XCTAssertTrue(access.label.contains("Read-only · Discord"), "Access row was wrong: \(access.label)")
        addScreenshot(named: "two-controllers-discord-details")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(access.waitToDisappear(timeout: 10), "Details did not close")

        // Once it's answered elsewhere, a read-only bar replaces the card.
        var request = URLRequest(url: try XCTUnwrap(URL(string: requiredRunnerVariable(secondControl) + "/fixture/stockade/answered-elsewhere/discord-triage-approval")))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let bar = app.element(identifier: "read-only-bar")
        XCTAssertTrue(bar.waitToExist(timeout: 30), "Read-only bar did not replace the card")
        XCTAssertEqual(bar.label, "Read-only · Discord")
        XCTAssertFalse(composer.exists, "Read-only session showed a composer")
        addScreenshot(named: "two-controllers-read-only-bar")
    }

    private func bringIntoView(_ element: XCUIElement, in container: XCUIElement) -> Bool {
        if element.exists && element.isHittable { return true }
        for _ in 0..<8 {
            container.swipeUp()
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }

    private func appearanceOrder(of identifiers: [String], in list: XCUIElement) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for swipe in 0...10 {
            let visible = identifiers.compactMap { identifier -> (String, CGFloat)? in
                let element = list.descendants(matching: .any).matching(identifier: identifier).firstMatch
                guard !seen.contains(identifier), element.exists, element.isHittable else { return nil }
                return (identifier, element.frame.minY)
            }.sorted { $0.1 < $1.1 }
            for (identifier, _) in visible {
                seen.insert(identifier)
                order.append(identifier)
            }
            if seen.count == identifiers.count || swipe == 10 { break }
            list.swipeUp(velocity: .slow)
        }
        return order
    }
}
