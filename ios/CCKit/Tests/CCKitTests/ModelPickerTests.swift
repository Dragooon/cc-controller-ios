import XCTest
@testable import CCKit

final class ModelPickerTests: XCTestCase {
    /// What Mustafar's gateway offers: Claude Code's short names, then the exact versions from its config.
    private let offered = [
        ModelOption(id: "default", label: "Default"),
        ModelOption(id: "opus", label: "Opus"),
        ModelOption(id: "sonnet", label: "Sonnet"),
        ModelOption(id: "haiku", label: "Haiku"),
        ModelOption(id: "fable", label: "Fable"),
        ModelOption(id: "claude-fable-5-2", label: "claude-fable-5-2"),
        ModelOption(id: "claude-fable-5-2[1m]", label: "claude-fable-5-2[1m]"),
        ModelOption(id: "claude-opus-5-5", label: "claude-opus-5-5"),
        ModelOption(id: "claude-sonnet-5-5", label: "claude-sonnet-5-5"),
        ModelOption(id: "claude-haiku-5-5", label: "claude-haiku-5-5"),
    ]

    func testEachModelIsListedOnceUnderItsName() {
        let models = pickerModels(offered, defaultModelLabel: "Opus 5.5")
        XCTAssertEqual(models.map(\.id), ["default", "claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(models.map(\.label), ["Default (Opus 5.5)", "Fable 5.2", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])
        XCTAssertEqual(pickerModels(offered).first?.label, "Default")
    }

    func testAShortNameStaysWhenNoVersionOfItsFamilyIsListed() {
        let models = pickerModels([
            ModelOption(id: "opus", label: "Opus"),
            ModelOption(id: "opus[1m]", label: "opus[1m]"),
            ModelOption(id: "haiku", label: "haiku"),
            ModelOption(id: "claude-sonnet-5-5[1m]", label: "claude-sonnet-5-5[1m]"),
        ])
        // Sonnet 5.5 is 1M with or without the suffix, so its only listing carries the plain name.
        XCTAssertEqual(models.map(\.id), ["claude-sonnet-5-5[1m]", "opus", "haiku"])
        XCTAssertEqual(models.map(\.label), ["Sonnet 5.5", "Opus", "Haiku"])
    }

    func testAOneMillionVariantStaysWhereItIsADifferentModel() {
        let models = pickerModels([
            ModelOption(id: "claude-opus-4-6", label: "claude-opus-4-6"),
            ModelOption(id: "claude-opus-4-6[1m]", label: "claude-opus-4-6[1m]"),
            ModelOption(id: "claude-opus-4-7", label: "claude-opus-4-7"),
            ModelOption(id: "claude-opus-4-7[1m]", label: "claude-opus-4-7[1m]"),
            ModelOption(id: "claude-sonnet-5", label: "claude-sonnet-5"),
            ModelOption(id: "claude-sonnet-4-6-20260115", label: "claude-sonnet-4-6-20260115"),
        ])
        XCTAssertEqual(models.map(\.id), ["claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-6[1m]", "claude-sonnet-5", "claude-sonnet-4-6-20260115"])
        XCTAssertEqual(models.map(\.label), ["Opus 4.7", "Opus 4.6", "Opus 4.6 · 1M", "Sonnet 5", "Sonnet 4.6"])
    }

    func testTheControllersOwnLabelsAndOtherModelsAreKept() {
        let models = pickerModels([
            ModelOption(id: "gpt-6-astra", label: "Astra"),
            ModelOption(id: "claude-opus-5-5", label: "Opus (work)"),
            ModelOption(id: "local-model", label: "local-model"),
        ])
        XCTAssertEqual(models.map(\.id), ["claude-opus-5-5", "gpt-6-astra", "local-model"])
        XCTAssertEqual(models.map(\.label), ["Opus (work)", "Astra", "local-model"])
        // Effort levels travel with the entry.
        let withEfforts = pickerModels([ModelOption(id: "claude-fable-5-2", label: "claude-fable-5-2", efforts: ["low"], defaultEffort: "xhigh")])
        XCTAssertEqual(withEfforts.first?.efforts, ["low"])
        XCTAssertEqual(withEfforts.first?.defaultEffort, "xhigh")
    }

    func testTheSessionsModelIsTickedOnTheEntryThatStandsForIt() {
        let models = pickerModels(offered)
        // A variant or a short name that is no longer listed ticks the model it means.
        XCTAssertEqual(pickerCurrentModelID(models: models, picked: "claude-fable-5-2[1m]", running: nil), "claude-fable-5-2")
        XCTAssertEqual(pickerCurrentModelID(models: models, picked: "opus", running: "claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(pickerCurrentModelID(models: models, picked: nil, running: "claude-sonnet-5-5-20261001"), "claude-sonnet-5-5")
        // A picked model wins over the one the transcript still shows.
        XCTAssertEqual(pickerCurrentModelID(models: models, picked: "claude-haiku-5-5", running: "claude-opus-5-5"), "claude-haiku-5-5")
        XCTAssertEqual(pickerCurrentModelID(models: models, picked: "default", running: nil), "default")
        XCTAssertNil(pickerCurrentModelID(models: models, picked: nil, running: "<synthetic>"))
        XCTAssertNil(pickerCurrentModelID(models: models, picked: nil, running: nil))
    }

    func testTheChipNamesARealModel() {
        // Claude Code's usage-limit notice is written under "<synthetic>".
        XCTAssertFalse(isRealModelID("<synthetic>"))
        XCTAssertFalse(isRealModelID(nil))
        XCTAssertTrue(isRealModelID("claude-opus-5-5"))
        XCTAssertEqual(shownSessionModelID(picked: nil, usage: "<synthetic>", transcript: "claude-fable-5-2"), "claude-fable-5-2")
        XCTAssertEqual(shownSessionModelID(picked: "claude-fable-5-2[1m]", usage: "<synthetic>", transcript: nil), "claude-fable-5-2[1m]")
        // The same model under two ids shows as the session reports it; another model waits for the next turn.
        XCTAssertEqual(shownSessionModelID(picked: "opus", usage: "claude-opus-5-5", transcript: nil), "claude-opus-5-5")
        XCTAssertEqual(shownSessionModelID(picked: "claude-fable-5-2[1m]", usage: "claude-fable-5-2", transcript: nil), "claude-fable-5-2")
        XCTAssertEqual(shownSessionModelID(picked: "claude-haiku-5-5", usage: "claude-opus-5-5", transcript: nil), "claude-haiku-5-5")
        XCTAssertEqual(shownSessionModelID(picked: "default", usage: "claude-opus-5-5", transcript: nil), "claude-opus-5-5")
        XCTAssertNil(shownSessionModelID(picked: nil, usage: nil, transcript: "<synthetic>"))
        XCTAssertNil(composerModelName("<synthetic>"))
    }
}
