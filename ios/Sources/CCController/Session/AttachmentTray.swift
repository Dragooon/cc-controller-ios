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
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    attachmentView(attachment)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
        }
        .scrollIndicators(.hidden)
        .frame(height: 70)
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
                removeButton(for: attachment, name: resourceName)
            }
            .frame(width: 56, height: 56)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(resourceName)
        case .file(let name):
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text")
                        .font(.subheadline)
                        .foregroundStyle(.ccSecondary)
                    Text(name)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.ccLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .frame(width: 154, height: 56)
                .background(.ccCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.ccSeparator, lineWidth: 0.5)
                }
                removeButton(for: attachment, name: name)
            }
            .frame(width: 154, height: 56)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(name)
        }
    }

    private func removeButton(for attachment: ComposerAttachment, name: String) -> some View {
        Button { onRemove(attachment) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.96), in: Circle())
                .overlay {
                    Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -6)
        .accessibilityLabel("Remove \(name)")
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
