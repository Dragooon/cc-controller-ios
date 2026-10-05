import XCTest

@MainActor
final class RealControllerSmokeTests: XCTestCase {
    // This test is read-only: it may tap session rows, the Sessions back button, and scroll gestures only.
    private struct SelectedSession: Decodable {
        let id: String
        let name: String
        let state: String
        let entryCount: Int
    }

    private struct PassResult {
        let pass: String
        let session: SelectedSession
        let result: String
        let firstRowMilliseconds: Int?
        let visibleRows: Int
        let barState: String
        let pinned: Bool
        let nonEmpty: Bool
        let warning: String?
    }

    func testRealSessions() throws {
        guard ProcessInfo.processInfo.environment["TEST_RUNNER_REAL_SMOKE"] == "1" else {
            throw XCTSkip("Real controller smoke is opt-in")
        }
        let sessions = try selectedSessions()
        let app = XCUIApplication()
        configure(app: app, resetCache: true)
        app.launch()
        var results = runPass("cold", app: app, sessions: sessions)
        app.terminate()

        configure(app: app, resetCache: false)
        app.launch()
        results += runPass("warm", app: app, sessions: sessions)
        app.terminate()

        writeSummary(results)
        let failures = results.filter { $0.result == "FAIL" }.count
        if failures > 0 {
            XCTFail("Real controller smoke had \(failures) failed session checks")
        }
    }

    private func selectedSessions() throws -> [SelectedSession] {
        let value = requiredRunnerVariable("TEST_RUNNER_REAL_SESSIONS")
        guard let data = value.data(using: .utf8) else {
            throw XCTSkip("Selected session data was not UTF-8")
        }
        do {
            let sessions = try JSONDecoder().decode([SelectedSession].self, from: data)
            guard !sessions.isEmpty else { throw NSError(domain: "RealSmoke", code: 1) }
            return sessions
        } catch {
            throw XCTSkip("Selected session data was invalid")
        }
    }

    private func configure(app: XCUIApplication, resetCache: Bool) {
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        if resetCache {
            app.launchArguments.append("-CCResetCache")
        }
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        dismissLeftoverNotificationPrompt()
    }

    private func runPass(_ pass: String, app: XCUIApplication, sessions: [SelectedSession]) -> [PassResult] {
        sessions.map { session in
            let result = checkSession(session, pass: pass, app: app)
            attachScreenshot(named: "real-smoke-\(pass)-\(safeAttachmentPart(session.id))")
            navigateBackIfNeeded(in: app)
            return result
        }
    }

    private func checkSession(_ session: SelectedSession, pass: String, app: XCUIApplication) -> PassResult {
        let sessionRow = app.buttons["session-\(session.id)"]
        guard waitForHittable(sessionRow, timeout: 30) else {
            return PassResult(
                pass: pass,
                session: session,
                result: "FAIL",
                firstRowMilliseconds: nil,
                visibleRows: 0,
                barState: "not-checked",
                pinned: false,
                nonEmpty: false,
                warning: "session-row-not-hittable"
            )
        }
        let tapStarted = Date()
        sessionRow.tap()
        let title = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        let titleLoaded = title.waitForExistence(timeout: 10)
        let scroll = app.scrollViews["transcript-scroll"]
        let bottomStack = app.descendants(matching: .any).matching(identifier: "bottom-stack").firstMatch
        let deadline = tapStarted.addingTimeInterval(10)
        var firstRowMilliseconds: Int?
        var visibleRows: [XCUIElement] = []
        var nonEmpty = false
        var pinned = false

        while Date() < deadline {
            if scroll.exists {
                visibleRows = transcriptRows(in: scroll)
                if firstRowMilliseconds == nil, !visibleRows.isEmpty {
                    firstRowMilliseconds = Int(Date().timeIntervalSince(tapStarted) * 1000)
                }
                nonEmpty = nonEmpty || hasNonEmptyPromptOrAssistant(in: scroll)
                if let lowest = visibleRows.last, bottomStack.exists {
                    pinned = abs(lowest.frame.maxY - bottomStack.frame.minY) <= 160
                }
            }
            if firstRowMilliseconds != nil && nonEmpty && pinned { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let bar = app.descendants(matching: .any).matching(identifier: "working-bar").firstMatch
        let barState = bar.exists && bar.isHittable ? "present" : "absent"
        var warning: String?
        if session.state == "working" && barState == "absent" {
            warning = "working-state-bar-absent"
        } else if session.state != "working" && barState == "present" {
            warning = "session-state-changed-to-working"
        }
        let passed = titleLoaded && firstRowMilliseconds != nil && nonEmpty && pinned
        return PassResult(
            pass: pass,
            session: session,
            result: passed ? "PASS" : "FAIL",
            firstRowMilliseconds: firstRowMilliseconds,
            visibleRows: visibleRows.count,
            barState: barState,
            pinned: pinned,
            nonEmpty: nonEmpty,
            warning: warning
        )
    }

    private func transcriptRows(in scroll: XCUIElement) -> [XCUIElement] {
        scroll.descendants(matching: .any).allElementsBoundByIndex.filter { element in
            guard element.exists && element.isHittable else { return false }
            let frame = element.frame
            guard frame.intersects(scroll.frame), scroll.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
            let identifier = element.identifier
            if identifier == "prompt-bubble" || identifier == "pending-prompt-bubble" { return true }
            if identifier.hasPrefix("subagent-card-") || identifier.hasPrefix("subagent-result-row-") { return true }
            if element.elementType == .button && !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            return element.elementType == .staticText && !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func hasNonEmptyPromptOrAssistant(in scroll: XCUIElement) -> Bool {
        let promptIdentifiers = ["prompt-bubble", "pending-prompt-bubble"]
        if promptIdentifiers.contains(where: { identifier in
            let element = scroll.descendants(matching: .any).matching(identifier: identifier).firstMatch
            return element.exists && element.isHittable && !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return true
        }
        return scroll.staticTexts.allElementsBoundByIndex.contains {
            $0.exists && $0.isHittable && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func navigateBackIfNeeded(in app: XCUIApplication) {
        let back = app.navigationBars.buttons["Sessions"]
        guard back.exists && back.isHittable else { return }
        back.tap()
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH[c] 'session-'")).firstMatch.waitForExistence(timeout: 10)
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func attachScreenshot(named name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func writeSummary(_ results: [PassResult]) {
        let lines = results.map { result in
            let firstRow = result.firstRowMilliseconds.map(String.init) ?? "none"
            let warning = result.warning ?? "none"
            return "pass=\(result.pass) session_id=\(result.session.id) session_name=\(result.session.name) expected_state=\(result.session.state) entry_count=\(result.session.entryCount) result=\(result.result) first_hittable_row_ms=\(firstRow) visible_rows=\(result.visibleRows) bar=\(result.barState) pinned=\(result.pinned) non_empty=\(result.nonEmpty) warning=\(warning)"
        }
        let summary = lines.joined(separator: "\n") + "\n"
        print(summary, terminator: "")
        guard let outputDirectory = ProcessInfo.processInfo.environment["TEST_RUNNER_REAL_SMOKE_OUTPUT_DIR"], !outputDirectory.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
            try summary.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Could not write real-smoke summary")
        }
    }

    private func safeAttachmentPart(_ value: String) -> String {
        value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
            .reduce(into: "", { $0.append($1) })
    }
}
