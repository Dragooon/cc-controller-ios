import Foundation
import XCTest
@testable import CCKit

final class DiskCacheTests: XCTestCase {
    func testDefaultDebounceIsThirtySeconds() async {
        let cache = DiskCache(directory: temporaryDirectory())
        let debounce = await cache.debounce
        XCTAssertEqual(debounce, .seconds(30))
    }

    func testTranscriptFileKeepsMalformedKnownKindBetweenValidEntries() async throws {
        let directory = temporaryDirectory()
        let cache = DiskCache(directory: directory)
        let state = DiskCacheState(
            bootstrap: Bootstrap(state: StateSnapshot(sessions: [Session(id: "session-1")])),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        await cache.saveNow(state, changedTranscripts: ["session-1": []], retainedTranscriptKeys: ["session-1"])
        let url = await cache.transcriptFileURL(for: "session-1")
        try Data("""
        {"v":3,"entries":[{"kind":"assistant","id":"before","text":"Before"},{"kind":"prompt","id":"bad","paste":[]},{"kind":"assistant","id":"after","text":"After"}]}
        """.utf8).write(to: url, options: .atomic)

        let loaded = try await cache.load()
        let entries = try XCTUnwrap(loaded?.transcripts["session-1"])

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.id, "before")
        XCTAssertEqual(entries.last?.id, "after")
        guard case .unknown(let kind, _) = entries[1] else { return XCTFail("Expected malformed entry to be unknown") }
        XCTAssertEqual(kind, "malformed")
    }

    func testTranscriptFileRoundTripsEntriesRevisionAndEpoch() async throws {
        let directory = temporaryDirectory()
        let cache = DiskCache(directory: directory)
        let state = state(value: "v2")
        let entries = [entry(id: "v2-entry", text: "cached")]

        await cache.saveNow(
            state,
            changedTranscripts: ["v2": entries],
            changedTranscriptMetadata: ["v2": TranscriptCacheMetadata(rev: 42, epoch: "epoch-a")],
            retainedTranscriptKeys: ["v2"]
        )

        let loadedValue = try await cache.load()
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.transcripts["v2"], entries)
        XCTAssertEqual(loaded.transcriptMetadata["v2"], TranscriptCacheMetadata(rev: 42, epoch: "epoch-a"))
        let data = try Data(contentsOf: await cache.transcriptFileURL(for: "v2"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["v"] as? Int, TranscriptCacheFile.currentVersion)
        XCTAssertEqual(object["rev"] as? Int, 42)
        XCTAssertEqual(object["epoch"] as? String, "epoch-a")
    }

    func testOlderTranscriptFormatsAreDroppedOnLoad() async throws {
        let directory = temporaryDirectory()
        let cache = DiskCache(directory: directory)
        let state = state(value: "older")
        await cache.saveNow(state, changedTranscripts: ["older": [entry(id: "older")]], retainedTranscriptKeys: ["older"])
        let url = await cache.transcriptFileURL(for: "older")
        for stale in ["[{\"kind\":\"assistant\",\"id\":\"older\"}]", "{\"v\":2,\"entries\":[{\"kind\":\"assistant\",\"id\":\"older\"}]}"] {
            try Data(stale.utf8).write(to: url, options: .atomic)

            let loadedValue = try await cache.load()
            let loaded = try XCTUnwrap(loadedValue)
            XCTAssertNil(loaded.transcripts["older"])
            XCTAssertNil(loaded.transcriptMetadata["older"])
        }
    }

    func testOnlyChangedTranscriptsAreWrittenAndUnopenedTranscriptSurvives() async throws {
        let directory = temporaryDirectory()
        let cache = DiskCache(directory: directory)
        let first = state(value: "first")
        let firstEntries = [entry(id: "first", text: "before")]
        let unopenedEntries = [entry(id: "unopened", text: "untouched")]

        await cache.saveNow(
            first,
            changedTranscripts: ["first": firstEntries, "unopened": unopenedEntries],
            retainedTranscriptKeys: ["first", "unopened"]
        )
        let unopenedURL = await cache.transcriptFileURL(for: "unopened")
        let unopenedData = try Data(contentsOf: unopenedURL)

        await cache.saveNow(
            state(value: "latest"),
            changedTranscripts: ["first": [entry(id: "first", text: "after")]],
            retainedTranscriptKeys: ["first", "unopened"]
        )

        XCTAssertEqual(try Data(contentsOf: unopenedURL), unopenedData)
        let loaded = try await cache.load()
        XCTAssertEqual(loaded?.transcripts["unopened"], unopenedEntries)
        XCTAssertEqual(loaded?.transcripts["first"], [entry(id: "first", text: "after")])
    }

    func testPruningRemovesTranscriptFilesMissingFromSnapshot() async throws {
        let cache = DiskCache(directory: temporaryDirectory())
        await cache.saveNow(
            state(value: "initial"),
            changedTranscripts: ["keep": [entry(id: "keep")], "remove": [entry(id: "remove")]],
            retainedTranscriptKeys: ["keep", "remove"]
        )

        await cache.saveNow(
            state(value: "pruned"),
            changedTranscripts: [:],
            retainedTranscriptKeys: ["keep"]
        )

        let loaded = try await cache.load()
        XCTAssertEqual(Set(loaded?.transcripts.keys ?? Dictionary<String, [TranscriptEntry]>().keys), ["keep"])
    }

    func testOldFormatStateIsTolerated() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = LegacyState(
            bootstrap: Bootstrap(state: StateSnapshot(sessions: [Session(id: "legacy")])),
            transcripts: ["legacy": [entry(id: "legacy", text: "old")]],
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let data = try JSONEncoder.ccKit().encode(legacy)
        try data.write(to: directory.appendingPathComponent("state.json"))

        let loaded = try await DiskCache(directory: directory).load()
        XCTAssertEqual(loaded?.transcripts["legacy"]?.first?.id, "legacy")
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

    private func entry(id: String, text: String? = nil) -> TranscriptEntry {
        .assistant(AssistantEntry(id: id, text: text))
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

private struct LegacyState: Codable {
    let bootstrap: Bootstrap
    let transcripts: [String: [TranscriptEntry]]
    let updatedAt: Date
}
