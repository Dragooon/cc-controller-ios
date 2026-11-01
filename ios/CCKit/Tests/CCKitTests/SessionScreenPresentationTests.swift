import XCTest
@testable import CCKit

final class SessionScreenPresentationTests: XCTestCase {
    private let commands = defaultSlashCommands.map(\.command)

    private func suggestions(_ text: String) -> [String] {
        slashSuggestions(text: text, commands: commands, name: { $0 })
    }

    func testSlashSuggestionsMatchTheFirstWordTyped() {
        let matches = suggestions("/co")
        XCTAssertTrue(matches.contains("/compact"))
        XCTAssertTrue(matches.contains("/cost"))
        XCTAssertFalse(matches.contains("/clear"))
        XCTAssertEqual(suggestions("/CO"), matches, "Matching ignores case")
        XCTAssertEqual(suggestions("/compact now"), ["/compact"], "Only the first word matches")
    }

    func testSlashSuggestionsNeedALeadingSlash() {
        XCTAssertEqual(suggestions("compact"), [])
        XCTAssertEqual(suggestions(""), [])
        XCTAssertEqual(suggestions(" /compact"), [])
    }

    func testSlashSuggestionFillsTheComposerExceptModel() {
        XCTAssertEqual(slashSuggestionAction(command: "/compact"), .fillComposer("/compact "))
        XCTAssertEqual(slashSuggestionAction(command: "/rename"), .fillComposer("/rename "))
        XCTAssertEqual(slashSuggestionAction(command: "/model"), .openModelSheet)
    }

    func testPendingNoteStatusTextForEachState() {
        XCTAssertEqual(pendingNoteStatusText(.sending), "Sending…")
        XCTAssertEqual(pendingNoteStatusText(.sent), "Sent")
        XCTAssertEqual(pendingNoteStatusText(.queued), "Queued")
        XCTAssertEqual(pendingNoteStatusText(.failed(message: "offline")), "Not sent · Tap to retry")
    }

    func testPendingNoteActionsForEachState() {
        XCTAssertEqual(pendingNoteActions(state: .sending, needsAttention: false), [])
        XCTAssertEqual(pendingNoteActions(state: .failed(message: "offline"), needsAttention: false), [.retry, .edit, .delete])
        XCTAssertEqual(pendingNoteActions(state: .queued, needsAttention: false), [.copy, .edit, .dismiss])
        XCTAssertEqual(pendingNoteActions(state: .sent, needsAttention: false), [.copy, .edit, .dismiss])
        XCTAssertEqual(pendingNoteActions(state: .sent, needsAttention: true), [.copy, .sendAgain, .edit, .dismiss])
        XCTAssertEqual(pendingNoteActions(state: .queued, needsAttention: true), [.copy, .sendAgain, .edit, .dismiss])
    }

    func testSendBlockedByAnAttachmentRaisesNoAlert() {
        XCTAssertFalse(shouldPresentSendError(.invalid("Remove or retry the failed attachment")))
        XCTAssertFalse(shouldPresentSendError(.invalid("Remove the file that is too large")))
        XCTAssertTrue(shouldPresentSendError(.invalid("Message text is required.")))
        XCTAssertTrue(shouldPresentSendError(.unauthorized))
        XCTAssertTrue(shouldPresentSendError(.server(status: 500, message: "boom")))
    }

    func testAttachmentAccessibilityLabelForEachState() {
        XCTAssertEqual(attachmentAccessibilityLabel(name: "a.png", state: .uploading(progress: 0.5)), "a.png, uploading 50 percent")
        XCTAssertEqual(attachmentAccessibilityLabel(name: "a.png", state: .uploading(progress: 1)), "a.png, uploaded, waiting for server")
        XCTAssertEqual(attachmentAccessibilityLabel(name: "a.png", state: .attached), "a.png, attached")
        XCTAssertEqual(
            attachmentAccessibilityLabel(name: "a.png", state: .failed(reason: "Offline", canRetry: true)),
            "a.png, upload failed, double-tap to retry"
        )
        XCTAssertEqual(
            attachmentAccessibilityLabel(name: "a.bin", state: .failed(reason: "Too large (max 25 MB)", canRetry: false)),
            "a.bin, upload failed, Too large (max 25 MB)"
        )
    }

    func testApprovalsElsewhereExcludesTheOpenSessionAndSpansControllers() throws {
        let mac = try XCTUnwrap(ControllerID(rawValue: "mac"))
        let mustafar = try XCTUnwrap(ControllerID(rawValue: "mustafar"))
        let selected = SessionRef(controllerID: mac, sessionID: "open")
        let count = approvalsElsewhereCount(
            approvals: [
                (mac, [
                    Approval(requestId: "1", sessionId: "open", toolName: "Bash"),
                    Approval(requestId: "2", sessionId: "other", toolName: "Bash"),
                    Approval(requestId: "3", sessionId: "other", toolName: "Read"),
                    Approval(requestId: "4", sessionId: nil, toolName: "Bash"),
                ]),
                // The same session ID on another controller is a different session.
                (mustafar, [
                    Approval(requestId: "5", sessionId: "open", toolName: "Bash"),
                    Approval(requestId: "6", sessionId: "other", toolName: "Bash"),
                ]),
            ],
            selected: selected
        )
        XCTAssertEqual(count, 3, "other on the Mac, and open and other on Mustafar")
    }

    func testApprovalsElsewhereIsZeroWithOnlyTheOpenSessionWaiting() throws {
        let mac = try XCTUnwrap(ControllerID(rawValue: "mac"))
        let count = approvalsElsewhereCount(
            approvals: [(mac, [Approval(requestId: "1", sessionId: "open", toolName: "Bash")])],
            selected: SessionRef(controllerID: mac, sessionID: "open")
        )
        XCTAssertEqual(count, 0)
    }

    func testInspectorFitsBesideTheSidebarOnlyWhenItIsClosed() {
        // The sidebar is 300 wide at the open Duo's 867 and at the 669 it uses for phone width.
        XCTAssertFalse(inspectorFitsBesideSidebar(width: 867, sidebarWidth: 300))
        XCTAssertFalse(inspectorFitsBesideSidebar(width: 669, sidebarWidth: 300))
        XCTAssertTrue(inspectorFitsBesideSidebar(width: 867, sidebarWidth: 0))
        XCTAssertTrue(inspectorFitsBesideSidebar(width: 669, sidebarWidth: 0))
        XCTAssertTrue(inspectorFitsBesideSidebar(width: 1024, sidebarWidth: 360), "An iPad's width has room for both")
    }
}
