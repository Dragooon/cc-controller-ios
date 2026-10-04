import CCKit
import Foundation

enum MockFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_740_920)

    static var sessions: [Session] {
        load().sessions?.map { session in
            var session = session
            session.pending = session.pending?.map { approval in
                var approval = approval
                if approval.status == .remote {
                    approval.receivedAt = Date.now.addingTimeInterval(-120)
                }
                return approval
            }
            if session.id == "session-staff-exclusions" {
                let now = Date.now
                session.startedAt = now.addingTimeInterval(-12 * 60)
                session.subagents = session.subagents?.enumerated().map { index, agent in
                    var agent = agent
                    agent.startedAt = now.addingTimeInterval(Double(-(9 + index * 2) * 60))
                    return agent
                }
                session.shells = session.shells?.map { shell in
                    var shell = shell
                    shell.startedAt = now.addingTimeInterval(-4 * 60)
                    return shell
                }
            }
            return session
        } ?? []
    }

    static var approvals: [Approval] {
        sessions.flatMap { $0.pending ?? [] }
    }

    private static func load() -> StateSnapshot {
        guard let url = Bundle.main.url(forResource: "sessions", withExtension: "json") else {
            fatalError("Mock data resource sessions.json is missing")
        }
        do {
            return try JSONDecoder.ccKit().decode(StateSnapshot.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Mock data failed to decode: \(error)")
        }
    }
}
