import XCTest

@MainActor
final class WarmThemeScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["TEST_RUNNER_WARM_THEME"] == "1" else {
            throw XCTSkip("Warm theme screenshots are opt-in")
        }
    }

    func testWarmThemeScreens() {
        let variants = [
            (name: "classic-light", theme: "classic", prose: "system", button: "classic", scheme: "light"),
            (name: "linen-light", theme: "linen", prose: "system", button: "floating", scheme: "light"),
            (name: "linen-serif", theme: "linen", prose: "serif", button: "floating", scheme: "light"),
            (name: "linen-dark", theme: "linen", prose: "system", button: "floating", scheme: "dark"),
        ]

        for variant in variants {
            let app = launchMock(
                screen: "warm-theme",
                scheme: variant.scheme,
                theme: variant.theme,
                prose: variant.prose,
                button: variant.button
            )
            let ready = app.descendants(matching: .any).matching(identifier: "mock-ready").firstMatch
            XCTAssertTrue(ready.waitForExistence(timeout: 15), "Warm theme mock did not load: \(variant.name)")
            let prose = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Linen theme review")
            ).firstMatch
            XCTAssertTrue(prose.waitForExistence(timeout: 15), "Warm theme transcript did not mount: \(variant.name)")
            let code = app.buttons["Copy code"]
            let tool = app.descendants(matching: .any).matching(identifier: "tool-run-card").firstMatch
            let codeMounted = code.waitForExistence(timeout: 15)
            let toolMounted = tool.waitForExistence(timeout: 15)
            if !codeMounted || !toolMounted {
                print("warm-theme content variant=\(variant.name) code=\(codeMounted) tool=\(toolMounted)")
            }

            let frames = waitForTranscriptRest(app, variant: variant.name)
            printFrames(frames, variant: variant.name)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = variant.name
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    func testWarmThemeDuoClassicButton() {
        let app = launchMock(
            screen: "warm-theme",
            scheme: "light",
            theme: "linen",
            prose: "system",
            button: "classic"
        )
        let ready = app.descendants(matching: .any).matching(identifier: "mock-ready").firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 15), "Warm theme classic-button mock did not load")
        let prose = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Linen theme review")
        ).firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 15), "Warm theme classic-button transcript did not mount")
        let code = app.buttons["Copy code"]
        let tool = app.descendants(matching: .any).matching(identifier: "tool-run-card").firstMatch
        _ = code.waitForExistence(timeout: 15)
        _ = tool.waitForExistence(timeout: 15)
        let frames = waitForTranscriptRest(app, variant: "linen-light-classic-button")
        printFrames(frames, variant: "linen-light-classic-button")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "linen-light-classic-button"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testSessionListScreens() {
        let variants = [
            (name: "sessions-classic-light", theme: "classic", button: "classic"),
            (name: "sessions-linen-light", theme: "linen", button: "floating"),
        ]
        for variant in variants {
            let app = launchMock(
                screen: "sessions",
                scheme: "light",
                theme: variant.theme,
                prose: "system",
                button: variant.button
            )
            let ready = app.descendants(matching: .any).matching(identifier: "mock-ready").firstMatch
            XCTAssertTrue(ready.waitForExistence(timeout: 15), "Session list mock did not load: \(variant.name)")
            let title = app.staticTexts["Sessions"]
            XCTAssertTrue(title.waitForExistence(timeout: 15), "Session list title did not load: \(variant.name)")
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = variant.name
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private func launchMock(
        screen: String,
        scheme: String,
        theme: String,
        prose: String,
        button: String
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CCMock", screen,
            "-CCColorScheme", scheme,
            "-CCTheme", theme,
            "-CCProseFont", prose,
            "-CCNewSessionButton", button,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge",
        ]
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func waitForTranscriptRest(
        _ app: XCUIApplication,
        variant: String
    ) -> (last: CGRect, composer: CGRect, settled: Bool) {
        let last = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Compare the classic and Linen light captures first")
        ).firstMatch
        let composer = app.descendants(matching: .any).matching(identifier: "bottom-stack").firstMatch
        let deadline = Date().addingTimeInterval(5)
        var lastFrame = last.frame
        var composerFrame = composer.frame
        var settled = false
        while Date() < deadline {
            guard last.exists, composer.exists else {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            lastFrame = last.frame
            composerFrame = composer.frame
            if lastFrame.maxY <= composerFrame.minY {
                settled = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        print(
            "warm-theme-rest variant=\(variant) settled=\(settled) "
                + "last=(\(lastFrame.minX),\(lastFrame.minY),\(lastFrame.width),\(lastFrame.height)) "
                + "composer=(\(composerFrame.minX),\(composerFrame.minY),\(composerFrame.width),\(composerFrame.height))"
        )
        return (lastFrame, composerFrame, settled)
    }

    private func printFrames(
        _ frames: (last: CGRect, composer: CGRect, settled: Bool),
        variant: String
    ) {
        print(
            "warm-theme-frame-evidence variant=\(variant) settled=\(frames.settled) "
                + "lastMaxY=\(frames.last.maxY) composerMinY=\(frames.composer.minY)"
        )
    }
}
