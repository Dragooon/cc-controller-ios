import CCKit
import Foundation
import SwiftUI

struct TranscriptReadinessGate<Content: View>: View {
    let readiness: TranscriptReadiness
    let onSyncingAppear: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingTranscript: Bool

    init(
        readiness: TranscriptReadiness,
        onSyncingAppear: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.readiness = readiness
        self.onSyncingAppear = onSyncingAppear
        self.content = content
        _showingTranscript = State(initialValue: readiness == .ready)
    }

    var body: some View {
        ZStack {
            if showingTranscript {
                content()
                    .transition(.opacity)
            } else {
                TranscriptSyncingView(isReady: readiness == .ready) {
                    revealTranscript()
                }
                .onAppear(perform: onSyncingAppear)
                .transition(.opacity)
            }
        }
    }

    private func revealTranscript() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            showingTranscript = true
        }
    }
}

struct TranscriptSyncingView: View {
    let isReady: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase = .waiting
    @State private var glyphShownAt: Date?
    @State private var timingTask: Task<Void, Never>?

    private enum Phase {
        case waiting
        case glyph
    }

    init(isReady: Bool = false, onFinished: @escaping () -> Void = {}) {
        self.isReady = isReady
        self.onFinished = onFinished
    }

    var body: some View {
        ZStack {
            if phase == .glyph {
                SpinnerGlyph(active: true, frozen: reduceMotion)
                    .font(.system(size: 30))
                    .frame(width: 42, height: 42)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading messages")
                    .accessibilityIdentifier("session-loading")
                    .transition(.opacity)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ccBackground)
        .onAppear(perform: start)
        .onChange(of: isReady) { _, ready in
            guard ready else { return }
            finishWhenAllowed()
        }
        .onDisappear {
            timingTask?.cancel()
            timingTask = nil
        }
    }

    private func start() {
        guard phase == .waiting else { return }
        guard !isReady else {
            onFinished()
            return
        }

        timingTask?.cancel()
        timingTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled, !isReady else { return }
            glyphShownAt = Date()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                phase = .glyph
            }
            scheduleMinimumVisibility()
        }
    }

    private func finishWhenAllowed() {
        switch phase {
        case .waiting:
            timingTask?.cancel()
            timingTask = nil
            onFinished()
        case .glyph:
            scheduleMinimumVisibility()
        }
    }

    private func scheduleMinimumVisibility() {
        guard let glyphShownAt else { return }
        let elapsed = Date().timeIntervalSince(glyphShownAt)
        let remainingMilliseconds = max(0, Int(ceil((0.35 - elapsed) * 1_000)))
        timingTask?.cancel()
        timingTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(remainingMilliseconds))
            } catch {
                return
            }
            timingTask = nil
            guard !Task.isCancelled, isReady else { return }
            onFinished()
        }
    }
}
