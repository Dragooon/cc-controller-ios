import Foundation
import XCTest
@testable import CCKit

final class TranscriptRowsTests: XCTestCase {
    func testRowsPreservePromptItemFooterOrderAndKinds() {
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

        let rows = transcriptRows(for: turn)
        XCTAssertEqual(rows.map(\.id), ["prompt-1", "assistant-1", "decision-1", "turn-1-worked"])
        guard case .prompt(let prompt) = rows[0].kind,
              case .item(.assistant(let assistant)) = rows[1].kind,
              case .item(.decision(let decision)) = rows[2].kind,
              case .workedFooter(let durationMs) = rows[3].kind else {
            return XCTFail("Rows were not emitted in prompt, item, footer order")
        }
        XCTAssertEqual(prompt.id, "prompt-1")
        XCTAssertEqual(assistant.id, "assistant-1")
        XCTAssertEqual(decision.id, "decision-1")
        XCTAssertEqual(durationMs, 1_234)
    }

    func testRowIDsRemainStableWhenEntriesAppend() {
        let initial = Turn(
            id: "turn-1",
            prompts: [PromptEntry(id: "prompt-1", text: "Prompt")],
            items: [.assistant(AssistantEntry(id: "assistant-1", text: "Reply"))],
            end: nil,
            durationMs: 0,
            hasBody: true,
            live: true,
            hasWorkedFooter: false
        )
        let appended = Turn(
            id: initial.id,
            prompts: initial.prompts,
            items: initial.items + [.assistant(AssistantEntry(id: "assistant-2", text: "More reply"))],
            end: nil,
            durationMs: 0,
            hasBody: true,
            live: true,
            hasWorkedFooter: false
        )

        let initialRows = transcriptRows(for: initial)
        let appendedRows = transcriptRows(for: appended)
        XCTAssertEqual(Array(appendedRows.prefix(initialRows.count)).map(\.id), initialRows.map(\.id))
        XCTAssertEqual(appendedRows.last?.id, "assistant-2")
    }

    func testRowsIncludeWorkedAndLiveActivityFooters() {
        let turn = Turn(
            id: "turn-2",
            prompts: [],
            items: [],
            end: nil,
            durationMs: 2_000,
            hasBody: false,
            live: true,
            hasWorkedFooter: true
        )
        let activity = TranscriptRow(
            id: "turn-2-activity",
            turnID: turn.id,
            kind: .liveActivityFooter(ActivityFooter(primary: "Working", detail: "Reading"))
        )

        let rows = transcriptRows(for: turn) + [activity]
        XCTAssertEqual(rows.map(\.id), ["turn-2-worked", "turn-2-activity"])
        guard case .workedFooter = rows[0].kind,
              case .liveActivityFooter(let footer) = rows[1].kind else {
            return XCTFail("Rows did not include both footer kinds")
        }
        XCTAssertEqual(footer.primary, "Working")
        XCTAssertEqual(footer.detail, "Reading")
    }
}
