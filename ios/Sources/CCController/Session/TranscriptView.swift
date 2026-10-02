import CCKit
import SwiftUI

struct SessionTranscriptView: View {
    let sessionID: String
    let turns: [Turn]
    let subagents: [Subagent]
    let showsComposer: Bool
    let showsWorkedFooter: Bool
    let bottomStackConfiguration: BottomStackConfiguration?
    let queuedNotes: [QueuedNote]
    let activityFooter: CCKit.ActivityFooter?
    let liveSession: Session?
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
        sessionID: String = "",
        turns: [Turn],
        showsComposer: Bool = true,
        showsWorkedFooter: Bool = true,
        bottomStackConfiguration: BottomStackConfiguration? = nil,
        queuedNotes: [QueuedNote] = [],
        activityFooter: CCKit.ActivityFooter? = nil,
        liveSession: Session? = nil,
        subagents: [Subagent] = [],
        hasMoreEarlier: Bool = false,
        loadEarlier: (() async throws -> Void)? = nil,
        onTool: @escaping (ToolEntry) -> Void = { _ in },
        onSubagent: @escaping (SubagentEntry) -> Void = { _ in },
        onCompaction: @escaping (CompactionEntry) -> Void = { _ in },
        downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil,
        scrollAnchor: UnitPoint = .top
    ) {
        self.sessionID = sessionID
        self.turns = turns
        self.showsComposer = showsComposer
        self.showsWorkedFooter = showsWorkedFooter
        self.bottomStackConfiguration = bottomStackConfiguration
        self.queuedNotes = queuedNotes
        self.activityFooter = activityFooter
        self.liveSession = liveSession
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
            .onChange(of: turns.last?.id) { _, _ in
                scrollToNewest(using: proxy)
            }
            .onChange(of: queuedNotes) { _, _ in
                scrollToNewest(using: proxy)
            }
            .background(.ccBackground)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
                return visibleBottom >= geometry.contentSize.height - 36
            } action: { _, isAtBottom in
                newestIsVisible = isAtBottom
                if !isAtBottom { loadEarlierIfNeeded() }
            }
            .overlay(alignment: .bottomTrailing) {
                if !newestIsVisible, let newestID = turns.last?.id {
                    Button {
                        withAnimation(.snappy) {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
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

    private func scrollToNewest(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard newestIsVisible else { return }
            withAnimation(.snappy) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var transcriptRows: some View {
        ForEach(turns) { turn in
            TranscriptTurnView(
                sessionID: sessionID,
                turn: turn,
                subagents: subagents,
                showsWorkedFooter: showsWorkedFooter,
                activityFooter: turn.id == turns.last?.id ? activityFooter : nil,
                liveSession: liveSession,
                onTool: onTool,
                onSubagent: onSubagent,
                onCompaction: onCompaction,
                downloadFile: downloadFile
            )
            .id(turn.id)
        }

        ForEach(Array(queuedNotes.enumerated()), id: \.offset) { _, note in
            PendingPromptView(sessionID: sessionID, note: note, downloadFile: downloadFile)
        }

        Color.clear
            .frame(height: 1)
            .id("transcript-bottom")
            .accessibilityHidden(true)
    }
}

private struct PendingPromptView: View {
    let sessionID: String
    let note: QueuedNote
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?

    private var promptDownload: (@MainActor @Sendable (String) async throws -> URL)? {
        guard let downloadFile else { return nil }
        let sessionID = self.sessionID
        return { name in
            try await downloadFile(FileEntry(sessionId: sessionID, name: name))
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            PromptBubble(
                prompt: PromptEntry(text: note.text, attachments: note.attachments),
                sessionID: sessionID,
                downloadFile: promptDownload,
                attachmentThumbnails: note.attachmentThumbnails,
                bubbleAccessibilityIdentifier: "pending-prompt-bubble"
            )
                .opacity(0.55)
            if note.queued {
                Text("Queued")
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pending-prompt")
        .accessibilityLabel(note.queued ? "\(note.text), Queued" : note.text)
    }
}

struct TranscriptTurnView: View {
    let sessionID: String
    let turn: Turn
    let subagents: [Subagent]
    let showsWorkedFooter: Bool
    let activityFooter: CCKit.ActivityFooter?
    let liveSession: Session?
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?

    init(
        sessionID: String = "",
        turn: Turn,
        subagents: [Subagent] = [],
        showsWorkedFooter: Bool,
        activityFooter: CCKit.ActivityFooter? = nil,
        liveSession: Session? = nil,
        onTool: @escaping (ToolEntry) -> Void,
        onSubagent: @escaping (SubagentEntry) -> Void,
        onCompaction: @escaping (CompactionEntry) -> Void = { _ in },
        downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil
    ) {
        self.sessionID = sessionID
        self.turn = turn
        self.subagents = subagents
        self.showsWorkedFooter = showsWorkedFooter
        self.activityFooter = activityFooter
        self.liveSession = liveSession
        self.onTool = onTool
        self.onSubagent = onSubagent
        self.onCompaction = onCompaction
        self.downloadFile = downloadFile
    }

    private var promptDownload: (@MainActor @Sendable (String) async throws -> URL)? {
        guard let downloadFile else { return nil }
        let sessionID = self.sessionID
        return { name in
            try await downloadFile(FileEntry(sessionId: sessionID, name: name))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(turn.prompts.enumerated()), id: \.offset) { _, prompt in
                PromptBubble(
                    prompt: prompt,
                    sessionID: sessionID,
                    downloadFile: promptDownload
                )
            }

            ForEach(turn.items) { item in
                TurnItemView(
                    item: item,
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
                LiveActivityFooterView(footer: activityFooter, session: liveSession)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TurnItemView: View {
    let item: TurnItem
    let subagents: [Subagent]
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?

    init(
        item: TurnItem,
        subagents: [Subagent] = [],
        onTool: @escaping (ToolEntry) -> Void,
        onSubagent: @escaping (SubagentEntry) -> Void,
        onCompaction: @escaping (CompactionEntry) -> Void = { _ in },
        downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil
    ) {
        self.item = item
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
            SubagentCard(entry: entry, onOpen: onSubagent)
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
