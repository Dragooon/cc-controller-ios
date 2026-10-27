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

    static var question: some View {
        ApprovalSessionMock(approvals: [MockApprovalData.questionApproval])
    }

    static var peerConversation: some View {
        ApprovalSessionMock(approvals: [MockApprovalData.peerConversationApproval])
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
                    showsComposer: false,
                    scrollAnchor: .bottom
                )
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    ApprovalBottomStackView(
                        approvals: approvals,
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
        receivedAt: Date.now.addingTimeInterval(-338),
        holdLimitMs: 590_000,
        mode: .remote,
        status: .remote
    )

    static let readApproval = Approval(
        requestId: "mock-read-approval",
        sessionId: "mock-approval-session",
        toolName: "Read",
        toolInput: .object(["file_path": .string("tasks/native-app.md")]),
        receivedAt: Date.now.addingTimeInterval(-120),
        holdLimitMs: 590_000,
        mode: .remote,
        status: .remote
    )

    static let questionApproval = Approval(
        requestId: "mock-question-approval",
        sessionId: "mock-approval-session",
        kind: .question,
        toolName: "AskUserQuestion",
        toolInput: .object([
            "questions": .array([
                .object([
                    "question": .string("Which environment should receive the deploy?"),
                    "header": .string("Environment"),
                    "options": .array([
                        .object(["label": .string("Sandbox"), "description": .string("Deploy to the shared sandbox.")]),
                        .object(["label": .string("Production"), "description": .string("Deploy to production after validation.")]),
                    ]),
                    "multiSelect": .bool(false),
                ]),
                .object([
                    "question": .string("Which checks should run first?"),
                    "header": .string("Checks"),
                    "options": .array([
                        .object(["label": .string("Unit tests"), "description": .string("Run the fast unit suite.")]),
                        .object(["label": .string("UI flows"), "description": .string("Run the focused iOS flows.")]),
                        .object(["label": .string("Smoke"), "description": .string("Run the live smoke path.")]),
                    ]),
                    "multiSelect": .bool(true),
                ]),
            ]),
        ]),
        receivedAt: Date.now.addingTimeInterval(-120),
        holdLimitMs: 590_000,
        mode: .remote,
        status: .remote
    )

    static let peerConversationApproval = Approval(
        requestId: "mock-peer-conversation-approval",
        sessionId: "mock-approval-session",
        kind: .peerConversation,
        toolName: "peer_conversation",
        toolInput: .object([
            "request": .string("Stockade session ‘thread \\\"X\\\" in #general’ wants to message ‘App Debugging’. Allow?"),
            "from": .string("thread \\\"X\\\" in #general"),
            "host": .string("Stockade"),
            "to": .string("App Debugging"),
            "message": .string("Please check the cross-controller build status."),
        ]),
        receivedAt: Date.now.addingTimeInterval(-120),
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
