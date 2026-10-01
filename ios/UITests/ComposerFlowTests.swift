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

    func testSendFromIdleSession() throws {
        let app = launchFixture()
        defer {
            audit(app: app, name: "composer-sent")
            attach(named: "composer-sent")
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

        let resetField = composerField(in: app)
        XCTAssertTrue(resetField.waitForExistence(timeout: 10), "Composer did not reappear after send")
        XCTAssertTrue(waitForValue(of: resetField, equalTo: "", timeout: 10), "Composer text did not clear after send")
        let resetHeight = resetField.frame.height
        XCTAssertLessThanOrEqual(abs(resetHeight - initialHeight), 2, "Composer did not reset height: initial \(initialHeight), reset \(resetHeight)")
        print("composer heights initial=\(initialHeight) wrapped=\(wrappedHeight ?? field.frame.height) reset=\(resetHeight)")
        resetField.typeText("f")
        XCTAssertEqual(resetField.value as? String, "f", "Composer did not retain keyboard focus after send")
        let prompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "Sent marker did not appear in the transcript")
        XCTAssertTrue(app.buttons["Model Fable 5.1"].waitForExistence(timeout: 10), "Model chip did not render")
    }

    func testQueueWhileWorking() throws {
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
        let initialComposerHeight = composer.frame.height

        let marker = "dune-part-three-imax-tickets"
        field.tap()
        field.typeText(marker)
        let send = app.buttons["composer-queue"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Queue button did not load while working")
        send.tap()

        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 15), "Queued marker did not render")
        XCTAssertTrue(app.staticTexts["Queued"].waitForExistence(timeout: 15), "Queued caption did not render")
        let resetField = composerField(in: app)
        XCTAssertTrue(resetField.waitForExistence(timeout: 10), "Composer did not remain visible after queue")
        XCTAssertTrue(waitForValue(of: resetField, equalTo: "", timeout: 10), "Composer text did not clear after queue")
        let resetHeight = resetField.frame.height
        XCTAssertLessThanOrEqual(abs(resetHeight - initialHeight), 2, "Composer did not reset height while queueing: initial \(initialHeight), reset \(resetHeight)")
        let resetComposerHeight = composer.frame.height
        print("composer queue heights fieldInitial=\(initialHeight) fieldReset=\(resetHeight) glassInitial=\(initialComposerHeight) glassReset=\(resetComposerHeight)")
        XCTAssertLessThanOrEqual(abs(resetComposerHeight - initialComposerHeight), 2, "Composer glass did not reset height while queueing: initial \(initialComposerHeight), reset \(resetComposerHeight)")
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

    private func launchFixture() -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832"
        let bearer = environment["TEST_RUNNER_BEARER"] ?? ""
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server]
        app.launchEnvironment["CCBearer"] = bearer
        app.launch()
        return app
    }

    private func openSession(id: String, in app: XCUIApplication) {
        if id == "session-long-session" {
            let searchButton = app.buttons["Search"]
            XCTAssertTrue(searchButton.waitForExistence(timeout: 15), "Session search did not load")
            searchButton.tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 15), "Session search field did not load")
            search.tap()
            search.typeText("Long session")
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
