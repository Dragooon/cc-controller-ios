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
