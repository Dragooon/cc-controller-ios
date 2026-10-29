import CCKit
import Foundation
import SwiftUI

#if DEBUG
enum SessionMocks {
    static var warmTheme: some View {
        WarmThemeMock()
    }

    static var idle: some View {
        SessionMockScreen(
            session: MockSessionData.session,
            turns: MockSessionData.turns,
            subagents: MockSessionData.subagents,
            now: MockFixtures.now
        )
    }

    static var activity: some View {
        ActivitySessionMock()
    }

    static var sendingStates: some View {
        NavigationStack {
            SessionTranscriptView(
                turns: MockSessionData.shortTurns,
                showsComposer: false,
                showsWorkedFooter: false,
                queuedNotes: MockSessionData.sendingStateNotes,
                sessionState: .idle
            )
            .navigationTitle("Sending states")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(.ccAccent)
        .background(.ccBackground)
    }

    static var toolDetail: some View {
        ToolDetailMock(
            session: MockSessionData.session,
            turns: MockSessionData.turns,
            tool: MockSessionData.bashTool
        )
    }

    static var toolDetailEdit: some View {
        ToolDetailEditMock(
            session: MockSessionData.session,
            turns: MockSessionData.turns
        )
    }

    static var resultSheet: some View {
        SubagentResultSheetMock()
    }

    static var subagent: some View {
        SubagentMock(
            turns: MockSessionData.subagentTurns,
            now: MockFixtures.now
        )
    }
}

private struct SessionMockScreen: View {
    let session: Session
    let turns: [Turn]
    let subagents: [Subagent]
    let now: Date

    var body: some View {
        NavigationStack {
            SessionTranscriptView(turns: turns, subagents: subagents)
                .navigationTitle(session.name ?? "Session")
                .navigationSubtitle(sessionDetailSubtitle(session, now: now))
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
        .toolbarBackground(.ccBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct ActivitySessionMock: View {
    private let session = MockBottomStackData.activitySession

    var body: some View {
        NavigationStack {
            SessionTranscriptView(
                turns: MockBottomStackData.workingTurns,
                showsWorkedFooter: false,
                bottomStackConfiguration: MockBottomStackData.activityBottomStack
            )
            .navigationTitle(session.name ?? "Session")
            .navigationSubtitle(sessionDetailSubtitle(session))
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
        .toolbarBackground(.ccBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct ToolDetailMock: View {
    let session: Session
    let turns: [Turn]
    let tool: ToolEntry

    var body: some View {
        SessionMockScreen(session: session, turns: turns, subagents: MockSessionData.subagents, now: MockFixtures.now)
            .sheet(isPresented: .constant(true)) {
                ToolDetailSheet(tool: tool)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }
}

private struct ToolDetailEditMock: View {
    let session: Session
    let turns: [Turn]

    var body: some View {
        SessionMockScreen(session: session, turns: turns, subagents: MockSessionData.subagents, now: MockFixtures.now)
            .sheet(isPresented: .constant(true)) {
                ToolDetailSheet(tool: MockSessionData.editTool)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }
}


private struct SubagentResultSheetMock: View {
    var body: some View {
        SessionMockScreen(
            session: MockSessionData.session,
            turns: MockSessionData.turns,
            subagents: MockSessionData.subagents,
            now: MockFixtures.now
        )
        .sheet(isPresented: .constant(true)) {
            SubagentResultSheet(
                entry: MockSessionData.subagentResult,
                subagent: MockSessionData.resultSubagent,
                onViewTranscript: {}
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct SubagentMock: View {
    let turns: [Turn]
    let now: Date
    @State private var isPushed = true

    var body: some View {
        NavigationStack {
            SessionTranscriptView(
                turns: MockSessionData.turns,
                showsComposer: false,
                showsWorkedFooter: false
            )
            .navigationTitle("Eval dataset versioning")
            .navigationDestination(isPresented: $isPushed) {
                SessionTranscriptView(
                    turns: turns,
                    showsComposer: false,
                    showsWorkedFooter: false
                )
                .navigationTitle("researcher")
                .navigationSubtitle("done · 4m")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .tint(.ccAccent)
        .background(.ccBackground)
    }
}

private struct WarmThemeMock: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                transcriptLayout
            }
        }
        .tint(.ccAccent)
        .background(.ccBackground)
    }

    private var regularLayout: some View {
        NavigationSplitView {
            SessionsListView(sessions: MockFixtures.sessions, subtitleOverride: "Mac")
        } detail: {
            transcriptLayout
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var transcriptLayout: some View {
        NavigationStack {
            SessionTranscriptView(
                turns: MockSessionData.warmThemeTurns,
                subagents: []
            )
            .navigationTitle("Eval dataset versioning")
            .navigationSubtitle("atlas · idle")
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
        .toolbarBackground(.ccBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

enum MockSessionData {
    static let session = MockFixtures.sessions.first(where: { $0.name == "Eval dataset versioning" }) ?? Session(
        id: "mock-session",
        name: "Eval dataset versioning",
        project: "atlas",
        state: .idle,
        usage: Usage(model: "claude-fable-5-1", contextPercent: 32),
        idleSince: Date(timeIntervalSince1970: 1790738400)
    )

    static let subagents: [Subagent] = [
        resultSubagent
    ]

    static let resultSubagent = Subagent(
        agentId: "researcher-1",
        agent: "researcher",
        text: "Check the rollout events and compare the desired agent image with the running pods.",
        state: .done,
        startedAt: Date(timeIntervalSince1970: 1790739060),
        finishedAt: Date(timeIntervalSince1970: 1790739300),
        linked: true,
        toolUseId: "agent-call-1",
        result: "The deployment is healthy; one pod is being replaced after the image digest changed."
    )

    static let subagentResult = SubagentResultEntry(
        id: "researcher-result-1",
        ts: Date(timeIntervalSince1970: 1790739300),
        toolUseId: "agent-call-1",
        agentId: "researcher-1",
        agent: "researcher",
        text: "Check the rollout events and compare the desired agent image with the running pods.",
        state: .done,
        result: "The deployment is healthy; one pod is being replaced after the image digest changed.\n\nThe new digest is registered and the final pod is progressing through readiness.",
        durationMs: 240_000
    )

    static let shortTurns: [Turn] = [
        Turn(
            id: "sending-states-idle",
            prompts: [PromptEntry(id: "sending-states-prompt", text: "Review the latest session changes.")],
            items: [.assistant(AssistantEntry(id: "sending-states-assistant", text: "The session is idle and ready for another message."))],
            end: TurnEndEntry(id: "sending-states-end"),
            durationMs: 1_200,
            hasBody: true,
            live: false,
            hasWorkedFooter: false
        )
    ]

    static let warmThemeTurns: [Turn] = {
        groupTranscript(entries: decode(warmThemeJSON), working: false, now: MockFixtures.now)
    }()

    static let sendingStateNotes: [QueuedNote] = {
        let now = MockFixtures.now
        let currentTime = Date()
        return [
            QueuedNote(id: "sending-state-sending", text: "A message is being sent", state: .sending, createdAt: now, now: false),
            QueuedNote(id: "sending-state-sent", text: "A message was sent", state: .sent, createdAt: currentTime, sentAt: currentTime, now: false),
            QueuedNote(id: "sending-state-queued", text: "A message is queued", state: .queued, createdAt: now, sentAt: now, now: false),
            QueuedNote(id: "sending-state-attention", text: "A message needs attention", state: .sent, createdAt: currentTime.addingTimeInterval(-60), sentAt: currentTime.addingTimeInterval(-60), now: false),
            QueuedNote(id: "sending-state-failed", text: "A message failed", state: .failed(message: "The fixture could not send this message."), createdAt: now, now: false)
        ]
    }()

    static let turns: [Turn] = {
        let entries = decode(transcriptJSON)
        return groupTranscript(entries: entries, working: false, now: MockFixtures.now)
    }()

    static let subagentTurns: [Turn] = {
        let entries = decode(subagentJSON)
        return groupTranscript(entries: entries, working: false, now: MockFixtures.now)
    }()

    static let bashTool = ToolEntry(
        id: "tool-detail-bash",
        ts: Date(timeIntervalSince1970: 1790740800),
        toolUseId: "tool-detail-bash",
        tool: "Bash",
        args: .object(["command": .string("npm test -- --runInBand")]),
        result: npmOutput,
        state: .done,
        durationMs: 2_400
    )

    static let editTool = ToolEntry(
        id: "tool-detail-edit",
        ts: Date(timeIntervalSince1970: 1790740800),
        toolUseId: "tool-detail-edit",
        tool: "Edit",
        args: .object([
            "file_path": .string("/Users/sam/dev/cc-controller/ios/Sources/CCController/Session/SessionTranscriptView.swift"),
            "old_string": .string("let status = \\\"loading\\\"\\nText(status)"),
            "new_string": .string("let status = \\\"ready\\\"\\nText(status).foregroundStyle(.ccGreen)")
        ]),
        result: "Updated SessionTranscriptView.swift",
        state: .done,
        durationMs: 1_100
    )

    static let npmOutput = """
    > cc-controller@0.1.0 test
    > swift test --package-path ios/CCKit && xcodebuild test -scheme CCController

    Building for debugging...
    Build complete! (1.84s)
    Test Suite 'All tests' started at 2026-09-30 14:01:22.103
    Test Suite 'CCKitPackageTests' started
    Test Case 'PresentationTests.testPromptCollapse' passed (0.001 seconds)
    Test Case 'PresentationTests.testToolGrouping' passed (0.002 seconds)
    Test Case 'PresentationTests.testWorkedFooter' passed (0.001 seconds)
    Test Case 'TranscriptTests.testWireDecode' passed (0.003 seconds)
    Test Case 'TranscriptTests.testSubagentResult' passed (0.001 seconds)
    Test Suite 'CCKitPackageTests' passed at 2026-09-30 14:01:23.020
    Executed 5 tests, with 0 failures (0 unexpected) in 0.917 seconds

    Prepare build
    Analyze workspace
    Compile Swift sources
    Link CCController
    Signing disabled for simulator
    Test session started
    MockScreenshotTests.testDesignMocks started
    session-idle dark default passed
    session-idle light default passed
    tool-detail dark default passed
    tool-detail-edit light default passed
    subagent dark default passed
    Accessibility audit completed
    Test session finished

    ** TEST SUCCEEDED **
    Testing completed successfully.
    """

    private static func decode(_ json: String) -> [TranscriptEntry] {
        do {
            return try JSONDecoder.ccKit().decode([TranscriptEntry].self, from: Data(json.utf8))
        } catch {
            fatalError("Session mock transcript failed to decode: \(error)")
        }
    }

    private static let warmThemeJSON = #"""
    [
      {"kind":"prompt","id":"warm-prompt-1","ts":"2026-09-30T03:24:00Z","text":"Review the Linen theme and confirm the transcript surfaces feel warm without losing contrast."},
      {"kind":"assistant","id":"warm-assistant-1","ts":"2026-09-30T03:24:08Z","text":"## Linen theme review\n\nThe **warm palette** softens the background and cards while preserving contrast.\n\n- Background: warm ivory\n- Cards: toasted oat\n- Prose: system font\n\n```swift\nlet background = Color.ccBackground\n```"},
      {"kind":"tool","id":"warm-read","ts":"2026-09-30T03:24:12Z","toolUseId":"warm-read","tool":"Read","args":{"file_path":"DesignSystem/Colors.swift"},"result":"Theme colors loaded successfully.","state":"done"},
      {"kind":"tool","id":"warm-bash","ts":"2026-09-30T03:24:14Z","toolUseId":"warm-bash","tool":"Bash","args":{"command":"xcodebuild -scheme CCController build"},"result":"Build Succeeded","state":"done"},
      {"kind":"tool","id":"warm-read-assets","ts":"2026-09-30T03:24:16Z","toolUseId":"warm-read-assets","tool":"Read","args":{"file_path":"Resources/Assets.xcassets/Linen"},"result":"Linen assets are present in light and dark appearances.","state":"done"},
      {"kind":"turn_end","id":"warm-end-1","ts":"2026-09-30T03:24:20Z","durationMs":20000},
      {"kind":"prompt","id":"warm-prompt-2","ts":"2026-09-30T03:25:00Z","text":"What should I compare next?"},
      {"kind":"assistant","id":"warm-assistant-2","ts":"2026-09-30T03:25:05Z","text":"Compare the light and dark captures first, then confirm the system font stays consistent."},
      {"kind":"turn_end","id":"warm-end-2","ts":"2026-09-30T03:25:08Z","durationMs":8000}
    ]
    """#

    private static let transcriptJSON = #"""
    [
      {"kind":"compaction","id":"compact-1","ts":"2026-09-30T03:10:00Z","text":"Earlier context was compacted after the policy evidence was collected."},
      {"kind":"turn_end","id":"end-compact","ts":"2026-09-30T03:10:01Z","durationMs":1000},
      {"kind":"prompt","id":"prompt-paste","ts":"2026-09-30T03:18:00Z","text":"Review the latest judge alignment screenshots and tell me what changed.","paste":{"lines":42,"text":"pasted review notes"},"attachments":["judge-alignment.png"]},
      {"kind":"tool","id":"send-1","ts":"2026-09-30T03:18:04Z","toolUseId":"send-1","tool":"SendMessage","args":{"to":"engineer","summary":"Polish four defects"},"result":"Message queued","state":"done"},
      {"kind":"interrupt","id":"interrupt-1","ts":"2026-09-30T03:18:30Z"},
      {"kind":"turn_end","id":"end-paste","ts":"2026-09-30T03:18:31Z","durationMs":31000},
      {"kind":"prompt","id":"prompt-long","ts":"2026-09-30T03:24:00Z","text":"Please compare the sandbox rollout.\nReview the evaluator results and approval history.\nCheck the migration order.\nCompare screenshots from the last three validation runs.\nCall out anything that could explain the mismatch.\nInclude the visible report state.\nInclude the persisted evaluation state.\nMention any stale agent image.\nKeep the findings actionable."},
      {"kind":"turn_end","id":"end-long","ts":"2026-09-30T03:24:15Z","durationMs":15000},
      {"kind":"prompt","id":"prompt-main","ts":"2026-09-30T03:28:00Z","text":"Why is the sandbox deploy stuck?"},
      {"kind":"assistant","id":"assistant-1","ts":"2026-09-30T03:28:20Z","text":"## The short version\n\nThe deploy is waiting on the **agent pool** to converge.\n\n- The backend rollout is healthy.\n- Two warm pods still have the previous image.\n- The migration gate is already green.\n\nThe next check is `AGENT_POD_IMAGE`, then we can rerun the smoke path.\n\n```\nkubectl -n product-analytics get pods -l app=agent -o wide\nkubectl -n data-risk get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}'\n```"},
      {"kind":"tool","id":"read-1","ts":"2026-09-30T03:29:00Z","toolUseId":"read-1","tool":"Read","args":{"file_path":"tasks/native-app.md"},"result":"Session section defines the transcript grammar and footer.","state":"done"},
      {"kind":"tool","id":"read-2","ts":"2026-09-30T03:29:04Z","toolUseId":"read-2","tool":"Read","args":{"file_path":"ios/CCKit/Sources/CCKit/Presentation.swift"},"result":"groupTranscript is the single presentation model.","state":"done"},
      {"kind":"tool","id":"bash-1","ts":"2026-09-30T03:29:12Z","toolUseId":"bash-1","tool":"Bash","args":{"command":"kubectl get pods -n product-analytics"},"result":"2 pods are still rolling out.","state":"done"},
      {"kind":"tool","id":"bash-2","ts":"2026-09-30T03:29:20Z","toolUseId":"bash-2","tool":"Bash","args":{"command":"kubectl rollout status deploy/backend -n data-risk"},"result":"deployment successfully rolled out", "state":"done"},
      {"kind":"tool","id":"grep-1","ts":"2026-09-30T03:29:28Z","toolUseId":"grep-1","tool":"Grep","args":{"pattern":"AGENT_POD_IMAGE"},"result":"Found in deployment values and health checks.","state":"done"},
      {"kind":"assistant","id":"assistant-2","ts":"2026-09-30T03:30:00Z","text":"The old pods are the only remaining mismatch; I am checking the live image label now."},
      {"kind":"tool","id":"read-live","ts":"2026-09-30T03:30:10Z","toolUseId":"read-live","tool":"Read","args":{"file_path":".env-sand"},"result":"AGENT_POD_IMAGE points at the release image.","state":"done"},
      {"kind":"tool","id":"bash-live","ts":"2026-09-30T03:30:18Z","toolUseId":"bash-live","tool":"Bash","args":{"command":"kubectl -n product-analytics wait --for=condition=ready pod -l app=agent"},"result":"all managed pods are ready", "state":"done"},
      {"kind":"subagent","id":"researcher-1","ts":"2026-09-30T03:31:00Z","toolUseId":"agent-call-1","agentId":"researcher-1","agent":"researcher","text":"Check the rollout events and compare the desired agent image with the running pods.","result":"The deployment is healthy; one pod is being replaced after the image digest changed.","state":"done","startedAt":"2026-09-30T03:31:00Z","finishedAt":"2026-09-30T03:35:00Z"},
      {"kind":"subagent_result","id":"researcher-result-1","ts":"2026-09-30T03:35:00Z","toolUseId":"agent-call-1","agentId":"researcher-1","agent":"researcher","result":"The deployment is healthy; one pod is being replaced after the image digest changed.\n\nThe new digest is registered and the final pod is progressing through readiness.","state":"done","durationMs":240000},
      {"kind":"decision","id":"decision-1","ts":"2026-09-30T03:36:00Z","requestId":"approval-1","behavior":"allow","text":"Allowed from this device"},
      {"kind":"file","id":"file-evidence","ts":"2026-09-30T03:37:00Z","name":"evidence.csv","size":18432,"mime":"text/csv","url":"file:///evidence.csv"},
      {"kind":"file","id":"file-image","ts":"2026-09-30T03:38:00Z","name":"rollout.png","size":92834,"mime":"image/png","url":"file:///rollout.png"},
      {"kind":"assistant","id":"assistant-final","ts":"2026-09-30T03:39:00Z","text":"The deploy is unstuck: the final agent pod is now on the release digest.\n\n| Check | Result |\n| --- | --- |\n| Backend rollout | Healthy |\n| Agent pool | Converged |\n| Smoke path | Ready to run |"},
      {"kind":"turn_end","id":"end-main","ts":"2026-09-30T03:40:00Z","durationMs":720000}
    ]
    """#

    private static let subagentJSON = #"""
    [
      {"kind":"prompt","id":"sub-prompt","ts":"2026-09-30T03:31:00Z","text":"Check the rollout events and compare the desired agent image with the running pods."},
      {"kind":"tool","id":"sub-bash-rollout","ts":"2026-09-30T03:32:00Z","toolUseId":"sub-bash-rollout","tool":"Bash","args":{"command":"kubectl rollout status deploy/agent -n atlas"},"result":"deployment \"agent\" successfully rolled out","state":"done"},
      {"kind":"tool","id":"sub-bash-pods","ts":"2026-09-30T03:32:08Z","toolUseId":"sub-bash-pods","tool":"Bash","args":{"command":"kubectl get pods -n atlas"},"result":"3 running, 1 terminating","state":"done"},
      {"kind":"assistant","id":"sub-assistant","ts":"2026-09-30T03:35:00Z","text":"## Rollout comparison\n\nThe deployment is healthy; one pod is being replaced after the image digest changed.\n\nThe new digest is registered and the final pod is progressing through readiness."},
      {"kind":"turn_end","id":"sub-end","ts":"2026-09-30T03:35:00Z","durationMs":240000}
    ]
    """#
}
#endif
