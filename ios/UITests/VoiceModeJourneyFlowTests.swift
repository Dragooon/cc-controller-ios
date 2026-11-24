import XCTest

/// Voice mode against the fixture's voice routes: start it on a session, speak a turn (a silent test clip the
/// fixture "hears" as queued text), hear the agent's live turn spoken back, pause and resume, interrupt, see what the
/// agent puts on the stage, and end it. Needs a fixture daemon with voice routes (controller stockade-next, ad905bf
/// or later); the simulator has no mic, so the app runs with -CCVoiceTestAudio.
final class VoiceModeJourneyFlowTests: JourneyTestCase {
    private let session = "dune-part-three-imax-tickets"

    func testVoiceModeJourney() async throws {
        try await postFixture("/fixture/disable-live-event")
        let app = launchSignedIn(arguments: ["-CCVoiceTestAudio"])
        defer { app.terminate() }
        openSession(session, in: app)

        // The host has voice, so the session offers voice mode; starting it turns the agent's voice note on.
        let voiceButton = app.element(identifier: "voice-mode-button")
        XCTAssertTrue(voiceButton.waitToExist(timeout: 20), "The session had no voice mode button")
        voiceButton.tap()
        let status = app.element(identifier: "voice-status")
        XCTAssertTrue(status.waitToExist(timeout: 10), "Voice mode did not show its strip")
        XCTAssertTrue(pollUntil(timeout: 10) { status.label == "Listening" }, "Voice mode did not start listening: \(status.label)")
        let voiceOn = try await waitForFixtureRequest("POST /api/sessions/\(session)/voice")
        XCTAssertTrue(voiceOn, "Starting voice mode did not turn the session's voice note on")
        addScreenshot(named: "voice-listening")

        // A spoken turn: the host transcribes the clip and the turn goes in as a voice message.
        let spoken = "What time is the last IMAX screening tonight"
        try await postFixtureJSON("/fixture/voice/transcripts", body: ["texts": [spoken]])
        app.element(identifier: "voice-test-utterance").tap()
        let transcribed = try await waitForFixtureRequest("POST /api/voice/transcribe")
        XCTAssertTrue(transcribed, "The clip was not sent for transcription")
        let sent = try await waitForFixtureRequest("POST /api/sessions/\(session)/message", timeout: 15)
        XCTAssertTrue(sent, "The transcribed turn was not sent to the session")

        // The agent's turn is spoken: its text blocks go to the host's speech route and the strip says so.
        try await postFixtureJSON("/fixture/live-turn", body: ["prompt": spoken, "timeScale": 2])
        XCTAssertTrue(pollUntil(timeout: 60) { status.label == "Speaking" }, "The reply was not spoken: \(status.label)")
        let spokeAloud = try await fixtureRequestCount("POST /api/voice/speech")
        XCTAssertGreaterThan(spokeAloud, 0, "No reply text reached the host's speech route")
        XCTAssertTrue(app.element(identifier: "voice-conversation-line").waitToExist(timeout: 10), "The spoken sentence wasn't shown")
        addScreenshot(named: "voice-speaking")

        // Play/pause pauses the reply and mutes the mic, and resumes both.
        let playPause = app.element(identifier: "voice-play-pause")
        playPause.tap()
        XCTAssertTrue(pollUntil(timeout: 5) { status.label == "Paused" }, "Pause did not pause: \(status.label)")
        addScreenshot(named: "voice-paused")
        playPause.tap()
        XCTAssertTrue(pollUntil(timeout: 5) { status.label != "Paused" }, "Play did not resume")

        // Tapping the stage while it speaks cuts the reply.
        if status.label == "Speaking" {
            app.element(identifier: "voice-stage").tap()
            XCTAssertTrue(pollUntil(timeout: 5) { status.label != "Speaking" }, "Tapping the stage did not cut the reply")
        }

        // Once the agent's turn is over and voice mode is listening again, what the agent shows fills the stage:
        // markdown, then an image the host serves, which replaces it.
        XCTAssertTrue(pollUntil(timeout: 90) { status.label == "Listening" }, "Voice mode did not go back to listening: \(status.label)")
        try await postFixtureJSON("/fixture/stage", body: ["sessionId": session, "title": "Tonight's screenings", "markdown": "1. 7:00 PM\n2. 8:00 PM\n3. 9:30 PM"])
        XCTAssertTrue(app.staticText(containing: "Tonight's screenings").waitToExist(timeout: 15), "The stage did not show the agent's title")
        XCTAssertTrue(app.element(identifier: "voice-stage-markdown").waitToExist(timeout: 5), "The stage did not show the markdown")
        addScreenshot(named: "voice-stage-markdown")
        try await postFixtureJSON("/fixture/stage", body: ["sessionId": session, "title": "Getting there", "image": true])
        let loadedImage = app.element(identifier: "voice-stage-image-loaded")
        let failedImage = app.element(identifier: "voice-stage-image-failed")
        XCTAssertTrue(pollUntil(timeout: 20) { loadedImage.exists || failedImage.exists }, "The stage did not show the host's image")
        XCTAssertFalse(failedImage.exists, "The image failed to load: \(failedImage.label)")
        XCTAssertTrue(app.element(identifier: "voice-stage-history").waitToExist(timeout: 5), "Earlier stage items were not kept")
        addScreenshot(named: "voice-stage-image")

        // Screen off: in the background voice mode keeps the app running, and a reply that arrives then is spoken.
        let spokenBeforeBackground = try await fixtureRequestCount("POST /api/voice/speech")
        sendToBackground(app)
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(app.state, .runningBackground, "Voice mode let the app be suspended in the background")
        try await postFixtureJSON("/fixture/live-turn", body: ["prompt": "Is there parking near the cinema", "timeScale": 2])
        var spokenInBackground = spokenBeforeBackground
        let backgroundDeadline = Date().addingTimeInterval(60 * flowTimeScale())
        while spokenInBackground <= spokenBeforeBackground, Date() < backgroundDeadline {
            try await Task.sleep(for: .milliseconds(500))
            spokenInBackground = try await fixtureRequestCount("POST /api/voice/speech")
        }
        XCTAssertGreaterThan(spokenInBackground, spokenBeforeBackground, "A reply that arrived in the background was not spoken")
        XCTAssertEqual(app.state, .runningBackground, "The app was suspended while speaking in the background")
        app.activate()
        XCTAssertTrue(status.waitToExist(timeout: 10), "Voice mode was gone after coming back from the background")
        XCTAssertTrue(pollUntil(timeout: 90) { status.label == "Listening" }, "Voice mode did not carry on after the background: \(status.label)")

        // The chat is one tap away, and ending voice mode turns the note off.
        app.element(identifier: "voice-stage-toggle").tap()
        XCTAssertTrue(pollUntil(timeout: 5) { !app.element(identifier: "voice-stage").exists }, "Show chat did not collapse the stage")
        addScreenshot(named: "voice-collapsed")
        app.element(identifier: "voice-exit").tap()
        XCTAssertTrue(pollUntil(timeout: 5) { !status.exists }, "Ending voice mode left the strip up")
        let voiceCalls = try await fixtureRequestCount("POST /api/sessions/\(session)/voice")
        XCTAssertGreaterThanOrEqual(voiceCalls, 2, "Ending voice mode did not turn the note off")
    }
}
