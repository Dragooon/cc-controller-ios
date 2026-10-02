import CCKit
import Foundation
import SwiftUI

struct PromptBubble: View {
    let prompt: PromptEntry
    let sessionID: String
    let downloadFile: (@MainActor @Sendable (String) async throws -> URL)?
    let attachmentThumbnails: [String: Data]
    let bubbleAccessibilityIdentifier: String
    @State private var isExpanded = false
    @State private var previewURL: URL?

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
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                if !attachmentNames.isEmpty {
                    PromptAttachmentFlow(rowSpacing: 8) {
                        ForEach(attachmentNames, id: \.self) { name in
                            PromptAttachmentItemView(
                                sessionID: sessionID,
                                name: name,
                                initialData: attachmentThumbnails[name],
                                downloadFile: downloadFile,
                                onPreview: { previewURL = $0 }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.85 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(promptText)
        .accessibilityIdentifier(bubbleAccessibilityIdentifier)
        .fullScreenCover(
            isPresented: Binding(
                get: { previewURL != nil },
                set: { if !$0 { previewURL = nil } }
            )
        ) {
            if let previewURL {
                QuickLookPreviewController(url: previewURL)
            }
        }
    }
}
