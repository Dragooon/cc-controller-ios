import Foundation
import XCTest

@MainActor
final class LiveTurnCaptureFlowTests: XCTestCase {
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
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15), "Session search button did not load")
        searchButton.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Session search field did not load")
        search.typeText("Dune Part Three")
        let session = app.buttons["session-dune-part-three-imax-tickets"]
        XCTAssertTrue(session.waitForExistence(timeout: 30), "Dune session row did not load")
        session.tap()

        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "Composer did not load")
        let prompt = "Find an IMAX screening for Dune Part Three tonight."
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["composer-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Send button did not load")
        let sentAt = Date()
        send.tap()

        try await waitUntil(sentAt, hasElapsed: 0.2)
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
        capture("c", moment: "first-assistant", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 3.2)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Bash, Running'")).firstMatch.exists, "First Bash did not show as running")
        capture("d", moment: "first-bash-running", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 6.2)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Bash, Done'")).firstMatch.exists, "First Bash did not show as done")
        capture("e", moment: "first-bash-done", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 7.2)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Read, Running'")).firstMatch.exists, "Read did not show as running")
        capture("f", moment: "read-running", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 11.2)
        XCTAssertGreaterThanOrEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Bash, Done'")).count, 2, "Second Bash did not show as done")
        capture("g", moment: "second-bash-done", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 12.2)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "8:00 PM screening has the best remaining seats")).firstMatch.exists, "Final assistant text did not load")
        capture("h", moment: "final-text", sentAt: sentAt, in: app, scheme: scheme)

        try await waitUntil(turnStart, hasElapsed: 13.3)
        XCTAssertFalse(app.buttons["composer-stop"].exists, "Stop button remained after Stop hook")
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
        let footer = rows.first { $0.contains("✻") && !$0.hasPrefix("✻ Worked for") } ?? "absent"
        let line = "CAPTURE \(scheme)-\(letter)-\(moment) elapsed=\(String(format: "%.3f", elapsed)) rows=[\(rows.joined(separator: " | "))] footer=\(footer)"
        observations.append(line)
        print(line)
    }

    private func visibleTranscriptLabels(in app: XCUIApplication) -> [String] {
        guard app.scrollViews["transcript-scroll"].exists else { return [] }
        let textLabels = [
            "Find three good seats for Dune Part Three IMAX.",
            "I found a short list of IMAX sessions and left the final choice to you.",
            "Find an IMAX screening for Dune Part Three tonight.",
            "Let me check the showtimes.",
            "The 8:00 PM screening has the best remaining seats.",
            "I can keep looking if you want a different time.",
        ]
        var labels: [String] = []
        let textPredicate = NSPredicate(format: "label IN %@", textLabels)
        let textMatches = app.staticTexts.matching(textPredicate)
        for index in 0..<textMatches.count {
            let label = textMatches.element(boundBy: index).label
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        let toolPredicate = NSPredicate(format: "label BEGINSWITH[c] 'Bash,' OR label BEGINSWITH[c] 'Read,' OR label BEGINSWITH[c] 'Ran '")
        let toolMatches = app.buttons.matching(toolPredicate)
        for index in 0..<toolMatches.count {
            let label = toolMatches.element(boundBy: index).label
            if !label.isEmpty, !labels.contains(label) { labels.append(label) }
        }
        let worked = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] '✻ Worked for'")).firstMatch
        if worked.exists, !labels.contains(worked.label) { labels.append(worked.label) }
        return labels
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

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        if let scheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !scheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", scheme]
        }
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
