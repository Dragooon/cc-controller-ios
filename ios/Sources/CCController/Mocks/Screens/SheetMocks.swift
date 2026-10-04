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

    static var activity: some View {
        ActivityBackdrop()
            .sheet(isPresented: .constant(true)) {
                ActivitySheet(session: activitySession, initialDetent: .large)
            }
    }

    static var settings: some View {
        Color.ccBackground
            .sheet(isPresented: .constant(true)) {
                SettingsView(
                    latency: .reachable(.milliseconds(18)),
                    thisDevice: .loaded(
                        SettingsThisDevice(
                            name: "Sam's iPhone",
                            pairedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30)),
                            sessionExpiresAt: Date.now.addingTimeInterval(11 * 60 * 60 + 30 * 60)
                        )
                    ),
                    pairedDevices: .loaded([
                        SettingsPairedDeviceRow(id: "iphone", name: "Sam's iPhone", lastSeenAt: .now, isThisDevice: true),
                        SettingsPairedDeviceRow(id: "ipad", name: "Sam's iPad", lastSeenAt: Date.now.addingTimeInterval(-2 * 24 * 60 * 60), isThisDevice: false),
                    ]),
                    appVersion: "1.0 (1)",
                    daemon: DaemonInfo(version: "0.1.0", commit: "b961f05"),
                    apiVersion: 2
                )
            }
    }

    static var onboardingWelcome: some View { OnboardingWelcomeView() }
    static var onboardingConnect: some View { OnboardingConnectView() }
    static var onboardingPair: some View { OnboardingPairView(code: "482913", expiresAt: .now.addingTimeInterval(4 * 60 + 32)) }
    static var onboardingFaceID: some View { OnboardingFaceIDView() }
    static var lock: some View { LockView() }
    static var privacyCover: some View { PrivacyCoverView() }

    private static let activitySession: Session = {
        let now = Date.now
        return Session(
            id: "session-activity",
            name: "cc-controller native app",
            project: "cc-controller",
            state: .working,
            subagents: [
                Subagent(agentId: "activity-engineer", agent: "engineer", text: "Implement the activity presentation", state: .running, startedAt: now.addingTimeInterval(-8 * 60), background: true),
                Subagent(agentId: "activity-researcher", agent: "researcher", text: "Compare daemon activity payloads", state: .running, startedAt: now.addingTimeInterval(-5 * 60), background: true),
                Subagent(agentId: "activity-finished", agent: "reviewer", state: .done, startedAt: now.addingTimeInterval(-9 * 60), finishedAt: now.addingTimeInterval(-4 * 60), result: "Confirmed the activity rows match the live payload.", background: true)
            ],
            shells: [
                Shell(toolUseId: "activity-running-shell", description: "Run the sharded flow suite", command: "scripts/ios.sh flows --shards 3 --test TranscriptFlowTests --device 'iPhone 18 Pro'", state: .running, startedAt: now.addingTimeInterval(-3 * 60)),
                Shell(toolUseId: "activity-failed-shell", description: "Build the release archive", command: "scripts/ios.sh release-check --configuration Release", state: .failed, startedAt: now.addingTimeInterval(-7 * 60), finishedAt: now.addingTimeInterval(-2 * 60))
            ]
        )
    }()

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

private struct ActivityBackdrop: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("The sharded flow suite is still running in the background.")
                Text("The main turn can continue while the activity stays visible here.")
            }
            .font(.body)
            .foregroundStyle(.ccSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .background(.ccBackground)
            .navigationTitle("cc-controller native app")
        }
        .tint(.ccAccent)
    }
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
