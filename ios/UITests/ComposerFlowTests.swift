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
        let clearSearchField = openSessionSearch(in: app)
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
        let resultSearch = openSessionSearch(in: app)
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

        let pending = app.descendants(matching: .any)
            .matching(identifier: "pending-prompt")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", marker))
            .firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "Sent marker did not appear as a pending prompt")
        XCTAssertTrue(waitForPendingStatus("Sent", in: app, timeout: 10), "Optimistic prompt did not reach Sent state")

        let resetField = composerField(in: app)
        XCTAssertTrue(resetField.waitForExistence(timeout: 10), "Composer did not reappear after send")
        XCTAssertTrue(waitForValue(of: resetField, equalTo: "", timeout: 10), "Composer text did not clear after send")
        let resetHeight = resetField.frame.height
        XCTAssertLessThanOrEqual(abs(resetHeight - initialHeight), 2, "Composer did not reset height: initial \(initialHeight), reset \(resetHeight)")
        print("composer heights initial=\(initialHeight) wrapped=\(wrappedHeight ?? field.frame.height) reset=\(resetHeight)")
        XCTAssertTrue(waitForKeyboardDismissal(in: app, timeout: 3), "Keyboard did not dismiss after send")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(app.keyboards.count, 0, "Keyboard reappeared after send")
        XCTAssertTrue(waitForNonExistence(of: pending, timeout: 15), "Pending prompt did not become delivered")
        let prompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 15), "Delivered sent marker did not render in the transcript")
        XCTAssertTrue(waitForHittable(prompt, timeout: 15), "Delivered sent marker was not hittable in the transcript")
        let matchingPrompts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker))
        XCTAssertEqual(matchingPrompts.count, 1, "Sent marker appeared in both pending and delivered prompts")
        XCTAssertTrue(app.buttons["Model Fable 5.1"].waitForExistence(timeout: 10), "Model chip did not render")
    }

    func testHeldSendShowsSendingAndClearsComposer() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "optimistic-sending")
            attach(named: "optimistic-sending")
            app.terminate()
        }
        openSession(id: "session-long-session", in: app)
        try await postFixture("/fixture/delay-next-send")
        let field = composerField(in: app)
        let marker = "optimistic-held-\(UUID().uuidString)"
        field.tap()
        field.typeText(marker)
        app.buttons["composer-send"].tap()

        let pending = app.descendants(matching: .any)
            .matching(identifier: "pending-prompt")
            .matching(NSPredicate(format: "label BEGINSWITH %@", marker))
            .firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 3), "Held send did not show an optimistic bubble")
        XCTAssertTrue(waitForPendingStatus("Sending…", message: marker, in: app, timeout: 3), "Held send did not show Sending…")
        XCTAssertTrue(waitForValue(of: field, equalTo: "", timeout: 3), "Composer did not clear while send was held")
        pending.press(forDuration: 1.0)
        XCTAssertTrue(
            waitForNoButtons(["Dismiss", "Retry", "Copy"], in: app, timeout: 2),
            "Sending bubble exposed an action menu"
        )
        attach(named: "optimistic-sending-before-delivery")
        XCTAssertTrue(waitForPendingStatus("Sent", message: marker, in: app, timeout: 15), "Held send did not reconcile to Sent")
        XCTAssertTrue(waitForNonExistence(of: pending, timeout: 15), "Held send did not reconcile into the transcript")
        let delivered = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
        XCTAssertTrue(delivered.waitForExistence(timeout: 10), "Held send delivered marker did not render")
        attach(named: "optimistic-sending-after-delivery")
    }

    func testFailedSendRetryShowsSentState() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "optimistic-retry")
            attach(named: "optimistic-retry")
            app.terminate()
        }
        openSession(id: "session-long-session", in: app)
        try await setMessageBehaviour(failNext: true, status: 500)
        let field = composerField(in: app)
        let marker = "optimistic-retry-\(UUID().uuidString)"
        field.tap()
        field.typeText(marker)
        app.buttons["composer-send"].tap()

        XCTAssertTrue(waitForPendingStatus("Not sent · Tap to retry", in: app, timeout: 10), "Failed send did not show its inline error")
        app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch.tap()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5), "Failed send confirmation did not offer Retry")
        app.buttons["Retry"].tap()
        XCTAssertTrue(waitForPendingStatus("Sent", in: app, timeout: 10), "Retry did not transition the note to Sent")
    }

    func testFailedSendEditRestoresComposerAndRemovesBubble() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "optimistic-edit")
            attach(named: "optimistic-edit")
            app.terminate()
        }
        openSession(id: "session-long-session", in: app)
        try await setMessageBehaviour(failNext: true, status: 500)
        let field = composerField(in: app)
        let marker = "optimistic-edit-\(UUID().uuidString)"
        field.tap()
        field.typeText(marker)
        app.buttons["composer-send"].tap()

        XCTAssertTrue(waitForPendingStatus("Not sent · Tap to retry", in: app, timeout: 10), "Failed send did not show its inline error")
        app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit message"].waitForExistence(timeout: 5), "Failed send confirmation did not offer Edit message")
        app.buttons["Edit message"].tap()
        XCTAssertTrue(waitForValue(of: field, equalTo: marker, timeout: 5), "Edit message did not restore the composer")
        XCTAssertTrue(waitForNonExistence(of: app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch, timeout: 5), "Edited message bubble remained visible")
    }

    func testQuickSendsKeepPendingOrder() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "optimistic-order")
            attach(named: "optimistic-order")
            app.terminate()
        }
        openSession(id: "session-long-session", in: app)
        let field = composerField(in: app)
        let first = "optimistic-order-first-\(UUID().uuidString)"
        let second = "optimistic-order-second-\(UUID().uuidString)"
        field.tap()
        field.typeText(first)
        app.buttons["composer-send"].tap()
        XCTAssertTrue(waitForValue(of: field, equalTo: "", timeout: 2), "First quick send did not clear the composer")
        field.tap()
        field.typeText(second)
        app.buttons["composer-send"].tap()

        let firstPending = app.descendants(matching: .any)
            .matching(identifier: "pending-prompt")
            .matching(NSPredicate(format: "label BEGINSWITH %@", first))
            .firstMatch
        let secondPending = app.descendants(matching: .any)
            .matching(identifier: "pending-prompt")
            .matching(NSPredicate(format: "label BEGINSWITH %@", second))
            .firstMatch
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if firstPending.exists && secondPending.exists {
                XCTAssertLessThanOrEqual(firstPending.frame.minY, secondPending.frame.minY, "First pending bubble moved behind the second")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Two quick sends did not leave two ordered pending bubbles")
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
        XCTAssertTrue(field.waitForPlaceholder("Queue for after this turn…", timeout: 45), "Dune fixture session did not become working")

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
            field.waitForPlaceholder("Queue for after this turn…", timeout: 45),
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
        XCTAssertTrue(waitForPendingStatus("Queued", message: marker, in: app, timeout: 10), "Queued caption did not render")

        try await Task.sleep(for: .milliseconds(100))
        let earlyComposerHeight = composer.frame.height
        attach(named: "composer-queued-0.1s")
        try await Task.sleep(for: .milliseconds(1400))
        let settledComposerHeight = composer.frame.height
        attach(named: "composer-queued-1.5s")
        print("composer queue timing glassUnfocused=\(unfocusedComposerHeight) glassFocused=\(focusedComposerHeight) glassAt0.1=\(earlyComposerHeight) glassAt1.5=\(settledComposerHeight)")
        XCTAssertLessThanOrEqual(abs(earlyComposerHeight - unfocusedComposerHeight), 2, "Composer glass grew during queue reset: unfocused \(unfocusedComposerHeight), at 0.1s \(earlyComposerHeight)")
        XCTAssertLessThanOrEqual(abs(settledComposerHeight - unfocusedComposerHeight), 2, "Composer glass did not settle: unfocused \(unfocusedComposerHeight), at 1.5s \(settledComposerHeight)")

        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 15), "Queued marker did not render")
        let queuedStatus = pendingPrompt(in: app, status: "Queued", message: marker)
        XCTAssertTrue(waitForNonExistence(of: queuedStatus, timeout: 10), "Queued caption did not clear after tail delivery")
        let resetField = composerField(in: app)
        XCTAssertTrue(resetField.waitForExistence(timeout: 10), "Composer did not remain visible after queue")
        XCTAssertTrue(waitForValue(of: resetField, equalTo: "", timeout: 10), "Composer text did not clear after queue")
        let resetHeight = resetField.frame.height
        XCTAssertLessThanOrEqual(abs(resetHeight - initialHeight), 2, "Composer did not reset height while queueing: initial \(initialHeight), reset \(resetHeight)")
        let resetComposerHeight = composer.frame.height
        print("composer queue heights fieldInitial=\(initialHeight) fieldReset=\(resetHeight) glassUnfocused=\(unfocusedComposerHeight) glassReset=\(resetComposerHeight)")
        XCTAssertLessThanOrEqual(abs(resetComposerHeight - unfocusedComposerHeight), 2, "Composer glass did not reset height while queueing: unfocused \(unfocusedComposerHeight), reset \(resetComposerHeight)")
        let contextSubtitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "ctx 6%")).firstMatch
        XCTAssertTrue(contextSubtitle.waitForExistence(timeout: 10), "Navigation subtitle did not show ctx 6%")
    }

    func testQueuedMessageActionsDismissAndPersistAcrossRelaunch() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "queued-actions")
            app.terminate()
        }

        openSession(id: "session-dune-part-three-imax-tickets", in: app)
        let field = composerField(in: app)
        XCTAssertTrue(field.waitForPlaceholder("Queue for after this turn…", timeout: 45), "Dune fixture session did not become working")
        let marker = "queued-actions-\(UUID().uuidString)"
        field.tap()
        field.typeText(marker)
        app.buttons["composer-queue"].tap()

        XCTAssertTrue(waitForPendingStatus("Queued", message: marker, in: app, timeout: 10), "Queued message did not render")
        let pending = app.descendants(matching: .any).matching(identifier: "pending-prompt").matching(NSPredicate(format: "label BEGINSWITH %@", marker)).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5), "Queued message bubble was not found")
        pending.tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5), "Queued message menu did not offer Copy")
        XCTAssertTrue(app.buttons["Edit message"].exists, "Queued message menu did not offer Edit message")
        XCTAssertTrue(app.buttons["Dismiss"].exists, "Queued message menu did not offer Dismiss")
        attach(named: "queued-actions-menu")
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(waitForNonExistence(of: pending, timeout: 5), "Dismissed queued message bubble remained visible")

        let longPressMarker = "queued-actions-long-press-\(UUID().uuidString)"
        field.tap()
        field.typeText(longPressMarker)
        app.buttons["composer-queue"].tap()
        XCTAssertTrue(waitForPendingStatus("Queued", message: longPressMarker, in: app, timeout: 10), "Long-press queued message did not render")
        let longPressPending = app.descendants(matching: .any).matching(identifier: "pending-prompt").matching(NSPredicate(format: "label BEGINSWITH %@", longPressMarker)).firstMatch
        XCTAssertTrue(longPressPending.waitForExistence(timeout: 5), "Long-press queued message bubble was not found")
        longPressPending.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Dismiss"].waitForExistence(timeout: 5), "Long-press queued message menu did not offer Dismiss")
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(waitForNonExistence(of: longPressPending, timeout: 5), "Long-press dismissed queued message bubble remained visible")
        attach(named: "queued-actions-dismissed")

        app.terminate()
        app.launch()
        openSession(id: "session-dune-part-three-imax-tickets", in: app)
        let relaunchedPending = app.descendants(matching: .any).matching(identifier: "pending-prompt").matching(NSPredicate(format: "label BEGINSWITH %@", marker)).firstMatch
        XCTAssertFalse(relaunchedPending.waitForExistence(timeout: 5), "Dismissed queued message returned after relaunch")
        let relaunchedLongPressPending = app.descendants(matching: .any).matching(identifier: "pending-prompt").matching(NSPredicate(format: "label BEGINSWITH %@", longPressMarker)).firstMatch
        XCTAssertFalse(relaunchedLongPressPending.waitForExistence(timeout: 5), "Long-press dismissed queued message returned after relaunch")
        attach(named: "queued-actions-relaunch")
    }

    func testBatchedQuickSendsReconcileBothPendingBubbles() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "batched-reconciliation")
            attach(named: "batched-reconciliation")
            app.terminate()
        }

        openSession(id: "session-dune-part-three-imax-tickets", in: app)
        let field = composerField(in: app)
        XCTAssertTrue(field.waitForPlaceholder("Queue for after this turn…", timeout: 45), "Dune fixture session did not become working")
        try await postFixture("/fixture/batch-next-prompts")
        let first = "batched-first-\(UUID().uuidString)"
        let second = "batched-second-\(UUID().uuidString)"
        field.tap()
        field.typeText(first)
        app.buttons["composer-queue"].tap()
        XCTAssertTrue(waitForValue(of: field, equalTo: "", timeout: 5), "First batched send did not clear the composer")
        field.tap()
        field.typeText(second)
        app.buttons["composer-queue"].tap()

        XCTAssertTrue(waitForPendingStatus("Queued", message: first, in: app, timeout: 10), "First batched message did not render")
        XCTAssertTrue(waitForPendingStatus("Queued", message: second, in: app, timeout: 10), "Second batched message did not render")
        let firstPending = app.descendants(matching: .any).matching(identifier: "pending-prompt").matching(NSPredicate(format: "label BEGINSWITH %@", first)).firstMatch
        let secondPending = app.descendants(matching: .any).matching(identifier: "pending-prompt").matching(NSPredicate(format: "label BEGINSWITH %@", second)).firstMatch
        XCTAssertTrue(waitForNonExistence(of: firstPending, timeout: 15), "First batched message did not reconcile")
        XCTAssertTrue(waitForNonExistence(of: secondPending, timeout: 15), "Second batched message did not reconcile")
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
        XCTAssertTrue(waitForStableFrame(compact), "/compact suggestion frame did not stabilize before tap")

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

    func testRejectedSendKeepsMessageAndTypingDuringSendSurvives() async throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "composer-rejected-and-typing-during-send")
            attach(named: "composer-rejected-and-typing-during-send")
            app.terminate()
        }

        try await postFixture("/fixture/clear-approvals")
        openSession(id: "session-staff-account-exclusions", in: app)
        let field = composerField(in: app)
        let marker = "rejected-send-\(UUID().uuidString)"
        field.tap()
        field.typeText(marker)
        try await postFixture("/fixture/reject-next-send")
        app.buttons["composer-send"].tap()

        XCTAssertTrue(waitForPendingStatus("Not sent · Tap to retry", message: marker, in: app, timeout: 10), "Rejected send did not keep the message as Not sent")
        let failedMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
        XCTAssertTrue(failedMessage.waitForExistence(timeout: 5), "Rejected message text is not visible")
        XCTAssertTrue(waitForValue(of: field, equalTo: "", timeout: 3), "Composer kept the rejected text instead of moving it to the bubble")
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1), "Rejected send also showed an alert")

        try await setMessageBehaviour(delayMs: 8_000)
        let heldMarker = "held-send-\(UUID().uuidString)"
        field.tap()
        field.typeText(heldMarker)
        app.buttons["composer-send"].tap()
        XCTAssertTrue(waitForValue(of: field, equalTo: "", timeout: 3), "Held send did not clear the composer")
        field.tap()
        field.typeText("while sending")
        XCTAssertTrue(waitForValue(of: field, equalTo: "while sending", timeout: 3), "Text typed during send did not appear")
        XCTAssertTrue(waitForPendingStatus("Sent", message: heldMarker, in: app, timeout: 15), "Held send did not reconcile to Sent")
        XCTAssertTrue(waitForValue(of: field, equalTo: "while sending", timeout: 3), "Text typed during send was wiped when the send succeeded")
    }

    private func setMessageBehaviour(delayMs: Int? = nil, failNext: Bool? = nil, status: Int? = nil) async throws {
        var body: [String: Any] = [:]
        if let delayMs { body["delayMs"] = delayMs }
        if let failNext { body["failNext"] = failNext }
        if let status { body["status"] = status }
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)/fixture/message-behaviour") else { throw XCTSkip("Fixture control URL was invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ComposerFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "fixture request failed"])
        }
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
            let search = openSessionSearch(in: app)
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

    private func pendingPrompt(in app: XCUIApplication, status: String? = nil, message: String? = nil) -> XCUIElement {
        var predicates: [NSPredicate] = []
        if let status {
            predicates.append(NSPredicate(format: "value == %@", status))
        }
        if let message {
            predicates.append(NSPredicate(format: "label BEGINSWITH %@", message))
        }
        let prompts = app.descendants(matching: .any).matching(identifier: "pending-prompt")
        guard !predicates.isEmpty else { return prompts.firstMatch }
        return prompts
            .matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
            .firstMatch
    }

    private func waitForPendingStatus(_ text: String, message: String? = nil, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let pending = pendingPrompt(in: app, status: text, message: message)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if pending.exists, pending.value as? String == text {
                for legacyStatus in ["Queued", "Sending…", "Sent"] {
                    XCTAssertFalse(app.staticTexts[legacyStatus].exists, "Legacy pending status label \(legacyStatus) was visible")
                }
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func waitForNoButtons(_ labels: [String], in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let buttons = labels.map { app.buttons[$0] }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if buttons.contains(where: \.exists) { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return true
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
private func waitForKeyboardDismissal(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if app.keyboards.count == 0 { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
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
