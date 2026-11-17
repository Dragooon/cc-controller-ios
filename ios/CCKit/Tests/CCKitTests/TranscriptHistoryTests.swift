import Foundation
import XCTest
@testable import CCKit

final class TranscriptHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_793_000_000)

    func testATurnsNewestEntryTimeIsItsLatestEntry() {
        let turn = Turn(
            id: "turn",
            prompts: [PromptEntry(id: "prompt", ts: base)],
            items: [
                .tools(ToolRun(entries: [
                    ToolEntry(id: "quick", ts: base.addingTimeInterval(5), durationMs: 1_000),
                    // Started early and ran for five minutes: it counts from when it finished.
                    ToolEntry(id: "slow", ts: base.addingTimeInterval(2), durationMs: 300_000),
                ])),
                .subagent(SubagentEntry(id: "agent", ts: base.addingTimeInterval(10), finishedAt: base.addingTimeInterval(120))),
            ],
            end: nil,
            durationMs: 0,
            hasBody: true,
            live: false,
            hasWorkedFooter: false
        )

        XCTAssertEqual(turn.newestEntryTime, base.addingTimeInterval(302))
    }

    func testATurnWithoutTimesHasNoNewestEntryTime() {
        let turn = Turn(
            id: "turn",
            prompts: [PromptEntry(id: "prompt")],
            items: [],
            end: nil,
            durationMs: 0,
            hasBody: false,
            live: false,
            hasWorkedFooter: false
        )

        XCTAssertNil(turn.newestEntryTime)
    }

    func testRowsWrittenLongAgoAreHistoryAndRecentOnesAreNot() {
        // A resting session waking sends its old entries again one by one.
        XCTAssertTrue(transcriptRowsAreHistory(newestEntryTime: base, now: base.addingTimeInterval(3_600)))
        XCTAssertTrue(transcriptRowsAreHistory(newestEntryTime: base, now: base.addingTimeInterval(transcriptLiveWindow + 1)))
        // A row from the turn that is running now, delivered a moment later.
        XCTAssertFalse(transcriptRowsAreHistory(newestEntryTime: base, now: base.addingTimeInterval(2)))
        // The controller's clock a little ahead of this device.
        XCTAssertFalse(transcriptRowsAreHistory(newestEntryTime: base.addingTimeInterval(20), now: base))
        // Nothing to go by: treat it as happening now.
        XCTAssertFalse(transcriptRowsAreHistory(newestEntryTime: nil, now: base))
    }
}
