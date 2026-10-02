import XCTest

@MainActor
final class AttachmentFlowTests: XCTestCase {
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
        let app = launchFixture(with: [fixture("attachment.png"), fixture("evidence.csv")])
        defer {
            audit(app, name: "attachment-delivered-bubble")
            app.terminate()
        }
        openLongSession(in: app)

        let field = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Composer did not load")
        field.tap()
        field.typeText("delivered-attachment-flow-marker")
        app.buttons["composer-send"].tap()

        let pending = app.descendants(matching: .any).matching(identifier: "pending-prompt").firstMatch
        if pending.waitForExistence(timeout: 5) {
            XCTAssertTrue(waitForNonExistence(of: pending, timeout: 20), "Prompt attachment assertions ran against the pending bubble")
        }

        sleep(10)
        let marker = "delivered-attachment-flow-marker"
        let markerPredicate = NSPredicate(format: "label CONTAINS[c] %@", marker)
        let markerElements = app.descendants(matching: .any).matching(markerPredicate)
        let deliveredMarkerBubbles = app.descendants(matching: .any)
            .matching(identifier: "prompt-bubble")
            .matching(markerPredicate)
        let pendingMarkerBubbles = app.descendants(matching: .any)
            .matching(identifier: "pending-prompt-bubble")
            .matching(markerPredicate)
        print("Attachment marker counts: elements=\(markerElements.count), prompt-bubble=\(deliveredMarkerBubbles.count), pending-prompt-bubble=\(pendingMarkerBubbles.count)")
        if deliveredMarkerBubbles.count > 0, pendingMarkerBubbles.count > 0 {
            print("Duplicate attachment marker bubbles detected. Debug description excerpt:\n\(String(app.debugDescription.prefix(4000)))")
        }

        let bubbles = app.descendants(matching: .any).matching(identifier: "prompt-bubble")
        let markerBubbles = bubbles.matching(markerPredicate)
        XCTAssertTrue(markerBubbles.firstMatch.waitForExistence(timeout: 30), "Delivered prompt bubble did not appear")
        XCTAssertEqual(markerBubbles.count, 1, "Expected exactly one bubble to contain the delivered marker")
        let delivered = markerBubbles.firstMatch

        let image = delivered.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'attachment.png'"))
            .firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 30), "Delivered image attachment did not appear")
        XCTAssertEqual(image.label, "attachment.png, image")
        XCTAssertEqual(image.identifier, "prompt-attachment")
        XCTAssertEqual(image.value as? String, "loaded")

        let csv = delivered.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'evidence.csv'"))
            .firstMatch
        XCTAssertTrue(csv.waitForExistence(timeout: 30), "Delivered CSV attachment did not appear")
        XCTAssertEqual(csv.label, "evidence.csv, file")
        XCTAssertEqual(csv.identifier, "prompt-attachment")

        addScreenshot(named: "attachment-delivered-bubble")
        image.tap()

        let quickLook = app.otherElements["QLPreviewControllerView"]
        guard quickLook.waitForExistence(timeout: 15) else {
            XCTFail("Quick Look controller did not appear")
            return
        }

        let canvas = app.otherElements["Image canvas"]
        guard canvas.waitForExistence(timeout: 10) else {
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
        XCTAssertTrue(file.waitForExistence(timeout: 30), "Agent-sent review.png file did not appear")
        let imageTile = app.descendants(matching: .any).matching(identifier: "agent-file-image").firstMatch
        XCTAssertTrue(imageTile.waitForExistence(timeout: 10), "Agent-sent image tile did not appear")
        XCTAssertEqual(imageTile.frame.width, 277.0 * 280.0 / 600.0, accuracy: 1)
        XCTAssertEqual(imageTile.frame.height, 280, accuracy: 1)
        XCTAssertLessThan(imageTile.frame.width, 220)
        addScreenshot(named: "agent-sent-file-tile")
        file.tap()

        let quickLook = app.otherElements["QLPreviewControllerView"]
        guard quickLook.waitForExistence(timeout: 15) else {
            XCTFail("Quick Look controller did not appear for agent-sent file")
            return
        }

        let canvas = app.otherElements["Image canvas"]
        guard canvas.waitForExistence(timeout: 10) else {
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
        XCTAssertTrue(tray.waitForExistence(timeout: 10), "Attachment tray did not appear")
        let tile = app.descendants(matching: .any).matching(identifier: "attachment-tile").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "Attachment tile did not appear")
        let attached = NSPredicate(format: "label ENDSWITH[c] %@", "attached")
        expectation(for: attached, evaluatedWith: tile)
        waitForExpectations(timeout: 10)

        let field = app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch
        field.tap()
        field.typeText("attachment-flow-marker")
        app.buttons["composer-send"].tap()
        XCTAssertFalse(tray.waitForExistence(timeout: 15), "Attachment tray remained after send")
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
        XCTAssertTrue(tray.waitForExistence(timeout: 10), "Attachment tray did not appear")
        let csv = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'evidence.csv'")).firstMatch
        XCTAssertTrue(csv.waitForExistence(timeout: 10), "CSV attachment chip did not appear")
        let attached = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'attached'")).firstMatch
        XCTAssertTrue(attached.waitForExistence(timeout: 10), "PNG attachment did not finish uploading")
    }

    func testUploadWaitingStateShowsIndeterminateTile() throws {
        let slowPath = outputFile("slow-attachment.png")
        try FileManager.default.copyItem(atPath: fixture("attachment.png"), toPath: slowPath.path)
        defer { try? FileManager.default.removeItem(at: slowPath) }

        let app = launchFixture(with: slowPath.path)
        defer {
            audit(app, name: "attachment-upload-waiting")
            app.terminate()
        }
        openLongSession(in: app)

        let waiting = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'waiting for server'")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 3), "Upload did not reach the all-bytes-sent waiting state")
        addScreenshot(named: "attachment-upload-waiting")
    }

    func testTooLargeAttachmentShowsInlineRetryCaption() throws {
        let largePath = outputFile("too-large.bin")
        try Data(repeating: 0, count: 26 * 1024 * 1024).write(to: largePath)
        defer { try? FileManager.default.removeItem(at: largePath) }

        let app = launchFixture(with: largePath.path)
        defer {
            audit(app, name: "attachment-too-large")
            addScreenshot(named: "attachment-too-large")
            app.terminate()
        }
        openLongSession(in: app)

        let failed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'failed'")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "Too-large attachment did not fail")
        let tileCaption = app.staticTexts["Too large (max 25 MB)"]
        XCTAssertTrue(tileCaption.waitForExistence(timeout: 10), "Too-large attachment tile caption did not appear")
        app.buttons["composer-send"].tap()
        let caption = app.staticTexts["Remove the file that is too large"]
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "Too-large attachment caption did not appear")
        XCTAssertFalse(app.alerts["Action failed"].exists, "Blocked attachment send showed an alert")
    }

    func testFailedImageAttachmentShowsRetryCaption() throws {
        let failedPath = outputFile("fail-attachment.png")
        try FileManager.default.copyItem(atPath: fixture("attachment.png"), toPath: failedPath.path)
        defer { try? FileManager.default.removeItem(at: failedPath) }

        let app = launchFixture(with: failedPath.path)
        defer {
            audit(app, name: "attachment-failed-image")
            addScreenshot(named: "attachment-failed-image")
            app.terminate()
        }
        openLongSession(in: app)

        let failed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'failed'")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "Retryable image attachment did not fail")
        let tile = app.descendants(matching: .any).matching(identifier: "attachment-tile").firstMatch
        let badge = app.descendants(matching: .any).matching(identifier: "attachment-failure-badge").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "Retryable image failure badge did not appear")
        XCTAssertTrue(tile.frame.contains(badge.frame), "Failure badge frame \(badge.frame) was not inside tile frame \(tile.frame)")
        let tileCaption = app.staticTexts["Upload failed"]
        XCTAssertTrue(tileCaption.waitForExistence(timeout: 10), "Retryable attachment tile caption did not appear")
        let caption = app.staticTexts["Remove or retry the failed attachment"]
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "Retryable attachment caption did not appear")
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
        XCTAssertTrue(tray.waitForExistence(timeout: 10), "Attachment tray did not appear")
        let tile = app.descendants(matching: .any).matching(identifier: "attachment-tile").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "Attachment tile did not appear")
        let remove = tile.descendants(matching: .button).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "Remove badge did not appear")
        remove.tap()
        XCTAssertFalse(tray.waitForExistence(timeout: 10), "Attachment tray remained after removing tile")
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
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "Photos menu item did not appear")
        photos.tap()

        let picker = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        guard picker.wait(for: .runningForeground, timeout: 10) else {
            throw XCTSkip("PhotosPicker did not become foreground after tapping the real Photos menu item")
        }
        let image = picker.images.firstMatch
        guard image.waitForExistence(timeout: 10) else {
            throw XCTSkip("Could not reach a PhotosPicker image element through XCUITest")
        }
        image.tap()
        let add = picker.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add' OR label CONTAINS[c] 'Done'" )).firstMatch
        guard add.waitForExistence(timeout: 5) else {
            throw XCTSkip("PhotosPicker opened, but its out-of-process confirmation control was not accessible")
        }
        add.tap()
        XCTAssertTrue(app.otherElements["attachment-tray"].waitForExistence(timeout: 10), "Photos attachment was not added")
    }

    private func launchFixture(with path: String? = nil) -> XCUIApplication {
        launchFixture(with: path.map { [$0] } ?? [])
    }

    private func launchFixture(with paths: [String]) -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["TEST_RUNNER_SERVER_URL"] ?? "http://127.0.0.1:47832"
        let bearer = environment["TEST_RUNNER_BEARER"] ?? ""
        let app = XCUIApplication()
        app.launchArguments = ["-CCServer", server, "-CCResetCache"]
        for path in paths {
            app.launchArguments += ["-CCAttachFile", path]
        }
        app.launchEnvironment["CCAttachFile"] = paths.joined(separator: "\n")
        app.launchEnvironment["CCBearer"] = bearer
        dismissLeftoverNotificationPrompt()
        app.launch()
        return app
    }

    private func openStaffSession(in app: XCUIApplication) {
        let row = app.buttons["session-staff-account-exclusions"]
        XCTAssertTrue(row.waitForExistence(timeout: 75), "Staff session did not load")
        row.tap()
        XCTAssertTrue(
            app.staticTexts["Staff Account Exclusions Atlas Monitoring"].waitForExistence(timeout: 30),
            "Staff session did not open"
        )
    }

    private func openLongSession(in app: XCUIApplication) {
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15), "Session search did not load")
        searchButton.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Session search field did not load")
        search.tap()
        search.typeText("Long session")
        let row = app.buttons["session-long-session"]
        XCTAssertTrue(row.waitForExistence(timeout: 75), "Long session did not load")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer-text").firstMatch.waitForExistence(timeout: 20), "Composer did not load")
    }

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }

    private func outputFile(_ name: String) -> URL {
        let directory = ProcessInfo.processInfo.environment["CC_FLOW_OUTPUT_DIR"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
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
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
