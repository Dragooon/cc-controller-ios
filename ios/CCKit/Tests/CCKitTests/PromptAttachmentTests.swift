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

    func testAttachmentCacheKeyIncludesSessionAndName() {
        XCTAssertEqual(
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png"),
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png")
        )
        XCTAssertNotEqual(
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png"),
            attachmentCacheKey(sessionID: "session-2", name: "attachment.png")
        )
        XCTAssertNotEqual(
            attachmentCacheKey(sessionID: "session-1", name: "attachment.png"),
            attachmentCacheKey(sessionID: "session-1", name: "evidence.csv")
        )
    }
}
