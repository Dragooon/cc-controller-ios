import CCKit
import ImageIO
import SwiftUI
import UIKit

struct ComposerAttachment: Identifiable {
    enum State {
        case uploading(progress: Double)
        case attached
        case failed(reason: String)
    }

    let id: String
    let name: String
    let size: Int
    let isImage: Bool
    let thumbnailData: Data?
    let resourceName: String?
    let state: State
    let canRetry: Bool

    init(item: AttachmentItem) {
        id = item.id
        name = item.name
        size = item.size
        isImage = item.isImage
        thumbnailData = item.thumbnailData
        resourceName = nil
        canRetry = item.isRetryableFailure
        switch item.state {
        case .uploading(let progress): state = .uploading(progress: progress)
        case .attached: state = .attached
        case .failed(let error): state = .failed(reason: error.userMessage)
        }
    }

    #if DEBUG
    enum Content {
        case image(resourceName: String, progress: Double?)
        case file(name: String)
    }

    init(id: String, content: Content) {
        self.id = id
        switch content {
        case .image(let resourceName, let progress):
            name = resourceName
            size = 0
            isImage = true
            thumbnailData = nil
            self.resourceName = resourceName
            canRetry = false
            state = progress.map { .uploading(progress: $0) } ?? .attached
        case .file(let name):
            self.name = name
            size = 0
            isImage = false
            thumbnailData = nil
            resourceName = nil
            canRetry = false
            state = .attached
        }
    }
    #endif
}

@MainActor
private final class AttachmentThumbnailCache {
    private let images = NSCache<NSString, UIImage>()

    init() {
        images.countLimit = 32
    }

    func image(for attachmentID: String) -> UIImage? {
        images.object(forKey: attachmentID as NSString)
    }

    func insert(_ image: UIImage, for attachmentID: String) {
        images.setObject(image, forKey: attachmentID as NSString)
    }
}

struct AttachmentTrayView: View {
    let attachments: [ComposerAttachment]
    let notice: String?
    let onRemove: (String) -> Void
    let onRetry: (String) -> Void
    let pulseFailed: Bool
    @State private var thumbnailCache = AttachmentThumbnailCache()

    init(
        attachments: [ComposerAttachment],
        notice: String? = nil,
        pulseFailed: Bool = false,
        onRemove: @escaping (String) -> Void = { _ in },
        onRetry: @escaping (String) -> Void = { _ in }
    ) {
        self.attachments = attachments
        self.notice = notice
        self.onRemove = onRemove
        self.onRetry = onRetry
        self.pulseFailed = pulseFailed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(attachments) { attachment in
                        attachmentView(attachment)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 0)
            }
            .scrollIndicators(.hidden)
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                    .padding(.horizontal, 8)
            }
        }
        .frame(minHeight: notice == nil ? 70 : 88)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachment-tray")
        .accessibilityLabel("Pending attachments")
    }

    @ViewBuilder
    private func attachmentView(_ attachment: ComposerAttachment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topTrailing) {
                if attachment.isImage {
                    imageView(for: attachment)
                } else {
                    fileView(for: attachment)
                }
                removeButton(for: attachment)
            }
            if case .failed = attachment.state {
                Text(attachment.canRetry ? "Tap to retry" : "Too large (max 25 MB)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: 154, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.18)) { content in
            content.scaleEffect(pulseFailed && isFailed(attachment) ? 1.04 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(for: attachment))
        .accessibilityIdentifier("attachment-tile")
        .onTapGesture {
            if isFailed(attachment), attachment.canRetry { onRetry(attachment.id) }
        }
    }

    private func imageView(for attachment: ComposerAttachment) -> some View {
        thumbnailContent(for: attachment)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { progressOverlay(for: attachment) }
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.ccSeparator, lineWidth: 0.5) }
            .overlay(alignment: .bottomLeading) { failureBadge(for: attachment) }
    }

    @ViewBuilder
    private func thumbnailContent(for attachment: ComposerAttachment) -> some View {
        if let image = thumbnailImage(for: attachment) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Color.ccCard.overlay { Image(systemName: "photo").foregroundStyle(.ccSecondary) }
        }
    }

    private func thumbnailImage(for attachment: ComposerAttachment) -> UIImage? {
        if let image = thumbnailCache.image(for: attachment.id) { return image }

        let data: Data?
        if let thumbnailData = attachment.thumbnailData {
            data = thumbnailData
        } else if let resourceName = attachment.resourceName,
                  let url = Bundle.main.url(forResource: resourceName, withExtension: "png") {
            data = try? Data(contentsOf: url)
        } else {
            data = nil
        }
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 168,
              ] as CFDictionary) else { return nil }
        let thumbnail = UIImage(cgImage: image)
        thumbnailCache.insert(thumbnail, for: attachment.id)
        return thumbnail
    }

    private func fileView(for attachment: ComposerAttachment) -> some View {
        ZStack {
            HStack(spacing: 7) {
                Group {
                    if isFailed(attachment) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: fileSymbol(for: attachment.name))
                            .foregroundStyle(.ccSecondary)
                    }
                }
                .font(.subheadline)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name)
                        .font(.subheadline)
                        .foregroundStyle(.ccLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                    if attachment.size > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.ccSecondary)
                    }
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 32)
            progressOverlay(for: attachment)
        }
        .frame(width: 220, height: 56)
        .background(.ccCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.ccSeparator, lineWidth: 0.5) }
    }

    @ViewBuilder
    private func progressOverlay(for attachment: ComposerAttachment) -> some View {
        if case .uploading(let progress) = attachment.state {
            ZStack {
                Color.ccBackground.opacity(0.38)
                if progress >= 1 {
                    ProgressView()
                        .tint(.ccAccent)
                        .scaleEffect(0.85)
                } else {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .tint(.ccAccent)
                        .scaleEffect(0.85)
                }
            }
        }
    }

    @ViewBuilder
    private func failureBadge(for attachment: ComposerAttachment) -> some View {
        if case .failed = attachment.state, attachment.isImage {
            Circle()
                .fill(.red)
                .frame(width: 22, height: 22)
                .overlay { Image(systemName: "exclamationmark").font(.caption2.weight(.bold)).foregroundStyle(.white) }
                .padding(4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Attachment upload failed")
                .accessibilityIdentifier("attachment-failure-badge")
        }
    }

    private func removeButton(for attachment: ComposerAttachment) -> some View {
        Button { onRemove(attachment.id) } label: {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.96), in: Circle())
                .overlay { Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .offset(x: 6, y: -6)
        .accessibilityLabel("Remove \(attachment.name)")
    }

    private func isFailed(_ attachment: ComposerAttachment) -> Bool {
        if case .failed = attachment.state { return true }
        return false
    }

    private func accessibilityLabel(for attachment: ComposerAttachment) -> String {
        switch attachment.state {
        case .uploading(let progress):
            progress >= 1 ? "\(attachment.name), uploaded, waiting for server" : "\(attachment.name), uploading \(Int(progress * 100)) percent"
        case .attached: "\(attachment.name), attached"
        case .failed(let reason):
            attachment.canRetry
                ? "\(attachment.name), upload failed, double-tap to retry"
                : "\(attachment.name), upload failed, \(reason)"
        }
    }

    private func fileSymbol(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "csv", "xls", "xlsx": "tablecells"
        case "zip", "gz": "archivebox"
        default: "doc.text"
        }
    }
}
