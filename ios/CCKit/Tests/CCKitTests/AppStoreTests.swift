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

    func testControllerKindFromBootstrapIsRememberedForTheNextLaunch() async throws {
        let stockade = ControllerInfo(id: .mac, name: "Mac", kind: .stockade, capabilities: [.list, .transcript, .send])
        let bootstrap = try JSONEncoder.ccKit().encode(Bootstrap(controller: stockade, apiVersion: 2, daemon: DaemonInfo(version: "fixture", startedAt: Date(timeIntervalSince1970: 1))))
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(bootstrap) }
            if request.url?.path == "/api/events" {
                return URLProtocolStub.json(Data("event: state\ndata: {\"sessions\":[],\"entries\":{}}\n\n".utf8), contentType: "text/event-stream")
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = makeApp(cacheDirectory: directory)
        XCTAssertEqual(app.controllerInfo.kind, .claudeCode)
        app.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(app.controllerInfo.kind, .stockade)
        app.suspend()

        URLProtocolStub.handler = { _ in URLProtocolStub.json(401, body: Data("{}".utf8)) }
        let relaunched = makeApp(cacheDirectory: directory)
        XCTAssertEqual(relaunched.controllerInfo.kind, .stockade)
        XCTAssertEqual(relaunched.controllerInfo.capabilities, [.list, .transcript, .send])
        try await Task.sleep(for: .milliseconds(20))
    }

    func testBootstrapFailureRetriesWithinGraceAndBecomesLive() async throws {
        let clock = BootstrapClock()
        var bootstrapCalls = 0
        URLProtocolStub.requestFailure = { request in
            guard request.url?.path == "/api/bootstrap" else { return nil }
            bootstrapCalls += 1
            return bootstrapCalls == 1 ? .cannotConnectToHost : nil
        }
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            if request.url?.path == "/api/events" {
                let body = "event: state\ndata: {\"sessions\":[],\"entries\":{}}\n\n"
                return URLProtocolStub.json(Data(body.utf8), contentType: "text/event-stream")
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        URLProtocolStub.keepEvents = true
        defer {
            URLProtocolStub.requestFailure = nil
            URLProtocolStub.keepEvents = false
        }
        let app = AppStore(
            serverURL: URL(string: "http://localhost:47832")!,
            bearerProvider: { "test-token" },
            session: URLProtocolStub.session,
            clock: clock,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        app.start()
        try await waitUntil { bootstrapCalls == 1 && clock.sleepDurations.contains(.milliseconds(500)) }
        clock.advance(by: 0.5)
        try await waitUntil("second bootstrap") { bootstrapCalls == 2 }
        try await Task.sleep(for: .milliseconds(100))
        try await waitUntil("live connection") {
            if case .live = app.connection { return true }
            return false
        }
        XCTAssertEqual(bootstrapCalls, 2)
        if case .offline = app.connection { XCTFail("Transient bootstrap failure became offline") }
        app.suspend()
    }

    func testBootstrapFailuresShowOfflineAtEightSecondsAndKeepRetrying() async throws {
        let clock = BootstrapClock()
        var bootstrapCalls = 0
        URLProtocolStub.requestFailure = { request in
            guard request.url?.path == "/api/bootstrap" else { return nil }
            bootstrapCalls += 1
            return .cannotConnectToHost
        }
        URLProtocolStub.handler = { _ in URLProtocolStub.json(Data("{}".utf8)) }
        defer { URLProtocolStub.requestFailure = nil }
        let app = AppStore(
            serverURL: URL(string: "http://localhost:47832")!,
            bearerProvider: { "test-token" },
            session: URLProtocolStub.session,
            clock: clock,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        app.start()
        try await waitUntil { bootstrapCalls == 1 && clock.sleepDurations.contains(.milliseconds(500)) }
        for delay in [0.5, 1.0, 2.0, 4.0] {
            clock.advance(by: delay)
            try await waitUntil { bootstrapCalls >= 1 + [0.5, 1.0, 2.0, 4.0].prefix(while: { $0 <= delay }).count }
        }
        clock.advance(by: 0.5)
        try await waitUntil {
            if case .offline = app.connection { return true }
            return false
        }
        let callsWhenOffline = bootstrapCalls
        clock.advance(by: 8)
        try await waitUntil { bootstrapCalls > callsWhenOffline }
        app.suspend()
    }

    func testSuspendingCancelsPendingBootstrapRetry() async throws {
        let clock = BootstrapClock()
        var bootstrapCalls = 0
        URLProtocolStub.requestFailure = { request in
            guard request.url?.path == "/api/bootstrap" else { return nil }
            bootstrapCalls += 1
            return .cannotConnectToHost
        }
        URLProtocolStub.handler = { _ in URLProtocolStub.json(Data("{}".utf8)) }
        defer { URLProtocolStub.requestFailure = nil }
        let app = AppStore(
            serverURL: URL(string: "http://localhost:47832")!,
            bearerProvider: { "test-token" },
            session: URLProtocolStub.session,
            clock: clock,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        app.start()
        try await waitUntil { bootstrapCalls == 1 && clock.sleepDurations.contains(.milliseconds(500)) }
        app.suspend()
        clock.advance(by: 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bootstrapCalls, 1)
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

    func testFailedReconnectBootstrapRetriesBeforeReopeningStream() async throws {
        var requests: [String] = []
        var bootstrapCalls = 0
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" {
                bootstrapCalls += 1
                if bootstrapCalls == 2 {
                    requests.append("bootstrap-failed")
                    return URLProtocolStub.json(400, body: Data())
                }
                requests.append("bootstrap")
                return URLProtocolStub.json(Self.bootstrapJSON)
            }
            if request.url?.path == "/api/events" {
                requests.append("events")
                return URLProtocolStub.json(Data(), contentType: "text/event-stream")
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.start()
        try await waitUntil { requests.count >= 5 }
        app.suspend()
        XCTAssertEqual(Array(requests.prefix(5)), ["bootstrap", "events", "bootstrap-failed", "bootstrap", "events"])
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
        settleCoalescedEvents(app)
        XCTAssertEqual(app.sessions["session-1"]?.lastTool, "Bash")
        XCTAssertEqual(app.sessions["session-1"]?.toolRunning, true)
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.first?.agentId, "agent-old")
        XCTAssertEqual(app.sessions["session-1"]?.pending?.first?.requestId, "request-old")

        let cleared = try XCTUnwrap(LiveEvent.decode(name: "state", data: "{\"sessionId\":\"session-1\",\"toolRunning\":false,\"lastTool\":null,\"lastToolInput\":null,\"pending\":[],\"usage\":{\"model\":\"new\",\"outputTokens\":3}}"))
        app.apply(cleared)
        settleCoalescedEvents(app)
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
        try await waitUntil("shell activity") { app.sessions["session-1"]?.shells?.first?.toolUseId == "shell-1" }
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

    func testWakeFlowReturnsAfterWakeRouteWithoutPolling() async throws {
        var wakeCalled = false
        var stateRequests = 0
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/sessions/sleep-1/wake" {
                wakeCalled = true
                return URLProtocolStub.json(Data("{\"id\":\"sleep-1\"}".utf8))
            }
            if request.url?.path == "/api/state" {
                stateRequests += 1
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        let appeared = try await app.wakeSession(id: "sleep-1")
        XCTAssertTrue(appeared)
        XCTAssertTrue(wakeCalled)
        XCTAssertEqual(stateRequests, 0)

        app.apply(.state(StateSnapshot(sessions: [Session(id: "sleep-1", live: true, state: .idle)], entries: [:], sleeping: [])))
        XCTAssertNotNil(app.sessions["sleep-1"])
    }

    func testWakeFailureKeepsSleepingTranscriptReadable() async throws {
        let sleeping = SleepingSession(
            id: "sleep-1",
            shortId: "sleep",
            name: "Sleeping",
            cwd: "/tmp/sleeping",
            project: "sleeping",
            lastActiveAt: Date()
        )
        let transcript = Self.entriesJSON([Self.entry(id: "sleeping-entry")])
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/sessions/sleep-1/transcript" {
                return URLProtocolStub.json(transcript)
            }
            if request.url?.path == "/api/sessions/sleep-1/wake" {
                return URLProtocolStub.json(502, body: Data("{\"error\":\"wake failed\"}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [], sleeping: [sleeping])))
        let store = try XCTUnwrap(app.openSession("sleep-1"))
        try await waitUntil { store.isLoaded }

        do {
            _ = try await app.wakeSession(id: "sleep-1")
            XCTFail("Wake unexpectedly succeeded")
        } catch {
            XCTAssertEqual(store.entries.map(\.id), ["sleeping-entry"])
        }
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

    func testTranscriptResetEventDecodes() throws {
        let event = try XCTUnwrap(LiveEvent.decode(name: "transcript", data: "{\"sessionId\":\"session-1\",\"path\":null,\"entry\":null,\"entryCount\":7,\"reset\":true}"))
        guard case .transcript(let transcript) = event else {
            return XCTFail("Expected transcript event")
        }
        XCTAssertEqual(transcript.sessionId, "session-1")
        XCTAssertNil(transcript.entry)
        XCTAssertEqual(transcript.entryCount, 7)
        XCTAssertEqual(transcript.reset, true)
    }

    func testTranscriptResetRefetchesOpenStoreWithoutMergingNullEntry() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/transcript") == true {
                return URLProtocolStub.json(Self.entriesJSON([Self.entry(id: "fresh")]))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 1])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil { store.isLoaded }
        store.merge([Self.entry(id: "stale")])
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entryCount: 1, reset: true)))
        try await waitUntil { store.entries.map(\.id) == ["fresh"] }
        XCTAssertEqual(store.entries.map(\.id), ["fresh"])
        XCTAssertFalse(store.entries.contains(where: { $0.id == nil }))
    }

    func testTranscriptResetRetriesAfterAOneTimeFetchFailure() async throws {
        let clock = ManualClock()
        var transcriptCalls = 0
        var failedReset = false
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON(entryCount: 1)) }
            if request.url?.path.hasSuffix("/transcript") == true {
                transcriptCalls += 1
                if transcriptCalls == 2 && !failedReset {
                    failedReset = true
                    return URLProtocolStub.json(500, body: Data("{\"error\":\"reset failed\"}".utf8))
                }
                let entry = transcriptCalls == 1 ? Self.entry(id: "old") : Self.entry(id: "fresh")
                return URLProtocolStub.json(Self.pageJSON(entries: [entry], total: transcriptCalls == 1 ? 1 : 2, hasMore: false))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = try await makePaginatedApp(clock: clock)
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 1])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("initial transcript") { store.isLoaded }

        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entryCount: 2, reset: true)))
        try await waitUntil("reset fetch failure") { failedReset }
        // The retry either waits out the backoff or runs at once when another resync request lands
        // first, so release any backoff sleep until the store recovers.
        try await waitUntil("reset retry") {
            clock.resumeSleeps()
            return store.confirmedTotal == 2
        }
        XCTAssertEqual(store.entries.map(\.id), ["fresh"])
        XCTAssertGreaterThanOrEqual(transcriptCalls, 3, "the failed reset was retried")
        app.closeSession("session-1")
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

    func testOpeningExistingStoreDoesNotRecordStoreOpen() throws {
        let lifecycle = TranscriptLifecycleLog.shared
        lifecycle.removeAll()
        defer { lifecycle.removeAll() }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        _ = try XCTUnwrap(app.openSession("session-1"))
        lifecycle.removeAll()

        _ = try XCTUnwrap(app.openSession("session-1"))

        XCTAssertTrue(lifecycle.events.isEmpty)
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
        settleCoalescedEvents(app)
        XCTAssertEqual(app.sessions["session-1"]?.usage?.model, "next")
    }

    func testSubagentsEventReplacesSubagentSnapshot() async throws {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        app.apply(.subagents(SubagentsEvent(sessionId: "session-1", subagents: [Subagent(agentId: "agent-1", state: .running)])))
        settleCoalescedEvents(app)
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
        settleCoalescedEvents(app)
        app.apply(.subagent(SubagentEvent(sessionId: "session-1", subagents: [
            Subagent(agentId: "agent-new", state: .running, startedAt: newer, toolUseId: "task-new"),
            Subagent(agentId: "agent-old", state: .done, startedAt: older, toolUseId: "task-old"),
        ])))
        settleCoalescedEvents(app)
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.map(\.toolUseId), ["task-new", "task-old"])
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.last?.state, .done)
    }

    func testNoOpSubagentUpsertDoesNotMutateSession() async throws {
        let app = makeApp()
        let existing = Subagent(agentId: "agent-1", state: .done, startedAt: Date(timeIntervalSince1970: 10), toolUseId: "task-1")
        app.apply(.state(StateSnapshot(sessions: [Self.session(subagents: [existing])], entries: ["session-1": 0])))
        let before = app.sessions["session-1"]
        app.apply(.subagent(SubagentEvent(sessionId: "session-1", subagents: [existing])))
        settleCoalescedEvents(app)
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
        settleCoalescedEvents(app)
        XCTAssertEqual(app.sessions["session-1"]?.subagents?.count, 2)
        XCTAssertTrue(app.sessions["session-1"]?.subagents?.contains { $0.state == .done } == true)
    }

    func testFullSubagentsEventReplacesAfterUpsert() async throws {
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        app.apply(.subagent(SubagentEvent(sessionId: "session-1", subagents: [Subagent(agentId: "agent-1", state: .running)])))
        settleCoalescedEvents(app)
        app.apply(.subagents(SubagentsEvent(sessionId: "session-1", subagents: [])))
        settleCoalescedEvents(app)
        XCTAssertEqual(app.sessions["session-1"]?.subagents, [])
    }

    func testArchiveIsOptimisticAndUndoUnarchives() async throws {
        var archived = false
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/archive") == true {
                archived = true
                return URLProtocolStub.json(Data("{\"id\":\"session-1\",\"archivedAt\":\"2026-10-28T10:20:30.000Z\"}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))

        guard case .success = await app.archiveSession(id: "session-1", archived: true) else { return XCTFail("Archive failed") }
        XCTAssertTrue(archived)
        XCTAssertNotNil(app.sessions["session-1"]?.archivedAt)

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-1/archive")
            return URLProtocolStub.json(Data("{\"id\":\"session-1\",\"archivedAt\":null}".utf8))
        }
        guard case .success = await app.archiveSession(id: "session-1", archived: false) else { return XCTFail("Undo failed") }
        XCTAssertNil(app.sessions["session-1"]?.archivedAt)
    }

    func testArchiveFailureRevertsOptimisticState() async {
        URLProtocolStub.handler = { _ in URLProtocolStub.json(500, body: Data("{\"error\":\"archive failed\"}".utf8)) }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))

        guard case .failure(.server(status: 500, message: "archive failed")) = await app.archiveSession(id: "session-1", archived: true) else {
            return XCTFail("Archive failure was not surfaced")
        }
        XCTAssertNil(app.sessions["session-1"]?.archivedAt)
    }

    func testCloseErrorCodesMapToUserActions() async {
        let app = makeApp()
        URLProtocolStub.handler = { _ in URLProtocolStub.json(409, body: Data("{\"error\":\"busy\",\"code\":\"busy\"}".utf8)) }
        guard case .failure(.sessionBusy) = await app.endSession(id: "session-1") else { return XCTFail("Busy close was not mapped") }
        URLProtocolStub.handler = { _ in URLProtocolStub.json(409, body: Data("{\"error\":\"unsupported\",\"code\":\"close_unsupported\"}".utf8)) }
        guard case .failure(.closeUnsupported) = await app.endSession(id: "session-1") else { return XCTFail("Unsupported close was not mapped") }
        XCTAssertEqual(ActionError.sessionBusy.userMessage, "Approve or stop the current request first.")
        XCTAssertEqual(ActionError.closeUnsupported.userMessage, "This session can't be ended from here.")
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

    func testApprovalEventDoesNotEraseToolInputAlreadyReceivedInState() {
        let app = makeApp()
        let input = JSONValue.object(["command": .string("rm -f scratch")])
        let existing = Approval(
            requestId: "request-1",
            sessionId: "session-1",
            toolName: "Bash",
            toolInput: input,
            agentType: "atlas-ops"
        )
        var session = Self.session()
        session.pending = [existing]
        app.apply(.state(StateSnapshot(sessions: [session], entries: ["session-1": 0])))
        app.apply(.approval(ApprovalEvent(sessionId: "session-1", requestId: "request-1", toolName: "Bash", agentType: "atlas-ops")))
        XCTAssertEqual(app.approvals(for: "session-1").first?.toolInput, input)
    }

    func testTerminalNoPaneDecisionRestoresApprovalAsPaneLessWithoutAlertState() async {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/sessions/session-1/decision" {
                return URLProtocolStub.json(409, body: Data("{\"error\":\"Waiting in the terminal\",\"code\":\"terminal_no_pane\"}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        let approval = Approval(requestId: "request-1", sessionId: "session-1", toolName: "Bash", mode: .terminal, status: .terminal)
        var session = Self.session()
        session.tmuxPane = "%7"
        app.apply(.state(StateSnapshot(sessions: [session], entries: ["session-1": 0])))
        app.apply(.approval(ApprovalEvent(sessionId: "session-1", requestId: approval.requestId, toolName: approval.toolName, mode: .terminal, status: .terminal)))

        guard case .failure(.waitingInTerminal) = await app.allow(approval) else {
            return XCTFail("Expected terminal no-pane refusal")
        }
        XCTAssertNil(app.sessions["session-1"]?.tmuxPane)
        XCTAssertEqual(app.approvals(for: "session-1").first?.status, .terminal)
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

    func testSendMarksPendingTurnUntilWorkingStateArrives() async throws {
        URLProtocolStub.handler = { _ in
            URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session(state: .idle)], entries: ["session-1": 0])))

        guard case .success = await app.send(text: "start a turn", to: "session-1") else {
            return XCTFail("Send failed")
        }
        XCTAssertNotNil(app.pendingTurnStart(for: "session-1"))

        app.apply(.stateDelta(StateDelta(sessionId: "session-1", state: .working)))
        settleCoalescedEvents(app)
        XCTAssertNil(app.pendingTurnStart(for: "session-1"))
    }

    func testFailedSendClearsPendingTurn() async {
        URLProtocolStub.handler = { _ in
            URLProtocolStub.json(500, body: Data("{\"error\":\"send failed\"}".utf8))
        }
        let app = makeApp()

        guard case .failure = await app.send(text: "failed turn", to: "session-1") else {
            return XCTFail("Failed send unexpectedly succeeded")
        }
        XCTAssertNil(app.pendingTurnStart(for: "session-1"))
    }

    func testQueuedNoteStartsTurnOnlyWhenCreatedWhileIdle() async throws {
        URLProtocolStub.handler = { _ in
            URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session(state: .idle)], entries: ["session-1": 0])))

        guard case .success = await app.enqueueMessage(text: "starts turn", to: "session-1") else {
            return XCTFail("Idle enqueue failed")
        }
        XCTAssertEqual(app.queuedNotes(for: "session-1").first?.startsTurn, true)

        app.apply(.stateDelta(StateDelta(sessionId: "session-1", state: .working)))
        settleCoalescedEvents(app)
        guard case .success = await app.enqueueMessage(text: "queues later", to: "session-1") else {
            return XCTFail("Working enqueue failed")
        }
        XCTAssertEqual(app.queuedNotes(for: "session-1").last?.startsTurn, false)
    }

    func testOldQueuedNoteDecodesStartsTurnAsFalse() throws {
        let data = Data("{\"id\":\"old\",\"text\":\"old\",\"queued\":false,\"forceSent\":false,\"createdAt\":\"1970-01-01T00:00:00.000Z\",\"now\":false}".utf8)
        let note = try JSONDecoder.ccKit().decode(QueuedNote.self, from: data)
        XCTAssertFalse(note.startsTurn)
    }

    func testPendingTurnExpiryClearsAfterTwentySecondsOnInjectedClock() async throws {
        URLProtocolStub.handler = { _ in
            URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
        }
        let clock = ManualClock()
        let app = AppStore(
            serverURL: URL(string: "http://localhost:47832")!,
            bearerProvider: { "test-token" },
            session: URLProtocolStub.session,
            clock: clock,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        _ = await app.send(text: "expiring turn", to: "session-1")
        for _ in 0..<50 where clock.sleepCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(clock.sleepDurations.contains(.seconds(20)), "Expiry task did not reach the injected 20-second sleep")
        XCTAssertNotNil(app.pendingTurnStart(for: "session-1"))
        clock.resumeSleeps()
        for _ in 0..<50 where app.pendingTurnStart(for: "session-1") != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(app.pendingTurnStart(for: "session-1"), "Expiry task did not clear after injected 20-second sleep")
    }

    func testSendComposerShowsSendingNoteBeforeResponseAndUpdatesItInPlace() async throws {
        let gate = DispatchSemaphore(value: 0)
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                gate.wait()
                return URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.setDraft("send now", for: "session-1")
        let sending = Task { @MainActor in await app.sendComposer(text: "send now", to: "session-1") }
        try await waitUntil { app.queuedNotes(for: "session-1").first?.state == .sending }
        XCTAssertEqual(app.draft(for: "session-1"), "")
        XCTAssertNil(app.queuedNotes(for: "session-1").first?.sentAt)
        gate.signal()
        guard case .success = await sending.value else { return XCTFail("Send was rejected") }
        try await waitUntil { app.queuedNotes(for: "session-1").first?.state == .sent }
        XCTAssertNotNil(app.queuedNotes(for: "session-1").first?.sentAt)
        XCTAssertEqual(app.queuedNotes(for: "session-1").count, 1)
    }

    func testSendComposerRemovesSendingNoteAndRestoresDraftOnFailure() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                return URLProtocolStub.json(500, body: Data("{\"error\":\"send failed\"}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.setDraft("keep this", for: "session-1")
        guard case .failure = await app.sendComposer(text: "keep this", to: "session-1") else {
            return XCTFail("Failed send unexpectedly succeeded")
        }
        XCTAssertTrue(app.queuedNotes(for: "session-1").isEmpty)
        XCTAssertEqual(app.draft(for: "session-1"), "keep this")
    }

    func testSendingNoteReconcilesNewPromptBeforeResponseButNotOlderIdenticalPrompt() async throws {
        let gate = DispatchSemaphore(value: 0)
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                gate.wait()
                return URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = makeApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session(state: .idle)], entries: ["session-1": 0])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        let old = TranscriptEntry.prompt(PromptEntry(id: "old-prompt", ts: Date(timeIntervalSince1970: 1_800_000_000), text: "same text"))
        store.merge([old])

        let sending = Task { @MainActor in await app.sendComposer(text: "same text", to: "session-1") }
        try await waitUntil { app.queuedNotes(for: "session-1").first?.state == .sending }
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: old)))
        XCTAssertEqual(app.queuedNotes(for: "session-1").map(\.text), ["same text"])

        let new = TranscriptEntry.prompt(PromptEntry(id: "new-prompt", ts: Date(), text: "same text"))
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: new)))
        XCTAssertTrue(app.queuedNotes(for: "session-1").isEmpty)
        gate.signal()
        _ = await sending.value
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

    func testSendAllowsAttachmentsWithoutText() async {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-1/message")
            return URLProtocolStub.json(Data("{\"delivered\":true,\"queued\":false}".utf8))
        }
        let app = makeApp()
        let result = await app.send(text: "", attachments: ["photo.png"], to: "session-1")
        guard case .success = result else {
            XCTFail("Send failed: \(result)")
            return
        }
        XCTAssertEqual(app.queuedNotes(for: "session-1").first?.attachments, ["photo.png"])
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

    func testContainmentKeepsPromptOlderThanCreatedAtSkew() {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let note = QueuedNote(id: "note", text: "same", state: .queued, createdAt: createdAt, sentAt: createdAt.addingTimeInterval(10))
        let prompt = TranscriptEntry.prompt(PromptEntry(ts: createdAt.addingTimeInterval(-5.1), text: "other\nsame"))

        XCTAssertEqual(reconcileQueuedNote([note], promptEntry: prompt).map(\.id), ["note"])
    }

    func testContainmentMatchesPromptBetweenCreationAndSend() {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let note = QueuedNote(id: "note", text: "same", state: .queued, createdAt: createdAt, sentAt: createdAt.addingTimeInterval(10))
        let prompt = TranscriptEntry.prompt(PromptEntry(ts: createdAt.addingTimeInterval(5), text: "other\nsame"))

        XCTAssertTrue(reconcileQueuedNote([note], promptEntry: prompt).isEmpty)
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

    func testQueuedNoteWaitsForNonWorkingGracePeriod() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let note = QueuedNote(text: "queued", state: .queued, createdAt: now.addingTimeInterval(-5 * 60), sentAt: now.addingTimeInterval(-5 * 60))

        XCTAssertFalse(noteNeedsAttention(note: note, sessionState: .idle, nonWorkingSince: now.addingTimeInterval(-5), now: now))
    }

    func testQueuedNoteNeedsAttentionAfterNonWorkingGracePeriod() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let note = QueuedNote(text: "queued", state: .queued, createdAt: now.addingTimeInterval(-5 * 60), sentAt: now.addingTimeInterval(-5 * 60))

        XCTAssertTrue(noteNeedsAttention(note: note, sessionState: .idle, nonWorkingSince: now.addingTimeInterval(-31), now: now))
    }

    func testQueuedNoteNeedsAttentionAfterTenMinutesWhileWorking() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let note = QueuedNote(text: "queued", state: .queued, createdAt: now.addingTimeInterval(-10 * 60), sentAt: now.addingTimeInterval(-10 * 60))

        XCTAssertTrue(noteNeedsAttention(note: note, sessionState: .working, now: now))
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
        var transcriptCalls = 0
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/message") == true {
                return URLProtocolStub.json(Data("{\"delivered\":false,\"queued\":true}".utf8))
            }
            if request.url?.path.hasSuffix("/transcript") == true {
                transcriptCalls += 1
                return transcriptCalls == 1
                    ? URLProtocolStub.json(Self.entriesJSON([]))
                    : URLProtocolStub.json(Self.promptJSON(text: "gap delivery", timestamp: createdAt))
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

    func testFailedGapFetchIsRetriedImmediatelyByTheNextLiveEvent() async throws {
        var transcriptCalls = 0
        var failedGapFetch = false
        URLProtocolStub.requestPaths = []
        URLProtocolStub.keepEvents = false
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            if request.url?.path == "/api/events" { return URLProtocolStub.json(Data("event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\n".utf8), contentType: "text/event-stream") }
            if request.url?.path.hasSuffix("/transcript") == true {
                var tail: String?
                for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] where item.name == "tail" {
                    tail = item.value
                    break
                }
                transcriptCalls += 1
                if tail != "100" && !failedGapFetch {
                    failedGapFetch = true
                    return URLProtocolStub.json(500, body: Data("{\"error\":\"gap failed\"}".utf8))
                }
                let entries = failedGapFetch ? gapTestEntries(1, 4) : gapTestEntries(1, 1)
                return URLProtocolStub.json(Self.pageJSON(entries: entries, total: entries.count, hasMore: false))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = try await makePaginatedApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 1])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await store.loadInitial()
        XCTAssertTrue(store.isLoaded)

        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: Self.entry(id: "entry-3"), entryCount: 3)))
        try await waitUntil("failed gap fetch") { failedGapFetch }
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: Self.entry(id: "entry-4"), entryCount: 4)))

        try await waitUntil("gap retry") { store.entries.count == 4 && transcriptCalls >= 3 }
        XCTAssertEqual(Set(store.entries.compactMap(\.id)), Set((1...4).map { "entry-\($0)" }))
        XCTAssertEqual(store.confirmedTotal, 4)
        app.closeSession("session-1")
        app.suspend()
        URLProtocolStub.keepEvents = false
    }

    func testQuietGapHealsThroughInjectedBackoffRetry() async throws {
        let clock = ManualClock()
        var transcriptCalls = 0
        var failedGapFetch = false
        URLProtocolStub.keepEvents = true
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            if request.url?.path == "/api/events" { return URLProtocolStub.json(Data("event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\n".utf8), contentType: "text/event-stream") }
            if request.url?.path.hasSuffix("/transcript") == true {
                transcriptCalls += 1
                if transcriptCalls == 2 && !failedGapFetch {
                    failedGapFetch = true
                    return URLProtocolStub.json(500, body: Data("{\"error\":\"gap failed\"}".utf8))
                }
                let entries = transcriptCalls >= 3 ? gapTestEntries(1, 2) : []
                return URLProtocolStub.json(Self.pageJSON(entries: entries, total: entries.count, hasMore: false))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = try await makePaginatedApp(clock: clock)
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("initial transcript") { store.isLoaded }
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: Self.entry(id: "entry-2"), entryCount: 2)))
        try await waitUntil("backoff scheduled") { clock.sleepDurations.contains(.seconds(1)) }

        clock.resumeSleeps()
        try await waitUntil("quiet gap retry") { store.confirmedTotal == 2 }
        XCTAssertEqual(transcriptCalls, 3)
        app.closeSession("session-1")
    }

    func testForegroundResyncsAnOpenStoreWithAnUnconfirmedServerTotal() async throws {
        var transcriptCalls = 0
        URLProtocolStub.keepEvents = true
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            if request.url?.path == "/api/events" { return URLProtocolStub.json(Data("event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\n".utf8), contentType: "text/event-stream") }
            if request.url?.path.hasSuffix("/transcript") == true {
                transcriptCalls += 1
                let entries = transcriptCalls == 1 ? [] : gapTestEntries(1, 3)
                return URLProtocolStub.json(Self.pageJSON(entries: entries, total: entries.count, hasMore: false))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = try await makePaginatedApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("initial transcript") { store.isLoaded }

        store.observeServerTotal(3)
        app.resyncOpenTranscripts()

        try await waitUntil("foreground resync") { store.confirmedTotal == 3 }
        XCTAssertEqual(transcriptCalls, 2)
        app.closeSession("session-1")
        app.suspend()
        URLProtocolStub.keepEvents = false
    }

    func testReplaceAndUpdateEventsDoNotTriggerGapFetch() async throws {
        var transcriptCalls = 0
        URLProtocolStub.keepEvents = true
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON(entryCount: 1)) }
            if request.url?.path == "/api/events" { return URLProtocolStub.json(Data("event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\n".utf8), contentType: "text/event-stream") }
            if request.url?.path.hasSuffix("/transcript") == true {
                transcriptCalls += 1
                return URLProtocolStub.json(Self.pageJSON(entries: [Self.entry(id: "entry-1")], total: 1, hasMore: false))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = try await makePaginatedApp()
        try await Task.sleep(for: .milliseconds(100))
        transcriptCalls = 0
        URLProtocolStub.requestPaths = []
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("initial transcript") { store.isLoaded }
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: Self.entry(id: "entry-1"), entryCount: 1, replace: true)))
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: Self.entry(id: "entry-1"), entryCount: 1)))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transcriptCalls, 1)
        XCTAssertEqual(store.confirmedTotal, 1)
        app.closeSession("session-1")
        app.suspend()
        URLProtocolStub.keepEvents = false
    }

    func testMoreThanFourHundredMissingEntriesUsesResetFetch() async throws {
        var transcriptCalls = 0
        var usedResetTail = false
        URLProtocolStub.requestPaths = []
        URLProtocolStub.keepEvents = true
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            if request.url?.path == "/api/events" { return URLProtocolStub.json(Data("event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\n".utf8), contentType: "text/event-stream") }
            if request.url?.path.hasSuffix("/transcript") == true {
                transcriptCalls += 1
                for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] where item.name == "tail" && item.value == "100" {
                    usedResetTail = true
                    break
                }
                let entries = transcriptCalls == 1 ? [] : [Self.entry(id: "tail")]
                return URLProtocolStub.json(Self.pageJSON(entries: entries, total: transcriptCalls == 1 ? 0 : 401, hasMore: transcriptCalls == 1))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = try await makePaginatedApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("initial transcript") { store.isLoaded }
        app.apply(.transcript(TranscriptEvent(sessionId: "session-1", entry: Self.entry(id: "entry-401"), entryCount: 401)))

        try await waitUntil("reset gap fetch") { transcriptCalls >= 2 }
        XCTAssertTrue(usedResetTail, "Expected reset tail request")
        XCTAssertEqual(store.confirmedTotal, 401)
        app.closeSession("session-1")
        app.suspend()
        URLProtocolStub.keepEvents = false
    }

    func testStateDeltaAboveConfirmedTotalTriggersResync() async throws {
        var transcriptCalls = 0
        URLProtocolStub.keepEvents = true
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            if request.url?.path == "/api/events" { return URLProtocolStub.json(Data("event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\n".utf8), contentType: "text/event-stream") }
            if request.url?.path.hasSuffix("/transcript") == true {
                transcriptCalls += 1
                let entries = transcriptCalls == 1 ? [] : gapTestEntries(1, 3)
                return URLProtocolStub.json(Self.pageJSON(entries: entries, total: entries.count, hasMore: false))
            }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = try await makePaginatedApp()
        app.apply(.state(StateSnapshot(sessions: [Self.session()], entries: ["session-1": 0])))
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("initial transcript") { store.isLoaded }
        app.apply(.stateDelta(StateDelta(sessionId: "session-1", entries: ["session-1": 3])))

        try await waitUntil("state delta resync") { transcriptCalls >= 2 && store.confirmedTotal == 3 }
        XCTAssertEqual(store.serverTotal, 3)
        app.closeSession("session-1")
        app.suspend()
        URLProtocolStub.keepEvents = false
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
        settleCoalescedEvents(app)
        XCTAssertEqual(app.sessions["session-1"]?.state, .needsYou)

        app.apply(.usage(UsageEvent(sessionId: "session-1", usage: Usage(model: "fable", outputTokens: 7))))
        app.apply(.subagents(SubagentsEvent(sessionId: "session-1", subagents: [Subagent(agentId: "agent-1", state: .running)])))
        settleCoalescedEvents(app)
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
        // The second bootstrap is counted before its result reaches the store, so wait for the drop itself.
        try await waitUntil {
            bootstrapCalls >= 2
                && store.entries.contains(where: { $0.id == "new" })
                && !store.entries.contains(where: { $0.id == "old" })
        }
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

    func testOpenCurrentCacheIsReadyBeforeTailReturns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let epoch = Date(timeIntervalSince1970: 42)
        await writeReadinessCache(directory: directory, rev: 7, epoch: epoch)
        URLProtocolStub.requestPaths = []
        URLProtocolStub.keepEvents = true
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/bootstrap":
                return URLProtocolStub.json(Self.readinessBootstrapJSON(rev: 7, startedAt: epoch))
            case "/api/events":
                return URLProtocolStub.json(Data(), contentType: "text/event-stream")
            case let path where path?.hasSuffix("/transcript") == true:
                Thread.sleep(forTimeInterval: 2)
                return URLProtocolStub.json(Self.pageJSON(entries: [Self.entry(id: "fresh")], total: 1, hasMore: false, rev: 7))
            default:
                return URLProtocolStub.json(Data("{}".utf8))
            }
        }
        let app = makeApp(cacheDirectory: directory)
        defer {
            app.suspend()
            URLProtocolStub.keepEvents = false
        }
        app.start()
        try await waitUntil("current bootstrap") { app.isStateCurrent && app.sessions["session-1"] != nil }
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("delayed transcript request") { URLProtocolStub.requestPaths.contains { $0.hasSuffix("/transcript") } }
        XCTAssertEqual(store.readiness, .ready)
        try await waitUntil("delayed transcript completion") { store.isLoaded }
    }

    func testOpenChangedCacheSyncsBeforeTailReturns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let epoch = Date(timeIntervalSince1970: 43)
        await writeReadinessCache(directory: directory, rev: 7, epoch: epoch)
        URLProtocolStub.requestPaths = []
        URLProtocolStub.keepEvents = true
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/bootstrap":
                return URLProtocolStub.json(Self.readinessBootstrapJSON(rev: 8, startedAt: epoch))
            case "/api/events":
                return URLProtocolStub.json(Data(), contentType: "text/event-stream")
            case let path where path?.hasSuffix("/transcript") == true:
                Thread.sleep(forTimeInterval: 2)
                return URLProtocolStub.json(Self.pageJSON(entries: [Self.entry(id: "fresh")], total: 1, hasMore: false, rev: 9))
            default:
                return URLProtocolStub.json(Data("{}".utf8))
            }
        }
        let app = makeApp(cacheDirectory: directory)
        defer {
            app.suspend()
            URLProtocolStub.keepEvents = false
        }
        app.start()
        try await waitUntil("changed bootstrap") { app.isStateCurrent && app.sessions["session-1"] != nil }
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("delayed transcript request") { URLProtocolStub.requestPaths.contains { $0.hasSuffix("/transcript") } }
        app.apply(.transcript(TranscriptEvent(
            sessionId: "session-1",
            entry: Self.entry(id: "live-before-tail"),
            entryCount: 2,
            rev: 9
        )))
        XCTAssertEqual(store.readiness, .syncing)
        try await Task.sleep(for: .milliseconds(2_200))
        XCTAssertEqual(store.readiness, .ready)
    }

    func testInSyncStoreAdvancesRevisionFromLiveEventAndStaysReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let epoch = Date(timeIntervalSince1970: 44)
        await writeReadinessCache(directory: directory, rev: 10, epoch: epoch)
        URLProtocolStub.requestPaths = []
        URLProtocolStub.keepEvents = true
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/bootstrap":
                return URLProtocolStub.json(Self.readinessBootstrapJSON(rev: 10, startedAt: epoch))
            case "/api/events":
                return URLProtocolStub.json(Data(), contentType: "text/event-stream")
            case let path where path?.hasSuffix("/transcript") == true:
                Thread.sleep(forTimeInterval: 2)
                return URLProtocolStub.json(Self.pageJSON(entries: [Self.entry(id: "fresh")], total: 1, hasMore: false, rev: 11))
            default:
                return URLProtocolStub.json(Data("{}".utf8))
            }
        }
        let app = makeApp(cacheDirectory: directory)
        defer {
            app.suspend()
            URLProtocolStub.keepEvents = false
        }
        app.start()
        try await waitUntil("in-sync bootstrap") { app.isStateCurrent && app.sessions["session-1"] != nil }
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("delayed transcript request") { URLProtocolStub.requestPaths.contains { $0.hasSuffix("/transcript") } }
        XCTAssertEqual(store.readiness, .ready)
        app.apply(.transcript(TranscriptEvent(
            sessionId: "session-1",
            entry: Self.entry(id: "live-in-sync"),
            entryCount: 2,
            rev: 11
        )))
        XCTAssertEqual(store.syncedRev, 11)
        XCTAssertEqual(store.readiness, .ready)
    }

    func testBehindCacheWritesItsOldRevisionAfterLiveEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let epoch = Date(timeIntervalSince1970: 45)
        await writeReadinessCache(directory: directory, rev: 100, epoch: epoch)
        URLProtocolStub.requestPaths = []
        URLProtocolStub.keepEvents = true
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/bootstrap":
                return URLProtocolStub.json(Self.readinessBootstrapJSON(rev: 110, startedAt: epoch))
            case "/api/events":
                return URLProtocolStub.json(Data(), contentType: "text/event-stream")
            case let path where path?.hasSuffix("/transcript") == true:
                Thread.sleep(forTimeInterval: 2)
                return URLProtocolStub.json(Self.pageJSON(entries: [Self.entry(id: "fresh")], total: 1, hasMore: false, rev: 111))
            default:
                return URLProtocolStub.json(Data("{}".utf8))
            }
        }
        let app = makeApp(cacheDirectory: directory)
        defer {
            app.suspend()
            URLProtocolStub.keepEvents = false
        }
        app.start()
        try await waitUntil("behind bootstrap") { app.isStateCurrent && app.sessions["session-1"] != nil }
        let store = try XCTUnwrap(app.openSession("session-1"))
        try await waitUntil("delayed transcript request") { URLProtocolStub.requestPaths.contains { $0.hasSuffix("/transcript") } }
        app.apply(.transcript(TranscriptEvent(
            sessionId: "session-1",
            entry: Self.entry(id: "live-behind"),
            entryCount: 2,
            rev: 111
        )))
        XCTAssertEqual(store.readiness, .syncing)
        app.closeSession("session-1")
        for _ in 0..<50 {
            if (try? await DiskCache(directory: directory).load()?.transcriptMetadata["session-1"]?.rev) == 100 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let loaded = try await DiskCache(directory: directory).load()
        XCTAssertEqual(loaded?.transcriptMetadata["session-1"]?.rev, 100)
    }

    func testClosingStoreFlushesTranscriptCacheWithoutDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        URLProtocolStub.keepEvents = true
        defer { URLProtocolStub.keepEvents = false }
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            if request.url?.path == "/api/events" { return URLProtocolStub.json(Data("event: state\ndata: {\"sessions\":[{\"id\":\"session-1\",\"live\":true,\"state\":\"working\"}],\"entries\":{\"session-1\":0}}\n\n".utf8), contentType: "text/event-stream") }
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

    private func settleCoalescedEvents(_ app: AppStore) {
        app.flushCoalescedEvents()
    }

    private func waitUntil(_ message: String = "app state", _ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(message)")
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

    private func makePaginatedApp(clock: any CCKitClock = SystemCCKitClock()) async throws -> AppStore {
        let client = APIClient(baseURL: URL(string: "http://localhost:47832")!, session: URLProtocolStub.session)
        _ = try await client.bootstrap()
        return AppStore(
            client: client,
            bearerProvider: { "test-token" },
            clock: clock,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }

    private static func session(state: SessionState = .idle, subagents: [Subagent]? = nil) -> Session {
        Session(id: "session-1", name: "Fixture", live: true, state: state, usage: Usage(), subagents: subagents)
    }

    private static func entry(id: String) -> TranscriptEntry {
        .assistant(AssistantEntry(id: id, rev: 1, ts: Date(timeIntervalSince1970: Double(id == "first" ? 1 : 2)), text: id))
    }

    private func writeReadinessCache(directory: URL, rev: Int, epoch: Date) async {
        let cache = DiskCache(directory: directory)
        let cachedEntry = Self.entry(id: "cached")
        let state = DiskCacheState(
            bootstrap: Bootstrap(
                apiVersion: 2,
                daemon: DaemonInfo(version: "cached", startedAt: epoch),
                capabilities: Capabilities(pagination: true),
                state: StateSnapshot(
                    sessions: [Self.session()],
                    entries: ["session-1": 1],
                    revs: ["session-1": rev]
                )
            ),
            transcripts: ["session-1": [cachedEntry]],
            updatedAt: Date(timeIntervalSince1970: 10),
            transcriptMetadata: ["session-1": TranscriptCacheMetadata(rev: rev, epoch: String(epoch.timeIntervalSince1970))]
        )
        await cache.saveNow(
            state,
            changedTranscripts: state.transcripts,
            changedTranscriptMetadata: state.transcriptMetadata,
            retainedTranscriptKeys: ["session-1"]
        )
        await cache.flush()
    }

    private static func readinessBootstrapJSON(rev: Int, startedAt: Date) -> Data {
        let value = Bootstrap(
            apiVersion: 2,
            daemon: DaemonInfo(version: "fixture", startedAt: startedAt),
            capabilities: Capabilities(pagination: true),
            state: StateSnapshot(
                sessions: [session(state: .working)],
                entries: ["session-1": 1],
                revs: ["session-1": rev]
            )
        )
        return try! JSONEncoder.ccKit().encode(value)
    }

    private static let bootstrapJSON = bootstrapJSON()

    private static func bootstrapJSON(startedAt: Date = Date(timeIntervalSince1970: 1), entryCount: Int = 0) -> Data {
        let value = Bootstrap(apiVersion: 2, daemon: DaemonInfo(version: "fixture", startedAt: startedAt), capabilities: Capabilities(pagination: true), state: StateSnapshot(sessions: [session(state: .working)], entries: ["session-1": entryCount]))
        return try! JSONEncoder.ccKit().encode(value)
    }

    private static func pageJSON(entries: [TranscriptEntry], total: Int, hasMore: Bool, rev: Int? = nil) -> Data {
        try! JSONEncoder.ccKit().encode(TranscriptPage(entries: entries, total: total, hasMore: hasMore, rev: rev))
    }

    private static func entriesJSON(_ entries: [TranscriptEntry]) -> Data {
        try! JSONEncoder.ccKit().encode(entries)
    }

    private static func promptJSON(text: String, timestamp: Date) -> Data {
        Data("[{\"kind\":\"prompt\",\"ts\":\"\(CCDateCoding.format(timestamp))\",\"text\":\"\(text)\"}]".utf8)
    }
}

private func gapTestEntries(_ first: Int, _ last: Int) -> [TranscriptEntry] {
    (first...last).map { index in
        .assistant(AssistantEntry(
            id: "entry-\(index)",
            rev: 1,
            ts: Date(timeIntervalSince1970: Double(index)),
            text: "entry-\(index)"
        ))
    }
}

private struct FixedClock: CCKitClock {
    let now: Date

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}

private final class ManualClock: CCKitClock, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var durations: [Duration] = []

    var sleepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    var sleepDurations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return durations
    }

    var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            durations.append(duration)
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func resumeSleeps() {
        lock.lock()
        let current = waiters
        waiters.removeAll()
        lock.unlock()
        current.forEach { $0.resume() }
    }
}

private final class BootstrapClock: CCKitClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var durations: [Duration] = []

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var sleepDurations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return durations
    }

    func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            durations.append(duration)
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let currentWaiters = waiters
        waiters.removeAll()
        lock.unlock()
        currentWaiters.forEach { $0.resume() }
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
    nonisolated(unsafe) static var requestFailure: ((URLRequest) -> URLError.Code?)?
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
        if let code = Self.requestFailure?(request) {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
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
