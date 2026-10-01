import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CCKit

final class AttachmentTests: XCTestCase {
    func testPNGIsKeptAndPhotoNameIsGenerated() throws {
        let data = try imageData(type: UTType.png.identifier as CFString, width: 20, height: 10)
        let file = try AttachmentNormalizer.normalizeImage(data: data, date: Date(timeIntervalSince1970: 1_735_689_600), sequence: 2)
        XCTAssertTrue(file.name.hasPrefix("photo-20250101-000000-2"))
        XCTAssertEqual(file.mimeType, "image/png")
        XCTAssertTrue(AttachmentNormalizer.isPNG(data: file.data))
        XCTAssertEqual(pixelSize(file.data).width, 20)
    }

    func testJPEGIsConvertedAndLongEdgeIsCapped() throws {
        let data = try imageData(type: UTType.jpeg.identifier as CFString, width: 3000, height: 1000)
        let file = try AttachmentNormalizer.normalizeImage(data: data, sequence: 1)
        XCTAssertEqual(file.mimeType, "image/jpeg")
        XCTAssertTrue(file.name.hasSuffix(".jpg"))
        let size = pixelSize(file.data)
        XCTAssertEqual(size.width, 2048)
        XCTAssertEqual(size.height, 683)
    }

    func testFilesKeepOriginalBasename() {
        let file = AttachmentNormalizer.prepareFile(data: Data([1, 2]), name: "/tmp/report.csv", mimeType: "text/csv")
        XCTAssertEqual(file.name, "report.csv")
        XCTAssertEqual(file.mimeType, "text/csv")
        XCTAssertFalse(file.isImage)
    }

    func testTooLargeFailureIsNotRetryableAndCaptionReflectsRetryability() {
        let tooLarge = AttachmentItem(
            file: UploadFile(name: "too-large.bin", data: Data([1])),
            state: .failed(.tooLarge(fileName: "too-large.bin", limitBytes: AttachmentNormalizer.maxFileBytes))
        )
        XCTAssertFalse(tooLarge.isRetryableFailure)
        XCTAssertEqual(AttachmentItem.sendBlockedCaption(for: [tooLarge]), "Remove the file that is too large")

        let retryable = AttachmentItem(
            file: UploadFile(name: "failed.png", data: Data([1]), isImage: true),
            state: .failed(.server(status: 500, message: "upload failed"))
        )
        XCTAssertTrue(retryable.isRetryableFailure)
        XCTAssertEqual(AttachmentItem.sendBlockedCaption(for: [tooLarge, retryable]), "Remove or retry the failed attachment")
    }

    private func imageData(type: CFString, width: Int, height: Int) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw AttachmentNormalizerError.couldNotEncode }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else { throw AttachmentNormalizerError.couldNotEncode }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentNormalizerError.couldNotEncode }
        _ = image
        return data as Data
    }

    private func pixelSize(_ data: Data) -> (width: Int, height: Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return (properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int)
    }
}
