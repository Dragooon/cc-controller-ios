import CCKit
import SwiftUI

#if DEBUG
enum BottomStackMocks {
    static var working: some View {
        WorkingSessionMock()
    }

    static var slash: some View {
        ComposerMock(configuration: MockBottomStackData.slashBottomStack)
    }

    static var attachments: some View {
        ComposerMock(configuration: MockBottomStackData.attachmentBottomStack)
    }

    static var keyboard: some View {
        ComposerMock(configuration: MockBottomStackData.keyboardBottomStack)
    }
}

private struct WorkingSessionMock: View {
    var body: some View {
        NavigationStack {
            SessionTranscriptView(
                turns: MockBottomStackData.workingTurns,
                showsWorkedFooter: false,
                bottomStackConfiguration: MockBottomStackData.workingBottomStack,
                activityFooter: MockBottomStackData.activityFooter,
                subagents: MockBottomStackData.workingSession.subagents ?? []
            )
            .navigationTitle(MockBottomStackData.workingSession.name ?? "Session")
            .navigationSubtitle(sessionDetailSubtitle(MockBottomStackData.workingSession, now: MockFixtures.now))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Session info")
                }
            }
        }
        .tint(.ccAccent)
        .background(.ccBackground)
    }
}

private struct ComposerMock: View {
    let configuration: BottomStackConfiguration

    var body: some View {
        NavigationStack {
            SessionTranscriptView(
                turns: MockSessionData.turns,
                showsWorkedFooter: true,
                bottomStackConfiguration: configuration
            )
            .navigationTitle("cc-controller native app")
            .navigationSubtitle(sessionDetailSubtitle(MockSessionData.session, now: MockFixtures.now))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Session info")
                }
            }
        }
        .tint(.ccAccent)
        .background(.ccBackground)
    }
}
#endif
