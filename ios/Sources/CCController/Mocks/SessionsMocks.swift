import SwiftUI

extension SessionsMocks {
    static var sessions: some View {
        SessionsListView(
            sessions: MockFixtures.sessions,
            approvals: MockFixtures.approvals
        )
    }

    static var empty: some View {
        SessionsListView(
            sessions: []
        )
    }

    static var offline: some View {
        SessionsListView(
            sessions: MockFixtures.sessions,
            approvals: MockFixtures.approvals,
            connection: .offline(updatedAt: MockFixtures.now),
            subtitleOverride: "Offline"
        )
    }

    static var reconnecting: some View {
        SessionsListView(
            sessions: MockFixtures.sessions,
            approvals: MockFixtures.approvals,
            connection: .reconnecting,
            subtitleOverride: "Offline"
        )
    }
}

enum SessionsMocks {}
