import Foundation
import Observation
import XCTest
@testable import CCKit

@MainActor
final class SessionStoreTests: XCTestCase {
    func testLoadInitialPublishesIsLoaded() async throws {
        let entry = TranscriptEntry.assistant(AssistantEntry(id: "entry-1", text: "loaded"))
        SessionStoreURLProtocol.body = Data("[{\"kind\":\"assistant\",\"id\":\"entry-1\",\"text\":\"loaded\"}]".utf8)
        let client = APIClient(
            baseURL: URL(string: "http://localhost:47832")!,
            session: SessionStoreURLProtocol.session
        )
        let store = SessionStore(
            session: Session(id: "session-1", live: true),
            client: client
        )
        let changed = expectation(description: "isLoaded observation changed")

        withObservationTracking {
            _ = store.isLoaded
        } onChange: {
            changed.fulfill()
        }

        try await store.loadInitial()
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.entries, [entry])
    }
}

private final class SessionStoreURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionStoreURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
