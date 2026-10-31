import Foundation
import XCTest
@testable import CCKit

final class SessionReadMarksTests: XCTestCase {
    private let baseline = Date(timeIntervalSince1970: 1_000)

    private func idleSession(repliedAt date: Date?) -> Session {
        Session(id: "one", state: .idle, idleSince: date)
    }

    func testRepliesBeforeTheBaselineAreRead() {
        let marks = SessionReadMarks(baseline: baseline)
        let session = idleSession(repliedAt: baseline.addingTimeInterval(-10))
        XCTAssertEqual(marks.status(for: session, key: "mac/one", isOpen: false), .read)
    }

    func testReplyAfterTheBaselineIsUnreadUntilMarkedRead() {
        var marks = SessionReadMarks(baseline: baseline)
        let replyDate = baseline.addingTimeInterval(10)
        let session = idleSession(repliedAt: replyDate)
        XCTAssertEqual(marks.status(for: session, key: "mac/one", isOpen: false), .unread)
        marks.markRead(key: "mac/one", through: replyDate)
        XCTAssertEqual(marks.status(for: session, key: "mac/one", isOpen: false), .read)
    }

    func testNewReplyAfterReadingIsUnreadAgain() {
        var marks = SessionReadMarks(baseline: baseline)
        marks.markRead(key: "mac/one", through: baseline.addingTimeInterval(10))
        let session = idleSession(repliedAt: baseline.addingTimeInterval(20))
        XCTAssertEqual(marks.status(for: session, key: "mac/one", isOpen: false), .unread)
    }

    func testWorkingWinsOverUnread() {
        let marks = SessionReadMarks(baseline: baseline)
        let session = Session(id: "one", state: .working, idleSince: baseline.addingTimeInterval(10))
        XCTAssertEqual(marks.status(for: session, key: "mac/one", isOpen: false), .working)
    }

    func testOpenSessionIsRead() {
        let marks = SessionReadMarks(baseline: baseline)
        let session = idleSession(repliedAt: baseline.addingTimeInterval(10))
        XCTAssertEqual(marks.status(for: session, key: "mac/one", isOpen: true), .read)
    }

    func testSessionWaitingOnApprovalIsUnreadUntilOpened() {
        let marks = SessionReadMarks(baseline: baseline)
        let session = Session(id: "one", state: .needsYou)
        XCTAssertEqual(marks.status(for: session, key: "mac/one", isOpen: false), .unread)
        XCTAssertEqual(marks.status(for: session, key: "mac/one", isOpen: true), .read)
    }

    func testSleepingSessionPrefersItsLastReplyOverItsTranscriptTime() {
        var marks = SessionReadMarks(baseline: baseline)
        let replyDate = baseline.addingTimeInterval(10)
        marks.markRead(key: "mac/one", through: replyDate)
        var sleeping = SleepingSession(
            id: "one",
            shortId: "one",
            cwd: "/tmp",
            project: "tmp",
            lastActiveAt: baseline.addingTimeInterval(500)
        )
        XCTAssertEqual(marks.status(for: sleeping, key: "mac/one", isOpen: false), .unread)
        sleeping.lastAssistantMessageAt = replyDate
        XCTAssertEqual(marks.status(for: sleeping, key: "mac/one", isOpen: false), .read)
    }

    func testMarksSurviveStorage() {
        var marks = SessionReadMarks()
        marks.startIfNeeded(now: baseline)
        marks.markRead(key: "mac/one", through: baseline.addingTimeInterval(10))
        XCTAssertEqual(SessionReadMarks(stored: marks.stored), marks)
        XCTAssertEqual(SessionReadMarks(stored: ""), SessionReadMarks())
    }
}
