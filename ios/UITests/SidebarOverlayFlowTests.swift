import XCTest

@MainActor
final class SidebarOverlayFlowTests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testLandscapeSelectedSessionStartsDetailOnlyAndSwitchesSession() throws {
        let app = launch(orientation: .landscapeRight, sessionID: "staff-account-exclusions")
        defer { app.terminate() }
        assertRegularLandscape(in: app)

        let selectedTitle = app.descendants(matching: .any)
            .matching(identifier: "selected-session-name")
            .firstMatch
        XCTAssertTrue(selectedTitle.waitForExistence(timeout: 75), "Selected session did not open in landscape")
        XCTAssertEqual(selectedTitle.label, "Staff Account Exclusions Atlas Monitoring")
        let sessionsList = app.descendants(matching: .any)
            .matching(identifier: "sessions-list")
            .firstMatch
        XCTAssertTrue(sessionsList.waitForNonExistence(timeout: 10), "Sessions list was visible in detail-only mode")
        addScreenshot(named: "sidebar-detail-only")

        let toggle = sidebarToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Sidebar toggle did not load")
        toggle.tap()
        let otherSession = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(otherSession.waitForExistence(timeout: 20), "Opening the sidebar did not show other sessions")
        addScreenshot(named: "sidebar-overlay-open")

        otherSession.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let switchedTitle = app.descendants(matching: .any)
            .matching(identifier: "selected-session-name")
            .firstMatch
        XCTAssertTrue(switchedTitle.waitForExistence(timeout: 30), "Second session did not open")
        XCTAssertEqual(switchedTitle.label, "Approval Flow Light Mode")
        XCTAssertFalse(otherSession.exists, "Selecting another session did not hide the sidebar overlay")
    }

    func testLandscapeShowsApprovalsElsewhereAndOpensSidebar() throws {
        let app = launch(orientation: .landscapeRight, sessionID: "staff-account-exclusions")
        defer { app.terminate() }
        assertRegularLandscape(in: app)

        let capsule = app.buttons["approvals-elsewhere"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 75), "Approvals-elsewhere capsule did not load")
        XCTAssertEqual(capsule.label, "1 session needs you")
        addScreenshot(named: "sidebar-approvals-elsewhere")

        capsule.tap()
        XCTAssertTrue(
            app.buttons["session-approval-flow-light-mode"].waitForExistence(timeout: 20),
            "Approvals-elsewhere capsule did not open the sessions list"
        )
    }

    func testReadableComposerWidthIsCappedLandscapeAndFillsPortrait() throws {
        let landscape = launch(orientation: .landscapeRight, sessionID: "long-session")
        defer { landscape.terminate() }
        assertRegularLandscape(in: landscape)
        let landscapeComposer = landscape.descendants(matching: .any)
            .matching(identifier: "composer-text")
            .firstMatch
        XCTAssertTrue(landscapeComposer.waitForExistence(timeout: 75), "Landscape composer did not load")
        XCTAssertLessThanOrEqual(landscapeComposer.frame.width, 760, "Landscape composer exceeded readable width")
        XCUIDevice.shared.orientation = .portrait
        let portraitComposer = landscape.descendants(matching: .any)
            .matching(identifier: "composer-text")
            .firstMatch
        XCTAssertTrue(portraitComposer.waitForExistence(timeout: 30), "Portrait composer did not load")
        let portraitWidth = landscape.windows.firstMatch.frame.width
        XCTAssertGreaterThan(
            portraitComposer.frame.width,
            portraitWidth - 80,
            "Portrait composer no longer fills the available width"
        )
        addScreenshot(named: "sidebar-portrait-unchanged")
    }

    private func assertRegularLandscape(in app: XCUIApplication) {
        let sizeClass = app.descendants(matching: .any)
            .matching(identifier: "horizontal-size-class")
            .firstMatch
        XCTAssertTrue(sizeClass.waitForExistence(timeout: 30), "Horizontal size-class probe did not load")
        XCTAssertEqual(sizeClass.label, "regular", "Landscape pool device did not report regular horizontal size class")
        print("LANDSCAPE_HORIZONTAL_SIZE_CLASS \(sizeClass.label) VISIBILITY \(sizeClass.value ?? "nil")")
    }

    private func sidebarToggle(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'"))
            .firstMatch
    }

    private func launch(orientation: UIDeviceOrientation, sessionID: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = [
            "-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL"),
            "-CCSession", sessionID,
        ]
        app.launchEnvironment["CCBearer"] = requiredRunnerVariable("TEST_RUNNER_BEARER")
        if let colorScheme = ProcessInfo.processInfo.environment["TEST_RUNNER_COLOR_SCHEME"], !colorScheme.isEmpty {
            app.launchArguments += ["-CCColorScheme", colorScheme]
        }
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
