import Foundation
import Observation
import XCTest
@testable import CCKit

@MainActor
final class SessionStoreTests: XCTestCase {
    func testCachedEntriesAreLoadedBeforeInitialFetch() {
        let cached = TranscriptEntry.assistant(AssistantEntry(id: "cached", text: "cached"))
        let store = SessionStore(
            session: Session(id: "session-1", live: true),
            client: makeClient(),
            entries: [cached]
        )

        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(store.entries, [cached])
        XCTAssertEqual(store.turns.flatMap(\.items).count, 1)
    }

    func testLoadInitialMergesOverlappingPageAndKeepsCachedEntries() async throws {
        let cached = entries(from: 0, through: 1)
        let fresh = entries(from: 1, through: 2)
        let client = makeClient()
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: fresh, total: 4, hasMore: true),
        ]
        _ = try await client.bootstrap()
        let store = SessionStore(
            session: Session(id: "session-1", live: true),
            client: client,
            entries: cached
        )

        try await store.loadInitial()

        XCTAssertEqual(store.entries.map(\.id), ["entry-0", "entry-1", "entry-2"])
        XCTAssertTrue(store.hasMoreEarlier)
        XCTAssertEqual(store.totalEntries, 4)
    }

    func testLoadInitialReplacesStaleCacheWithoutOverlap() async throws {
        let cached = entries(from: 0, through: 1)
        let fresh = entries(from: 10, through: 11)
        let client = makeClient()
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: fresh, total: 11, hasMore: true),
        ]
        _ = try await client.bootstrap()
        let store = SessionStore(
            session: Session(id: "session-1", live: true),
            client: client,
            entries: cached
        )

        try await store.loadInitial()

        XCTAssertEqual(store.entries.map(\.id), ["entry-10", "entry-11"])
        XCTAssertTrue(store.hasMoreEarlier)
    }

    func testLoadInitialSetsNoEarlierWhenFetchedPageFillsTotal() async throws {
        let fresh = entries(from: 10, through: 11)
        let client = makeClient()
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: fresh, total: 2, hasMore: false),
        ]
        _ = try await client.bootstrap()
        let store = SessionStore(
            session: Session(id: "session-1", live: true),
            client: client,
            entries: entries(from: 0, through: 1)
        )

        try await store.loadInitial()

        XCTAssertFalse(store.hasMoreEarlier)
    }

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

    func testTailRefetchDoesNotPrependOrOverwritePagination() async throws {
        let initialEntries = entries(from: 100, through: 199)
        let refetchedEntries = entries(from: 0, through: 399)
        let client = makeClient()
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: initialEntries, total: 500, hasMore: true),
            pageData(entries: refetchedEntries, total: 500, hasMore: false),
        ]
        _ = try await client.bootstrap()
        let store = makeStore(client: client)

        try await store.loadInitial()
        try await store.refetchTail()

        XCTAssertEqual(store.entries.first?.id, "entry-100")
        XCTAssertFalse(store.entries.contains { ($0.id ?? "").compare("entry-100", options: .numeric) == .orderedAscending })
        XCTAssertTrue(store.hasMoreEarlier, "A non-reset tail refetch must preserve the loaded window's pagination state")
    }

    func testResetTailRefetchUsesInitialPageSize() async throws {
        let client = makeClient()
        let initialEntries = entries(from: 100, through: 199)
        SessionStoreURLProtocol.requests = []
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: initialEntries, total: 500, hasMore: true),
            pageData(entries: initialEntries, total: 500, hasMore: true),
        ]
        _ = try await client.bootstrap()
        let store = makeStore(client: client)

        try await store.loadInitial()
        try await store.refetchTail(reset: true)

        let query = URLComponents(url: try XCTUnwrap(SessionStoreURLProtocol.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "tail" })?.value, "100")
    }

    func testTailRefetchGapReplacesLoadedWindow() async throws {
        let initialEntries = entries(from: 100, through: 199)
        let refetchedEntries = entries(from: 400, through: 499)
        let client = makeClient()
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: initialEntries, total: 500, hasMore: true),
            pageData(entries: refetchedEntries, total: 500, hasMore: false),
        ]
        _ = try await client.bootstrap()
        let store = makeStore(client: client)

        try await store.loadInitial()
        try await store.refetchTail()

        XCTAssertEqual(store.entries.map(\.id), refetchedEntries.map(\.id))
        XCTAssertFalse(store.hasMoreEarlier)
    }

    private func makeClient() -> APIClient {
        APIClient(
            baseURL: URL(string: "http://localhost:47832")!,
            session: SessionStoreURLProtocol.session
        )
    }

    private func makeStore(client: APIClient) -> SessionStore {
        SessionStore(session: Session(id: "session-1", live: true), client: client)
    }

    private func entries(from first: Int, through last: Int) -> [TranscriptEntry] {
        (first...last).map { index in
            .assistant(AssistantEntry(
                id: "entry-\(index)",
                ts: Date(timeIntervalSince1970: Double(index)),
                text: "Entry \(index)"
            ))
        }
    }

    private func pageData(entries: [TranscriptEntry], total: Int, hasMore: Bool) -> Data {
        try! JSONEncoder.ccKit().encode(TranscriptPage(entries: entries, total: total, hasMore: hasMore))
    }
}

private final class SessionStoreURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionStoreURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.bodies.isEmpty ? Self.body : Self.bodies.removeFirst()
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
