import Foundation
import XCTest
@testable import CCKit

@MainActor
final class ConnectionRouterTests: XCTestCase {
    func testCancellingPathChangeIteratorDoesNotEndTheStream() async throws {
        let router = makeRouter()
        try await Task.sleep(for: .milliseconds(100))
        let first = Task { await nextEvent(from: router.pathChangeEvents()) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        let firstReceived = await first.value
        XCTAssertFalse(firstReceived)

        let second = Task { await nextEvent(from: router.pathChangeEvents()) }
        try await Task.sleep(for: .milliseconds(20))
        router.emitPathChangeForTesting()

        let secondReceived = await second.value
        XCTAssertTrue(secondReceived)
    }

    func testOnePathChangeReachesBothSubscribers() async throws {
        let router = makeRouter()
        try await Task.sleep(for: .milliseconds(100))
        let first = Task { await nextEvent(from: router.pathChangeEvents()) }
        let second = Task { await nextEvent(from: router.pathChangeEvents()) }
        try await Task.sleep(for: .milliseconds(20))
        router.emitPathChangeForTesting()

        let firstReceived = await first.value
        let secondReceived = await second.value
        XCTAssertTrue(firstReceived)
        XCTAssertTrue(secondReceived)
    }

    private func makeRouter() -> ConnectionRouter {
        ConnectionRouter(baseURL: URL(string: "http://127.0.0.1:47832")!)
    }

    private func nextEvent(from stream: AsyncStream<Void>, timeout: Duration = .seconds(1)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
