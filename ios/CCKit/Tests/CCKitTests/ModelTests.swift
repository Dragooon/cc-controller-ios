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
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
}
