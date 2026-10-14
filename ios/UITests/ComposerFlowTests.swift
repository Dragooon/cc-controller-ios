import XCTest

@MainActor
final class ComposerFlowTests: XCTestCase {
    private var auditLines: [String] = []

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "composer-audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testSendTargetsNewlySelectedSession() async throws {
        let app = launchFixture()
        try await postFixture("/fixture/disable-live-event")
        defer {
            audit(app: app, name: "composer-session-target")
            attach(named: "composer-session-target")
            app.terminate()
        }

        openSession(id: "session-dune-part-three-imax-tickets", in: app)
        XCTAssertTrue(app.buttons["Model Fable 5.1"].waitForExistence(timeout: 10), "Warm session B model chip did not load")
        let sessionsBackButton = app.navigationBars.buttons["Sessions"]
        XCTAssertTrue(sessionsBackButton.waitForExistence(timeout: 10), "Sessions back button did not load after warming B")
        sessionsBackButton.tap()

        openSession(id: "session-long-session", in: app)
        XCTAssertTrue(app.buttons["Model Fable 5.1"].waitForExistence(timeout: 10), "Session A model chip did not load")

        XCTAssertTrue(sessionsBackButton.waitForExistence(timeout: 10), "Sessions back button did not load")
        sessionsBackButton.tap()
        let clearSearchField = app.searchFields.firstMatch
        if !clearSearchField.exists { app.buttons["Search"].tap() }
        XCTAssertTrue(clearSearchField.waitForExistence(timeout: 15), "Session search field did not return")
        clearSearchField.tap()
        if app.buttons["Clear text"].exists { app.buttons["Clear text"].tap() }
        clearSearchField.typeText("Dune Part Three")

        let sessionB = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(sessionB.waitForExistence(timeout: 15), "Session B row did not load")
        let idleExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "idle"),
            object: sessionB
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [idleExpectation], timeout: 10),
            .completed,
            "Session B did not remain idle with the same model as session A"
        )
        sessionB.tap()

        let field = composerField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Session B composer did not load")
        print("COMPOSER_DRAFT_CARRY_OVER sessionB=\(field.value ?? "<nil>")")
        XCTAssertEqual(field.value as? String, "", "Session A draft carried into session B")

        let marker1 = "composer-session-target-1-\(UUID().uuidString)"
        let marker2 = "composer-session-target-2-\(UUID().uuidString)"
        print("COMPOSER_MARKERS marker1=\(marker1) marker2=\(marker2)")
        field.tap()
        field.typeText(marker1)
        app.buttons["composer-send"].tap()

        let sentInB = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker1)).firstMatch
        XCTAssertTrue(sentInB.waitForExistence(timeout: 10), "Marker 1 did not appear in session B")
        let resetField = composerField(in: app)
        XCTAssertTrue(waitForValue(of: resetField, equalTo: "", timeout: 10), "Composer did not reset after marker 1")
        resetField.tap()
        resetField.typeText(marker2)
        app.buttons["composer-send"].tap()
        try await Task.sleep(for: .seconds(1))

        XCTAssertTrue(sessionsBackButton.waitForExistence(timeout: 10), "Sessions back button did not return after sending")
        sessionsBackButton.tap()
        let resultSearchButton = app.buttons["Search"]
        XCTAssertTrue(resultSearchButton.waitForExistence(timeout: 15), "Session search did not return after sending")
        resultSearchButton.tap()
        let resultSearch = app.searchFields.firstMatch
        XCTAssertTrue(resultSearch.waitForExistence(timeout: 15), "Session search field did not return after sending")
        resultSearch.tap()
        if app.buttons["Clear text"].exists { app.buttons["Clear text"].tap() }
        resultSearch.typeText("Long session")
        let sessionARow = app.buttons["session-long-session"]
        XCTAssertTrue(sessionARow.waitForExistence(timeout: 15), "Session A row did not return after sending")
        sessionARow.tap()
        XCTAssertTrue(composerField(in: app).waitForExistence(timeout: 20), "Session A did not reopen after sending")
        let sessionAResult = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", marker1, marker2)
        ).firstMatch
        XCTAssertFalse(sessionAResult.waitForExistence(timeout: 7), "A marker was delivered to session A")
    }

    func testSendFromIdleSession() throws {
        let app = launchFixture()
        defer {
            attach(named: "composer-sent")
            audit(app: app, name: "composer-sent")
            app.terminate()
        }

        openSession(id: "session-long-session", in: app)
        let field = composerField(in: app)
        let initialHeight = field.frame.height
        let marker = "composer-sent-\(UUID().uuidString)"
        let message = marker + String(repeating: " wrap", count: 30)
        field.tap()
        field.typeText(message)

        let wrappedHeight = waitForHeight(of: field, greaterThan: initialHeight, timeout: 10)
        XCTAssertNotNil(wrappedHeight, "Composer did not grow after wrapping: initial \(initialHeight), current \(field.frame.height)")
        XCTAssertGreaterThan(wrappedHeight ?? initialHeight, initialHeight)

        let send = app.buttons["composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send button did not load for an idle session")
        send.tap()

        let pending = app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "Sent marker did not appear as a pending prompt")
        XCTAssertTrue(pending.label.contains(marker), "Pending bubble did not contain the sent marker")

        let resetField = composerField(in: app)
        XCTAssertTrue(resetField.waitForExistence(timeout: 10), "Composer did not reappear after send")
        XCTAssertTrue(waitForValue(of: resetField, equalTo: "", timeout: 10), "Composer text did not clear after send")
        let resetHeight = resetField.frame.height
        XCTAssertLessThanOrEqual(abs(resetHeight - initialHeight), 2, "Composer did not reset height: initial \(initialHeight), reset \(resetHeight)")
        print("composer heights initial=\(initialHeight) wrapped=\(wrappedHeight ?? field.frame.height) reset=\(resetHeight)")
        resetField.typeText("f")
        XCTAssertEqual(resetField.value as? String, "f", "Composer did not retain keyboard focus after send")
        XCTAssertTrue(waitForNonExistence(of: pending, timeout: 15), "Pending prompt did not become delivered")
        let prompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "Delivered sent marker did not render in the transcript")
        XCTAssertTrue(waitForHittable(prompt, timeout: 15), "Delivered sent marker was not hittable in the transcript")
        let matchingPrompts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker))
        XCTAssertEqual(matchingPrompts.count, 1, "Sent marker appeared in both pending and delivered prompts")
        XCTAssertTrue(app.buttons["Model Fable 5.1"].waitForExistence(timeout: 10), "Model chip did not render")
    }

    func testSendClearsTrailingWhitespace() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "composer-trailing-whitespace")
            attach(named: "composer-trailing-whitespace")
            app.terminate()
        }

        openSession(id: "session-long-session", in: app)
        let field = composerField(in: app)
        let marker = "trailing-space-\(UUID().uuidString)"
        field.tap()
        field.typeText(marker + " ")
        app.buttons["composer-send"].tap()

        let pending = app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "Trailing-space send did not appear as a pending prompt")
        XCTAssertTrue(waitForValue(of: field, equalTo: "", timeout: 10), "Composer retained trailing whitespace after successful send")
    }

    func testSendClearsLeadingWhitespace() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "composer-leading-whitespace")
            attach(named: "composer-leading-whitespace")
            app.terminate()
        }

        openSession(id: "session-long-session", in: app)
        let field = composerField(in: app)
        let marker = "leading-space-\(UUID().uuidString)"
        field.tap()
        field.typeText("  " + marker)
        app.buttons["composer-send"].tap()

        let pending = app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "Leading-space send did not appear as a pending prompt")
        XCTAssertTrue(waitForValue(of: field, equalTo: "", timeout: 10), "Composer retained leading whitespace after successful send")
    }

    func testStopFromWorkingModSession() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "composer-stop-mod")
            attach(named: "composer-stop-mod")
            app.terminate()
        }

        openSession(id: "session-dune-part-three-imax-tickets", in: app)
        let field = composerField(in: app)
        XCTAssertTrue(field.waitForPlaceholder("Queue a message", timeout: 45), "Dune fixture session did not become working")

        let stop = app.buttons["composer-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Stop button did not load for a working mod session")
        stop.tap()

        let requests = try await waitForKeyRequests(timeout: 10)
        XCTAssertTrue(
            requests.contains { $0.sessionID == "dune-part-three-imax-tickets" && $0.key == "escape" },
            "Tapping Stop did not send escape: \(requests)"
        )
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1), "An idle Stop response showed an error alert")
    }

    func testQueueWhileWorking() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "composer-queued")
            attach(named: "composer-queued")
            app.terminate()
        }

        openSession(id: "session-dune-part-three-imax-tickets", in: app)
        let field = composerField(in: app)
        XCTAssertTrue(
            field.waitForPlaceholder("Queue a message", timeout: 45),
            "Dune fixture session did not become working"
        )
        let initialHeight = field.frame.height
        let composer = app.otherElements["Message composer"]
        let unfocusedComposerHeight = composer.frame.height

        let marker = "dune-part-three-imax-tickets"
        field.tap()
        let focusedComposerHeight = composer.frame.height
        field.typeText(marker)
        try await postFixture("/fixture/tail-only")
        let send = app.buttons["composer-queue"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Queue button did not load while working")
        send.tap()
        XCTAssertTrue(app.staticTexts["Queued"].waitForExistence(timeout: 10), "Queued caption did not render")

        try await Task.sleep(for: .milliseconds(100))
        let earlyComposerHeight = composer.frame.height
        attach(named: "composer-queued-0.1s")
        try await Task.sleep(for: .milliseconds(1400))
        let settledComposerHeight = composer.frame.height
        attach(named: "composer-queued-1.5s")
        print("composer queue timing glassUnfocused=\(unfocusedComposerHeight) glassFocused=\(focusedComposerHeight) glassAt0.1=\(earlyComposerHeight) glassAt1.5=\(settledComposerHeight)")
        XCTAssertLessThanOrEqual(abs(earlyComposerHeight - focusedComposerHeight), 2, "Composer glass grew during queue reset: focused \(focusedComposerHeight), at 0.1s \(earlyComposerHeight)")
        XCTAssertLessThanOrEqual(abs(settledComposerHeight - focusedComposerHeight), 2, "Composer glass did not settle: focused \(focusedComposerHeight), at 1.5s \(settledComposerHeight)")

        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 15), "Queued marker did not render")
        XCTAssertTrue(waitForNonExistence(of: app.staticTexts["Queued"], timeout: 10), "Queued caption did not clear after tail delivery")
        let resetField = composerField(in: app)
        XCTAssertTrue(resetField.waitForExistence(timeout: 10), "Composer did not remain visible after queue")
        XCTAssertTrue(waitForValue(of: resetField, equalTo: "", timeout: 10), "Composer text did not clear after queue")
        let resetHeight = resetField.frame.height
        XCTAssertLessThanOrEqual(abs(resetHeight - initialHeight), 2, "Composer did not reset height while queueing: initial \(initialHeight), reset \(resetHeight)")
        let resetComposerHeight = composer.frame.height
        print("composer queue heights fieldInitial=\(initialHeight) fieldReset=\(resetHeight) glassFocused=\(focusedComposerHeight) glassReset=\(resetComposerHeight)")
        XCTAssertLessThanOrEqual(abs(resetComposerHeight - focusedComposerHeight), 2, "Composer glass did not reset height while queueing: focused \(focusedComposerHeight), reset \(resetComposerHeight)")
        let contextSubtitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "ctx 6%")).firstMatch
        XCTAssertTrue(contextSubtitle.waitForExistence(timeout: 10), "Navigation subtitle did not show ctx 6%")
    }

    func testSlashSuggestions() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "composer-slash")
            attach(named: "composer-slash")
            app.terminate()
        }

        openSession(id: "session-dune-part-three-imax-tickets", in: app)
        let field = composerField(in: app)
        field.tap()
        field.typeText("/co")

        let compact = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] '/compact,'")).firstMatch
        let cost = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] '/cost,'")).firstMatch
        let clear = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] '/clear,'")).firstMatch
        XCTAssertTrue(compact.waitForExistence(timeout: 10), "/compact suggestion did not load")
        XCTAssertTrue(cost.exists, "/cost suggestion did not load")
        XCTAssertFalse(clear.exists, "/clear must not match /co")

        compact.tap()
        XCTAssertEqual(field.value as? String, "/compact ", "Suggestion did not replace composer text")
    }

    func testComposerDraftSurvivesNavigationBackgroundReconnectAndRelaunch() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "composer-draft-relaunch")
            attach(named: "composer-draft-relaunch")
            app.terminate()
        }

        try await postFixture("/fixture/clear-approvals")
        openSession(id: "session-staff-account-exclusions", in: app)
        let field = composerField(in: app)
        let marker = "draft-survives-\(UUID().uuidString)"
        field.tap()
        field.typeText(marker)

        let resultRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH[c] 'subagent-result-row-'" )).firstMatch
        XCTAssertTrue(resultRow.waitForExistence(timeout: 20), "Subagent result row did not load for draft navigation")
        resultRow.tap()
        let viewTranscript = app.buttons["View transcript"]
        XCTAssertTrue(viewTranscript.waitForExistence(timeout: 10), "Subagent result sheet did not load")
        viewTranscript.tap()
        XCTAssertTrue(app.navigationBars["engineer"].waitForExistence(timeout: 15), "Subagent transcript did not open")
        let back = app.navigationBars["engineer"].buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Subagent transcript did not expose a back button")
        back.tap()

        let returnedField = composerField(in: app)
        XCTAssertTrue(returnedField.waitForExistence(timeout: 10), "Composer did not return after subagent navigation")
        XCTAssertEqual(returnedField.value as? String, marker, "Draft was lost after subagent navigation")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(returnedField.waitForExistence(timeout: 10), "Composer did not return after foregrounding")
        XCTAssertEqual(returnedField.value as? String, marker, "Draft was lost after backgrounding")

        try await postFixture("/fixture/registry-event")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(composerField(in: app).value as? String, marker, "Draft was lost after registry reconnect")

        try await Task.sleep(for: .seconds(1))
        app.terminate()
        app.launch()
        openSession(id: "session-staff-account-exclusions", in: app)
        let relaunchedField = composerField(in: app)
        XCTAssertTrue(relaunchedField.waitForExistence(timeout: 15), "Composer did not load after relaunch")
        XCTAssertEqual(relaunchedField.value as? String, marker, "Draft was not restored after relaunch")
    }

    func testComposerDraftStaysOnRejectedSendAndClearsOnSuccess() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "composer-draft-send-outcomes")
            attach(named: "composer-draft-send-outcomes")
            app.terminate()
        }

        try await postFixture("/fixture/clear-approvals")
        openSession(id: "session-staff-account-exclusions", in: app)
        let field = composerField(in: app)
        let marker = "draft-send-failure-\(UUID().uuidString)"
        field.tap()
        field.typeText(marker)
        try await postFixture("/fixture/reject-next-send")
        app.buttons["composer-send"].tap()
        XCTAssertTrue(waitForValue(of: field, equalTo: marker, timeout: 10), "Failed send wiped the draft")
        if app.alerts.firstMatch.waitForExistence(timeout: 5) { app.alerts.buttons["OK"].tap() }

        try await postFixture("/fixture/delay-next-send")
        app.buttons["composer-send"].tap()
        try await Task.sleep(for: .milliseconds(100))
        let extraText = " while sending"
        field.typeText(extraText)
        let resetField = composerField(in: app)
        XCTAssertTrue(waitForValue(of: resetField, equalTo: "while sending", timeout: 10), "Text typed during send did not survive")
    }

    private func postFixture(_ path: String) async throws {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)\(path)") else { throw XCTSkip("Fixture control URL was invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ComposerFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "fixture request failed"])
        }
    }

    private func waitForKeyRequests(timeout: TimeInterval) async throws -> [FixtureKeyRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let base = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
            guard let url = URL(string: "\(base)/fixture/key-requests") else { throw XCTSkip("Fixture control URL was invalid") }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "ComposerFlow", code: 2) }
            let result = try JSONDecoder().decode(FixtureKeyRequests.self, from: data)
            if !result.requests.isEmpty { return result.requests }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return []
    }

    private func launchFixture() -> XCUIApplication {
        let server = requiredRunnerVariable("TEST_RUNNER_SERVER_URL")
        let bearer = requiredRunnerVariable("TEST_RUNNER_BEARER")
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        app.launchEnvironment["CCBearer"] = bearer
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func openSession(id: String, in app: XCUIApplication) {
        if id == "session-long-session" || id == "session-dune-part-three-imax-tickets" {
            let searchButton = app.buttons["Search"]
            XCTAssertTrue(searchButton.waitForExistence(timeout: 15), "Session search did not load")
            searchButton.tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 15), "Session search field did not load")
            search.tap()
            if app.buttons["Clear text"].exists { app.buttons["Clear text"].tap() }
            search.typeText(id == "session-long-session" ? "Long session" : "Dune Part Three")
        }
        let row = app.buttons[id]
        XCTAssertTrue(row.waitForExistence(timeout: 75), "Fixture session \(id) did not load")
        row.tap()
        XCTAssertTrue(composerField(in: app).waitForExistence(timeout: 20), "Composer did not load")
    }

    private func composerField(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
    }

    private func audit(app: XCUIApplication, name: String) {
        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append("\(name): \(issue)")
                return true
            }
        } catch {
            auditLines.append("\(name) audit failed: \(error)")
        }
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct FixtureKeyRequests: Decodable {
    let requests: [FixtureKeyRequest]
}

private struct FixtureKeyRequest: Decodable, CustomStringConvertible {
    let sessionID: String
    let key: String

    var description: String { "FixtureKeyRequest(sessionID: \(sessionID), key: \(key))" }
}

@MainActor
private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"),
        object: element
    )
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
}

@MainActor
private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if element.exists && element.isHittable { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
}

@MainActor
private func waitForHeight(of element: XCUIElement, greaterThan height: CGFloat, timeout: TimeInterval) -> CGFloat? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let currentHeight = element.frame.height
        if currentHeight > height { return currentHeight }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return nil
}

@MainActor
private func waitForValue(of element: XCUIElement, equalTo expected: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if element.value as? String == expected { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
}

private extension XCUIElement {
    func waitForPlaceholder(_ expected: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "placeholderValue == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
