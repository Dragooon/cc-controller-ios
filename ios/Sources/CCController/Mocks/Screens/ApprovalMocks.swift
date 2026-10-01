import CCKit
import Foundation
import SwiftUI

#if DEBUG
enum ApprovalMocks {
    static var stacked: some View {
        ApprovalSessionMock(approvals: MockApprovalData.remoteApprovals)
    }

    static var terminal: some View {
        ApprovalSessionMock(approvals: [MockApprovalData.terminalApproval])
    }
}

private struct ApprovalSessionMock: View {
    let approvals: [Approval]

    private var session: Session {
        Session(
            id: "mock-approval-session",
            name: "cc-controller native app",
            project: "cc-controller",
            state: .needsYou,
            usage: Usage(contextPercent: 32)
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                SessionTranscriptView(
                    turns: MockSessionData.turns,
                    now: MockFixtures.now,
                    showsComposer: false,
                    scrollAnchor: .bottom
                )
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    ApprovalBottomStackView(
                        approvals: approvals,
                        now: MockFixtures.now,
                        maxHeight: max(0, proxy.size.height - 24)
                    )
                }
            }
            .navigationTitle(session.name ?? "Session")
            .navigationSubtitle(sessionDetailSubtitle(session, now: MockFixtures.now))
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


private enum MockApprovalData {
    static let remoteApprovals = [primaryApproval, readApproval]

    static let primaryApproval = Approval(
        requestId: "mock-bash-approval",
        sessionId: "mock-approval-session",
        toolName: "Bash",
        toolInput: .object([
            "command": .string("""
xcodebuild test \\
  -scheme CCController \\
  -destination 'platform=iOS Simulator,name=iPhone 16 Plus' \\
  -resultBundlePath build/mocks.xcresult \\
  -only-testing:CCControllerUITests/MockScreenshotTests \\
  CODE_SIGNING_ALLOWED=NO \\
  | tee /tmp/cc-build.log
"""),
            "description": .string("Render the design mocks on the lane simulators.")
        ]),
        permissionMode: "acceptEdits",
        agentType: "engineer",
        receivedAt: MockFixtures.now.addingTimeInterval(-338),
        holdLimitMs: 590_000,
        mode: .remote,
        status: .remote
    )

    static let readApproval = Approval(
        requestId: "mock-read-approval",
        sessionId: "mock-approval-session",
        toolName: "Read",
        toolInput: .object(["file_path": .string("tasks/native-app.md")]),
        receivedAt: MockFixtures.now.addingTimeInterval(-120),
        holdLimitMs: 590_000,
        mode: .remote,
        status: .remote
    )

    static let terminalApproval = Approval(
        requestId: "mock-terminal-approval",
        sessionId: "mock-approval-session",
        toolName: "Bash",
        toolInput: primaryApproval.toolInput,
        permissionMode: "acceptEdits",
        agentType: "engineer",
        receivedAt: terminalSince.addingTimeInterval(-590),
        holdLimitMs: 590_000,
        mode: .terminal,
        status: .terminal,
        timedOutAt: terminalSince
    )

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return calendar
    }()

    private static let terminalSince = calendar.date(
        from: DateComponents(year: 2026, month: 9, day: 30, hour: 9, minute: 33)
    )!
}
#endif
