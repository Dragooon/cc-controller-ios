import CCKit
import SwiftUI

struct SubagentScreen: View {
    let sessionID: String
    let agentID: String
    @Bindable var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            screen(now: context.date)
        }
        .task(id: "\(sessionID)|\(agentID)") {
            guard let store = model.store.openSubagent(sessionID: sessionID, agentID: agentID) else { return }
            do {
                try await store.loadInitial()
                while !Task.isCancelled, subagentIsRunning(in: store) {
                    try await Task.sleep(for: .seconds(2))
                    try await store.refetchTail()
                }
            } catch is CancellationError {
                return
            } catch {
                model.actionError = .network(error.localizedDescription)
            }
        }
        .onDisappear {
            model.store.closeSubagent(sessionID: sessionID, agentID: agentID)
        }
    }

    @ViewBuilder
    private func screen(now: Date) -> some View {
        if let store = model.store.openSubagent(sessionID: sessionID, agentID: agentID) {
            SessionTranscriptView(
                turns: store.turns,
                now: now,
                showsComposer: false,
                subagents: store.session.subagents ?? [],
                scrollAnchor: .top
            )
            .navigationTitle(subagent?.agent ?? agentID)
            .navigationSubtitle(subagent.map { subagentSubtitle($0, now: now) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.ccAccent)
            .background(.ccBackground)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ccBackground)
                .navigationTitle(agentID)
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var subagent: Subagent? {
        model.store.sessions[sessionID]?.subagents?.first { $0.agentId == agentID }
    }

    private func subagentIsRunning(in store: SessionStore) -> Bool {
        store.session.subagents?.first { $0.agentId == agentID }?.state == .running
    }
}
