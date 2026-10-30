import Foundation
import XCTest
@testable import CCKit

@MainActor
final class TranscriptLifecycleDiagnosticsTests: XCTestCase {
    func testReloadAfterTranscriptWrites() {
        var engine = TranscriptLifecycleTriggerEngine(clock: { Date(timeIntervalSince1970: 0) })

        XCTAssertEqual(
            engine.ingest(.screenBranch(screenID: "screen", sessionID: "session-123456", branch: .transcript)),
            []
        )
        XCTAssertEqual(
            engine.ingest(.screenBranch(screenID: "screen", sessionID: "session-123456", branch: .loadingUnloaded)),
            [.reload(sessionID: "session-123456")]
        )
    }

    func testReloadTriggerIsThrottledForTenSeconds() {
        let clock = TestClock()
        var engine = TranscriptLifecycleTriggerEngine(clock: { clock.now })
        let session = "session-123456"

        clock.now = date(0)
        _ = engine.ingest(.screenBranch(screenID: "screen", sessionID: session, branch: .transcript))
        clock.now = date(1)
        XCTAssertEqual(
            engine.ingest(.screenBranch(screenID: "screen", sessionID: session, branch: .loadingUnloaded)).count,
            1
        )
        clock.now = date(2)
        _ = engine.ingest(.screenBranch(screenID: "screen", sessionID: session, branch: .transcript))
        clock.now = date(3)
        XCTAssertEqual(
            engine.ingest(.screenBranch(screenID: "screen", sessionID: session, branch: .loadingUnloaded)),
            []
        )
        clock.now = date(11)
        _ = engine.ingest(.screenBranch(screenID: "screen", sessionID: session, branch: .transcript))
        clock.now = date(12)
        XCTAssertEqual(
            engine.ingest(.screenBranch(screenID: "screen", sessionID: session, branch: .loadingUnloaded)).count,
            1
        )
    }

    func testGapDiagnosticsFileCapsAtFiveHundredLines() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-gap-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TranscriptGapDiagnosticsFileStore(url: url)
        let record = TranscriptGapDiagnosticRecord(
            timestamp: "2026-10-29T00:00:00.000Z",
            name: "transcript-gap-fetch-failed",
            sessionID: "session-1",
            serverTotal: 42,
            confirmedTotal: 10,
            attempt: 1,
            errorType: "TestError"
        )

        for _ in 0..<505 {
            let appended = await store.append(record)
            XCTAssertTrue(appended)
        }

        let lines = await store.readLines()
        XCTAssertEqual(lines.count, 500)
        let decoded = try JSONDecoder().decode(TranscriptGapDiagnosticRecord.self, from: Data(lines.last!.utf8))
        XCTAssertEqual(decoded.serverTotal, 42)
        XCTAssertEqual(decoded.confirmedTotal, 10)
        XCTAssertEqual(decoded.errorType, "TestError")
    }

    func testLifecycleLogCapsAtSixtyFourAndRedactsSessionAndDetail() {
        let clock = TestClock()
        let log = TranscriptLifecycleLog(clock: { clock.now })
        clock.now = date(0)

        for index in 0..<65 {
            log.record(
                name: "event",
                sessionID: "1234567890abcdef",
                detail: String(repeating: "x", count: 100) + "\(index)"
            )
        }

        XCTAssertEqual(log.events.count, 64)
        XCTAssertEqual(log.events.first?.session, "12345678")
        XCTAssertEqual(log.events.first?.detail?.count, 39)
        XCTAssertEqual(log.events.first?.at, "1970-01-01T00:00:00.000Z")
    }

    func testSampleRecordJSON() throws {
        let log = TranscriptLifecycleLog(clock: { Date(timeIntervalSince1970: 0) })
        log.record(name: "screen-branch", sessionID: "session-123456", detail: "transcript")
        let entry = ScrollDiagnosticEntry(
            timestamp: "1970-01-01T00:00:00.000Z",
            appVersion: "1.0",
            build: "469",
            sessionIDPrefix: "session-",
            kind: .reload,
            geometry: ScrollDiagnosticGeometry(
                ScrollGuardGeometry(
                    contentOffsetY: 0,
                    contentHeight: 0,
                    containerHeight: 0,
                    insetTop: 0,
                    insetBottom: 0,
                    visibleMinY: 0,
                    visibleMaxY: 0
                )
            ),
            rowsCount: 0,
            notesCount: 0,
            isPinnedToBottom: false,
            userHasScrolled: false,
            lifecycle: log.events
        )
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        print("SAMPLE_RECORD \(json)")
        XCTAssertTrue(json.contains("\"kind\":\"reload\""))
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    private final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
    }
}
