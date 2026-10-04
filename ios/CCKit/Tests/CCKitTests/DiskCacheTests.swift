import Foundation
import XCTest
@testable import CCKit

final class DiskCacheTests: XCTestCase {
    func testDefaultDebounceIsFiveSeconds() async {
        let cache = DiskCache(directory: temporaryDirectory())
        let debounce = await cache.debounce
        XCTAssertEqual(debounce, .seconds(5))
    }

    func testDebouncedSaveKeepsTheLatestSnapshot() async throws {
        let directory = temporaryDirectory()
        let cache = DiskCache(directory: directory, debounce: .milliseconds(20))
        let first = state(value: "first")
        let latest = state(value: "latest")

        await cache.save(first)
        await cache.save(latest)
        try await Task.sleep(for: .milliseconds(50))
        await cache.flush()

        let loaded = try await cache.load()
        XCTAssertEqual(loaded, latest)
    }

    private func state(value: String) -> DiskCacheState {
        DiskCacheState(
            bootstrap: Bootstrap(state: StateSnapshot(sessions: [Session(id: value)])),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}
