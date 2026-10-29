import XCTest

@MainActor
final class AttachmentFlowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try await restartFixtureIfConfigured()
    }

    private var auditLines: [String] = []

    override func tearDown() {
        let report = auditLines.isEmpty ? "No accessibility issues reported." : auditLines.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(report.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "attachment-audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    func testDeliveredPromptShowsRealAttachmentsAndQuickLook() throws {
        let app = launchFixture(
            with: [fixture("attachment.png"), fixture("evidence.csv")],
            openingSession: "long-session"
        )
        defer {
            audit(app, name: "attachment-delivered-bubble")
            app.terminate()
        }

        let field = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(field.waitToExist(timeout: 20), "Composer did not load")
        field.tap()
        field.typeText("delivered-attachment-flow-marker")
        app.buttons["composer-send"].tap()

        let pending = app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch
        if pending.waitToExist(timeout: 5) {
            XCTAssertTrue(waitForNonExistence(of: pending, timeout: 20), "Prompt attachment assertions ran against the pending bubble")
        }

        let marker = "delivered-attachment-flow-marker"
        let markerPredicate = NSPredicate(format: "label CONTAINS[c] %@", marker)
        let bubbles = app.descendants(matching: .any).matching(identifier: "prompt-bubble")
        let markerBubbles = bubbles.matching(markerPredicate)
        XCTAssertTrue(markerBubbles.firstMatch.waitToExist(timeout: 30), "Delivered prompt bubble did not appear")
        XCTAssertEqual(markerBubbles.count, 1, "Expected exactly one bubble to contain the delivered marker")
        let delivered = markerBubbles.firstMatch

        let image = delivered.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'attachment.png'"))
            .firstMatch
        XCTAssertTrue(image.waitToExist(timeout: 30), "Delivered image attachment did not appear")
        XCTAssertEqual(image.label, "attachment.png, image")
        XCTAssertEqual(image.identifier, "prompt-attachment")
        XCTAssertEqual(image.value as? String, "loaded")

        let csv = delivered.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'evidence.csv'"))
            .firstMatch
        XCTAssertTrue(csv.waitToExist(timeout: 30), "Delivered CSV attachment did not appear")
        XCTAssertEqual(csv.label, "evidence.csv, file")
        XCTAssertEqual(csv.identifier, "prompt-attachment")

        addScreenshot(named: "attachment-delivered-bubble")
        image.tap()

        let quickLook = app.otherElements["QLPreviewControllerView"]
        guard quickLook.waitToExist(timeout: 15) else {
            XCTFail("Quick Look controller did not appear")
            return
        }

        let canvas = app.otherElements["Image canvas"]
        guard canvas.waitToExist(timeout: 10) else {
            let debug = XCTAttachment(data: Data(app.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
            debug.name = "prompt-attachment-quicklook-debug.txt"
            debug.lifetime = .keepAlways
            add(debug)
            XCTFail("Quick Look image canvas did not appear")
            return
        }
        addScreenshot(named: "prompt-attachment-quicklook")
    }

    func testAgentSentFileShowsRealAttachmentAndQuickLook() throws {
        let app = launchFixture()
        defer {
            audit(app, name: "agent-sent-file")
            app.terminate()
        }
        openStaffSession(in: app)

        let file = app.buttons["Open review.png"]
        XCTAssertTrue(file.waitToExist(timeout: 30), "Agent-sent review.png file did not appear")
        let imageTile = app.descendants(matching: .any).matching(identifier: "agent-file-image").firstMatch
        XCTAssertTrue(imageTile.waitToExist(timeout: 10), "Agent-sent image tile did not appear")
        XCTAssertEqual(imageTile.frame.width, 277.0 * 280.0 / 600.0, accuracy: 1)
        XCTAssertEqual(imageTile.frame.height, 280, accuracy: 1)
        XCTAssertLessThan(imageTile.frame.width, 220)
        addScreenshot(named: "agent-sent-file-tile")
        file.tap()

        let quickLook = app.otherElements["QLPreviewControllerView"]
        guard quickLook.waitToExist(timeout: 15) else {
            XCTFail("Quick Look controller did not appear for agent-sent file")
            return
        }

        let canvas = app.otherElements["Image canvas"]
        guard canvas.waitToExist(timeout: 10) else {
            let debug = XCTAttachment(data: Data(app.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
            debug.name = "agent-sent-quicklook-debug.txt"
            debug.lifetime = .keepAlways
            add(debug)
            XCTFail("Agent-sent Quick Look image canvas did not appear")
            return
        }
        addScreenshot(named: "agent-sent-quicklook")
    }

    func testLaunchAttachmentSendClearsTray() throws {
        let app = launchFixture(with: fixture("attachment.png"))
        defer {
            audit(app, name: "attachment-send")
            addScreenshot(named: "attachment-uploaded")
            app.terminate()
        }
        openLongSession(in: app)

        let tray = app.descendants(matching: .any).matching(identifier: "attachment-tray").firstMatch
        XCTAssertTrue(tray.waitToExist(timeout: 10), "Attachment tray did not appear")
        let tile = app.descendants(matching: .any).matching(identifier: "attachment-tile").firstMatch
        XCTAssertTrue(tile.waitToExist(timeout: 10), "Attachment tile did not appear")
        let attached = NSPredicate(format: "label ENDSWITH[c] %@", "attached")
        XCTAssertTrue(pollUntil(timeout: 10) { attached.evaluate(with: tile) })

        let field = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        field.tap()
        field.typeText("attachment-flow-marker")
        app.buttons["composer-send"].tap()
        XCTAssertTrue(waitForNonExistence(of: tray, timeout: 15), "Attachment tray remained after send")
    }

    func testTrayBeforeSendShowsRealThumbnailAndCSV() throws {
        let app = launchFixture(with: [fixture("attachment.png"), fixture("evidence.csv")])
        defer {
            audit(app, name: "attachment-tray-before-send")
            addScreenshot(named: "attachment-tray-before-send")
            app.terminate()
        }
        openLongSession(in: app)

        let tray = app.descendants(matching: .any).matching(identifier: "attachment-tray").firstMatch
        XCTAssertTrue(tray.waitToExist(timeout: 10), "Attachment tray did not appear")
        let csv = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'evidence.csv'")).firstMatch
        XCTAssertTrue(csv.waitToExist(timeout: 10), "CSV attachment chip did not appear")
        let attached = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'attached'")).firstMatch
        XCTAssertTrue(attached.waitToExist(timeout: 10), "PNG attachment did not finish uploading")
    }

    func testUploadWaitingStateShowsIndeterminateTile() throws {
        let slowPath = outputFile("slow-attachment.png")
        try FileManager.default.copyItem(atPath: fixture("attachment.png"), toPath: slowPath.path)
        defer { try? FileManager.default.removeItem(at: slowPath.deletingLastPathComponent()) }

        let app = launchFixture(with: slowPath.path)
        defer {
            audit(app, name: "attachment-upload-waiting")
            app.terminate()
        }
        openLongSession(in: app)

        let waiting = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'waiting for server'")).firstMatch
        XCTAssertTrue(waiting.waitToExist(timeout: 3), "Upload did not reach the all-bytes-sent waiting state")
        addScreenshot(named: "attachment-upload-waiting")
    }

    func testTooLargeAttachmentShowsInlineRetryCaption() throws {
        let largePath = outputFile("too-large.bin")
        try Data(repeating: 0, count: 26 * 1024 * 1024).write(to: largePath)
        defer { try? FileManager.default.removeItem(at: largePath.deletingLastPathComponent()) }

        let app = launchFixture(with: largePath.path)
        defer {
            audit(app, name: "attachment-too-large")
            addScreenshot(named: "attachment-too-large")
            app.terminate()
        }
        openLongSession(in: app)

        let failed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'failed'")).firstMatch
        XCTAssertTrue(failed.waitToExist(timeout: 10), "Too-large attachment did not fail")
        let tileCaption = app.staticTexts["Too large (max 25 MB)"]
        XCTAssertTrue(tileCaption.waitToExist(timeout: 10), "Too-large attachment tile caption did not appear")
        app.buttons["composer-send"].tap()
        XCTAssertFalse(app.staticTexts["Remove the file that is too large"].exists, "Tray-level too-large caption appeared")
        XCTAssertFalse(app.alerts["Action failed"].exists, "Blocked attachment send showed an alert")
    }

    func testFailedImageAttachmentShowsRetryCaption() throws {
        let failedPath = outputFile("fail-attachment.png")
        try FileManager.default.copyItem(atPath: fixture("attachment.png"), toPath: failedPath.path)
        defer { try? FileManager.default.removeItem(at: failedPath.deletingLastPathComponent()) }

        let app = launchFixture(with: failedPath.path)
        defer {
            audit(app, name: "attachment-failed-image")
            addScreenshot(named: "attachment-failed-image")
            app.terminate()
        }
        openLongSession(in: app)

        let failed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'failed'")).firstMatch
        XCTAssertTrue(failed.waitToExist(timeout: 10), "Retryable image attachment did not fail")
        let tile = app.descendants(matching: .any).matching(identifier: "attachment-tile").firstMatch
        let badge = app.descendants(matching: .any).matching(identifier: "attachment-failure-badge").firstMatch
        XCTAssertTrue(badge.waitToExist(timeout: 10), "Retryable image failure badge did not appear")
        XCTAssertTrue(tile.frame.contains(badge.frame), "Failure badge frame \(badge.frame) was not inside tile frame \(tile.frame)")
        let tileCaption = app.staticTexts["Tap to retry"]
        XCTAssertTrue(tileCaption.waitToExist(timeout: 10), "Retryable attachment tile caption did not appear")
        XCTAssertEqual(tile.label, "fail-attachment.png, upload failed, double-tap to retry")
        XCTAssertFalse(app.staticTexts["Remove or retry the failed attachment"].exists, "Tray-level failed caption appeared")
    }

    func testRemoveAttachmentRemovesOnlyTrayTile() throws {
        let app = launchFixture(with: fixture("attachment.png"))
        defer {
            audit(app, name: "attachment-remove")
            addScreenshot(named: "attachment-removed")
            app.terminate()
        }
        openLongSession(in: app)
        let tray = app.descendants(matching: .any).matching(identifier: "attachment-tray").firstMatch
        XCTAssertTrue(tray.waitToExist(timeout: 10), "Attachment tray did not appear")
        let tile = app.descendants(matching: .any).matching(identifier: "attachment-tile").firstMatch
        XCTAssertTrue(tile.waitToExist(timeout: 10), "Attachment tile did not appear")
        let remove = tile.descendants(matching: .button).firstMatch
        XCTAssertTrue(remove.waitToExist(timeout: 10), "Remove badge did not appear")
        remove.tap()
        XCTAssertTrue(waitForNonExistence(of: tray, timeout: 10), "Attachment tray remained after removing tile")
    }

    func testPhotosPickerUsesRealPicker() throws {
        let app = launchFixture()
        defer {
            audit(app, name: "attachment-photos")
            addScreenshot(named: "attachment-photos")
            app.terminate()
        }
        openLongSession(in: app)
        app.buttons["Add attachment"].tap()
        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitToExist(timeout: 5), "Photos menu item did not appear")
        photos.tap()
        addDebugDescription(app, named: "photos-picker-app-hierarchy")

        guard waitForPresentedPicker(in: app, timeout: 10) != nil else {
            XCTFail("Photos picker did not present in the app accessibility hierarchy within 10 seconds")
            return
        }

        // The transcript is itself a collection view behind the sheet, so skip it when looking for photo cells.
        let photoCell = app.collectionViews
            .matching(NSPredicate(format: "identifier != %@", "transcript-scroll"))
            .firstMatch.cells.firstMatch
        guard photoCell.waitToExist(timeout: 10) else {
            throw XCTSkip("Photos picker presented, but no photo cell was accessible through the app accessibility hierarchy")
        }
        photoCell.tap()
        let add = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add' OR label CONTAINS[c] 'Done'" )).firstMatch
        guard add.waitToExist(timeout: 5) else {
            throw XCTSkip("Photos picker presented and a photo cell was accessible, but its Add/Done control was not accessible")
        }
        add.tap()
        XCTAssertTrue(app.otherElements["attachment-tray"].waitToExist(timeout: 10), "Photos attachment was not added")
    }

    func testCameraPickerUsesSimulatorCamera() throws {
        let app = launchFixture()
        defer {
            audit(app, name: "attachment-camera")
            addScreenshot(named: "attachment-camera")
            app.terminate()
        }
        openLongSession(in: app)
        app.buttons["Add attachment"].tap()
        let camera = app.buttons["Camera"]
        XCTAssertTrue(camera.waitToExist(timeout: 5), "Camera menu item did not appear")
        camera.tap()

        let takePicture = app.buttons["Take Picture"]
        XCTAssertTrue(takePicture.waitToExist(timeout: 10), "Simulator camera UI did not appear")
        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.isHittable, "Simulator camera dismiss control was not hittable")
        dismiss.tap()
        XCTAssertTrue(waitForNonExistence(of: takePicture, timeout: 5), "Simulator camera UI did not dismiss")
    }

    func testFilesPickerUsesRealPicker() throws {
        let app = launchFixture()
        defer {
            audit(app, name: "attachment-files")
            addScreenshot(named: "attachment-files")
            app.terminate()
        }
        openLongSession(in: app)
        app.buttons["Add attachment"].tap()
        let files = app.buttons["Files"]
        XCTAssertTrue(files.waitToExist(timeout: 5), "Files menu item did not appear")
        files.tap()
        addDebugDescription(app, named: "files-picker-app-hierarchy")

        let pickerPresented = waitForPresentedPicker(in: app, timeout: 10) != nil
        XCTAssertTrue(pickerPresented, "Files picker did not present in the app accessibility hierarchy within 10 seconds")
        guard pickerPresented else { return }

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable, "Files picker Cancel control was not hittable")
        cancel.tap()
        XCTAssertTrue(waitForNonExistence(of: cancel, timeout: 5), "Files picker did not dismiss after tapping Cancel")
    }

    private func waitForPresentedPicker(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let cancel = app.buttons["Cancel"]
        while Date() < deadline {
            if app.navigationBars.count > 1 && cancel.exists {
                return app.navigationBars.element(boundBy: 1)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard app.navigationBars.count > 1 && cancel.exists else { return nil }
        return app.navigationBars.element(boundBy: 1)
    }

    private func addDebugDescription(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(data: Data(app.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchFixture(with path: String? = nil, openingSession: String? = nil) -> XCUIApplication {
        launchFixture(with: path.map { [$0] } ?? [], openingSession: openingSession)
    }

    private func launchFixture(with paths: [String], openingSession: String? = nil) -> XCUIApplication {
        let server = requiredRunnerVariable("TEST_RUNNER_SERVER_URL")
        let bearer = requiredRunnerVariable("TEST_RUNNER_BEARER")
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server, "-CCResetCache"]
        if let openingSession { app.launchArguments += ["-CCSession", openingSession] }
        for path in paths {
            app.launchArguments += ["-CCAttachFile", path]
        }
        app.launchEnvironment["CCAttachFile"] = paths.joined(separator: "\n")
        app.launchEnvironment["CCBearer"] = bearer
        configureLiveIndicatorAnimations(app)
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func openStaffSession(in app: XCUIApplication) {
        let row = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(row.waitToExist(timeout: 75), "Staff session did not load")
        row.tap()
        XCTAssertTrue(
            app.staticTexts["Staff Account Exclusions Atlas Monitoring"].waitToExist(timeout: 30),
            "Staff session did not open"
        )
    }

    private func openLongSession(in app: XCUIApplication) {
        let search = openSessionSearch(in: app)
        search.tap()
        search.typeText("Long session")
        let row = app.buttons["session-long-session"]
        XCTAssertTrue(row.waitToExist(timeout: 75), "Long session did not load")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch.waitToExist(timeout: 20), "Composer did not load")
    }

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }

    private func outputFile(_ name: String) -> URL {
        let root = ProcessInfo.processInfo.environment["CC_FLOW_OUTPUT_DIR"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private func audit(_ app: XCUIApplication, name: String) {
        do {
            try app.performAccessibilityAudit { issue in
                self.auditLines.append("\(name): \(issue)")
                return true
            }
        } catch {
            auditLines.append("\(name) audit failed: \(error)")
        }
    }

    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) { !element.exists }
    }
}
