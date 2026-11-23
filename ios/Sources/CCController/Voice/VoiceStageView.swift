import CCKit
import SwiftUI
import UIKit
import WebKit

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

/// One stage item: markdown, a mermaid diagram or an image the host serves.
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
        case .mermaid(let source):
            MermaidView(source: source)
                .accessibilityIdentifier("voice-stage-mermaid")
        case .image:
            StageImageView(stage: stage, store: store)
                .accessibilityIdentifier("voice-stage-image")
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
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                Text("The image couldn't be loaded.")
                    .foregroundStyle(.ccSecondary)
            } else {
                ProgressView()
            }
        }
        .task(id: stage.id) {
            guard let file = stage.imageFile else { failed = true; return }
            do {
                let downloaded = try await store.downloadFile(sessionID: file.sessionID, name: file.name)
                image = UIImage(data: downloaded.data)
                failed = image == nil
            } catch {
                failed = true
            }
        }
    }
}

/// Draws a mermaid diagram offline with the bundled mermaid.js, in the app's colours.
struct MermaidView: UIViewRepresentable {
    let source: String
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let script = MermaidScript.source {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.accessibilityIdentifier = "voice-stage-mermaid"
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let key = "\(colorScheme == .dark)|\(source)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        view.loadHTMLString(MermaidScript.page(source: source, dark: colorScheme == .dark), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedKey: String?
    }
}

enum MermaidScript {
    /// mermaid.js 12.3.0 (MIT), bundled in Resources/Mermaid.
    @MainActor static let source: String? = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    static func page(source: String, dark: Bool) -> String {
        let encoded = (try? String(data: JSONEncoder().encode(source), encoding: .utf8)) ?? "\"\""
        let background = dark ? "#0A0A09" : "#FFFFFF"
        let text = dark ? "#F6F3ED" : "#1D1C1A"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=4">
        <style>html,body{margin:0;padding:0;background:\(background);color:\(text);font:20px -apple-system,system-ui}
        #d{display:flex;justify-content:center;align-items:flex-start;padding:8px}#d svg{max-width:100%;height:auto}
        #e{white-space:pre-wrap;font:15px ui-monospace,monospace;color:\(text);padding:8px}</style></head>
        <body><div id="d"></div><div id="e"></div><script>
        (async () => {
          try {
            mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: '\(dark ? "dark" : "default")', fontSize: 18 });
            const { svg } = await mermaid.render('stage', \(encoded));
            document.getElementById('d').innerHTML = svg;
          } catch (error) {
            document.getElementById('e').textContent = \(encoded);
          }
        })();
        </script></body></html>
        """
    }
}
