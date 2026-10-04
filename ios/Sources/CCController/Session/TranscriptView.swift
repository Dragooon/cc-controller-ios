import CCKit
import SwiftUI

private struct TranscriptScrollMetrics: Equatable {
    let isAtBottom: Bool
    let contentFitsViewport: Bool
}

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
    let onSubagentResult: (SubagentResultEntry, Subagent?) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    let scrollAnchor: UnitPoint
    @State private var isLoadingEarlier = false
    @State private var didTriggerPaging = false
    @State private var pagingRowIsVisible = false
    @State private var newestIsVisible = true
    @State private var pagingAnchorEntryID: String?
    @State private var pagingRestoreTask: Task<Void, Never>?
    @State private var newestScrollTask: Task<Void, Never>?
    @State private var pagingError: String?
    @State private var transcriptHeight: CGFloat = 0
    @State private var userHasScrolled = false
    @State private var contentFitsViewport = false

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
        onSubagentResult: @escaping (SubagentResultEntry, Subagent?) -> Void = { _, _ in },
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
        self.onSubagentResult = onSubagentResult
        self.onCompaction = onCompaction
        self.downloadFile = downloadFile
        self.scrollAnchor = scrollAnchor
    }

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.transcriptList)
        #endif
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    pagingRow
                    transcriptRows
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .scrollTargetLayout()
                #if DEBUG
                .onAppear { TranscriptPerformance.shared.markFirstRows() }
                #endif
            }
            .defaultScrollAnchor(showsComposer ? .bottom : scrollAnchor)
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { _, height in
                transcriptHeight = height
            }
            .onChange(of: turns.first?.id) { _, newID in
                guard let anchorEntryID = pagingAnchorEntryID else { return }
                guard let anchorID = turns.first(where: { $0.entryIDs.contains(anchorEntryID) })?.id else {
                    pagingAnchorEntryID = nil
                    return
                }
                guard newID != anchorID else { return }
                cancelPagingRestore()
                scrollToPagingAnchor(anchorID, using: proxy)
                pagingAnchorEntryID = nil
                pagingRestoreTask = Task { @MainActor in
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scrollToPagingAnchor(anchorID, using: proxy)
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    scrollToPagingAnchor(anchorID, using: proxy)
                }
            }
            .onChange(of: turns.last) { _, _ in
                scrollToNewest(using: proxy)
            }
            .onChange(of: queuedNotes) { _, _ in
                scrollToNewest(using: proxy)
            }
            .background(.ccBackground)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
                let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
                return TranscriptScrollMetrics(
                    isAtBottom: visibleBottom >= geometry.contentSize.height - 36,
                    contentFitsViewport: geometry.contentSize.height <= geometry.visibleRect.height
                )
            } action: { _, metrics in
                newestIsVisible = metrics.isAtBottom
                contentFitsViewport = metrics.contentFitsViewport
                if metrics.contentFitsViewport {
                    loadEarlierIfNeeded()
                }
            }
            .onScrollPhaseChange { _, phase in
                guard phase == .interacting else { return }
                newestScrollTask?.cancel()
                userHasScrolled = true
                if pagingRowIsVisible {
                    loadEarlierIfNeeded()
                }
                cancelPagingRestore()
            }
            .onChange(of: sessionID) { _, _ in
                userHasScrolled = false
                contentFitsViewport = false
                pagingAnchorEntryID = nil
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
            #if DEBUG
            .overlay(alignment: .topLeading) {
                Text(TranscriptPerformance.shared.snapshot)
                    .accessibilityIdentifier("transcript-performance")
                    .accessibilityLabel(TranscriptPerformance.shared.snapshot)
                    .font(.caption2)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
            #endif
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
                pagingRowIsVisible = true
                loadEarlierIfNeeded()
            }
            .onDisappear {
                pagingRowIsVisible = false
                didTriggerPaging = false
            }
        }
    }

    private func loadEarlierIfNeeded() {
        guard hasMoreEarlier,
              !isLoadingEarlier,
              !didTriggerPaging,
              userHasScrolled || contentFitsViewport,
              let loadEarlier else { return }
        cancelPagingRestore()
        pagingAnchorEntryID = turns.first?.entryIDs.first
        didTriggerPaging = true
        isLoadingEarlier = true
        Task { @MainActor in
            var loaded = false
            do {
                try await loadEarlier()
                loaded = true
            } catch {
                pagingError = error.localizedDescription
            }
            isLoadingEarlier = false
            didTriggerPaging = false
            guard loaded, pagingRowIsVisible else { return }
            Task { @MainActor in
                await Task.yield()
                guard pagingRowIsVisible else { return }
                loadEarlierIfNeeded()
            }
        }
    }

    private func cancelPagingRestore() {
        pagingRestoreTask?.cancel()
        pagingRestoreTask = nil
    }

    private func scrollToPagingAnchor(_ anchorID: Turn.ID, using proxy: ScrollViewProxy) {
        withTransaction(Transaction(animation: nil)) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    private func scrollToNewest(using proxy: ScrollViewProxy) {
        #if CC_PERF
        PerfCounters.shared.hit(.scrollToBottom)
        #endif
        guard newestIsVisible else { return }
        newestScrollTask?.cancel()
        newestScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    private func relevantSubagents(for turn: Turn) -> [Subagent] {
        var identifiers = Set<String>()
        var targets = Set<String>()
        for item in turn.items {
            switch item {
            case .subagent(let entry):
                if let agentId = entry.agentId { identifiers.insert(agentId) }
                if let toolUseId = entry.toolUseId { identifiers.insert(toolUseId) }
            case .subagentResult(let entry):
                if let agentId = entry.agentId { identifiers.insert(agentId) }
                if let toolUseId = entry.toolUseId { identifiers.insert(toolUseId) }
            case .sendMessage(let entry):
                let args = entry.args?.objectValue ?? [:]
                if let target = args["to"]?.stringValue ?? args["recipient"]?.stringValue {
                    targets.insert(target)
                }
            default:
                break
            }
        }
        guard !identifiers.isEmpty || !targets.isEmpty else { return [] }
        return subagents.filter { subagent in
            identifiers.contains(subagent.agentId ?? "")
                || identifiers.contains(subagent.toolUseId ?? "")
                || targets.contains(subagent.agentId ?? "")
        }
    }

    @ViewBuilder
    private var transcriptRows: some View {
        ForEach(turns) { turn in
            let isNewest = turn.id == turns.last?.id
            TranscriptTurnView(
                sessionID: sessionID,
                turn: turn,
                subagents: relevantSubagents(for: turn),
                showsWorkedFooter: showsWorkedFooter,
                activityFooter: isNewest ? activityFooter : nil,
                liveSession: isNewest ? liveSession : nil,
                onTool: onTool,
                onSubagent: onSubagent,
                onSubagentResult: onSubagentResult,
                onCompaction: onCompaction,
                downloadFile: downloadFile
            )
            .equatable()
            .id(turn.id)
            #if DEBUG
            .onAppear {
                TranscriptPerformance.shared.markFirstRows()
            }
            #endif
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

struct TranscriptTurnView: View, Equatable {
    let sessionID: String
    let turn: Turn
    let subagents: [Subagent]
    let showsWorkedFooter: Bool
    let activityFooter: CCKit.ActivityFooter?
    let liveSession: Session?
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onSubagentResult: (SubagentResultEntry, Subagent?) -> Void
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
        onSubagentResult: @escaping (SubagentResultEntry, Subagent?) -> Void = { _, _ in },
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
        self.onSubagentResult = onSubagentResult
        self.onCompaction = onCompaction
        self.downloadFile = downloadFile
    }

    nonisolated static func == (lhs: TranscriptTurnView, rhs: TranscriptTurnView) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.turn == rhs.turn
            && lhs.subagents == rhs.subagents
            && lhs.showsWorkedFooter == rhs.showsWorkedFooter
            && lhs.activityFooter == rhs.activityFooter
            && lhs.liveSession == rhs.liveSession
    }

    private var promptDownload: (@MainActor @Sendable (String) async throws -> URL)? {
        guard let downloadFile else { return nil }
        let sessionID = self.sessionID
        return { name in
            try await downloadFile(FileEntry(sessionId: sessionID, name: name))
        }
    }

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.turnRow)
        #endif
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
                    onSubagentResult: onSubagentResult,
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
    let onSubagentResult: (SubagentResultEntry, Subagent?) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?

    init(
        item: TurnItem,
        subagents: [Subagent] = [],
        onTool: @escaping (ToolEntry) -> Void,
        onSubagent: @escaping (SubagentEntry) -> Void,
        onSubagentResult: @escaping (SubagentResultEntry, Subagent?) -> Void = { _, _ in },
        onCompaction: @escaping (CompactionEntry) -> Void = { _ in },
        downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil
    ) {
        self.item = item
        self.subagents = subagents
        self.onTool = onTool
        self.onSubagent = onSubagent
        self.onSubagentResult = onSubagentResult
        self.onCompaction = onCompaction
        self.downloadFile = downloadFile
    }

    private func matchingSubagent(for entry: SubagentResultEntry) -> Subagent? {
        if let toolUseId = entry.toolUseId, !toolUseId.isEmpty,
           let match = subagents.first(where: { $0.toolUseId == toolUseId }) {
            return match
        }
        if let agentId = entry.agentId, !agentId.isEmpty {
            return subagents.first(where: { $0.agentId == agentId })
        }
        return nil
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
            SubagentResultView(
                entry: entry,
                subagent: matchingSubagent(for: entry),
                onOpen: { onSubagentResult(entry, matchingSubagent(for: entry)) }
            )
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
