import CCKit
import SwiftUI
import UIKit

struct SessionTranscriptView: View {
    let sessionID: String
    let turns: [Turn]
    let rows: [TranscriptRow]
    let subagents: [Subagent]
    let showsComposer: Bool
    let showsWorkedFooter: Bool
    let bottomStackConfiguration: BottomStackConfiguration?
    let queuedNotes: [QueuedNote]
    let noteAliases: [String: String]
    let activityFooter: CCKit.ActivityFooter?
    let liveSession: Session?
    let sessionState: SessionState?
    let onRetryNote: (String) -> Void
    let onEditNote: (String) -> Void
    let onDeleteNote: (String) -> Void
    let onCopyNote: (String) -> Void
    let onSendAgain: (String) -> Void
    let hasMoreEarlier: Bool
    let loadEarlier: (() async throws -> Void)?
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onSubagentResult: (SubagentResultEntry, Subagent?) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pagingError: String?
    @State private var availableHeight: CGFloat = 0
    @State private var isPinnedToBottom = true
    @State private var jumpToLatestRequest = 0
    @State private var expansion: TranscriptExpansionStore

    init(
        sessionID: String = "",
        turns: [Turn],
        rows: [TranscriptRow]? = nil,
        showsComposer: Bool = true,
        showsWorkedFooter: Bool = true,
        bottomStackConfiguration: BottomStackConfiguration? = nil,
        queuedNotes: [QueuedNote] = [],
        noteAliases: [String: String] = [:],
        activityFooter: CCKit.ActivityFooter? = nil,
        liveSession: Session? = nil,
        sessionState: SessionState? = nil,
        onRetryNote: @escaping (String) -> Void = { _ in },
        onEditNote: @escaping (String) -> Void = { _ in },
        onDeleteNote: @escaping (String) -> Void = { _ in },
        onCopyNote: @escaping (String) -> Void = { _ in },
        onSendAgain: @escaping (String) -> Void = { _ in },
        subagents: [Subagent] = [],
        hasMoreEarlier: Bool = false,
        loadEarlier: (() async throws -> Void)? = nil,
        onTool: @escaping (ToolEntry) -> Void = { _ in },
        onSubagent: @escaping (SubagentEntry) -> Void = { _ in },
        onSubagentResult: @escaping (SubagentResultEntry, Subagent?) -> Void = { _, _ in },
        onCompaction: @escaping (CompactionEntry) -> Void = { _ in },
        downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil
    ) {
        self.sessionID = sessionID
        self.turns = turns
        self.rows = rows ?? CCKit.transcriptRows(for: turns)
        self.showsComposer = showsComposer
        self.showsWorkedFooter = showsWorkedFooter
        self.bottomStackConfiguration = bottomStackConfiguration
        self.queuedNotes = queuedNotes
        self.noteAliases = noteAliases
        self.activityFooter = activityFooter
        self.liveSession = liveSession
        self.sessionState = sessionState ?? liveSession?.state
        self.onRetryNote = onRetryNote
        self.onEditNote = onEditNote
        self.onDeleteNote = onDeleteNote
        self.onCopyNote = onCopyNote
        self.onSendAgain = onSendAgain
        self.subagents = subagents
        self.hasMoreEarlier = hasMoreEarlier
        self.loadEarlier = loadEarlier
        self.onTool = onTool
        self.onSubagent = onSubagent
        self.onSubagentResult = onSubagentResult
        self.onCompaction = onCompaction
        self.downloadFile = downloadFile
        _expansion = State(initialValue: TranscriptExpansionStore())
    }

    var body: some View {
#if CC_PERF
        let _ = PerfCounters.shared.hit(.transcriptList)
#endif
        TranscriptCollectionRepresentable(
            sessionID: sessionID,
            rows: displayRows,
            queuedNotes: queuedNotes,
            transcriptExpansion: expansion,
            sessionState: sessionState,
            subagents: subagents,
            liveSession: liveSession,
            hasMoreEarlier: hasMoreEarlier,
            loadEarlier: loadEarlier,
            onPagingError: { pagingError = $0 },
            onRetryNote: onRetryNote,
            onEditNote: onEditNote,
            onDeleteNote: onDeleteNote,
            onCopyNote: onCopyNote,
            onSendAgain: onSendAgain,
            onTool: onTool,
            onSubagent: onSubagent,
            onSubagentResult: onSubagentResult,
            onCompaction: onCompaction,
            downloadFile: downloadFile,
            readableContentMaxWidth: readableContentMaxWidth,
            reduceMotion: reduceMotion,
            noteAliases: noteAliases,
            isPinnedToBottom: $isPinnedToBottom,
            jumpToLatestRequest: $jumpToLatestRequest
        )
        .overlay(alignment: .bottomTrailing) {
            if !isPinnedToBottom, turns.last != nil {
                Button {
                    isPinnedToBottom = true
                    jumpToLatestRequest += 1
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
                BottomStackView(configuration: configuration.withAvailableHeight(availableHeight))
                    .frame(maxWidth: readableContentMaxWidth)
                    .frame(maxWidth: .infinity)
                    #if DEBUG
                    .background(MotionTraceProbe(id: "composer"))
                    #endif
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
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { _, height in
            guard abs(height - availableHeight) >= 1 else { return }
            availableHeight = height
        }
        .background(.ccBackground)
        .environment(\.transcriptExpansion, expansion)
    }

    private var readableContentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? CCMetrics.readableContentWidth : .infinity
    }

    private var displayRows: [TranscriptRow] {
        var result = rows.filter { row in
            if case .status = row.kind { return false }
            return true
        }
        result.append(statusRow)
        return result
    }

    private var statusRow: TranscriptRow {
        let status: TranscriptStatus
        if let activityFooter {
            status = .activity(activityFooter)
        } else if showsWorkedFooter, let turn = turns.last, turn.hasWorkedFooter {
            status = .worked(durationMs: turn.durationMs)
        } else {
            status = .none
        }
        return TranscriptRow(
            id: "status",
            turnID: turns.last?.id ?? sessionID,
            kind: .status(status)
        )
    }
}

struct PendingPromptView: View {
    let sessionID: String
    let note: QueuedNote
    let sessionState: SessionState?
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    let onRetry: (String) -> Void
    let onEdit: (String) -> Void
    let onDelete: (String) -> Void
    let onCopy: (String) -> Void
    let onSendAgain: (String) -> Void
    @State private var confirmationPresented = false
    @State private var nonWorkingSince: Date?
    @Environment(\.isTranscriptSizingPass) private var isTranscriptSizingPass

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
        TimelineView(.periodic(from: .now, by: 5)) { context in
            content(now: context.date)
        }
        .onAppear {
            guard !isTranscriptSizingPass else { return }
            if sessionState != .working { nonWorkingSince = .now }
        }
        .onChange(of: sessionState) { oldState, newState in
            guard !isTranscriptSizingPass else { return }
            if newState == .working {
                nonWorkingSince = nil
            } else if oldState == .working {
                nonWorkingSince = .now
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let needsAttention = noteNeedsAttention(
            note: note,
            sessionState: sessionState,
            nonWorkingSince: nonWorkingSince,
            now: now
        )
        let isPendingActionable = note.state == .sent || note.state == .queued
        let actionable = needsAttention || isPendingActionable || isFailed
        let text = needsAttention ? "Sent · not received yet" : statusText
        let view = VStack(alignment: .trailing, spacing: 4) {
            PromptBubble(
                prompt: PromptEntry(text: note.text, attachments: note.attachments),
                sessionID: sessionID,
                downloadFile: promptDownload,
                attachmentThumbnails: note.attachmentThumbnails,
                bubbleAccessibilityIdentifier: "pending-prompt-bubble"
            )

            if isFailed || needsAttention {
                HStack(spacing: 4) {
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
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .gesture(
            TapGesture().onEnded { presentConfirmationIfNeeded(actionable: actionable) },
            including: actionable ? .all : .subviews
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pending-prompt")
        .accessibilityLabel(note.text)
        .accessibilityValue(text)
        .accessibilityAddTraits(actionable ? .isButton : [])
        .accessibilityHint(actionable ? "Shows options for this message" : "")
        .accessibilityAction { presentConfirmationIfNeeded(actionable: actionable) }
        .confirmationDialog(
            failureMessage ?? (needsAttention ? "Message not received" : "Message pending"),
            isPresented: $confirmationPresented,
            titleVisibility: .visible
        ) {
            if needsAttention {
                Button("Copy") { onCopy(note.id) }
                Button("Send again") { onSendAgain(note.id) }
                Button("Edit message") { onEdit(note.id) }
                Button("Dismiss") { onDelete(note.id) }
            } else if failureMessage != nil {
                Button("Retry") { onRetry(note.id) }
                Button("Edit message") { onEdit(note.id) }
                Button("Delete", role: .destructive) { onDelete(note.id) }
            } else if isPendingActionable {
                Button("Copy") { onCopy(note.id) }
                Button("Edit message") { onEdit(note.id) }
                Button("Dismiss") { onDelete(note.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if needsAttention {
                Text("The session hasn't shown this message yet. Sending again may deliver it twice. Edit and Dismiss only change this screen.")
            } else if isPendingActionable {
                Text("Edit and Dismiss only change this screen. The message may already be with Claude.")
            }
        }

        view.contextMenu {
            if note.state != .sending {
                contextMenuContent(needsAttention: needsAttention)
            }
        }
    }

    @ViewBuilder
    private func contextMenuContent(needsAttention: Bool) -> some View {
        if needsAttention {
            Button { onCopy(note.id) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button { onSendAgain(note.id) } label: {
                Label("Send again", systemImage: "arrow.clockwise")
            }
            Button { onEdit(note.id) } label: {
                Label("Edit message", systemImage: "pencil")
            }
            Button { onDelete(note.id) } label: {
                Label("Dismiss", systemImage: "xmark")
            }
        } else if isFailed {
            Button { onRetry(note.id) } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            Button { onEdit(note.id) } label: {
                Label("Edit message", systemImage: "pencil")
            }
            Button(role: .destructive) { onDelete(note.id) } label: {
                Label("Delete", systemImage: "trash")
            }
        } else {
            Button { onCopy(note.id) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button { onEdit(note.id) } label: {
                Label("Edit message", systemImage: "pencil")
            }
            Button { onDelete(note.id) } label: {
                Label("Dismiss", systemImage: "xmark")
            }
        }
    }

    private func presentConfirmationIfNeeded(actionable: Bool) {
        guard actionable else { return }
        confirmationPresented = true
    }
}

struct TranscriptStatusView: View {
    let status: TranscriptStatus
    let session: Session?

    @ViewBuilder
    var body: some View {
        switch status {
        case .activity(let footer):
            LiveActivityFooterView(footer: footer, session: session)
        case .worked(let durationMs):
            WorkedFooter(durationMs: durationMs)
        case .none:
            Color.clear
                .frame(height: 0)
                .accessibilityHidden(true)
        }
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
    @Environment(\.isTranscriptSizingPass) private var isTranscriptSizingPass

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
        let _ = isTranscriptSizingPass ? 0 : PerfCounters.shared.hit(.transcriptRow)
        #endif
        Group {
            switch row.kind {
            case .prompt(let prompt):
                PromptBubble(prompt: prompt, sessionID: sessionID, downloadFile: promptDownload, showsChatSender: liveSession?.writable == false)
            case .item(let item):
                TurnItemView(
                    item: item,
                    expansionKey: "\(sessionID):\(row.id)",
                    subagents: subagents,
                    onTool: onTool,
                    onSubagent: onSubagent,
                    onSubagentResult: onSubagentResult,
                    onCompaction: onCompaction,
                    downloadFile: downloadFile
                )
            case .status(let status):
                TranscriptStatusView(status: status, session: liveSession)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TurnItemView: View {
    let item: TurnItem
    let expansionKey: String
    let subagents: [Subagent]
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onSubagentResult: (SubagentResultEntry, Subagent?) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?

    init(
        item: TurnItem,
        expansionKey: String,
        subagents: [Subagent] = [],
        onTool: @escaping (ToolEntry) -> Void,
        onSubagent: @escaping (SubagentEntry) -> Void,
        onSubagentResult: @escaping (SubagentResultEntry, Subagent?) -> Void = { _, _ in },
        onCompaction: @escaping (CompactionEntry) -> Void = { _ in },
        downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)? = nil
    ) {
        self.item = item
        self.expansionKey = expansionKey
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
            ToolRunCard(
                run: run,
                expansionKey: expansionKey,
                onTool: onTool
            )
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
            FileEntryView(entry: entry, download: downloadFile, heightKey: expansionKey)
        case .other:
            EmptyView()
        }
    }
}
