import CCKit
import SwiftUI

private struct TranscriptScrollMetrics: Equatable {
    let contentFitsViewport: Bool
    let contentHeight: CGFloat
    let containerHeight: CGFloat
}

struct SessionTranscriptView: View {
    let sessionID: String
    let turns: [Turn]
    let rows: [TranscriptRow]
    let subagents: [Subagent]
    let showsComposer: Bool
    let showsWorkedFooter: Bool
    let bottomStackConfiguration: BottomStackConfiguration?
    let queuedNotes: [QueuedNote]
    let activityFooter: CCKit.ActivityFooter?
    let liveSession: Session?
    let sessionState: SessionState?
    let onRetryNote: (String) -> Void
    let onEditNote: (String) -> Void
    let onDeleteNote: (String) -> Void
    let onSendAgain: (String) -> Void
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
    @State private var pagingAnchorEntryID: String?
    @State private var pagingRestoreTask: Task<Void, Never>?
    @State private var newestScrollTask: Task<Void, Never>?
    @State private var pagingError: String?
    @State private var transcriptHeight: CGFloat = 0
    @State private var userHasScrolled = false
    @State private var contentFitsViewport = false
    @State private var isPinnedToBottom = true
    @State private var userIsScrolling = false
    @State private var subagentIndex: SubagentIndex

    init(
        sessionID: String = "",
        turns: [Turn],
        rows: [TranscriptRow]? = nil,
        showsComposer: Bool = true,
        showsWorkedFooter: Bool = true,
        bottomStackConfiguration: BottomStackConfiguration? = nil,
        queuedNotes: [QueuedNote] = [],
        activityFooter: CCKit.ActivityFooter? = nil,
        liveSession: Session? = nil,
        sessionState: SessionState? = nil,
        onRetryNote: @escaping (String) -> Void = { _ in },
        onEditNote: @escaping (String) -> Void = { _ in },
        onDeleteNote: @escaping (String) -> Void = { _ in },
        onSendAgain: @escaping (String) -> Void = { _ in },
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
        self.rows = rows ?? CCKit.transcriptRows(for: turns)
        self.showsComposer = showsComposer
        self.showsWorkedFooter = showsWorkedFooter
        self.bottomStackConfiguration = bottomStackConfiguration
        self.queuedNotes = queuedNotes
        self.activityFooter = activityFooter
        self.liveSession = liveSession
        self.sessionState = sessionState ?? liveSession?.state
        self.onRetryNote = onRetryNote
        self.onEditNote = onEditNote
        self.onDeleteNote = onDeleteNote
        self.onSendAgain = onSendAgain
        self.subagents = subagents
        _subagentIndex = State(initialValue: SubagentIndex(subagents))
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .scrollTargetLayout()
                #if DEBUG || CC_PERF
                .onAppear { TranscriptPerformance.shared.markFirstRows() }
                #endif
            }
            .defaultScrollAnchor(showsComposer ? .bottom : scrollAnchor, for: .initialOffset)
            .defaultScrollAnchor(showsComposer ? .bottom : scrollAnchor, for: .alignment)
            .defaultScrollAnchor(showsComposer ? .bottom : scrollAnchor, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("transcript-scroll")
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
            // Rows present at creation do not trigger the change handlers, so estimated heights can leave the viewport past every built row.
            .onAppear {
                scrollToNewest(using: proxy)
            }
            .onChange(of: queuedNotes) { _, _ in
                isPinnedToBottom = true
                scrollToNewest(using: proxy)
            }
            .background(.ccBackground)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
                TranscriptScrollMetrics(
                    contentFitsViewport: geometry.contentSize.height <= geometry.visibleRect.height,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.visibleRect.height
                )
            } action: { oldMetrics, metrics in
                contentFitsViewport = metrics.contentFitsViewport
                if metrics.contentFitsViewport {
                    loadEarlierIfNeeded()
                }
                guard isPinnedToBottom,
                      !userIsScrolling,
                      oldMetrics.contentHeight != metrics.contentHeight
                          || oldMetrics.containerHeight != metrics.containerHeight else { return }
                scrollToNewest(using: proxy)
            }
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .interacting:
                    newestScrollTask?.cancel()
                    userIsScrolling = true
                    userHasScrolled = true
                    if pagingRowIsVisible {
                        loadEarlierIfNeeded()
                    }
                    cancelPagingRestore()
                case .decelerating:
                    userIsScrolling = true
                case .idle:
                    guard userIsScrolling else { return }
                    userIsScrolling = false
                    isPinnedToBottom = isAtBottom(in: context.geometry)
                default:
                    break
                }
            }
            .onChange(of: subagents) { _, newSubagents in
                subagentIndex = SubagentIndex(newSubagents)
            }
            .onChange(of: sessionID) { _, _ in
                subagentIndex = SubagentIndex(subagents)
                userHasScrolled = false
                contentFitsViewport = false
                isPinnedToBottom = true
                userIsScrolling = false
                pagingAnchorEntryID = nil
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom, turns.last != nil {
                    Button {
                        isPinnedToBottom = true
                        scrollToNewest(using: proxy)
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
            #if DEBUG || CC_PERF
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

    private func isAtBottom(in geometry: ScrollGeometry) -> Bool {
        let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
        return visibleBottom >= geometry.contentSize.height - 36
    }

    private func scrollToNewest(using proxy: ScrollViewProxy) {
        #if CC_PERF
        PerfCounters.shared.hit(.scrollToBottom)
        #endif
        guard isPinnedToBottom, !userIsScrolling else { return }
        newestScrollTask?.cancel()
        newestScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, isPinnedToBottom, !userIsScrolling else { return }
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    private var displayRows: [TranscriptRow] {
        var result = rows
        if !showsWorkedFooter {
            result.removeAll { row in
                if case .workedFooter = row.kind { return true }
                return false
            }
        }
        if let activityFooter, let turnID = turns.last?.id {
            result.append(TranscriptRow(id: "\(turnID)-activity", turnID: turnID, kind: .liveActivityFooter(activityFooter)))
        }
        return result
    }

    @ViewBuilder
    private var transcriptRows: some View {
        ForEach(displayRows) { row in
            TranscriptRowView(
                sessionID: sessionID,
                row: row,
                subagents: rowSubagents(for: row),
                liveSession: rowUsesLiveSession(row) ? liveSession : nil,
                onTool: onTool,
                onSubagent: onSubagent,
                onSubagentResult: onSubagentResult,
                onCompaction: onCompaction,
                downloadFile: downloadFile
            )
            .equatable()
            .id(row.id)
            #if DEBUG || CC_PERF
            .onAppear {
                TranscriptPerformance.shared.markFirstRows()
            }
            #endif
        }

        ForEach(queuedNotes) { note in
            PendingPromptView(
                sessionID: sessionID,
                note: note,
                sessionState: sessionState,
                downloadFile: downloadFile,
                onRetry: onRetryNote,
                onEdit: onEditNote,
                onDelete: onDeleteNote,
                onSendAgain: onSendAgain
            )
        }

        Color.clear
            .frame(height: 1)
            .id("transcript-bottom")
            .accessibilityHidden(true)
    }

    private func rowUsesLiveSession(_ row: TranscriptRow) -> Bool {
        guard case .liveActivityFooter = row.kind else { return false }
        return true
    }

    private func rowSubagents(for row: TranscriptRow) -> [Subagent] {
        guard case .item(let item) = row.kind else { return [] }
        return subagentIndex.matchingSubagents(for: item)
    }
}

private struct PendingPromptView: View {
    let sessionID: String
    let note: QueuedNote
    let sessionState: SessionState?
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    let onRetry: (String) -> Void
    let onEdit: (String) -> Void
    let onDelete: (String) -> Void
    let onSendAgain: (String) -> Void
    @State private var confirmationPresented = false

    private var promptDownload: (@MainActor @Sendable (String) async throws -> URL)? {
        guard let downloadFile else { return nil }
        let sessionID = self.sessionID
        return { name in
            try await downloadFile(FileEntry(sessionId: sessionID, name: name))
        }
    }

    private var failureMessage: String? {
        guard case .failed(let message) = note.state else { return nil }
        return message
    }

    private var isFailed: Bool {
        if case .failed = note.state { return true }
        return false
    }

    private var statusText: String {
        switch note.state {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .queued: "Queued"
        case .failed: "Not sent · Tap to retry"
        }
    }

    private func statusColor(needsAttention: Bool) -> Color {
        if needsAttention { return .ccAmber }
        if failureMessage != nil { return .ccRed }
        return .ccSecondary
    }

    @ViewBuilder
    var body: some View {
        if note.state == .sent {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                content(now: context.date)
            }
        } else {
            content(now: .now)
        }
    }

    private func content(now: Date) -> some View {
        let needsAttention = noteNeedsAttention(note: note, sessionState: sessionState, now: now)
        let actionable = needsAttention || isFailed
        let text = needsAttention ? "Sent · not received yet" : statusText
        return VStack(alignment: .trailing, spacing: 4) {
            PromptBubble(
                prompt: PromptEntry(text: note.text, attachments: note.attachments),
                sessionID: sessionID,
                downloadFile: promptDownload,
                attachmentThumbnails: note.attachmentThumbnails,
                bubbleAccessibilityIdentifier: "pending-prompt-bubble"
            )
            .opacity(isFailed ? 1 : 0.55)

            HStack(spacing: 4) {
                if note.state == .sending {
                    ProgressView()
                        .controlSize(.mini)
                }
                if isFailed {
                    Image(systemName: "exclamationmark.circle")
                }
                Text(text)
            }
            .font(.caption)
            .foregroundStyle(statusColor(needsAttention: needsAttention))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pending-prompt-status")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .gesture(
            TapGesture().onEnded { presentConfirmationIfNeeded(actionable: actionable) },
            including: actionable ? .all : .subviews
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pending-prompt")
        .accessibilityLabel("\(note.text), \(text)")
        .accessibilityAddTraits(actionable ? .isButton : [])
        .accessibilityHint(actionable ? "Shows options for this message" : "")
        .accessibilityAction { presentConfirmationIfNeeded(actionable: actionable) }
        .confirmationDialog(
            failureMessage ?? "Message not received",
            isPresented: $confirmationPresented,
            titleVisibility: .visible
        ) {
            if needsAttention {
                Button("Send again") { onSendAgain(note.id) }
                Button("Dismiss") { onDelete(note.id) }
            } else if failureMessage != nil {
                Button("Retry") { onRetry(note.id) }
                Button("Edit message") { onEdit(note.id) }
                Button("Delete", role: .destructive) { onDelete(note.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if needsAttention {
                Text("The session hasn't shown this message yet. Sending again may deliver it twice.")
            }
        }
    }

    private func presentConfirmationIfNeeded(actionable: Bool) {
        guard actionable else { return }
        confirmationPresented = true
    }
}

struct TranscriptRowView: View, Equatable {
    let sessionID: String
    let row: TranscriptRow
    let subagents: [Subagent]
    let liveSession: Session?
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onSubagentResult: (SubagentResultEntry, Subagent?) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?

    nonisolated static func == (lhs: TranscriptRowView, rhs: TranscriptRowView) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.row == rhs.row
            && lhs.subagents == rhs.subagents
            && lhs.liveSession == rhs.liveSession
    }

    private var promptDownload: (@MainActor @Sendable (String) async throws -> URL)? {
        guard let downloadFile else { return nil }
        let sessionID = self.sessionID
        return { name in
            try await downloadFile(FileEntry(sessionId: sessionID, name: name))
        }
    }

    @ViewBuilder
    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.transcriptRow)
        #endif
        Group {
            switch row.kind {
            case .prompt(let prompt):
                PromptBubble(prompt: prompt, sessionID: sessionID, downloadFile: promptDownload)
            case .item(let item):
                TurnItemView(
                    item: item,
                    subagents: subagents,
                    onTool: onTool,
                    onSubagent: onSubagent,
                    onSubagentResult: onSubagentResult,
                    onCompaction: onCompaction,
                    downloadFile: downloadFile
                )
            case .workedFooter(let durationMs):
                WorkedFooter(durationMs: durationMs)
            case .liveActivityFooter(let footer):
                LiveActivityFooterView(footer: footer, session: liveSession)
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
