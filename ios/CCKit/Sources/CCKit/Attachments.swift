import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AttachmentNormalizerError: Error, Sendable, Equatable {
    case notAnImage
    case couldNotEncode
}

public enum AttachmentNormalizer {
    public static let maxImageEdge = 2048
    public static let maxFileBytes = 25 * 1024 * 1024

    public static func normalizeImage(
        data: Data,
        date: Date = .now,
        sequence: Int = 1
    ) throws -> UploadFile {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .image) == true else {
            throw AttachmentNormalizerError.notAnImage
        }

        let keepPNG = UTType(sourceType as String)?.conforms(to: .png) == true
        let outputType: CFString = keepPNG ? UTType.png.identifier as CFString : UTType.jpeg.identifier as CFString
        let image = downsampledImage(source: source)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType, 1, nil) else {
            throw AttachmentNormalizerError.couldNotEncode
        }
        if keepPNG {
            CGImageDestinationAddImage(destination, image, nil)
        } else {
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw AttachmentNormalizerError.couldNotEncode }

        let extensionName = keepPNG ? "png" : "jpg"
        let name = "photo-\(timestamp(date))-\(max(1, sequence)).\(extensionName)"
        return UploadFile(name: name, data: output as Data, mimeType: keepPNG ? "image/png" : "image/jpeg", isImage: true, thumbnailData: output as Data)
    }

    public static func prepareFile(data: Data, name: String, mimeType: String? = nil) -> UploadFile {
        let isImage = imageType(data: data) != nil
        return UploadFile(name: URL(fileURLWithPath: name).lastPathComponent, data: data, mimeType: mimeType ?? inferredMimeType(name), isImage: isImage, thumbnailData: isImage ? data : nil)
    }

    public static func isPNG(data: Data) -> Bool {
        guard let type = imageType(data: data) else { return false }
        return UTType(type as String)?.conforms(to: .png) == true
    }

    private static func imageType(data: Data) -> CFString? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .image) == true else { return nil }
        return type
    }

    private static func downsampledImage(source: CGImageSource) -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longEdge = max(width, height)
        guard longEdge > maxImageEdge,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxImageEdge,
            ] as CFDictionary) else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)!
        }
        return thumbnail
    }

    private static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0, components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
    }

    private static func inferredMimeType(_ name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "csv": "text/csv"
        case "json": "application/json"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }
}

public struct AttachmentItem: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case uploading(progress: Double)
        case attached(UploadedFile)
        case failed(ActionError)
    }

    public let id: String
    public let name: String
    public let data: Data
    public let mimeType: String?
    public let isImage: Bool
    public let thumbnailData: Data?
    public var state: State

    public init(id: String = UUID().uuidString, file: UploadFile, state: State = .uploading(progress: 0)) {
        self.id = id
        self.name = file.name
        self.data = file.data
        self.mimeType = file.mimeType
        self.isImage = file.isImage
        self.thumbnailData = file.thumbnailData
        self.state = state
    }

    public var size: Int { data.count }
}
