import SwiftUI

extension SessionsMocks {
    static var sessions: some View {
        SessionsListView(
            sessions: MockFixtures.sessions,
            approvals: MockFixtures.approvals,
            now: MockFixtures.now,
            freezeWorkingGlyphs: true
        )
    }

    static var empty: some View {
        SessionsListView(
            sessions: [],
            now: MockFixtures.now
        )
    }

    static var offline: some View {
        SessionsListView(
            sessions: MockFixtures.sessions,
            approvals: MockFixtures.approvals,
            connection: .offline(updatedAt: MockFixtures.now),
            now: MockFixtures.now,
            subtitleOverride: "Offline"
        )
    }

    static var reconnecting: some View {
        SessionsListView(
            sessions: MockFixtures.sessions,
            approvals: MockFixtures.approvals,
            connection: .reconnecting,
            now: MockFixtures.now,
            subtitleOverride: "Offline"
        )
    }
}

enum SessionsMocks {}
