import Foundation
import XCTest
@testable import CCKit

final class TranscriptModelsTests: XCTestCase {
    func testTranscriptPageKeepsMalformedKnownKindBetweenValidEntries() throws {
        let data = Data("""
        {"entries":[{"kind":"assistant","id":"before","text":"Before"},{"kind":"prompt","id":"bad","paste":[]},{"kind":"assistant","id":"after","text":"After"}],"total":3,"hasMore":false}
        """.utf8)

        let page = try JSONDecoder.ccKit().decode(TranscriptPage.self, from: data)

        XCTAssertEqual(page.entries.count, 3)
        XCTAssertEqual(page.entries.first?.id, "before")
        XCTAssertEqual(page.entries.last?.id, "after")
        guard case .unknown(let kind, _) = page.entries[1] else { return XCTFail("Expected malformed entry to be unknown") }
        XCTAssertEqual(kind, "malformed")
    }

    func testEveryTranscriptKindRoundTripsWithKindField() throws {
        let entries: [(String, TranscriptEntry)] = [
            ("prompt", .prompt(PromptEntry(id: "prompt", text: "Ask"))),
            ("assistant", .assistant(AssistantEntry(id: "assistant", text: "Answer"))),
            ("tool", .tool(ToolEntry(id: "tool", tool: "Bash", state: .done))),
            ("subagent", .subagent(SubagentEntry(id: "subagent", agent: "worker"))),
            ("subagent_result", .subagentResult(SubagentResultEntry(id: "subagent-result", result: "Done"))),
            ("compaction", .compaction(CompactionEntry(id: "compaction", text: "Summary"))),
            ("interrupt", .interrupt(InterruptEntry(id: "interrupt"))),
            ("turn_end", .turnEnd(TurnEndEntry(id: "turn-end", durationMs: 42))),
            ("decision", .decision(DecisionEntry(id: "decision", behavior: .allow))),
            ("file", .file(FileEntry(id: "file", name: "report.txt"))),
            ("attention", .attention(AttentionEntry(id: "attention", text: "Look here"))),
            ("future_kind", .unknown(kind: "future_kind", raw: .object([
                "kind": .string("future_kind"),
                "id": .string("unknown"),
                "payload": .number(7)
            ])))
        ]

        for (kind, entry) in entries {
            let data = try JSONEncoder.ccKit().encode(entry)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["kind"] as? String, kind, "Encoded entry omitted its kind")
            XCTAssertEqual(try JSONDecoder.ccKit().decode(TranscriptEntry.self, from: data), entry, "Round-trip changed \(kind)")
        }
    }

    func testMain7420DirectPayloadEncodingOmitsKindAndDecodesAsUnknown() throws {
        let value = AssistantEntry(id: "baseline", text: "Main payload")
        let data = try JSONEncoder.ccKit().encode(value)
        let decoded = try JSONDecoder.ccKit().decode(TranscriptEntry.self, from: data)

        XCTAssertFalse((try JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.contains("kind") == true)
        XCTAssertEqual(decoded, .unknown(kind: "unknown", raw: .object([
            "id": .string("baseline"),
            "text": .string("Main payload")
        ])))
        print("MAIN_7420_BASELINE kind_present=false decoded_kind=unknown")
    }

    func testEncoding400MixedEntriesReportsBranchAndSinglePassMilliseconds() throws {
        let samples: [TranscriptEntry] = [
            .prompt(PromptEntry(id: "prompt", text: "Ask")),
            .assistant(AssistantEntry(id: "assistant", text: "Answer")),
            .tool(ToolEntry(id: "tool", tool: "Bash", state: .done)),
            .subagent(SubagentEntry(id: "subagent", agent: "worker")),
            .subagentResult(SubagentResultEntry(id: "subagent-result", result: "Done")),
            .compaction(CompactionEntry(id: "compaction", text: "Summary")),
            .interrupt(InterruptEntry(id: "interrupt")),
            .turnEnd(TurnEndEntry(id: "turn-end", durationMs: 42)),
            .decision(DecisionEntry(id: "decision", behavior: .allow)),
            .file(FileEntry(id: "file", name: "report.txt")),
            .attention(AttentionEntry(id: "attention", text: "Look here")),
            .unknown(kind: "future_kind", raw: .object(["kind": .string("future_kind"), "id": .string("unknown")]))
        ]
        let entries = Array((0..<400).map { samples[$0 % samples.count] })
        let branch = try measureMinimumMilliseconds(repetitions: 3) {
            entries.reduce(into: 0) { total, entry in
                total += (try? branchEncoding(entry).count) ?? 0
            }
        }
        let singlePass = try measureMinimumMilliseconds(repetitions: 3) {
            entries.reduce(into: 0) { total, entry in
                total += (try? JSONEncoder.ccKit().encode(entry).count) ?? 0
            }
        }

        XCTAssertGreaterThan(branch.bytes, 0)
        XCTAssertGreaterThan(singlePass.bytes, 0)
        print("TRANSCRIPT_ENCODING_TIMING entries=400 branch_ms=\(String(format: "%.2f", branch.milliseconds)) single_pass_ms=\(String(format: "%.2f", singlePass.milliseconds))")
    }

    private func branchEncoding(_ entry: TranscriptEntry) throws -> Data {
        let encoded: Data
        switch entry {
        case .prompt(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .assistant(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .tool(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .subagent(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .subagentResult(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .compaction(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .interrupt(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .turnEnd(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .decision(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .file(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .attention(let value): encoded = try JSONEncoder.ccKit().encode(value)
        case .unknown(let kind, let raw):
            guard case .object(var object) = raw else { return try JSONEncoder.ccKit().encode(raw) }
            object["kind"] = .string(kind)
            return try JSONEncoder.ccKit().encode(JSONValue.object(object))
        }
        guard case .object(var object) = try JSONDecoder.ccKit().decode(JSONValue.self, from: encoded) else {
            throw EncodingError.invalidValue(entry, EncodingError.Context(codingPath: [], debugDescription: "Transcript entry is not an object"))
        }
        object["kind"] = .string(entry.kind)
        return try JSONEncoder.ccKit().encode(JSONValue.object(object))
    }

    private func measureMinimumMilliseconds(repetitions: Int, operation: () -> Int) throws -> (milliseconds: Double, bytes: Int) {
        var best = Double.infinity
        var bytes = 0
        for _ in 0..<repetitions {
            let start = DispatchTime.now().uptimeNanoseconds
            bytes = operation()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            best = min(best, elapsed)
        }
        return (best, bytes)
    }
}
