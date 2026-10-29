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
    var didFinishLayout: (() -> Void)?
    var didChangeTraits: (() -> Void)?
    var isAnimatingJump = false

    override func layoutSubviews() {
        super.layoutSubviews()
        applyAnchoredContentOffsetIfNeeded()
        didFinishLayout?()
    }

    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        didChangeTraits?()
    }

    private func applyAnchoredContentOffsetIfNeeded() {
        guard !isTracking, !isDragging, !isDecelerating, !isAnimatingJump,
              let layout = collectionViewLayout as? TranscriptListLayout,
              let target = layout.anchoredContentOffset(for: self),
              abs(contentOffset.y - target.y) > 0.5 else { return }

        let before = contentOffset.y
        var offset = contentOffset
        offset.y = target.y
        setContentOffset(offset, animated: false)
        #if DEBUG
        MotionTrace.shared.recordPin(before: before, after: target.y, reason: target.reason)
        #endif
    }
}

private final class TranscriptListCell: UICollectionViewCell {
    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }
}

private final class TranscriptListLayout: UICollectionViewLayout {
    enum Anchor {
        case bottom
        case item(TranscriptCollectionItem, distanceFromViewportTop: CGFloat)
    }

    private struct HeightKey: Hashable {
        let item: TranscriptCollectionItem
        let width: Int

        init(item: TranscriptCollectionItem, width: CGFloat) {
            self.item = item
            self.width = Int((width * 2).rounded())
        }
    }

    private let heightProvider: (TranscriptCollectionItem, CGFloat) -> CGFloat
    private var attributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var contentSize = CGSize.zero
    private var measuredHeights: [HeightKey: CGFloat] = [:]
    private var itemsRequiringMeasurement: Set<TranscriptCollectionItem> = []
    private var preparedWidth: CGFloat = -1
    private var newestEndUpdate = false
    private var insertedIndexPaths: Set<IndexPath> = []

    var anchor: Anchor = .bottom
    var readableContentMaxWidth: CGFloat = .infinity

    init(heightProvider: @escaping (TranscriptCollectionItem, CGFloat) -> CGFloat) {
        self.heightProvider = heightProvider
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepareForAnimatedNewestEndUpdate() {
        newestEndUpdate = true
    }

    func invalidateHeights(for items: [TranscriptCollectionItem]) {
        itemsRequiringMeasurement.formUnion(items)
        for item in items {
            measuredHeights = measuredHeights.filter { $0.key.item != item }
        }
        invalidateLayout()
    }

    func invalidateAllHeights() {
        measuredHeights.removeAll(keepingCapacity: true)
        invalidateLayout()
    }

    override func prepare() {
        super.prepare()
        guard let collectionView,
              collectionView.numberOfSections > 0 else {
            attributes.removeAll(keepingCapacity: true)
            contentSize = .zero
            return
        }
        let width = max(0, collectionView.bounds.width)
        let itemWidth = itemWidth(for: width)
        let itemCount = collectionView.numberOfItems(inSection: 0)
        let viewportHeight = max(collectionView.bounds.height, 1)
        let visibleRect = collectionView.bounds
        let expandedRect = visibleRect.insetBy(dx: 0, dy: -viewportHeight)
        let itemEntries = (0..<itemCount).compactMap { index -> (index: Int, item: TranscriptCollectionItem)? in
            guard let item = itemIdentifier(at: IndexPath(item: index, section: 0)) else { return nil }
            return (index, item)
        }
        let itemIdentifiers = itemEntries.map(\.item)

        var heights = itemIdentifiers.map { height(for: $0, width: itemWidth, force: itemsRequiringMeasurement.contains($0)) }
        var measuredIndices = Set<Int>()
        for _ in 0..<2 {
            let frames = makeFrames(heights: heights, width: width)
            let newestStart = newestIndices(heights: heights, viewportHeight: viewportHeight)
            for index in heights.indices {
                let frame = frames[index]
                let shouldMeasure = itemsRequiringMeasurement.contains(itemIdentifiers[index])
                    || newestStart.contains(index)
                    || frame.intersects(expandedRect)
                guard shouldMeasure, !measuredIndices.contains(index) else { continue }
                heights[index] = height(for: itemIdentifiers[index], width: itemWidth, force: true)
                measuredIndices.insert(index)
            }
        }

        attributes.removeAll(keepingCapacity: true)
        let frames = makeFrames(heights: heights, width: width)
        for index in heights.indices {
            let indexPath = IndexPath(item: itemEntries[index].index, section: 0)
            let itemAttributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            itemAttributes.frame = frames[index]
            itemAttributes.zIndex = index
            attributes[indexPath] = itemAttributes
        }
        let height = frames.last?.maxY ?? 0
        contentSize = CGSize(width: collectionView.bounds.width, height: height + 18)
        preparedWidth = width
        itemsRequiringMeasurement.subtract(itemIdentifiers)
    }

    override var collectionViewContentSize: CGSize { contentSize }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes[indexPath]
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.values.filter { $0.frame.intersects(rect) }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        let widthChanged = abs(newBounds.width - preparedWidth) > 0.5
        guard !widthChanged else { return true }
        let viewportHeight = max(newBounds.height, 1)
        let expandedRect = newBounds.insetBy(dx: 0, dy: -viewportHeight)
        let itemWidth = itemWidth(for: newBounds.width)
        return attributes.contains { indexPath, itemAttributes in
            guard let item = itemIdentifier(at: indexPath) else { return false }
            return itemAttributes.frame.intersects(expandedRect)
                && !isMeasured(item, width: itemWidth)
        }
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        guard let collectionView,
              collectionView.numberOfSections > 0,
              abs(newBounds.width - preparedWidth) <= 0.5 else { return context }

        let itemWidth = itemWidth(for: newBounds.width)
        let firstVisibleIndex = attributes
            .sorted { $0.value.frame.minY < $1.value.frame.minY }
            .first { $0.value.frame.maxY > newBounds.minY }?.key.item ?? 0
        let margin = max(newBounds.height, 1)
        let measurementRect = newBounds.insetBy(dx: 0, dy: -margin)
        var contentOffsetAdjustment: CGFloat = 0
        var didMeasure = false
        for (indexPath, itemAttributes) in attributes where indexPath.item < firstVisibleIndex {
            guard itemAttributes.frame.intersects(measurementRect),
                  let item = itemIdentifier(at: indexPath),
                  !isMeasured(item, width: itemWidth) else { continue }
            let oldHeight = itemAttributes.frame.height
            let newHeight = height(for: item, width: itemWidth, force: true)
            contentOffsetAdjustment += newHeight - oldHeight
            didMeasure = true
        }
        if didMeasure {
            context.contentOffsetAdjustment.y += contentOffsetAdjustment
        }
        return context
    }

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        insertedIndexPaths = Set(updateItems.compactMap { updateItem in
            guard updateItem.updateAction == .insert else { return nil }
            return updateItem.indexPathAfterUpdate
        })
    }

    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard newestEndUpdate,
              anchorIsBottom,
              insertedIndexPaths.contains(itemIndexPath),
              let final = layoutAttributesForItem(at: itemIndexPath)?.copy() as? UICollectionViewLayoutAttributes
        else {
            return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
        }
        var frame = final.frame
        frame.size.height = 0
        frame.origin.y = final.frame.minY
        final.frame = frame
        final.alpha = 1
        return final
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        insertedIndexPaths.removeAll()
        newestEndUpdate = false
    }

    func anchoredContentOffset(for collectionView: UICollectionView) -> (y: CGFloat, reason: String)? {
        let inset = collectionView.adjustedContentInset
        let minimumY = -inset.top
        let maximumY = max(
            minimumY,
            collectionView.contentSize.height + inset.bottom - collectionView.bounds.height
        )
        let targetY: CGFloat
        let reason: String
        switch anchor {
        case .bottom:
            targetY = maximumY
            reason = "anchorBottom"
        case .item(let item, let distanceFromViewportTop):
            guard let indexPath = indexPath(for: item),
                  let itemAttributes = layoutAttributesForItem(at: indexPath) else { return nil }
            targetY = itemAttributes.frame.minY - inset.top - distanceFromViewportTop
            reason = "anchorItem"
        }
        return (min(max(targetY, minimumY), maximumY), reason)
    }

    private var anchorIsBottom: Bool {
        if case .bottom = anchor { return true }
        return false
    }

    private func itemIdentifier(at indexPath: IndexPath) -> TranscriptCollectionItem? {
        guard let dataSource = collectionView?.dataSource as?
            UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem> else { return nil }
        return dataSource.itemIdentifier(for: indexPath)
    }

    private func indexPath(for item: TranscriptCollectionItem) -> IndexPath? {
        guard let dataSource = collectionView?.dataSource as?
            UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem> else { return nil }
        return dataSource.indexPath(for: item)
    }

    private func height(
        for item: TranscriptCollectionItem,
        width: CGFloat,
        force: Bool
    ) -> CGFloat {
        let key = HeightKey(item: item, width: width)
        if let cached = measuredHeights[key] { return cached }
        guard force else { return 80 }
        let measured = max(0, heightProvider(item, width))
        measuredHeights[key] = measured
        return measured
    }

    private func isMeasured(_ item: TranscriptCollectionItem, width: CGFloat) -> Bool {
        measuredHeights[HeightKey(item: item, width: width)] != nil
    }

    private func itemWidth(for width: CGFloat) -> CGFloat {
        let extra = readableContentMaxWidth.isFinite
            ? max(0, width - readableContentMaxWidth) / 2
            : 0
        return max(0, width - (16 + extra) * 2)
    }

    private func makeFrames(heights: [CGFloat], width: CGFloat) -> [CGRect] {
        let extra = readableContentMaxWidth.isFinite
            ? max(0, width - readableContentMaxWidth) / 2
            : 0
        let horizontalInset = 16 + extra
        let itemWidth = itemWidth(for: width)
        var y: CGFloat = 18
        return heights.map { itemHeight in
            defer { y += itemHeight + 20 }
            return CGRect(x: horizontalInset, y: y, width: itemWidth, height: itemHeight)
        }
    }


    private func newestIndices(heights: [CGFloat], viewportHeight: CGFloat) -> Set<Int> {
        var result: Set<Int> = []
        var covered: CGFloat = 18
        for index in heights.indices.reversed() {
            result.insert(index)
            covered += heights[index] + 20
            if covered >= viewportHeight * 2 { break }
        }
        return result
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
        if let layout = uiView.collectionViewLayout as? TranscriptListLayout {
            layout.readableContentMaxWidth = self.readableContentMaxWidth
            if readableContentMaxWidthChanged {
                layout.invalidateLayout()
            }
        }
    }

    private func makeLayout(coordinator: Coordinator) -> UICollectionViewLayout {
        TranscriptListLayout { [weak coordinator] item, width in
            coordinator?.height(for: item, width: width) ?? 80
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        private struct SizingTraits: Equatable {
            let preferredContentSizeCategory: UIContentSizeCategory
            let horizontalSizeClass: UIUserInterfaceSizeClass
            let legibilityWeight: UILegibilityWeight
            let displayScale: CGFloat

            init(_ traits: UITraitCollection) {
                preferredContentSizeCategory = traits.preferredContentSizeCategory
                horizontalSizeClass = traits.horizontalSizeClass
                legibilityWeight = traits.legibilityWeight
                displayScale = traits.displayScale
            }
        }

        private weak var collectionView: TranscriptCollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<TranscriptCollectionSection, TranscriptCollectionItem>?
        private var currentItems: [TranscriptCollectionItem] = []
        private var currentContent: [TranscriptCollectionItem: TranscriptCollectionContent] = [:]
        private let sizingCell = TranscriptListCell(frame: .zero)
        private var sizingTraits: SizingTraits?
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
            sizingCell.isHidden = true
            sizingCell.isUserInteractionEnabled = false
            sizingCell.frame = CGRect(x: -1, y: -1, width: 1, height: 1)
            collectionView.addSubview(sizingCell)
            _ = updateSizingTraits(from: collectionView)
            collectionView.register(TranscriptListCell.self, forCellWithReuseIdentifier: "transcript-cell")
            collectionView.delegate = self
            collectionView.didFinishLayout = { [weak self] in
                self?.didFinishLayout()
            }
            collectionView.didChangeTraits = { [weak self] in
                self?.sizingTraitsDidChange()
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
                cell.clipsToBounds = true
                cell.contentConfiguration = self.contentConfiguration(for: item)
                #if DEBUG || CC_PERF
                TranscriptPerformance.shared.markFirstRows()
                #endif
                return cell
            }
        }

        func update(_ representable: TranscriptCollectionRepresentable) -> Bool {
            guard let collectionView = self.collectionView else { return false }
            if updateSizingTraits(from: collectionView),
               let layout = collectionView.collectionViewLayout as? TranscriptListLayout {
                layout.invalidateAllHeights()
            }
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
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
            updateAnchorAfterUserScroll(scrollView)
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
            updatePinAfterUserScroll(scrollView)
            #if DEBUG
            MotionTrace.shared.recordEvent("scrollToNewest", data: ["phase": "ran", "animated": true])
            #endif
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            (scrollView as? TranscriptCollectionView)?.isAnimatingJump = true
            return true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            if let collectionView = scrollView as? TranscriptCollectionView {
                collectionView.isAnimatingJump = false
            }
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
            if pinned,
               let layout = collectionView?.collectionViewLayout as? TranscriptListLayout {
                layout.anchor = .bottom
            }
            guard isPinnedToBottom != pinned else { return }
            isPinnedToBottom = pinned
            pinnedBinding.wrappedValue = pinned
        }

        private func updateAnchorAfterUserScroll(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? TranscriptCollectionView,
                  let layout = collectionView.collectionViewLayout as? TranscriptListLayout else { return }
            if isPinnedToBottom {
                layout.anchor = .bottom
                return
            }
            guard let dataSource,
                  let indexPath = collectionView.indexPathsForVisibleItems.min(by: {
                      collectionView.layoutAttributesForItem(at: $0)?.frame.minY ?? .greatestFiniteMagnitude
                          < collectionView.layoutAttributesForItem(at: $1)?.frame.minY ?? .greatestFiniteMagnitude
                  }),
                  let item = dataSource.itemIdentifier(for: indexPath),
                  let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
            let viewportTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            layout.anchor = .item(
                item,
                distanceFromViewportTop: attributes.frame.minY - viewportTop
            )
        }

        private func updatePinAfterUserScroll(_ scrollView: UIScrollView) {
            let inset = scrollView.adjustedContentInset
            let maxOffsetY = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
            setPinned(scrollView.contentOffset.y >= maxOffsetY - 36)
            updateAnchorAfterUserScroll(scrollView)
        }

        private func jumpToLatest() {
            guard let collectionView else { return }
            collectionView.isAnimatingJump = true
            #if DEBUG
            MotionTrace.shared.recordEvent("scrollToNewest", data: ["phase": "scheduled", "animated": true])
            #endif
            setPinned(true)
            collectionView.layoutIfNeeded()
            let inset = collectionView.adjustedContentInset
            let maxOffsetY = max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
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
            if let layout = collectionView.collectionViewLayout as? TranscriptListLayout {
                layout.invalidateHeights(for: inserted + changedItems)
                if animated { layout.prepareForAnimatedNewestEndUpdate() }
            }
            #if DEBUG
            MotionTrace.shared.recordEvent("snapshotApplied", data: [
                "inserted": inserted.map(traceID),
                "deleted": deleted.map(traceID),
                "reconfigured": changedItems.map(traceID),
                "animated": animated,
                "duration": animated ? 0.3 : 0,
            ])
            #endif
            let markApplied = { [weak self] in
                guard let self else { return }
                self.hasAppliedSnapshot = true
                self.maybeLoadEarlierIfNearTop()
            }
            if animated {
                UIView.animate(
                    withDuration: 0.3,
                    delay: 0,
                    options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
                    animations: {
                        dataSource.apply(snapshot, animatingDifferences: true)
                        collectionView.layoutIfNeeded()
                    },
                    completion: { _ in markApplied() }
                )
            } else {
                dataSource.apply(snapshot, animatingDifferences: false)
                collectionView.layoutIfNeeded()
                markApplied()
            }
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

        #if DEBUG
        private func recordMeasureMismatches(in collectionView: TranscriptCollectionView) {
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath),
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                      let item = dataSource?.itemIdentifier(for: indexPath) else { continue }
                let width = max(0, cell.contentView.bounds.width)
                let measuredHeight = cell.contentView.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height
                guard abs(measuredHeight - attributes.frame.height) > 1 else { continue }
                MotionTrace.shared.recordEvent("measureMismatch", data: [
                    "id": traceID(item),
                    "measuredHeight": measuredHeight,
                    "layoutHeight": attributes.frame.height,
                ])
            }
        }
        #endif

        private func didFinishLayout() {
            guard let collectionView, collectionView.window != nil,
                  collectionView.bounds.height > 0,
                  !(dataSource?.snapshot().itemIdentifiers.isEmpty ?? true),
                  collectionView.indexPathsForVisibleItems.isEmpty else { return }
            let now = Date()
            #if DEBUG
            if MotionTrace.shared.isEnabled {
                recordMeasureMismatches(in: collectionView)
            }
            #endif
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

        private func sizingTraitsDidChange() {
            guard let collectionView,
                  updateSizingTraits(from: collectionView),
                  let layout = collectionView.collectionViewLayout as? TranscriptListLayout else { return }
            layout.invalidateAllHeights()
        }

        private func updateSizingTraits(from collectionView: TranscriptCollectionView) -> Bool {
            let traits = collectionView.traitCollection
            let sizingTraits = SizingTraits(traits)
            sizingCell.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
            sizingCell.traitOverrides.horizontalSizeClass = traits.horizontalSizeClass
            sizingCell.traitOverrides.legibilityWeight = traits.legibilityWeight
            sizingCell.traitOverrides.displayScale = traits.displayScale
            let changed = self.sizingTraits != sizingTraits
            self.sizingTraits = sizingTraits
            return changed
        }

        fileprivate func height(for item: TranscriptCollectionItem, width: CGFloat) -> CGFloat {
            guard currentContent[item] != nil else { return 80 }
            sizingCell.clipsToBounds = true
            sizingCell.contentConfiguration = contentConfiguration(for: item)
            sizingCell.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
            sizingCell.contentView.bounds = sizingCell.bounds
            sizingCell.setNeedsLayout()
            sizingCell.layoutIfNeeded()
            let fittingSize = sizingCell.contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            return max(1, ceil(fittingSize.height))
        }

        private func contentConfiguration(for item: TranscriptCollectionItem) -> UIContentConfiguration {
            UIHostingConfiguration {
                self.hostedView(for: item)
            }
            .margins(.all, 0)
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
