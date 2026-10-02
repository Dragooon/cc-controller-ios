import Foundation

private let promptImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp"]

public func isImageAttachmentName(_ name: String) -> Bool {
    promptImageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
}

public func attachmentCacheKey(sessionID: String, name: String) -> String {
    "\(sessionID)\u{001F}\(name)"
}
