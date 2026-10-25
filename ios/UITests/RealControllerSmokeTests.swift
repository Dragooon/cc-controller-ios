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
        let reveal: String
        let firstRowMilliseconds: Int?
        let phases: String
        let responseBytes: String
        let visibleRows: Int
        let barState: String
        let pinned: Bool
        let nonEmpty: Bool
        let warning: String?
    }

    private struct PerformanceSnapshot {
        let phases: String
        let responseBytes: String
    }

    private let phaseNames = [
        "request_sent",
        "response_received",
        "decode_done",
        "merge_done",
        "grouping_done",
        "first_rows",
        "usage_update",
    ]

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
        let reveal = revealSessionRow(sessionRow, in: app)
        guard reveal.reachable else {
            return PassResult(
                pass: pass,
                session: session,
                result: "FAIL",
                reveal: reveal.path,
                firstRowMilliseconds: nil,
                phases: "none",
                responseBytes: "none",
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
        var phases = "none"
        var responseBytes = "none"
        var visibleRows = 0
        var nonEmpty = false
        var pinned = false

        while Date() < deadline {
            if let probe = probeRows(in: scroll) {
                let probedAt = Int(Date().timeIntervalSince(tapStarted) * 1000)
                visibleRows = probe.rows
                if firstRowMilliseconds == nil, probe.rows > 0 {
                    firstRowMilliseconds = probedAt
                }
                nonEmpty = nonEmpty || probe.nonEmpty
                if let lowest = probe.lowestMaxY, bottomStack.exists {
                    pinned = abs(lowest - bottomStack.frame.minY) <= 160
                }
            }
            if firstRowMilliseconds != nil && nonEmpty && pinned { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if let firstRow = firstRowMilliseconds, firstRow > 10_000 {
            firstRowMilliseconds = nil
        }
        let performance = app.staticTexts["transcript-performance"]
        if performance.waitForExistence(timeout: 1) {
            let snapshot = performanceSnapshot(from: performance.label)
            phases = snapshot.phases
            responseBytes = snapshot.responseBytes
        }

        let subtitle = app.descendants(matching: .any).matching(identifier: "selected-session-subtitle").firstMatch
        let subtitleText = subtitle.exists ? subtitle.label : ""
        let hasActivityIndicator = subtitle.exists && (subtitleText.hasPrefix("working") || subtitleText.hasPrefix("background"))
        let barState = hasActivityIndicator ? "present" : "absent"
        var warning: String?
        if session.state == "working" && barState == "absent" {
            warning = "working-indicator-absent"
        } else if session.state != "working" && barState == "present" && !subtitleText.hasPrefix("background") {
            warning = "session-state-changed-to-working"
        }
        let passed = titleLoaded && firstRowMilliseconds != nil && nonEmpty && pinned
        return PassResult(
            pass: pass,
            session: session,
            result: passed ? "PASS" : "FAIL",
            reveal: reveal.path,
            firstRowMilliseconds: firstRowMilliseconds,
            phases: phases,
            responseBytes: responseBytes,
            visibleRows: visibleRows,
            barState: barState,
            pinned: pinned,
            nonEmpty: nonEmpty,
            warning: warning
        )
    }

    private struct RowProbe {
        let rows: Int
        let lowestMaxY: CGFloat?
        let nonEmpty: Bool
    }

    // One snapshot is a single round trip; per-element exists/isHittable queries cost seconds on a full transcript and hid the app's real first-row time.
    private func probeRows(in scroll: XCUIElement) -> RowProbe? {
        guard scroll.exists, let tree = try? scroll.snapshot() else { return nil }
        let viewport = tree.frame
        var rows = 0
        var lowestMaxY: CGFloat?
        var nonEmpty = false
        var pending = tree.children
        while let node = pending.popLast() {
            pending.append(contentsOf: node.children)
            guard viewport.contains(CGPoint(x: node.frame.midX, y: node.frame.midY)), isTranscriptRow(node) else { continue }
            rows += 1
            lowestMaxY = max(lowestMaxY ?? node.frame.maxY, node.frame.maxY)
            nonEmpty = nonEmpty || isNonEmptyPromptOrText(node)
        }
        return RowProbe(rows: rows, lowestMaxY: lowestMaxY, nonEmpty: nonEmpty)
    }

    private func isTranscriptRow(_ node: XCUIElementSnapshot) -> Bool {
        let identifier = node.identifier
        if identifier == "prompt-bubble" || identifier == "pending-prompt-bubble" { return true }
        if identifier.hasPrefix("subagent-card-") || identifier.hasPrefix("subagent-result-row-") { return true }
        guard node.elementType == .button || node.elementType == .staticText else { return false }
        return hasLabel(node)
    }

    private func isNonEmptyPromptOrText(_ node: XCUIElementSnapshot) -> Bool {
        let isPrompt = node.identifier == "prompt-bubble" || node.identifier == "pending-prompt-bubble"
        return (isPrompt || node.elementType == .staticText) && hasLabel(node)
    }

    private func hasLabel(_ node: XCUIElementSnapshot) -> Bool {
        !node.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func performanceSnapshot(from label: String) -> PerformanceSnapshot {
        var fields: [String: String] = [:]
        for token in label.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1]
        }
        let phases = phaseNames
            .map { "\($0):\(fields[$0] ?? "none")" }
            .joined(separator: ",")
        return PerformanceSnapshot(
            phases: phases,
            responseBytes: fields["response_bytes"] ?? "none"
        )
    }

    private func navigateBackIfNeeded(in app: XCUIApplication) {
        let back = app.navigationBars.buttons["Sessions"]
        guard back.exists && back.isHittable else { return }
        back.tap()
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH[c] 'session-'")).firstMatch.waitForExistence(timeout: 10)
    }

    private struct SessionRowReveal {
        let reachable: Bool
        let path: String
    }

    private func revealSessionRow(_ row: XCUIElement, in app: XCUIApplication) -> SessionRowReveal {
        let list = app.collectionViews.firstMatch
        guard list.waitForExistence(timeout: 30) else {
            return SessionRowReveal(reachable: false, path: "direct")
        }
        let navigationBar = app.navigationBars.firstMatch
        let visibleTop = max(list.frame.minY, navigationBar.exists ? navigationBar.frame.maxY : list.frame.minY)
        let searchButton = app.buttons["Search"]
        let searchFrame = searchButton.frame
        let hasSearchButton = searchButton.exists && !searchFrame.isEmpty
        let bottomControlsTop = hasSearchButton ? searchFrame.minY : app.windows.firstMatch.frame.maxY - 120
        let bottomBoundary = hasSearchButton ? "search-button" : "window-fallback"
        print("real-smoke reveal boundary=\(bottomBoundary) bottom-controls-top=\(bottomControlsTop)")

        struct Probe {
            let exists: Bool
            let hittable: Bool
            let frame: CGRect
        }
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH[c] 'session-'")).firstMatch

        func probeRow() -> Probe {
            let exists = row.exists
            let frame = exists ? row.frame : firstRow.frame
            return Probe(exists: exists, hittable: exists && row.isHittable, frame: frame)
        }

        func frameMoved(from previous: CGRect, to current: CGRect) -> Bool {
            abs(current.minY - previous.minY) >= 0.5
        }

        func isReachable(_ probe: Probe) -> Bool {
            probe.exists
                && probe.hittable
                && probe.frame.minY >= visibleTop
                && probe.frame.maxY <= bottomControlsTop
        }

        func nudgeDirection(for frame: CGRect) -> (upward: Bool, distance: CGFloat)? {
            let bottomOverlap = frame.maxY - bottomControlsTop
            let topOverlap = visibleTop - frame.minY
            if bottomOverlap > 0 {
                return (true, bottomOverlap + 80)
            }
            if topOverlap > 0 {
                return (false, topOverlap + 80)
            }
            return nil
        }

        var usedSwipe = false
        var usedNudge = false
        func path() -> String {
            if usedSwipe && usedNudge { return "swiped+nudged" }
            if usedSwipe { return "swiped" }
            if usedNudge { return "nudged" }
            return "direct"
        }

        func nudgeIfObscured(_ initialProbe: Probe) -> Probe {
            var probe = initialProbe
            guard probe.exists, !isReachable(probe), list.frame.height > 0 else { return probe }
            for nudgeIndex in 1...6 {
                guard let direction = nudgeDirection(for: probe.frame) else { break }
                let frameBefore = probe.frame
                let startY: CGFloat = direction.upward ? 0.75 : 0.25
                let distance = min(direction.distance, list.frame.height * 0.6)
                let offset = distance / list.frame.height
                let endY = direction.upward
                    ? max(0.1, startY - offset)
                    : min(0.9, startY + offset)
                let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
                let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
                start.press(forDuration: 0.05, thenDragTo: end)
                usedNudge = true
                probe = probeRow()
                print("real-smoke reveal session=\(row.identifier) nudge=\(nudgeIndex) frame-before=\(frameBefore) frame-after=\(probe.frame)")
                if isReachable(probe) || !frameMoved(from: frameBefore, to: probe.frame) { break }
            }
            return probe
        }

        var probe = nudgeIfObscured(probeRow())
        if isReachable(probe) { return SessionRowReveal(reachable: true, path: path()) }

        var movedUp = false
        for _ in 0..<8 {
            let previousFrame = probe.frame
            list.swipeUp()
            usedSwipe = true
            probe = nudgeIfObscured(probeRow())
            if isReachable(probe) { return SessionRowReveal(reachable: true, path: path()) }
            guard frameMoved(from: previousFrame, to: probe.frame) else { break }
            movedUp = true
        }
        guard movedUp else { return SessionRowReveal(reachable: false, path: path()) }

        for _ in 0..<8 {
            let previousFrame = probe.frame
            list.swipeDown()
            usedSwipe = true
            probe = nudgeIfObscured(probeRow())
            if isReachable(probe) { return SessionRowReveal(reachable: true, path: path()) }
            guard frameMoved(from: previousFrame, to: probe.frame) else { break }
        }
        return SessionRowReveal(reachable: false, path: path())
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
            return "pass=\(result.pass) session_id=\(result.session.id) session_name=\(result.session.name) expected_state=\(result.session.state) entry_count=\(result.session.entryCount) result=\(result.result) reveal=\(result.reveal) first_hittable_row_ms=\(firstRow) visible_rows=\(result.visibleRows) bar=\(result.barState) pinned=\(result.pinned) non_empty=\(result.nonEmpty) warning=\(warning) phases=\(result.phases) response_bytes=\(result.responseBytes)"
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
