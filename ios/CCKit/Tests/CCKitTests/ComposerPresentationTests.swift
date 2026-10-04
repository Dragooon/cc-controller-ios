import XCTest
@testable import CCKit

final class ComposerPresentationTests: XCTestCase {
    func testSuccessfulSendClearsOriginalTextWithWhitespace() {
        XCTAssertEqual(
            composerTextAfterSuccessfulSend(
                originalText: "fix this ",
                submittedText: "fix this",
                currentText: "fix this "
            ),
            ""
        )
        XCTAssertEqual(
            composerTextAfterSuccessfulSend(
                originalText: "  hello",
                submittedText: "hello",
                currentText: "  hello"
            ),
            ""
        )
    }

    func testSuccessfulSendClearsCurrentTextThatOnlyDiffersByWhitespace() {
        XCTAssertEqual(
            composerTextAfterSuccessfulSend(
                originalText: "fix this",
                submittedText: "fix this",
                currentText: "fix this\n"
            ),
            ""
        )
    }

    func testSuccessfulSendKeepsTextAddedDuringSendAfterOriginalPrefix() {
        XCTAssertEqual(
            composerTextAfterSuccessfulSend(
                originalText: "fix this",
                submittedText: "fix this",
                currentText: "fix this \n while sending"
            ),
            "while sending"
        )
    }

    func testSuccessfulSendLeavesIndependentlyEditedTextUnchanged() {
        XCTAssertNil(
            composerTextAfterSuccessfulSend(
                originalText: "fix this",
                submittedText: "fix this",
                currentText: "please review this instead"
            )
        )
    }
}
