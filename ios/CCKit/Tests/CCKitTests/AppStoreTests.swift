import Foundation
import XCTest
@testable import CCKit

@MainActor
final class AppStoreTests: XCTestCase {
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

    func testEveryContractEventUpdatesTheRightState() async throws {
        let app = makeApp()
        let session = Self.session(state: .working)
        app.apply(.state(StateSnapshot(sessions: [session], entries: ["session-1": 0])))
        app.apply(.stateDelta(StateDelta(sessionId: "session-1", state: .needsYou, action: "Needs your attention")))
        XCTAssertEqual(app.sessions["session-1"]?.state, .needsYou)

        app.apply(.usage(UsageEvent(sessionId: "session-1", usage: Usage(model: "fable", outputTokens: 7))))
        XCTAssertEqual(app.sessions["session-1"]?.usage?.outputTokens, 7)
        app.apply(.subagents(SubagentsEvent(sessionId: "session-1", subagents: [Subagent(agentId: "agent-1", state: .running)])))
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
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/bootstrap" { return URLProtocolStub.json(Self.bootstrapJSON) }
            return URLProtocolStub.json(Data("{}".utf8))
        }
        let app = AppStore(serverURL: URL(string: "http://localhost:47832")!, bearerProvider: { "test-token" }, session: URLProtocolStub.session, cacheDirectory: directory)
        app.start()
        try await waitUntil { app.sessions["session-1"] != nil }
        XCTAssertEqual(app.sessions["session-1"]?.name, "Fixture")
        app.suspend()
    }

    func testUnauthorizedBootstrapIsExplicitOfflineState() async throws {
        URLProtocolStub.handler = { _ in URLProtocolStub.json(401, body: Data("{\"error\":\"Authentication required\"}".utf8)) }
        let app = makeApp()
        app.start()
        try await Task.sleep(for: .milliseconds(100))
        guard case .offline(_, let error) = app.connection else { return XCTFail("Expected offline state") }
        XCTAssertEqual(error, "Authentication required")
        app.suspend()
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<50 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for app state")
    }

    private func makeApp() -> AppStore {
        AppStore(
            serverURL: URL(string: "http://localhost:47832")!,
            bearerProvider: { "test-token" },
            session: URLProtocolStub.session,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }

    private static func session(state: SessionState = .idle) -> Session {
        Session(id: "session-1", name: "Fixture", live: true, state: state, usage: Usage())
    }

    private static func entry(id: String) -> TranscriptEntry {
        .assistant(AssistantEntry(id: id, rev: 1, ts: Date(timeIntervalSince1970: Double(id == "first" ? 1 : 2)), text: id))
    }

    private static let bootstrapJSON = bootstrapJSON()

    private static func bootstrapJSON(startedAt: Date = Date(timeIntervalSince1970: 1)) -> Data {
        let value = Bootstrap(apiVersion: 2, daemon: DaemonInfo(version: "fixture", startedAt: startedAt), capabilities: Capabilities(pagination: true), state: StateSnapshot(sessions: [session(state: .working)], entries: ["session-1": 0]))
        return try! JSONEncoder.ccKit().encode(value)
    }

    private static func pageJSON(entries: [TranscriptEntry], total: Int, hasMore: Bool) -> Data {
        try! JSONEncoder.ccKit().encode(TranscriptPage(entries: entries, total: total, hasMore: hasMore))
    }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("No URLProtocol handler") }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path == "/api/events" {
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
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
