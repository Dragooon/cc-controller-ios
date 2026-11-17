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

final class ModelSwitchPendingTextTests: XCTestCase {
    func testWordsTheSwitchByWhenItApplies() {
        XCTAssertNil(modelSwitchPendingText(SessionModelResult(model: "opus", applied: true)))
        XCTAssertEqual(
            modelSwitchPendingText(SessionModelResult(model: "claude-fable-5-2", applied: false, appliesOn: "next_message"), label: "Fable 5.2"),
            "Switches to Fable 5.2 with your next message"
        )
        XCTAssertEqual(
            modelSwitchPendingText(SessionModelResult(model: "opus", applied: false)),
            "Switches to opus when the session next runs"
        )
    }
}

final class SessionNamePreambleTests: XCTestCase {
    func testASessionNameDropsTheSenderAndPlatformTags() throws {
        XCTAssertEqual(sessionNameWithoutPreamble("[sender: shitiz | via: app] Databricks experimentation"), "Databricks experimentation")
        XCTAssertEqual(sessionNameWithoutPreamble("[platform: sudo mode off] [sender: shitiz | via: app] Fix it"), "Fix it")
        XCTAssertEqual(sessionNameWithoutPreamble("[peer: from App Dev · on behalf of shitiz] Check the relay"), "Check the relay")
        XCTAssertEqual(sessionNameWithoutPreamble("App Dev"), "App Dev")
        XCTAssertEqual(sessionNameWithoutPreamble("[draft] notes"), "[draft] notes")
        XCTAssertNil(sessionNameWithoutPreamble("[sender: shitiz | via: app]"))
        XCTAssertNil(sessionNameWithoutPreamble(nil))

        let session = try JSONDecoder.ccKit().decode(
            Session.self,
            from: Data(#"{"id":"s","name":"[sender: shitiz | via: app] Databricks experimentation"}"#.utf8)
        )
        let sleeping = try JSONDecoder.ccKit().decode(
            SleepingSession.self,
            from: Data(#"{"id":"r","name":"[sender: shitiz | discord name: Dragooon | discord id: 1] Land search"}"#.utf8)
        )

        XCTAssertEqual(session.name, "Databricks experimentation")
        XCTAssertEqual(sleeping.name, "Land search")
    }
}

final class PeerStartRequestTests: XCTestCase {
    func testAStartRequestReadsAsStartingASessionHere() throws {
        let json = #"""
        {"sessions":[{"id":"held-1","name":"Mustafar: Check the relay","live":true,"state":"needs_you","pending":[{
          "requestId":"request-1","sessionId":"held-1","kind":"peer_conversation",
          "tool_input":{"request":"…","host":"Mustafar","from":"App Dev","to":"a new session","message":"Check the relay","start":true}
        }]}]}
        """#
        let state = try JSONDecoder.ccKit().decode(StateSnapshot.self, from: Data(json.utf8))
        let session = try XCTUnwrap(state.sessions?.first)
        let request = try XCTUnwrap(session.pending?.first?.peerConversation)

        XCTAssertTrue(request.startsSession)
        XCTAssertEqual(request.sentence, "Mustafar session ‘App Dev’ wants to start a new session here. Allow?")
        XCTAssertEqual(request.previewTitle, "First message")
        XCTAssertEqual(request.messagePreview, "Check the relay")
        XCTAssertTrue(session.isWaitingToBeStarted)
    }

    func testAMessageRequestKeepsItsWording() throws {
        let json = #"""
        {"sessions":[{"id":"session-1","live":true,"state":"needs_you","pending":[{
          "requestId":"request-1","sessionId":"session-1","kind":"peer_conversation",
          "tool_input":{"host":"Mustafar","from":"App Dev","to":"Kepler","message":"Status?"}
        }]}]}
        """#
        let state = try JSONDecoder.ccKit().decode(StateSnapshot.self, from: Data(json.utf8))
        let session = try XCTUnwrap(state.sessions?.first)
        let request = try XCTUnwrap(session.pending?.first?.peerConversation)

        XCTAssertFalse(request.startsSession)
        XCTAssertEqual(request.sentence, "Mustafar session ‘App Dev’ wants to message ‘Kepler’. Allow?")
        XCTAssertEqual(request.previewTitle, "Message preview")
        XCTAssertFalse(session.isWaitingToBeStarted)
    }
}
