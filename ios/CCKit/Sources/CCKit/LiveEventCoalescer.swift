import Foundation

private func subagentIdentity(_ value: Subagent) -> String? {
    value.toolUseId ?? value.agentId
}

private func mergeSubagentEvents(_ older: SubagentEvent, _ newer: SubagentEvent) -> SubagentEvent {
    var merged = older.subagents ?? []
    for value in newer.subagents ?? [] {
        if let identity = subagentIdentity(value), let index = merged.firstIndex(where: { subagentIdentity($0) == identity }) {
            merged[index] = value
        } else {
            merged.append(value)
        }
    }
    return SubagentEvent(sessionId: newer.sessionId ?? older.sessionId, subagents: merged)
}

public enum CoalescedLiveEvent: Sendable, Equatable {
    case stateDelta(StateDelta)
    case usage(UsageEvent)
    case subagents(SubagentsEvent)
    case subagent(SubagentEvent)

    public var sessionID: String? {
        switch self {
        case .stateDelta(let event): event.sessionId
        case .usage(let event): event.sessionId
        case .subagents(let event): event.sessionId
        case .subagent(let event): event.sessionId
        }
    }
}

public final class LiveEventCoalescer {
    private struct Pending {
        var stateDelta: (sequence: Int, event: StateDelta)?
        var usage: (sequence: Int, event: UsageEvent)?
        var subagents: (sequence: Int, event: SubagentsEvent)?
        var subagent: (sequence: Int, event: SubagentEvent)?
    }

    private var nextSequence = 0
    private var pending: [String: Pending] = [:]

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    public func enqueue(_ event: CoalescedLiveEvent) {
        guard let sessionID = event.sessionID else { return }
        nextSequence += 1
        var session = pending[sessionID] ?? Pending()
        switch event {
        case .stateDelta(let value):
            let merged = session.stateDelta?.event.merged(with: value) ?? value
            session.stateDelta = (nextSequence, merged)
        case .usage(let value): session.usage = (nextSequence, value)
        case .subagents(let value):
            session.subagents = (nextSequence, value)
            session.subagent = nil
        case .subagent(let value):
            let merged = session.subagent.map { mergeSubagentEvents($0.event, value) } ?? value
            session.subagent = (nextSequence, merged)
        }
        pending[sessionID] = session
    }

    public func drain(sessionID: String) -> [CoalescedLiveEvent] {
        guard let session = pending.removeValue(forKey: sessionID) else { return [] }
        return queuedEvents(in: session).map(\.1)
    }

    public func drainAll() -> [CoalescedLiveEvent] {
        let sessions = pending.values.flatMap(queuedEvents(in:))
        pending.removeAll(keepingCapacity: true)
        return sessions.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func queuedEvents(in pending: Pending) -> [(Int, CoalescedLiveEvent)] {
        [
            pending.stateDelta.map { ($0.sequence, CoalescedLiveEvent.stateDelta($0.event)) },
            pending.usage.map { ($0.sequence, CoalescedLiveEvent.usage($0.event)) },
            pending.subagents.map { ($0.sequence, CoalescedLiveEvent.subagents($0.event)) },
            pending.subagent.map { ($0.sequence, CoalescedLiveEvent.subagent($0.event)) },
        ]
        .compactMap { $0 }
        .sorted { $0.0 < $1.0 }
    }
}
