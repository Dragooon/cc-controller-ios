import Foundation
import XCTest
@testable import CCKit

final class TolerantStateDecodingTests: XCTestCase {
    func testACarriedOverConversationWithoutAFolderStillDecodes() throws {
        let row = try JSONDecoder.ccKit().decode(
            SleepingSession.self,
            from: Data(#"{"id":"0123456789abcdef","name":null,"cwd":null,"project":null,"lastActiveAt":null,"lastUserMessageAt":"2026-11-14T10:00:00Z","lastPeerMessageAt":null,"resting":true}"#.utf8)
        )

        XCTAssertEqual(row.shortId, "01234567")
        XCTAssertEqual(row.cwd, "")
        XCTAssertEqual(row.project, "")
        XCTAssertEqual(row.lastActiveAt, row.lastUserMessageAt)
    }

    func testAnUnreadableRowIsSkippedInsteadOfFailingTheWholeState() throws {
        let state = try JSONDecoder.ccKit().decode(
            StateSnapshot.self,
            from: Data(#"""
            {
              "sessions": [{"id":"live","live":true}, {"id":42}, null],
              "sleeping": [
                {"id":"resting-1","cwd":"/var/home/madge/workspace","lastActiveAt":"2026-11-14T09:00:00Z"},
                {"name":"no id"},
                "junk",
                {"id":"resting-2"}
              ]
            }
            """#.utf8)
        )

        XCTAssertEqual(state.sessions?.compactMap(\.id), ["live"])
        XCTAssertEqual(state.sleeping?.map(\.id), ["resting-1", "resting-2"])
        XCTAssertEqual(state.sleeping?.first?.project, "workspace")
    }

    func testASleepingEventSkipsUnreadableRows() throws {
        let event = try JSONDecoder.ccKit().decode(
            SleepingEvent.self,
            from: Data(#"{"sleeping":[{"id":"a"},{"id":7},{"id":"b","cwd":null}]}"#.utf8)
        )

        XCTAssertEqual(event.sleeping.map(\.id), ["a", "b"])
    }
}
