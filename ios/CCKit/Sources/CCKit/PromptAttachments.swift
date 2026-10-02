import Foundation

private let promptImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp"]

public func isImageAttachmentName(_ name: String) -> Bool {
    promptImageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
}

public func attachmentCacheKey(sessionID: String, name: String, targetPixelSize: Int = 192) -> String {
    "\(sessionID)\u{001F}\(name)\u{001F}\(targetPixelSize)"
}

public func fittedImageSize(
    pixelWidth: CGFloat,
    pixelHeight: CGFloat,
    maxWidth: CGFloat,
    maxHeight: CGFloat
) -> CGSize {
    guard pixelWidth.isFinite, pixelHeight.isFinite, maxWidth.isFinite, maxHeight.isFinite,
          pixelWidth > 0, pixelHeight > 0, maxWidth > 0, maxHeight > 0 else { return .zero }
    let scale = min(maxWidth / pixelWidth, maxHeight / pixelHeight)
    return CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
}
