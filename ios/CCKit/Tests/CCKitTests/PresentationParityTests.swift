import Foundation
import XCTest
@testable import CCKit

final class PresentationParityTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Australia/Sydney")!
    private let locale = Locale(identifier: "en_AU")

    func testWebGoldenParity() throws {
        let functions = [
            "actionGlyph", "stateLabel", "subagentStateLabel", "formatModelName", "formatTime",
            "formatCountdown", "chooseSpinnerVerb", "turnOutputTokens", "formatDuration", "formatTokenCount",
            "formatContextUsage", "sessionStateSegment", "buildStatusSegments", "sessionNavSubtitle",
            "resolveSendMessageTarget", "sendMessageSummary", "formatSendMessage", "earlierTurnCount",
            "displayText", "firstMeaningfulLine", "promptCollapse", "normalisePromptText", "toolArgument",
            "activityLineText", "sessionActivity", "nowSubtitle", "composeSessionState", "entryFields", "permissionCopy",
            "reconcileQueuedNote", "mergeTranscriptEntries", "groupTurns",
        ]
        for function in functions {
            let golden = try loadGolden(function)
            for testCase in golden.cases {
                let actual = try evaluate(function: function, input: testCase.input)
                XCTAssertEqual(actual, testCase.output, "Parity mismatch in \(function)/\(testCase.name)")
            }
        }
    }

    func testSendMessageAcceptsFixtureRecipientAndOmitsEmptyTargetSeparator() {
        XCTAssertEqual(
            formatSendMessage(args: ["recipient": .string("engineer"), "message": .string("Polish four defects")]),
            "→ engineer · Polish four defects"
        )
        XCTAssertEqual(
            formatSendMessage(args: ["message": .string("Please polish the evidence summary")]),
            "→ Please polish the evidence summary"
        )
    }

    func testToolTallyUsesNativeSeparator() {
        // app/app.js:561-566 defines the web tally; native intentionally uses one middle dot.
        let run = ToolRun(entries: [
            ToolEntry(tool: "Read"), ToolEntry(tool: "Bash"), ToolEntry(tool: "Bash"),
        ])
        XCTAssertEqual(run.tallyText, "Read · Bash ×2")
        XCTAssertNotEqual(run.tallyText, "Read  Bash ×2")
    }

    func testGroupingTenThousandEntriesIsFast() {
        // app/app.js:791-797 defines the idle-last-assistant worked-footer condition.
        let entries = (0..<10_000).map { index in
            TranscriptEntry.assistant(AssistantEntry(id: "a\(index)", ts: Date(timeIntervalSince1970: Double(index)), text: "reply"))
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let turns = groupTranscript(entries: entries, working: false, now: Date())
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertEqual(turns.count, 1)
        XCTAssertLessThan(elapsedMs, 50, "10,000-entry grouping took \(elapsedMs) ms")
        print("10,000-entry grouping: \(elapsedMs) ms")
    }

    private func evaluate(function: String, input: JSONValue) throws -> JSONValue {
        switch function {
        case "groupTurns": return try groupTurnsParity(input)
        case "actionGlyph": return .string(actionGlyph(state: input.stringValue))
        case "stateLabel": return .string(stateLabel(state: input.stringValue))
        case "subagentStateLabel": return .string(subagentStateLabel(state: input.stringValue))
        case "formatModelName": return .string(formatModelName(input.stringValue))
        case "formatTime":
            return .string(formatTime(try decodeDate(input), timeZone: timeZone, locale: locale))
        case "formatCountdown": return .string(formatCountdown(input.doubleValue))
        case "chooseSpinnerVerb": return .string(chooseSpinnerVerb(random: input.doubleValue))
        case "turnOutputTokens":
            let entries = try decode([TranscriptEntry].self, from: input)
            return entriesOutput(turnOutputTokens(entries))
        case "formatDuration": return .string(formatDuration(input.doubleValue))
        case "formatTokenCount": return .string(formatTokenCount(input.doubleValue))
        case "formatContextUsage":
            let values = try input.arrayValues
            return .string(formatContextUsage(try decode(Usage.self, from: values[0]), expanded: values[1].boolValue))
        case "sessionStateSegment":
            let values = try input.arrayValues
            return .string(sessionStateSegment(try decode(Session.self, from: values[0]), now: try decodeDate(values[1])))
        case "buildStatusSegments":
            let values = try input.arrayValues
            let options = try values[1].objectValues
            return .array(buildStatusSegments(try decode(Session.self, from: values[0]), now: try decodeDate(options["now"]!), contextExpanded: options["contextExpanded"]?.boolValue ?? false).map(JSONValue.string))
        case "sessionNavSubtitle":
            let values = try input.arrayValues
            return .string(sessionNavSubtitle(try decode(Session.self, from: values[0]), now: try decodeDate(values[1]), timeZone: timeZone, locale: locale))
        case "resolveSendMessageTarget":
            let values = try input.arrayValues
            return .string(resolveSendMessageTarget(values[0].stringValue, subagents: try decode([Subagent].self, from: values[1])))
        case "sendMessageSummary": return .string(sendMessageSummary(args: try input.objectValues))
        case "formatSendMessage":
            let values = try input.arrayValues
            return .string(formatSendMessage(args: try values[0].objectValues, subagents: try decode([Subagent].self, from: values[1])))
        case "earlierTurnCount":
            let values = try input.arrayValues
            return .number(Double(earlierTurnCount(totalTurns: values[0].intValue, visibleTurns: values[1].intValue)))
        case "displayText": return .string(displayText(input.stringValue))
        case "firstMeaningfulLine": return .string(firstMeaningfulLine(input.stringValue))
        case "promptCollapse":
            let values = try input.arrayValues
            let options = values.count > 1 ? try values[1].objectValues : [:]
            let result = promptCollapse(values[0].stringValue, maxLines: options["maxLines"]?.intValue ?? 8, collapsedLines: options["collapsedLines"]?.intValue ?? 4, charsPerLine: options["charsPerLine"]?.intValue ?? 48, renderedLines: options["renderedLines"]?.intValue, hasPaste: options["hasPaste"]?.boolValue ?? false)
            return try encode(result)
        case "normalisePromptText": return try encode(normalisePromptText(input.stringValue))
        case "toolArgument":
            let values = try input.arrayValues
            return .string(toolArgument(values[0].stringValue, args: values[1]))
        case "activityLineText": return .string(activityLineText(try decode(Session.self, from: input)))
        case "sessionActivity": return sessionActivityParity(try decode(Session.self, from: input))
        case "nowSubtitle":
            let values = try input.arrayValues
            return .string(nowSubtitle(total: values[0].intValue, needsYou: values[1].intValue))
        case "composeSessionState":
            let values = try input.arrayValues
            return .string(composeSessionState(try decode(Session.self, from: values[0]), now: try decodeDate(values[1]), timeZone: timeZone, locale: locale))
        case "entryFields":
            return entryFieldsParity(entryFields(try decode(TranscriptEntry.self, from: input)))
        case "permissionCopy":
            return try encode(permissionCopy(try decode(Approval.self, from: input), timeZone: timeZone, locale: locale))
        case "reconcileQueuedNote":
            let values = try input.arrayValues
            return try encode(reconcileQueuedNote(try decode([QueuedNote].self, from: values[0]), promptEntry: try decode(TranscriptEntry.self, from: values[1])))
        case "mergeTranscriptEntries":
            let values = try input.arrayValues
            let merged = mergeTranscriptEntries(snapshot: try decode([TranscriptEntry].self, from: values[0]), local: try decode([TranscriptEntry].self, from: values[1]))
            return .array(merged.map(transcriptEntryParity))
        default: throw XCTSkip("No evaluator for \(function)")
        }
    }

    private func sessionActivityParity(_ session: Session) -> JSONValue {
        switch sessionActivity(session) {
        case .needsYou: return .object(["kind": .string("needs_you")])
        case .working: return .object(["kind": .string("working")])
        case .background(let agents, let shells):
            return .object(["kind": .string("background"), "agents": .number(Double(agents)), "shells": .number(Double(shells))])
        case .idle: return .object(["kind": .string("idle")])
        }
    }

    private func groupTurnsParity(_ input: JSONValue) throws -> JSONValue {
        let object = try input.objectValues
        let entries = try decode([TranscriptEntry].self, from: object["entries"]!)
        let turns = groupTurns(entries: entries, working: object["working"]?.boolValue ?? false, now: try decodeDate(JSONValue.string(object["now"]?.stringValue ?? "")))
        return .array(turns.map { turn in
            var value: [String: JSONValue] = [
                "id": .string(turn.id), "prompts": .array(turn.prompts.map(promptParity)),
                "items": .array(turn.items.map(itemParity)), "end": turn.end.map { .string($0.id ?? "") } ?? .null,
                "durationMs": .number(Double(turn.durationMs)), "hasBody": .bool(turn.hasBody),
                "live": .bool(turn.live), "worked": .bool(turn.hasWorkedFooter),
            ]
            if value["id"] == .string("") { value["id"] = .string("turn") }
            return .object(value)
        })
    }

    private func promptParity(_ entry: PromptEntry) -> JSONValue {
        .object(["id": entry.id.map(JSONValue.string) ?? .null, "kind": .string("prompt"), "text": .string(entry.text ?? entry.command ?? "")])
    }

    private func itemParity(_ item: TurnItem) -> JSONValue {
        switch item {
        case .tools(let run):
            return .object(["kind": .string("tools"), "id": .string(item.id), "count": .number(Double(run.entries.count)), "running": .bool(run.isRunning), "tools": .array(run.entries.map { .string($0.tool ?? "unknown") }), "label": .string(run.label), "tally": .array(run.tally.map { .array([.string($0.tool), .number(Double($0.count))]) })])
        default: return .object(["kind": .string(item.kind), "id": .string(item.id)])
        }
    }

    private func transcriptEntryParity(_ entry: TranscriptEntry) -> JSONValue {
        var object = (try? encode(entry).objectValues) ?? [:]
        object["kind"] = .string(entry.kind)
        return .object(object)
    }

    private func entryFieldsParity(_ fields: EntryFields) -> JSONValue {
        let date = fields.time.map { CCDateCoding.format($0) } ?? ""
        switch fields.kind {
        case "prompt":
            return .object(["kind": .string(fields.kind), "text": .string(fields.text), "attachments": .array(fields.attachments.map(JSONValue.string)), "paste": fields.paste.map { try! encode($0) } ?? .null, "command": fields.command.map(JSONValue.string) ?? .null])
        case "assistant":
            return .object(["kind": .string(fields.kind), "text": .string(fields.text), "model": fields.model.map(JSONValue.string) ?? .null])
        case "tool":
            return .object(["kind": .string(fields.kind), "toolUseId": .string(fields.toolUseId), "tool": .string(fields.tool), "args": fields.args, "result": .string(fields.result), "summary": .string(fields.summary), "state": .string(fields.state), "time": .string(date)])
        case "subagent":
            return .object(["kind": .string(fields.kind), "toolUseId": .string(fields.toolUseId), "agent": .string(fields.agent), "agentId": .string(fields.agentId), "text": .string(fields.text), "result": .string(fields.result), "state": .string(fields.state), "startedAt": fields.startedAt.map { .string(CCDateCoding.format($0)) } ?? .null, "finishedAt": fields.finishedAt.map { .string(CCDateCoding.format($0)) } ?? .null])
        case "subagent_result":
            return .object(["kind": .string(fields.kind), "toolUseId": .string(fields.toolUseId), "agent": .string(fields.agent), "agentId": .string(fields.agentId), "text": .string(fields.text), "result": .string(fields.result), "state": .string(fields.state), "durationMs": fields.durationMs.map { .number(Double($0)) } ?? .null])
        case "interrupt": return .object(["kind": .string(fields.kind)])
        case "compaction": return .object(["kind": .string(fields.kind), "text": .string(fields.text), "time": .string(date)])
        case "decision": return .object(["kind": .string(fields.kind), "text": .string(fields.text), "behavior": .string(fields.behavior)])
        case "file": return .object(["kind": .string(fields.kind), "name": .string(fields.name), "size": .number(Double(fields.size)), "mime": .string(fields.mime), "url": .string(fields.url)])
        default: return .object(["kind": .string(fields.kind), "text": .string(fields.text)])
        }
    }

    private func loadGolden(_ function: String) throws -> GoldenFile {
        guard let url = Bundle.module.url(forResource: function, withExtension: "json") else { throw NSError(domain: "Parity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing golden \(function)"]) }
        return try decode(GoldenFile.self, data: Data(contentsOf: url))
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder.ccKit().decode(type, from: try JSONEncoder.ccKit().encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        try JSONDecoder.ccKit().decode(type, from: data)
    }

    private func decodeDate(_ value: JSONValue) throws -> Date {
        if case .number(let milliseconds) = value { return Date(timeIntervalSince1970: milliseconds / 1000) }
        return try decode(Date.self, from: value)
    }

    private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder.ccKit().decode(JSONValue.self, from: JSONEncoder.ccKit().encode(value))
    }

    private func entriesOutput(_ value: Int?) -> JSONValue {
        value.map { .number(Double($0)) } ?? .null
    }
}

private struct GoldenFile: Decodable {
    let function: String
    let cases: [GoldenCase]
}

private struct GoldenCase: Decodable {
    let name: String
    let input: JSONValue
    let output: JSONValue
}

private extension JSONValue {
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var doubleValue: Double { if case .number(let value) = self { return value }; return 0 }
    var intValue: Int { Int(doubleValue) }
    var boolValue: Bool { if case .bool(let value) = self { return value }; return false }
    var arrayValues: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    var objectValues: [String: JSONValue] { if case .object(let value) = self { return value }; return [:] }
}
