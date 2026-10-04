import XCTest
@testable import CCKit

final class LiveEventCoalescerTests: XCTestCase {
    func testLatestEventOfEachTypeWinsWhileRetainingEventOrder() {
        let coalescer = LiveEventCoalescer()
        coalescer.enqueue(.stateDelta(StateDelta(sessionId: "session-1", state: .working)))
        coalescer.enqueue(.usage(UsageEvent(sessionId: "session-1", usage: Usage(model: "old"))))
        coalescer.enqueue(.stateDelta(StateDelta(sessionId: "session-1", state: .needsYou)))
        coalescer.enqueue(.subagents(SubagentsEvent(sessionId: "session-1", subagents: [Subagent(agentId: "agent-1")])))

        XCTAssertEqual(coalescer.drain(sessionID: "session-1"), [
            .usage(UsageEvent(sessionId: "session-1", usage: Usage(model: "old"))),
            .stateDelta(StateDelta(sessionId: "session-1", state: .needsYou)),
            .subagents(SubagentsEvent(sessionId: "session-1", subagents: [Subagent(agentId: "agent-1")])),
        ])
        XCTAssertTrue(coalescer.isEmpty)
    }

    func testDrainKeepsOrderingAcrossSessions() {
        let coalescer = LiveEventCoalescer()
        let first = StateDelta(sessionId: "session-1", state: .working)
        let second = UsageEvent(sessionId: "session-2", usage: Usage(model: "next"))
        coalescer.enqueue(.stateDelta(first))
        coalescer.enqueue(.usage(second))

        XCTAssertEqual(coalescer.drainAll(), [.stateDelta(first), .usage(second)])
    }

    func testSubagentUpsertsCoalesceDistinctIdentities() throws {
        let coalescer = LiveEventCoalescer()
        coalescer.enqueue(.subagent(SubagentEvent(sessionId: "session-1", subagents: [Subagent(state: .running, toolUseId: "task-1")])))
        coalescer.enqueue(.subagent(SubagentEvent(sessionId: "session-1", subagents: [Subagent(state: .done, toolUseId: "task-2")])))
        guard case .subagent(let event) = try XCTUnwrap(coalescer.drain(sessionID: "session-1").first) else {
            return XCTFail("Expected a coalesced subagent event")
        }
        XCTAssertEqual(event.subagents?.map(\.toolUseId), ["task-1", "task-2"])
    }

    func testSuccessiveStateDeltasMergeKeysAndRetainExplicitNulls() throws {
        let coalescer = LiveEventCoalescer()
        let first = StateDelta(sessionId: "session-1", state: .working, lastTool: "Bash", toolRunning: true)
        let rawSecond = try XCTUnwrap(LiveEvent.decode(name: "state", data: "{\"sessionId\":\"session-1\",\"action\":\"still working\",\"lastTool\":null}"))
        guard case .stateDelta(let second) = rawSecond else {
            XCTFail("Expected a state delta")
            return
        }
        coalescer.enqueue(.stateDelta(first))
        coalescer.enqueue(.stateDelta(second))

        guard case .stateDelta(let merged) = try XCTUnwrap(coalescer.drain(sessionID: "session-1").first) else {
            XCTFail("Expected a merged state delta")
            return
        }
        XCTAssertEqual(merged.state, .working)
        XCTAssertEqual(merged.action, "still working")
        XCTAssertNil(merged.lastTool)
        XCTAssertEqual(merged.toolRunning, true)
        XCTAssertNotNil(merged.rawObject["lastTool"])
    }
}
