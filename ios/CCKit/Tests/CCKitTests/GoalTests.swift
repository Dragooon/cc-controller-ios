import Foundation
import XCTest
@testable import CCKit

final class GoalTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.ccKit().decode(T.self, from: Data(json.utf8))
    }

    func testAGoalEntryDecodesThroughTheUnknownKind() throws {
        let entry = try decode(TranscriptEntry.self, #"{"kind":"goal","id":"g1","ts":"2026-11-27T10:00:00.000Z","status":"met","condition":"All journeys pass","reason":"Done","iterations":3,"durationMs":720000}"#)
        XCTAssertEqual(entry.kind, "goal")
        XCTAssertEqual(entry.goal, GoalEntry(id: "g1", ts: entry.goal?.ts, status: "met", condition: "All journeys pass", reason: "Done", iterations: 3, durationMs: 720000))
        let prompt = try decode(TranscriptEntry.self, #"{"kind":"prompt","text":"hi"}"#)
        XCTAssertNil(prompt.goal)
    }

    func testCaptionsForEachGoalEvent() {
        XCTAssertEqual(goalCaption(GoalEntry(status: "set", condition: " Ship it "))?.text, "Goal: Ship it")
        XCTAssertNil(goalCaption(GoalEntry(status: "checked", condition: "Ship it", reason: "Not yet")))
        XCTAssertEqual(goalCaption(GoalEntry(status: "met", condition: "Ship it", iterations: 3, durationMs: 720000))?.text, "Goal met · 3 checks · 12m")
        XCTAssertEqual(goalCaption(GoalEntry(status: "met", condition: "Ship it", iterations: 1))?.text, "Goal met · 1 check")
        XCTAssertEqual(goalCaption(GoalEntry(status: "failed", condition: "Ship it", reason: "Needs the phone"))?.text, "Goal stopped: Needs the phone")
        XCTAssertEqual(goalCaption(GoalEntry(status: "cleared", condition: "Ship it"))?.text, "Goal cleared")
        XCTAssertNil(goalCaption(GoalEntry(status: "set", condition: "  ")))
    }

    func testDurationsAndTheStatusLine() {
        XCTAssertEqual(goalDurationText(seconds: 45), "45s")
        XCTAssertEqual(goalDurationText(seconds: 12 * 60 + 5), "12m")
        XCTAssertEqual(goalDurationText(seconds: 3600), "1h")
        XCTAssertEqual(goalDurationText(seconds: 3900), "1h 5m")
        let since = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(goalStatusLine(SessionGoal(condition: "A", since: since, checks: 2), now: since.addingTimeInterval(600)), "Goal · 10m · 2 checks")
        XCTAssertEqual(goalStatusLine(SessionGoal(condition: "A", since: nil, checks: 0), now: since), "Goal")
    }

    func testASessionCarriesItsGoalAndToleratesABadOne() throws {
        let session = try decode(Session.self, #"{"id":"s","goal":{"condition":"Gate passes","since":"2026-11-27T10:00:00.000Z","checks":1,"lastReason":"One left"}}"#)
        XCTAssertEqual(session.goal?.condition, "Gate passes")
        XCTAssertEqual(session.goal?.checks, 1)
        XCTAssertNil(try decode(Session.self, #"{"id":"s","goal":null}"#).goal)
        XCTAssertNil(try decode(Session.self, #"{"id":"s","goal":"weird"}"#).goal)
        // The app's saved copy keeps it.
        let saved = try JSONEncoder.ccKit().encode(session)
        XCTAssertEqual(try JSONDecoder.ccKit().decode(Session.self, from: saved).goal, session.goal)
    }

    func testASudoSwitchIsReadFromTheMessagePlatformNote() {
        let on = normalisePromptText("[platform: sudo mode on. You now run as madge-sudo.]\n[sender: shitiz | via: app]\nDeploy it")
        XCTAssertEqual(on.sudoSwitch, true)
        XCTAssertEqual(on.text, "Deploy it")
        let off = normalisePromptText("[platform: sudo mode off. You now run as madge.]\n[platform: Sudo changed while you were working, which cut off your last turn. Continue it if it still matters.]\n[sender: shitiz | via: app]\nThanks")
        XCTAssertEqual(off.sudoSwitch, false)
        XCTAssertNil(normalisePromptText("[sender: shitiz | via: app]\nHi").sudoSwitch)
        XCTAssertNil(normalisePromptText("[platform: sudo mode on. nope]").sudoSwitch, "only a real preamble counts")
    }
}
