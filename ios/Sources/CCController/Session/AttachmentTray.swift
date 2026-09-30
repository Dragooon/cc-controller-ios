import SwiftUI
import UIKit

struct ComposerAttachment: Identifiable {
    enum Content {
        case image(resourceName: String, progress: Double?)
        case file(name: String)
    }

    let id: String
    let content: Content
}

struct AttachmentTrayView: View {
    let attachments: [ComposerAttachment]
    let onRemove: (ComposerAttachment) -> Void

    init(attachments: [ComposerAttachment], onRemove: @escaping (ComposerAttachment) -> Void = { _ in }) {
        self.attachments = attachments
        self.onRemove = onRemove
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentView(attachment)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
        .frame(height: 56)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pending attachments")
    }

    @ViewBuilder
    private func attachmentView(_ attachment: ComposerAttachment) -> some View {
        switch attachment.content {
        case .image(let resourceName, let progress):
            ZStack(alignment: .topTrailing) {
                AttachmentImage(resourceName: resourceName)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .tint(.ccAccent)
                        .scaleEffect(0.85)
                        .frame(width: 56, height: 56)
                        .background(.ccBackground.opacity(0.38), in: .rect(cornerRadius: 10))
                }
                removeButton(for: attachment)
            }
            .frame(width: 56, height: 56)
            .accessibilityLabel(resourceName)
        case .file(let name):
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                Text(name)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.ccLabel)
                    .lineLimit(1)
                removeButton(for: attachment)
            }
            .padding(.leading, 10)
            .padding(.trailing, 3)
            .frame(height: 40)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(name)
        }
    }

    private func removeButton(for attachment: ComposerAttachment) -> some View {
        ZStack {
            Circle()
                .fill(.clear)
                .frame(width: 22, height: 22)
                .glassEffect(.regular, in: .circle)
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
            Button { onRemove(attachment) } label: {
                Color.clear
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .frame(width: 32, height: 32)
        .fixedSize()
    }
}

private struct AttachmentImage: View {
    let resourceName: String

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.ccCard
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.ccSecondary)
                    }
            }
        }
        .frame(width: 56, height: 56)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.ccSeparator, lineWidth: 0.5)
        }
    }

    private var image: UIImage? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
