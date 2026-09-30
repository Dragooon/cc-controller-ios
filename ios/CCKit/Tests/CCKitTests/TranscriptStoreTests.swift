import Foundation
import XCTest
@testable import CCKit

final class TranscriptStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100)
    private let t1 = Date(timeIntervalSince1970: 101)

    func testStableIDRevisionAndReplacementInPlace() {
        var store = TranscriptStore()
        let first = TranscriptEntry.tool(ToolEntry(id: "e1", rev: 1, ts: t0, toolUseId: "tool", tool: "Bash", text: "running", state: .running))
        let newer = TranscriptEntry.tool(ToolEntry(id: "e1", rev: 2, ts: t0, toolUseId: "tool", tool: "Bash", text: "done", state: .done))
        XCTAssertEqual(store.merge([first]).inserted.count, 1)
        XCTAssertEqual(store.merge([newer], replace: true).updatedIDs, ["e1"])
        XCTAssertEqual(store.entries, [newer])
        XCTAssertTrue(store.merge([first]).updatedIDs.isEmpty)
    }

    func testFallbackKeysForToolAndOrdinaryEntries() {
        var store = TranscriptStore()
        let tool = TranscriptEntry.tool(ToolEntry(ts: t0, toolUseId: "tool", text: "running"))
        let result = TranscriptEntry.tool(ToolEntry(ts: t1, toolUseId: "tool", text: "done"))
        let prompt = TranscriptEntry.prompt(PromptEntry(ts: t0, text: "hello"))
        XCTAssertEqual(store.merge([tool, prompt]).inserted.count, 2)
        XCTAssertEqual(store.merge([result], replace: true).updatedIDs.count, 1)
        XCTAssertEqual(store.entries.count, 2)
    }

    func testOutOfOrderEntriesAreInsertedByTimestamp() {
        var store = TranscriptStore()
        let late = TranscriptEntry.assistant(AssistantEntry(ts: t1, text: "late"))
        let early = TranscriptEntry.assistant(AssistantEntry(ts: t0, text: "early"))
        _ = store.merge([late])
        _ = store.merge([early])
        XCTAssertEqual(store.entries.map(\.text), ["early", "late"])
    }

    func testRefetchCannotRegressNewerReplacement() {
        var store = TranscriptStore()
        let replacement = TranscriptEntry.subagent(SubagentEntry(id: "a", rev: 4, ts: t0, toolUseId: "task", result: "new", state: .done))
        let staleFetch = TranscriptEntry.subagent(SubagentEntry(id: "a", rev: 2, ts: t0, toolUseId: "task", state: .running))
        _ = store.merge([replacement], replace: true)
        _ = store.merge([staleFetch])
        XCTAssertEqual(store.entries.first?.rev, 4)
        XCTAssertEqual(store.entries.first?.text, nil)
    }

    func testNoIDReplacementIsProtectedFromLaterRefetch() {
        var store = TranscriptStore()
        let running = TranscriptEntry.tool(ToolEntry(ts: t0, toolUseId: "task", text: "running", state: .running))
        let done = TranscriptEntry.tool(ToolEntry(ts: t0, toolUseId: "task", text: "done", state: .done))
        _ = store.merge([running])
        _ = store.merge([done], replace: true)
        _ = store.merge([running])
        XCTAssertEqual(store.entries.first?.text, "done")
    }
}
