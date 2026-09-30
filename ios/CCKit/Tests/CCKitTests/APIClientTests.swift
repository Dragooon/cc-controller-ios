import Foundation
import XCTest
@testable import CCKit

final class APIClientTests: XCTestCase {
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
