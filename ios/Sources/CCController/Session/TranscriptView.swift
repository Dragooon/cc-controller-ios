import CCKit
import SwiftUI

struct SessionTranscriptView: View {
    let turns: [Turn]
    let now: Date
    let showsComposer: Bool
    let showsWorkedFooter: Bool
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void

    init(
        turns: [Turn],
        now: Date,
        showsComposer: Bool = true,
        showsWorkedFooter: Bool = true,
        onTool: @escaping (ToolEntry) -> Void = { _ in },
        onSubagent: @escaping (SubagentEntry) -> Void = { _ in }
    ) {
        self.turns = turns
        self.now = now
        self.showsComposer = showsComposer
        self.showsWorkedFooter = showsWorkedFooter
        self.onTool = onTool
        self.onSubagent = onSubagent
    }

    @ViewBuilder
    var body: some View {
        if showsComposer {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        transcriptRows
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)

                ComposerPlaceholder()
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
            .background(.ccBackground)
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
                onTool: onTool,
                onSubagent: onSubagent
            )
            .id(turn.id)
        }
    }
}

struct ComposerPlaceholder: View {
    var body: some View {
        HStack {
            Text("Message")
                .font(.body)
                .foregroundStyle(.ccSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityLabel("Message")
    }
}

struct TranscriptTurnView: View {
    let turn: Turn
    let now: Date
    let showsWorkedFooter: Bool
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void

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
