import Foundation
import XCTest
@testable import CCKit

final class APIClientTests: XCTestCase {
    func testLegacyTranscriptArrayKeepsMalformedKnownKindBetweenValidEntries() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.response(status: 200, body: Data("""
            [{"kind":"assistant","id":"before","text":"Before"},{"kind":"prompt","id":"bad","paste":[]},{"kind":"assistant","id":"after","text":"After"}]
            """.utf8))
        }

        let entries = try await makeClient().transcript(sessionID: "session-1")

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.id, "before")
        XCTAssertEqual(entries.last?.id, "after")
        guard case .unknown(let kind, _) = entries[1] else { return XCTFail("Expected malformed entry to be unknown") }
        XCTAssertEqual(kind, "malformed")
    }

    func testAPIErrorDecodingDetailContainsCodingPath() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.response(status: 200, body: Data("{\"sessions\":[{\"id\":123}]}".utf8))
        }

        do {
            _ = try await makeClient().state()
            XCTFail("Expected decoding failure")
        } catch let error as APIError {
            guard case .decoding(let detail) = error else { return XCTFail("Expected decoding error") }
            XCTAssertTrue(detail.contains("sessions[0].id"), detail)
        }
    }

    func testRequestsBearerAndMapsErrors() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(request.url?.path, "/api/bootstrap")
            return StubURLProtocol.response(status: 200, body: Data("{\"apiVersion\":2,\"capabilities\":{\"pagination\":true}}".utf8))
        }
        let client = makeClient(token: "token")
        let bootstrap = try await client.bootstrap()
        XCTAssertEqual(bootstrap.apiVersion, 2)

        let failures = await client.authenticationFailures
        var failureIterator = failures.makeAsyncIterator()
        StubURLProtocol.handler = { _ in StubURLProtocol.response(status: 401, body: Data("{\"error\":\"no\"}".utf8)) }
        do { _ = try await client.state(); XCTFail("Expected unauthorized") }
        catch let error as APIError { XCTAssertEqual(error, .unauthorized) }
        let signal: Void? = await failureIterator.next()
        XCTAssertNotNil(signal)
    }

    func testEventRequestUsesSSEAcceptAndBearerHeaders() async throws {
        let client = makeClient(token: "token")
        let request = await client.eventRequest()
        XCTAssertEqual(request.url?.path, "/api/events")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testPeerConversationApprovalDecodesDaemonBootstrapAndSSEShapes() throws {
        let approvalJSON = """
        {
          "requestId":"peer-approval-1",
          "sessionId":"approval-flow-light-mode",
          "kind":"peer_conversation",
          "tool_name":"peer_conversation",
          "tool_input":{
            "request":"Stockade session ‘thread \\\"X\\\" in #general’ wants to message ‘Approval Flow Light Mode’. Allow?",
            "from":"thread \\\"X\\\" in #general",
            "host":"Stockade",
            "to":"Approval Flow Light Mode",
            "message":"Please check the cross-controller build status."
          },
          "receivedAt":"2026-10-27T01:00:00.000Z",
          "holdLimitMs":590000,
          "mode":"remote",
          "status":"remote"
        }
        """
        let bootstrap = try JSONDecoder.ccKit().decode(StateSnapshot.self, from: Data("{\"sessions\":[{\"id\":\"approval-flow-light-mode\",\"pending\":[\(approvalJSON)]}]}".utf8))
        let approval = try XCTUnwrap(bootstrap.sessions?.first?.pending?.first)
        XCTAssertEqual(approval.kind, .peerConversation)
        XCTAssertEqual(approval.peerConversation, PeerConversationApproval(
            senderHost: "Stockade",
            senderLabel: "thread \"X\" in #general",
            targetLabel: "Approval Flow Light Mode",
            messagePreview: "Please check the cross-controller build status."
        ))

        guard case .approval(let event)? = LiveEvent.decode(name: "approval", data: approvalJSON) else {
            return XCTFail("Expected an approval SSE event")
        }
        XCTAssertEqual(event.kind, .peerConversation)
        XCTAssertEqual(event.toolInput, approval.toolInput)
    }

    func testPeerConversationListAndRevokeUseDaemonRoutes() async throws {
        var paths: [(String, String)] = []
        StubURLProtocol.handler = { request in
            let method = request.httpMethod ?? ""
            let path = request.url?.path ?? ""
            paths.append((method, path))
            if method == "GET" {
                return StubURLProtocol.response(status: 200, body: Data("""
                [{"id":"74dca0e9cd297800","peer":{"host":"stockade","hostLabel":"Stockade","ref":"stockade1","label":"thread \\\"X\\\" in #general"},"local":{"ref":"local1","label":"Approval Flow Light Mode"},"state":"allowed","since":"2026-10-27T01:00:00.000Z","until":"2026-10-27T02:00:00.000Z"}]
                """.utf8))
            }
            return StubURLProtocol.response(status: 204, body: Data())
        }
        let client = makeClient()
        let conversations = try await client.peerConversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].peer.label, "thread \"X\" in #general")
        XCTAssertEqual(conversations[0].lastActive, Date(timeIntervalSince1970: 1793062800))
        try await client.revokePeerConversation(id: conversations[0].id)
        XCTAssertEqual(paths.map { $0.0 }, ["GET", "DELETE"])
        XCTAssertEqual(paths.map { $0.1 }, ["/api/peer-conversations", "/api/peer-conversations/74dca0e9cd297800"])
    }

    func testEventRequestOptsIntoSubagentUpsertsWhenAdvertised() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in
            StubURLProtocol.response(status: 200, body: Data("{\"apiVersion\":2,\"capabilities\":{\"subagentUpsert\":true}}".utf8))
        }
        _ = try await client.bootstrap()
        let request = await client.eventRequest()
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "subagentUpsert", value: "true")])
    }

    func testMessageResultDecodesCommandOutputAndRoute() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.response(status: 200, body: Data("{\"delivered\":true,\"route\":\"mod\",\"queued\":true,\"output\":\"Context: 42%\"}".utf8))
        }
        let result = try await makeClient().message(sessionID: "s", text: "/context")
        XCTAssertEqual(result, MessageResult(delivered: true, queued: true, route: "mod", output: "Context: 42%"))
    }

    func testNewSessionOptionsAndBackgroundStateDecode() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/sessions/new-options" {
                return StubURLProtocol.response(status: 200, body: Data("""
                {"folders":[{"path":"/Users/test/project","name":"project","lastUsedAt":"2026-10-13T12:00:00Z"}],"models":[{"id":"opus","label":"Opus"}],"defaultModel":"opus"}
                """.utf8))
            }
            return StubURLProtocol.response(status: 200, body: Data("""
            {"sessions":[{"id":"live","live":true,"background":{"shortId":"bg-123"}}],"sleeping":[{"id":"sleep","shortId":"sleep-123","name":"Sleeping project","cwd":"/Users/test/project","project":"project","lastActiveAt":"2026-10-13T11:00:00Z"}]}
            """.utf8))
        }
        let client = makeClient()
        let options = try await client.newSessionOptions()
        XCTAssertEqual(options.folders.first?.path, "/Users/test/project")
        XCTAssertEqual(options.models.first?.id, "opus")
        XCTAssertEqual(options.defaultModel, "opus")
        let state = try await client.state()
        XCTAssertEqual(state.sessions?.first?.background?.shortId, "bg-123")
        XCTAssertEqual(state.sleeping?.first?.shortId, "sleep-123")
    }

    func testCreateAndWakeSessionRoutes() async throws {
        var paths: [String] = []
        StubURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            if request.url?.path == "/api/sessions" {
                return StubURLProtocol.response(status: 200, body: Data("{\"id\":\"session-new\",\"shortId\":\"new-123\",\"name\":\"New\"}".utf8))
            }
            return StubURLProtocol.response(status: 200, body: Data("{\"id\":\"session-new\"}".utf8))
        }
        let client = makeClient()
        let created = try await client.createSession(cwd: "/Users/test/project", model: nil)
        let woken = try await client.wakeSession(id: "sleep-123")
        XCTAssertEqual(created.id, "session-new")
        XCTAssertEqual(woken.id, "session-new")
        XCTAssertEqual(paths, ["/api/sessions", "/api/sessions/sleep-123/wake"])
    }

    func testCreateAgentSessionPostsAgentAndPrompt() async throws {
        var bodies: [Data] = []
        StubURLProtocol.handler = { request in
            if let body = APIClientTests.bodyData(for: request) { bodies.append(body) }
            return StubURLProtocol.response(status: 200, body: Data("{\"id\":\"created-1\",\"shortId\":\"create\",\"name\":\"Check the build\"}".utf8))
        }
        let client = makeClient()
        let created = try await client.createAgentSession(agentId: "main", prompt: "Check the build")
        XCTAssertEqual(created, CreatedSession(id: "created-1", shortId: "create", name: "Check the build"))
        let body = try XCTUnwrap(bodies.first.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(body, ["agentId": "main", "prompt": "Check the build"])
    }

    func testCreateSessionEncodesOptionalAgentOnlyWhenSet() async throws {
        var bodies: [Data] = []
        StubURLProtocol.handler = { request in
            if let body = APIClientTests.bodyData(for: request) { bodies.append(body) }
            return StubURLProtocol.response(status: 200, body: Data("{\"id\":\"created-1\",\"shortId\":\"create\"}".utf8))
        }
        let client = makeClient()
        _ = try await client.createSession(cwd: "/tmp/project", prompt: "Review", agent: "reviewer")
        _ = try await client.createSession(cwd: "/tmp/project", prompt: "Default", agent: nil)

        let withAgent = try XCTUnwrap(bodies.first.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let withoutAgent = try XCTUnwrap(bodies.last.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(withAgent["agent"] as? String, "reviewer")
        XCTAssertNil(withoutAgent["agent"])
    }

    func testMessageNowAndMultipartUpload() async throws {
        var bodies: [Data] = []
        var contentTypes: [String?] = []
        StubURLProtocol.handler = { request in
            if let body = APIClientTests.bodyData(for: request) { bodies.append(body) }
            contentTypes.append(request.value(forHTTPHeaderField: "Content-Type"))
            if request.url?.path.hasSuffix("/files") == true { return StubURLProtocol.response(status: 200, body: Data("{\"files\":[{\"name\":\"a.txt\",\"size\":3,\"mime\":\"text/plain\"}]}".utf8)) }
            return StubURLProtocol.response(status: 200, body: Data("{\"delivered\":true,\"queued\":false,\"route\":\"socket\"}".utf8))
        }
        let client = makeClient()
        let result = try await client.message(sessionID: "s", text: "hello", now: true)
        XCTAssertEqual(result.delivered, true)
        _ = try await client.uploadFile(sessionID: "s", data: Data("abc".utf8), filename: "a.txt", mimeType: "text/plain")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies.contains { String(decoding: $0, as: UTF8.self).contains("\"now\":true") })
        XCTAssertTrue(contentTypes.contains { $0?.contains("multipart/form-data") == true })
    }

    private func makeClient(token: String? = nil) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return APIClient(baseURL: URL(string: "http://localhost:47832")!, bearerToken: token, session: URLSession(configuration: configuration))
    }

    private static func bodyData(for request: URLRequest) -> Data? {
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

private final class StubURLProtocol: URLProtocol {
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
    static func response(status: Int, body: Data) -> (HTTPURLResponse, Data) { (HTTPURLResponse(url: URL(string: "http://localhost")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, body) }
}
