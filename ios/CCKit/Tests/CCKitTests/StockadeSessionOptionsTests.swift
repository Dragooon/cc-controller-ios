import Foundation
import XCTest
@testable import CCKit

final class StockadeSessionOptionsTests: XCTestCase {
    func testSlashCommandsFromTheSessionGetOneLeadingSlashAndNoRepeats() {
        let commands = [
            SessionCommand(name: "compact", description: "Summarize context", source: "builtin"),
            SessionCommand(name: "/review", description: "Review changes", source: "skill"),
            SessionCommand(name: "compact", description: "Again", source: "plugin"),
            SessionCommand(name: "  ", description: "Blank"),
            SessionCommand(name: "mcp__docs__search", description: nil, source: "mcp"),
        ]

        XCTAssertEqual(slashCommandDefinitions(from: commands), [
            SlashCommandDefinition(command: "/compact", description: "Summarize context"),
            SlashCommandDefinition(command: "/review", description: "Review changes"),
            SlashCommandDefinition(command: "/mcp__docs__search", description: ""),
        ])
    }

    func testDecodesTheCommandList() throws {
        let list = try JSONDecoder.ccKit().decode(
            SessionCommandList.self,
            from: Data(#"{"commands":[{"name":"init","description":"Initialize project","source":"builtin"},{"name":"deploy","description":"Ship it","source":"plugin","plugin":"ops"}]}"#.utf8)
        )

        XCTAssertEqual(list.commands.count, 2)
        XCTAssertEqual(list.commands[1].plugin, "ops")
    }

    func testOnlyAnAgentWithoutAFixedFolderChoosesOne() throws {
        let options = try JSONDecoder.ccKit().decode(
            NewSessionOptions.self,
            from: Data(#"{"folders":[],"models":[{"id":"opus","label":"Opus"}],"defaultModel":"default","agents":[{"id":"main","name":"Madge","fixedFolder":true},{"id":"dev","name":"Dev","fixedFolder":false},{"id":"old","name":"Old"}]}"#.utf8)
        )
        let agents = try XCTUnwrap(options.agents)

        XCTAssertEqual(agents.map(\.choosesFolder), [false, true, false])
    }

    func testDecodesASessionModelOverrideAndTheModelRouteResult() throws {
        let session = try JSONDecoder.ccKit().decode(Session.self, from: Data(#"{"id":"s","model":"opus"}"#.utf8))
        let result = try JSONDecoder.ccKit().decode(SessionModelResult.self, from: Data(#"{"model":"opus","applied":false}"#.utf8))

        XCTAssertEqual(session.model, "opus")
        XCTAssertEqual(result, SessionModelResult(model: "opus", applied: false))
        XCTAssertEqual(ControllerCapability(rawValue: "model"), .model)
    }
}
