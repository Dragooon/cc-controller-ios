import XCTest

@MainActor
final class InspectorFlowTests: XCTestCase {
    private var auditLines: [String] = []

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testSubagentPush() throws {
        let app = launch()
        openStaffSession(app)

        let engineer = app.buttons["subagent-card-agent-done"]
        let scrollView = transcriptScroll(in: app)
        XCTAssertTrue(scrollView.waitForExistence(timeout: 15), "Transcript did not load")
        let bottomStack = app.descendants(matching: .any)["bottom-stack"]
        XCTAssertTrue(bottomStack.waitForExistence(timeout: 15), "Bottom stack did not load")
        let staffDeny = app.buttons["Deny"]
        XCTAssertTrue(staffDeny.waitForExistence(timeout: 15), "Staff approval deny button did not load")
        staffDeny.tap()
        let marker = "typed-nav-marker"
        let composer = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "Composer did not load")
        composer.tap()
        composer.typeText("typed-nav-marker")
        XCTAssertEqual(composer.value as? String, marker)
        XCTAssertTrue(
            reveal(engineer, in: scrollView, above: bottomStack),
            "Engineer subagent card did not load above the bottom stack"
        )
        XCTAssertLessThanOrEqual(
            engineer.frame.maxY,
            bottomStack.frame.minY,
            "Engineer subagent card overlaps the bottom stack"
        )
        engineer.tap()

        let subagentNavigationBar = app.navigationBars["engineer"]
        XCTAssertTrue(subagentNavigationBar.waitForExistence(timeout: 15), "Subagent screen did not load")
        XCTAssertTrue(subagentNavigationBar.buttons.element(boundBy: 0).exists, "Subagent back button did not load")
        attach(named: "subagent-pushed")
        audit(app: app, name: "subagent-pushed")

        subagentNavigationBar.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Staff Account Exclusions Atlas Monitoring"].waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.buttons["subagent-card-agent-done"].waitForExistence(timeout: 15),
            "Engineer subagent card was not retained after returning"
        )
        XCTAssertTrue(
            (composer.value as? String)?.contains(marker) == true,
            "Composer lost typed marker after returning from subagent"
        )
        if app.keyboards.firstMatch.exists {
            app.keyboards.firstMatch.swipeDown()
        }
        attach(named: "after-back")
    }

    func testInspectorSubagentPush() throws {
        let app = launch()
        openStaffSession(app)

        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 15), "Session info button did not load")
        info.tap()

        XCTAssertTrue(app.staticTexts["Status"].waitForExistence(timeout: 15), "Inspector Status section did not load")
        app.swipeUp()
        let engineer = app.buttons["inspector-subagent-agent-done"]
        XCTAssertTrue(engineer.waitForExistence(timeout: 15), "Inspector engineer row did not load")
        XCTAssertTrue(
            engineer.label.localizedCaseInsensitiveContains("done"),
            "Inspector subagent accessibility label lost its state: \(engineer.label)"
        )
        engineer.tap()

        let subagentNavigationBar = app.navigationBars["engineer"]
        XCTAssertTrue(subagentNavigationBar.waitForExistence(timeout: 15), "Inspector subagent screen did not load")
        XCTAssertFalse(app.navigationBars["Details"].exists, "Inspector sheet remained visible after push")
    }

    func testInspectorSheet() throws {
        let app = launch()
        openStaffSession(app)

        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 15), "Session info button did not load")
        info.tap()

        XCTAssertTrue(app.staticTexts["Status"].waitForExistence(timeout: 15), "Inspector Status section did not load")
        XCTAssertFalse(app.staticTexts["Context"].exists, "Staff session should hide an empty Context section")
        XCTAssertFalse(app.staticTexts["Usage"].exists, "Staff session should hide an empty Usage section")
        let subtitle = app.descendants(matching: .any).matching(identifier: "selected-session-subtitle").firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10), "Session subtitle did not load")
        let subtitleBefore = elementText(subtitle)
        XCTAssertTrue(waitForChange(subtitle, from: subtitleBefore, timeout: 3), "Session subtitle did not tick: \(subtitleBefore) -> \(elementText(subtitle)) / label \(subtitle.label)")
        let elapsed = app.descendants(matching: .any).matching(identifier: "inspector-elapsed").firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), "Elapsed row did not load")
        let elapsedBefore = elementText(elapsed)
        XCTAssertTrue(waitForChange(elapsed, from: elapsedBefore, timeout: 3), "Details elapsed value did not tick")
        attach(named: "session-live-subtitle")
        attach(named: "inspector-details")
        // Exclude dynamic type and clipped-text audits because they stall a presented sheet on iOS 27.0; AccessibilityXL screenshots cover text sizes.
        auditPresentedSheet(app)
        attach(named: "inspector-medium")
        let expandGrabber = app.buttons["Sheet Grabber"]
        if expandGrabber.exists {
            expandGrabber.swipeUp()
        } else {
            app.swipeUp()
        }
        attach(named: "inspector-large")

        let picker = app.buttons["approval-mode-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "Approval mode picker did not load")
        picker.tap()
        let terminal = app.buttons["Terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Terminal mode was not offered")
        XCTAssertTrue(waitForHittable(terminal, timeout: 10), "Terminal mode was not hittable")
        terminal.tap()
        XCTAssertTrue(waitForValue(picker, expected: "Terminal"), "Approval mode did not become Terminal")
        XCTAssertEqual(picker.value as? String, "Terminal")

        picker.tap()
        let auto = app.buttons["Auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 10), "Auto mode was not offered")
        auto.tap()
        XCTAssertTrue(waitForValue(picker, expected: "Auto"), "Approval mode did not become Auto")
        XCTAssertEqual(picker.value as? String, "Auto")
        attach(named: "inspector-auto")

        let sheetGrabber = app.buttons["Sheet Grabber"]
        if sheetGrabber.exists {
            sheetGrabber.swipeDown()
        }
    }

    func testInspectorLongSessionSections() throws {
        let app = launch()
        openSession(id: "session-long-session", in: app)

        let info = app.buttons["session-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 15), "Session info button did not load")
        info.tap()

        XCTAssertTrue(app.staticTexts["Status"].waitForExistence(timeout: 15), "Inspector Status section did not load")
        XCTAssertTrue(app.staticTexts["Context"].waitForExistence(timeout: 15), "Long session Context section did not load")
        XCTAssertTrue(app.staticTexts["Usage"].waitForExistence(timeout: 15), "Long session Usage section did not load")
        XCTAssertTrue(app.staticTexts["6%"].waitForExistence(timeout: 15), "Long session context percentage did not load")
        XCTAssertTrue(app.staticTexts["64k"].waitForExistence(timeout: 15), "Long session input usage did not load")
        XCTAssertTrue(app.staticTexts["1.2k"].waitForExistence(timeout: 15), "Long session output usage did not load")
        XCTAssertTrue(app.staticTexts["97%"].waitForExistence(timeout: 15), "Long session cache usage did not load")
        let context = app.descendants(matching: .any).matching(identifier: "inspector-context").firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 15), "Long session context accessibility element did not load")
        XCTAssertEqual(context.label, "Context, 6 percent, 64k of 1M tokens")
        let responses = app.descendants(matching: .any).matching(identifier: "inspector-responses").firstMatch
        XCTAssertTrue(responses.waitForExistence(timeout: 15), "Long session Responses tile did not load")
        XCTAssertEqual(responses.label, "1 Response")
        XCTAssertFalse(app.staticTexts["Messages"].exists, "Usage tile retained the old Messages label")
        attach(named: "inspector-long-medium")
        auditPresentedSheet(app)

        let expandGrabber = app.buttons["Sheet Grabber"]
        if expandGrabber.exists {
            expandGrabber.swipeUp()
        } else {
            app.swipeUp()
        }
        attach(named: "inspector-long-large")
    }

    private func launch() -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        if let colorScheme = environment["TEST_RUNNER_COLOR_SCHEME"], !colorScheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", colorScheme]
        }
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func openStaffSession(_ app: XCUIApplication) {
        openSession(id: "session-staff-account-exclusions", in: app)
        XCTAssertTrue(
            app.staticTexts["Staff Account Exclusions Atlas Monitoring"].waitForExistence(timeout: 30),
            "Staff session did not open"
        )
    }

    private func openSession(id: String, in app: XCUIApplication) {
        let row = app.buttons[id]
        for _ in 0..<12 {
            if row.waitForExistence(timeout: 5) {
                row.tap()
                return
            }
            app.swipeUp()
        }
        XCTFail("Session row did not load: \(id)")
    }

    private func elementText(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    private func waitForChange(_ element: XCUIElement, from initial: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if elementText(element) != initial { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func waitForValue(_ element: XCUIElement, expected: String) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if element.value as? String == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement, above bottomStack: XCUIElement) -> Bool {
        for index in 0..<8 {
            let timeout: TimeInterval = index == 0 ? 30 : 1
            if element.waitForExistence(timeout: timeout),
               element.frame.maxY <= bottomStack.frame.minY {
                return true
            }
            scrollView.swipeDown()
        }
        return element.exists && element.frame.maxY <= bottomStack.frame.minY
    }

    private func auditPresentedSheet(_ app: XCUIApplication) {
        let issueCount = auditLines.count
        do {
            try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .textClipped])) { issue in
                self.auditLines.append("inspector-sheet: \(self.auditDescription(issue))")
                return true
            }
        } catch {
            auditLines.append("inspector-sheet: audit failed: \(error)")
        }
        XCTAssertEqual(auditLines.count, issueCount, "Details-sheet accessibility audit found issues")
    }

    private func auditDescription(_ issue: XCUIAccessibilityAuditIssue) -> String {
        guard let element = issue.element else { return String(describing: issue) }
        return "\(issue) frame=\(element.frame) identifier=\(element.identifier) label=\(element.label) type=\(element.elementType.rawValue)"
    }

    private func audit(app: XCUIApplication, name: String) {
        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append("\(name): \(self.auditDescription(issue))")
                return true
            }
        } catch {
            auditLines.append("\(name): audit failed: \(error)")
        }
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
