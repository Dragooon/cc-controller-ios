import CCKit
import Foundation
import SwiftUI

private struct PromptBubbleLayout: Layout {
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
            at: CGPoint(x: bounds.maxX - bubbleSize.width, y: bounds.minY),
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

    private var promptText: String {
        CCKit.normalisePromptText(prompt.text ?? prompt.command).text
    }

    private var collapse: PromptCollapse {
        promptCollapse(promptText, hasPaste: prompt.paste != nil)
    }

    private var attachmentNames: [String] {
        prompt.attachments ?? CCKit.normalisePromptText(prompt.text ?? prompt.command).attachments
    }

    var body: some View {
        PromptBubbleLayout {
                VStack(alignment: .leading, spacing: 8) {
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
                .background(.ccBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(promptText)
        .accessibilityIdentifier(bubbleAccessibilityIdentifier)
    }
}
