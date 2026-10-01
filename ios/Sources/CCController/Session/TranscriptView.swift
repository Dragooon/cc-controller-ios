import CCKit
import SwiftUI

struct SessionTranscriptView: View {
    let turns: [Turn]
    let now: Date
    let subagents: [Subagent]
    let showsComposer: Bool
    let showsWorkedFooter: Bool
    let bottomStackConfiguration: BottomStackConfiguration?
    let queuedNotes: [QueuedNote]
    let activityFooter: CCKit.ActivityFooter?
    let hasMoreEarlier: Bool
    let loadEarlier: (() async throws -> Void)?
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    let scrollAnchor: UnitPoint
    @State private var isLoadingEarlier = false
    @State private var didTriggerPaging = false
    @State private var newestIsVisible = true
    @State private var pagingAnchorID: Turn.ID?
    @State private var pagingError: String?
    @State private var transcriptHeight: CGFloat = 0

    init(
        turns: [Turn],
        now: Date,
        showsComposer: Bool = true,
        showsWorkedFooter: Bool = true,
        bottomStackConfiguration: BottomStackConfiguration? = nil,
        queuedNotes: [QueuedNote] = [],
        activityFooter: CCKit.ActivityFooter? = nil,
        subagents: [Subagent] = [],
        hasMoreEarlier: Bool = false,
        loadEarlier: (() async throws -> Void)? = nil,
        onTool: @escaping (ToolEntry) -> Void = { _ in },
        onSubagent: @escaping (SubagentEntry) -> Void = { _ in },
        onCompaction: @escaping (CompactionEntry) -> Void = { _ in },
        downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil,
        scrollAnchor: UnitPoint = .top
    ) {
        self.turns = turns
        self.now = now
        self.showsComposer = showsComposer
        self.showsWorkedFooter = showsWorkedFooter
        self.bottomStackConfiguration = bottomStackConfiguration
        self.queuedNotes = queuedNotes
        self.activityFooter = activityFooter
        self.subagents = subagents
        self.hasMoreEarlier = hasMoreEarlier
        self.loadEarlier = loadEarlier
        self.onTool = onTool
        self.onSubagent = onSubagent
        self.onCompaction = onCompaction
        self.downloadFile = downloadFile
        self.scrollAnchor = scrollAnchor
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    pagingRow
                    transcriptRows
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(showsComposer ? .bottom : scrollAnchor)
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { _, height in
                transcriptHeight = height
            }
            .onChange(of: turns.first?.id) { _, newID in
                guard let anchorID = pagingAnchorID, newID != anchorID else { return }
                withTransaction(Transaction(animation: nil)) {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
                pagingAnchorID = nil
            }
            .background(.ccBackground)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
                return visibleBottom >= geometry.contentSize.height - 36
            } action: { _, isAtBottom in
                newestIsVisible = isAtBottom
            }
            .overlay(alignment: .bottomTrailing) {
                if !newestIsVisible, let newestID = turns.last?.id {
                    Button {
                        withAnimation(.snappy) {
                            proxy.scrollTo(newestID, anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.ccAccent)
                            .frame(width: CCMetrics.controlCircle, height: CCMetrics.controlCircle)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
                    .contentShape(.rect)
                    .accessibilityLabel("Jump to latest")
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if showsComposer {
                    let configuration = bottomStackConfiguration ?? BottomStackConfiguration()
                    BottomStackView(configuration: configuration.withTranscriptHeight(transcriptHeight))
                }
            }
            .alert(
                "Couldn't load earlier transcript",
                isPresented: Binding(
                    get: { pagingError != nil },
                    set: { if !$0 { pagingError = nil } }
                )
            ) {
                Button("OK") { pagingError = nil }
            } message: {
                Text(pagingError ?? "The earlier transcript could not be loaded.")
            }
        }
    }

    @ViewBuilder
    private var pagingRow: some View {
        if hasMoreEarlier || isLoadingEarlier {
            HStack {
                if isLoadingEarlier {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .id("transcript-paging-top")
            .onAppear {
                loadEarlierIfNeeded()
            }
            .onDisappear {
                didTriggerPaging = false
            }
        }
    }

    private func loadEarlierIfNeeded() {
        guard hasMoreEarlier, !isLoadingEarlier, !didTriggerPaging, let loadEarlier else { return }
        pagingAnchorID = turns.first?.id
        didTriggerPaging = true
        isLoadingEarlier = true
        Task { @MainActor in
            do {
                try await loadEarlier()
            } catch {
                pagingError = error.localizedDescription
            }
            isLoadingEarlier = false
        }
    }

    @ViewBuilder
    private var transcriptRows: some View {
        ForEach(turns) { turn in
            TranscriptTurnView(
                turn: turn,
                now: now,
                subagents: subagents,
                showsWorkedFooter: showsWorkedFooter,
                activityFooter: turn.id == turns.last?.id ? activityFooter : nil,
                onTool: onTool,
                onSubagent: onSubagent,
                onCompaction: onCompaction,
                downloadFile: downloadFile
            )
            .id(turn.id)
        }

        ForEach(Array(queuedNotes.enumerated()), id: \.offset) { _, note in
            QueuedPromptView(text: note.text)
        }
    }
}

private struct QueuedPromptView: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            PromptBubble(prompt: PromptEntry(text: text))
                .opacity(0.55)
            Text("Queued")
                .font(.caption)
                .foregroundStyle(.ccSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(text), Queued")
    }
}

struct TranscriptTurnView: View {
    let turn: Turn
    let now: Date
    let subagents: [Subagent]
    let showsWorkedFooter: Bool
    let activityFooter: CCKit.ActivityFooter?
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?

    init(
        turn: Turn,
        now: Date,
        subagents: [Subagent] = [],
        showsWorkedFooter: Bool,
        activityFooter: CCKit.ActivityFooter? = nil,
        onTool: @escaping (ToolEntry) -> Void,
        onSubagent: @escaping (SubagentEntry) -> Void,
        onCompaction: @escaping (CompactionEntry) -> Void = { _ in },
        downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil
    ) {
        self.turn = turn
        self.now = now
        self.subagents = subagents
        self.showsWorkedFooter = showsWorkedFooter
        self.activityFooter = activityFooter
        self.onTool = onTool
        self.onSubagent = onSubagent
        self.onCompaction = onCompaction
        self.downloadFile = downloadFile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(turn.prompts.enumerated()), id: \.offset) { _, prompt in
                PromptBubble(prompt: prompt)
            }

            ForEach(turn.items) { item in
                TurnItemView(
                    item: item,
                    now: now,
                    subagents: subagents,
                    onTool: onTool,
                    onSubagent: onSubagent,
                    onCompaction: onCompaction,
                    downloadFile: downloadFile
                )
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
    let subagents: [Subagent]
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?

    init(
        item: TurnItem,
        now: Date,
        subagents: [Subagent] = [],
        onTool: @escaping (ToolEntry) -> Void,
        onSubagent: @escaping (SubagentEntry) -> Void,
        onCompaction: @escaping (CompactionEntry) -> Void = { _ in },
        downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil
    ) {
        self.item = item
        self.now = now
        self.subagents = subagents
        self.onTool = onTool
        self.onSubagent = onSubagent
        self.onCompaction = onCompaction
        self.downloadFile = downloadFile
    }

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
            SendMessageView(entry: entry, subagents: subagents)
        case .decision(let entry):
            DecisionCaption(entry: entry)
        case .interrupt:
            CaptionRow(symbol: "stop.circle", text: "Interrupted", symbolColor: .ccSecondary)
        case .compaction(let entry):
            CompactionDivider(entry: entry, onOpen: onCompaction)
        case .file(let entry):
            FileEntryView(entry: entry, download: downloadFile)
        case .other:
            EmptyView()
        }
    }
}
