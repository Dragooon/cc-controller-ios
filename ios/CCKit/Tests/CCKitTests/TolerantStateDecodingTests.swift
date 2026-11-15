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

final class GatewayBootstrapSampleTests: XCTestCase {
    /// A bootstrap from Stockade's gateway (a test gateway with one live session and six carried-over rows, one of
    /// them with no folder, person or times).
    func testDecodesTheGatewayBootstrapSample() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "gateway-bootstrap", withExtension: "json"))
        let bootstrap = try JSONDecoder.ccKit().decode(Bootstrap.self, from: Data(contentsOf: url))

        XCTAssertEqual(bootstrap.controller?.kind, .unknown("hosts"))
        XCTAssertTrue(bootstrap.controller?.capabilities.contains(.model) == true)
        XCTAssertEqual(bootstrap.state?.sessions?.count, 1)
        XCTAssertEqual(bootstrap.state?.sleeping?.count, 6)
    }
}
