import CCKit
import SwiftUI

struct SubagentScreen: View {
    let sessionID: String
    let agentID: String
    let store: AppStore
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        screen()
        .task(id: "\(sessionID)|\(agentID)") {
            guard let store = store.openSubagent(sessionID: sessionID, agentID: agentID) else { return }
            do {
                try await store.loadInitial()
                while !Task.isCancelled, subagentIsRunning(in: store) {
                    try await Task.sleep(for: .seconds(2))
                    try await store.refetchTail()
                }
            } catch {
                guard !isTranscriptCancellation(error) else { return }
                model.actionError = self.store.actionError(for: error)
            }
        }
        .onDisappear {
            store.closeSubagent(sessionID: sessionID, agentID: agentID)
        }
    }

    @ViewBuilder
    private func screen() -> some View {
        if let store = store.openSubagent(sessionID: sessionID, agentID: agentID) {
            SessionTranscriptView(
                turns: store.turns,
                rows: store.rows,
                showsComposer: false,
                subagents: store.session.subagents ?? [],
                scrollAnchor: .top
            )
            .navigationTitle(subagent?.agent ?? agentID)
            .modifier(SubagentHeaderModifier(isRegular: horizontalSizeClass == .regular, dismiss: { dismiss() }) {
                VStack(alignment: horizontalSizeClass == .regular ? .leading : .center, spacing: 0) {
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
            })
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
        store.sessions[sessionID]?.subagents?.first { $0.agentId == agentID }
    }

    private func subagentIsRunning(in store: SessionStore) -> Bool {
        store.session.subagents?.first { $0.agentId == agentID }?.state == .running
    }

    private func isTranscriptCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        if let apiError = error as? APIError,
           case .transport(let urlError) = apiError {
            return urlError.code == .cancelled
        }
        return false
    }
}

/// The system bar on a phone; in large mode the same header as the session screen, with a back button.
private struct SubagentHeaderModifier<Title: View>: ViewModifier {
    let isRegular: Bool
    let dismiss: () -> Void
    @ViewBuilder let title: () -> Title

    func body(content: Content) -> some View {
        if isRegular {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    RegularDetailHeader {
                        HStack(spacing: RegularHeaderMetrics.controlSpacing) {
                            Button(action: dismiss) {
                                Image(systemName: "chevron.left")
                                    .frame(width: RegularHeaderMetrics.toggleSize, height: RegularHeaderMetrics.toggleSize)
                            }
                            .glassEffect(.regular.interactive(), in: .circle)
                            .accessibilityLabel("Back")
                            .accessibilityIdentifier("subagent-back")
                            title()
                        }
                    } trailing: {
                        EmptyView()
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
        } else {
            content
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        title()
                    }
                }
        }
    }
}
