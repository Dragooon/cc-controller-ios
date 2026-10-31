import CCKit
import Foundation

#if DEBUG
enum MockBottomStackData {
    static let slashCommands = [
        SlashCommand(command: "/clear", description: "Clear session"),
        SlashCommand(command: "/compact", description: "Summarize context"),
        SlashCommand(command: "/model", description: "Choose model")
    ]

    static let workingSession = Session(
        id: "mock-working-session",
        name: "cc-controller native app",
        project: "cc-controller",
        tmuxPane: "%4",
        tmux: true,
        state: .working,
        lastTool: "Bash",
        lastToolInput: .object(["command": .string("npm test")]),
        toolRunning: true,
        usage: Usage(
            model: "claude-fable-5-1",
            contextPercent: 41,
            totalInputTokens: 3_100_000,
            outputTokens: 84_000,
            cacheHitRate: 0.92
        ),
        subagents: [
            Subagent(agentId: "engineer-1", agent: "engineer", state: .running),
            Subagent(agentId: "researcher-1", agent: "researcher", state: .running)
        ],
        shells: [
            Shell(toolUseId: "shell-working", description: "Run the sharded flow suite", command: "scripts/ios.sh flows --shards 3", state: .running, startedAt: MockFixtures.now.addingTimeInterval(-35))
        ],
        startedAt: MockFixtures.now.addingTimeInterval(-42)
    )

    static let activitySession: Session = {
        let now = Date.now
        return Session(
            id: "mock-activity-session",
            name: "cc-controller native app",
            project: "cc-controller",
            tmuxPane: "%4",
            tmux: true,
            state: .working,
            lastTool: "Bash",
            toolRunning: true,
            subagents: [
                Subagent(agentId: "activity-engineer", agent: "engineer", text: "Polish the activity sheet", state: .running, startedAt: now.addingTimeInterval(-7 * 60), background: true),
                Subagent(agentId: "activity-researcher", agent: "researcher", text: "Check the live shell lifecycle", state: .running, startedAt: now.addingTimeInterval(-3 * 60), background: true)
            ],
            shells: [
                Shell(toolUseId: "activity-shell", description: "Run the sharded flow suite", command: "scripts/ios.sh flows --shards 3 --test TranscriptFlowTests --device 'iPhone 18 Pro'", state: .running, startedAt: now.addingTimeInterval(-2 * 60))
            ],
            startedAt: now.addingTimeInterval(-11 * 60)
        )
    }()


    static let activityFooter: ActivityFooter = {
        let activitySession = Session(
            lastTool: "Bash",
            lastToolInput: .object(["command": .string("npm test")]),
            toolRunning: true,
            usage: Usage(outputTokens: 1_200),
            startedAt: MockFixtures.now.addingTimeInterval(-42)
        )
        return activityFooterText(activitySession, now: MockFixtures.now, verb: "Contemplating")
    }()

    static let workingTurns: [Turn] = decode(#"""
    [
      {"kind":"prompt","id":"working-prompt","ts":"2026-09-30T04:00:00Z","text":"Finish the native composer mocks and check every screenshot."},
      {"kind":"assistant","id":"working-assistant","ts":"2026-09-30T04:00:12Z","text":"I am checking the bottom stack at both phone sizes and will keep the composer above the keyboard."},
      {"kind":"tool","id":"working-read","ts":"2026-09-30T04:00:18Z","toolUseId":"working-read","tool":"Read","args":{"file_path":"tasks/native-app.md"},"result":"Read the Bottom stack and Keyboard decisions.","state":"done"},
      {"kind":"tool","id":"working-bash","ts":"2026-09-30T04:00:24Z","toolUseId":"working-bash","tool":"Bash","args":{"command":"npm test"},"result":"Running test suite…","state":"running"},
      {"kind":"subagent_result","id":"working-agent-result","ts":"2026-09-30T04:00:30Z","toolUseId":"working-agent-call","agentId":"researcher-1","agent":"researcher","result":"The screenshot pass is complete; the composer stays above the keyboard.","state":"done","durationMs":18000}
    ]
    """#)

    static let workingBottomStack = BottomStackConfiguration(
        composer: ComposerConfiguration(
            placeholder: "Queue a message",
            isWorking: true,
            canInterrupt: true
        ),
        activitySession: workingSession
    )

    static let activityBottomStack = BottomStackConfiguration(
        composer: ComposerConfiguration(
            placeholder: "Queue a message",
            isWorking: true,
            canInterrupt: true
        ),
        activitySession: activitySession
    )

    static let slashBottomStack = BottomStackConfiguration(
        composer: ComposerConfiguration(initialText: "/"),
        slashCommands: slashCommands
    )

    static let attachmentBottomStack = BottomStackConfiguration(
        composer: ComposerConfiguration(initialText: "Here are the screenshots"),
        attachments: [
            ComposerAttachment(id: "judge-alignment", content: .image(resourceName: "judge-alignment", progress: nil)),
            ComposerAttachment(id: "rollout", content: .image(resourceName: "rollout", progress: 0.62)),
            ComposerAttachment(id: "evidence", content: .file(name: "evidence.csv"))
        ]
    )

    static let keyboardBottomStack = BottomStackConfiguration(
        composer: ComposerConfiguration(focusesOnAppear: true)
    )

    private static func decode(_ json: String) -> [Turn] {
        do {
            let entries = try JSONDecoder.ccKit().decode([TranscriptEntry].self, from: Data(json.utf8))
            return groupTranscript(entries: entries, working: true, now: MockFixtures.now)
        } catch {
            fatalError("Bottom stack mock transcript failed to decode: \(error)")
        }
    }
}
#endif
