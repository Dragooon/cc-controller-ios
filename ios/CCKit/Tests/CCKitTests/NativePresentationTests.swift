import XCTest
@testable import CCKit

final class NativePresentationTests: XCTestCase {
    func testSessionsSubtitleOrdersActiveStatesAndOmitsZeroes() {
        let sessions = [
            Session(state: .working),
            Session(state: .needsYou),
            Session(state: .working),
        ]

        XCTAssertEqual(sessionsSubtitle(sessions), "1 needs you · 2 working")
    }

    func testSessionsSubtitleReturnsAllIdle() {
        XCTAssertEqual(sessionsSubtitle([Session(state: .idle), Session(state: .idle)]), "All idle")
    }

    func testSessionsSubtitleReturnsNilForEmptySessions() {
        XCTAssertNil(sessionsSubtitle([]))
    }

    func testDisplayDurationOmitsZeroTrailingUnits() {
        XCTAssertEqual(displayDuration(42_000), "42s")
        XCTAssertEqual(displayDuration(4 * 60_000), "4m")
        XCTAssertEqual(displayDuration(4 * 60_000 + 12_000), "4m 12s")
        XCTAssertEqual(displayDuration(65 * 60_000), "1h 5m")
        XCTAssertEqual(displayDuration(2 * 60 * 60_000), "2h")
    }

    func testDisplayDurationUsesTenthsBelowTenSeconds() {
        XCTAssertEqual(displayDuration(2_400), "2.4s")
        XCTAssertEqual(displayDuration(9_950), "10.0s")
        XCTAssertEqual(displayDuration(10_000), "10s")
    }

    func testDisplayDurationClampsNegativeValues() {
        XCTAssertEqual(displayDuration(-1), "0.0s")
    }

    func testSessionDetailSubtitleUsesNativeDurationAndPercentComposition() {
        let idleSince = Date(timeIntervalSince1970: 1_000)
        let session = Session(
            state: .idle,
            usage: Usage(contextPercent: 67),
            idleSince: idleSince
        )

        XCTAssertEqual(
            sessionDetailSubtitle(session, now: Date(timeIntervalSince1970: 1_000 + 42 * 60)),
            "idle · 42m · ctx 67%"
        )
    }

    func testSessionDetailSubtitleIncludesAgentCount() {
        let session = Session(
            state: .working,
            usage: Usage(contextPercent: 32),
            subagents: [Subagent(agent: "researcher"), Subagent(agent: "engineer")],
            startedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(
            sessionDetailSubtitle(session, now: Date(timeIntervalSince1970: 2_000 + 65 * 60)),
            "working · 1h 5m · 2 agents · ctx 32%"
        )
    }
}
