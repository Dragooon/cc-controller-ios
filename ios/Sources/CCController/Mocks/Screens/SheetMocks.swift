import CCKit
import Foundation
import SwiftUI

enum SheetMocks {
    static var inspector: some View {
        InspectorBackdrop()
            .sheet(isPresented: .constant(true)) {
                InspectorView(
                    session: inspectorSession,
                    elapsed: "31m",
                    branch: "work/2026-09-30",
                    onInterrupt: {},
                    onCopySessionID: {},
                    onApprovalMode: { _ in }
                )
            }
    }

    static var settings: some View {
        Color.ccBackground
            .sheet(isPresented: .constant(true)) {
                SettingsView(
                    pairedDevices: [
                        SettingsPairedDevice(id: "macbook", name: "Sam's MacBook Pro", lastSeen: "just now"),
                        SettingsPairedDevice(id: "ipad", name: "Sam's iPad", lastSeen: "2 days ago"),
                    ]
                )
            }
    }

    static var onboardingWelcome: some View { OnboardingWelcomeView() }
    static var onboardingConnect: some View { OnboardingConnectView() }
    static var onboardingPair: some View { OnboardingPairView() }
    static var onboardingFaceID: some View { OnboardingFaceIDView() }
    static var lock: some View { LockView() }
    static var privacyCover: some View { PrivacyCoverView() }

    private static let inspectorSession = Session(
        id: "session-eval-dataset",
        name: "Eval dataset versioning",
        project: "atlas",
        tmuxPane: "control:2.1",
        tmux: true,
        state: .working,
        usage: Usage(
            model: "claude-fable-5-1",
            contextTokens: 412_000,
            contextWindow: 1_000_000,
            contextPercent: 41,
            totalInputTokens: 3_100_000,
            outputTokens: 84_000,
            cacheHitRate: 0.92,
            messages: 214
        ),
        subagents: [
            Subagent(agentId: "engineer", agent: "engineer", text: "Implement the migration", state: .running),
            Subagent(agentId: "researcher", agent: "researcher", text: "Check dataset semantics", state: .running),
            Subagent(agentId: "reviewer", agent: "reviewer", text: "Review the release notes", state: .done),
        ],
        mode: .remote
    )
}

private struct InspectorBackdrop: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Version the evaluation dataset without changing the live pointer.")
                Text("Draft a manifest, compare the item set, then release it when the judge is ready.")
                Text("The current run remains pinned to its original version.")
            }
            .font(.body)
            .foregroundStyle(.ccSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .background(.ccBackground)
            .navigationTitle("Eval dataset versioning")
        }
        .tint(.ccAccent)
    }
}
