import Foundation
import XCTest

func requiredRunnerVariable(_ key: String, file: StaticString = #filePath, line: UInt = #line) -> String {
    guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
        XCTFail("Required runner environment variable \(key) is missing or empty", file: file, line: line)
        return ""
    }
    return value
}

func configureLiveIndicatorAnimations(_ app: XCUIApplication, freeze: Bool = true) {
    guard freeze else { return }
    app.launchArguments += ["-CCFreezeLiveIndicators", "YES"]
}

func configureTranscriptEngine(_ app: XCUIApplication) {
    guard let engine = ProcessInfo.processInfo.environment["TEST_RUNNER_CC_TRANSCRIPT_ENGINE"], !engine.isEmpty else { return }
    app.launchArguments += ["-CCTranscriptEngine", engine]
}

func transcriptScroll(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "transcript-scroll").firstMatch
}

/// Dismisses a notification prompt left on SpringBoard by an earlier test or another simulator lane.
/// An app launched under that prompt never becomes active, so it never connects, and a test that only waits
/// for elements never triggers XCTest's interruption handling.
@MainActor
func dismissLeftoverNotificationPrompt() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let prompt = springboard.alerts.matching(
        NSPredicate(format: "label CONTAINS[c] %@", "Would Like to Send You Notifications")
    ).firstMatch
    guard prompt.exists else { return }
    let label = prompt.label
    prompt.buttons["Don’t Allow"].tap()
    let dismissed = prompt.waitForNonExistence(timeout: 5)
    print("Dismissed leftover notification prompt before launch: \(label) (gone: \(dismissed))")
}

func restartFixtureIfConfigured() async throws {
    guard let value = ProcessInfo.processInfo.environment["TEST_RUNNER_FIXTURE_SUPERVISOR_URL"], !value.isEmpty else { return }
    guard let url = URL(string: "\(value)/supervisor/restart") else {
        throw XCTSkip("Fixture supervisor URL was invalid")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? "no response body"
        throw NSError(domain: "FixtureFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture supervisor restart failed: \(body)"])
    }
}

func postFixtureRoute(_ path: String) async throws {
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

@MainActor
@discardableResult
func openSessionSearch(in app: XCUIApplication, timeout: TimeInterval = 15) -> XCUIElement {
    let regularField = app.textFields["sessions-search-field"]
    if regularField.exists {
        regularField.tap()
        return regularField
    }

    let search = app.searchFields.firstMatch
    if search.exists {
        search.tap()
        return search
    }

    let button = app.buttons["sessions-search"]
    if button.waitForExistence(timeout: min(timeout, 2)) {
        button.tap()
        XCTAssertTrue(search.waitForExistence(timeout: timeout), "Session search field did not load")
        return search
    }

    XCTAssertTrue(regularField.waitForExistence(timeout: timeout), "Session search field did not load")
    regularField.tap()
    return regularField
}

@MainActor
class FixtureFlowTestSupport: XCTestCase {
    private var auditLines: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        try await restartFixtureIfConfigured()
    }

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "fixture-flow-audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func launchOnboarding(
        server: String? = nil,
        expirySeconds: Int? = nil,
        lockInterval: TimeInterval? = nil,
        maxUnlockAge: TimeInterval? = nil,
        probeInterval: TimeInterval? = nil,
        freezeLiveIndicators: Bool = true
    ) -> XCUIApplication {
        launchFixture(
            server: server,
            onboarding: true,
            expirySeconds: expirySeconds,
            lockInterval: lockInterval,
            maxUnlockAge: maxUnlockAge,
            probeInterval: probeInterval,
            freezeLiveIndicators: freezeLiveIndicators
        )
    }

    func launchCold(
        server: String? = nil,
        openingSession: String? = nil,
        maxUnlockAge: TimeInterval? = nil,
        freezeLiveIndicators: Bool = true,
        motionTraceFile: String? = nil,
        motionScenario: String? = nil,
        motionOrientation: UIDeviceOrientation? = nil
    ) -> XCUIApplication {
        launchFixture(
            server: server,
            onboarding: false,
            openingSession: openingSession,
            maxUnlockAge: maxUnlockAge,
            freezeLiveIndicators: freezeLiveIndicators,
            motionTraceFile: motionTraceFile,
            motionScenario: motionScenario,
            motionOrientation: motionOrientation
        )
    }

    func reachFaceID(_ app: XCUIApplication) async throws {
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 10))
        let connected = app.staticTexts["Connected to cc-controller"]
        XCTAssertTrue(connected.waitForExistence(timeout: 15), "Live whoami check did not turn green")
        let latency = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*· [0-9]+ ms")).firstMatch
        XCTAssertTrue(latency.waitForExistence(timeout: 10), "Connected card did not show round-trip latency")
        addScreenshot(named: "onboarding-connect-connected")
        XCTAssertTrue(app.buttons["Continue"].isEnabled)
        app.buttons["Continue"].tap()

        let codeElement = app.descendants(matching: .any).matching(identifier: "pairing-code").firstMatch
        XCTAssertTrue(codeElement.waitForExistence(timeout: 10), "Pairing code did not appear")
        addScreenshot(named: "onboarding-pair-waiting")
        let code = codeElement.label.replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(code.count, 6)
        try await approvePairing(code)
        XCTAssertTrue(app.staticTexts["Protect with Face ID"].waitForExistence(timeout: 15), "Pair confirmation did not reach Face ID")
        addScreenshot(named: "onboarding-faceid-prompt")
    }

    @discardableResult
    func waitForNotificationAuthorizationPrompt(in springboard: XCUIApplication, timeout: TimeInterval = 30) -> XCUIElement {
        let prompt = springboard.alerts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Would Like to Send You Notifications")
        ).firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: timeout), "Notification authorization prompt did not appear")
        return prompt
    }

    func postFixture(_ path: String) async throws {
        try await postFixtureRoute(path)
    }

    func completeFaceID(
        _ app: XCUIApplication,
        until target: XCUIElement,
        timeout: TimeInterval = 30,
        _ message: String
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !target.exists && Date() < deadline {
            try await postFixture("/fixture/biometric/match")
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            _ = target.waitForExistence(timeout: min(3, remaining))
        }
        XCTAssertTrue(target.exists, message)
    }

    func setBiometricEnrollment(_ enrolled: Bool) async throws {
        try await postFixture(enrolled ? "/fixture/biometric/enroll" : "/fixture/biometric/unenroll")
    }

    func approvePairing(_ code: String) async throws {
        let value = requiredRunnerVariable("TEST_RUNNER_FIXTURE_CONTROL_URL")
        guard let url = URL(string: "\(value)/fixture/approve-pairing") else {
            throw XCTSkip("Fixture control URL was invalid")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func audit(_ app: XCUIApplication, name: String) {
        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append("\(name): \(issue)")
                return true
            }
        } catch {
            auditLines.append("\(name) audit failed: \(error)")
        }
    }

    func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchFixture(
        server: String?,
        onboarding: Bool,
        openingSession: String? = nil,
        expirySeconds: Int? = nil,
        lockInterval: TimeInterval? = nil,
        maxUnlockAge: TimeInterval? = nil,
        probeInterval: TimeInterval? = nil,
        freezeLiveIndicators: Bool = true,
        motionTraceFile: String? = nil,
        motionScenario: String? = nil,
        motionOrientation: UIDeviceOrientation? = nil
    ) -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        if let motionOrientation { XCUIDevice.shared.orientation = motionOrientation }
        let app = XCUIApplication()
        if motionTraceFile != nil, let bearer = environment["TEST_RUNNER_BEARER"], !bearer.isEmpty {
            app.launchEnvironment["CCBearer"] = bearer
        }
        app.launchArguments = [
            "-CCServer", server ?? requiredRunnerVariable("TEST_RUNNER_SERVER_URL"),
        ]
        if let openingSession { app.launchArguments += ["-CCSession", openingSession] }
        if let motionTraceFile {
            app.launchArguments += ["-CCMotionTrace", motionTraceFile]
        }
        if let motionScenario {
            app.launchArguments += ["-CCMotionScenario", motionScenario]
        }
        if let sha = environment["CCMotionBuildSHA"], !sha.isEmpty {
            app.launchArguments += ["-CCMotionSHA", sha]
        }
        if let device = environment["CCMotionDevice"], !device.isEmpty {
            app.launchArguments += ["-CCMotionDevice", device]
        }
        if onboarding {
            app.launchArguments += ["-CCOnboarding", "-CCResetCache"]
        }
        if let scheme = environment["TEST_RUNNER_COLOR_SCHEME"] {
            app.launchArguments += ["-CCColorScheme", scheme]
        }
        if let expirySeconds {
            app.launchArguments += ["-CCPairingExpirySeconds", String(expirySeconds)]
        }
        if let lockInterval {
            app.launchArguments += ["-CCLockInterval", String(lockInterval)]
        }
        if let maxUnlockAge {
            app.launchArguments += ["-CCMaxUnlockAge", String(maxUnlockAge)]
        }
        if let probeInterval {
            app.launchArguments += ["-CCProbeInterval", String(probeInterval)]
        }
        configureTranscriptEngine(app)
        configureLiveIndicatorAnimations(app, freeze: freezeLiveIndicators)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }
}

@MainActor
func waitForStableFrame(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var previousFrame: CGRect?
    var stableReads = 0

    repeat {
        guard element.exists, element.isHittable else {
            previousFrame = nil
            stableReads = 0
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            continue
        }

        let currentFrame = element.frame
        if currentFrame == previousFrame {
            stableReads += 1
        } else {
            previousFrame = currentFrame
            stableReads = 1
        }
        if stableReads >= 3 { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return false
}
