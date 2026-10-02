import CCKit
import ImageIO
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class PromptAttachmentImageCache {
    static let shared = PromptAttachmentImageCache()

    private let images = NSCache<NSString, UIImage>()

    private init() {
        images.countLimit = 64
    }

    func image(sessionID: String, name: String) -> UIImage? {
        images.object(forKey: attachmentCacheKey(sessionID: sessionID, name: name) as NSString)
    }

    func insert(_ image: UIImage, sessionID: String, name: String) {
        images.setObject(image, forKey: attachmentCacheKey(sessionID: sessionID, name: name) as NSString)
    }

    func seed(data: Data, sessionID: String, name: String) {
        guard image(sessionID: sessionID, name: name) == nil,
              let image = downsampledImage(data: data) else { return }
        insert(image, sessionID: sessionID, name: name)
    }

    static func downsampledImage(data: Data, maxPixelSize: Int = 192) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func downsampledImage(data: Data) -> UIImage? {
        Self.downsampledImage(data: data)
    }
}

private enum PromptAttachmentImageState: String {
    case loading
    case loaded
    case unavailable
}

struct PromptAttachmentFlow: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
        return layout(in: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = layout(in: bounds.width, subviews: subviews)
        for placement in layout.placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, placements: [Placement]) {
        var rows: [[Placement]] = [[]]
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = rows[rows.count - 1].isEmpty ? size.width : rowWidth + spacing + size.width
            if nextWidth > width, !rows[rows.count - 1].isEmpty {
                totalHeight += rowHeight + rowSpacing
                rows.append([])
                rowWidth = 0
                rowHeight = 0
            }
            let x = rows[rows.count - 1].isEmpty ? 0 : rowWidth + spacing
            rows[rows.count - 1].append(Placement(index: index, x: x, y: totalHeight, size: size))
            rowWidth = x + size.width
            rowHeight = max(rowHeight, size.height)
        }

        totalHeight += rowHeight
        let placements = rows.flatMap { row in
            let usedWidth = row.last.map { $0.x + $0.size.width } ?? 0
            let offset = max(0, width - usedWidth)
            return row.map { placement in
                Placement(index: placement.index, x: placement.x + offset, y: placement.y, size: placement.size)
            }
        }
        return (CGSize(width: width, height: totalHeight), placements)
    }

    private struct Placement {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGSize
    }
}

struct PromptAttachmentItemView: View {
    let sessionID: String
    let name: String
    let initialData: Data?
    let downloadFile: (@MainActor @Sendable (String) async throws -> URL)?
    @State private var image: UIImage?
    @State private var downloadedURL: URL?
    @State private var previewURL: URL?
    @State private var imageState: PromptAttachmentImageState

    init(
        sessionID: String,
        name: String,
        initialData: Data? = nil,
        downloadFile: (@MainActor @Sendable (String) async throws -> URL)? = nil
    ) {
        self.sessionID = sessionID
        self.name = name
        self.initialData = initialData
        self.downloadFile = downloadFile
        _imageState = State(initialValue: isImageAttachmentName(name) ? .loading : .loaded)
    }

    private var isImage: Bool { isImageAttachmentName(name) }

    var body: some View {
        Button(action: open) {
            if isImage {
                imageTile
            } else {
                fileChip
            }
        }
        .buttonStyle(.plain)
        .frame(width: isImage ? 64 : nil, height: isImage ? 64 : nil, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityLabel("\(name), \(isImage ? "image" : "file")")
        .accessibilityValue(isImage ? imageState.rawValue : "loaded")
        .accessibilityIdentifier("prompt-attachment")
        .accessibilityAddTraits(.isButton)
        .quickLookPreview($previewURL)
        .task(id: attachmentCacheKey(sessionID: sessionID, name: name)) {
            await load()
        }
    }

    @ViewBuilder
    private var imageTile: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if imageState == .loading {
                Color.ccCard
                ProgressView()
                    .controlSize(.small)
            } else {
                Color.ccCard
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.ccSecondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.ccSeparator, lineWidth: 0.5) }
    }

    private var fileChip: some View {
        HStack(spacing: 7) {
            Image(systemName: promptFileSymbol(name: name))
                .foregroundStyle(.ccSecondary)
            Text(name)
                .font(.subheadline)
                .foregroundStyle(.ccLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 180, minHeight: 36)
        .background(.ccCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.ccSeparator, lineWidth: 0.5) }
    }

    @MainActor
    private func load() async {
        guard isImage else { return }
        let cache = PromptAttachmentImageCache.shared
        if let cached = cache.image(sessionID: sessionID, name: name) {
            image = cached
            imageState = .loaded
            return
        }
        if let initialData {
            cache.seed(data: initialData, sessionID: sessionID, name: name)
            if let seeded = cache.image(sessionID: sessionID, name: name) {
                image = seeded
                imageState = .loaded
                return
            }
        }
        guard let downloadFile else {
            imageState = .unavailable
            return
        }
        do {
            let url = try await downloadFile(name)
            guard let data = try? Data(contentsOf: url),
                  let decoded = PromptAttachmentImageCache.downsampledImage(data: data) else {
                imageState = .unavailable
                return
            }
            downloadedURL = url
            cache.insert(decoded, sessionID: sessionID, name: name)
            image = decoded
            imageState = .loaded
        } catch {
            imageState = .unavailable
        }
    }

    @MainActor
    private func open() {
        if let downloadedURL, FileManager.default.fileExists(atPath: downloadedURL.path) {
            present(downloadedURL)
            return
        }
        guard let downloadFile else { return }
        Task { @MainActor in
            do {
                let url = try await downloadFile(name)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    imageState = .unavailable
                    return
                }
                downloadedURL = url
                present(url)
            } catch {
                imageState = .unavailable
            }
        }
    }

    @MainActor
    private func present(_ url: URL) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.windows.first(where: \.isKeyWindow)?.endEditing(true)
        }
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            previewURL = url
        }
    }
}

struct RemoteFileImageTile: View {
    let entry: FileEntry
    let download: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    @State private var image: UIImage?
    @State private var unavailable = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if unavailable {
                Color.ccCard
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.ccSecondary)
            } else {
                Color.ccCard
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 220, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.ccSeparator, lineWidth: 0.5) }
        .task(id: attachmentCacheKey(sessionID: entry.sessionId ?? "", name: entry.name ?? "")) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        let name = entry.name ?? "download"
        let sessionID = entry.sessionId ?? ""
        let cache = PromptAttachmentImageCache.shared
        if let cached = cache.image(sessionID: sessionID, name: name) {
            image = cached
            return
        }
        guard let download else {
            unavailable = true
            return
        }
        do {
            let url = try await download(entry)
            guard let data = try? Data(contentsOf: url),
                  let decoded = PromptAttachmentImageCache.downsampledImage(data: data) else {
                unavailable = true
                return
            }
            cache.insert(decoded, sessionID: sessionID, name: name)
            image = decoded
        } catch {
            unavailable = true
        }
    }
}

func promptFileSymbol(name: String) -> String {
    switch URL(fileURLWithPath: name).pathExtension.lowercased() {
    case "pdf": "doc.richtext"
    case "csv", "xls", "xlsx": "tablecells"
    case "zip", "gz": "archivebox"
    default: "doc.text"
    }
}
