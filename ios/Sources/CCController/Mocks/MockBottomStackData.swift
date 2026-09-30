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
        startedAt: MockFixtures.now.addingTimeInterval(-42)
    )

    static let statusSegments = buildStatusSegments(workingSession, now: MockFixtures.now)

    static let activityFooter: ActivityFooter = {
        let activitySession = Session(
            lastTool: "Bash",
            lastToolInput: .object(["command": .string("npm test")]),
            toolRunning: true,
            usage: Usage(outputTokens: 22_000),
            startedAt: MockFixtures.now.addingTimeInterval(-1_877)
        )
        return activityFooterText(activitySession, now: MockFixtures.now, verb: "Contemplating")
    }()

    static let workingTurns: [Turn] = decode(#"""
    [
      {"kind":"prompt","id":"working-prompt","ts":"2026-09-30T04:00:00Z","text":"Finish the native composer mocks and check every screenshot."},
      {"kind":"assistant","id":"working-assistant","ts":"2026-09-30T04:00:12Z","text":"I am checking the bottom stack at both phone sizes and will keep the composer above the keyboard."},
      {"kind":"tool","id":"working-read","ts":"2026-09-30T04:00:18Z","toolUseId":"working-read","tool":"Read","args":{"file_path":"tasks/native-app.md"},"result":"Read the Bottom stack and Keyboard decisions.","state":"done"},
      {"kind":"tool","id":"working-bash","ts":"2026-09-30T04:00:24Z","toolUseId":"working-bash","tool":"Bash","args":{"command":"npm test"},"result":"Running test suite…","state":"running"}
    ]
    """#)

    static let workingBottomStack = BottomStackConfiguration(
        composer: ComposerConfiguration(
            placeholder: "Queue a message",
            isWorking: true,
            hasTmuxPane: true
        ),
        statusSegments: statusSegments
    )

    static let slashBottomStack = BottomStackConfiguration(
        composer: ComposerConfiguration(initialText: "/co"),
        statusSegments: statusSegments,
        slashCommands: slashCommands
    )

    static let attachmentBottomStack = BottomStackConfiguration(
        composer: ComposerConfiguration(initialText: "Here are the screenshots"),
        statusSegments: statusSegments,
        attachments: [
            ComposerAttachment(id: "judge-alignment", content: .image(resourceName: "judge-alignment", progress: nil)),
            ComposerAttachment(id: "rollout", content: .image(resourceName: "rollout", progress: 0.62)),
            ComposerAttachment(id: "evidence", content: .file(name: "evidence.csv"))
        ]
    )

    static let keyboardBottomStack = BottomStackConfiguration(
        composer: ComposerConfiguration(focusesOnAppear: true),
        statusSegments: statusSegments
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
