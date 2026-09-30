import CCKit
import SwiftUI

#if DEBUG
enum BottomStackMocks {
    static var working: some View {
        WorkingSessionMock()
    }

    static var slash: some View {
        ComposerMock(title: "Slash commands", configuration: MockBottomStackData.slashBottomStack)
    }

    static var attachments: some View {
        ComposerMock(title: "Attachments", configuration: MockBottomStackData.attachmentBottomStack)
    }

    static var keyboard: some View {
        ComposerMock(title: "Keyboard", configuration: MockBottomStackData.keyboardBottomStack)
    }
}

private struct WorkingSessionMock: View {
    var body: some View {
        NavigationStack {
            SessionTranscriptView(
                turns: MockBottomStackData.workingTurns,
                now: MockFixtures.now,
                showsWorkedFooter: false,
                bottomStackConfiguration: MockBottomStackData.workingBottomStack,
                activityFooter: MockBottomStackData.activityFooter
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
    let title: String
    let configuration: BottomStackConfiguration

    var body: some View {
        NavigationStack {
            SessionTranscriptView(
                turns: [],
                now: MockFixtures.now,
                showsWorkedFooter: false,
                bottomStackConfiguration: configuration
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(.ccAccent)
        .background(.ccBackground)
    }
}
#endif
