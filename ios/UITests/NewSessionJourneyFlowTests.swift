import XCTest

/// Starting a session from nothing on the folded Duo, in one launch.
final class NewSessionJourneyFlowTests: JourneyTestCase {
    func testNewSessionJourney() async throws {
        // With no sessions, the empty state's button opens New session.
        try await postFixture("/fixture/clear-sessions")
        let app = launchSignedIn()
        defer { app.terminate() }
        let empty = app.buttons["empty-new-session"]
        XCTAssertTrue(empty.waitToExist(timeout: 30), "Empty state's button did not load")
        addScreenshot(named: "new-session-empty")
        empty.tap()
        let send = app.buttons["new-session-send"]
        XCTAssertTrue(send.waitToExist(timeout: 15), "New session did not open")
        XCTAssertTrue(app.staticTexts["new-session-title"].waitToExist(timeout: 15), "New session title did not load")
        XCTAssertFalse(app.buttons["Cancel"].exists, "Embedded new session showed a Cancel button")
        let folderChip = app.buttons["new-session-folder"]
        XCTAssertTrue(folderChip.waitToExist(timeout: 15), "Folder chip did not load")

        // The greeting uses the owner's name, and the composer sits on the keyboard.
        let greeting = app.staticTexts["new-session-greeting"]
        XCTAssertTrue(greeting.waitToExist(timeout: 15), "Greeting did not load")
        XCTAssertTrue(greeting.label.contains(", Alex") || greeting.label == "Hello, night owl", "Greeting did not use the owner's name: \(greeting.label)")
        let prompt = app.textFields["new-session-prompt"]
        XCTAssertTrue(prompt.waitToExist(timeout: 15), "Prompt did not load")
        XCTAssertTrue(prompt.placeholderValue?.hasPrefix("Chat with") == true, "Prompt's placeholder changed")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitToExist(timeout: 15), "Keyboard did not appear")
        let composer = app.element(identifier: "new-session-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10), "Composer card did not load")
        XCTAssertLessThanOrEqual(abs(composer.frame.maxY - keyboard.frame.minY), 40, "Composer was not attached to the keyboard")
        addScreenshot(named: "new-session-keyboard-up")
        greeting.tap()
        XCTAssertTrue(keyboard.waitToDisappear(timeout: 10), "Keyboard did not go away")
        addScreenshot(named: "new-session-keyboard-down")

        // The agent menu shows the default once, and picking it sends no agent.
        app.buttons["new-session-agent"].tap()
        let defaultAgent = app.buttons["new-session-agent-default"]
        XCTAssertTrue(defaultAgent.waitToExist(timeout: 10), "Default agent did not appear")
        XCTAssertTrue(defaultAgent.label.contains("Default"), "Default agent had no subtitle: \(defaultAgent.label)")
        XCTAssertFalse(app.buttons["new-session-agent-builder"].exists, "The resolved agent showed twice")
        defaultAgent.tap()

        // A recent folder is picked from the menu.
        folderChip.tap()
        let recent = app.buttons["new-session-folder-new-project-1"]
        XCTAssertTrue(recent.waitToExist(timeout: 10), "Recent folder did not load")
        addScreenshot(named: "new-session-folder-picker")
        recent.tap()
        XCTAssertTrue(send.waitToExist(timeout: 10), "Folder menu did not close")
        XCTAssertTrue(folderChip.label.contains("new-project-1"), "Folder chip did not follow the choice")

        // Other takes a typed path.
        folderChip.tap()
        let other = app.buttons["Other folder…"]
        XCTAssertTrue(other.waitToExist(timeout: 10), "Other folder did not appear")
        other.tap()
        let path = app.textFields["new-session-other-path"]
        XCTAssertTrue(path.waitToExist(timeout: 10), "Path field did not appear")
        path.tap()
        path.typeText("/tmp")
        XCTAssertEqual(path.value as? String, "/tmp")
        addScreenshot(named: "new-session-other-folder")
        app.buttons["Done"].tap()
        XCTAssertTrue(send.waitToExist(timeout: 10), "Other folder sheet did not close")
        XCTAssertTrue(folderChip.label.contains("tmp"), "Folder chip did not show the typed path")

        // An untrusted folder shows its error inline and leaves the form editable.
        try await postFixture("/fixture/new-session-error/untrusted_folder")
        prompt.tap()
        prompt.typeText("Try the untrusted folder")
        send.tap()
        let error = app.staticTexts["Open this folder in a terminal once and accept the trust prompt, then try again."]
        XCTAssertTrue(error.waitToExist(timeout: 15), "Untrusted folder's error did not show inline")
        addScreenshot(named: "new-session-error")
        XCTAssertTrue(send.isEnabled, "The form did not stay editable after the error")
        try await postFixture("/fixture/new-session-error/none")

        // Creating sends the folder and agent, opens the session, and the form remembers them.
        folderChip.tap()
        XCTAssertTrue(recent.waitToExist(timeout: 10), "Recent folder did not come back")
        recent.tap()
        app.buttons["new-session-agent"].tap()
        let reviewer = app.buttons["new-session-agent-reviewer"]
        XCTAssertTrue(reviewer.waitToExist(timeout: 10), "Reviewer agent did not load")
        reviewer.tap()
        send.tap()
        let title = app.selectedSessionName
        XCTAssertTrue(title.waitToExist(timeout: 30), "Created session did not open")
        XCTAssertEqual(title.label, "new-project-1")
        addScreenshot(named: "new-session-created")
        let requests = try await fixtureJSON("/fixture/create-requests")
        let latest = try XCTUnwrap((requests["requests"] as? [[String: Any]])?.last)
        XCTAssertTrue((latest["cwd"] as? String)?.hasSuffix("/projects/new-project-1") == true, "Create request had the wrong folder: \(latest)")
        XCTAssertEqual(latest["agent"] as? String, "reviewer")

        // A background session's details offer Open on Mac.
        app.buttons["session-info"].tap()
        for _ in 0..<4 { app.swipeUp() }
        let openOnMac = app.buttons["inspector-open-on-mac"]
        XCTAssertTrue(openOnMac.waitToExist(timeout: 15), "Open on Mac did not load")
        XCTAssertTrue(openOnMac.label.contains("Copy attach command"), "Open on Mac lost its command: \(openOnMac.label)")
        addScreenshot(named: "new-session-open-on-mac")
        openOnMac.tap()
        // The details are scrolled down by now, so a swipe on the content only scrolls them. The grabber closes the sheet.
        let grabber = app.buttons["Sheet Grabber"]
        for _ in 0..<3 where grabber.exists { grabber.swipeDown(); settle(1) }
        XCTAssertTrue(openOnMac.waitToDisappear(timeout: 10), "Details did not close")

        // Back on the list, New session opens again with those values, and Send doesn't crowd the agent chip.
        goBackToSessions(in: app)
        let newSession = app.buttons["new-session"]
        XCTAssertTrue(newSession.waitToExist(timeout: 15), "New session button did not come back")
        addScreenshot(named: "new-session-list-after-back")
        newSession.tap()
        XCTAssertTrue(folderChip.waitToExist(timeout: 15), "Folder chip did not load on reopening")
        XCTAssertTrue(folderChip.label.contains("new-project-1"), "Form forgot the folder")
        let agentChip = app.buttons["new-session-agent"]
        XCTAssertTrue(agentChip.label.contains("Reviewer"), "Form forgot the agent")
        XCTAssertFalse(send.frame.intersects(agentChip.frame), "Send overlapped the agent chip")
    }
}
