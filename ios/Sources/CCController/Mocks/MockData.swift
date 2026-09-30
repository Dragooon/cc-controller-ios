import CCKit
import Foundation

enum MockFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_740_920)

    static var sessions: [Session] {
        load().sessions ?? []
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
