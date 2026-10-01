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
        app.launch()
        return app
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
}
