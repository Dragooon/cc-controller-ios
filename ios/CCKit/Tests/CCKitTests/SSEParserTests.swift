import XCTest
@testable import CCKit

final class SSEParserTests: XCTestCase {
    func testContractFramingAndComments() {
        var parser = SSEParser()
        let lines = ["event: state", "data: {\"one\":", "data: 1}", "", ": keep-alive", "event: transcript", "data: {\"ok\":true}", ""]
        let events = lines.compactMap { parser.consume($0) }
        XCTAssertEqual(events, [SSEEvent(name: "state", data: "{\"one\":\n1}"), SSEEvent(name: "transcript", data: "{\"ok\":true}")])
    }

    func testDefaultEventAndUnknownFields() {
        var parser = SSEParser()
        XCTAssertNil(parser.consume("retry: 1000"))
        XCTAssertNil(parser.consume("data: hello"))
        XCTAssertEqual(parser.consume(""), SSEEvent(data: "hello"))
    }

    func testLiveEventKindsAndHookDrop() {
        XCTAssertEqual(LiveEvent.decode(name: "hook", data: "{}"), nil)
        XCTAssertEqual(LiveEvent.decode(name: "unrecognized", data: "{}"), nil)
        if case .stateDelta(let delta) = LiveEvent.decode(name: "state", data: "{\"sessionId\":\"s\",\"state\":\"mystery\"}") {
            XCTAssertEqual(delta.sessionId, "s")
            XCTAssertEqual(delta.state, .unknown("mystery"))
        } else { XCTFail("Expected state delta") }
    }
}
