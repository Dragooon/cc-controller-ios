import CCKit
import SwiftUI
import UIKit

#if DEBUG
import OSLog
#endif

private struct TranscriptScrollMetrics: Equatable {
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    let overshoot: Bool
    let overshootGeometry: ScrollGuardGeometry?
}

private struct ScrollBlankOccurrence {
    let kind: ScrollBlankKind
    let startedAt: Date
    var corrections: Int
    var latestGeometry: ScrollGuardGeometry
}

@MainActor
private final class TranscriptScrollState {
    var builtRowIndices: [String: Int] = [:]
    var highestBuiltRowIndex = -1
    var lastBuiltRowID: String?
    var lastScrollGeometry: ScrollGuardGeometry?
    var latestUIKitMetrics: UIKitScrollMetrics?
    let bridgeHandle = TranscriptScrollBridgeHandle()
    var blankCandidate: ScrollBlankKind?
    var blankCandidateStartedAt: Date?
    var blankCheckTask: Task<Void, Never>?
    var blankOccurrence: ScrollBlankOccurrence?
    var sentinelCheckTask: Task<Void, Never>?
    var scrollPhaseIsIdle = true
    var recorder: ScrollDiagnosticsRecorder?
    var onBuiltRowsEmpty: (() -> Void)?
    var onDiagnosticWritten: ((ScrollBlankKind, Bool) -> Void)?
    private var displayRowIDs: [String] = []
    private var displayRowIndices: [String: Int] = [:]
    private var queuedNoteIDs: [String] = []
    private var queuedNoteIndices: [String: Int] = [:]
    private var sessionID: String

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func prepare(
        sessionID: String,
        onDiagnosticWritten: @escaping (ScrollBlankKind, Bool) -> Void
    ) {
        self.onDiagnosticWritten = onDiagnosticWritten
        ensureRecorder(sessionID: sessionID)
    }

    func ensureRecorder(sessionID: String? = nil) -> ScrollDiagnosticsRecorder {
        if let sessionID {
            self.sessionID = sessionID
        }
        if let recorder { return recorder }
        let recorder = ScrollDiagnosticsRecorder(sessionID: self.sessionID)
        self.recorder = recorder
        return recorder
    }

    func recordEvent(name: String, oldValue: Double? = nil, newValue: Double? = nil) {
        ensureRecorder().recordEvent(name: name, oldValue: oldValue, newValue: newValue)
    }

    func sessionChanged(to sessionID: String) {
        self.sessionID = sessionID
        ensureRecorder().sessionChanged(to: sessionID)
        cancelBlankCheck()
        blankCandidate = nil
        blankCandidateStartedAt = nil
        blankOccurrence = nil
        builtRowIndices = [:]
        highestBuiltRowIndex = -1
        lastBuiltRowID = nil
        lastScrollGeometry = nil
        latestUIKitMetrics = nil
    }

    func cancelBlankCheck() {
        blankCheckTask?.cancel()
        blankCheckTask = nil
    }

    func cancelSentinelCheck() {
        sentinelCheckTask?.cancel()
        sentinelCheckTask = nil
    }

    func updateRowIndices(displayRows: [TranscriptRow], queuedNotes: [QueuedNote]) {
        let displayRowsChanged = displayRowIDs.count != displayRows.count
            || zip(displayRowIDs, displayRows).contains { $0 != $1.id }
        if displayRowsChanged {
            displayRowIDs = displayRows.map(\.id)
            displayRowIndices = Dictionary(uniqueKeysWithValues: displayRowIDs.enumerated().map { ($1, $0) })
        }
        let queuedNotesChanged = queuedNoteIDs.count != queuedNotes.count
            || zip(queuedNoteIDs, queuedNotes).contains { $0 != $1.id }
        if queuedNotesChanged {
            queuedNoteIDs = queuedNotes.map(\.id)
            queuedNoteIndices = Dictionary(uniqueKeysWithValues: queuedNoteIDs.enumerated().map { ($1, $0) })
        }
    }

    func displayRowIndex(for id: String) -> Int? {
        displayRowIndices[id]
    }

    func queuedNoteIndex(for id: String) -> Int? {
        queuedNoteIndices[id]
    }

    func builtRowDidAppear(id: String, index: Int) {
        builtRowIndices[id] = index
        guard index > highestBuiltRowIndex else { return }
        highestBuiltRowIndex = index
        lastBuiltRowID = id
    }

    func builtRowDidDisappear(id: String, displayRowCount: Int, queuedNoteCount: Int) {
        builtRowIndices.removeValue(forKey: id)
        guard builtRowIndices.isEmpty, displayRowCount > 0 || queuedNoteCount > 0 else { return }
        onBuiltRowsEmpty?()
    }

    func recordOccurrence(
        kind: ScrollBlankKind,
        geometry: ScrollGuardGeometry,
        rowsCount: Int,
        notesCount: Int,
        isPinnedToBottom: Bool,
        userHasScrolled: Bool,
        corrections: Int,
        recovered: Bool,
        msToRecover: Int
    ) {
        let callback = onDiagnosticWritten
        ensureRecorder().record(
            kind: kind,
            geometry: geometry,
            rowsCount: rowsCount,
            notesCount: notesCount,
            isPinnedToBottom: isPinnedToBottom,
            userHasScrolled: userHasScrolled,
            corrections: corrections,
            recovered: recovered,
            msToRecover: msToRecover
        ) { written in
            guard written else { return }
            callback?(kind, recovered)
        }
    }
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
    let onCopyNote: (String) -> Void
    let onSendAgain: (String) -> Void
    let hasMoreEarlier: Bool
    let loadEarlier: (() async throws -> Void)?
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onSubagentResult: (SubagentResultEntry, Subagent?) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    let scrollAnchor: UnitPoint
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isLoadingEarlier = false
    @State private var didTriggerPaging = false
    @State private var pagingRowIsVisible = false
    @State private var pagingAnchorEntryID: String?
    @State private var pagingRestoreTask: Task<Void, Never>?
    @State private var newestScrollTask: Task<Void, Never>?
    @State private var stackGeneration = 0
    @State private var rebuildScrollTask: Task<Void, Never>?
    @State private var pagingError: String?
    @State private var availableHeight: CGFloat = 0
    @State private var userHasScrolled = false
    @State private var contentFitsViewport = false
    @State private var isPinnedToBottom = true
    @State private var userIsScrolling = false
    @State private var rowsMounted = false
    @State private var transcriptIsVisible = false
    @State private var transcriptAppearDate: Date?
    @State private var scrollState: TranscriptScrollState
    @State private var diagnosticWrittenCount = 0
    @State private var diagnosticStatus = "count=0"
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
        onCopyNote: @escaping (String) -> Void = { _ in },
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
        self.onCopyNote = onCopyNote
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
        _scrollState = State(initialValue: TranscriptScrollState(sessionID: sessionID))
    }

    var body: some View {
#if CC_PERF
        let _ = PerfCounters.shared.hit(.transcriptList)
#endif
        ScrollViewReader { proxy in
            transcriptScrollView(using: proxy)
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom, turns.last != nil {
                    Button {
                        isPinnedToBottom = true
                        _ = TranscriptLifecycleDiagnostics.shared.ingest(
                            .pinned(sessionID: sessionID, pinned: true)
                        )
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
                    BottomStackView(configuration: configuration.withAvailableHeight(availableHeight))
                        .frame(maxWidth: readableContentMaxWidth)
                        .frame(maxWidth: .infinity)
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
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                Text(diagnosticStatus)
                    .accessibilityIdentifier("scroll-diagnostics-status")
                    .accessibilityLabel(diagnosticStatus)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            }
            #endif
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { _, height in
            guard abs(height - availableHeight) >= 1 else { return }
            availableHeight = height
        }
    }

    private func transcriptStack(using proxy: ScrollViewProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            pagingRow
            transcriptRows
        }
        .id(stackGeneration)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .frame(maxWidth: readableContentMaxWidth)
        .frame(maxWidth: .infinity)
        .scrollTargetLayout()
        .background {
            transcriptScrollBridge(using: proxy)
        }
        #if DEBUG || CC_PERF
        .onAppear { TranscriptPerformance.shared.markFirstRows() }
        #endif
    }

    private func transcriptScrollBridge(using proxy: ScrollViewProxy) -> some View {
        TranscriptScrollBridge(handle: scrollState.bridgeHandle) { metrics in
            handleUIKitScrollMetrics(metrics, using: proxy)
        }
    }

    private func transcriptScrollView(using proxy: ScrollViewProxy) -> some View {
        let scrollView = ScrollView {
            if rowsMounted {
                transcriptStack(using: proxy)
            } else {
                Color.clear
                    .frame(height: 1)
                    .id("transcript-bottom")
                    .accessibilityHidden(true)
                    .background {
                        transcriptScrollBridge(using: proxy)
                    }
            }
        }
        let configuredScrollView = scrollView
            .defaultScrollAnchor(showsComposer ? .bottom : scrollAnchor, for: .initialOffset)
            .defaultScrollAnchor(showsComposer ? .bottom : scrollAnchor, for: .alignment)
            .defaultScrollAnchor(showsComposer ? .bottom : scrollAnchor, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("transcript-scroll")
        let withPaging = configuredScrollView
            .onChange(of: turns.first?.id) { _, newID in
                handleFirstTurnChange(newID: newID, using: proxy)
            }
        let withRows = withPaging
            .onChange(of: turns.last) { _, _ in
                scrollToNewest(using: proxy)
            }
            // Rows present at creation do not trigger the change handlers, so estimated heights can leave the viewport past every built row.
            .background {
                TranscriptMountReader { source in
                    mountRows(source: source, using: proxy)
                }
            }
            .onAppear {
                transcriptIsVisible = true
                transcriptAppearDate = Date()
                rowsMounted = false
                contentFitsViewport = false
                scrollState.latestUIKitMetrics = nil
                handleTranscriptAppear(using: proxy)
                recordLifecycleEvent(
                    name: "transcript-appear",
                    sessionID: sessionID,
                    input: .transcriptAppear(sessionID: sessionID),
                    recorder: scrollState.recorder,
                    geometry: scrollState.lastScrollGeometry,
                    rowsCount: displayRows.count,
                    notesCount: queuedNotes.count,
                    isPinnedToBottom: isPinnedToBottom,
                    userHasScrolled: userHasScrolled
                )
                _ = TranscriptLifecycleDiagnostics.shared.ingest(
                    .rowsMounted(sessionID: sessionID, mounted: false)
                )
                _ = TranscriptLifecycleDiagnostics.shared.ingest(
                    .pinned(sessionID: sessionID, pinned: isPinnedToBottom)
                )
                _ = TranscriptLifecycleDiagnostics.shared.ingest(
                    .scrollIdle(sessionID: sessionID, idle: true)
                )
            }
            .task {
                do {
                    try await Task.sleep(for: .milliseconds(700))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                mountRows(source: .cap, using: proxy)
            }
            .onDisappear {
                recordLifecycleEvent(
                    name: "transcript-disappear",
                    sessionID: sessionID,
                    input: .transcriptDisappear(sessionID: sessionID),
                    recorder: scrollState.recorder,
                    geometry: scrollState.lastScrollGeometry,
                    rowsCount: displayRows.count,
                    notesCount: queuedNotes.count,
                    isPinnedToBottom: isPinnedToBottom,
                    userHasScrolled: userHasScrolled
                )
                _ = TranscriptLifecycleDiagnostics.shared.ingest(
                    .rowsMounted(sessionID: sessionID, mounted: false)
                )
                transcriptIsVisible = false
                rowsMounted = false
                contentFitsViewport = false
                scrollState.latestUIKitMetrics = nil
                transcriptAppearDate = nil
                scrollState.cancelBlankCheck()
                scrollState.cancelSentinelCheck()
                rebuildScrollTask?.cancel()
                rebuildScrollTask = nil
                scrollState.onBuiltRowsEmpty = nil
            }
            .onChange(of: displayRows.count) { oldCount, newCount in
                scrollState.recordEvent(name: "rows", oldValue: Double(oldCount), newValue: Double(newCount))
            }
            .onChange(of: queuedNotes) { _, _ in
                handleQueuedNotesChange(using: proxy)
            }
            .onChange(of: queuedNotes.count) { oldCount, newCount in
                scrollState.recordEvent(name: "notes", oldValue: Double(oldCount), newValue: Double(newCount))
            }
        let withScrollEvents = withRows
            .background(.ccBackground)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
                scrollState.lastScrollGeometry = makeScrollGuardGeometry(from: geometry)
                let overshoot = ScrollBlankCondition.isOvershoot(
                    contentHeight: geometry.contentSize.height,
                    visibleMinY: geometry.visibleRect.minY,
                    insetTop: geometry.contentInsets.top
                )
                let overshootGeometry = overshoot ? makeScrollGuardGeometry(from: geometry) : nil
                return TranscriptScrollMetrics(
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.visibleRect.height,
                    insetTop: geometry.contentInsets.top,
                    insetBottom: geometry.contentInsets.bottom,
                    overshoot: overshoot,
                    overshootGeometry: overshootGeometry
                )
            } action: { oldMetrics, metrics in
                handleScrollGeometryChange(from: oldMetrics, to: metrics, using: proxy)
            }
        let withPhase = withScrollEvents
            .onScrollPhaseChange { _, phase, context in
                handleScrollPhaseChange(phase, geometry: context.geometry, using: proxy)
            }
        let withSession = withPhase
            .onChange(of: subagents) { _, newSubagents in
                subagentIndex = SubagentIndex(newSubagents)
            }
            .onChange(of: sessionID) { _, newSessionID in
                handleSessionChange(to: newSessionID, using: proxy)
            }
        return withSession
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
        guard rowsMounted,
              hasMoreEarlier,
              !isLoadingEarlier,
              !didTriggerPaging,
              userHasScrolled || contentFitsViewport,
              let loadEarlier else { return }
        cancelPagingRestore()
        pagingAnchorEntryID = turns.first?.entryIDs.first
        didTriggerPaging = true
        isLoadingEarlier = true
        scrollState.recordEvent(name: "paging-start", newValue: 1)
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
            scrollState.recordEvent(name: "paging-end", newValue: loaded ? 1 : 0)
            guard loaded, pagingRowIsVisible else { return }
            Task { @MainActor in
                await Task.yield()
                guard pagingRowIsVisible else { return }
                loadEarlierIfNeeded()
            }
        }
    }

    private func handleFirstTurnChange(newID: Turn.ID?, using proxy: ScrollViewProxy) {
        guard let anchorEntryID = pagingAnchorEntryID else { return }
        guard let anchorID = turns.first(where: { $0.entryIDs.contains(anchorEntryID) })?.id else {
            pagingAnchorEntryID = nil
            return
        }
        guard newID != anchorID else { return }
        cancelPagingRestore()
        scrollToPagingAnchor(anchorID, using: proxy)
        pagingAnchorEntryID = nil
        schedulePagingRestore(anchorID: anchorID, using: proxy)
    }

    private func cancelPagingRestore() {
        pagingRestoreTask?.cancel()
        pagingRestoreTask = nil
    }

    private func schedulePagingRestore(anchorID: Turn.ID, using proxy: ScrollViewProxy) {
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

    private func scrollToPagingAnchor(_ anchorID: Turn.ID, using proxy: ScrollViewProxy) {
        withTransaction(Transaction(animation: nil)) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    private func builtRowDidAppear(id: String, index: Int) {
        scrollState.builtRowDidAppear(id: id, index: index)
    }

    private func builtRowDidDisappear(id: String) {
        scrollState.builtRowDidDisappear(
            id: id,
            displayRowCount: displayRows.count,
            queuedNoteCount: queuedNotes.count
        )
    }

    private func handleSessionChange(to newSessionID: String, using proxy: ScrollViewProxy) {
        recordLifecycleEvent(name: "session-change", sessionID: newSessionID)
        rebuildScrollTask?.cancel()
        rebuildScrollTask = nil
        rowsMounted = false
        _ = TranscriptLifecycleDiagnostics.shared.ingest(
            .rowsMounted(sessionID: sessionID, mounted: false)
        )
        scrollState.cancelBlankCheck()
        scrollState.cancelSentinelCheck()
        scrollState.sessionChanged(to: newSessionID)
        subagentIndex = SubagentIndex(subagents)
        userHasScrolled = false
        contentFitsViewport = false
        scrollState.latestUIKitMetrics = nil
        isPinnedToBottom = true
        userIsScrolling = false
        pagingAnchorEntryID = nil
        Task { @MainActor in
            await Task.yield()
            guard transcriptIsVisible else { return }
            mountRows(source: .session, using: proxy)
        }
    }

    private func handleTranscriptAppear(using proxy: ScrollViewProxy) {
        scrollState.prepare(sessionID: sessionID) { kind, recovered in
            diagnosticWrittenCount += 1
            diagnosticStatus = "count=\(diagnosticWrittenCount) kind=\(kind.rawValue) recovered=\(recovered)"
        }
        scrollState.onBuiltRowsEmpty = { [scrollState] in
            scheduleBlankCheck(using: proxy)
        }
        scrollState.recordEvent(name: "rows", newValue: Double(displayRows.count))
        scrollState.recordEvent(name: "notes", newValue: Double(queuedNotes.count))
    }

    private func mountRows(source: TranscriptMountSource, using proxy: ScrollViewProxy) {
        guard transcriptIsVisible, !rowsMounted else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(transcriptAppearDate ?? Date()) * 1000))
        withTransaction(Transaction(animation: nil)) {
            rowsMounted = true
        }
        _ = TranscriptLifecycleDiagnostics.shared.ingest(
            .rowsMounted(sessionID: sessionID, mounted: true)
        )
        recordLifecycleEvent(
            name: "mount",
            sessionID: sessionID,
            detail: "\(source.rawValue) \(elapsed)",
            recorder: scrollState.recorder
        )
        if isPinnedToBottom {
            scrollToNewest(using: proxy)
        }
        evaluateBlankIfNeeded(using: proxy)
        #if DEBUG
        transcriptLogger.notice("transcript-mount source=\(source.rawValue, privacy: .public) ms=\(elapsed, privacy: .public)")
        #endif
    }

    private func handleQueuedNotesChange(using proxy: ScrollViewProxy) {
        isPinnedToBottom = true
        _ = TranscriptLifecycleDiagnostics.shared.ingest(
            .pinned(sessionID: sessionID, pinned: true)
        )
        scrollToNewest(using: proxy)
    }

    private func evaluateBlankIfNeeded(using proxy: ScrollViewProxy) {
        guard rowsMounted,
              scrollState.builtRowIndices.isEmpty,
              !displayRows.isEmpty || !queuedNotes.isEmpty else { return }
        evaluateBlankState(using: proxy)
    }

    private func makeScrollGuardGeometry(from geometry: ScrollGeometry) -> ScrollGuardGeometry {
        ScrollGuardGeometry(
            contentOffsetY: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.visibleRect.height,
            insetTop: geometry.contentInsets.top,
            insetBottom: geometry.contentInsets.bottom,
            visibleMinY: geometry.visibleRect.minY,
            visibleMaxY: geometry.visibleRect.maxY
        )
    }

    private func handleScrollGeometryChange(
        from oldMetrics: TranscriptScrollMetrics,
        to metrics: TranscriptScrollMetrics,
        using proxy: ScrollViewProxy
    ) {
        recordGeometryChanges(from: oldMetrics, to: metrics)
        if let geometry = metrics.overshootGeometry {
            scrollState.lastScrollGeometry = geometry
            evaluateBlankState(using: proxy)
        } else if oldMetrics.overshoot, scrollState.blankOccurrence != nil {
            finishBlankOccurrence(recovered: true)
        }
        if isPinnedToBottom,
           !userIsScrolling,
           oldMetrics.contentHeight != metrics.contentHeight {
            scrollToNewest(using: proxy)
        }
        evaluateBlankIfNeeded(using: proxy)
    }

    private func handleUIKitScrollMetrics(_ metrics: UIKitScrollMetrics, using proxy: ScrollViewProxy) {
        scrollState.latestUIKitMetrics = metrics
        guard rowsMounted else { return }

        let viewportHeight = metrics.boundsHeight - metrics.insetTop - metrics.insetBottom
        contentFitsViewport = metrics.contentHeight <= viewportHeight
        if contentFitsViewport {
            loadEarlierIfNeeded()
        }

        guard isPinnedToBottom,
              !userIsScrolling,
              !metrics.userInteracting,
              pagingAnchorEntryID == nil,
              pagingRestoreTask == nil,
              metrics.contentHeight > viewportHeight,
              metrics.maxOffsetY - metrics.offsetY > 1 else { return }
        scrollState.bridgeHandle.pinToBottom()
        #if DEBUG
        transcriptLogger.notice(
            "transcript-pin from=\(metrics.offsetY, privacy: .public) to=\(metrics.maxOffsetY, privacy: .public)"
        )
        #endif
    }

    private func recordGeometryChanges(from old: TranscriptScrollMetrics, to new: TranscriptScrollMetrics) {
        if old.contentHeight != new.contentHeight {
            scrollState.recordEvent(
                name: "content-height",
                oldValue: Double(old.contentHeight),
                newValue: Double(new.contentHeight)
            )
        }
        if old.containerHeight != new.containerHeight {
            scrollState.recordEvent(
                name: "container-height",
                oldValue: Double(old.containerHeight),
                newValue: Double(new.containerHeight)
            )
        }
        if old.insetBottom != new.insetBottom {
            scrollState.recordEvent(
                name: "inset-bottom",
                oldValue: Double(old.insetBottom),
                newValue: Double(new.insetBottom)
            )
        }
    }

    private func handleScrollPhaseChange(
        _ phase: ScrollPhase,
        geometry: ScrollGeometry,
        using proxy: ScrollViewProxy
    ) {
        scrollState.scrollPhaseIsIdle = phase == .idle
        scrollState.lastScrollGeometry = makeScrollGuardGeometry(from: geometry)
        recordPhaseChange(phase)
        if scrollState.scrollPhaseIsIdle {
            evaluateBlankState(using: proxy)
        }
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
            isPinnedToBottom = isAtBottom(in: geometry)
        default:
            break
        }
        _ = TranscriptLifecycleDiagnostics.shared.ingest(
            .scrollIdle(sessionID: sessionID, idle: scrollState.scrollPhaseIsIdle)
        )
        _ = TranscriptLifecycleDiagnostics.shared.ingest(
            .pinned(sessionID: sessionID, pinned: isPinnedToBottom)
        )
    }

    private func recordPhaseChange(_ phase: ScrollPhase) {
        let code: Double
        switch phase {
        case .idle: code = 0
        case .interacting: code = 1
        case .decelerating: code = 2
        case .animating: code = 3
        case .tracking: code = 4
        @unknown default: code = 5
        }
        scrollState.recordEvent(name: "scroll-phase", newValue: code)
    }

    private func evaluateBlankState(using proxy: ScrollViewProxy, mayCorrect: Bool = false) {
        guard rowsMounted,
              scrollState.scrollPhaseIsIdle,
              let geometry = scrollState.lastScrollGeometry else { return }
        let kind = ScrollBlankCondition.kind(
            geometry: geometry,
            builtRowCount: scrollState.builtRowIndices.count,
            displayRowCount: displayRows.count,
            queuedNoteCount: queuedNotes.count
        )
        guard let kind else {
            if scrollState.blankOccurrence != nil {
                finishBlankOccurrence(recovered: true)
            } else {
                scrollState.blankCandidate = nil
                scrollState.blankCandidateStartedAt = nil
            }
            return
        }
        if var occurrence = scrollState.blankOccurrence {
            occurrence.latestGeometry = geometry
            scrollState.blankOccurrence = occurrence
            guard mayCorrect else { return }
            startCorrection(for: occurrence.kind, geometry: geometry, using: proxy)
            return
        }
        if scrollState.blankCandidate != kind {
            scrollState.blankCandidate = kind
            scrollState.blankCandidateStartedAt = Date()
        }
        scheduleBlankCheck(using: proxy)
        guard let startedAt = scrollState.blankCandidateStartedAt,
              Date().timeIntervalSince(startedAt) >= 0.4 else { return }
        startCorrection(for: kind, geometry: geometry, using: proxy)
    }

    private func scheduleBlankCheck(using proxy: ScrollViewProxy, delay: Duration = .milliseconds(250)) {
        guard rowsMounted, scrollState.blankCheckTask == nil else { return }
        scrollState.blankCheckTask = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            scrollState.blankCheckTask = nil
            evaluateBlankState(using: proxy, mayCorrect: true)
        }
    }

    private func startCorrection(
        for kind: ScrollBlankKind,
        geometry: ScrollGuardGeometry,
        using proxy: ScrollViewProxy
    ) {
        var occurrence = scrollState.blankOccurrence ?? ScrollBlankOccurrence(
            kind: kind,
            startedAt: scrollState.blankCandidateStartedAt ?? Date(),
            corrections: 0,
            latestGeometry: geometry
        )
        occurrence.latestGeometry = geometry
        guard occurrence.corrections < 2 else {
            scrollState.blankOccurrence = occurrence
            finishBlankOccurrence(recovered: false)
            return
        }
        occurrence.corrections += 1
        scrollState.blankOccurrence = occurrence
        if kind == .unbuilt {
            withTransaction(Transaction(animation: nil)) {
                stackGeneration += 1
            }
            recordLifecycleEvent(
                name: "stack-rebuild",
                sessionID: sessionID,
                detail: "\(stackGeneration)",
                recorder: scrollState.recorder
            )
            scrollState.recordEvent(name: "rebuild", newValue: Double(stackGeneration))
            if isPinnedToBottom {
                scheduleRebuildScroll(using: proxy)
            }
        } else if kind == .overshoot || isPinnedToBottom {
            isPinnedToBottom = true
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        } else if let lastBuiltRowID = scrollState.lastBuiltRowID {
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(lastBuiltRowID, anchor: .center)
            }
        } else {
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
        scrollState.cancelBlankCheck()
        scheduleBlankCheck(using: proxy, delay: .milliseconds(500))
    }

    private func finishBlankOccurrence(recovered: Bool) {
        guard let occurrence = scrollState.blankOccurrence else { return }
        scrollState.cancelBlankCheck()
        let elapsed = max(0, Int(Date().timeIntervalSince(occurrence.startedAt) * 1000))
        let kind = occurrence.kind
        scrollState.recordOccurrence(
            kind: kind,
            geometry: occurrence.latestGeometry,
            rowsCount: displayRows.count,
            notesCount: queuedNotes.count,
            isPinnedToBottom: isPinnedToBottom,
            userHasScrolled: userHasScrolled,
            corrections: occurrence.corrections,
            recovered: recovered,
            msToRecover: elapsed
        )
        scrollState.blankOccurrence = nil
        scrollState.blankCandidate = nil
        scrollState.blankCandidateStartedAt = nil
    }

    private func isAtBottom(in geometry: ScrollGeometry) -> Bool {
        if let metrics = scrollState.latestUIKitMetrics {
            return metrics.offsetY >= metrics.maxOffsetY - 36
        }
        let visibleBottom = geometry.visibleRect.maxY - geometry.contentInsets.bottom
        return visibleBottom >= geometry.contentSize.height - 36
    }

    private func scheduleRebuildScroll(using proxy: ScrollViewProxy) {
        rebuildScrollTask?.cancel()
        rebuildScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, isPinnedToBottom else { return }
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    private func scrollToNewest(using proxy: ScrollViewProxy) {
        scrollState.recordEvent(name: "scrollToNewest", newValue: 1)
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

    private var readableContentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? CCMetrics.readableContentWidth : .infinity
    }

    private var displayRows: [TranscriptRow] {
        var result = rows
        if !showsWorkedFooter {
            result.removeAll { row in
                if case .workedFooter = row.kind { return true }
                return false
            }
        }
        if let activityRow { result.append(activityRow) }
        return result
    }

    private var activityRow: TranscriptRow? {
        guard let activityFooter else { return nil }
        let turnID = turns.last?.id ?? "\(sessionID)-live"
        return TranscriptRow(id: "\(turnID)-activity", turnID: turnID, kind: .liveActivityFooter(activityFooter))
    }

    private var transcriptContentRows: [TranscriptRow] {
        displayRows.filter { row in
            if case .liveActivityFooter = row.kind { return false }
            return true
        }
    }

    private var turnStartingNotes: [QueuedNote] {
        queuedNotes.filter(\.startsTurn)
    }

    private var afterTurnNotes: [QueuedNote] {
        queuedNotes.filter { !$0.startsTurn }
    }

    @ViewBuilder
    private var transcriptRows: some View {
        let currentRows = transcriptContentRows
        let currentActivityRow = activityRow
        let startingNotes = turnStartingNotes
        let queuedNotes = afterTurnNotes
        let orderedNotes = startingNotes + queuedNotes
        let indexRows = currentRows + (currentActivityRow.map { [$0] } ?? [])
        let _ = scrollState.updateRowIndices(displayRows: indexRows, queuedNotes: orderedNotes)

        ForEach(currentRows) { row in
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
            .onAppear {
                let index = scrollState.displayRowIndex(for: row.id) ?? 0
                builtRowDidAppear(id: row.id, index: index)
            }
            .onDisappear {
                builtRowDidDisappear(id: row.id)
            }
            #if DEBUG || CC_PERF
            .onAppear {
                TranscriptPerformance.shared.markFirstRows()
            }
            #endif
        }

        ForEach(startingNotes) { note in
            pendingNoteView(note, displayRowCount: currentRows.count, activityInserted: false)
        }

        if let currentActivityRow {
            TranscriptRowView(
                sessionID: sessionID,
                row: currentActivityRow,
                subagents: rowSubagents(for: currentActivityRow),
                liveSession: liveSession,
                onTool: onTool,
                onSubagent: onSubagent,
                onSubagentResult: onSubagentResult,
                onCompaction: onCompaction,
                downloadFile: downloadFile
            )
            .equatable()
            .id(currentActivityRow.id)
            .onAppear {
                let index = scrollState.displayRowIndex(for: currentActivityRow.id) ?? 0
                builtRowDidAppear(id: currentActivityRow.id, index: index)
            }
            .onDisappear {
                builtRowDidDisappear(id: currentActivityRow.id)
            }
        }

        ForEach(queuedNotes) { note in
            pendingNoteView(note, displayRowCount: currentRows.count, activityInserted: currentActivityRow != nil)
        }

        Color.clear
            .frame(height: 1)
            .padding(.bottom, 18)
            .id("transcript-bottom")
            .onAppear {
                sentinelDidAppear()
            }
            .onDisappear {
                sentinelDidDisappear()
            }
            .accessibilityHidden(true)
            #if DEBUG
            .background {
                if ProcessInfo.processInfo.arguments.contains("-CCScrollGuardTestOvershoot") {
                    ScrollGuardDebugOvershootHook()
                }
            }
            #endif
    }

    private func sentinelDidAppear() {
        scrollState.cancelSentinelCheck()
        _ = TranscriptLifecycleDiagnostics.shared.ingest(
            .sentinelBuilt(sessionID: sessionID, built: true)
        )
    }

    private func sentinelDidDisappear() {
        _ = TranscriptLifecycleDiagnostics.shared.ingest(
            .sentinelBuilt(sessionID: sessionID, built: false)
        )
        scrollState.cancelSentinelCheck()
        scrollState.sentinelCheckTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled, transcriptIsVisible else { return }
            let triggers = TranscriptLifecycleDiagnostics.shared.ingest(
                .sentinelCheck(sessionID: sessionID)
            )
            writeLifecycleTriggers(
                triggers,
                sessionID: sessionID,
                recorder: scrollState.recorder,
                geometry: scrollState.lastScrollGeometry,
                rowsCount: displayRows.count,
                notesCount: queuedNotes.count,
                isPinnedToBottom: isPinnedToBottom,
                userHasScrolled: userHasScrolled
            )
            scrollState.sentinelCheckTask = nil
        }
    }

    @ViewBuilder
    private func pendingNoteView(
        _ note: QueuedNote,
        displayRowCount: Int,
        activityInserted: Bool
    ) -> some View {
        PendingPromptView(
            sessionID: sessionID,
            note: note,
            sessionState: sessionState,
            downloadFile: downloadFile,
            onRetry: onRetryNote,
            onEdit: onEditNote,
            onDelete: onDeleteNote,
            onCopy: onCopyNote,
            onSendAgain: onSendAgain
        )
        .onAppear {
            let index = scrollState.queuedNoteIndex(for: note.id) ?? 0
            let activityOffset = note.startsTurn ? 0 : (activityInserted ? 1 : 0)
            builtRowDidAppear(id: note.id, index: displayRowCount + index + activityOffset)
        }
        .onDisappear {
            builtRowDidDisappear(id: note.id)
        }
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

private enum TranscriptMountSource: String {
    case coordinator
    case immediate
    case cap
    case session
}

private struct TranscriptMountReader: UIViewRepresentable {
    let onSettled: (TranscriptMountSource) -> Void

    func makeUIView(context: Context) -> ReaderView {
        ReaderView(onSettled: onSettled)
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onSettled = onSettled
    }

    final class ReaderView: UIView {
        var onSettled: ((TranscriptMountSource) -> Void)?
        private var didSchedule = false

        init(onSettled: @escaping (TranscriptMountSource) -> Void) {
            self.onSettled = onSettled
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                didSchedule = false
                return
            }
            guard !didSchedule else { return }
            didSchedule = true

            var responder: UIResponder? = self
            while let current = responder {
                if let viewController = current as? UIViewController {
                    if let coordinator = viewController.transitionCoordinator {
                        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                            self?.onSettled?(.coordinator)
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            self?.onSettled?(.immediate)
                        }
                    }
                    return
                }
                responder = current.next
            }

            DispatchQueue.main.async { [weak self] in
                self?.onSettled?(.immediate)
            }
        }
    }
}

#if DEBUG
private let transcriptLogger = Logger(
    subsystem: "com.example.cc-controller",
    category: "transcript"
)

private struct ScrollGuardDebugOvershootHook: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        context.coordinator.schedule(from: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.schedule(from: uiView)
    }

    @MainActor
    final class Coordinator {
        private var attempts = 0
        private var scheduled = false

        func schedule(from view: UIView) {
            guard !scheduled, attempts < 12 else { return }
            scheduled = true
            attempts += 1
            let delay: Duration = attempts == 1 ? .seconds(1.5) : .milliseconds(250)
            Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: delay)
                guard let self, let view else { return }
                self.scheduled = false
                guard let scrollView = self.scrollView(above: view) else {
                    self.schedule(from: view)
                    return
                }
                scrollView.layoutIfNeeded()
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: scrollView.contentSize.height + 2_000),
                    animated: false
                )
            }
        }

        private func scrollView(above view: UIView) -> UIScrollView? {
            var current: UIView? = view.superview
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView { return scrollView }
                current = candidate.superview
            }
            return nil
        }
    }
}
#endif

private struct PendingPromptView: View {
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
            if sessionState != .working { nonWorkingSince = .now }
        }
        .onChange(of: sessionState) { oldState, newState in
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
