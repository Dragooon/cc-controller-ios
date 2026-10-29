import Foundation
import Observation
import XCTest
@testable import CCKit

@MainActor
final class SessionStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SessionStoreURLProtocol.reset()
    }

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

    func testCachedStoreDoesNotDeclareGapBeforeItsInitialPageConfirmsTheCount() async throws {
        let client = makeClient()
        let cached = entries(from: 0, through: 399)
        let pageEntries = [cached.last!] + entries(from: 400, through: 498)
        SessionStoreURLProtocol.completions = [
            .succeed(try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true)))),
            .suspend,
        ]
        _ = try await client.bootstrap()
        let store = SessionStore(
            session: Session(id: "session-1", live: true),
            client: client,
            entries: cached,
            serverTotal: 3819
        )
        let initial = Task { try await store.loadInitial() }
        await waitForRequest(count: 2)

        store.observeServerTotal(3819)
        _ = store.mergeLive([entries(from: 400, through: 400)[0]], entryCount: 3820)
        XCTAssertFalse(store.hasTranscriptGap)
        XCTAssertEqual(SessionStoreURLProtocol.requests.count, 2, "State/live updates must not start a reset fetch before initial confirmation")

        SessionStoreURLProtocol.completeNext(.succeed(pageData(entries: pageEntries, total: 3819, hasMore: true)))
        _ = try await initial.value

        XCTAssertEqual(store.confirmedTotal, 3819)
        XCTAssertTrue(store.entries.contains(where: { $0.id == "entry-400" }))
    }

    func testTranscriptOnlyStoreLoadsSleepingTranscript() async throws {
        let client = makeClient()
        let sleepingEntries = entries(from: 1, through: 2)
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: sleepingEntries, total: 2, hasMore: false),
        ]
        _ = try await client.bootstrap()
        let store = SessionStore(
            session: Session(id: "sleeping-1", live: false, state: .idle),
            client: client,
            transcriptOnly: true
        )

        try await store.loadInitial()

        XCTAssertEqual(store.entries.map(\.id), ["entry-1", "entry-2"])
        XCTAssertTrue(store.isLoaded)
    }

    func testTranscriptOnlyStoreContinuesLiveWithoutDuplicatingEntryIDs() async throws {
        let client = makeClient()
        let sleepingEntries = entries(from: 1, through: 2)
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: sleepingEntries, total: 2, hasMore: false),
        ]
        _ = try await client.bootstrap()
        let store = SessionStore(
            session: Session(id: "sleeping-1", live: false, state: .idle),
            client: client,
            transcriptOnly: true
        )
        try await store.loadInitial()
        store.updateSession(Session(id: "sleeping-1", live: true, state: .idle))

        store.merge(entries(from: 2, through: 3), appendNewEntries: true)

        XCTAssertEqual(store.entries.map(\.id), ["entry-1", "entry-2", "entry-3"])
        XCTAssertEqual(Set(store.entries.compactMap(\.id)).count, 3)
    }

    func testTranscriptOnlyStoreKeepsEntriesWhenWakeFails() async throws {
        let client = makeClient()
        let sleepingEntries = entries(from: 1, through: 2)
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: sleepingEntries, total: 2, hasMore: false),
        ]
        _ = try await client.bootstrap()
        let store = SessionStore(
            session: Session(id: "sleeping-1", live: false, state: .idle),
            client: client,
            transcriptOnly: true
        )
        try await store.loadInitial()

        XCTAssertEqual(store.entries.map(\.id), ["entry-1", "entry-2"])
        XCTAssertFalse(store.session.live == true)
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

    func testLoadInitialUsesConfiguredTail() async throws {
        let client = makeClient()
        SessionStoreURLProtocol.requests = []
        SessionStoreURLProtocol.bodies = [
            try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true))),
            pageData(entries: entries(from: 100, through: 119), total: 500, hasMore: true),
        ]
        _ = try await client.bootstrap()
        let store = SessionStore(
            session: Session(id: "session-1", live: true),
            client: client,
            initialTranscriptTail: 20
        )

        try await store.loadInitial()

        let query = URLComponents(url: try XCTUnwrap(SessionStoreURLProtocol.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "tail" })?.value, "20")
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

    func testLoadInitialRetriesAfterInFlightRefetchFails() async throws {
        let client = makeClient()
        let page = pageData(entries: entries(from: 1, through: 1), total: 1, hasMore: false)
        SessionStoreURLProtocol.completions = [
            .succeed(try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true)))),
            .suspend,
            .fail(TestTranscriptError.failed),
            .succeed(page),
        ]
        _ = try await client.bootstrap()
        let store = makeStore(client: client)

        let refetch = Task { try await store.refetchTail(limit: 50) }
        await waitForRequest(count: 2)
        let initial = Task { try await store.loadInitial() }
        SessionStoreURLProtocol.completeNext()

        _ = try? await refetch.value
        _ = try await initial.value

        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(SessionStoreURLProtocol.requests.count, 3)
    }

    func testOverlappingLoadInitialCallsShareSuccessfulRequest() async throws {
        let client = makeClient()
        let page = pageData(entries: entries(from: 1, through: 1), total: 1, hasMore: false)
        SessionStoreURLProtocol.completions = [
            .succeed(try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true)))),
            .suspend,
        ]
        _ = try await client.bootstrap()
        let store = makeStore(client: client)

        let first = Task { try await store.loadInitial() }
        await waitForRequest(count: 2)
        let second = Task { try await store.loadInitial() }
        SessionStoreURLProtocol.completeNext(.succeed(page))

        _ = try await first.value
        _ = try await second.value

        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(SessionStoreURLProtocol.requests.count, 2)
    }

    func testOverlappingRefetchesCoalesceFollowUpToLargestLimit() async throws {
        let client = makeClient()
        let initialPage = pageData(entries: entries(from: 1, through: 1), total: 1, hasMore: false)
        let refetchedPage = pageData(entries: entries(from: 2, through: 2), total: 2, hasMore: false)
        SessionStoreURLProtocol.completions = [
            .succeed(try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true)))),
            .suspend,
            .suspend,
        ]
        _ = try await client.bootstrap()
        let store = makeStore(client: client)
        let initial = Task { try await store.loadInitial() }
        await waitForRequest(count: 2)

        let first = Task { try await store.refetchTail(limit: 20) }
        let second = Task { try await store.refetchTail(limit: 300) }
        let third = Task { try await store.refetchTail(limit: 100, reset: true) }
        SessionStoreURLProtocol.completeNext(.succeed(initialPage))
        await waitForRequest(count: 3)

        let query = URLComponents(url: try XCTUnwrap(SessionStoreURLProtocol.requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "tail" })?.value, "300")
        SessionStoreURLProtocol.completeNext(.succeed(refetchedPage))

        _ = try await initial.value
        _ = try await first.value
        _ = try await second.value
        _ = try await third.value
        XCTAssertEqual(SessionStoreURLProtocol.requests.count, 3)
    }

    func testCancelledOwningFetchCanBeRecoveredByWaitingLoadInitial() async throws {
        let client = makeClient()
        let page = pageData(entries: entries(from: 1, through: 1), total: 1, hasMore: false)
        SessionStoreURLProtocol.completions = [
            .succeed(try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true)))),
            .suspend,
            .succeed(page),
        ]
        _ = try await client.bootstrap()
        let store = makeStore(client: client)
        let owner = Task { try await store.loadInitial() }
        await waitForRequest(count: 2)
        let waiter = Task { try await store.loadInitial() }

        owner.cancel()
        _ = try? await owner.value
        _ = try await waiter.value

        XCTAssertTrue(store.isLoaded)
        XCTAssertEqual(SessionStoreURLProtocol.requests.count, 3)
    }

    func testLoadEarlierDoesNotRunDuringTranscriptFetch() async throws {
        let client = makeClient()
        let initialPage = pageData(entries: entries(from: 1, through: 1), total: 2, hasMore: true)
        SessionStoreURLProtocol.completions = [
            .succeed(try! JSONEncoder.ccKit().encode(Bootstrap(capabilities: Capabilities(pagination: true)))),
            .succeed(initialPage),
            .suspend,
        ]
        _ = try await client.bootstrap()
        let store = makeStore(client: client)
        try await store.loadInitial()
        let refetch = Task { try await store.refetchTail() }
        await waitForRequest(count: 3)

        _ = try await store.loadEarlier()

        XCTAssertEqual(SessionStoreURLProtocol.requests.count, 3)
        SessionStoreURLProtocol.completeNext(.succeed(initialPage))
        _ = try? await refetch.value
    }

    private func waitForRequest(count: Int) async {
        for _ in 0..<100 where SessionStoreURLProtocol.requests.count < count {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(SessionStoreURLProtocol.requests.count, count)
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

private enum TestTranscriptError: Error {
    case failed
}

private final class SessionStoreURLProtocol: URLProtocol {
    enum Completion {
        case suspend
        case succeed(Data)
        case fail(Error)
        case cancel
    }

    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var completions: [Completion] = []
    nonisolated(unsafe) static var suspended: [SessionStoreURLProtocol] = []
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionStoreURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    static func reset() {
        body = Data()
        bodies = []
        requests = []
        completions = []
        suspended = []
    }

    static func completeNext(_ completion: Completion? = nil) {
        guard !suspended.isEmpty else { return }
        let request = suspended.removeFirst()
        let next = completion ?? (completions.isEmpty ? .succeed(body) : completions.removeFirst())
        request.complete(next)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let completion = Self.completions.isEmpty
            ? .succeed(Self.bodies.isEmpty ? Self.body : Self.bodies.removeFirst())
            : Self.completions.removeFirst()
        complete(completion)
    }

    override func stopLoading() {
        Self.suspended.removeAll { $0 === self }
    }

    private func complete(_ completion: Completion) {
        guard let client else { return }
        switch completion {
        case .suspend:
            Self.suspended.append(self)
        case .succeed(let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            client.urlProtocol(self, didFailWithError: error)
        case .cancel:
            client.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
    }
}
