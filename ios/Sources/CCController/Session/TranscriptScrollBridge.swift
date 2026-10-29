import SwiftUI
import UIKit

struct UIKitScrollMetrics: Equatable {
    let contentHeight: CGFloat
    let boundsHeight: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    let offsetY: CGFloat
    let userInteracting: Bool
    let maxOffsetY: CGFloat
}

@MainActor
final class TranscriptScrollBridgeHandle {
    private weak var scrollView: UIScrollView?

    fileprivate func attach(to scrollView: UIScrollView) {
        self.scrollView = scrollView
    }

    fileprivate func detach(from scrollView: UIScrollView? = nil) {
        guard scrollView == nil || self.scrollView === scrollView else { return }
        self.scrollView = nil
    }

    func pinToBottom() {
        guard let scrollView else { return }
        let inset = scrollView.adjustedContentInset
        let maxOffsetY = max(
            -inset.top,
            scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        )
        guard abs(maxOffsetY - scrollView.contentOffset.y) > 0.5 else { return }
        let before = scrollView.contentOffset.y
        var offset = scrollView.contentOffset
        offset.y = maxOffsetY
        scrollView.setContentOffset(offset, animated: false)
        #if DEBUG
        MotionTrace.shared.recordPin(before: before, after: maxOffsetY, reason: "legacyBridge")
        #endif
    }
}

@MainActor
struct TranscriptScrollBridge: UIViewRepresentable {
    let handle: TranscriptScrollBridgeHandle
    let onMetrics: (UIKitScrollMetrics) -> Void
    let isPinned: () -> Bool

    func makeUIView(context: Context) -> BridgeView {
        BridgeView(handle: handle, onMetrics: onMetrics, isPinned: isPinned)
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        uiView.update(handle: handle, onMetrics: onMetrics, isPinned: isPinned)
    }

    @MainActor
    final class BridgeView: UIView {
        private var handle: TranscriptScrollBridgeHandle
        private var observedScrollView: UIScrollView?
        #if DEBUG
        private var motionRegistrationToken: UUID?
        #endif
        private var observations: [NSKeyValueObservation] = []
        private var retryScheduled = false
        private var metricsDeliveryPending = false
        private var onMetrics: (UIKitScrollMetrics) -> Void
        private var isPinned: () -> Bool

        init(
            handle: TranscriptScrollBridgeHandle,
            onMetrics: @escaping (UIKitScrollMetrics) -> Void,
            isPinned: @escaping () -> Bool
        ) {
            self.handle = handle
            self.onMetrics = onMetrics
            self.isPinned = isPinned
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            handle: TranscriptScrollBridgeHandle,
            onMetrics: @escaping (UIKitScrollMetrics) -> Void,
            isPinned: @escaping () -> Bool
        ) {
            self.isPinned = isPinned
            if self.handle !== handle {
                stopObserving()
                self.handle = handle
            }
            self.onMetrics = onMetrics
            attachIfPossible()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                stopObserving()
                return
            }
            attachIfPossible()
        }

        deinit {
            observations.removeAll()
        }

        private func attachIfPossible() {
            guard window != nil else { return }
            guard let scrollView = nearestScrollView() else {
                scheduleRetry()
                return
            }
            guard observedScrollView !== scrollView else {
                scheduleMetricsDelivery()
                return
            }

            stopObserving()
            observedScrollView = scrollView
            handle.attach(to: scrollView)
            #if DEBUG
            motionRegistrationToken = MotionTrace.shared.registerScrollView(scrollView, pinned: isPinned)
            #endif
            observations = [
                scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleMetricsDelivery()
                    }
                },
                scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleMetricsDelivery()
                    }
                },
                scrollView.observe(\.bounds, options: [.initial, .new]) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.scheduleMetricsDelivery()
                    }
                }
            ]
        }

        private func stopObserving() {
            observations.removeAll()
            #if DEBUG
            if let observedScrollView, let motionRegistrationToken {
                MotionTrace.shared.unregisterScrollView(observedScrollView, token: motionRegistrationToken)
            }
            motionRegistrationToken = nil
            #endif
            handle.detach(from: observedScrollView)
            observedScrollView = nil
            metricsDeliveryPending = false
        }

        private func scheduleRetry() {
            guard !retryScheduled else { return }
            retryScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                self.attachIfPossible()
            }
        }

        private func scheduleMetricsDelivery() {
            guard !metricsDeliveryPending else { return }
            metricsDeliveryPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.metricsDeliveryPending = false
                guard self.window != nil, let metrics = self.metrics() else { return }
                self.onMetrics(metrics)
            }
        }

        private func metrics() -> UIKitScrollMetrics? {
            guard let scrollView = observedScrollView, window != nil else { return nil }
            let inset = scrollView.adjustedContentInset
            let contentHeight = scrollView.contentSize.height
            let boundsHeight = scrollView.bounds.height
            return UIKitScrollMetrics(
                contentHeight: contentHeight,
                boundsHeight: boundsHeight,
                insetTop: inset.top,
                insetBottom: inset.bottom,
                offsetY: scrollView.contentOffset.y,
                userInteracting: scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating,
                maxOffsetY: max(-inset.top, contentHeight - boundsHeight + inset.bottom)
            )
        }

        private func nearestScrollView() -> UIScrollView? {
            var current = superview
            while let view = current {
                if let scrollView = view as? UIScrollView { return scrollView }
                current = view.superview
            }
            return nil
        }
    }
}
