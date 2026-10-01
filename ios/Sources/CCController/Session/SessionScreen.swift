import CCKit
import SwiftUI

struct SessionScreen: View {
    let sessionID: String
    @Bindable var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            screen(now: context.date)
        }
        .task(id: sessionID) {
            guard let sessionStore = model.store.openSession(sessionID) else { return }
            do {
                try await sessionStore.loadInitial()
            } catch {
                model.actionError = .network(error.localizedDescription)
            }
        }
        .onDisappear {
            model.store.closeSession(sessionID)
        }
    }

    @ViewBuilder
    private func screen(now: Date) -> some View {
        if let sessionStore = model.store.openSession(sessionID) {
            contentNavigation(
                name: sessionStore.session.name ?? "Session",
                subtitle: sessionDetailSubtitle(sessionStore.session, now: now)
            ) {
                if sessionStore.isLoaded {
                    SessionTranscriptView(turns: sessionStore.turns, now: now)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ccBackground)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ccBackground)
                .navigationTitle("Session")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func contentNavigation<Content: View>(
        name: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(name)
                            .font(.headline)
                            .lineLimit(1)
                            .accessibilityIdentifier("selected-session-name")
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .tint(.ccAccent)
            .background(.ccBackground)
    }
}
