import Foundation
import XCTest
@testable import CCKit

final class SessionRecencyTests: XCTestCase {
    func testDecodesLastUserMessageFieldsWithCCDateCoding() throws {
        let session = try JSONDecoder.ccKit().decode(
            Session.self,
            from: Data("{\"id\":\"session\",\"lastUserMessageAt\":\"2026-10-28T10:20:30.123Z\",\"lastUserMessageAtExact\":false}".utf8)
        )

        XCTAssertEqual(session.lastUserMessageAt, Date(timeIntervalSince1970: 1793182830.123))
        XCTAssertEqual(session.lastUserMessageAtExact, false)
    }

    func testSortsRecentsNewestFirstAcrossHosts() {
        let sessions = [
            session(id: "mac-older", name: "Mac older", messageAt: "2026-10-28T10:00:00Z"),
            session(id: "mustafar-newer", name: "Mustafar newer", messageAt: "2026-10-28T10:05:00Z"),
            session(id: "mac-newest", name: "Mac newest", messageAt: "2026-10-28T10:10:00Z"),
        ]

        XCTAssertEqual(sortSessionsForRecents(sessions).map(\.id), ["mac-newest", "mustafar-newer", "mac-older"])
    }

    func testPlacesSessionsWithoutMessagesAfterMessageSessionsUsingNewestActivityFallback() {
        let sessions = [
            session(id: "nil-started", name: "Nil started", startedAt: "2026-10-28T10:04:00Z"),
            session(id: "with-message", name: "With message", messageAt: "2026-10-28T10:01:00Z"),
            session(id: "nil-idle", name: "Nil idle", startedAt: "2026-10-28T09:00:00Z", idleSince: "2026-10-28T10:05:00Z"),
        ]

        XCTAssertEqual(sortSessionsForRecents(sessions).map(\.id), ["with-message", "nil-idle", "nil-started"])
    }

    func testTiesUseNameThenID() {
        let sameTime = date("2026-10-28T10:00:00Z")
        let sessions = [
            Session(id: "z", name: "Beta", lastUserMessageAt: sameTime),
            Session(id: "b", name: "Alpha", lastUserMessageAt: sameTime),
            Session(id: "a", name: "Alpha", lastUserMessageAt: sameTime),
        ]

        XCTAssertEqual(sortSessionsForRecents(sessions).map(\.id), ["a", "b", "z"])
    }

    func testInexactMessageTimesStillOrderByMessageTime() {
        let sessions = [
            session(id: "exact", name: "Exact", messageAt: "2026-10-28T10:00:00Z", exact: true),
            session(id: "inexact", name: "Inexact", messageAt: "2026-10-28T10:01:00Z", exact: false),
        ]

        XCTAssertEqual(sortSessionsForRecents(sessions).map(\.id), ["inexact", "exact"])
    }

    private func session(
        id: String,
        name: String,
        messageAt: String? = nil,
        exact: Bool? = nil,
        startedAt: String? = nil,
        idleSince: String? = nil
    ) -> Session {
        Session(
            id: id,
            name: name,
            lastUserMessageAt: messageAt.map(date),
            lastUserMessageAtExact: exact,
            startedAt: startedAt.map(date),
            idleSince: idleSince.map(date)
        )
    }

    private func date(_ value: String) -> Date {
        try! XCTUnwrap(CCDateCoding.parse(value))
    }
}
