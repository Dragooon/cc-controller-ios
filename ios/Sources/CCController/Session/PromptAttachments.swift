import CCKit
import ImageIO
import SwiftUI
import UIKit

@MainActor
final class PromptAttachmentImageCache {
    static let shared = PromptAttachmentImageCache()

    private let images = NSCache<NSString, UIImage>()
    /// Pixel sizes outlive the images, so a re-measured row keeps its loaded size.
    private var pixelSizes: [String: CGSize] = [:]

    private init() {
        images.countLimit = 64
    }

    func image(sessionID: String, name: String, targetPixelSize: Int) -> UIImage? {
        images.object(forKey: attachmentCacheKey(sessionID: sessionID, name: name, targetPixelSize: targetPixelSize) as NSString)
    }

    func insert(_ image: UIImage, sessionID: String, name: String, targetPixelSize: Int) {
        images.setObject(image, forKey: attachmentCacheKey(sessionID: sessionID, name: name, targetPixelSize: targetPixelSize) as NSString)
        if let cgImage = image.cgImage {
            pixelSizes["\(sessionID)/\(name)"] = CGSize(width: cgImage.width, height: cgImage.height)
        }
    }

    func pixelSize(sessionID: String, name: String) -> CGSize? {
        pixelSizes["\(sessionID)/\(name)"]
    }
}

enum PromptAttachmentImageDecoder {
    static func decode(data: Data, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            downsampledCGImage(data: data, maxPixelSize: maxPixelSize)
        }.value
    }

    static func load(from url: URL, maxPixelSize: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return downsampledCGImage(data: data, maxPixelSize: maxPixelSize)
        }.value
    }

    private static func downsampledCGImage(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { return nil }
        return image
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
        var placements: [Placement] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let isFirstInRow = rowWidth == 0
            let nextWidth = isFirstInRow ? size.width : rowWidth + spacing + size.width
            if nextWidth > width, !isFirstInRow {
                widestRowWidth = max(widestRowWidth, rowWidth)
                totalHeight += rowHeight + rowSpacing
                rowWidth = 0
                rowHeight = 0
            }
            let x = rowWidth == 0 ? 0 : rowWidth + spacing
            placements.append(Placement(index: index, x: x, y: totalHeight, size: size))
            rowWidth = x + size.width
            rowHeight = max(rowHeight, size.height)
        }

        widestRowWidth = max(widestRowWidth, rowWidth)
        totalHeight += rowHeight
        return (CGSize(width: widestRowWidth, height: totalHeight), placements)
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
    @Environment(\.openFilePreview) private var openFilePreview
    @State private var image: UIImage?
    @State private var downloadedURL: URL?
    @State private var imageState: PromptAttachmentImageState
    @State private var isDownloading = false
    @State private var errorMessage: String?

    private let targetPixelSize = 192

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
        .disabled(downloadFile == nil || isDownloading)
        .frame(width: isImage ? 64 : nil, height: isImage ? 64 : nil, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityLabel("\(name), \(isImage ? "image" : "file")")
        .accessibilityValue(isImage ? imageState.rawValue : "loaded")
        .accessibilityIdentifier("prompt-attachment")
        .accessibilityAddTraits(.isButton)
        .alert(
            "Couldn't open file",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The file could not be downloaded.")
        }
        .task(id: attachmentCacheKey(sessionID: sessionID, name: name, targetPixelSize: targetPixelSize)) {
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
        if let cached = cache.image(sessionID: sessionID, name: name, targetPixelSize: targetPixelSize) {
            image = cached
            imageState = .loaded
            return
        }
        if let initialData,
           let decoded = await PromptAttachmentImageDecoder.decode(data: initialData, maxPixelSize: targetPixelSize) {
            let image = UIImage(cgImage: decoded)
            cache.insert(image, sessionID: sessionID, name: name, targetPixelSize: targetPixelSize)
            self.image = image
            imageState = .loaded
            return
        }
        guard let downloadFile else {
            imageState = .unavailable
            return
        }
        do {
            let url = try await downloadFile(name)
            guard let decoded = await PromptAttachmentImageDecoder.load(from: url, maxPixelSize: targetPixelSize) else {
                imageState = .unavailable
                return
            }
            let image = UIImage(cgImage: decoded)
            downloadedURL = url
            cache.insert(image, sessionID: sessionID, name: name, targetPixelSize: targetPixelSize)
            self.image = image
            imageState = .loaded
        } catch {
            imageState = .unavailable
        }
    }

    @MainActor
    private func open() {
        guard !isDownloading else { return }
        if let downloadedURL, FileManager.default.fileExists(atPath: downloadedURL.path) {
            openFilePreview(downloadedURL)
            return
        }
        guard let downloadFile else { return }
        isDownloading = true
        Task { @MainActor in
            do {
                let url = try await downloadFile(name)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    if isImage { imageState = .unavailable }
                    throw NSError(
                        domain: "PromptAttachment",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The downloaded file was not available."]
                    )
                }
                downloadedURL = url
                openFilePreview(url)
            } catch {
                if isImage { imageState = .unavailable }
                errorMessage = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

struct RemoteFileImageTile: View {
    let entry: FileEntry
    let download: (@MainActor @Sendable (FileEntry) async throws -> URL)?
    /// The transcript row's key, so the row is measured again once the image's real size is known.
    var heightKey: String? = nil
    @State private var image: UIImage?
    @State private var imagePixelSize: CGSize?
    @State private var unavailable = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.transcriptExpansion) private var transcriptExpansion

    private let placeholderSize = CGSize(width: 220, height: 160)
    private var targetPixelSize: Int { Int(ceil(280 * displayScale)) }

    /// The sizing cell never loads the image, so it reads the size an earlier load cached.
    private var knownPixelSize: CGSize? {
        imagePixelSize
            ?? PromptAttachmentImageCache.shared.pixelSize(sessionID: entry.sessionId ?? "", name: entry.name ?? "download")
    }

    private var tileSize: CGSize {
        guard let imagePixelSize = knownPixelSize else { return placeholderSize }
        return fittedImageSize(
            pixelWidth: imagePixelSize.width,
            pixelHeight: imagePixelSize.height,
            maxWidth: 220,
            maxHeight: 280
        )
    }

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
        .frame(width: tileSize.width, height: tileSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.ccSeparator, lineWidth: 0.5) }
        .accessibilityIdentifier("agent-file-image")
        .task(id: attachmentCacheKey(
            sessionID: entry.sessionId ?? "",
            name: entry.name ?? "",
            targetPixelSize: targetPixelSize
        )) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        let name = entry.name ?? "download"
        let sessionID = entry.sessionId ?? ""
        let cache = PromptAttachmentImageCache.shared
        if let cached = cache.image(sessionID: sessionID, name: name, targetPixelSize: targetPixelSize) {
            image = cached
            imagePixelSize = cached.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            return
        }
        guard let download else {
            unavailable = true
            return
        }
        do {
            let url = try await download(entry)
            guard let decoded = await PromptAttachmentImageDecoder.load(from: url, maxPixelSize: targetPixelSize) else {
                unavailable = true
                return
            }
            let image = UIImage(cgImage: decoded)
            let measuredSize = tileSize
            cache.insert(image, sessionID: sessionID, name: name, targetPixelSize: targetPixelSize)
            self.image = image
            imagePixelSize = CGSize(width: decoded.width, height: decoded.height)
            if let heightKey, tileSize != measuredSize {
                transcriptExpansion?.heightChanged(for: heightKey)
            }
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
