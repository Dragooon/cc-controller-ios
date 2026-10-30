import CCKit
import Foundation
import SwiftUI

private struct PromptBubbleLayout: Layout {
    /// Device and terminal prompts sit on the trailing edge; peer messages sit on the leading edge.
    var leading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let idealSize = subview.sizeThatFits(.unspecified)
        guard let rowWidth = proposal.width else { return idealSize }
        let bubbleWidth = min(idealSize.width, rowWidth * 0.85)
        let bubbleSize = subview.sizeThatFits(ProposedViewSize(width: bubbleWidth, height: proposal.height))
        return CGSize(width: rowWidth, height: bubbleSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let idealSize = subview.sizeThatFits(.unspecified)
        let bubbleWidth = min(idealSize.width, bounds.width * 0.85)
        let bubbleSize = subview.sizeThatFits(ProposedViewSize(width: bubbleWidth, height: bounds.height))
        subview.place(
            at: CGPoint(x: leading ? bounds.minX : bounds.maxX - bubbleSize.width, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(bubbleSize)
        )
    }
}

struct PromptBubble: View {
    let prompt: PromptEntry
    let sessionID: String
    let downloadFile: (@MainActor @Sendable (String) async throws -> URL)?
    let attachmentThumbnails: [String: Data]
    let bubbleAccessibilityIdentifier: String
    @State private var isExpanded = false

    init(
        prompt: PromptEntry,
        sessionID: String = "",
        downloadFile: (@MainActor @Sendable (String) async throws -> URL)? = nil,
        attachmentThumbnails: [String: Data] = [:],
        bubbleAccessibilityIdentifier: String = "prompt-bubble"
    ) {
        self.prompt = prompt
        self.sessionID = sessionID
        self.downloadFile = downloadFile
        self.attachmentThumbnails = attachmentThumbnails
        self.bubbleAccessibilityIdentifier = bubbleAccessibilityIdentifier
    }

    private var normalized: NormalizedPromptText {
        CCKit.normalisePromptText(prompt.text ?? prompt.command)
    }

    private var promptText: String { normalized.text }

    /// Named only for messages that came from a chat platform, so a read-only chat shows who wrote each one.
    private var chatSender: String? { peer == nil ? normalized.sender : nil }

    private var collapse: PromptCollapse {
        promptCollapse(promptText, hasPaste: prompt.paste != nil)
    }

    private var peer: PeerSender? { prompt.peerSender }

    private var attachmentNames: [String] {
        prompt.attachments ?? normalized.attachments
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let chatSender {
                Text(chatSender)
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                    .padding(.trailing, 6)
                    .accessibilityIdentifier("prompt-sender")
            }
            bubble
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var bubble: some View {
        PromptBubbleLayout(leading: peer != nil) {
            VStack(alignment: .leading, spacing: 8) {
                if let peer {
                    Label(peer.headerText, systemImage: "arrow.left.arrow.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("peer-message-header")
                }

                if !attachmentNames.isEmpty {
                    PromptAttachmentFlow(rowSpacing: 8) {
                        ForEach(attachmentNames, id: \.self) { name in
                            PromptAttachmentItemView(
                                sessionID: sessionID,
                                name: name,
                                initialData: attachmentThumbnails[name],
                                downloadFile: downloadFile
                            )
                        }
                    }
                }

                if let paste = prompt.paste {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                        Text("pasted, \(paste.lines ?? paste.text?.components(separatedBy: .newlines).count ?? 0) lines")
                    }
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ccCard, in: Capsule())
                }

                if !promptText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isExpanded ? promptText : collapse.visibleText)
                            .font(.body)
                            .foregroundStyle(.ccLabel)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)

                        if collapse.collapsed {
                            Button { isExpanded.toggle() } label: {
                                Text(isExpanded ? "Show less" : "Show more")
                                    .font(.footnote)
                                    .foregroundStyle(.ccAccent)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background {
                let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
                if peer != nil {
                    shape.strokeBorder(Color.ccSeparator, lineWidth: 1)
                } else {
                    shape.fill(Color.ccBubble)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(peer.map { "\($0.headerText). \(promptText)" } ?? chatSender.map { "\($0): \(promptText)" } ?? promptText)
        .accessibilityIdentifier(peer == nil ? bubbleAccessibilityIdentifier : "peer-message")
    }
}
