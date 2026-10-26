import Foundation
import XCTest
@testable import CCKit

final class AddControllerTests: XCTestCase {
    func testControllerIDFromNameIsASlug() throws {
        XCTAssertEqual(ControllerID.make(fromName: "Mustafar", existing: [.mac]).rawValue, "mustafar")
        XCTAssertEqual(ControllerID.make(fromName: "  Sam's  Mac mini! ", existing: []).rawValue, "sam-s-mac-mini")
        XCTAssertEqual(ControllerID.make(fromName: "Ünïcode 2", existing: []).rawValue, "n-code-2")
        XCTAssertEqual(ControllerID.make(fromName: "!!!", existing: []).rawValue, "controller")
        XCTAssertEqual(ControllerID.make(fromName: String(repeating: "a", count: 40), existing: []).rawValue.count, 32)
    }

    func testControllerIDFromNameIsUniqueAgainstExisting() throws {
        let mustafar = try ControllerID("mustafar")
        let second = try ControllerID("mustafar-2")
        XCTAssertEqual(ControllerID.make(fromName: "Mac", existing: [.mac]).rawValue, "mac-2")
        XCTAssertEqual(ControllerID.make(fromName: "Mustafar", existing: [mustafar, second]).rawValue, "mustafar-3")
        let long = String(repeating: "b", count: 32)
        let taken = try ControllerID(long)
        let made = ControllerID.make(fromName: long, existing: [taken])
        XCTAssertEqual(made.rawValue, String(repeating: "b", count: 30) + "-2")
    }

    func testAddressEndpointsAcceptIPPortAndHTTPS() throws {
        XCTAssertEqual(
            ControllerConfig.addressEndpoints(from: "192.0.2.10:47834\nhttps://100.64.0.5:47834"),
            [URL(string: "https://192.0.2.10:47834")!, URL(string: "https://100.64.0.5:47834")!]
        )
        XCTAssertEqual(
            ControllerConfig.addressEndpoints(from: "10.0.0.1:1, 10.0.0.1:1"),
            [URL(string: "https://10.0.0.1:1")!]
        )
    }

    func testAddressEndpointsRejectHostnamesMissingPortsPlainHTTPAndEmpty() {
        XCTAssertNil(ControllerConfig.addressEndpoints(from: ""))
        XCTAssertNil(ControllerConfig.addressEndpoints(from: "  \n "))
        XCTAssertNil(ControllerConfig.addressEndpoints(from: "mustafar.local:47834"))
        XCTAssertNil(ControllerConfig.addressEndpoints(from: "192.0.2.10"))
        XCTAssertNil(ControllerConfig.addressEndpoints(from: "http://192.0.2.10:47834"))
        XCTAssertNil(ControllerConfig.addressEndpoints(from: "192.0.2.10:47834 nonsense"))
    }

    func testControllerStatusFollowsConnectionState() {
        XCTAssertEqual(SettingsControllerStatus(.live), .live)
        XCTAssertEqual(SettingsControllerStatus(.connecting), .connecting)
        XCTAssertEqual(SettingsControllerStatus(.reconnecting(attempt: 2, since: .now)), .connecting)
        XCTAssertEqual(SettingsControllerStatus(.offline(lastUpdated: nil, error: nil)), .offline)
        XCTAssertEqual(SettingsControllerStatus(.offlineUnreadable(lastUpdated: nil, error: nil)), .offline)
        XCTAssertEqual(SettingsControllerStatus(.unauthorized), .signInNeeded)
        XCTAssertEqual(SettingsControllerStatus.signInNeeded.text, "Sign in needed")
    }

    func testControllerKindAndAddressText() {
        XCTAssertEqual(controllerKindText(.claudeCode), "Claude Code")
        XCTAssertEqual(controllerKindText(.stockade), "Stockade")
        XCTAssertEqual(controllerKindText(.unknown("codex")), "codex")
        XCTAssertEqual(controllerAddressText(URL(string: "https://192.0.2.10:47834")), "192.0.2.10:47834")
        XCTAssertEqual(controllerAddressText(URL(string: "http://127.0.0.1:47832")), "127.0.0.1:47832")
        XCTAssertEqual(controllerAddressText(nil), "No address")
    }

    func testDraftReportsTheFirstProblem() {
        XCTAssertEqual(AddControllerDraft(name: " ", addresses: "192.0.2.10:47834").problem, .nameMissing)
        XCTAssertEqual(AddControllerDraft(name: "Mustafar", addresses: "").problem, .addressesInvalid)
        XCTAssertEqual(AddControllerDraft(name: "Mustafar", addresses: "mustafar:47834").problem, .addressesInvalid)
        XCTAssertNil(AddControllerDraft(name: "Mustafar", addresses: "192.0.2.10:47834").problem)
    }

    func testDraftMakesARelayConfigWithAUniqueID() throws {
        let draft = AddControllerDraft(name: "  Mustafar ", addresses: "192.0.2.10:47834\n100.64.0.5:47834")
        let config = try XCTUnwrap(draft.config(existing: [.mac, try ControllerID("mustafar")]))
        XCTAssertEqual(config.id.rawValue, "mustafar-2")
        XCTAssertEqual(config.displayName, "Mustafar")
        XCTAssertNil(config.directBaseURL)
        XCTAssertEqual(config.relayEndpoints, [URL(string: "https://192.0.2.10:47834")!, URL(string: "https://100.64.0.5:47834")!])
        XCTAssertNil(AddControllerDraft(name: "", addresses: "192.0.2.10:47834").config(existing: []))
    }
}
