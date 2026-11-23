import CCKit
import SwiftUI
import UIKit

/// Voice mode's screen. Expanded, the stage fills most of it with whatever the agent last showed, and a slim strip
/// carries the status, live captions and controls. Collapsed, only the strip shows, under the chat.
struct VoiceStageView: View {
    @Bindable var controller: VoiceModeController
    let store: AppStore
    let onExit: () -> Void

    private var expanded: Bool { controller.stageExpanded }

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                stageArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.tap() }
                    .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                        if value.translation.height > 80 { controller.stageExpanded = false }
                    })
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("voice-stage")
            }
            VoiceStripView(controller: controller, onExit: onExit)
        }
        .background(expanded ? Color.ccBackground : Color.clear)
    }

    @ViewBuilder
    private var stageArea: some View {
        if let stage = controller.stage {
            VStack(alignment: .leading, spacing: 16) {
                if !stage.title.isEmpty {
                    Text(stage.title)
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
                StageContentView(stage: stage, store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if controller.stageHistory.count > 1 {
                    StageHistoryStrip(history: controller.stageHistory, current: stage.id) { controller.show($0) }
                }
            }
            .padding(20)
            .id(stage.id)
        } else {
            VStack(spacing: 18) {
                Spacer()
                Text(conversationLine)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(controller.heardText.isEmpty ? Color.ccLabel : Color.ccSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 28)
                    .accessibilityIdentifier("voice-conversation-line")
                Spacer()
            }
        }
    }

    private var conversationLine: String {
        if !controller.heardText.isEmpty { return controller.heardText }
        if !controller.speakingText.isEmpty { return controller.speakingText }
        if case .failed(let message) = controller.phase { return message }
        return controller.phase.label
    }
}

/// The slim strip: status, captions, play/pause, replay, stage toggle and exit. Big enough to hit from a step away.
struct VoiceStripView: View {
    @Bindable var controller: VoiceModeController
    let onExit: () -> Void

    private var expanded: Bool { controller.stageExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                Text(controller.phase.label)
                    .font(.headline)
                    .foregroundStyle(.ccLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                    .accessibilityIdentifier("voice-status")
                Spacer()
                stripButton(controller.isPaused ? "play.fill" : "pause.fill", label: controller.isPaused ? "Resume" : "Pause", id: "voice-play-pause") {
                    controller.togglePause()
                }
                stripButton("arrow.counterclockwise", label: "Replay", id: "voice-replay") { controller.replay() }
                    .disabled(!controller.canReplay)
                stripButton(expanded ? "text.bubble" : "rectangle.inset.filled", label: expanded ? "Show chat" : "Show stage", id: "voice-stage-toggle") {
                    controller.stageExpanded.toggle()
                }
                stripButton("xmark", label: "End voice mode", id: "voice-exit", action: onExit)
            }
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.body)
                    .foregroundStyle(.ccSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("voice-caption")
            }
            if VoiceModeController.usesTestAudio {
                Button("Say test utterance") { controller.injectTestUtterance() }
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("voice-test-utterance")
            }
            if let notice = controller.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.ccAmberText)
                    .lineLimit(2)
                    .accessibilityIdentifier("voice-notice")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.ccCard)
        .clipShape(.rect(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-strip")
    }

    /// The expanded stage already shows the conversation in large type when nothing is on it.
    private var caption: String? {
        if expanded, controller.stage == nil { return nil }
        if !controller.heardText.isEmpty { return "You: \(controller.heardText)" }
        if !controller.speakingText.isEmpty { return controller.speakingText }
        return nil
    }

    private var statusColor: Color {
        switch controller.phase {
        case .listening: .ccGreen
        case .hearing, .sending: .ccBlue
        case .working: .ccAmber
        case .speaking: .ccAccent
        case .paused, .starting: .ccTertiary
        case .failed: .ccRed
        }
    }

    private func stripButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ccPressable)
        .foregroundStyle(.ccLabel)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// One stage item: markdown, or an image the host serves.
struct StageContentView: View {
    let stage: StageEntry
    let store: AppStore

    var body: some View {
        switch stage.content {
        case .markdown(let text):
            ScrollView {
                MarkdownView(markdown: text)
                    .font(.title3)
                    .accessibilityIdentifier("voice-stage-markdown")
            }
        case .image:
            StageImageView(stage: stage, store: store)
        }
    }
}

/// Earlier stage items, to swipe back through.
struct StageHistoryStrip: View {
    let history: [StageEntry]
    let current: String
    let select: (StageEntry) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(history) { item in
                    Button { select(item) } label: {
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .font(.footnote.weight(item.id == current ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(item.id == current ? Color.ccBubble : Color.ccCard, in: .capsule)
                    }
                    .buttonStyle(.ccPressable)
                    .foregroundStyle(.ccLabel)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-stage-history")
    }
}

struct StageImageView: View {
    let stage: StageEntry
    let store: AppStore
    @State private var image: UIImage?
    @State private var failure: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Exposed as a labelled element, not an image, so accessibility doesn't analyse the picture's
                    // contents on every query (a screenshot full of text made each one take seconds).
                    .accessibilityElement(children: .ignore)
                    .accessibilityRemoveTraits(.isImage)
                    .accessibilityLabel(stage.title.isEmpty ? "Image" : stage.title)
                    .accessibilityIdentifier("voice-stage-image-loaded")
            } else if let failure {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The image couldn't be loaded.")
                        .foregroundStyle(.ccSecondary)
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.ccTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("voice-stage-image-failed")
            } else {
                ProgressView()
                    .accessibilityIdentifier("voice-stage-image-loading")
            }
        }
        .task(id: stage.id) {
            guard let file = stage.imageFile else {
                failure = "No image address."
                return
            }
            do {
                let downloaded = try await store.downloadFile(sessionID: file.sessionID, name: file.name)
                if let decoded = UIImage(data: downloaded.data) {
                    image = decoded
                } else {
                    failure = "Not an image (\(downloaded.data.count) bytes, \(downloaded.mime ?? "no type"))."
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
