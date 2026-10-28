import Foundation
import XCTest
@testable import CCKit

final class ConnectionNoticePolicyTests: XCTestCase {
    func testSuccessWithinLaunchWindowDoesNotShowNotice() {
        let clock = PolicyTestClock()
        var policy = ConnectionNoticePolicy(clock: clock)
        policy.beginGracePeriod()

        XCTAssertEqual(policy.failureDecision(), .suppress(until: clock.now.addingTimeInterval(8)))
        clock.now = clock.now.addingTimeInterval(2)
        policy.markSuccess()
        clock.now = clock.now.addingTimeInterval(10)

        XCTAssertEqual(policy.failureDecision(), .suppress(until: clock.now.addingTimeInterval(3)))
    }

    func testStillFailingAtEightSecondsShowsNotice() {
        let clock = PolicyTestClock()
        var policy = ConnectionNoticePolicy(clock: clock)
        policy.beginGracePeriod()
        XCTAssertEqual(policy.failureDecision(), .suppress(until: clock.now.addingTimeInterval(8)))

        clock.now = clock.now.addingTimeInterval(8)

        XCTAssertEqual(policy.failureDecision(), .show)
    }

    func testForegroundWindowResetsWhileFailureIsInProgress() {
        let clock = PolicyTestClock()
        var policy = ConnectionNoticePolicy(clock: clock)
        policy.beginGracePeriod()
        XCTAssertEqual(policy.failureDecision(), .suppress(until: clock.now.addingTimeInterval(8)))

        clock.now = clock.now.addingTimeInterval(4)
        policy.beginGracePeriod()
        clock.now = clock.now.addingTimeInterval(3)

        XCTAssertEqual(policy.failureDecision(), .suppress(until: clock.now.addingTimeInterval(5)))
    }

    func testTwoSecondBlipWhileConnectedDoesNotShowNotice() {
        let clock = PolicyTestClock()
        var policy = ConnectionNoticePolicy(clock: clock)
        policy.markSuccess()

        XCTAssertEqual(policy.failureDecision(), .suppress(until: clock.now.addingTimeInterval(3)))
        clock.now = clock.now.addingTimeInterval(2)
        policy.markSuccess()

        XCTAssertEqual(policy.failureDecision(), .suppress(until: clock.now.addingTimeInterval(3)))
    }

    func testThreeSecondsOfContinuousFailureShowsNotice() {
        let clock = PolicyTestClock()
        var policy = ConnectionNoticePolicy(clock: clock)
        policy.markSuccess()
        XCTAssertEqual(policy.failureDecision(), .suppress(until: clock.now.addingTimeInterval(3)))

        clock.now = clock.now.addingTimeInterval(3)

        XCTAssertEqual(policy.failureDecision(), .show)
    }

    func testEligibleFirstAttemptErrorRetriesImmediately() async throws {
        ImmediateRetryProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImmediateRetryProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(baseURL: URL(string: "http://localhost:47832")!, session: session)
        let stream = EventStream(client: client, session: session)
        await stream.start()

        var iterator = stream.statuses.makeAsyncIterator()
        var reachedLive = false
        for _ in 0..<10 {
            guard let status = await iterator.next() else { break }
            if case .live = status {
                reachedLive = true
                break
            }
        }
        await stream.stop()

        XCTAssertTrue(reachedLive)
        XCTAssertEqual(ImmediateRetryProtocol.requestCount, 2)
    }
}

private final class ImmediateRetryProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        if Self.requestCount == 1 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
    }

    override func stopLoading() {}
}

private final class PolicyTestClock: CCKitClock, @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}
