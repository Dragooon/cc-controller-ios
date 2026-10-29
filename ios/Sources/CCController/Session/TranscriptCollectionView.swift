import CCKit
import SwiftUI
import UIKit

private enum TranscriptCollectionSection: Hashable {
    case transcript
}

enum TranscriptCollectionItem: Hashable {
    case paging
    case row(String)
    case startingNote(String)
    case queuedNote(String)
}

private enum TranscriptCollectionContent: Equatable {
    case paging(isLoading: Bool)
    case row(TranscriptRow, subagents: [Subagent], liveSession: Session?)
    case note(QueuedNote, sessionState: SessionState?)
}

final class TranscriptCollectionView: UICollectionView {
    var shouldPinToBottom: (() -> Bool)?
    var didFinishLayout: (() -> Void)?
    var isAnimatingJump = false

    override func layoutSubviews() {
        super.layoutSubviews()
        didFinishLayout?()
    }

    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        guard shouldPinToBottom?() == true else { return }
        let inset = adjustedContentInset
        let maxOffsetY = max(
            -inset.top,
            contentSize.height + inset.bottom - bounds.height
        )
        guard abs(contentOffset.y - maxOffsetY) > 0.5 else { return }
        let before = contentOffset.y
        var offset = contentOffset
        offset.y = maxOffsetY
        setContentOffset(offset, animated: false)
        #if DEBUG
        MotionTrace.shared.recordPin(before: before, after: maxOffsetY, reason: "insetChange")
        #endif
    }
}

private final class TranscriptAnchoringLayout: UICollectionViewCompositionalLayout {
    enum Anchor {
        case bottom
        case item(TranscriptCollectionItem, distanceFromViewportTop: CGFloat)
    }

    var anchor: Anchor = .bottom
    private var updateAnchor: Anchor?

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        updateAnchor = anchor
        super.prepare(forCollectionViewUpdates: updateItems)
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        updateAnchor = nil
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        let anchor = updateAnchor ?? self.anchor
        guard let collectionView else { return proposedContentOffset }
        let inset = collectionView.adjustedContentInset
        let minimumY = -inset.top
        let maximumY = max(minimumY, collectionViewContentSize.height + inset.bottom - collectionView.bounds.height)
        let targetY: CGFloat
        switch anchor {
        case .bottom:
            targetY = maximumY
        case .item(let item, let distanceFromViewportTop):
            guard let indexPath = indexPath(for: item),
                  let attributes = layoutAttributesForItem(at: indexPath) else {
                return proposedContentOffset
            }
            targetY = attributes.frame.minY - inset.top - distanceFromViewportTop
        }
        let clampedY = min(max(targetY, minimumY), maximumY)
        #if DEBUG
        if abs(collectionView.contentOffset.y - clampedY) > 0.5 {
            MotionTrace.shared.recordPin(
                before: collectionView.contentOffset.y,
                after: clampedY,
                reason: "layoutAnchor"
            )
        }
        #endif
        return CGPoint(x: proposedContentOffset.x, y: clampedY)
    }

    override func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes
        )
        let heightDelta = preferredAttributes.frame.height - originalAttributes.frame.height
        guard abs(heightDelta) > 0.5 else { return context }

        let anchor = updateAnchor ?? self.anchor
        switch anchor {
        case .bottom:
            context.contentOffsetAdjustment.y += heightDelta
        case .item(let item, _):
            guard let indexPath = indexPath(for: item),
                  let anchorAttributes = layoutAttributesForItem(at: indexPath),
                  originalAttributes.indexPath != anchorAttributes.indexPath,
                  originalAttributes.frame.maxY <= anchorAttributes.frame.minY else { return context }
            context.contentOffsetAdjustment.y += heightDelta
        }
        #if DEBUG
        if let collectionView {
            MotionTrace.shared.recordPin(
                before: collectionView.contentOffset.y,
                after: collectionView.contentOffset.y + heightDelta,
                reason: "layoutAnchor"
            )
        }
        #endif
        return context
    }

    private func indexPath(for item: TranscriptCollectionItem) -> IndexPath? {
        guard let dataSource = collectionView?.dataSource as?
            UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem> else { return nil }
        return dataSource.indexPath(for: item)
    }
}

@MainActor
struct TranscriptCollectionRepresentable: UIViewRepresentable {
    let sessionID: String
    let rows: [TranscriptRow]
    let queuedNotes: [QueuedNote]
    let sessionState: SessionState?
    let subagents: [Subagent]
    let liveSession: Session?
    let hasMoreEarlier: Bool
    let loadEarlier: (() async throws -> Void)?
    let onPagingError: (String) -> Void
    let onRetryNote: (String) -> Void
    let onEditNote: (String) -> Void
    let onDeleteNote: (String) -> Void
    let onCopyNote: (String) -> Void
    let onSendAgain: (String) -> Void
    let onTool: (ToolEntry) -> Void
    let onSubagent: (SubagentEntry) -> Void
    let onSubagentResult: (SubagentResultEntry, Subagent?) -> Void
    let onCompaction: (CompactionEntry) -> Void
    let downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    let readableContentMaxWidth: CGFloat
    let reduceMotion: Bool
    let onUnbuiltDiagnostic: () -> Void
    let noteAliases: [String: String]
    @Binding var isPinnedToBottom: Bool
    @Binding var jumpToLatestRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> TranscriptCollectionView {
        let collectionView = TranscriptCollectionView(
            frame: .zero,
            collectionViewLayout: makeLayout(coordinator: context.coordinator)
        )
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "transcript-scroll"
        if #available(iOS 26.0, *) {
            collectionView.bottomEdgeEffect.style = .hard
        }
        context.coordinator.attach(collectionView: collectionView)
        _ = context.coordinator.update(self)
        return collectionView
    }

    func updateUIView(_ uiView: TranscriptCollectionView, context: Context) {
        let readableContentMaxWidthChanged = context.coordinator.update(self)
        if readableContentMaxWidthChanged,
           let layout = uiView.collectionViewLayout as? UICollectionViewCompositionalLayout {
            layout.invalidateLayout()
        }
    }

    private func makeLayout(coordinator: Coordinator) -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(80)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(80)
            ),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 20
        section.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)
        let sectionProvider: UICollectionViewCompositionalLayoutSectionProvider = { _, environment in
            let maxWidth = coordinator.readableContentMaxWidth
            guard maxWidth.isFinite else { return section }
            let extra = max(0, environment.container.effectiveContentSize.width - maxWidth) / 2
            var cappedSection = section
            cappedSection.contentInsets.leading = 16 + extra
            cappedSection.contentInsets.trailing = 16 + extra
            return cappedSection
        }
        return TranscriptAnchoringLayout(sectionProvider: sectionProvider)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        private weak var collectionView: TranscriptCollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem>?
        private var currentItems: [TranscriptCollectionItem] = []
        private var currentContent: [TranscriptCollectionItem: TranscriptCollectionContent] = [:]
        private var currentNotes: [QueuedNote] = []
        private var noteAliases: [String: String] = [:]
        private var hasAppliedSnapshot = false
        private var sessionID = ""
        private var hasMoreEarlier = false
        private var isLoadingEarlier = false
        private var didTriggerPaging = false
        private var pagingTask: Task<Void, Never>?
        private var loadEarlier: (() async throws -> Void)?
        private var onPagingError: (String) -> Void = { _ in }
        private var onRetryNote: (String) -> Void = { _ in }
        private var onEditNote: (String) -> Void = { _ in }
        private var onDeleteNote: (String) -> Void = { _ in }
        private var onCopyNote: (String) -> Void = { _ in }
        private var onSendAgain: (String) -> Void = { _ in }
        private var onUnbuiltDiagnostic: () -> Void = {}
        private var recorder: ScrollDiagnosticsRecorder?
        private var lastUnbuiltDiagnosticAt: Date?
        private var pinnedBinding = Binding.constant(true)
        private var lastJumpToLatestRequest = 0
        private(set) var isPinnedToBottom = true
        private var rowSubagentIndex = SubagentIndex([])
        private var onTool: (ToolEntry) -> Void = { _ in }
        private var onSubagent: (SubagentEntry) -> Void = { _ in }
        private var onSubagentResult: (SubagentResultEntry, Subagent?) -> Void = { _, _ in }
        private var onCompaction: (CompactionEntry) -> Void = { _ in }
        private var downloadFile: (@MainActor @Sendable (FileEntry) async throws -> URL)?
        private var sessionState: SessionState?
        private var liveSession: Session?
        private var sessionIDForView = ""
        private var reduceMotion = false
        fileprivate var readableContentMaxWidth: CGFloat = .infinity

        func attach(collectionView: TranscriptCollectionView) {
            self.collectionView = collectionView
            collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "transcript-cell")
            collectionView.delegate = self
            collectionView.shouldPinToBottom = { [weak self] in
                self?.isPinnedToBottom == true
            }
            collectionView.didFinishLayout = { [weak self] in
                self?.didFinishLayout()
            }
            #if DEBUG
            MotionTrace.shared.registerScrollView(collectionView, pinned: { [weak self] in
                self?.isPinnedToBottom == true
            })
            #endif
            dataSource = UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, item in
                guard let self else { return nil }
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "transcript-cell",
                    for: indexPath
                )
                cell.contentConfiguration = UIHostingConfiguration {
                    self.hostedView(for: item)
                }
                .margins(.all, 0)
                #if DEBUG || CC_PERF
                TranscriptPerformance.shared.markFirstRows()
                #endif
                return cell
            }
        }

        func update(_ representable: TranscriptCollectionRepresentable) -> Bool {
            guard self.collectionView != nil else { return false }
            let readableContentMaxWidthChanged = readableContentMaxWidth != representable.readableContentMaxWidth
            readableContentMaxWidth = representable.readableContentMaxWidth
            pinnedBinding = representable.$isPinnedToBottom
            if !hasAppliedSnapshot {
                isPinnedToBottom = representable.isPinnedToBottom
            }
            loadEarlier = representable.loadEarlier
            onPagingError = representable.onPagingError
            onRetryNote = representable.onRetryNote
            onEditNote = representable.onEditNote
            onDeleteNote = representable.onDeleteNote
            onCopyNote = representable.onCopyNote
            onSendAgain = representable.onSendAgain
            onUnbuiltDiagnostic = representable.onUnbuiltDiagnostic
            noteAliases = representable.noteAliases
            hasMoreEarlier = representable.hasMoreEarlier
            sessionState = representable.sessionState
            liveSession = representable.liveSession
            sessionIDForView = representable.sessionID
            reduceMotion = representable.reduceMotion
            rowSubagentIndex = SubagentIndex(representable.subagents)
            onTool = representable.onTool
            onSubagent = representable.onSubagent
            onSubagentResult = representable.onSubagentResult
            onCompaction = representable.onCompaction
            downloadFile = representable.downloadFile
            isLoadingEarlier = dataSource?.snapshot().itemIdentifiers.contains(.paging) == true
                && isLoadingEarlier

            if sessionID != representable.sessionID {
                sessionID = representable.sessionID
                recorder = ScrollDiagnosticsRecorder(sessionID: sessionID)
                lastUnbuiltDiagnosticAt = nil
                didTriggerPaging = false
            }

            let newState = makeState(from: representable)
            apply(
                items: newState.items,
                content: newState.content,
                notes: representable.queuedNotes
            )

            if representable.jumpToLatestRequest != lastJumpToLatestRequest {
                lastJumpToLatestRequest = representable.jumpToLatestRequest
                jumpToLatest()
            }
            return readableContentMaxWidthChanged
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if let collectionView = scrollView as? TranscriptCollectionView {
                collectionView.isAnimatingJump = false
            }
            setPinned(false)
            didTriggerPaging = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isPinnedToBottom else { return }
            let top = -scrollView.adjustedContentInset.top
            if scrollView.contentOffset.y <= top + scrollView.bounds.height {
                loadEarlierIfNeeded()
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                updatePinAfterUserScroll(scrollView)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updatePinAfterUserScroll(scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? TranscriptCollectionView else { return }
            collectionView.isAnimatingJump = false
            #if DEBUG
            MotionTrace.shared.recordEvent("scrollToNewest", data: ["phase": "ran", "animated": true])
            #endif
        }

        func collectionView(
            _ collectionView: UICollectionView,
            willDisplay cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
            if item == .paging {
                loadEarlierIfNeeded()
            }
        }

        private func setPinned(_ pinned: Bool) {
            guard isPinnedToBottom != pinned else { return }
            isPinnedToBottom = pinned
            pinnedBinding.wrappedValue = pinned
        }

        private func updatePinAfterUserScroll(_ scrollView: UIScrollView) {
            let inset = scrollView.adjustedContentInset
            let maxOffsetY = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
            setPinned(scrollView.contentOffset.y >= maxOffsetY - 36)
            if isPinnedToBottom {
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: maxOffsetY),
                    animated: false
                )
            }
        }

        private func jumpToLatest() {
            guard let collectionView else { return }
            #if DEBUG
            MotionTrace.shared.recordEvent("scrollToNewest", data: ["phase": "scheduled", "animated": true])
            #endif
            setPinned(true)
            collectionView.layoutIfNeeded()
            let inset = collectionView.adjustedContentInset
            let maxOffsetY = max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
            collectionView.isAnimatingJump = true
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: maxOffsetY),
                animated: true
            )
        }

        private func loadEarlierIfNeeded() {
            guard hasMoreEarlier, !isLoadingEarlier, !didTriggerPaging, let loadEarlier else { return }
            didTriggerPaging = true
            isLoadingEarlier = true
            pagingTask?.cancel()
            pagingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await loadEarlier()
                } catch {
                    onPagingError(error.localizedDescription)
                }
                isLoadingEarlier = false
                didTriggerPaging = false
            }
        }

        private func makeState(
            from representable: TranscriptCollectionRepresentable
        ) -> (items: [TranscriptCollectionItem], content: [TranscriptCollectionItem: TranscriptCollectionContent]) {
            var items: [TranscriptCollectionItem] = []
            var content: [TranscriptCollectionItem: TranscriptCollectionContent] = [:]
            if representable.hasMoreEarlier || isLoadingEarlier {
                items.append(.paging)
                content[.paging] = .paging(isLoading: isLoadingEarlier)
            }

            let contentRows = representable.rows.filter { row in
                if case .status = row.kind { return false }
                return true
            }
            for row in contentRows {
                let item = aliasedItem(for: row.id) ?? .row(row.id)
                items.append(item)
                let rowSubagents: [Subagent] = {
                    guard case .item(let item) = row.kind else { return [] }
                    return rowSubagentIndex.matchingSubagents(for: item)
                }()
                content[item] = .row(row, subagents: rowSubagents, liveSession: nil)
            }
            for note in representable.queuedNotes where note.startsTurn {
                let item = TranscriptCollectionItem.startingNote(note.id)
                items.append(item)
                content[item] = .note(note, sessionState: representable.sessionState)
            }
            for note in representable.queuedNotes where !note.startsTurn {
                let item = TranscriptCollectionItem.queuedNote(note.id)
                items.append(item)
                content[item] = .note(note, sessionState: representable.sessionState)
            }
            if let statusRow = representable.rows.first(where: { row in
                if case .status = row.kind { return true }
                return false
            }) {
                let item = TranscriptCollectionItem.row("status")
                items.append(item)
                content[item] = .row(
                    statusRow,
                    subagents: [],
                    liveSession: representable.liveSession
                )
            }
            return (items, content)
        }

        private func aliasedItem(for entryID: String) -> TranscriptCollectionItem? {
            guard let noteID = noteAliases[entryID] else { return nil }
            if let existing = currentItems.first(where: { item in
                switch item {
                case .startingNote(let id), .queuedNote(let id): return id == noteID
                default: return false
                }
            }) {
                return existing
            }
            return .queuedNote(noteID)
        }

        private func apply(
            items: [TranscriptCollectionItem],
            content: [TranscriptCollectionItem: TranscriptCollectionContent],
            notes: [QueuedNote]
        ) {
            guard let collectionView, let dataSource else { return }
            let oldItems = currentItems
            let oldContent = currentContent
            let layout = collectionView.collectionViewLayout as? TranscriptAnchoringLayout
            let anchor = anchorForUpdate(in: collectionView, dataSource: dataSource)
            currentItems = items
            currentContent = content
            currentNotes = notes
            guard oldItems != items || oldContent != content else {
                maybeLoadEarlierIfNearTop()
                return
            }

            var snapshot = NSDiffableDataSourceSnapshot<TranscriptCollectionSection, TranscriptCollectionItem>()
            snapshot.appendSections([.transcript])
            snapshot.appendItems(items, toSection: .transcript)
            let changedItems = items.filter { item in
                oldItems.contains(item) && oldContent[item] != content[item]
            }
            if !changedItems.isEmpty {
                snapshot.reconfigureItems(changedItems)
            }
            let inserted = items.filter { !oldItems.contains($0) }
            let deleted = oldItems.filter { !items.contains($0) }
            let animated = hasAppliedSnapshot && !reduceMotion && isNewestEndUpdate(
                oldItems: oldItems,
                newItems: items,
                inserted: inserted,
                deleted: deleted,
                reconfigured: changedItems
            )
            layout?.anchor = anchor
            #if DEBUG
            MotionTrace.shared.recordEvent("snapshotApplied", data: [
                "inserted": inserted.map(traceID),
                "deleted": deleted.map(traceID),
                "reconfigured": changedItems.map(traceID),
                "animated": animated,
            ])
            #endif
            let applySnapshot = {
                dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
                    guard let self else { return }
                    self.hasAppliedSnapshot = true
                    self.maybeLoadEarlierIfNearTop()
                }
            }
            if animated {
                UIView.animate(
                    withDuration: 0.3,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
                    animations: applySnapshot
                )
            } else {
                applySnapshot()
            }
        }

        private func anchorForUpdate(
            in collectionView: UICollectionView,
            dataSource: UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem>
        ) -> TranscriptAnchoringLayout.Anchor {
            if isPinnedToBottom, !collectionView.isDragging, !collectionView.isDecelerating {
                return .bottom
            }
            guard let indexPath = collectionView.indexPathsForVisibleItems.min(by: {
                collectionView.layoutAttributesForItem(at: $0)?.frame.minY ?? .greatestFiniteMagnitude
                    < collectionView.layoutAttributesForItem(at: $1)?.frame.minY ?? .greatestFiniteMagnitude
            }), let item = dataSource.itemIdentifier(for: indexPath),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
                return .bottom
            }
            let viewportTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            return .item(item, distanceFromViewportTop: attributes.frame.minY - viewportTop)
        }

        private func isNewestEndUpdate(
            oldItems: [TranscriptCollectionItem],
            newItems: [TranscriptCollectionItem],
            inserted: [TranscriptCollectionItem],
            deleted: [TranscriptCollectionItem],
            reconfigured: [TranscriptCollectionItem]
        ) -> Bool {
            let oldSurvivingContent = oldItems.enumerated().filter { _, item in
                item != .paging && item != .row("status") && newItems.contains(item)
            }
            let newSurvivingContent = newItems.enumerated().filter { _, item in
                item != .paging && item != .row("status") && oldItems.contains(item)
            }
            let oldBoundary = oldSurvivingContent.last?.offset ?? -1
            let newBoundary = newSurvivingContent.last?.offset ?? -1
            let insertedAtNewestEnd = inserted.allSatisfy { item in
                guard let index = newItems.firstIndex(of: item) else { return false }
                return index > newBoundary
            }
            let deletedAtNewestEnd = deleted.allSatisfy { item in
                guard let index = oldItems.firstIndex(of: item) else { return false }
                return index > oldBoundary
            }
            let reconfiguredAtNewestEnd = reconfigured.allSatisfy { item in
                guard let index = newItems.firstIndex(of: item) else { return false }
                return item == .row("status") || index >= newBoundary
            }
            return !(inserted.isEmpty && deleted.isEmpty && reconfigured.isEmpty)
                && insertedAtNewestEnd && deletedAtNewestEnd && reconfiguredAtNewestEnd
        }

        private func maybeLoadEarlierIfNearTop() {
            guard let collectionView else { return }
            let top = -collectionView.adjustedContentInset.top
            if collectionView.contentOffset.y <= top + collectionView.bounds.height {
                loadEarlierIfNeeded()
            }
        }

        private func didFinishLayout() {
            guard let collectionView, collectionView.window != nil,
                  collectionView.bounds.height > 0,
                  !(dataSource?.snapshot().itemIdentifiers.isEmpty ?? true),
                  collectionView.indexPathsForVisibleItems.isEmpty else { return }
            let now = Date()
            guard lastUnbuiltDiagnosticAt.map({ now.timeIntervalSince($0) >= 10 }) ?? true else { return }
            lastUnbuiltDiagnosticAt = now
            let inset = collectionView.adjustedContentInset
            let geometry = ScrollGuardGeometry(
                contentOffsetY: collectionView.contentOffset.y,
                contentHeight: collectionView.contentSize.height,
                containerHeight: collectionView.bounds.height - inset.top - inset.bottom,
                insetTop: inset.top,
                insetBottom: inset.bottom,
                visibleMinY: collectionView.contentOffset.y + inset.top,
                visibleMaxY: collectionView.contentOffset.y + collectionView.bounds.height - inset.bottom
            )
            recorder?.record(
                kind: .unbuilt,
                geometry: geometry,
                rowsCount: currentItems.count,
                notesCount: currentNotes.count,
                isPinnedToBottom: isPinnedToBottom,
                userHasScrolled: !isPinnedToBottom,
                corrections: 0,
                recovered: false,
                msToRecover: 0
            )
            onUnbuiltDiagnostic()
        }

        private func traceID(_ item: TranscriptCollectionItem) -> String {
            switch item {
            case .paging: return "paging"
            case .row(let id): return id
            case .startingNote(let id), .queuedNote(let id): return "note:\(id)"
            }
        }

        @ViewBuilder
        private func hostedView(for item: TranscriptCollectionItem) -> some View {
            if let content = currentContent[item] {
                switch content {
            case .paging(let isLoading):
                HStack {
                    if isLoading { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                #if DEBUG
                .background(MotionTraceProbe(id: "paging"))
                #endif
            case .row(let row, let subagents, let liveSession):
                TranscriptRowView(
                    sessionID: sessionIDForView,
                    row: row,
                    subagents: subagents,
                    liveSession: liveSession,
                    onTool: onTool,
                    onSubagent: onSubagent,
                    onSubagentResult: onSubagentResult,
                    onCompaction: onCompaction,
                    downloadFile: downloadFile
                )
                .equatable()
                #if DEBUG
                .background(MotionTraceProbe(id: row.id))
                #endif
            case .note(let note, let sessionState):
                PendingPromptView(
                    sessionID: sessionIDForView,
                    note: note,
                    sessionState: sessionState,
                    downloadFile: downloadFile,
                    onRetry: onRetryNote,
                    onEdit: onEditNote,
                    onDelete: onDeleteNote,
                    onCopy: onCopyNote,
                    onSendAgain: onSendAgain
                )
                .transition(.identity)
                #if DEBUG
                .background(MotionTraceProbe(id: "note:\(note.id)"))
                #endif
            }
        }
    }
}
}
