import Foundation
import XCTest
@testable import CCKit

final class StockadePresentationTests: XCTestCase {
    func testSessionDecodesTheD3bFields() throws {
        let json = """
        {"id":"dune-relay","name":"Dune relay","state":"idle","origin":"peer",
         "startedBy":{"kind":"agent","name":"Kepler"},
         "participants":[{"name":"sam","platform":"app"},{"name":"kepler","platform":"api"}],
         "writable":true,"readOnlyReason":null,"sudo":false,"agent":{"id":"main","name":"Madge"}}
        """
        let session = try JSONDecoder.ccKit().decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.origin, "peer")
        XCTAssertEqual(session.startedBy, SessionStarter(kind: "agent", name: "Kepler"))
        XCTAssertEqual(session.participants?.map(\.name), ["sam", "kepler"])
        XCTAssertEqual(session.writable, true)
        XCTAssertNil(session.readOnlyReason)
        XCTAssertEqual(session.sudo, false)
        XCTAssertEqual(session.agent, SessionAgent(id: "main", name: "Madge"))
    }

    func testMacSessionsHaveNoStockadePresentation() throws {
        let session = try JSONDecoder.ccKit().decode(Session.self, from: Data("{\"id\":\"mac\",\"project\":\"cc-controller\"}".utf8))
        XCTAssertNil(readOnlyLabel(for: session))
        XCTAssertNil(startedByLabel(for: session))
        XCTAssertNil(participantsLabel(for: session))
        XCTAssertNil(stockadeSessionMeta(for: session))
        XCTAssertFalse(acceptsSudo(session, capabilities: ControllerCapability.all))
    }

    func testReadOnlyLabelNamesTheReason() {
        XCTAssertEqual(readOnlyLabel(for: Session(writable: false, readOnlyReason: "discord")), "Read-only · Discord")
        XCTAssertEqual(readOnlyLabel(for: Session(writable: false, readOnlyReason: "terminal")), "Read-only · Terminal")
        XCTAssertEqual(readOnlyLabel(for: Session(writable: false, readOnlyReason: "agent")), "Read-only · Agent")
        XCTAssertEqual(readOnlyLabel(for: Session(writable: false)), "Read-only")
        XCTAssertNil(readOnlyLabel(for: Session(writable: true)))
    }

    func testApprovalDecodesAnswerInAndNamesThePlace() throws {
        let approval = try JSONDecoder.ccKit().decode(Approval.self, from: Data("{\"requestId\":\"a\",\"sessionId\":\"s\",\"answerIn\":\"discord\"}".utf8))
        XCTAssertEqual(approval.answerIn, "discord")
        XCTAssertEqual(answerInLabel(for: approval), "Answer in Discord")
        XCTAssertEqual(answerInLabel(for: Approval(answerIn: "terminal")), "Answer in the terminal")
        XCTAssertEqual(answerInLabel(for: Approval(answerIn: "agent")), "Answer in the agent's session")
        XCTAssertEqual(answerInLabel(for: Approval(answerIn: "somewhere")), "Answer where this session runs")
        XCTAssertNil(answerInLabel(for: Approval()))
    }

    func testStartedByAndParticipants() {
        XCTAssertEqual(startedByLabel(for: Session(startedBy: SessionStarter(kind: "agent", name: "Kepler"))), "Started by Kepler")
        XCTAssertEqual(startedByLabel(for: Session(startedBy: SessionStarter(kind: "agent", name: " "))), "Started by an agent")
        XCTAssertNil(startedByLabel(for: Session(startedBy: SessionStarter(kind: "person", name: "sam"))))
        XCTAssertNil(participantsLabel(for: Session(participants: [SessionParticipant(name: "sam")])))
        XCTAssertEqual(
            participantsLabel(for: Session(participants: [SessionParticipant(name: "sam"), SessionParticipant(name: "riley")])),
            "With sam, riley"
        )
    }

    func testSessionMetaLine() {
        let peer = Session(origin: "peer", startedBy: SessionStarter(kind: "agent", name: "Kepler"), writable: true, agent: SessionAgent(id: "main", name: "Madge"))
        XCTAssertEqual(stockadeSessionMeta(for: peer), "Madge · Started by Kepler")
        let discord = Session(origin: "discord", startedBy: SessionStarter(kind: "person", name: "sam"), writable: false, readOnlyReason: "discord", agent: SessionAgent(id: "main", name: "Madge"))
        XCTAssertEqual(stockadeSessionMeta(for: discord), "Madge · Discord · read-only")
        let sudo = Session(origin: "app", writable: true, sudo: true, agent: SessionAgent(id: "kleya"))
        XCTAssertEqual(stockadeSessionMeta(for: sudo), "kleya · App · sudo")
    }

    func testSudoNeedsTheCapabilityAndAWritableSession() {
        let writable = Session(writable: true)
        XCTAssertTrue(acceptsSudo(writable, capabilities: [.list, .send, .sudo]))
        XCTAssertFalse(acceptsSudo(writable, capabilities: [.list, .send]))
        XCTAssertFalse(acceptsSudo(Session(writable: false, readOnlyReason: "discord"), capabilities: [.sudo]))
        XCTAssertEqual(sudoToastText(true), "Sudo on")
        XCTAssertEqual(sudoToastText(false), "Sudo off")
    }

    func testSudoCapabilityRoundTripsButIsNotAssumedForTheMac() throws {
        XCTAssertEqual(ControllerCapability(rawValue: "sudo"), .sudo)
        XCTAssertEqual(ControllerCapability.sudo.rawValue, "sudo")
        XCTAssertFalse(ControllerCapability.all.contains(.sudo))
    }

    func testComposerCapabilitiesForClaudeCode() {
        let composer = ComposerCapabilities(controllerCapabilities: ControllerCapability.all)

        XCTAssertTrue(composer.canAttach)
        XCTAssertTrue(composer.canRunCommands)
    }

    func testComposerCapabilitiesForStockadeFixture() {
        let capabilities: Set<ControllerCapability> = [.list, .transcript, .send, .decide, .questions, .newSession, .files, .sudo]
        let composer = ComposerCapabilities(controllerCapabilities: capabilities)

        XCTAssertTrue(composer.canAttach)
        XCTAssertFalse(composer.canRunCommands)
    }

    func testComposerCapabilitiesWithoutFilesHideAttachments() {
        let capabilities: Set<ControllerCapability> = [.list, .transcript, .send, .decide, .questions, .newSession, .sudo]
        let composer = ComposerCapabilities(controllerCapabilities: capabilities)

        XCTAssertFalse(composer.canAttach)
    }

    func testNewSessionOptionsCarryStockadeAgents() throws {
        let mac = try JSONDecoder.ccKit().decode(NewSessionOptions.self, from: Data("{\"folders\":[],\"models\":[],\"defaultModel\":\"opus\"}".utf8))
        XCTAssertNil(mac.agents)
        let stockade = try JSONDecoder.ccKit().decode(
            NewSessionOptions.self,
            from: Data("{\"folders\":[],\"models\":[],\"defaultModel\":\"default\",\"agents\":[{\"id\":\"main\",\"name\":\"Madge\"}]}".utf8)
        )
        XCTAssertEqual(stockade.agents, [NewSessionAgent(id: "main", name: "Madge")])
    }

    func testMessageResultCarriesSudo() throws {
        let result = try JSONDecoder.ccKit().decode(MessageResult.self, from: Data("{\"delivered\":true,\"queued\":false,\"route\":\"stockade\",\"sudo\":true}".utf8))
        XCTAssertEqual(result.sudo, true)
    }

    @MainActor
    func testReadOnlyRefusalMapsToItsOwnError() {
        let app = AppStore(
            serverURL: URL(string: "http://localhost:47832")!,
            bearerProvider: { "test-token" },
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let mapped = app.actionError(for: APIError.http(status: 403, message: "This session is read-only here. Answer in Discord.", code: "read_only"))
        XCTAssertEqual(mapped, .readOnly("This session is read-only here. Answer in Discord."))
        XCTAssertEqual(mapped.userMessage, "This session is read-only here. Answer in Discord.")
    }
}
