import Foundation
import XCTest
@testable import CCKit

@MainActor
final class AppStoreTests: XCTestCase {
    func testCacheWriteDebounceIsThirtySeconds() {
        XCTAssertEqual(AppStore.cacheWriteDebounce, .seconds(30))
    }

    func testBootstrapToLive() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" {
                return URLProtocolStub.json(Self.bootstrapJSON)
            }
            if request.url?.path == "/api/events" {
                let body = "event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\nevent: future\ndata: {}\n\n"
                return URLProtocolStub.json(Data(body.utf8), contentType: "text/event-stream")
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(app.lastUpdated)
        XCTAssertGreaterThanOrEqual(app.unknownEventCount, 1)
        app.apply(.connected)
        XCTAssertEqual(app.connection, .live)
        XCTAssertEqual(app.sessions["session-1"]?.state, .working)
        app.suspend()
        try await Task.sleep(for: .milliseconds(20))
    }

    func testReconnectBackoffSequenceUsesInjectedClock() async throws {
        URLProtocolStub.handler = { _ in URLProtocolStub.json(500, body: Data("{}".utf8)) }
        let clock = RecordingClock()
        let client = APIClient(baseURL: URL(string: "http://localhost:47832")!, session: URLProtocolStub.session)
        let stream = EventStream(client: client, session: URLProtocolStub.session, clock: clock)
        await stream.start()
        for _ in 0..<50 {
            if await clock.values().count >= 8 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await stream.stop()
        let delays = Array((await clock.values()).prefix(8))
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(15), .seconds(15)])
    }

    func testStreamDropRebootstrapsAfterBackoff() async throws {
        var bootstrapCalls = 0
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" {
                bootstrapCalls += 1
                return URLProtocolStub.json(Self.bootstrapJSON)
            }
            if request.url?.path == "/api/events" {
                let body = "event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\n"
                return URLProtocolStub.json(Data(body.utf8), contentType: "text/event-stream")
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.start()
        try await waitUntil { bootstrapCalls >= 1 }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThanOrEqual(bootstrapCalls, 2)
        app.suspend()
    }

    func testPlaceholderStateUsageDoesNotEraseKnownUsage() {
        let app = makeApp()
        let known = Self.session(state: .idle)
        var withUsage = known
        withUsage.usage = Usage(model: "claude-fable-5-1", totalInputTokens: 3_100_000, outputTokens: 84_000, cacheHitRate: 0.92)
        app.apply(.state(StateSnapshot(sessions: [withUsage], entries: ["session-1": 0])))
        var placeholder = known
        placeholder.usage = Usage()
        app.apply(.state(StateSnapshot(sessions: [placeholder], entries: ["session-1": 0])))
        XCTAssertEqual(app.sessions["session-1"]?.usage, withUsage.usage)
    }

    func testStateDeltaPresenceAndNullsFollowDaemonStateModel() async throws {
        let app = makeApp()
        let initial = Self.session(state: .working)
        var seeded = initial
        seeded.lastTool = "Bash"
        seeded.lastToolInput = .object(["command": .string("npm test")])
        seeded.toolRunning = true
        seeded.usage = Usage(model: "old", inputTokens: 10, outputTokens: 2)
        seeded.subagents = [Subagent(agentId: "agent-old", state: .done)]
        seeded.pending = [Approval(requestId: "request-old", sessionId: "session-1", toolName: "Bash")]
        app.apply(.state(StateSnapshot(sessions: [seeded], entries: ["session-1": 1])))

        let omitted = try XCTUnwrap(LiveEvent.decode(name: "state", data: "{\"sessionId\":\"session-1\",\"action\":\"still working\"}"))
        app.apply(omitted)
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"]?.lastTool, "Bash")
        XCTAssertEqual(app.sessions["session-1"]?.toolRunning, true)
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.first?.agentId, "agent-old")
        XCTAssertEqual(app.sessions["session-1"]?.pending?.first?.requestId, "request-old")

        let cleared = try XCTUnwrap(LiveEvent.decode(name: "state", data: "{\"sessionId\":\"session-1\",\"toolRunning\":false,\"lastTool\":null,\"lastToolInput\":null,\"pending\":[],\"usage\":{\"model\":\"new\",\"outputTokens\":3}}"))
        app.apply(cleared)
        try await settleCoalescedEvents()
        XCTAssertNil(app.sessions["session-1"]?.lastTool)
        XCTAssertNil(app.sessions["session-1"]?.lastToolInput)
        XCTAssertEqual(app.sessions["session-1"]?.toolRunning, false)
        XCTAssertEqual(app.sessions["session-1"]?.usage?.model, "new")
        XCTAssertNil(app.sessions["session-1"]?.usage?.inputTokens)
        XCTAssertEqual(app.sessions["session-1"]?.usage?.outputTokens, 3)
        XCTAssertEqual(app.sessions["session-1"]?.pending, [])

        let activity = try XCTUnwrap(LiveEvent.decode(name: "state", data: """
        {"sessionId":"session-1","shells":[{"toolUseId":"shell-1","description":"Run tests","command":"swift test","state":"running"}]}
        """))
        app.apply(activity)
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"]?.shells?.first?.toolUseId, "shell-1")
    }

    func testSuspendClosesStreamAndResumeRebootstraps() async throws {
        var bootstrapCalls = 0
        var eventRequests = 0
        URLProtocolStub.keepEvents = true
        defer { URLProtocolStub.keepEvents = false }
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" {
                bootstrapCalls += 1
                return URLProtocolStub.json(Self.bootstrapJSON)
            }
            if request.url?.path == "/api/events" { eventRequests += 1 }
            return URLProtocolStub.json(Data("{}".utf8), contentType: request.url?.path == "/api/events" ? "text/event-stream" : "application/json")
        }
        let app = makeApp()
        app.start()
        try await waitUntil { bootstrapCalls >= 1 && eventRequests >= 1 }
        app.suspend()
        let stoppedRequests = eventRequests
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(eventRequests, stoppedRequests)
        app.resume()
        try await waitUntil { bootstrapCalls >= 2 }
        app.suspend()
    }

    func testCreateOmitsModelWhenItMatchesDefault() async throws {
        var requestBody = Data()
        URLProtocolStub.handler = { request in
            requestBody = Self.bodyData(for: request)
            return URLProtocolStub.json(Data("{\"id\":\"new\",\"shortId\":\"new-short\",\"name\":\"New\"}".utf8))
        }
        let app = makeApp()
        _ = try await app.createSession(cwd: "/Users/test/project", model: "opus", defaultModel: "opus")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertEqual(object["cwd"] as? String, "/Users/test/project")
        XCTAssertNil(object["model"])
    }

    func testWaitForSessionObservesStateUntilTheIDAppears() async throws {
        var stateRequests = 0
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/state" {
                stateRequests += 1
                let body = stateRequests < 2
                    ? "{\"sessions\":[],\"entries\":{}}"
                    : "{\"sessions\":[{\"id\":\"session-2\",\"live\":true}],\"entries\":{}}"
                return URLProtocolStub.json(Data(body.utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        let appeared = await app.waitForSession("session-2", timeout: .milliseconds(1_200))
        XCTAssertTrue(appeared)
        XCTAssertNotNil(app.sessions["session-2"])
    }

    func testWaitForSessionFetchesStateAtMostOncePerSecond() async throws {
        var stateRequests = 0
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/state" { stateRequests += 1 }
            return URLProtocolStub.json(Data("{\"sessions\":[],\"entries\":{}}".utf8))
        }
        let app = makeApp()
        let appeared = await app.waitForSession("never", timeout: .milliseconds(2_100))
        XCTAssertFalse(appeared)
        XCTAssertLessThanOrEqual(stateRequests, 3)
    }

    func testWakeFlowMovesSessionIntoLiveState() async throws {
        var wakeCalled = false
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/sessions/sleep-1/wake" {
                wakeCalled = true
                return URLProtocolStub.json(Data("{\"id\":\"sleep-1\"}".utf8))
            }
            if request.url?.path == "/api/state" {
                return URLProtocolStub.json(Data("{\"sessions\":[{\"id\":\"sleep-1\",\"live\":true,\"state\":\"idle\"}],\"sleeping\":[]}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        let appeared = try await app.wakeSession(id: "sleep-1")
        XCTAssertTrue(appeared)
        XCTAssertTrue(wakeCalled)
        XCTAssertNotNil(app.sessions["sleep-1"])
    }

    func testStateEventAppliesSnapshot() {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 4])))
        XCTAssertEqual(app.sessions["session-1"]?.id, "session-1")
    }

    func testRegistryEventIsHandled() {
        let app = makeApp()
        app.apply(.registry(RegistryEvent(sessions: [])))
        XCTAssertTrue(app.sessions.isEmpty)
    }

    func testTranscriptEventMergesOpenSession() throws {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        _ = try XCTUnwrap(app.openSession("session-1"))
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: Self.entry(id: "event-entry"), entryCount: 1)))
        XCTAssertEqual(app.openSession("session-1")?.entries.first?.id, "event-entry")
    }

    func testLoadedStoreSurvivesSessionMissingFromState() throws {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 1])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        store.merge([Self.entry(id: "loaded")])

        app.apply(.state(StateSnapshot(sessions: [], entries: [:])))

        XCTAssertTrue(app.openSession("session-1") === store)
        XCTAssertFalse(store.session.live == true)
        XCTAssertEqual(store.entries.map(\.id), ["loaded"])
    }

    func testRegistryReconcileDoesNotRefetchWhenCountsMatch() async throws {
        var bootstrapCalls = 0
        URLProtocolStub.keepEvents = true
        URLProtocolStub.requestPaths = []
        defer {
            URLProtocolStub.keepEvents = false
            URLProtocolStub.requestPaths = []
        }
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/bootstrap":
                bootstrapCalls += 1
                return URLProtocolStub.json(Self.bootstrapJSON(entryCount: 1))
            case "/api/events":
                let body = "event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"idle\"}],\"entries\":{\"session-1\":1}}\n\n"
                return URLProtocolStub.json(Data(body.utf8), contentType: "text/event-stream")
            case "/api/sessions/session-1/transcript":
                return URLProtocolStub.json(Self.pageJSON(entries: [Self.entry(id: "loaded")], total: 1, hasMore: false))
            default:
                return URLProtocolStub.json(Data("{}".utf8))
            }
        }
        let app = makeApp()
        app.start()
        try await waitUntil { bootstrapCalls >= 1 && app.sessions["session-1"] != nil }
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil { store.isLoaded }
        let initialTranscriptRequests = URLProtocolStub.requestPaths.filter { $0.contains("/transcript") }.count

        app.apply(.registry(RegistryEvent(sessions: [])))
        try await waitUntil { bootstrapCalls >= 2 }
        try await Task.sleep(for: .milliseconds(50))

        let finalTranscriptRequests = URLProtocolStub.requestPaths.filter { $0.contains("/transcript") }.count
        XCTAssertEqual(finalTranscriptRequests, initialTranscriptRequests)
        app.suspend()
    }

    func testLiveAppendAfterTailBecomesNewestTurn() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/sessions/session-1/message" {
                return URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 1000])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        let tailStart = try JSONDecoder.ccKit().decode(
            Date.self,
            from: Data("\"2026-10-01T13:55:01.785Z\"".utf8)
        )
        let tail = (0..<200).flatMap { index -> [TranscriptEntry] in
            let promptDate = tailStart.addingTimeInterval(Double(index * 2))
            let assistantDate = promptDate.addingTimeInterval(1)
            return [
                .prompt(PromptEntry(id: "tail-prompt-\(index)", rev: index * 2, ts: promptDate, text: "Tail prompt \(index)")),
                .assistant(AssistantEntry(id: "tail-assistant-\(index)", rev: index * 2 + 1, ts: assistantDate, text: "Tail response \(index)")),
            ]
        }
        _ = store.merge(tail, entryCount: 1000)

        let marker = "root-cause-live-append"
        guard case .success = await app.send(text: marker, to: "session-1") else {
            XCTFail("Failed to create pending sent prompt")
            return
        }
        XCTAssertEqual(app.queuedNotes(for: "session-1").map(\.text), [marker])
        let promptTimestamp = app.queuedNotes(for: "session-1").first?.createdAt ?? Date()
        let rawEvent = """
        {"sessionId":"session-1","path":"/tmp/long-session.jsonl","entry":{"ts":"\(CCDateCoding.format(promptTimestamp))","kind":"prompt","origin":"device","text":"\(marker)","id":"synthetic:339c819273ef8130","rev":1038},"entryCount":1001,"replace":false}
        """
        let transcriptEvent = try JSONDecoder.ccKit().decode(
            TranscriptEvent.self,
            from: Data(rawEvent.utf8)
        )
        app.apply(.transcript(transcriptEvent))

        XCTAssertEqual(store.entries.last?.id, "synthetic:339c819273ef8130")
        XCTAssertEqual(store.turns.last?.prompts.first?.text, marker)
    }

    func testUsageEventReplacesUsageSnapshot() async throws {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        app.apply(.usage(UsageEvent(sessionId: "session-1", usage: Usage(model: "next", outputTokens: 3))))
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"]?.usage?.model, "next")
    }

    func testSubagentsEventReplacesSubagentSnapshot() async throws {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        app.apply(.subagents(SubagentsEvent(sessionId: "session-1", subagents: [Subagent(agentId: "agent-1", state: .running)])))
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.first?.agentId, "agent-1")
    }

    func testSubagentUpsertMergesAndOrdersNewestFirst() async throws {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        app.apply(.subagents(SubagentsEvent(sessionId: "session-1", subagents: [
            Subagent(agentId: "agent-old", state: .running, startedAt: older, toolUseId: "task-old"),
        ])))
        try await settleCoalescedEvents()
        app.apply(.subagent(SubagentEvent(sessionId: "session-1", subagents: [
            Subagent(agentId: "agent-new", state: .running, startedAt: newer, toolUseId: "task-new"),
            Subagent(agentId: "agent-old", state: .done, startedAt: older, toolUseId: "task-old"),
        ])))
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.map(\.toolUseId), ["task-new", "task-old"])
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.last?.state, .done)
    }

    func testNoOpSubagentUpsertDoesNotMutateSession() async throws {
        let app = makeApp()
        let existing = Subagent(agentId: "agent-1", state: .done, startedAt: Date(timeIntervalSince1970: 10), toolUseId: "task-1")
        app.apply(.state(StateSnapshot(sessions: [Self.session(subagents: [existing])], entries: ["session-1": 0])))
        let before = app.sessions["session-1"]
        app.apply(.subagent(SubagentEvent(sessionId: "session-1", subagents: [existing])))
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"], before)
    }

    func testSubagentUpsertToleratesDuplicateIdentities() async throws {
        let app = makeApp()
        let started = Date(timeIntervalSince1970: 10)
        let duplicate = Subagent(agentId: "agent-1", state: .running, startedAt: started)
        app.apply(.state(StateSnapshot(sessions: [Self.session(subagents: [duplicate, duplicate])], entries: ["session-1": 0])))
        app.apply(.subagent(SubagentEvent(sessionId: "session-1", subagents: [
            Subagent(agentId: "agent-1", state: .done, startedAt: started),
        ])))
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.count, 2)
        XCTAssertTrue(app.sessions["session-1"]?.subagents?.contains { $0.state == .done } == true)
    }

    func testFullSubagentsEventReplacesAfterUpsert() async throws {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        app.apply(.subagent(SubagentEvent(sessionId: "session-1", subagents: [Subagent(agentId: "agent-1", state: .running)])))
        try await settleCoalescedEvents()
        app.apply(.subagents(SubagentsEvent(sessionId: "session-1", subagents: [])))
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"]?.subagents, [])
    }

    func testApprovalModeUpdatesSessionFromModeRoute() async {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/sessions/session-1/mode" {
                return URLProtocolStub.json(Data("{\"mode\":\"terminal\"}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))

        let result = await app.setApprovalMode(sessionID: "session-1", mode: .terminal)

        guard case .success = result else {
            XCTFail("Approval mode request failed: \(result)")
            return
        }
        XCTAssertEqual(app.sessions["session-1"]?.mode, .terminal)
    }

    func testApprovalModeRejectsUnsupportedModeWithoutChangingSession() async {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))

        let result = await app.setApprovalMode(sessionID: "session-1", mode: .unknown("future"))

        guard case .failure(.invalid(let message)) = result else {
            XCTFail("Unsupported approval mode was accepted")
            return
        }
        XCTAssertEqual(message, "Approval mode is not supported.")
        XCTAssertNil(app.sessions["session-1"]?.mode)
    }

    func testApprovalModeFailureRevertsOptimisticSession() async {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/sessions/session-1/mode" {
                return URLProtocolStub.json(500, body: Data("{\"error\":\"mode failed\"}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        var session = Self.session()
        session.mode = .remote
        app.apply(.state(StateSnapshot(sessions: [session], entries: ["session-1": 0])))

        let result = await app.setApprovalMode(sessionID: "session-1", mode: .terminal)

        guard case .failure(.server(status: 500, message: "mode failed")) = result else {
            XCTFail("Mode failure was not surfaced as a server action error: \(result)")
            return
        }
        XCTAssertEqual(app.sessions["session-1"]?.mode, .remote)
    }

    func testApprovalEventAddsPendingApproval() {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        app.apply(.stateDelta(StateDelta(sessionId: "session-1", state: .working)))
        app.apply(.approval(ApprovalEvent(sessionId: "session-1", requestId: "request-1", toolName: "Bash")))
        XCTAssertEqual(app.approvals(for: "session-1").first?.requestId, "request-1")
    }

    func testDecisionEventRemovesPendingApproval() {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        app.apply(.approval(ApprovalEvent(sessionId: "session-1", requestId: "request-1")))
        app.apply(.decision(DecisionEvent(sessionId: "session-1", requestId: "request-1", behavior: .allow)))
        XCTAssertTrue(app.approvals.isEmpty)
    }

    func testFileEventDoesNotCreateDurableTranscriptEntry() {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        let store = app.openSession("session-1")
        app.apply(.file(FileEvent(sessionId: "session-1", name: "out.txt")))
        XCTAssertTrue(store?.entries.isEmpty == true)
    }

    func testDownloadFileDelegatesDownloadRoute() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/files/session-1/report.csv")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), nil)
            return URLProtocolStub.json(Data("a,b\n1,2\n".utf8), contentType: "text/csv")
        }
        let app = makeApp()
        let downloaded = try await app.downloadFile(sessionID: "session-1", name: "report.csv")
        XCTAssertEqual(downloaded.data, Data("a,b\n1,2\n".utf8))
        XCTAssertEqual(downloaded.mime, "text/csv")
    }

    func testSendCarriesAttachmentNamesAndThumbnailsIntoPendingNote() async {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-1/message")
            return URLProtocolStub.json(Data("{\"delivered\":false,\"queued\":true}".utf8))
        }
        let app = makeApp()
        let result = await app.send(
            text: "Inspect these files",
            attachments: ["attachment.png", "evidence.csv"],
            attachmentThumbnails: ["attachment.png": Data([1, 2, 3])],
            to: "session-1"
        )

        guard case .success = result else {
            XCTFail("Send failed: \(result)")
            return
        }
        let note = try! XCTUnwrap(app.queuedNotes(for: "session-1").first)
        XCTAssertEqual(note.text, "Inspect these files")
        XCTAssertTrue(note.queued)
        XCTAssertEqual(note.attachments, ["attachment.png", "evidence.csv"])
        XCTAssertEqual(note.attachmentThumbnails["attachment.png"], Data([1, 2, 3]))
    }

    func testEnqueueShowsSendingBeforeNetworkCompletesAndThenSends() async throws {
        let gate = DispatchSemaphore(value: 0)
        var requestBody = Data()
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                requestBody = Self.bodyData(for: request)
                gate.wait()
                return URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.setDraft("send now", for: "session-1")
        let sending = Task { @MainActor in await app.enqueueMessage(text: "send now", to: "session-1") }
        try await waitUntil { app.queuedNotes(for: "session-1").first?.state == .sending && !requestBody.isEmpty }
        let note = try XCTUnwrap(app.queuedNotes(for: "session-1").first)
        XCTAssertEqual(note.text, "send now")
        XCTAssertEqual(app.draft(for: "session-1"), "")
        let beforeNetwork = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertEqual(beforeNetwork["text"] as? String, "send now")
        gate.signal()
        guard case .success = await sending.value else { return XCTFail("Enqueue was rejected") }
        try await waitUntil { app.queuedNotes(for: "session-1").first?.state == .sent }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertEqual(body["clientMessageId"] as? String, note.id)
    }

    func testEnqueueFailurePreservesTextAndRetryUsesSameClientMessageID() async throws {
        var attempts = 0
        var clientMessageIDs: [String] = []
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                attempts += 1
                if let object = try? JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any],
                   let id = object["clientMessageId"] as? String { clientMessageIDs.append(id) }
                if attempts == 1 { return URLProtocolStub.json(500, body: Data("{\"error\":\"send failed\"}".utf8)) }
                return URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        guard case .success(let note) = await app.enqueueMessage(text: "keep this", to: "session-1") else { return XCTFail("Enqueue was rejected") }
        try await waitUntil {
            if case .failed = app.queuedNotes(for: "session-1").first?.state { return true }
            return false
        }
        XCTAssertEqual(app.queuedNotes(for: "session-1").first?.text, "keep this")
        XCTAssertTrue(app.retryNote(id: note.id, sessionID: "session-1"))
        try await waitUntil { app.queuedNotes(for: "session-1").first?.state == .sent }
        XCTAssertEqual(clientMessageIDs, [note.id, note.id])
    }

    func testEnqueueFailureFailsLaterNotesWithoutInvertingOrder() async throws {
        var messageTexts: [String] = []
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                let object = try? JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                messageTexts.append(object?["text"] as? String ?? "")
                return URLProtocolStub.json(500, body: Data("{\"error\":\"first failed\"}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        guard case .success = await app.enqueueMessage(text: "first", to: "session-1"),
              case .success = await app.enqueueMessage(text: "second", to: "session-1") else { return XCTFail("Enqueue was rejected") }
        try await waitUntil { app.queuedNotes(for: "session-1").allSatisfy { if case .failed = $0.state { return true }; return false } }
        XCTAssertEqual(messageTexts, ["first"])
        XCTAssertEqual(app.queuedNotes(for: "session-1").map(\.text), ["first", "second"])
        if case .failed(let message) = app.queuedNotes(for: "session-1")[1].state {
            XCTAssertEqual(message, "An earlier message did not send.")
        } else {
            XCTFail("The later note was not failed")
        }
    }

    func testQueuedNotePersistenceFailsSendingAndDropsOldNotes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = QueuedNote(id: "current", text: "current", state: .sending, createdAt: now, attachmentThumbnails: ["image.png": Data([1])])
        let old = QueuedNote(id: "old", text: "old", state: .sent, createdAt: now.addingTimeInterval(-8 * 24 * 60 * 60))
        QueuedNoteCache(directory: directory, clock: FixedClock(now: now)).saveNow(["session-1": [current, old]])
        let app = AppStore(serverURL: URL(string: "http://localhost:47832")!, bearerProvider: { "token" }, session: URLProtocolStub.session, clock: FixedClock(now: now), cacheDirectory: directory)
        XCTAssertEqual(app.queuedNotes(for: "session-1").map(\.id), ["current"])
        XCTAssertEqual(app.queuedNotes(for: "session-1").first?.state, .failed(message: "The app closed before this message was sent."))
        XCTAssertTrue(app.queuedNotes(for: "session-1").first?.attachmentThumbnails.isEmpty == true)
    }

    func testFailedNoteReconcilesWhenItsPromptArrives() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let note = QueuedNote(id: "failed", text: "retry me", state: .failed(message: "offline"), createdAt: timestamp)
        let prompt = TranscriptEntry.prompt(PromptEntry(ts: timestamp.addingTimeInterval(1), text: "retry me"))
        XCTAssertTrue(reconcileQueuedNote([note], promptEntry: prompt).isEmpty)
    }

    func testBatchedPromptReconcilesTwoNotes() {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let notes = [
            QueuedNote(id: "first", text: "first", state: .queued, createdAt: sentAt, sentAt: sentAt),
            QueuedNote(id: "second", text: "second", state: .queued, createdAt: sentAt.addingTimeInterval(1), sentAt: sentAt.addingTimeInterval(1)),
        ]
        let prompt = TranscriptEntry.prompt(PromptEntry(ts: sentAt.addingTimeInterval(2), text: "first\nsecond"))

        XCTAssertTrue(reconcileQueuedNote(notes, promptEntry: prompt).isEmpty)
    }

    func testBatchedPromptReconcilesThreeNotesInSendOrder() {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let notes = [
            QueuedNote(id: "first", text: "first", state: .queued, createdAt: sentAt, sentAt: sentAt),
            QueuedNote(id: "second", text: "second", state: .queued, createdAt: sentAt.addingTimeInterval(1), sentAt: sentAt.addingTimeInterval(1)),
            QueuedNote(id: "third", text: "third", state: .queued, createdAt: sentAt.addingTimeInterval(2), sentAt: sentAt.addingTimeInterval(2)),
        ]
        let prompt = TranscriptEntry.prompt(PromptEntry(ts: sentAt.addingTimeInterval(3), text: "first\nsecond\nthird"))

        XCTAssertTrue(reconcileQueuedNote(notes, promptEntry: prompt).isEmpty)
    }

    func testContainmentDoesNotMatchAnUnrelatedLongerPrompt() {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let note = QueuedNote(id: "note", text: "fix", state: .queued, createdAt: sentAt, sentAt: sentAt)
        let prompt = TranscriptEntry.prompt(PromptEntry(ts: sentAt.addingTimeInterval(1), text: "prefix"))

        XCTAssertEqual(reconcileQueuedNote([note], promptEntry: prompt).map(\.id), ["note"])
    }

    func testContainmentRequiresPromptAfterNoteWasSent() {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let note = QueuedNote(id: "note", text: "same", state: .queued, createdAt: sentAt.addingTimeInterval(-1), sentAt: sentAt)
        let prompt = TranscriptEntry.prompt(PromptEntry(ts: sentAt.addingTimeInterval(-1), text: "other\nsame"))

        XCTAssertEqual(reconcileQueuedNote([note], promptEntry: prompt).map(\.id), ["note"])
    }

    func testEditRestoresDraftAndDeleteRemovesNote() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true { return URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8)) }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        guard case .success(let note) = await app.enqueueMessage(text: "edit me", to: "session-1") else { return XCTFail("Enqueue was rejected") }
        try await waitUntil { app.queuedNotes(for: "session-1").first?.state == .sent }
        app.setDraft("existing", for: "session-1")
        XCTAssertTrue(app.editNote(id: note.id, sessionID: "session-1"))
        XCTAssertEqual(app.draft(for: "session-1"), "edit me\n\nexisting")
        XCTAssertTrue(app.queuedNotes(for: "session-1").isEmpty)
        guard case .success(let second) = await app.enqueueMessage(text: "delete me", to: "session-1") else { return XCTFail("Enqueue was rejected") }
        XCTAssertTrue(app.deleteNote(id: second.id, sessionID: "session-1"))
        XCTAssertTrue(app.queuedNotes(for: "session-1").isEmpty)
    }

    func testDismissedNoteDoesNotReturnAfterStoreRecreation() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                return URLProtocolStub.json(Data("{\"delivered\":false,\"queued\":true}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = makeApp(cacheDirectory: directory)
        guard case .success(let note) = await app.enqueueMessage(text: "dismiss me", to: "session-1") else {
            return XCTFail("Enqueue was rejected")
        }
        XCTAssertTrue(app.deleteNote(id: note.id, sessionID: "session-1"))

        let restored = makeApp(cacheDirectory: directory)
        XCTAssertTrue(restored.queuedNotes(for: "session-1").isEmpty)
    }

    func testSendAgainUsesFreshIDForSentNote() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true { return URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8)) }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        guard case .success(let original) = await app.enqueueMessage(text: "again", to: "session-1") else { return XCTFail("Enqueue was rejected") }
        try await waitUntil { app.queuedNotes(for: "session-1").first?.state == .sent }
        let replacement = try XCTUnwrap(app.sendAgain(id: original.id, sessionID: "session-1"))
        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.text, original.text)
    }

    func testNoteNeedsAttentionForPendingNotesAfterTimeouts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sent = QueuedNote(text: "sent", state: .sent, createdAt: now, sentAt: now.addingTimeInterval(-31))
        XCTAssertTrue(noteNeedsAttention(note: sent, sessionState: .idle, now: now))
        XCTAssertFalse(noteNeedsAttention(note: sent, sessionState: .working, now: now))
        let queued = QueuedNote(text: "queued", state: .queued, createdAt: now, sentAt: now.addingTimeInterval(-31))
        XCTAssertTrue(noteNeedsAttention(note: queued, sessionState: .idle, now: now))
        XCTAssertFalse(noteNeedsAttention(note: queued, sessionState: .working, now: now))

        let workingSent = QueuedNote(text: "working sent", state: .sent, createdAt: now, sentAt: now.addingTimeInterval(-10 * 60))
        XCTAssertTrue(noteNeedsAttention(note: workingSent, sessionState: .working, now: now))
        let workingQueued = QueuedNote(text: "working queued", state: .queued, createdAt: now, sentAt: now.addingTimeInterval(-10 * 60))
        XCTAssertTrue(noteNeedsAttention(note: workingQueued, sessionState: .working, now: now))
    }

    func testDraftPersistsAndRestoresAcrossStoreRecreation() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = makeApp(cacheDirectory: directory)
        app.setDraft("unfinished work", for: "session-1")
        app.suspend()

        let restored = makeApp(cacheDirectory: directory)
        XCTAssertEqual(restored.draft(for: "session-1"), "unfinished work")
    }

    func testDraftClearsOnlyAfterSuccessfulSend() async {
        URLProtocolStub.handler = { _ in URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8)) }
        let app = makeApp()
        app.setDraft("send this", for: "session-1")

        guard case .success = await app.sendComposer(text: "send this", to: "session-1") else {
            return XCTFail("Successful send was rejected")
        }
        XCTAssertEqual(app.draft(for: "session-1"), "")
    }

    func testDraftStaysAfterFailedSend() async {
        URLProtocolStub.handler = { _ in URLProtocolStub.json(500, body: Data("{\"error\":\"send failed\"}".utf8)) }
        let app = makeApp()
        app.setDraft("keep this", for: "session-1")

        guard case .failure = await app.sendComposer(text: "keep this", to: "session-1") else {
            return XCTFail("Failed send unexpectedly succeeded")
        }
        XCTAssertEqual(app.draft(for: "session-1"), "keep this")
    }

    func testSuccessfulSendDoesNotClearNewerDraftText() async {
        URLProtocolStub.handler = { _ in URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8)) }
        let app = makeApp()
        app.setDraft("send this plus newer text", for: "session-1")

        guard case .success = await app.sendComposer(text: " send this ", to: "session-1") else {
            return XCTFail("Successful send was rejected")
        }
        XCTAssertEqual(app.draft(for: "session-1"), "send this plus newer text")
    }

    func testQueuedNoteClearsViaRefetchGap() async throws {
        let createdAt = Date()
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                return URLProtocolStub.json(Data("{\"delivered\":false,\"queued\":true}".utf8))
            }
            if request.url?.path.hasSuffix("/transcript") == true {
                return URLProtocolStub.json(Self.promptJSON(text: "gap delivery", timestamp: createdAt))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        for _ in 0..<20 {
            if store.isLoaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.isLoaded)
        try await Task.sleep(for: .milliseconds(50))
        _ = await app.send(text: "gap delivery", to: "session-1")
        try await store.refetchGap(limit: 1)
        XCTAssertTrue(app.queuedNotes(for: "session-1").isEmpty)
    }

    func testQueuedNoteClearsViaLoadInitial() async throws {
        let createdAt = Date()
        var loadCount = 0
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                return URLProtocolStub.json(Data("{\"delivered\":false,\"queued\":true}".utf8))
            }
            if request.url?.path.hasSuffix("/transcript") == true {
                loadCount += 1
                if loadCount > 1 { return URLProtocolStub.json(Self.promptJSON(text: "initial delivery", timestamp: createdAt)) }
                return URLProtocolStub.json(Self.entriesJSON([]))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        for _ in 0..<20 where !store.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        _ = await app.send(text: "initial delivery", to: "session-1")
        try await store.loadInitial()
        XCTAssertTrue(app.queuedNotes(for: "session-1").isEmpty)
    }

    func testOlderIdenticalPromptDoesNotClearQueuedNote() async {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                return URLProtocolStub.json(Data("{\"delivered\":false,\"queued\":true}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        _ = app.openSession("session-1")
        _ = await app.send(text: "same text", to: "session-1")
        let oldPrompt = TranscriptEntry.prompt(PromptEntry(ts: Date(timeIntervalSinceNow: -10), text: "same text"))
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: oldPrompt)))

        XCTAssertEqual(app.queuedNotes(for: "session-1").map(\.text), ["same text"])
    }

    func testEntryCountGapRefetchesOnlyGapPlusMargin() {
        XCTAssertEqual(AppStore.gapFetchLimit(missing: 12), 32)
        XCTAssertEqual(AppStore.gapFetchLimit(missing: 600), 400)
    }

    func testClearFollowSwitchesToLiveSessionWithSamePidWithinWindow() {
        let missingAt = Date(timeIntervalSince1970: 100)
        let previous = ["old": Session(id: "old", pid: 42, live: true)]
        let current = ["new": Session(id: "new", pid: 42, live: true)]

        XCTAssertEqual(
            AppStore.replacementSessionID(
                missingSessionID: "old",
                previousSessions: previous,
                currentSessions: current,
                missingAt: missingAt,
                now: missingAt.addingTimeInterval(3)
            ),
            "new"
        )
    }

    func testClearFollowDoesNotSwitchToDifferentPid() {
        let missingAt = Date(timeIntervalSince1970: 100)
        let previous = ["old": Session(id: "old", pid: 42, live: true)]
        let current = ["other": Session(id: "other", pid: 99, live: true)]

        XCTAssertNil(
            AppStore.replacementSessionID(
                missingSessionID: "old",
                previousSessions: previous,
                currentSessions: current,
                missingAt: missingAt,
                now: missingAt.addingTimeInterval(3)
            )
        )
    }

    func testClearFollowDoesNotSwitchAfterTimeout() {
        let missingAt = Date(timeIntervalSince1970: 100)
        let previous = ["old": Session(id: "old", pid: 42, live: true)]
        let current = ["new": Session(id: "new", pid: 42, live: true)]

        XCTAssertNil(
            AppStore.replacementSessionID(
                missingSessionID: "old",
                previousSessions: previous,
                currentSessions: current,
                missingAt: missingAt,
                now: missingAt.addingTimeInterval(10.1)
            )
        )
    }

    func testCommandRouteDecodesOnSession() throws {
        let data = Data("{\"id\":\"session-1\",\"pid\":42,\"live\":true,\"commandRoute\":\"mod\"}".utf8)
        let session = try JSONDecoder.ccKit().decode(Session.self, from: data)
        XCTAssertEqual(session.commandRoute, "mod")
    }

    func testEveryContractEventUpdatesTheRightState() async throws {
        let app = makeApp()
        let session = Self.session(state: .working)
        app.apply(.state(StateSnapshot(sessions: [session], entries: ["session-1": 0])))
        app.apply(.stateDelta(StateDelta(sessionId: "session-1", state: .needsYou, action: "Needs your attention")))
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"]?.state, .needsYou)

        app.apply(.usage(UsageEvent(sessionId: "session-1", usage: Usage(model: "fable", outputTokens: 7))))
        app.apply(.subagents(SubagentsEvent(sessionId: "session-1", subagents: [Subagent(agentId: "agent-1", state: .running)])))
        try await settleCoalescedEvents()
        XCTAssertEqual(app.sessions["session-1"]?.usage?.outputTokens, 7)
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.first?.agentId, "agent-1")

        let approval = ApprovalEvent(sessionId: "session-1", requestId: "request-1", toolName: "Bash", status: .remote)
        app.apply(.approval(approval))
        XCTAssertEqual(app.approvals(for: "session-1").map(\.requestId), ["request-1"])
        app.apply(.decision(DecisionEvent(sessionId: "session-1", requestId: "request-1", behavior: .allow)))
        XCTAssertTrue(app.approvals.isEmpty)
        app.apply(.file(FileEvent(sessionId: "session-1", name: "out.txt")))
        app.apply(.connected)
        XCTAssertEqual(app.connection, .live)
        app.apply(.registry(RegistryEvent(sessions: [])))
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: .assistant(AssistantEntry(id: "entry-1", rev: 1, text: "hello")))))
    }

    func testStartedAtChangeDropsOpenTranscript() async throws {
        var bootstrapCalls = 0
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" {
                bootstrapCalls += 1
                return URLProtocolStub.json(Self.bootstrapJSON(startedAt: Date(timeIntervalSince1970: Double(bootstrapCalls))))
            }
            if request.url?.path == "/api/events" {
                let body = "event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\nevent: future\ndata: {}\n\n"
                return URLProtocolStub.json(Data(body.utf8), contentType: "text/event-stream")
            }
            return URLProtocolStub.json(Self.pageJSON(entries: [Self.entry(id: "new")], total: 1, hasMore: false))
        }
        let app = makeApp()
        app.start()
        try await waitUntil { bootstrapCalls >= 1 && app.sessions["session-1"] != nil }
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil { store.isLoaded }
        store.merge([Self.entry(id: "old")])
        app.resume()
        try await waitUntil { bootstrapCalls >= 2 && store.entries.contains(where: { $0.id == "new" }) }
        XCTAssertFalse(store.entries.contains(where: { $0.id == "old" }))
        app.suspend()
    }

    func testColdStartLoadsDiskCacheBeforeLiveBootstrap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = DiskCache(directory: directory)
        let cached = DiskCacheState(bootstrap: Bootstrap(apiVersion: 2, daemon: DaemonInfo(version: "cached"), state: StateSnapshot(sessions: [Self.session()], entries: ["session-1": 1])), transcripts: ["session-1": [Self.entry(id: "cached-entry")]], updatedAt: Date(timeIntervalSince1970: 10))
        await cache.save(cached)
        await cache.flush()
        URLProtocolStub.keepEvents = false
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            if request.url?.path == "/api/events" {
                let body = "event: state\ndata: {\"sessions\":[],\"entries\":{}}\n\n"
                return URLProtocolStub.json(Data(body.utf8), contentType: "text/event-stream")
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = AppStore(serverURL: URL(string: "http://localhost:47832")!, bearerProvider: {
            try await Task.sleep(for: .milliseconds(150))
            return "test-token"
        }, session: URLProtocolStub.session, cacheDirectory: directory)
        app.start()
        try await waitUntil { if case .offline(let updated, _) = app.connection { return updated != nil }; return false }
        XCTAssertEqual(app.sessions["session-1"]?.name, "Fixture")
        app.apply(.connected)
        XCTAssertEqual(app.connection, .live)
        app.suspend()
    }

    func testClosingStoreFlushesTranscriptCacheWithoutDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        URLProtocolStub.keepEvents = true
        defer { URLProtocolStub.keepEvents = false }
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            if request.url?.path == "/api/events" { return URLProtocolStub.json(Data(), contentType: "text/event-stream") }
            if request.url?.path.hasSuffix("/transcript") == true { return URLProtocolStub.json(Self.entriesJSON([])) }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp(cacheDirectory: directory)
        app.start()
        try await waitUntil { app.lastUpdated != nil && app.sessions["session-1"] != nil }
        let store = try XCTUnwrap(app.openSession("session-1"))
        store.merge([Self.entry(id: "closed-entry")])
        app.closeSession("session-1")
        for _ in 0..<50 {
            if (try? await DiskCache(directory: directory).load()?.transcripts["session-1"]?.contains(where: { $0.id == "closed-entry" })) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let loaded = try await DiskCache(directory: directory).load()
        XCTAssertEqual(loaded?.transcripts["session-1"]?.first?.id, "closed-entry")
        app.suspend()
    }

    func testBootstrapDecodeFailureUsesUnreadableOfflineState() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" {
                return URLProtocolStub.json(Data("{\"state\":{\"sessions\":[{\"id\":123}]}}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.start()
        try await waitUntil {
            if case .offlineUnreadable(_, let error) = app.connection { return error?.contains("state.sessions[0].id") == true }
            return false
        }
        app.suspend()
    }

    func testUnauthorizedBootstrapIsExplicitOfflineState() async throws {
        URLProtocolStub.handler = { _ in URLProtocolStub.json(401, body: Data("{\"error\":\"Authentication required\"}".utf8)) }
        let app = makeApp()
        app.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(app.connection, .unauthorized)
        app.suspend()
    }

    private static func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
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

    private func settleCoalescedEvents() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<50 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for app state")
    }

    private func makeApp() -> AppStore {
        makeApp(cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func makeApp(cacheDirectory: URL) -> AppStore {
        AppStore(
            serverURL: URL(string: "http://localhost:47832")!,
            bearerProvider: { "test-token" },
            session: URLProtocolStub.session,
            cacheDirectory: cacheDirectory
        )
    }

    private static func session(state: SessionState = .idle, subagents: [Subagent]? = nil) -> Session {
        Session(id: "session-1", name: "Fixture", live: true, state: state, usage: Usage(), subagents: subagents)
    }

    private static func entry(id: String) -> TranscriptEntry {
        .assistant(AssistantEntry(id: id, rev: 1, ts: Date(timeIntervalSince1970: Double(id == "first" ? 1 : 2)), text: id))
    }

    private static let bootstrapJSON = bootstrapJSON()

    private static func bootstrapJSON(startedAt: Date = Date(timeIntervalSince1970: 1), entryCount: Int = 0) -> Data {
        let value = Bootstrap(apiVersion: 2, daemon: DaemonInfo(version: "fixture", startedAt: startedAt), capabilities: Capabilities(pagination: true), state: StateSnapshot(sessions: [session(state: .working)], entries: ["session-1": entryCount]))
        return try! JSONEncoder.ccKit().encode(value)
    }

    private static func pageJSON(entries: [TranscriptEntry], total: Int, hasMore: Bool) -> Data {
        try! JSONEncoder.ccKit().encode(TranscriptPage(entries: entries, total: total, hasMore: hasMore))
    }

    private static func entriesJSON(_ entries: [TranscriptEntry]) -> Data {
        try! JSONEncoder.ccKit().encode(entries)
    }

    private static func promptJSON(text: String, timestamp: Date) -> Data {
        Data("[{\"kind\":\"prompt\",\"ts\":\"\(CCDateCoding.format(timestamp))\",\"text\":\"\(text)\"}]".utf8)
    }
}

private struct FixedClock: CCKitClock {
    let now: Date

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}

private actor RecordingClock: CCKitClock {
    nonisolated let now = Date(timeIntervalSince1970: 1)
    private var recorded: [Duration] = []

    func sleep(for duration: Duration) async throws {
        recorded.append(duration)
        try Task.checkCancellation()
    }

    func values() -> [Duration] { recorded }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var keepEvents = false
    nonisolated(unsafe) static var requestPaths: [String] = []
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("No URLProtocol handler") }
        Self.requestPaths.append(request.url?.path ?? "")
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/api/events" {
            client?.urlProtocol(self, didLoad: data)
            if !Self.keepEvents { client?.urlProtocolDidFinishLoading(self) }
            return
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func json(_ body: Data, contentType: String = "application/json") -> (HTTPURLResponse, Data) {
        json(200, body: body, contentType: contentType)
    }

    static func json(_ status: Int, body: Data, contentType: String = "application/json") -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "http://localhost")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!, body)
    }
}
