import CCKit
import SwiftUI

struct SessionTranscriptView: View {
    let turns: [Turn]
    let now: Date
    let showsComposer: Bool
    let showsWorkedFooter: Bool
    let bottomStackConfiguration: BottomStackConfiguration?
    let activityFooter: CCKit.ActivityFooter?
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void

    init(
        turns: [Turn],
        now: Date,
        showsComposer: Bool = true,
        showsWorkedFooter: Bool = true,
        bottomStackConfiguration: BottomStackConfiguration? = nil,
        activityFooter: CCKit.ActivityFooter? = nil,
        onTool: @escaping (ToolEntry) -> Void = { _ in },
        onSubagent: @escaping (SubagentEntry) -> Void = { _ in }
    ) {
        self.turns = turns
        self.now = now
        self.showsComposer = showsComposer
        self.showsWorkedFooter = showsWorkedFooter
        self.bottomStackConfiguration = bottomStackConfiguration
        self.activityFooter = activityFooter
        self.onTool = onTool
        self.onSubagent = onSubagent
    }

    @ViewBuilder
    var body: some View {
        if showsComposer {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    transcriptRows
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(.ccBackground)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                BottomStackView(configuration: bottomStackConfiguration ?? BottomStackConfiguration())
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    transcriptRows
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .defaultScrollAnchor(.top)
            .scrollDismissesKeyboard(.interactively)
            .background(.ccBackground)
        }
    }

    @ViewBuilder
    private var transcriptRows: some View {
        ForEach(turns) { turn in
            TranscriptTurnView(
                turn: turn,
                now: now,
                showsWorkedFooter: showsWorkedFooter,
                activityFooter: turn.id == turns.last?.id ? activityFooter : nil,
                onTool: onTool,
                onSubagent: onSubagent
            )
            .id(turn.id)
        }
    }
}

struct TranscriptTurnView: View {
    let turn: Turn
    let now: Date
    let showsWorkedFooter: Bool
    let activityFooter: CCKit.ActivityFooter?
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void

    init(
        turn: Turn,
        now: Date,
        showsWorkedFooter: Bool,
        activityFooter: CCKit.ActivityFooter? = nil,
        onTool: @escaping (ToolEntry) -> Void,
        onSubagent: @escaping (SubagentEntry) -> Void
    ) {
        self.turn = turn
        self.now = now
        self.showsWorkedFooter = showsWorkedFooter
        self.activityFooter = activityFooter
        self.onTool = onTool
        self.onSubagent = onSubagent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(turn.prompts.enumerated()), id: \.offset) { _, prompt in
                PromptBubble(prompt: prompt)
            }

            ForEach(turn.items) { item in
                TurnItemView(item: item, now: now, onTool: onTool, onSubagent: onSubagent)
            }

            if showsWorkedFooter && turn.hasWorkedFooter {
                WorkedFooter(durationMs: turn.durationMs)
            }

            if let activityFooter {
                LiveActivityFooterView(footer: activityFooter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TurnItemView: View {
    let item: TurnItem
    let now: Date
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void

    @ViewBuilder
    var body: some View {
        switch item {
        case .assistant(let entry):
            AssistantReplyView(text: entry.text ?? "")
        case .tools(let run):
            ToolRunCard(run: run, onTool: onTool)
        case .subagent(let entry):
            SubagentCard(entry: entry, now: now, onOpen: onSubagent)
        case .subagentResult(let entry):
            SubagentResultView(entry: entry)
        case .sendMessage(let entry):
            SendMessageView(entry: entry)
        case .decision(let entry):
            DecisionCaption(entry: entry)
        case .interrupt:
            CaptionRow(symbol: "stop.circle", text: "Interrupted", symbolColor: .ccSecondary)
        case .compaction(let entry):
            CompactionDivider(entry: entry)
        case .file(let entry):
            FileEntryView(entry: entry)
        case .other:
            EmptyView()
        }
    }
}
