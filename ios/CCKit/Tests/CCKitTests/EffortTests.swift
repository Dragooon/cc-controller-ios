import XCTest
@testable import CCKit

final class EffortTests: XCTestCase {
    private let efforts = [
        EffortOption(id: "default", label: "Default"),
        EffortOption(id: "low", label: "Low"),
        EffortOption(id: "medium", label: "Medium"),
        EffortOption(id: "high", label: "High"),
        EffortOption(id: "xhigh", label: "Extra"),
        EffortOption(id: "max", label: "Max"),
    ]
    private let models = [
        ModelOption(id: "claude-fable-5-2", label: "Fable 5.2", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium"),
        ModelOption(id: "claude-sonnet-4-6", label: "Sonnet 4.6", efforts: ["low", "medium", "high", "max"], defaultEffort: "high"),
        ModelOption(id: "claude-haiku-4-5", label: "Haiku 4.5"),
    ]

    func testTheControllersOptionsAndASessionsLevelDecode() throws {
        let json = #"""
        {"folders":[],"defaultModel":"default","models":[{"id":"claude-fable-5-2","label":"Fable 5.2","efforts":["low","xhigh"],"defaultEffort":"medium"},{"id":"old","label":"Old"}],
         "efforts":[{"id":"default","label":"Default"},{"id":"xhigh","label":"Extra"}]}
        """#
        let options = try JSONDecoder.ccKit().decode(NewSessionOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.efforts, [EffortOption(id: "default", label: "Default"), EffortOption(id: "xhigh", label: "Extra")])
        XCTAssertEqual(options.models.first?.efforts, ["low", "xhigh"])
        XCTAssertEqual(options.models.first?.defaultEffort, "medium")
        XCTAssertNil(options.models.last?.efforts)

        let state = try JSONDecoder.ccKit().decode(StateSnapshot.self, from: Data(#"{"sessions":[{"id":"a","effort":"xhigh"},{"id":"b"}]}"#.utf8))
        XCTAssertEqual(state.sessions?.first?.effort, "xhigh")
        XCTAssertNil(state.sessions?.last?.effort)
        XCTAssertEqual(ControllerCapability(rawValue: "effort"), .effort)
    }

    func testASessionShowsItsOwnLevelElseItsModelsDefault() {
        XCTAssertEqual(sessionEffortName(effort: "xhigh", modelID: "claude-fable-5-2", models: models, efforts: efforts), "Extra")
        XCTAssertEqual(sessionEffortName(effort: nil, modelID: "claude-fable-5-2", models: models, efforts: efforts), "Medium")
        XCTAssertEqual(sessionEffortName(effort: "default", modelID: "claude-sonnet-4-6", models: models, efforts: efforts), "High")
        // A model the controller gives no default for, or one it doesn't list, shows no level.
        XCTAssertNil(sessionEffortName(effort: nil, modelID: "claude-haiku-4-5", models: models, efforts: efforts))
        XCTAssertNil(sessionEffortName(effort: "default", modelID: "something-else", models: models, efforts: efforts))
        XCTAssertNil(sessionEffortName(effort: nil, modelID: nil, models: [], efforts: []))
        // A level still has a name before the controller's list arrives.
        XCTAssertEqual(sessionEffortName(effort: "xhigh", modelID: nil, models: [], efforts: []), "Extra")
        XCTAssertEqual(effortLabel("max"), "Max")
    }

    func testDefaultNamesWhatTheChosenAgentLaunches() throws {
        let json = #"""
        {"folders":[],"defaultModel":"claude-opus-5-5","defaultModelLabel":"Opus 5.5",
         "models":[{"id":"opus","label":"Opus","defaultEffort":"medium"},
                   {"id":"claude-opus-5-5","label":"Opus 5.5","defaultEffort":"medium"},
                   {"id":"claude-fable-5-2","label":"Fable 5.2","defaultEffort":"xhigh"}],
         "agents":[{"id":"main","name":"Madge","fixedFolder":true,"defaultModel":"claude-opus-5-5","defaultModelLabel":"Opus 5.5","defaultEffort":"high","effort":"high"},
                   {"id":"scout","name":"Scout","fixedFolder":false,"defaultModel":"claude-fable-5-2","defaultModelLabel":"Fable 5.2","defaultEffort":"xhigh"},
                   {"id":"old","name":"Old"}]}
        """#
        let options = try JSONDecoder.ccKit().decode(NewSessionOptions.self, from: Data(json.utf8))
        let main = try XCTUnwrap(options.agents?.first)
        let scout = try XCTUnwrap(options.agents?.dropFirst().first)
        let old = try XCTUnwrap(options.agents?.last)

        XCTAssertEqual(newSessionDefaultModelID(options: options, agent: main), "claude-opus-5-5")
        XCTAssertEqual(newSessionDefaultModelLabel(options: options, agent: main), "Opus 5.5")
        XCTAssertEqual(newSessionDefaultModelID(options: options, agent: scout), "claude-fable-5-2")
        XCTAssertEqual(newSessionDefaultModelLabel(options: options, agent: scout), "Fable 5.2")
        // An agent the controller says nothing about, and no agent at all, take the controller's default.
        XCTAssertEqual(newSessionDefaultModelLabel(options: options, agent: old), "Opus 5.5")
        XCTAssertEqual(newSessionDefaultModelID(options: options, agent: nil), "claude-opus-5-5")

        // The agent's own level applies whichever model is picked.
        XCTAssertEqual(newSessionDefaultEffortID(options: options, agent: main, pickedModelID: nil), "high")
        XCTAssertEqual(newSessionDefaultEffortID(options: options, agent: main, pickedModelID: "claude-fable-5-2"), "high")
        // Without one: the agent's default on the default model, the picked model's default otherwise.
        XCTAssertEqual(newSessionDefaultEffortID(options: options, agent: scout, pickedModelID: nil), "xhigh")
        XCTAssertEqual(newSessionDefaultEffortID(options: options, agent: scout, pickedModelID: "claude-opus-5-5"), "medium")
        XCTAssertEqual(newSessionDefaultEffortID(options: options, agent: scout, pickedModelID: "opus"), "medium")
        XCTAssertEqual(newSessionDefaultEffortID(options: options, agent: old, pickedModelID: nil), "medium")
        XCTAssertNil(newSessionDefaultEffortID(options: options, agent: old, pickedModelID: "unlisted"))
    }

    func testAnOlderControllerNamesItsDefaultFromTheModelList() {
        let options = NewSessionOptions(models: models, defaultModel: "claude-sonnet-4-6")
        XCTAssertEqual(newSessionDefaultModelLabel(options: options, agent: nil), "Sonnet 4.6")
        XCTAssertEqual(newSessionDefaultModelLabel(options: NewSessionOptions(defaultModel: "default"), agent: nil), "default")
        XCTAssertEqual(newSessionDefaultEffortID(options: options, agent: nil, pickedModelID: nil), "high")
    }

    func testOnlyTheLevelsAModelTakesAreOffered() {
        XCTAssertEqual(
            effortOptions(efforts, forModel: "claude-sonnet-4-6", models: models).map(\.id),
            ["default", "low", "medium", "high", "max"]
        )
        XCTAssertEqual(effortOptions(efforts, forModel: "claude-haiku-4-5", models: models), efforts)
        XCTAssertEqual(effortOptions(efforts, forModel: nil, models: models), efforts)
        XCTAssertEqual(effortOptions(efforts, forModel: "unknown", models: models), efforts)
    }

    func testAChangeThatWaitsSaysWhenItApplies() {
        XCTAssertNil(effortSwitchPendingText(SessionEffortResult(effort: "high", applied: true)))
        XCTAssertEqual(
            effortSwitchPendingText(SessionEffortResult(effort: "xhigh", applied: false, appliesOn: "next_message")),
            "Effort changes to Extra with your next message"
        )
        XCTAssertEqual(
            effortSwitchPendingText(SessionEffortResult(effort: "low", applied: false)),
            "Effort changes to Low when the session next runs"
        )
    }
}
