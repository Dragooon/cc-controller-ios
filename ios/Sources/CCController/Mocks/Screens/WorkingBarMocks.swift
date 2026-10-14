import CCKit
import Foundation
import SwiftUI

#if DEBUG
enum WorkingBarMocks {
    static var thinking: some View {
        WorkingBarMockScreen(configuration: MockWorkingBarData.thinking)
    }

    static var toolAgents: some View {
        WorkingBarMockScreen(configuration: MockWorkingBarData.toolAgents)
    }

    static var typing: some View {
        WorkingBarMockScreen(configuration: MockWorkingBarData.typing)
    }

    static var idle: some View {
        WorkingBarMockScreen(configuration: MockWorkingBarData.idle)
    }

    static var current: some View {
        WorkingBarMockScreen(configuration: MockWorkingBarData.current)
    }
}

private struct WorkingBarMockConfiguration {
    let session: Session
    let turns: [Turn]
    let verb: String
    let showsWorkingBar: Bool
    let composerText: String
    let focusesComposer: Bool
    let statusSegments: [String]
    let activityFooter: CCKit.ActivityFooter?

    var composer: ComposerConfiguration {
        ComposerConfiguration(
            initialText: composerText,
            placeholder: "Message",
            isWorking: session.state == .working,
            canInterrupt: true
        )
    }
}

private enum MockWorkingBarData {
    static let now = Date.now

    static let thinkingSession = Session(
        id: "working-bar-thinking",
        name: "Release notes review",
        project: "cc-controller",
        state: .working,
        usage: Usage(
            model: "claude-fable-5-1",
            contextPercent: 41,
            totalInputTokens: 38_400,
            outputTokens: 6_500,
            cacheHitRate: 0.92
        ),
        startedAt: now.addingTimeInterval(-102)
    )

    static let toolAgentsSession = Session(
        id: "working-bar-tool-agents",
        name: "Release notes review",
        project: "cc-controller",
        state: .working,
        lastTool: "Bash",
        lastToolInput: .object(["command": .string("npm test")]),
        toolRunning: true,
        usage: Usage(
            model: "claude-fable-5-1",
            contextPercent: 46,
            totalInputTokens: 41_200,
            outputTokens: 6_500,
            cacheHitRate: 0.89
        ),
        subagents: [
            Subagent(agentId: "agent-one", agent: "engineer", state: .running, background: true),
            Subagent(agentId: "agent-two", agent: "researcher", state: .running, background: true),
            Subagent(agentId: "agent-three", agent: "reviewer", state: .running, background: true)
        ],
        shells: [
            Shell(
                toolUseId: "shell-one",
                description: "Run the integration tests",
                command: "npm test",
                state: .running,
                startedAt: now.addingTimeInterval(-46)
            )
        ],
        startedAt: now.addingTimeInterval(-102)
    )

    static let idleSession = Session(
        id: "working-bar-idle",
        name: "Release notes review",
        project: "cc-controller",
        state: .idle,
        usage: Usage(
            model: "claude-fable-5-1",
            contextPercent: 41,
            totalInputTokens: 38_400,
            outputTokens: 6_500,
            cacheHitRate: 0.92
        ),
        idleSince: now.addingTimeInterval(-38 * 60)
    )

    static let thinking: WorkingBarMockConfiguration = .init(
        session: thinkingSession,
        turns: thinkingTurns,
        verb: "Hashing",
        showsWorkingBar: true,
        composerText: "",
        focusesComposer: false,
        statusSegments: ["38.4k in", "6.5k out", "cache 92%"],
        activityFooter: nil
    )

    static let toolAgents: WorkingBarMockConfiguration = .init(
        session: toolAgentsSession,
        turns: toolTurns,
        verb: "Hashing",
        showsWorkingBar: true,
        composerText: "",
        focusesComposer: false,
        statusSegments: ["41.2k in", "6.5k out", "cache 89%"],
        activityFooter: nil
    )

    static let typing: WorkingBarMockConfiguration = .init(
        session: thinkingSession,
        turns: thinkingTurns,
        verb: "Hashing",
        showsWorkingBar: true,
        composerText: "While that runs, check the release checklist too",
        focusesComposer: true,
        statusSegments: ["38.4k in", "6.5k out", "cache 92%"],
        activityFooter: nil
    )

    static let idle: WorkingBarMockConfiguration = .init(
        session: idleSession,
        turns: finishedTurns,
        verb: "Hashing",
        showsWorkingBar: false,
        composerText: "",
        focusesComposer: false,
        statusSegments: ["38.4k in", "6.5k out", "cache 92%"],
        activityFooter: nil
    )

    static let current: WorkingBarMockConfiguration = .init(
        session: toolAgentsSession,
        turns: toolTurns,
        verb: "Hashing",
        showsWorkingBar: false,
        composerText: "",
        focusesComposer: false,
        statusSegments: ["41.2k in", "6.5k out", "cache 89%"],
        activityFooter: activityFooterText(toolAgentsSession, now: now, verb: "Hashing")
    )

    static let thinkingTurns = decode(#"""
    [
      {"kind":"prompt","id":"working-bar-thinking-prompt","ts":"2026-10-04T03:58:00Z","text":"Review the release checklist and explain the remaining gaps."},
      {"kind":"assistant","id":"working-bar-thinking-answer","ts":"2026-10-04T03:59:00Z","text":"The checklist is nearly ready. I am comparing the release gates now, then I will call out any missing validation before the final handoff."}
    ]
    """#)

    static let toolTurns = decode(#"""
    [
      {"kind":"prompt","id":"working-bar-tool-prompt","ts":"2026-10-04T03:58:00Z","text":"Run the release checks and summarize the result."},
      {"kind":"assistant","id":"working-bar-tool-answer","ts":"2026-10-04T03:59:00Z","text":"I am running the checks and comparing the output with the release checklist."},
      {"kind":"tool","id":"working-bar-tool-bash","ts":"2026-10-04T03:59:20Z","toolUseId":"working-bar-tool-bash","tool":"Bash","args":{"command":"npm test"},"result":"Test suite is running…","state":"running"}
    ]
    """#)

    static let finishedTurns = decode(#"""
    [
      {"kind":"prompt","id":"working-bar-idle-prompt","ts":"2026-10-04T03:48:00Z","text":"Review the release checklist and explain the remaining gaps."},
      {"kind":"assistant","id":"working-bar-idle-answer","ts":"2026-10-04T03:51:00Z","text":"The checklist is complete. The release notes include the test result, the rollout summary, and the final owner handoff."},
      {"kind":"turn_end","id":"working-bar-idle-end","ts":"2026-10-04T03:51:01Z","durationMs":181000}
    ]
    """#)

    private static func decode(_ json: String) -> [Turn] {
        do {
            let entries = try JSONDecoder.ccKit().decode([TranscriptEntry].self, from: Data(json.utf8))
            return groupTranscript(entries: entries, working: true, now: now)
        } catch {
            fatalError("Working bar mock transcript failed to decode: \(error)")
        }
    }
}

private struct WorkingBarMockScreen: View {
    let configuration: WorkingBarMockConfiguration

    var body: some View {
        NavigationStack {
            SessionTranscriptView(
                sessionID: configuration.session.id ?? "working-bar",
                turns: configuration.turns,
                showsComposer: false,
                showsWorkedFooter: false,
                activityFooter: configuration.activityFooter,
                liveSession: configuration.activityFooter == nil ? nil : configuration.session,
                subagents: configuration.session.subagents ?? []
            )
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if configuration.showsWorkingBar {
                    WorkingBarMockBottomStack(configuration: configuration)
                } else {
                    BottomStackView(
                        configuration: BottomStackConfiguration(
                            composer: configuration.composer,
                            statusSegments: configuration.statusSegments
                        )
                    )
                }
            }
            .navigationTitle(configuration.session.name ?? "Session")
            .navigationSubtitle(sessionDetailSubtitle(configuration.session, now: MockWorkingBarData.now))
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

private struct WorkingBarMockBottomStack: View {
    let configuration: WorkingBarMockConfiguration
    @State private var text: String
    @FocusState private var composerFocused: Bool
    @Namespace private var glassNamespace

    init(configuration: WorkingBarMockConfiguration) {
        self.configuration = configuration
        _text = State(initialValue: configuration.composerText)
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                StatusLineView(segments: configuration.statusSegments)
                WorkingBarView(
                    session: configuration.session,
                    verb: configuration.verb,
                    frozenNow: MockWorkingBarData.now
                )
                ComposerView(
                    text: $text,
                    isFocused: $composerFocused,
                    configuration: configuration.composer,
                    glassNamespace: glassNamespace
                )
                .equatable()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .background(.ccBackground.opacity(0.88))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("working-bar-bottom-stack")
        .onAppear {
            guard configuration.focusesComposer else { return }
            DispatchQueue.main.async {
                composerFocused = true
            }
        }
    }
}
#endif
