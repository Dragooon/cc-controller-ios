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

    func testContextUsageOmitsDaemonPlaceholderZeros() {
        XCTAssertEqual(formatContextUsage(Usage(contextTokens: 0, contextWindow: 200_000, contextPercent: 0, messages: 0)), "")
        XCTAssertEqual(sessionDetailSubtitle(Session(state: .idle, usage: Usage(contextPercent: 0))), "idle")
    }

    func testTokenUsageSegmentsOmitUnknownAndPlaceholderZeroValues() {
        XCTAssertEqual(
            formatTokenUsageSegments(Usage(totalInputTokens: 3_100_000, outputTokens: 84_000, cacheHitRate: 0.92)),
            ["3.1M in", "84k out", "cache 92%"]
        )
        XCTAssertEqual(formatTokenUsageSegments(Usage(inputTokens: 0, outputTokens: 0, cacheHitRate: 0)), [])
        XCTAssertEqual(formatTokenUsageSegments(nil), [])
    }

    func testDefaultSlashCommandsIncludeFullStaticComposerList() {
        XCTAssertEqual(defaultSlashCommands.map(\.command), ["/compact", "/clear", "/model", "/cost", "/context", "/review", "/init", "/help"])
    }

    func testComposerModelNameFormatsKnownModelsAndHidesUnknownValues() {
        XCTAssertEqual(composerModelName("claude-fable-5-1"), "Fable 5.1")
        XCTAssertNil(composerModelName(nil))
        XCTAssertNil(composerModelName(""))
        XCTAssertNil(composerModelName("unknown"))
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

    func testSubagentSubtitleUsesLowercaseStateAndElapsedTime() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let subagent = Subagent(
            state: .running,
            startedAt: startedAt
        )

        XCTAssertEqual(subagentSubtitle(subagent, now: startedAt.addingTimeInterval(3 * 60)), "running · 3m")
    }

    func testSubagentSubtitleUsesFinishedTimeAndOmitsUnknownValues() {
        let subagent = Subagent(state: .done)
        XCTAssertEqual(subagentSubtitle(subagent), "done")
    }

    func testNativeToolRunLabelReflectsRunningMembers() {
        let running = ToolRun(entries: [
            ToolEntry(tool: "Read", state: .done),
            ToolEntry(tool: "Bash", state: .running),
        ])
        let finished = ToolRun(entries: [
            ToolEntry(tool: "Read", state: .done),
            ToolEntry(tool: "Bash", state: .done),
        ])

        XCTAssertEqual(nativeToolRunLabel(running), "Running 2 tools")
        XCTAssertEqual(nativeToolRunLabel(finished), "Ran 2 tools")
    }

    func testToolEntryPreservesDurationForDetailPresentation() throws {
        let original = ToolEntry(tool: "Bash", result: "ok", state: .done, durationMs: 2_400)
        let data = try JSONEncoder.ccKit().encode(original)
        let decoded = try JSONDecoder.ccKit().decode(ToolEntry.self, from: data)
        XCTAssertEqual(decoded.durationMs, 2_400)
        XCTAssertEqual(decoded, original)
    }

    func testApprovalFallbackTextClampsAndFormatsMinutes() {
        XCTAssertEqual(approvalFallbackText(remaining: 252), "falls back to the terminal in 4:12")
        XCTAssertEqual(approvalFallbackText(remaining: 5), "falls back to the terminal in 0:05")
        XCTAssertEqual(approvalFallbackText(remaining: -1), "falls back to the terminal in 0:00")
    }

    func testApprovalWaitingTextUsesInjectedShortTimeStyle() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Australia/Sydney")!
        calendar.timeZone = timeZone
        let since = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 9, minute: 33))!

        XCTAssertEqual(
            approvalWaitingText(
                since: since,
                calendar: calendar,
                timeZone: timeZone,
                locale: Locale(identifier: "en_AU")
            ),
            "Waiting in the terminal since 9:33\u{202F}am"
        )
    }

    func testMoreWaitingTextOmitsEmptyStack() {
        XCTAssertNil(moreWaitingText(count: 0))
        XCTAssertEqual(moreWaitingText(count: 1), "1 more waiting")
        XCTAssertEqual(moreWaitingText(count: 2), "2 more waiting")
    }

    func testApprovalHoldFractionClampsToTheHold() {
        XCTAssertEqual(approvalHoldFraction(remaining: 252, total: 590), 252.0 / 590.0, accuracy: 0.0001)
        XCTAssertEqual(approvalHoldFraction(remaining: -1, total: 590), 0)
        XCTAssertEqual(approvalHoldFraction(remaining: 700, total: 590), 1)
        XCTAssertEqual(approvalHoldFraction(remaining: 1, total: 0), 0)
    }
}
