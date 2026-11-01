import Foundation
import XCTest

/// One long walk through the app on the iPhone Duo: one fixture restart, as few launches as the steps allow.
/// Set Up puts the hinge where the journey asks, so a journey's posture never depends on what ran before it.
@MainActor
class JourneyTestCase: FixtureFlowTestSupport {
    var posture: DuoPosture { .folded }

    override func setUp() async throws {
        try await super.setUp()
        SimulatorHinge.apply(posture)
    }

    func launchSignedIn(
        session: String? = nil,
        server: String? = nil,
        resetCache: Bool = true,
        extraControllers: Bool = false,
        arguments: [String] = [],
        environment: [String: String] = [:],
        freezeLiveIndicators: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server ?? requiredRunnerVariable("TEST_RUNNER_SERVER_URL")]
        if resetCache { app.launchArguments.append("-CCResetCache") }
        if let session { app.launchArguments += ["-CCSession", session] }
        if extraControllers {
            let extra = try! JSONSerialization.data(withJSONObject: [[
                "id": "mustafar",
                "name": "Mustafar",
                "server": requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_URL"),
            ]])
            app.launchArguments += ["-CCExtraControllers", String(decoding: extra, as: UTF8.self)]
            app.launchEnvironment["CCExtraControllerBearer_mustafar"] = requiredRunnerVariable("TEST_RUNNER_SECOND_FIXTURE_BEARER")
        }
        app.launchArguments += arguments
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        for (key, value) in environment { app.launchEnvironment[key] = value }
        if let scheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !scheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", scheme]
        }
        configureLiveIndicatorAnimations(app, freeze: freezeLiveIndicators)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    /// Opens a session from the folded list, or from the sidebar when open, scrolling to its row if it has to.
    func openSession(_ id: String, in app: XCUIApplication, timeout: TimeInterval = 75) {
        let row = app.buttons["session-\(id)"]
        XCTAssertTrue(row.waitToExist(timeout: timeout), "Session row \(id) did not load")
        for _ in 0..<5 where !row.isSafelyHittable { app.sessionsList.swipeUp() }
        row.tap()
        XCTAssertTrue(app.selectedSessionName.waitToExist(timeout: 20), "Session \(id) did not open")
    }

    /// Back from a session to the folded list. iOS puts the back button on the rail beside the folded
    /// display's content, outside the navigation bar, so `navigationBars.buttons` never holds it.
    func goBackToSessions(in app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitToExist(timeout: 10), "Back button did not load")
        back.tap()
        XCTAssertTrue(app.sessionsList.waitToExist(timeout: 15), "Sessions list did not come back")
    }

    func typeInComposer(_ text: String, in app: XCUIApplication) {
        let field = app.composer
        field.tap()
        field.typeText(text)
    }

    /// Sends with whichever button the session's state offers.
    func sendComposer(_ text: String, in app: XCUIApplication) {
        typeInComposer(text, in: app)
        let send = app.buttons["composer-send"]
        if send.exists { send.tap() } else { app.buttons["composer-queue"].tap() }
    }

    func emptyComposer(in app: XCUIApplication) {
        let field = app.composer
        let length = field.typedText.count
        guard length > 0 else { return }
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length))
    }

    func postFixtureJSON(_ path: String, body: [String: Any], control: String = "TEST_RUNNER_FIXTURE_CONTROL_URL") async throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: requiredRunnerVariable(control) + path)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Fixture route \(path) failed: \(String(decoding: data, as: UTF8.self))")
    }

    func fixtureJSON(_ path: String, control: String = "TEST_RUNNER_FIXTURE_CONTROL_URL") async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: requiredRunnerVariable(control) + path))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Fixture route \(path) failed")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func fixtureRequestCounts(control: String = "TEST_RUNNER_FIXTURE_CONTROL_URL") async throws -> [String: Int] {
        let log = try await fixtureJSON("/fixture/requests", control: control)
        return try XCTUnwrap(log["counts"] as? [String: Int])
    }

    /// How many requests the fixture has answered whose "METHOD path status" key starts this way.
    func fixtureRequestCount(_ prefix: String, control: String = "TEST_RUNNER_FIXTURE_CONTROL_URL") async throws -> Int {
        try await fixtureRequestCounts(control: control).filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
    }

    func waitForFixtureRequest(_ prefix: String, control: String = "TEST_RUNNER_FIXTURE_CONTROL_URL", timeout: TimeInterval = 10) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout * flowTimeScale())
        repeat {
            let count = try await fixtureRequestCount(prefix, control: control)
            if count > 0 { return true }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    /// `XCUIDevice.press(.home)` leaves the app in the foreground on the folded Duo, so a step that relies on
    /// it tests nothing. Bringing another app forward really backgrounds this one, and this checks that it did.
    func sendToBackground(_ app: XCUIApplication) {
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
        XCTAssertTrue(
            pollUntil(timeout: 5) { app.state == .runningBackground || app.state == .runningBackgroundSuspended },
            "The app did not go to the background: state \(app.state.rawValue)"
        )
    }

    /// Scrolls back past the first page, which ends at prompt 490, and returns a row from the page before it.
    /// A fast swipe covers several prompts and takes about five seconds on a runner, so don't wait for one exact row.
    func pageBackPastFirstPage(in app: XCUIApplication) -> XCUIElement {
        let paged = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "Long-session prompt 4[0-8][0-9]: inspect the next checkpoint\\."))
        for _ in 0..<12 {
            app.transcriptScroll.swipeDown(velocity: .fast)
            let row = paged.firstMatch
            if row.exists, row.isHittable { return app.staticTexts[row.label] }
        }
        XCTFail("Paging did not reach a row before the first page")
        return paged.firstMatch
    }

    /// Lets the app settle where a check needs a pause before it can mean anything.
    func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// Typed queries where a type is known: on the folded Duo they cost about a quarter of
/// `descendants(matching: .any)`, and a miss costs about a tenth. See the note in `ios/UITests/README.md`.
@MainActor
extension XCUIApplication {
    var composer: XCUIElement { textFields["composer-text"] }
    var transcriptScroll: XCUIElement { collectionViews["transcript-scroll"] }
    var selectedSessionName: XCUIElement { staticTexts["selected-session-name"] }
    var selectedSessionSubtitle: XCUIElement { staticTexts["selected-session-subtitle"] }
    var jumpToLatest: XCUIElement { buttons["Jump to latest"] }

    /// A list's identifier can land on the collection view or on a wrapper around it, depending on the screen.
    var sessionsList: XCUIElement { element(identifier: "sessions-list") }

    /// For elements whose type changes with state, such as a pending bubble that gains the button trait.
    func element(identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func pendingPrompt(message: String? = nil, status: String? = nil) -> XCUIElement {
        var predicates: [NSPredicate] = []
        if let message { predicates.append(NSPredicate(format: "label BEGINSWITH %@", message)) }
        if let status { predicates.append(NSPredicate(format: "value == %@", status)) }
        let prompts = descendants(matching: .any).matching(identifier: "pending-prompt")
        guard !predicates.isEmpty else { return prompts.firstMatch }
        return prompts.matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates)).firstMatch
    }

    func staticText(containing text: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }
}

@MainActor
extension XCUIElement {
    /// What's been typed. An empty field reports its placeholder as its value.
    var typedText: String {
        let text = value as? String ?? ""
        return text == placeholderValue ? "" : text
    }
}
