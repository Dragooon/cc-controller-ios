import Foundation
import XCTest
@testable import CCKit

final class PromptAttachmentTests: XCTestCase {
    func testNormalisePromptTextExtractsBasenamesFromInboxPaths() {
        let value = """
        Inspect these files

        Attached files:
        - /Users/me/.local/state/inbox/long-session/attachment.png
        - /Users/me/.local/state/inbox/long-session/evidence.csv
        """

        let result = normalisePromptText(value)

        XCTAssertEqual(result.text, "Inspect these files")
        XCTAssertEqual(result.attachments, ["attachment.png", "evidence.csv"])
    }

    func testNormalisePromptTextStripsStockadeWrappersAndKeepsChatSenders() {
        let fromApp = "[platform: session start]\nWhere: app\n[/platform]\n[sender: sam | via: app]\nLook at this\n\n"
            + "Attached files saved to your workspace:\n- /home/sam/workspace/tmp/attachments/1/photo.png (image/png, 1234 bytes)\n\n"
            + "You can read, analyze, or process these files using your tools (Read, Bash, etc.)."
        XCTAssertEqual(normalisePromptText(fromApp), NormalizedPromptText(text: "Look at this", attachments: ["photo.png"]))

        let fromChat = normalisePromptText("[sender: sam | discord name: Sam | discord id: 1]\nhello")
        XCTAssertEqual(fromChat, NormalizedPromptText(text: "hello", attachments: [], sender: "sam"))
        XCTAssertEqual(entryFields(.prompt(PromptEntry(text: "[sender: sam | discord name: Sam | discord id: 1]\nhello"))).sender, "sam")
    }

    func testImageAttachmentClassificationIsCaseInsensitiveAndExtensionBased() {
        XCTAssertTrue(isImageAttachmentName("attachment.PNG"))
        XCTAssertTrue(isImageAttachmentName("photo.jpeg"))
        XCTAssertTrue(isImageAttachmentName("photo.HEIC"))
        XCTAssertTrue(isImageAttachmentName("photo.webp"))
        XCTAssertFalse(isImageAttachmentName("evidence.csv"))
        XCTAssertFalse(isImageAttachmentName("photo.png.txt"))
    }

    func testQueuedNoteCarriesAttachmentNamesAndThumbnailData() throws {
        let note = QueuedNote(
            text: "Inspect these files",
            queued: true,
            attachments: ["attachment.png", "evidence.csv"],
            attachmentThumbnails: ["attachment.png": Data([1, 2, 3])]
        )

        let encoded = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(QueuedNote.self, from: encoded)

        XCTAssertEqual(decoded.attachments, ["attachment.png", "evidence.csv"])
        XCTAssertEqual(decoded.attachmentThumbnails["attachment.png"], Data([1, 2, 3]))
    }

    func testAttachmentCacheKeyIncludesSessionNameAndTargetSize() {
        XCTAssertEqual(
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png", targetPixelSize: 192),
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png", targetPixelSize: 192)
        )
        XCTAssertNotEqual(
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png", targetPixelSize: 192),
            attachmentCacheKey(sessionID: "session-2", name: "attachment.png", targetPixelSize: 192)
        )
        XCTAssertNotEqual(
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png", targetPixelSize: 192),
            attachmentCacheKey(sessionID: "session-1", name: "evidence.csv", targetPixelSize: 192)
        )
        XCTAssertNotEqual(
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png", targetPixelSize: 192),
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png", targetPixelSize: 840)
        )
    }

    func testFittedImageSizeHandlesPortraitLandscapeAndSquareImages() {
        let portrait = fittedImageSize(pixelWidth: 277, pixelHeight: 600, maxWidth: 220, maxHeight: 280)
        XCTAssertEqual(portrait.width, 277.0 * 280.0 / 600.0, accuracy: 0.001)
        XCTAssertEqual(portrait.height, 280, accuracy: 0.001)

        let landscape = fittedImageSize(pixelWidth: 600, pixelHeight: 277, maxWidth: 220, maxHeight: 280)
        XCTAssertEqual(landscape.width, 220, accuracy: 0.001)
        XCTAssertEqual(landscape.height, 277.0 * 220.0 / 600.0, accuracy: 0.001)

        let square = fittedImageSize(pixelWidth: 100, pixelHeight: 100, maxWidth: 220, maxHeight: 280)
        XCTAssertEqual(square.width, 220, accuracy: 0.001)
        XCTAssertEqual(square.height, 220, accuracy: 0.001)
    }

    func testFittedImageSizeRejectsZeroAndInvalidSizes() {
        XCTAssertEqual(fittedImageSize(pixelWidth: 0, pixelHeight: 100, maxWidth: 220, maxHeight: 280), .zero)
        XCTAssertEqual(fittedImageSize(pixelWidth: 100, pixelHeight: 100, maxWidth: 0, maxHeight: 280), .zero)
        XCTAssertEqual(fittedImageSize(pixelWidth: .nan, pixelHeight: 100, maxWidth: 220, maxHeight: 280), .zero)
        XCTAssertEqual(fittedImageSize(pixelWidth: 100, pixelHeight: .infinity, maxWidth: 220, maxHeight: 280), .zero)
    }
}
