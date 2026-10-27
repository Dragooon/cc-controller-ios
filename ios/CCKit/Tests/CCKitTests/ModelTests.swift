import Foundation
import XCTest
@testable import CCKit

final class ModelTests: XCTestCase {
    func testDatesWithAndWithoutFractionalSeconds() throws {
        let fractional = try JSONDecoder.ccKit().decode(AssistantEntry.self, from: Data("{\"ts\":\"2026-09-30T00:00:00.123Z\"}".utf8))
        let plain = try JSONDecoder.ccKit().decode(AssistantEntry.self, from: Data("{\"ts\":\"2026-09-30T00:00:00Z\"}".utf8))
        XCTAssertNotNil(fractional.ts)
        XCTAssertNotNil(plain.ts)
    }

    func testPeerConversationTimesDecodeEpochMilliseconds() throws {
        let conversation = try JSONDecoder.ccKit().decode(
            [PeerConversation].self,
            from: Data("""
            [{"id":"74dca0e9cd297800","peer":{"host":"stockade","hostLabel":"Stockade","ref":"stockade1","label":"thread \\\"X\\\" in #general"},"local":{"ref":"<any>","label":"Approval Flow Light Mode"},"state":"allowed","since":1793059200000,"until":1793062800000}]
            """.utf8)
        ).first
        let since = Date(timeIntervalSince1970: 1793059200)
        let until = Date(timeIntervalSince1970: 1793062800)

        XCTAssertEqual(conversation?.since, since)
        XCTAssertEqual(conversation?.until, until)
        XCTAssertEqual(conversation?.lastActive, until.addingTimeInterval(-60 * 60))
    }

    func testPeerConversationTimesDecodeISOStrings() throws {
        let conversation = try JSONDecoder.ccKit().decode(
            PeerConversation.self,
            from: Data("""
            {"id":"conversation","peer":{"host":"stockade","hostLabel":"Stockade","ref":"stockade1","label":"thread \\\"X\\\" in #general"},"local":{"ref":"local","label":"Approval Flow Light Mode"},"state":"allowed","since":"2026-10-27T00:00:00.000Z","until":"2026-10-27T01:00:00.000Z"}
            """.utf8)
        )

        let since = Date(timeIntervalSince1970: 1793059200)
        let until = Date(timeIntervalSince1970: 1793062800)
        XCTAssertEqual(conversation.since, since)
        XCTAssertEqual(conversation.until, until)
        XCTAssertEqual(conversation.lastActive, until.addingTimeInterval(-60 * 60))
    }

    func testPeerConversationMissingSinceRemainsNil() throws {
        let conversation = try JSONDecoder.ccKit().decode(
            PeerConversation.self,
            from: Data("""
            {"id":"conversation","peer":{"host":"stockade","hostLabel":"Stockade","ref":"stockade1","label":"thread \\\"X\\\" in #general"},"local":{"ref":"local","label":"Approval Flow Light Mode"},"state":"denied","until":1793062800000}
            """.utf8)
        )

        XCTAssertNil(conversation.since)
        XCTAssertEqual(conversation.until, Date(timeIntervalSince1970: 1793062800))
        XCTAssertEqual(conversation.lastActive, conversation.since)
    }

    func testUnknownEnumAndEntryArePreserved() throws {
        let state = try JSONDecoder.ccKit().decode(SessionState.self, from: Data("\"future_state\"".utf8))
        XCTAssertEqual(state, .unknown("future_state"))
        let entry = try JSONDecoder.ccKit().decode(TranscriptEntry.self, from: Data("{\"kind\":\"future\",\"id\":\"x\",\"value\":42}".utf8))
        guard case .unknown(let kind, let raw) = entry else { return XCTFail("Expected unknown entry") }
        XCTAssertEqual(kind, "future")
        XCTAssertEqual(raw.objectValue?["value"], .number(42))
    }

    func testUnknownFieldsAreIgnoredAndJSONValueRetainsToolInput() throws {
        let entry = try JSONDecoder.ccKit().decode(TranscriptEntry.self, from: Data("{\"kind\":\"tool\",\"tool_input\":{\"nested\":[true,null] },\"new_field\":\"ignored\"}".utf8))
        guard case .tool(let tool) = entry else { return XCTFail("Expected tool") }
        XCTAssertEqual(tool.args, nil)
        XCTAssertNil(tool.toolUseId)
    }

    func testActivityFieldsDecodeAndRemainOptional() throws {
        let session = try JSONDecoder.ccKit().decode(
            Session.self,
            from: Data("""
            {"id":"session","subagents":[{"agentId":"agent","background":true}],"shells":[{"toolUseId":"shell","description":"Run tests","command":"swift test","state":"running","startedAt":"2026-10-04T00:00:00Z"}]}
            """.utf8)
        )

        XCTAssertEqual(session.subagents?.first?.background, true)
        XCTAssertEqual(session.shells?.first?.state, .running)
        XCTAssertEqual(session.shells?.first?.command, "swift test")
        XCTAssertNil(try JSONDecoder.ccKit().decode(Session.self, from: Data("{\"id\":\"old\"}".utf8)).shells)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
}
