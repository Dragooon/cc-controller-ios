import Foundation
import XCTest
@testable import CCKit

@MainActor
final class SessionStoreIncrementalTests: XCTestCase {
    func testRandomTranscriptChangesMatchFullRegroup() {
        let seeds: [UInt64] = [0x11, 0x22, 0x33, 0x44, 0x55]
        let fixedNow = Date(timeIntervalSince1970: 10_000)
        var assertions = 0

        for seed in seeds {
            var random = SeededRandom(seed: seed)
            let store = makeStore(entries: initialEntries(), clock: { fixedNow })
            var working = false

            for step in 0..<500 {
                applyRandomOperation(to: store, random: &random, step: step, working: &working)
                let expected = groupTurns(entries: store.entries, working: working, now: fixedNow)
                XCTAssertEqual(store.turns, expected, "seed=\(seed) step=\(step)")
                assertions += 1
            }
        }

        print("INCREMENTAL_PROPERTY seeds=\(seeds.count) steps_per_seed=500 assertions=\(assertions)")
    }

    func testDuplicateIdentityInEarlierTurnMatchesFullRegroup() {
        let fixedNow = Date(timeIntervalSince1970: 10_000)
        let duplicateEntries: [TranscriptEntry] = [
            .prompt(PromptEntry(id: "prompt-0", ts: Date(timeIntervalSince1970: 0), text: "first")),
            .assistant(AssistantEntry(id: "duplicate", ts: Date(timeIntervalSince1970: 1), text: "old")),
            .turnEnd(TurnEndEntry(id: "end-0", ts: Date(timeIntervalSince1970: 2), durationMs: 2_000)),
            .prompt(PromptEntry(id: "prompt-1", ts: Date(timeIntervalSince1970: 3), text: "second")),
            .assistant(AssistantEntry(id: "assistant-1", ts: Date(timeIntervalSince1970: 4), text: "second reply")),
            .turnEnd(TurnEndEntry(id: "end-1", ts: Date(timeIntervalSince1970: 5), durationMs: 2_000)),
            .prompt(PromptEntry(id: "prompt-2", ts: Date(timeIntervalSince1970: 6), text: "third")),
            .assistant(AssistantEntry(id: "duplicate", ts: Date(timeIntervalSince1970: 7), text: "newest duplicate")),
        ]
        let store = makeStore(entries: duplicateEntries, clock: { fixedNow })
        _ = store.merge([.assistant(AssistantEntry(id: "duplicate", rev: 1, ts: Date(timeIntervalSince1970: 1), text: "updated earlier"))], replace: true)

        XCTAssertEqual(store.turns, groupTurns(entries: store.entries, working: false, now: fixedNow))
    }

    func testTwoThousandEntryGroupingBenchmark() {
        let fixedNow = Date(timeIntervalSince1970: 10_000)
        var entries: [TranscriptEntry] = []
        for turn in 0..<666 {
            let offset = turn * 3
            entries.append(.prompt(PromptEntry(id: "baseline-prompt-\(turn)", ts: Date(timeIntervalSince1970: Double(offset)), text: "prompt")))
            entries.append(.assistant(AssistantEntry(id: "baseline-assistant-\(turn)", ts: Date(timeIntervalSince1970: Double(offset + 1)), text: "reply")))
            entries.append(.turnEnd(TurnEndEntry(id: "baseline-end-\(turn)", ts: Date(timeIntervalSince1970: Double(offset + 2)), durationMs: 2_000)))
        }
        entries.append(.prompt(PromptEntry(id: "baseline-prompt-last", ts: Date(timeIntervalSince1970: 1_998), text: "prompt")))
        entries.append(.assistant(AssistantEntry(id: "baseline-assistant-last", ts: Date(timeIntervalSince1970: 1_999), text: "reply")))
        XCTAssertEqual(entries.count, 2_000)
        let repetitions = 7
        let fullEntries = entries + [.assistant(AssistantEntry(id: "full", ts: fixedNow, text: "reply"))]
        let fullMilliseconds = minimumMilliseconds(repetitions: repetitions) {
            _ = groupTurns(entries: fullEntries, working: false, now: fixedNow)
        }
        let grouped = groupTurnsWithStarts(entries: entries, working: false, now: fixedNow)
        let prefixCount = max(0, grouped.turns.count - 2)
        let startIndex = grouped.startIndices[prefixCount]
        let updatedEntries = entries + [.assistant(AssistantEntry(id: "incremental", ts: fixedNow, text: "reply"))]
        let incrementalMilliseconds = minimumMilliseconds(repetitions: repetitions) {
            let suffix = Array(updatedEntries[startIndex...])
            let tail = groupTurnsWithStarts(entries: suffix, working: false, now: fixedNow, turnIndexOffset: prefixCount)
            _ = Array(grouped.turns.prefix(prefixCount)) + tail.turns
        }

        XCTAssertGreaterThan(fullMilliseconds, 0)
        XCTAssertGreaterThan(incrementalMilliseconds, 0)
        print("TRANSCRIPT_GROUPING_BENCHMARK entries=2000 repetitions=\(repetitions) full_ms=\(String(format: "%.3f", fullMilliseconds)) incremental_ms=\(String(format: "%.3f", incrementalMilliseconds))")
    }

    private func makeStore(entries: [TranscriptEntry], clock: @escaping () -> Date) -> SessionStore {
        SessionStore(
            session: Session(id: "session-1", live: true, state: .idle),
            client: APIClient(baseURL: URL(string: "http://localhost:47832")!),
            entries: entries,
            clock: clock
        )
    }

    private func initialEntries() -> [TranscriptEntry] {
        [
            .prompt(PromptEntry(id: "prompt-0", ts: Date(timeIntervalSince1970: 0), text: "first")),
            .assistant(AssistantEntry(id: "assistant-0", ts: Date(timeIntervalSince1970: 1), text: "first reply")),
            .turnEnd(TurnEndEntry(id: "end-0", ts: Date(timeIntervalSince1970: 2), durationMs: 2_000)),
            .prompt(PromptEntry(id: "prompt-1", ts: Date(timeIntervalSince1970: 3), text: "second")),
            .assistant(AssistantEntry(id: "assistant-1", ts: Date(timeIntervalSince1970: 4), text: "second reply")),
        ]
    }

    private func applyRandomOperation(
        to store: SessionStore,
        random: inout SeededRandom,
        step: Int,
        working: inout Bool
    ) {
        let timestamp = Date(timeIntervalSince1970: Double(step + 10))
        switch random.nextInt(10) {
        case 0:
            _ = store.merge([.prompt(PromptEntry(id: "prompt-\(step)", ts: timestamp, text: "prompt \(step)"))])
        case 1:
            _ = store.merge([.assistant(AssistantEntry(id: "assistant-\(step)", ts: timestamp, text: "assistant \(step)"))])
        case 2:
            _ = store.merge([.tool(ToolEntry(id: "tool-\(step)", ts: timestamp, toolUseId: "tool-use-\(step)", tool: "Bash", state: .running))])
        case 3:
            if let tool = store.entries.compactMap(toolEntry).last {
                let revision = (tool.rev ?? 0) + 1
                _ = store.merge([.tool(ToolEntry(id: tool.id, rev: revision, ts: tool.ts, toolUseId: tool.toolUseId, tool: tool.tool, text: "result \(step)", result: "done", state: .done))], replace: true)
            } else {
                _ = store.merge([.tool(ToolEntry(id: "tool-\(step)", ts: timestamp, toolUseId: "tool-use-\(step)", tool: "Bash", state: .running))])
            }
        case 4:
            _ = store.merge([.subagent(SubagentEntry(id: "subagent-\(step)", ts: timestamp, toolUseId: "agent-use-\(step)", agentId: "agent-\(step)", agent: "worker", state: .running))])
        case 5:
            if let subagent = store.entries.compactMap(subagentEntry).last {
                _ = store.merge([.subagentResult(SubagentResultEntry(id: "subagent-result-\(step)", rev: 1, ts: timestamp, toolUseId: subagent.toolUseId, agentId: subagent.agentId, agent: subagent.agent, state: .done, result: "finished"))])
            } else {
                _ = store.merge([.subagent(SubagentEntry(id: "subagent-\(step)", ts: timestamp, toolUseId: "agent-use-\(step)", agentId: "agent-\(step)", agent: "worker", state: .running))])
            }
        case 6:
            _ = store.merge([.turnEnd(TurnEndEntry(id: "end-\(step)", ts: timestamp, durationMs: step * 10))])
        case 7:
            if let recent = store.entries.suffix(8).randomElement(using: &random) {
                _ = store.merge([updated(recent, step: step)], replace: true)
            }
        case 8:
            let earlier = Date(timeIntervalSince1970: -Double(step + 1))
            _ = store.merge([.prompt(PromptEntry(id: "earlier-\(step)", ts: earlier, text: "earlier \(step)"))])
        default:
            working.toggle()
            store.updateSession(Session(id: "session-1", live: true, state: working ? .working : .idle))
        }
    }

    private func updated(_ entry: TranscriptEntry, step: Int) -> TranscriptEntry {
        switch entry {
        case .prompt(var value):
            value.rev = (value.rev ?? 0) + 1
            value.text = "updated prompt \(step)"
            return .prompt(value)
        case .assistant(var value):
            value.rev = (value.rev ?? 0) + 1
            value.text = "updated assistant \(step)"
            return .assistant(value)
        case .tool(var value):
            value.rev = (value.rev ?? 0) + 1
            value.text = "updated tool \(step)"
            value.state = .done
            return .tool(value)
        case .subagent(var value):
            value.rev = (value.rev ?? 0) + 1
            value.text = "updated subagent \(step)"
            return .subagent(value)
        case .subagentResult(var value):
            value.rev = (value.rev ?? 0) + 1
            value.result = "updated result \(step)"
            return .subagentResult(value)
        case .compaction(var value):
            value.rev = (value.rev ?? 0) + 1
            value.text = "updated compaction \(step)"
            return .compaction(value)
        case .interrupt(var value):
            value.rev = (value.rev ?? 0) + 1
            return .interrupt(value)
        case .turnEnd(var value):
            value.rev = (value.rev ?? 0) + 1
            value.durationMs = step * 10
            return .turnEnd(value)
        case .decision(var value):
            value.rev = (value.rev ?? 0) + 1
            value.text = "updated decision \(step)"
            return .decision(value)
        case .file(var value):
            value.rev = (value.rev ?? 0) + 1
            value.name = "updated-\(step)"
            return .file(value)
        case .attention(var value):
            value.rev = (value.rev ?? 0) + 1
            value.text = "updated attention \(step)"
            return .attention(value)
        case .unknown(let kind, let raw):
            return .unknown(kind: kind, raw: raw)
        }
    }

    private func toolEntry(_ entry: TranscriptEntry) -> ToolEntry? {
        guard case .tool(let value) = entry else { return nil }
        return value
    }

    private func subagentEntry(_ entry: TranscriptEntry) -> SubagentEntry? {
        guard case .subagent(let value) = entry else { return nil }
        return value
    }

    private func minimumMilliseconds(repetitions: Int, operation: () -> Void) -> Double {
        var minimum = Double.infinity
        for _ in 0..<repetitions {
            let start = DispatchTime.now().uptimeNanoseconds
            operation()
            minimum = min(minimum, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return minimum
    }
}

private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}
