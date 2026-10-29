import XCTest
@testable import CCKit

final class TranscriptRowsTests: XCTestCase {
    func testRowsPreservePromptAndItemOrderWithStatusLast() {
        let turn = Turn(
            id: "turn-1",
            prompts: [PromptEntry(id: "prompt-1", text: "Prompt")],
            items: [
                .assistant(AssistantEntry(id: "assistant-1", text: "Reply")),
                .decision(DecisionEntry(id: "decision-1", text: "Allowed")),
            ],
            end: nil,
            durationMs: 1_234,
            hasBody: true,
            live: false,
            hasWorkedFooter: true
        )

        let rows = transcriptRows(for: [turn])
        XCTAssertEqual(rows.map(\.id), ["prompt-1", "assistant-1", "decision-1", "status"])
        guard case .prompt(let prompt) = rows[0].kind,
              case .item(.assistant(let assistant)) = rows[1].kind,
              case .item(.decision(let decision)) = rows[2].kind,
              case .status(.worked(let durationMs)) = rows[3].kind else {
            return XCTFail("Rows were not emitted in prompt, item, status order")
        }
        XCTAssertEqual(prompt.id, "prompt-1")
        XCTAssertEqual(assistant.id, "assistant-1")
        XCTAssertEqual(decision.id, "decision-1")
        XCTAssertEqual(durationMs, 1_234)
    }

    func testStatusRowIDIsStableAcrossSendWorkingReplyAndDone() {
        let turn = Turn(
            id: "turn-1",
            prompts: [PromptEntry(id: "prompt-1", text: "Prompt")],
            items: [],
            end: nil,
            durationMs: 0,
            hasBody: false,
            live: true,
            hasWorkedFooter: false
        )
        let statuses: [TranscriptStatus] = [
            .none,
            .activity(ActivityFooter(primary: "Thinking…", detail: "1s")),
            .activity(ActivityFooter(primary: "Thinking…", detail: "2s")),
            .worked(durationMs: 2_000),
        ]

        let rows = statuses.map { status in
            var rows = transcriptRows(for: [turn])
            rows[rows.count - 1] = TranscriptRow(id: "status", turnID: turn.id, kind: .status(status))
            return rows
        }

        XCTAssertEqual(rows.map { $0.last?.id }, ["status", "status", "status", "status"])
        XCTAssertEqual(rows.map { $0.dropLast().map(\.id) }, Array(repeating: ["prompt-1"], count: statuses.count))
    }

    func testNewPromptLeavesPreviousTurnsRowsUntouched() {
        let first = Turn(
            id: "turn-1",
            prompts: [PromptEntry(id: "prompt-1", text: "First")],
            items: [.assistant(AssistantEntry(id: "assistant-1", text: "Reply"))],
            end: nil,
            durationMs: 1_000,
            hasBody: true,
            live: false,
            hasWorkedFooter: true
        )
        let second = Turn(
            id: "turn-2",
            prompts: [PromptEntry(id: "prompt-2", text: "Second")],
            items: [],
            end: nil,
            durationMs: 0,
            hasBody: false,
            live: true,
            hasWorkedFooter: false
        )

        let before = transcriptRows(for: [first])
        let after = transcriptRows(for: [first, second])

        XCTAssertEqual(
            Array(before.dropLast()).map(\.id),
            Array(after.dropLast().prefix(before.count - 1)).map(\.id)
        )
        XCTAssertEqual(after.last?.id, "status")
        XCTAssertEqual(after.dropLast().last?.id, "prompt-2")
    }

    func testWorkedStatusAppearsOnlyForCurrentCompletedAssistantTurn() {
        let first = Turn(
            id: "turn-1",
            prompts: [PromptEntry(id: "prompt-1", text: "First")],
            items: [.assistant(AssistantEntry(id: "assistant-1", text: "Reply"))],
            end: nil,
            durationMs: 1_000,
            hasBody: true,
            live: false,
            hasWorkedFooter: false
        )
        let completed = Turn(
            id: "turn-2",
            prompts: [PromptEntry(id: "prompt-2", text: "Second")],
            items: [.assistant(AssistantEntry(id: "assistant-2", text: "Reply"))],
            end: nil,
            durationMs: 2_000,
            hasBody: true,
            live: false,
            hasWorkedFooter: true
        )
        let working = Turn(
            id: "turn-3",
            prompts: [PromptEntry(id: "prompt-3", text: "Third")],
            items: [.assistant(AssistantEntry(id: "assistant-3", text: "Partial"))],
            end: nil,
            durationMs: 3_000,
            hasBody: true,
            live: true,
            hasWorkedFooter: false
        )

        let firstStatus = transcriptRows(for: [first, completed]).last
        let workingStatus = transcriptRows(for: [first, completed, working]).last
        let noAssistant = Turn(
            id: "turn-4",
            prompts: [PromptEntry(id: "prompt-4", text: "Fourth")],
            items: [.tools(ToolRun(entries: [ToolEntry(id: "tool-4", tool: "Read", state: .done)]))],
            end: nil,
            durationMs: 4_000,
            hasBody: true,
            live: false,
            hasWorkedFooter: false
        )
        let toolStatus = transcriptRows(for: [first, completed, noAssistant]).last

        guard case .status(.worked(let completedDuration)) = firstStatus?.kind else {
            return XCTFail("The current completed assistant turn did not show worked")
        }
        XCTAssertEqual(completedDuration, 2_000)
        guard case .status(.none) = workingStatus?.kind else {
            return XCTFail("Worked status remained while the current turn was working")
        }
        guard case .status(.none) = toolStatus?.kind else {
            return XCTFail("Worked status appeared when the current turn did not end in an assistant entry")
        }
    }

    func testGroupedToolRunIDComesFromItsFirstEntry() {
        let first = ToolEntry(id: "tool-1", toolUseId: "use-1", tool: "Read", state: .done)
        let second = ToolEntry(id: "tool-2", toolUseId: "use-2", tool: "Bash", state: .running)
        let run = ToolRun(entries: [first, second])

        XCTAssertEqual(TurnItem.tools(run).id, "tool-1")
        XCTAssertEqual(TurnItem.tools(ToolRun(entries: [first, second, ToolEntry(id: "tool-3", tool: "Edit", state: .done)])).id, "tool-1")
    }

    func testSubagentIndexToleratesDuplicateIdentities() {
        let first = Subagent(agentId: "agent-1", state: .running, toolUseId: "task-1")
        let second = Subagent(agentId: "agent-1", state: .done, toolUseId: "task-1")
        let index = SubagentIndex([first, second])
        let item = TurnItem.subagent(SubagentEntry(id: "subagent", toolUseId: "task-1", agentId: "agent-1"))
        XCTAssertEqual(index.matchingSubagents(for: item), [first])
    }
}
