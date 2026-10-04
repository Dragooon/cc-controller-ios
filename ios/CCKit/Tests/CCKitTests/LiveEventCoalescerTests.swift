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
}
