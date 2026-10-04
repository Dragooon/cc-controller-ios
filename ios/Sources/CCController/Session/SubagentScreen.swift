import CCKit
import SwiftUI

struct SubagentScreen: View {
    let sessionID: String
    let agentID: String
    @Bindable var model: AppModel

    var body: some View {
        screen()
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
    private func screen() -> some View {
        if let store = model.store.openSubagent(sessionID: sessionID, agentID: agentID) {
            SessionTranscriptView(
                turns: store.turns,
                rows: store.rows,
                showsComposer: false,
                subagents: store.session.subagents ?? [],
                scrollAnchor: .top
            )
            .navigationTitle(subagent?.agent ?? agentID)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(subagent?.agent ?? agentID)
                            .font(.headline)
                            .lineLimit(1)
                        if let subagent {
                            SubagentSubtitleView(subagent: subagent)
                                .font(.caption)
                                .foregroundStyle(.ccSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
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
