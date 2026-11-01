import XCTest

/// Temporary probes for the Duo's two postures, deleted before this branch is finished.
@MainActor
final class ZDiagFlowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try await restartFixtureIfConfigured()
    }

    private func launchApp(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL"), "-CCResetCache"] + extra
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func timed<T>(_ name: String, _ body: () -> T) -> T {
        let started = Date()
        let value = body()
        print("DIAG \(name) = \(value) [\(String(format: "%.3f", Date().timeIntervalSince(started)))s]")
        return value
    }

    private func shoot(_ name: String) {
        print("DIAG screens=\(XCUIScreen.screens.count) main=\(XCUIScreen.main.screenshot().image.size)")
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let shot = screen.screenshot()
            print("DIAG \(name) screen \(index) size=\(shot.image.size)")
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(name)-display-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func dumpHierarchy(_ app: XCUIApplication, name: String) {
        let description = app.debugDescription
        print("DIAG hierarchy \(name) length=\(description.count)")
        let attachment = XCTAttachment(data: Data(description.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "\(name)-hierarchy.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        for line in description.split(separator: "\n") where line.contains("Back") || line.contains("session-info") || line.contains("Button,") {
            print("DIAG line \(line.prefix(180))")
        }
    }

    private func probeBack(_ app: XCUIApplication) {
        _ = timed("navigationBars.count") { app.navigationBars.count }
        _ = timed("navigationBars.buttons.count") { app.navigationBars.buttons.count }
        _ = timed("navigationBars.any.count") { app.navigationBars.descendants(matching: .any).count }
        _ = timed("buttons[BackButton]") { app.buttons["BackButton"].exists }
        _ = timed("buttons[Back]") { app.buttons["Back"].exists }
        _ = timed("buttons[Sessions]") { app.buttons["Sessions"].exists }
        _ = timed("buttons label Back") { app.buttons.matching(NSPredicate(format: "label == 'Back'")).count }
        _ = timed("others[BackButton]") { app.otherElements["BackButton"].exists }
        _ = timed("others[Back]") { app.otherElements["Back"].exists }
        _ = timed("any[BackButton]") { app.descendants(matching: .any)["BackButton"].exists }
        _ = timed("any label Back") { app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Back'")).count }
        _ = timed("buttons[session-info]") { app.buttons["session-info"].exists }
        _ = timed("any[session-info]") { app.descendants(matching: .any)["session-info"].exists }
        _ = timed("buttons all labels") { app.buttons.allElementsBoundByIndex.prefix(40).map { "\($0.identifier)|\($0.label)|\($0.frame)" } }
        _ = timed("windows") { app.windows.allElementsBoundByIndex.map(\.frame) }
    }

    /// Why a folded session's back button isn't found, and whether a person can use it.
    func testFoldedBackButton() async throws {
        let app = launchApp()
        defer { app.terminate() }
        let row = app.buttons["session-staff-account-exclusions"]
        let list = app.descendants(matching: .any).matching(identifier: "sessions-list").firstMatch
        XCTAssertTrue(list.waitToExist(timeout: 75))
        for _ in 0..<5 where !row.exists { list.swipeUp() }
        XCTAssertTrue(row.waitToExist(timeout: 20))
        row.tap()
        XCTAssertTrue(app.staticTexts["selected-session-name"].waitToExist(timeout: 20))
        shoot("opened")
        dumpHierarchy(app, name: "opened")
        probeBack(app)

        // Try every way back, one at a time, and report which one works.
        let backByLabel = app.buttons.matching(NSPredicate(format: "label == 'Back'")).firstMatch
        let backById = app.buttons["BackButton"]
        if backById.exists {
            print("DIAG tapping buttons[BackButton] hittable=\(backById.isHittable) frame=\(backById.frame)")
            backById.tap()
        } else if backByLabel.exists {
            print("DIAG tapping label Back hittable=\(backByLabel.isHittable) frame=\(backByLabel.frame)")
            backByLabel.tap()
        } else {
            let anyBack = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Back'")).firstMatch
            if anyBack.exists {
                print("DIAG tapping any Back type=\(anyBack.elementType.rawValue) frame=\(anyBack.frame)")
                anyBack.tap()
            } else {
                print("DIAG nothing named Back, tapping the rail by coordinate")
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 417, dy: 197)).tap()
            }
        }
        var back = list.waitToExist(timeout: 8)
        print("DIAG back after tap = \(back)")
        shoot("after-tap")
        if !back {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 417, dy: 197)).tap()
            back = list.waitToExist(timeout: 8)
            print("DIAG back after coordinate tap = \(back)")
        }
        if !back {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
            back = list.waitToExist(timeout: 8)
            print("DIAG back after edge swipe = \(back)")
        }
        shoot("end")

        // A short session, to see the same probes without the staff session's content.
        if back {
            let short = app.buttons["session-dune-part-three-imax-tickets"]
            XCTAssertTrue(short.waitToExist(timeout: 20))
            short.tap()
            XCTAssertTrue(app.staticTexts["selected-session-name"].waitToExist(timeout: 20))
            dumpHierarchy(app, name: "short")
            probeBack(app)
        }
    }

    /// Typed queries against `descendants(matching: .any)`, on the elements journeys look up most.
    func testLookupTiming() async throws {
        let app = launchApp(["-CCSession", "long-session"])
        defer { app.terminate() }
        let anyField = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(anyField.waitToExist(timeout: 75))
        dumpHierarchy(app, name: "long")
        let typedField = app.textViews["composer-text"]
        let anyScroll = transcriptScroll(in: app)
        let typedScroll = app.collectionViews["transcript-scroll"]
        let anyTitle = app.descendants(matching: .any).matching(identifier: "selected-session-name").firstMatch
        let typedTitle = app.staticTexts["selected-session-name"]
        for round in 0..<3 {
            for (name, element) in [
                ("any composer", anyField), ("typed composer", typedField),
                ("any scroll", anyScroll), ("typed scroll", typedScroll),
                ("any title", anyTitle), ("typed title", typedTitle),
                ("missing any", app.descendants(matching: .any).matching(identifier: "no-such-element").firstMatch),
                ("missing typed", app.buttons["no-such-element"]),
            ] {
                let started = Date()
                var found = false
                for _ in 0..<5 { found = element.exists }
                print("DIAG lookup round=\(round) \(name) found=\(found) avg=\(String(format: "%.3f", Date().timeIntervalSince(started) / 5))s")
            }
        }
    }

    /// Whether the hinge opens and closes on a running simulator, and what the app sees each way.
    func testHingeOpensAndCloses() async throws {
        let app = launchApp()
        let sizeClass = app.descendants(matching: .any).matching(identifier: "horizontal-size-class").firstMatch
        XCTAssertTrue(sizeClass.waitToExist(timeout: 75))
        func report(_ name: String) {
            print("DIAG \(name) sizeClass=\(sizeClass.exists ? sizeClass.label : "none") windows=\(app.windows.allElementsBoundByIndex.map(\.frame)) orientation=\(XCUIDevice.shared.orientation.rawValue)")
            shoot(name)
        }
        report("boot")
        for (name, angle) in [("angle-180", 180.0), ("angle-0", 0.0), ("angle-180-again", 180.0), ("angle-0-again", 0.0)] {
            print("DIAG set \(name) = \(SimulatorHinge.set(angle: angle))")
            RunLoop.current.run(until: Date().addingTimeInterval(4))
            report(name)
        }
        // Relaunch in each posture: does a fresh launch see the same display?
        app.terminate()
        let folded = launchApp()
        XCTAssertTrue(sizeClass.waitToExist(timeout: 40))
        report("relaunch-after-0")
        folded.terminate()
        print("DIAG set open = \(SimulatorHinge.set(angle: 180))")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        let open = launchApp()
        XCTAssertTrue(sizeClass.waitToExist(timeout: 40))
        report("relaunch-open")
        print("DIAG set closed while running = \(SimulatorHinge.set(angle: 0))")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        report("closed-while-running")
        open.terminate()
    }
}
