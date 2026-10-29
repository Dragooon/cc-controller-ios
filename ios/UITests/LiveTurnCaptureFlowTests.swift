import Foundation
import XCTest

@MainActor
final class LiveTurnCaptureFlowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try await restartFixtureIfConfigured()
    }

    private var observations: [String] = []

    func testCaptureLiveTurn() async throws {
        let app = launchFixture()
        let scheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"] ?? "unspecified"
        defer {
            let report = observations.joined(separator: "\n")
            let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "\(scheme)-rows"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }

        try await postFixture("/fixture/disable-live-event")
        try await postFixtureJSON("/fixture/message-behaviour", body: ["promptDelayMs": 2_000])
        let search = openSessionSearch(in: app)
        search.typeText("Dune Part Three")
        let session = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(session.waitForExistence(timeout: 30), "Dune session row did not load")
        session.tap()

        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "Composer did not load")
        let prompt = "Find a late-night IMAX screening for Moonlight Duo tonight."
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send button did not load")
        send.tap()
        let sentAt = Date()

        let initialRows = visibleTranscriptLabels(in: app)
        XCTAssertTrue(initialRows.contains(prompt), "User message did not appear before the transcript prompt")
        XCTAssertTrue(initialRows.contains { isActivityLabel($0) }, "Activity row did not appear immediately after send")
        XCTAssertFalse(initialRows.contains { $0.contains("↓") }, "Activity row showed output tokens before the live turn had assistant usage")
        let pendingPrompt = app.descendants(matching: .any)
            .matching(identifier: "pending-prompt")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", prompt))
            .firstMatch
        let initialActivity = app.descendants(matching: .any).matching(identifier: "live-activity-row").firstMatch
        XCTAssertTrue(pendingPrompt.exists, "The sent prompt bubble did not render")
        XCTAssertTrue(initialActivity.exists, "The live activity row did not render")
        XCTAssertLessThan(pendingPrompt.frame.maxY, initialActivity.frame.minY, "The activity row rendered above the note that started the turn")
        let activityElapsed = Date().timeIntervalSince(sentAt)
        XCTAssertLessThan(activityElapsed, 1.0, "User message and activity row did not appear within 1 s of send")
        let activityLine = "ACTIVITY_ROW_APPEARED elapsed=\(String(format: "%.3f", activityElapsed))"
        observations.append(activityLine)
        print(activityLine)
        capture("a", moment: "right-after-send", sentAt: sentAt, in: app, scheme: scheme)
        let turnStart = try await postLiveTurn(prompt: prompt)
        let workingButton = app.buttons["composer-queue"]
        XCTAssertTrue(workingButton.waitForExistence(timeout: 3), "Working composer state did not arrive")
        let workingElapsed = Date().timeIntervalSince(sentAt)
        let workingLine = "WORKING_STATE_FLIP elapsed=\(String(format: "%.3f", workingElapsed)) daemon_turn_start_delta=\(String(format: "%.3f", turnStart.timeIntervalSince(sentAt)))"
        observations.append(workingLine)
        print(workingLine)

        try await waitUntil(turnStart, hasElapsed: 1.2)
        capture("b", moment: "before-assistant", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 2.2)
        XCTAssertTrue(app.staticTexts["Let me check the showtimes."].exists, "First assistant text did not load")
        let firstAssistantActivity = app.descendants(matching: .any).matching(identifier: "live-activity-row").firstMatch
        XCTAssertTrue(firstAssistantActivity.label.contains("↓ 7"), "Activity row did not show the current turn's output tokens")
        XCTAssertFalse(firstAssistantActivity.label.contains("↓ 1.2k"), "Activity row showed the session total instead of current-turn tokens")
        capture("c", moment: "first-assistant", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 3.2)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'Running List IMAX sessions'")).firstMatch.exists, "First Bash did not show as running")
        capture("d", moment: "first-bash-running", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 6.2)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'Ran List IMAX sessions'")).firstMatch.exists, "First Bash did not show as done")
        capture("e", moment: "first-bash-done", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 7.2)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'Reading dune-showtimes.md'")).firstMatch.exists, "Read did not show as running")
        capture("f", moment: "read-running", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 10.2)
        let runningSummary = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'Running 4 tools…'")).firstMatch
        XCTAssertTrue(runningSummary.exists, "Four-tool run did not collapse to a running summary")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'Running Verify seat map…'")).firstMatch.exists, "Collapsed run did not retain the running tool row")
        capture("g", moment: "four-tool-running-collapsed", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 12.0)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'Ran 4 tools'")).firstMatch.exists, "Four-tool run did not show its collapsed done summary")

        try await waitUntil(turnStart, hasElapsed: 12.2)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "8:00 PM screening has the best remaining seats")).firstMatch.exists, "Final assistant text did not load")
        let finalAssistantActivity = app.descendants(matching: .any).matching(identifier: "live-activity-row").firstMatch
        XCTAssertTrue(finalAssistantActivity.label.contains("↓ 23"), "Activity row did not include usage from the tool-only assistant record")
        capture("h", moment: "final-text", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 13.3)
        XCTAssertFalse(app.buttons["composer-stop"].exists, "Stop button remained after Stop hook")
        let stoppedRows = visibleTranscriptLabels(in: app)
        XCTAssertFalse(stoppedRows.contains { isActivityLabel($0) }, "Activity row remained after turn stopped")
        let finalPromptMatches = app.staticTexts.matching(NSPredicate(format: "label == %@", prompt))
        XCTAssertEqual(finalPromptMatches.count, 1, "The sent prompt appeared more than once in the final transcript")
        assertRowsAppearInOrder(
            [
                prompt,
                "Let me check the showtimes.",
                "Ran 4 tools",
                "The 8:00 PM screening has the best remaining seats.",
            ],
            in: app
        )
        capture("i", moment: "stopped", sentAt: sentAt, in: app, scheme: scheme)
    }

    private func capture(
        _ letter: String,
        moment: String,
        sentAt: Date,
        in app: XCUIApplication,
        scheme: String
    ) {
        let elapsed = Date().timeIntervalSince(sentAt)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(scheme)-\(letter)-\(moment).png"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let rows = visibleTranscriptLabels(in: app)
        let footer = rows.first { isActivityLabel($0) && !$0.hasPrefix("✻ Worked for") } ?? "absent"
        let line = "CAPTURE \(scheme)-\(letter)-\(moment) elapsed=\(String(format: "%.3f", elapsed)) rows=[\(rows.joined(separator: " | "))] footer=\(footer)"
        observations.append(line)
        print(line)
    }

    private func visibleTranscriptLabels(in app: XCUIApplication) -> [String] {
        guard transcriptScroll(in: app).exists else { return [] }
        let textLabels: Set<String> = [
            "Find three good seats for Dune Part Three IMAX.",
            "I found a short list of IMAX sessions and left the final choice to you.",
            "Find an IMAX screening for Dune Part Three tonight.",
            "Find a late-night IMAX screening for Moonlight Duo tonight.",
            "Let me check the showtimes.",
            "The 8:00 PM screening has the best remaining seats.",
            "I can keep looking if you want a different time.",
        ]
        var labels: [String] = []
        let textMatches = app.staticTexts.matching(NSPredicate(format: "label IN %@", Array(textLabels)))
        for index in 0..<textMatches.count {
            let label = textMatches.element(boundBy: index).label
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        let toolPredicate = NSPredicate(format: "label BEGINSWITH[c] 'Running ' OR label BEGINSWITH[c] 'Reading ' OR label BEGINSWITH[c] 'Read ' OR label BEGINSWITH[c] 'Ran ' OR label BEGINSWITH[c] 'Writing ' OR label BEGINSWITH[c] 'Wrote ' OR label BEGINSWITH[c] 'Editing ' OR label BEGINSWITH[c] 'Edited '")
        let toolMatches = app.descendants(matching: .any).matching(toolPredicate)
        for index in 0..<toolMatches.count {
            let label = toolMatches.element(boundBy: index).label
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        let activityMatches = app.descendants(matching: .any).matching(activityLabelPredicate)
        for index in 0..<activityMatches.count {
            let label = activityMatches.element(boundBy: index).label
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        let worked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] '✻ Worked for'")).firstMatch
        if worked.exists, !labels.contains(worked.label) { labels.append(worked.label) }
        return labels
    }

    private let activityLabelPattern = #"^(?:Waiting for you(?:…)?|\p{Lu}[\p{L}'’-]*…)(?:, .*)?$"#

    private func isActivityLabel(_ label: String) -> Bool {
        label.range(of: activityLabelPattern, options: .regularExpression) != nil
    }

    private var activityLabelPredicate: NSPredicate {
        NSPredicate(format: "label MATCHES %@", activityLabelPattern)
    }

    private func assertRowsAppearInOrder(_ expected: [String], in app: XCUIApplication) {
        var previousY: CGFloat = -.greatestFiniteMagnitude
        for expectedRow in expected {
            let match = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", expectedRow)).firstMatch
            guard match.exists else {
                XCTFail("Missing transcript row \(expectedRow)")
                return
            }
            let y = match.frame.minY
            XCTAssertGreaterThanOrEqual(y, previousY, "Transcript row \(expectedRow) was out of order")
            previousY = y
        }
    }

    private func waitUntil(_ start: Date, hasElapsed seconds: TimeInterval) async throws {
        let remaining = seconds - Date().timeIntervalSince(start)
        if remaining > 0 {
            try await Task.sleep(for: .milliseconds(Int((remaining * 1000).rounded())))
        }
    }

    private func postLiveTurn(prompt: String) async throws -> Date {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)/fixture/live-turn") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "no response body"
            throw NSError(domain: "FixtureFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Live turn control failed: \(body)"])
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let startedAt = try XCTUnwrap(payload["startedAt"] as? String)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: startedAt))
    }

    private func postFixture(_ path: String) async throws {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)\(path)") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "no response body"
            throw NSError(domain: "FixtureFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture control route failed for \(path): \(body)"])
        }
    }

    private func postFixtureJSON(_ path: String, body: [String: Any]) async throws {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)\(path)") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "no response body"
            throw NSError(domain: "FixtureFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture control route failed for \(path): \(responseBody)"])
        }
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        if let scheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !scheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", scheme]
        }
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
