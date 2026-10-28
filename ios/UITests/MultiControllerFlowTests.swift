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
        let mac = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(bringIntoView(mac, in: sessions), "Primary session was not visible")
        XCTAssertTrue(mac.label.contains("Mac"), "Primary session had no controller caption: \(mac.label)")
        let dune = app.buttons["session-dune-relay"]
        XCTAssertTrue(bringIntoView(dune, in: sessions), "Mustafar session was not listed")
        XCTAssertTrue(dune.label.contains("Mustafar"), "Mustafar session had no controller caption: \(dune.label)")
        let agent = app.descendants(matching: .any).matching(identifier: "session-agent-dune-relay").firstMatch
        XCTAssertTrue(bringIntoView(agent, in: sessions), "Stockade session had no agent line")
        XCTAssertEqual(agent.label, "Madge · Mustafar")
    }

    func testNeedsYouMergesControllersWithCaptions() throws {
        let app = launch()
        defer { app.terminate() }
        waitForLiveControllers(in: app)

        let sessions = app.descendants(matching: .any)
            .matching(identifier: "sessions-list")
            .firstMatch
        XCTAssertTrue(sessions.waitForExistence(timeout: 20), "Sessions list did not load")
        let macRow = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(bringIntoView(macRow, in: sessions), "Mac approval session was not listed")
        XCTAssertEqual(macRow.value as? String, "needs_you")
        XCTAssertTrue(macRow.label.contains("Mac"), "Mac Needs-you row had no controller caption: \(macRow.label)")

        let mustafarRow = app.buttons["session-discord-triage"]
        XCTAssertTrue(bringIntoView(mustafarRow, in: sessions), "Mustafar approval session was not listed")
        XCTAssertEqual(mustafarRow.value as? String, "needs_you")
        XCTAssertTrue(mustafarRow.label.contains("Mustafar"), "Mustafar Needs-you row had no controller caption: \(mustafarRow.label)")

        // Both Needs-you rows sit above the merged Recents section.
        let recents = app.staticTexts["Recents"]
        XCTAssertTrue(recents.exists, "Recents section did not load")
        XCTAssertLessThan(macRow.frame.minY, recents.frame.minY, "Mac Needs-you row was not pinned above Recents")
        XCTAssertLessThan(mustafarRow.frame.minY, recents.frame.minY, "Mustafar Needs-you row was not pinned above Recents")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "controller-section-mac").firstMatch.exists)
    }

    func testRecentsMergeControllersByLastMessageTimeAndShowHosts() throws {
        let app = launch()
        defer { app.terminate() }
        waitForLiveControllers(in: app)

        let sessions = app.descendants(matching: .any)
            .matching(identifier: "sessions-list")
            .firstMatch
        XCTAssertTrue(sessions.waitForExistence(timeout: 20), "Sessions list did not load")

        let needsYou = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(needsYou.waitForExistence(timeout: 20), "Needs-you session was not listed")
        let recents = app.staticTexts["Recents"]
        XCTAssertTrue(bringIntoView(recents, in: sessions), "Recents section did not load")
        XCTAssertLessThan(needsYou.frame.minY, recents.frame.minY, "Needs-you session was not pinned above Recents")

        let expectedOrder = [
            "session-recent-review",
            "session-dune-part-three-imax-tickets",
        ]
        let observedOrder = appearanceOrder(of: expectedOrder, in: sessions)
        XCTAssertEqual(observedOrder, expectedOrder, "Recents did not interleave hosts by owner message time: \(observedOrder)")
        for identifier in expectedOrder {
            let row = app.buttons[identifier]
            XCTAssertTrue(row.label.contains(identifier.contains("recent-review") ? "Mustafar" : "Mac"), "Row \(identifier) had no host caption: \(row.label)")
        }
        let pull = app.buttons["session-pull-up-agentic-uw"]
        XCTAssertTrue(bringIntoView(pull, in: sessions), "Second Mac Recents session was not listed")
        XCTAssertTrue(pull.label.contains("Mac"), "Second Mac Recents session had no host caption: \(pull.label)")
        addScreenshot(named: "multi-controller-recents")
    }

    func testAllowingMustafarApprovalPostsToTheMustafarController() async throws {
        let app = launch()
        defer { app.terminate() }
        waitForLiveControllers(in: app)

        let allow = app.buttons["approval-moonlight-build-allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "Mustafar compact approval card did not load")
        allow.tap()

        let decided = "POST /api/sessions/moonlight-build/decision 200"
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
        let stockade = try await stockadeFixture()
        let decisions = try XCTUnwrap(stockade["decisions"] as? [[String: Any]])
        XCTAssertEqual(decisions.map { $0["id"] as? String }, ["moonlight-build-approval"], "Stockade did not receive the decision")
        XCTAssertEqual(decisions.first?["behaviour"] as? String, "allow")
    }

    func testStockadeSessionHidesUnsupportedControls() throws {
        let app = launch(sessionID: "mustafar:moonlight-build")
        defer { app.terminate() }

        let subtitle = app.descendants(matching: .any)
            .matching(identifier: "selected-session-subtitle")
            .firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 75), "Mustafar session did not open")
        XCTAssertTrue(subtitle.label.hasPrefix("Mustafar · "), "Subtitle was not prefixed with the controller: \(subtitle.label)")

        let allow = app.buttons["approval-moonlight-build-allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "Mustafar approval card did not load")
        let caption = app.descendants(matching: .any)
            .matching(identifier: "approval-controller-moonlight-build")
            .firstMatch
        XCTAssertTrue(caption.exists, "Approval card did not name its controller")
        XCTAssertFalse(app.buttons["Allow for this session"].exists, "Stockade approval offered session scope")
        allow.tap()

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
        XCTAssertTrue(peer.label.contains("Is the Mustafar direct TLS listener available?"), "Peer text was missing: \(peer.label)")
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

        let sidebarToggle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'"))
            .firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 20), "Sidebar toggle did not load")
        sidebarToggle.tap()
        expectation(for: NSPredicate(format: "value == %@", "detailOnly"), evaluatedWith: sizeClass)
        waitForExpectations(timeout: 20)

        let capsule = app.buttons["approvals-elsewhere"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 75), "Approvals-elsewhere capsule did not load")
        // One Mac approval, plus Mustafar's writable approval and its Discord one (answered in Discord, still waiting).
        let both = NSPredicate(format: "label == %@", "3 sessions need you")
        expectation(for: both, evaluatedWith: capsule)
        waitForExpectations(timeout: 30)
        addScreenshot(named: "multi-controller-approvals-elsewhere")
    }

    func testDiscordSessionIsReadOnly() throws {
        let app = launch(sessionID: "mustafar:discord-triage")
        defer { app.terminate() }

        let answerIn = app.descendants(matching: .any)
            .matching(identifier: "approval-discord-triage-answer-in")
            .firstMatch
        XCTAssertTrue(answerIn.waitForExistence(timeout: 75), "Discord approval did not say where to answer")
        XCTAssertEqual(answerIn.label, "Answer in Discord")
        XCTAssertFalse(app.buttons["approval-discord-triage-allow"].exists, "Discord approval offered Allow")
        XCTAssertFalse(app.buttons["approval-discord-triage-deny"].exists, "Discord approval offered Deny")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch.exists,
            "Read-only session showed a composer"
        )

        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10), "Session info button did not load")
        info.tap()
        let inspector = app.collectionViews.firstMatch
        let people = app.descendants(matching: .any).matching(identifier: "inspector-participants").firstMatch
        XCTAssertTrue(bringIntoView(people, in: inspector), "Inspector had no participants row")
        XCTAssertTrue(people.label.contains("sam, riley"), "Participants were wrong: \(people.label)")
        let access = app.descendants(matching: .any).matching(identifier: "inspector-access").firstMatch
        XCTAssertTrue(bringIntoView(access, in: inspector), "Inspector had no access row")
        XCTAssertTrue(access.label.contains("Read-only · Discord"), "Access row was wrong: \(access.label)")
        addScreenshot(named: "multi-controller-discord-read-only")
    }

    func testDiscordSessionWithoutApprovalShowsReadOnlyBar() async throws {
        let app = launch(sessionID: "mustafar:discord-triage")
        defer { app.terminate() }

        let answerIn = app.descendants(matching: .any)
            .matching(identifier: "approval-discord-triage-answer-in")
            .firstMatch
        XCTAssertTrue(answerIn.waitForExistence(timeout: 75), "Discord approval did not load")
        try await postStockade("/fixture/stockade/answered-elsewhere/discord-triage-approval")

        let bar = app.descendants(matching: .any).matching(identifier: "read-only-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "Read-only bar did not replace the composer")
        XCTAssertEqual(bar.label, "Read-only · Discord")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch.exists,
            "Read-only session showed a composer"
        )
        addScreenshot(named: "multi-controller-read-only-bar")
    }

    func testSudoTogglesOnAWritableStockadeSession() async throws {
        let app = launch(sessionID: "mustafar:dune-relay")
        defer { app.terminate() }

        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 75), "Composer did not load on the writable Stockade session")
        composer.tap()
        composer.typeText("/su")
        XCTAssertTrue(
            app.buttons["/sudo, Toggle sudo mode"].waitForExistence(timeout: 10),
            "Composer did not suggest /sudo"
        )
        composer.typeText("do")
        let send = app.buttons["composer-send"]
        if send.exists { send.tap() } else { app.buttons["composer-queue"].tap() }

        let toast = app.descendants(matching: .any).matching(identifier: "command-toast").firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 20), "No toast after /sudo")
        XCTAssertEqual(toast.label, "Sudo on")
        let subtitle = app.descendants(matching: .any).matching(identifier: "selected-session-subtitle").firstMatch
        let sudoSubtitle = expectation(for: NSPredicate(format: "label ENDSWITH %@", "· sudo"), evaluatedWith: subtitle)
        await fulfillment(of: [sudoSubtitle], timeout: 20)

        let stockade = try await stockadeFixture()
        let sudo = try XCTUnwrap(stockade["sudoRequests"] as? [[String: Any]])
        XCTAssertEqual(sudo.map { $0["sessionId"] as? String }, ["dune-relay"])
        let messages = try XCTUnwrap(stockade["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.isEmpty, "/sudo was sent as message text: \(messages)")
        addScreenshot(named: "multi-controller-sudo")
    }

    func testNewSessionOnMustafarStartsWithAnAgent() async throws {
        let app = launch()
        defer { app.terminate() }
        waitForLiveControllers(in: app)

        let button = app.buttons["new-session"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "New session toolbar button did not load")
        button.tap()
        XCTAssertTrue(app.buttons["new-session-send"].waitForExistence(timeout: 15), "New session sheet did not open")
        let controller = app.buttons["new-session-host"]
        XCTAssertTrue(controller.waitForExistence(timeout: 15), "Host picker did not load")
        let draft = app.textFields["new-session-prompt"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10), "Prompt field did not load")
        draft.tap()
        draft.typeText("Check the Moonlight build")
        if UIDevice.current.name.localizedCaseInsensitiveContains("Duo") {
            XCUIDevice.shared.orientation = .portrait
            try await Task.sleep(for: .seconds(1))
            addScreenshot(named: "new-session-composer-host-folder-agent-portrait")
            XCUIDevice.shared.orientation = .landscapeRight
            try await Task.sleep(for: .seconds(1))
            addScreenshot(named: "new-session-composer-host-folder-agent-landscape")
        } else {
            XCUIDevice.shared.orientation = .landscapeRight
            try await Task.sleep(for: .seconds(1))
            addScreenshot(named: "new-session-composer-host-folder-agent")
        }
        controller.tap()
        let mustafar = app.buttons["Mustafar"]
        XCTAssertTrue(mustafar.waitForExistence(timeout: 10), "Mustafar was not offered")
        mustafar.tap()

        let agent = app.buttons["new-session-agent"]
        XCTAssertTrue(agent.waitForExistence(timeout: 20), "Agent picker did not load for Mustafar")
        XCTAssertTrue(agent.label.contains("Madge"), "Agent picker did not default to Madge: \(agent.label)")
        XCTAssertFalse(app.buttons["new-session-folder"].exists, "Stockade New Session showed a folder")
        XCTAssertTrue(app.buttons["new-session-send"].isEnabled, "Send was not enabled after the draft survived host switch")

        let message = app.textFields["new-session-prompt"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "Prompt field did not load")
        XCTAssertEqual(message.value as? String, "Check the Moonlight build", "Prompt draft did not survive host switch")
        addScreenshot(named: "multi-controller-new-session-agent")
        app.buttons["new-session-send"].tap()

        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Created Stockade session did not open")
        XCTAssertEqual(title.label, "Check the Moonlight build")

        let stockade = try await stockadeFixture()
        let created = try XCTUnwrap(stockade["created"] as? [[String: Any]])
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?["agentId"] as? String, "main")
        XCTAssertEqual(created.first?["text"] as? String, "Check the Moonlight build")
    }

    func testUnreachableControllerShowsOfflineHeader() throws {
        let app = launch(extraServer: "http://127.0.0.1:9", extraBearer: "unreachable-controller")
        defer { app.terminate() }

        XCTAssertTrue(
            app.buttons["session-staff-account-exclusions"].waitForExistence(timeout: 75),
            "Primary session was not visible"
        )
        let sessions = app.descendants(matching: .any)
            .matching(identifier: "sessions-list")
            .firstMatch
        let header = sectionHeader("mustafar", in: app)
        XCTAssertTrue(bringIntoView(header, in: sessions), "Unreachable controller had no status row")
        let notLive = NSPredicate(format: "value == %@ OR value == %@", "offline", "reconnecting")
        expectation(for: notLive, evaluatedWith: header)
        waitForExpectations(timeout: 30)
        let retry = app.buttons["controller-retry-mustafar"]
        XCTAssertTrue(retry.exists, "Unreachable controller status row had no Retry action")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "controller-section-mac").firstMatch.exists)
        addScreenshot(named: "multi-controller-offline-header")
    }

    // MARK: Helpers

    private func scrollToTop(of list: XCUIElement, until element: XCUIElement) -> Bool {
        if element.exists && element.isHittable { return true }
        for _ in 0..<10 {
            list.swipeDown(velocity: .slow)
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }

    private func appearanceOrder(
        of identifiers: [String],
        in list: XCUIElement,
        maxSwipes: Int = 10
    ) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for swipe in 0...maxSwipes {
            let visible = identifiers.compactMap { identifier -> (String, CGFloat)? in
                let element = list.descendants(matching: .any)
                    .matching(identifier: identifier)
                    .firstMatch
                guard !seen.contains(identifier), element.exists, element.isHittable else { return nil }
                return (identifier, element.frame.minY)
            }.sorted { $0.1 < $1.1 }
            for (identifier, _) in visible {
                seen.insert(identifier)
                order.append(identifier)
            }
            if seen.count == identifiers.count || swipe == maxSwipes { break }
            list.swipeUp(velocity: .slow)
        }
        return order
    }

    private func bringIntoView(_ element: XCUIElement, in scrollContainer: XCUIElement) -> Bool {
        if element.exists && element.isHittable { return true }
        for _ in 0..<8 {
            scrollContainer.swipeUp()
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }

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

    private func stockadeFixture() async throws -> [String: Any] {
        let control = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_CONTROL_URL")
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(control)/fixture/stockade")!)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func postStockade(_ path: String) async throws {
        let control = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_CONTROL_URL")
        var request = URLRequest(url: URL(string: "\(control)\(path)")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
