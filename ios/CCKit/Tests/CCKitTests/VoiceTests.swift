import Foundation
import XCTest
@testable import CCKit

final class SpeakableTextTests: XCTestCase {
    func testMarkdownSymbolsGoAndEveryWordStays() {
        let markdown = """
        ## Plan

        **Restart** the `gateway` on [Mustafar](https://example.com).
        - First step
        - Second step: done

        ```bash
        npm test
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        That's it
        """
        XCTAssertEqual(
            SpeakableText.speakable(markdown),
            "Plan. Restart the gateway on Mustafar. First step. Second step: done. Code on screen. Table on screen. That's it."
        )
    }

    func testUnderscoresInsideWordsAreKept() {
        XCTAssertEqual(SpeakableText.speakable("Use snake_case_names and *emphasis* here"), "Use snake_case_names and emphasis here.")
    }

    func testNumberedListsKeepTheirNumbers() {
        XCTAssertEqual(SpeakableText.speakable("1. Boil water\n2) Add pasta"), "1. Boil water. 2. Add pasta.")
    }

    func testSentencesJoinShortFragmentsAndRespectAbbreviations() {
        XCTAssertEqual(
            SpeakableText.sentences("Done. The gateway restarted on Mustafar. Ok. It took about 2.5 seconds, e.g. quick."),
            ["Done. The gateway restarted on Mustafar.", "Ok. It took about 2.5 seconds, e.g. quick."]
        )
    }

    func testALongFirstSentenceIsCutAtCommas() {
        XCTAssertEqual(
            SpeakableText.sentences("I checked the logs on the gateway, the runner and the relay, and everything looks fine now.", firstChunkLimit: 40),
            ["I checked the logs on the gateway,", "the runner and the relay,", "and everything looks fine now."]
        )
    }

    func testSkipRepliesAreRecognised() {
        XCTAssertTrue(SpeakableText.isSkip("(skip)"))
        XCTAssertTrue(SpeakableText.isSkip(" (Skip). "))
        XCTAssertFalse(SpeakableText.isSkip("Skip the tests"))
    }
}

final class VoiceTurnTests: XCTestCase {
    private let policy = VoiceTurnPolicy()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testTrailingWordsHoldTheTurnOpen() {
        XCTAssertTrue(policy.endsMidThought("Restart the gateway and"))
        XCTAssertTrue(policy.endsMidThought("so, um"))
        XCTAssertTrue(policy.endsMidThought("I want to"))
        XCTAssertTrue(policy.endsMidThought("Check the logs, "))
        XCTAssertFalse(policy.endsMidThought("Restart the gateway."))
    }

    func testAFinishedThoughtIsSentAtOnce() {
        XCTAssertEqual(policy.decide(text: "Restart the gateway", speaking: false, transcribing: false, turnStartedAt: now, now: now), .send)
    }

    func testATrailingThoughtWaitsThreeSeconds() {
        XCTAssertEqual(
            policy.decide(text: "Restart the gateway and", speaking: false, transcribing: false, turnStartedAt: now, now: now),
            .hold(until: now.addingTimeInterval(3))
        )
    }

    func testSpeechInFlightKeepsTheTurnOpen() {
        XCTAssertEqual(policy.decide(text: "Restart", speaking: false, transcribing: true, turnStartedAt: now, now: now), .wait)
        XCTAssertEqual(policy.decide(text: "Restart the gateway", speaking: true, transcribing: false, turnStartedAt: now.addingTimeInterval(-1), now: now), .wait)
    }

    func testTheHoldNeverPassesTheMaximum() {
        XCTAssertEqual(
            policy.decide(text: "Restart the gateway", speaking: true, transcribing: false, turnStartedAt: now.addingTimeInterval(-9), now: now),
            .send
        )
        XCTAssertEqual(
            policy.decide(text: "and", speaking: false, transcribing: false, turnStartedAt: now.addingTimeInterval(-7), now: now),
            .hold(until: now.addingTimeInterval(1))
        )
        XCTAssertEqual(policy.decide(text: "and", speaking: false, transcribing: false, turnStartedAt: now.addingTimeInterval(-8), now: now), .send)
    }

    func testUtterancesJoinInOrder() {
        XCTAssertEqual(VoiceTurnPolicy.join(["Restart the gateway", " and then ", "", "rerun it"]), "Restart the gateway and then rerun it")
    }
}

final class VoiceEchoTests: XCTestCase {
    private let spoken = "I restarted the gateway on Mustafar and it is running now."

    func testTheReplyLeakingBackIsAnEcho() {
        XCTAssertTrue(VoiceEcho.isEcho(heard: "restarted the gateway on", spoken: spoken))
        XCTAssertFalse(VoiceEcho.isBargeIn(heard: "restarted the gateway on", spoken: spoken))
        XCTAssertTrue(VoiceEcho.isEcho(heard: "", spoken: spoken))
    }

    func testTwoNewWordsInterrupt() {
        XCTAssertTrue(VoiceEcho.isBargeIn(heard: "wait stop that", spoken: spoken))
        XCTAssertFalse(VoiceEcho.isEcho(heard: "wait stop that", spoken: spoken))
    }

    func testOneNewWordIsNotEnough() {
        XCTAssertEqual(VoiceEcho.newWords(heard: "the gateway pasta", spoken: spoken), 1)
        XCTAssertFalse(VoiceEcho.isBargeIn(heard: "the gateway pasta", spoken: spoken))
        XCTAssertTrue(VoiceEcho.isEcho(heard: "the gateway pasta", spoken: spoken))
    }
}

final class VoiceReplyTrackerTests: XCTestCase {
    private func stageEntry() throws -> TranscriptEntry {
        try JSONDecoder.ccKit().decode(TranscriptEntry.self, from: Data(#"{"kind":"stage","id":"s1","title":"Timing","mermaid":"graph TD; A-->B"}"#.utf8))
    }

    func testOnlyNewEntriesAreSpokenOnce() throws {
        let old = TranscriptEntry.assistant(AssistantEntry(id: "a1", text: "Old reply"))
        var tracker = VoiceReplyTracker(baseline: [old])
        let stage = try stageEntry()
        var entries: [TranscriptEntry] = [
            old,
            .prompt(PromptEntry(id: "p1", text: "Hi")),
            .tool(ToolEntry(id: "t1", tool: "Bash")),
            .assistant(AssistantEntry(id: "a2", text: "Hello there")),
            .assistant(AssistantEntry(id: "a3", text: "(skip)")),
            .assistant(AssistantEntry(id: "a4", text: "")),
            stage,
            .turnEnd(TurnEndEntry(id: "e1")),
        ]

        XCTAssertEqual(tracker.events(in: entries), [
            .speak(entryID: "assistant:a2", text: "Hello there"),
            .skip(entryID: "assistant:a3"),
            .stage(StageEntry(id: "s1", title: "Timing", content: .mermaid("graph TD; A-->B"))),
            .turnEnded(entryID: "turn_end:e1"),
        ])
        XCTAssertEqual(tracker.events(in: entries), [])

        entries[5] = .assistant(AssistantEntry(id: "a4", text: "Late text"))
        XCTAssertEqual(tracker.events(in: entries), [.speak(entryID: "assistant:a4", text: "Late text")])
    }

    func testStageEntriesDecodeEachKind() throws {
        XCTAssertEqual(try stageEntry().stage?.content, .mermaid("graph TD; A-->B"))
        let markdown = try JSONDecoder.ccKit().decode(TranscriptEntry.self, from: Data(#"{"kind":"stage","id":"s2","title":"Steps","markdown":"1. Boil"}"#.utf8))
        XCTAssertEqual(markdown.stage?.content, .markdown("1. Boil"))
        let image = try JSONDecoder.ccKit().decode(TranscriptEntry.self, from: Data(#"{"kind":"stage","id":"s3","title":"Photo","imageUrl":"/api/files/sess-1/diagram%20one.png"}"#.utf8))
        XCTAssertEqual(image.stage?.imageFile?.sessionID, "sess-1")
        XCTAssertEqual(image.stage?.imageFile?.name, "diagram one.png")
        XCTAssertNil(TranscriptEntry.assistant(AssistantEntry(id: "a", text: "x")).stage)
    }
}

final class VoiceAPITests: XCTestCase {
    func testCapabilitiesDecodeTolerantly() throws {
        let full = try JSONDecoder.ccKit().decode(VoiceCapabilities.self, from: Data(#"{"stt":{"available":true,"model":"Qwen"},"tts":{"available":true,"voices":["af_heart"]}}"#.utf8))
        XCTAssertTrue(full.isAvailable)
        XCTAssertEqual(full.tts.voices, ["af_heart"])
        let empty = try JSONDecoder.ccKit().decode(VoiceCapabilities.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isAvailable)
    }

    func testAVoiceMessageCarriesTheVoiceFlag() async throws {
        var bodies: [Data] = []
        VoiceStubProtocol.handler = { request in
            bodies.append(VoiceStubProtocol.bodyData(for: request) ?? Data())
            return VoiceStubProtocol.response(status: 200, body: Data(#"{"delivered":true}"#.utf8))
        }
        let client = makeClient()
        _ = try await client.message(sessionID: "session-1", text: "Hello", voice: true)
        _ = try await client.message(sessionID: "session-1", text: "Typed")

        let spoken = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        XCTAssertEqual(spoken["voice"] as? Bool, true)
        let typed = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        XCTAssertNil(typed["voice"])
    }

    func testTranscribeUploadsTheClipAsMultipart() async throws {
        var seen: URLRequest?
        var body = Data()
        VoiceStubProtocol.handler = { request in
            seen = request
            body = VoiceStubProtocol.bodyData(for: request) ?? Data()
            return VoiceStubProtocol.response(status: 200, body: Data(#"{"text":"  restart the gateway ","model":"Qwen","elapsedMs":210}"#.utf8))
        }
        let result = try await makeClient().transcribe(audio: Data([1, 2, 3]), filename: "u1.m4a", mimeType: "audio/mp4")

        XCTAssertEqual(result.text, "restart the gateway")
        XCTAssertEqual(result.elapsedMs, 210)
        XCTAssertEqual(seen?.url?.path, "/api/voice/transcribe")
        XCTAssertTrue(seen?.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#"name="audio"; filename="u1.m4a""#), text)
        XCTAssertTrue(text.contains("Content-Type: audio/mp4"), text)
        XCTAssertTrue(text.contains(#"name="language""#), text)
    }

    func testSpeechReturnsTheRawAudio() async throws {
        var json: [String: Any] = [:]
        VoiceStubProtocol.handler = { request in
            json = (try? JSONSerialization.jsonObject(with: VoiceStubProtocol.bodyData(for: request) ?? Data()) as? [String: Any]) ?? [:]
            XCTAssertEqual(request.url?.path, "/api/voice/speech")
            return VoiceStubProtocol.response(status: 200, body: Data([0, 1, 2, 3]))
        }
        let audio = try await makeClient().speech(text: "Hello.", voice: "af_heart")
        XCTAssertEqual(audio, Data([0, 1, 2, 3]))
        XCTAssertEqual(json["text"] as? String, "Hello.")
        XCTAssertEqual(json["voice"] as? String, "af_heart")
        XCTAssertNil(json["speed"])
        XCTAssertEqual(VoiceSpeechFormat.duration(ofBytes: 48_000), 1)
    }

    func testSessionVoiceUsesTheSessionRoute() async throws {
        VoiceStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-1/voice")
            XCTAssertEqual(request.httpMethod, "POST")
            return VoiceStubProtocol.response(status: 200, body: Data(#"{"voice":true}"#.utf8))
        }
        let result = try await makeClient().setSessionVoice(id: "session-1", on: true)
        XCTAssertTrue(result.voice)
    }

    private func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceStubProtocol.self]
        return APIClient(baseURL: URL(string: "http://localhost:47832")!, bearerToken: "token", session: URLSession(configuration: configuration))
    }
}

@MainActor
final class VoiceRecordingArchiveTests: XCTestCase {
    func testRecordingsPersistAndMatchTheirTurn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = VoiceRecordingArchive(directory: directory)
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).m4a")
        try Data(repeating: 7, count: 1_000).write(to: clip)

        let recording = VoiceRecording(id: "u1", controllerID: "mustafar", sessionID: "s1", createdAt: Date(timeIntervalSince1970: 10), durationMs: 1_200, fileName: "u1.m4a", mimeType: "audio/mp4")
        try archive.add(recording, movingFileAt: clip)
        archive.update(id: "u1") { $0.transcript = "restart the gateway"; $0.model = "Qwen" }
        archive.markTurn(ids: ["u1"], text: "restart the gateway")

        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertEqual(archive.totalBytes(), 1_000)

        let reopened = VoiceRecordingArchive(directory: directory)
        XCTAssertEqual(reopened.recordings(controllerID: "mustafar", sessionID: "s1", turnText: " restart the gateway ").map(\.id), ["u1"])
        XCTAssertEqual(reopened.recordings.first?.model, "Qwen")
        XCTAssertEqual(reopened.recordings(controllerID: "mac", sessionID: "s1"), [])

        reopened.deleteAll()
        XCTAssertEqual(reopened.recordings, [])
        XCTAssertEqual(reopened.allFileURLs(), [])
        XCTAssertEqual(VoiceRecordingArchive(directory: directory).recordings, [])
    }
}

private final class VoiceStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("No URLProtocol handler") }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func response(status: Int, body: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "http://localhost")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, body)
    }
    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
