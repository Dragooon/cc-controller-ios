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
    case note(QueuedNote, sessionState: SessionState?, activityInserted: Bool)
}

final class TranscriptCollectionView: UICollectionView {
    var shouldPinToBottom: (() -> Bool)?
    var didFinishLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        if shouldPinToBottom?() == true, !isDragging, !isDecelerating {
            let inset = adjustedContentInset
            let maxOffsetY = max(
                -inset.top,
                contentSize.height + inset.bottom - bounds.height
            )
            if abs(contentOffset.y - maxOffsetY) > 0.5 {
                var offset = contentOffset
                offset.y = maxOffsetY
                setContentOffset(offset, animated: false)
            }
        }
        didFinishLayout?()
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
    @Binding var isPinnedToBottom: Bool
    @Binding var jumpToLatestRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> TranscriptCollectionView {
        let collectionView = TranscriptCollectionView(
            frame: .zero,
            collectionViewLayout: makeLayout(maxWidth: readableContentMaxWidth)
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
        context.coordinator.update(self)
        return collectionView
    }

    func updateUIView(_ uiView: TranscriptCollectionView, context: Context) {
        context.coordinator.update(self)
        if let layout = uiView.collectionViewLayout as? UICollectionViewCompositionalLayout {
            layout.invalidateLayout()
        }
    }

    private func makeLayout(maxWidth: CGFloat) -> UICollectionViewLayout {
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
        return UICollectionViewCompositionalLayout(sectionProvider: { _, environment in
            guard maxWidth.isFinite else { return section }
            let extra = max(0, environment.container.effectiveContentSize.width - maxWidth) / 2
            var cappedSection = section
            cappedSection.contentInsets.leading = 16 + extra
            cappedSection.contentInsets.trailing = 16 + extra
            return cappedSection
        })
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        private weak var collectionView: TranscriptCollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem>?
        private var currentItems: [TranscriptCollectionItem] = []
        private var currentContent: [TranscriptCollectionItem: TranscriptCollectionContent] = [:]
        private var currentNotes: [QueuedNote] = []
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

        func update(_ representable: TranscriptCollectionRepresentable) {
            guard self.collectionView != nil else { return }
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
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
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
            setPinned(true)
            let inset = collectionView.adjustedContentInset
            let maxOffsetY = max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
            collectionView.layoutIfNeeded()
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

            let activityInserted = representable.rows.contains {
                if case .liveActivityFooter = $0.kind { return true }
                return false
            }
            for row in representable.rows {
                let item = TranscriptCollectionItem.row(row.id)
                items.append(item)
                let rowSubagents: [Subagent] = {
                    guard case .item(let item) = row.kind else { return [] }
                    return rowSubagentIndex.matchingSubagents(for: item)
                }()
                let rowSession: Session? = {
                    if case .liveActivityFooter = row.kind { return representable.liveSession }
                    return nil
                }()
                content[item] = .row(row, subagents: rowSubagents, liveSession: rowSession)
            }
            for note in representable.queuedNotes where note.startsTurn {
                let item = TranscriptCollectionItem.startingNote(note.id)
                items.append(item)
                content[item] = .note(note, sessionState: representable.sessionState, activityInserted: false)
            }
            for note in representable.queuedNotes where !note.startsTurn {
                let item = TranscriptCollectionItem.queuedNote(note.id)
                items.append(item)
                content[item] = .note(note, sessionState: representable.sessionState, activityInserted: activityInserted)
            }
            return (items, content)
        }

        private func apply(
            items: [TranscriptCollectionItem],
            content: [TranscriptCollectionItem: TranscriptCollectionContent],
            notes: [QueuedNote]
        ) {
            guard let collectionView, let dataSource else { return }
            let oldItems = currentItems
            let oldContent = currentContent
            let anchor = isPinnedToBottom ? nil : visibleAnchor(in: collectionView, dataSource: dataSource)
            let oldNoteIDs = Set(currentNotes.map(\.id))
            let newNoteIDs = Set(notes.map(\.id))
            let hasNewNote = hasAppliedSnapshot && !reduceMotion && !newNoteIDs.subtracting(oldNoteIDs).isEmpty
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
            dataSource.apply(snapshot, animatingDifferences: hasNewNote) { [weak self] in
                guard let self else { return }
                collectionView.layoutIfNeeded()
                self.restore(anchor: anchor, in: collectionView, dataSource: dataSource)
                self.hasAppliedSnapshot = true
                self.maybeLoadEarlierIfNearTop()
            }
        }

        private func visibleAnchor(
            in collectionView: UICollectionView,
            dataSource: UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem>
        ) -> (item: TranscriptCollectionItem, relativeMinY: CGFloat)? {
            guard let indexPath = collectionView.indexPathsForVisibleItems.min(by: {
                collectionView.layoutAttributesForItem(at: $0)?.frame.minY ?? .greatestFiniteMagnitude
                    < collectionView.layoutAttributesForItem(at: $1)?.frame.minY ?? .greatestFiniteMagnitude
            }), let item = dataSource.itemIdentifier(for: indexPath),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
            return (item, attributes.frame.minY - collectionView.contentOffset.y)
        }

        private func restore(
            anchor: (item: TranscriptCollectionItem, relativeMinY: CGFloat)?,
            in collectionView: UICollectionView,
            dataSource: UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem>
        ) {
            guard let anchor, !isPinnedToBottom,
                  let indexPath = dataSource.indexPath(for: anchor.item),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
            let newRelativeMinY = attributes.frame.minY - collectionView.contentOffset.y
            var offset = collectionView.contentOffset
            offset.y += newRelativeMinY - anchor.relativeMinY
            collectionView.setContentOffset(offset, animated: false)
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
            case .note(let note, let sessionState, let activityInserted):
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
                .id(note.id + (activityInserted ? "-activity" : "-starting"))
            }
        }
    }
}
}
