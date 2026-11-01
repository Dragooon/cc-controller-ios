import XCTest

/// Attachments on the folded Duo: delivered, received, in the tray, failing, and the real pickers.
final class AttachmentsJourneyFlowTests: JourneyTestCase {
    func testAttachmentsJourney() async throws {
        // A staged PNG and CSV show in the tray, and a send carries them into a delivered bubble.
        var app = launchAttaching([fixture("attachment.png"), fixture("evidence.csv")], session: "long-session")
        defer { app.terminate() }
        let field = app.composer
        XCTAssertTrue(field.waitToExist(timeout: 20), "Composer did not load")
        let tray = app.element(identifier: "attachment-tray")
        XCTAssertTrue(tray.waitToExist(timeout: 10), "Attachment tray did not appear")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'evidence.csv'")).firstMatch.waitToExist(timeout: 10), "CSV chip did not appear")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'attached'")).firstMatch.waitToExist(timeout: 10), "PNG did not finish uploading")
        addScreenshot(named: "attachments-tray")
        let marker = "delivered-attachment-flow-marker"
        sendComposer(marker, in: app)
        XCTAssertTrue(tray.waitToDisappear(timeout: 15), "The tray stayed after the send")
        let pending = app.pendingPrompt(message: marker)
        if pending.waitToExist(timeout: 5) {
            XCTAssertTrue(pending.waitToDisappear(timeout: 20), "The pending bubble did not become delivered")
        }
        let bubbles = app.descendants(matching: .any)
            .matching(identifier: "prompt-bubble")
            .matching(NSPredicate(format: "label CONTAINS[c] %@", marker))
        XCTAssertTrue(bubbles.firstMatch.waitToExist(timeout: 30), "Delivered bubble did not appear")
        XCTAssertEqual(bubbles.count, 1, "The delivered message showed more than once")
        let delivered = bubbles.firstMatch
        let image = delivered.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'attachment.png'")).firstMatch
        XCTAssertTrue(image.waitToExist(timeout: 30), "Delivered image did not appear")
        XCTAssertEqual(image.label, "attachment.png, image")
        XCTAssertEqual(image.identifier, "prompt-attachment")
        XCTAssertEqual(image.value as? String, "loaded")
        let csv = delivered.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'evidence.csv'")).firstMatch
        XCTAssertTrue(csv.waitToExist(timeout: 30), "Delivered CSV did not appear")
        XCTAssertEqual(csv.label, "evidence.csv, file")
        XCTAssertEqual(csv.identifier, "prompt-attachment")
        addScreenshot(named: "attachments-delivered")

        // Images open in our own viewer, closed by a swipe; other files open in Quick Look.
        image.tap()
        let viewer = app.element(identifier: "image-preview-canvas")
        XCTAssertTrue(viewer.waitToExist(timeout: 15), "Image viewer did not appear")
        XCTAssertEqual(viewer.label, "attachment.png")
        viewer.swipeDown(velocity: .fast)
        XCTAssertTrue(viewer.waitToDisappear(timeout: 10), "A downward swipe did not close the image viewer")
        csv.tap()
        let quickLook = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(quickLook.waitToExist(timeout: 15), "Quick Look did not appear for the CSV")
        addScreenshot(named: "attachments-quick-look")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(quickLook.waitToDisappear(timeout: 10), "Done did not close Quick Look")

        // The real Photos picker presents and cancels. A run with no reachable photo can't go further.
        app.buttons["Add attachment"].tap()
        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitToExist(timeout: 5), "Photos did not appear in the menu")
        photos.tap()
        XCTAssertTrue(waitForPicker(in: app), "Photos picker did not present")
        addScreenshot(named: "attachments-photos")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitToDisappear(timeout: 5), "Photos picker did not close")

        // So does the real Files picker.
        app.buttons["Add attachment"].tap()
        let files = app.buttons["Files"]
        XCTAssertTrue(files.waitToExist(timeout: 5), "Files did not appear in the menu")
        files.tap()
        XCTAssertTrue(waitForPicker(in: app), "Files picker did not present")
        addScreenshot(named: "attachments-files")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable, "Files picker's Cancel could not be tapped")
        cancel.tap()
        XCTAssertTrue(cancel.waitToDisappear(timeout: 5), "Files picker did not close")
        goBackToSessions(in: app)

        // A file the agent sent shows at the image's own size, and opens in the viewer.
        openSession("staff-account-exclusions", in: app)
        let file = app.buttons["Open review.png"]
        XCTAssertTrue(file.waitToExist(timeout: 30), "Agent-sent review.png did not appear")
        let tile = app.element(identifier: "agent-file-image")
        XCTAssertTrue(tile.waitToExist(timeout: 10), "Agent-sent image tile did not appear")
        XCTAssertEqual(tile.frame.width, 277.0 * 280.0 / 600.0, accuracy: 1)
        XCTAssertEqual(tile.frame.height, 280, accuracy: 1)
        // The row is first measured with the 160 pt placeholder; once the image loads it must grow.
        let row = app.cells.containing(.any, identifier: "agent-file-image").firstMatch
        XCTAssertTrue(pollUntil(timeout: 10) { row.frame.height >= tile.frame.height - 1 }, "The row was not measured again for the loaded image")
        addScreenshot(named: "attachments-agent-file")
        file.tap()
        XCTAssertTrue(viewer.waitToExist(timeout: 15), "Image viewer did not appear for the agent's file")
        app.terminate()

        // A failed upload and a too-large file each explain themselves on their own tile, without blocking the other.
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let failedPath = scratch.appendingPathComponent("fail-attachment.png")
        try FileManager.default.copyItem(atPath: fixture("attachment.png"), toPath: failedPath.path)
        let largePath = scratch.appendingPathComponent("too-large.bin")
        try Data(repeating: 0, count: 26 * 1024 * 1024).write(to: largePath)
        app = launchAttaching([failedPath.path, largePath.path], session: "long-session")
        let retryCaption = app.staticTexts["Tap to retry"]
        XCTAssertTrue(retryCaption.waitToExist(timeout: 20), "Retryable failure had no caption")
        XCTAssertTrue(app.staticTexts["Too large (max 25 MB)"].waitToExist(timeout: 10), "Too-large file had no caption")
        let failedTile = app.descendants(matching: .any)
            .matching(identifier: "attachment-tile")
            .matching(NSPredicate(format: "label == %@", "fail-attachment.png, upload failed, double-tap to retry"))
            .firstMatch
        XCTAssertTrue(failedTile.waitToExist(timeout: 10), "Failed tile did not offer a retry")
        let badge = failedTile.descendants(matching: .any).matching(identifier: "attachment-failure-badge").firstMatch
        XCTAssertTrue(badge.waitToExist(timeout: 10), "Failed tile had no badge")
        XCTAssertTrue(failedTile.frame.contains(badge.frame), "Failure badge left its tile")
        addScreenshot(named: "attachments-failed")
        // A send is blocked by the tiles' own captions, with no alert or tray-level message.
        app.buttons["composer-send"].tap()
        XCTAssertFalse(app.staticTexts["Remove or retry the failed attachment"].exists, "A tray-level caption appeared")
        XCTAssertFalse(app.staticTexts["Remove the file that is too large"].exists, "A tray-level caption appeared")
        XCTAssertFalse(app.alerts["Action failed"].exists, "A blocked send showed an alert")

        // Removing one tile leaves the other.
        let tiles = app.descendants(matching: .any).matching(identifier: "attachment-tile")
        XCTAssertEqual(tiles.count, 2, "Expected both tiles in the tray")
        failedTile.descendants(matching: .button).firstMatch.tap()
        XCTAssertTrue(pollUntil(timeout: 10) { tiles.count == 1 }, "Removing a tile did not leave exactly the other one")
    }

    private func launchAttaching(_ paths: [String], session: String) -> XCUIApplication {
        launchSignedIn(
            session: session,
            arguments: paths.flatMap { ["-CCAttachFile", $0] },
            environment: ["CCAttachFile": paths.joined(separator: "\n")]
        )
    }

    private func waitForPicker(in app: XCUIApplication) -> Bool {
        let cancel = app.buttons["Cancel"]
        return pollUntil(timeout: 10) { app.navigationBars.count > 1 && cancel.exists }
    }

    private func fixture(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }

    private func scratchDirectory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["CC_FLOW_OUTPUT_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
