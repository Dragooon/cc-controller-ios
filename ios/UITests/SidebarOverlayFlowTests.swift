import XCTest

@MainActor
final class SidebarOverlayFlowTests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testLandscapeKeepsBothColumnsAndSwitchesSession() throws {
        let app = launch(orientation: .landscapeRight, sessionID: "staff-account-exclusions")
        defer { app.terminate() }
        assertRegularLandscape(in: app)

        let selectedTitle = app.descendants(matching: .any)
            .matching(identifier: "selected-session-name")
            .firstMatch
        XCTAssertTrue(selectedTitle.waitForExistence(timeout: 75), "Selected session did not open in landscape")
        XCTAssertEqual(selectedTitle.label, "Staff Account Exclusions Atlas Monitoring")

        let sessionsList = sessionsList(in: app)
        XCTAssertTrue(sessionsList.waitForExistence(timeout: 20), "Sessions list was not visible beside the detail")
        let detail = transcript(in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 30), "Transcript detail did not load")
        assertDetailIsBesideSidebar(detail: detail, sidebar: sessionsList, in: app)
        addScreenshot(named: "sidebar-landscape-visible")

        let otherSession = app.buttons["session-approval-flow-light-mode"]
        XCTAssertTrue(otherSession.waitForExistence(timeout: 20), "Other session did not appear in the visible list")
        otherSession.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(selectedTitle.waitForExistence(timeout: 30), "Second session did not open")
        XCTAssertEqual(selectedTitle.label, "Approval Flow Light Mode")
        XCTAssertTrue(sessionsList.waitForExistence(timeout: 10), "Sessions list disappeared after switching sessions")
        assertDetailIsBesideSidebar(detail: transcript(in: app), sidebar: sessionsList, in: app)
    }

    func testLandscapeSearchFieldStaysInsideSessionsSidebar() throws {
        let app = launch(orientation: .landscapeRight, sessionID: "staff-account-exclusions")
        defer { app.terminate() }
        assertRegularLandscape(in: app)

        let sidebar = sessionsList(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 75), "Sessions list did not load")
        let searchButton = app.buttons["sessions-search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 20), "Sessions search button did not load")
        searchButton.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Presented sessions search field did not load")
        XCTAssertTrue(sidebar.frame.contains(field.frame), "Landscape search field escaped sessions sidebar: field=\(field.frame), sidebar=\(sidebar.frame)")
        addScreenshot(named: "sessions-search-landscape")
    }

    func testPortraitSearchFieldStaysInsideSessionsColumn() throws {
        let app = launch(orientation: .portrait)
        defer { app.terminate() }

        let sidebar = sessionsList(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 75), "Sessions list did not load")
        let searchButton = app.buttons["sessions-search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 20), "Sessions search button did not load")
        searchButton.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Presented sessions search field did not load")
        XCTAssertTrue(sidebar.frame.contains(field.frame), "Portrait search field escaped sessions column: field=\(field.frame), sidebar=\(sidebar.frame)")
        addScreenshot(named: "sessions-search-portrait")
    }

    func testLandscapeSidebarToggleResizesDetail() throws {
        let app = launch(orientation: .landscapeRight, sessionID: "long-session")
        defer { app.terminate() }
        assertRegularLandscape(in: app)

        let detail = transcript(in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 75), "Transcript did not load")
        let sidebar = sessionsList(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 20), "Sessions list did not load")
        let visibleExtent = detailExtent(of: detail, in: app)

        let toggle = sidebarToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Sidebar toggle did not load")
        toggle.tap()
        XCTAssertTrue(waitForExtent(of: detail, greaterThan: visibleExtent + 20, in: app, timeout: 10), "Hiding the sidebar did not widen the detail")
        let hiddenExtent = detailExtent(of: detail, in: app)
        addScreenshot(named: "sidebar-landscape-hidden")

        detail.swipeUp()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        addScreenshot(named: "sidebar-landscape-hidden-scrolled")

        sidebarToggle(in: app).tap()
        XCTAssertTrue(waitForExtent(of: detail, lessThan: hiddenExtent - 20, in: app, timeout: 10), "Showing the sidebar did not narrow the detail")
    }

    func testApprovalsCapsuleFollowsSidebarVisibility() throws {
        let app = launch(orientation: .landscapeRight, sessionID: "staff-account-exclusions")
        defer { app.terminate() }
        assertRegularLandscape(in: app)

        let sidebar = sessionsList(in: app)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 75), "Sessions list did not load")
        let capsule = app.buttons["approvals-elsewhere"]
        XCTAssertFalse(capsule.waitForExistence(timeout: 5), "Approvals capsule was visible while the sidebar was shown")

        sidebarToggle(in: app).tap()
        XCTAssertTrue(capsule.waitForExistence(timeout: 20), "Approvals capsule did not appear after hiding the sidebar")
        XCTAssertEqual(capsule.label, "1 session needs you")
        capsule.tap()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 20), "Approvals capsule did not show the sidebar")
        XCTAssertFalse(capsule.exists, "Approvals capsule remained visible with the sidebar shown")
    }

    func testReadableComposerWidthIsCappedLandscapeAndFillsPortrait() throws {
        let app = launch(orientation: .landscapeRight, sessionID: "long-session")
        defer { app.terminate() }
        assertRegularLandscape(in: app)

        let landscapeComposer = app.descendants(matching: .any)
            .matching(identifier: "composer-text")
            .firstMatch
        XCTAssertTrue(landscapeComposer.waitForExistence(timeout: 75), "Landscape composer did not load")
        XCTAssertLessThanOrEqual(landscapeComposer.frame.width, 760, "Landscape composer exceeded readable width")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(landscapeComposer.waitForExistence(timeout: 30), "Portrait composer did not load")
        let portraitWidth = app.windows.firstMatch.frame.width
        XCTAssertGreaterThan(
            landscapeComposer.frame.width,
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

    private func sessionsList(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sessions-list").firstMatch
    }

    private func transcript(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "session-detail-frame").firstMatch
    }

    private func assertDetailIsBesideSidebar(detail: XCUIElement, sidebar: XCUIElement, in app: XCUIApplication) {
        guard let detailFrame = layoutFrame(for: detail),
              let sidebarFrame = layoutFrame(for: app.descendants(matching: .any)
                .matching(identifier: "sessions-list-frame")
                .firstMatch) else {
            XCTFail("Layout frame probes did not load")
            return
        }
        XCTAssertTrue(
            detailFrame.minX + 1 >= sidebarFrame.maxX - 1,
            "Detail overlaps the sessions sidebar: detail=\(detailFrame), sidebar=\(sidebarFrame)"
        )
    }

    private func detailExtent(of element: XCUIElement, in app: XCUIApplication) -> CGFloat {
        layoutFrame(for: element).map { max($0.width, $0.height) } ?? 0
    }

    private func layoutFrame(for element: XCUIElement) -> CGRect? {
        let value = (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
        let components = value.split(separator: ",").compactMap { Double($0) }
        guard components.count == 4 else { return nil }
        return CGRect(
            x: components[0],
            y: components[1],
            width: components[2],
            height: components[3]
        )
    }

    private func sidebarToggle(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'"))
            .firstMatch
    }

    private func waitForExtent(
        of element: XCUIElement,
        greaterThan extent: CGFloat,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if detailExtent(of: element, in: app) > extent { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func waitForExtent(
        of element: XCUIElement,
        lessThan extent: CGFloat,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if detailExtent(of: element, in: app) < extent { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func launch(orientation: UIDeviceOrientation, sessionID: String? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = [
            "-CCServer", requiredRunnerVariable("TEST_RUNNER_SERVER_URL"),
        ]
        if let sessionID {
            app.launchArguments += ["-CCSession", sessionID]
        }
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
