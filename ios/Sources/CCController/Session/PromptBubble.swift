import CCKit
import SwiftUI

struct PromptBubble: View {
    let prompt: PromptEntry
    @State private var isExpanded = false

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
                    HStack(spacing: 8) {
                        ForEach(Array(attachmentNames.enumerated()), id: \.offset) { _, name in
                            MockImageThumbnail(
                                resourceName: "judge-alignment",
                                contentMode: .fill,
                                maxWidth: 64,
                                maxHeight: 64,
                                cornerRadius: 10
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
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.85 }
        }
    }
}
