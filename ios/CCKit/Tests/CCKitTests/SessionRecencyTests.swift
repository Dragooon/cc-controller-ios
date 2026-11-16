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

    func testOnlyYourOwnMessagesMoveASessionUpTheRecents() throws {
        // Someone else wrote in "shared" after you wrote in "mine"; another session messaged "peered" later still.
        let shared = try decode(#"{"id":"shared","lastUserMessageAt":"2026-10-28T10:10:00Z","lastOwnMessageAt":"2026-10-28T09:00:00Z"}"#)
        let peered = try decode(#"{"id":"peered","lastUserMessageAt":"2026-10-28T08:00:00Z","lastPeerMessageAt":"2026-10-28T10:20:00Z","lastOwnMessageAt":"2026-10-28T08:00:00Z"}"#)
        let mine = try decode(#"{"id":"mine","lastUserMessageAt":"2026-10-28T10:05:00Z","lastOwnMessageAt":"2026-10-28T10:05:00Z"}"#)

        XCTAssertEqual(shared.ownMessageAt, date("2026-10-28T09:00:00Z"))
        XCTAssertEqual(sortSessionsForRecents([shared, peered, mine]).map(\.id), ["mine", "shared", "peered"])
    }

    func testASessionYouNeverWroteInSortsBelowTheOnesYouDid() throws {
        let theirs = try decode(#"{"id":"theirs","lastUserMessageAt":"2026-10-28T10:30:00Z","lastOwnMessageAt":null,"idleSince":"2026-10-28T10:31:00Z"}"#)
        let mine = try decode(#"{"id":"mine","lastUserMessageAt":"2026-10-27T10:00:00Z","lastOwnMessageAt":"2026-10-27T10:00:00Z"}"#)
        let resting = try JSONDecoder.ccKit().decode(
            SleepingSession.self,
            from: Data(#"{"id":"resting","lastUserMessageAt":"2026-10-28T10:30:00Z","lastOwnMessageAt":null}"#.utf8)
        )

        XCTAssertTrue(theirs.reportsOwnMessageTime)
        XCTAssertNil(theirs.ownMessageAt)
        XCTAssertNil(resting.ownMessageAt)
        XCTAssertEqual(sortSessionsForRecents([theirs, mine]).map(\.id), ["mine", "theirs"])
    }

    func testAControllerWithoutOwnMessageTimesOrdersByTheUserMessage() throws {
        let session = try decode(#"{"id":"old-controller","lastUserMessageAt":"2026-10-28T09:00:00Z","lastPeerMessageAt":"2026-10-28T11:00:00Z"}"#)
        let resting = try JSONDecoder.ccKit().decode(
            SleepingSession.self,
            from: Data(#"{"id":"resting","lastUserMessageAt":"2026-10-28T09:30:00Z"}"#.utf8)
        )

        XCTAssertFalse(session.reportsOwnMessageTime)
        XCTAssertEqual(session.ownMessageAt, date("2026-10-28T09:00:00Z"))
        XCTAssertEqual(resting.ownMessageAt, date("2026-10-28T09:30:00Z"))
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

    private func decode(_ json: String) throws -> Session {
        try JSONDecoder.ccKit().decode(Session.self, from: Data(json.utf8))
    }

    private func date(_ value: String) -> Date {
        try! XCTUnwrap(CCDateCoding.parse(value))
    }
}
