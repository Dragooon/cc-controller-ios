import XCTest
@testable import CCKit

final class NativePresentationTests: XCTestCase {
    func testLatencyTextRoundsToWholeMillisecondsWithMinimum() {
        XCTAssertEqual(latencyText(.microseconds(200)), "1 ms")
        XCTAssertEqual(latencyText(.milliseconds(18) + .microseconds(400)), "18 ms")
        XCTAssertEqual(latencyText(.milliseconds(18) + .microseconds(600)), "19 ms")
        XCTAssertEqual(latencyText(.seconds(1) + .milliseconds(200)), "1200 ms")
    }

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

    func testFormatListDurationUsesCompactUnitBoundaries() {
        XCTAssertEqual(formatListDuration(-1), "0s")
        XCTAssertEqual(formatListDuration(59_999), "59s")
        XCTAssertEqual(formatListDuration(60_000), "1m")
        XCTAssertEqual(formatListDuration(59 * 60_000 + 59_999), "59m")
        XCTAssertEqual(formatListDuration(60 * 60_000), "1h 0m")
        XCTAssertEqual(formatListDuration(23 * 60 * 60_000 + 59 * 60_000), "23h 59m")
        XCTAssertEqual(formatListDuration(24 * 60 * 60_000), "1d 0h")
        XCTAssertEqual(formatListDuration(60 * 60 * 60_000 + 44 * 60_000 + 48_000), "2d 12h")
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

    func testSessionDetailSubtitleOmitsAgentCount() {
        let session = Session(
            state: .working,
            usage: Usage(contextPercent: 32),
            subagents: [Subagent(agent: "researcher"), Subagent(agent: "engineer")],
            startedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(
            sessionDetailSubtitle(session, now: Date(timeIntervalSince1970: 2_000 + 65 * 60)),
            "working · 1h 5m · ctx 32%"
        )
    }

    func testActivityCountsOnlyRunningAgentsAndShells() {
        let session = Session(
            subagents: [Subagent(state: .running), Subagent(state: .done), Subagent(state: .failed)],
            shells: [Shell(state: .running), Shell(state: .stopped)]
        )

        let counts = activityCounts(for: session)

        XCTAssertEqual(counts.agents, 1)
        XCTAssertEqual(counts.shells, 1)
    }

    func testActivitySummaryTextUsesSingularAndPluralLabels() {
        XCTAssertEqual(
            activitySummaryText(for: Session(subagents: [Subagent(state: .running), Subagent(state: .running)], shells: [Shell(state: .running)])),
            "2 agents · 1 shell"
        )
        XCTAssertEqual(activitySummaryText(for: Session(subagents: [Subagent(state: .running)])), "1 agent")
        XCTAssertEqual(activitySummaryText(for: Session(shells: [Shell(state: .running), Shell(state: .running), Shell(state: .running)])), "3 shells")
        XCTAssertNil(activitySummaryText(for: Session(subagents: [Subagent(state: .done)])))
    }

    func testFinishedRecentlyReturnsOnlyTenMinuteWindowNewestFirst() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recentAgent = Subagent(agentId: "agent", state: .done, finishedAt: now.addingTimeInterval(-4 * 60), result: "agent result")
        let recentShell = Shell(toolUseId: "shell", state: .failed, finishedAt: now.addingTimeInterval(-2 * 60))
        let boundary = Shell(toolUseId: "boundary", state: .stopped, finishedAt: now.addingTimeInterval(-10 * 60))
        let old = Subagent(agentId: "old", state: .done, finishedAt: now.addingTimeInterval(-11 * 60))
        let running = Shell(toolUseId: "running", state: .running, finishedAt: now.addingTimeInterval(-1 * 60))
        let session = Session(subagents: [recentAgent, old], shells: [recentShell, boundary, running])

        let items = finishedRecently(for: session, now: now)

        XCTAssertEqual(items.count, 3)
        guard case .shell(let first) = items[0], case .agent(let second) = items[1], case .shell(let third) = items[2] else {
            return XCTFail("Expected newest finished shell, agent, then boundary shell")
        }
        XCTAssertEqual(first.toolUseId, "shell")
        XCTAssertEqual(second.agentId, "agent")
        XCTAssertEqual(third.toolUseId, "boundary")
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
