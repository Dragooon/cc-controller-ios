import Foundation
import XCTest
@testable import CCKit

@MainActor
final class TranscriptLifecycleDiagnosticsTests: XCTestCase {
    func testRemountWithinFiveSecondsWritesAndAfterSixSecondsDoesNot() {
        let clock = TestClock()
        var engine = TranscriptLifecycleTriggerEngine(clock: { clock.now })

        clock.now = date(0)
        XCTAssertEqual(engine.ingest(.transcriptDisappear(sessionID: "session-123456")), [])
        clock.now = date(5)
        XCTAssertEqual(
            engine.ingest(.transcriptAppear(sessionID: "session-123456")),
            [.remount(sessionID: "session-123456")]
        )

        clock.now = date(6)
        _ = engine.ingest(.transcriptDisappear(sessionID: "session-123456"))
        clock.now = date(12)
        XCTAssertEqual(engine.ingest(.transcriptAppear(sessionID: "session-123456")), [])
    }

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

    func testSentinelUnbuiltWritesAfterThreeHundredMillisecondsWhenPinnedAndIdle() {
        let clock = TestClock()
        var engine = TranscriptLifecycleTriggerEngine(clock: { clock.now })
        let session = "session-123456"

        clock.now = date(0)
        _ = engine.ingest(.rowsMounted(sessionID: session, mounted: true))
        _ = engine.ingest(.pinned(sessionID: session, pinned: true))
        _ = engine.ingest(.scrollIdle(sessionID: session, idle: true))
        _ = engine.ingest(.sentinelBuilt(sessionID: session, built: false))
        clock.now = date(0.299)
        XCTAssertEqual(engine.ingest(.sentinelCheck(sessionID: session)), [])
        clock.now = date(0.3)
        XCTAssertEqual(
            engine.ingest(.sentinelCheck(sessionID: session)),
            [.sentinelUnbuilt(sessionID: session)]
        )
    }

    func testSentinelUnbuiltDoesNotWriteWhileUserIsScrolling() {
        let clock = TestClock()
        var engine = TranscriptLifecycleTriggerEngine(clock: { clock.now })
        let session = "session-123456"

        clock.now = date(0)
        _ = engine.ingest(.rowsMounted(sessionID: session, mounted: true))
        _ = engine.ingest(.sentinelBuilt(sessionID: session, built: false))
        _ = engine.ingest(.scrollIdle(sessionID: session, idle: false))
        clock.now = date(1)
        XCTAssertEqual(engine.ingest(.sentinelCheck(sessionID: session)), [])
    }

    func testSentinelCorrectionScrollsWhenRowsAreBuiltAndPinned() {
        XCTAssertEqual(sentinelCorrection(builtRowCount: 1, pinned: true), .scroll)
        XCTAssertEqual(sentinelCorrection(builtRowCount: 236, pinned: true), .scroll)
    }

    func testSentinelCorrectionRebuildsWhenNoRowsAreBuilt() {
        XCTAssertEqual(sentinelCorrection(builtRowCount: 0, pinned: true), .rebuild)
    }

    func testSentinelCorrectionDoesNothingWhenNotPinned() {
        XCTAssertEqual(sentinelCorrection(builtRowCount: 236, pinned: false), .none)
        XCTAssertEqual(sentinelCorrection(builtRowCount: 0, pinned: false), .none)
    }

    func testSentinelCorrectionIsEligibleAfterResume() {
        let clock = TestClock()
        var engine = TranscriptLifecycleTriggerEngine(clock: { clock.now })
        let session = "session-resume"
        makeSentinelEligible(&engine, session: session)

        clock.now = date(0.3)
        let result = engine.ingestWithCorrections(.sentinelCheck(sessionID: session))
        XCTAssertEqual(result.triggers, [.sentinelUnbuilt(sessionID: session)])
        XCTAssertEqual(result.corrections, [.sentinelUnbuilt(sessionID: session)])
    }

    func testSentinelCorrectionIsEligibleAfterSend() {
        let clock = TestClock()
        var engine = TranscriptLifecycleTriggerEngine(clock: { clock.now })
        let session = "session-send"
        makeSentinelEligible(&engine, session: session)

        clock.now = date(0.3)
        let result = engine.ingestWithCorrections(.sentinelCheck(sessionID: session))
        XCTAssertEqual(result.corrections, [.sentinelUnbuilt(sessionID: session)])
    }

    func testSentinelCorrectionIsNotRateLimitedWithDiagnosticTrigger() {
        let clock = TestClock()
        var engine = TranscriptLifecycleTriggerEngine(clock: { clock.now })
        let session = "session-throttle"
        makeSentinelEligible(&engine, session: session)

        clock.now = date(0.3)
        XCTAssertEqual(engine.ingestWithCorrections(.sentinelCheck(sessionID: session)).triggers.count, 1)
        _ = engine.ingest(.sentinelBuilt(sessionID: session, built: true))
        _ = engine.ingest(.sentinelBuilt(sessionID: session, built: false))
        clock.now = date(1)
        let result = engine.ingestWithCorrections(.sentinelCheck(sessionID: session))
        XCTAssertEqual(result.triggers, [])
        XCTAssertEqual(result.corrections, [.sentinelUnbuilt(sessionID: session)])
    }

    func testCorrectedDiagnosticFieldsRemainHonest() {
        let entry = ScrollDiagnosticEntry(
            timestamp: "1970-01-01T00:00:00.000Z",
            appVersion: "1.0",
            build: "1",
            sessionIDPrefix: "session-",
            kind: .sentinelUnbuilt,
            geometry: ScrollDiagnosticGeometry(
                ScrollGuardGeometry(
                    contentOffsetY: 100,
                    contentHeight: 500,
                    containerHeight: 678,
                    insetTop: 0,
                    insetBottom: 0,
                    visibleMinY: 100,
                    visibleMaxY: 778
                )
            ),
            rowsCount: 20,
            notesCount: 0,
            isPinnedToBottom: true,
            userHasScrolled: false,
            recentEvents: [ScrollDiagnosticEvent(name: "rebuild", newValue: 1)],
            corrections: 1,
            recovered: true,
            msToRecover: 500
        )

        XCTAssertEqual(entry.kind, .sentinelUnbuilt)
        XCTAssertEqual(entry.corrections, 1)
        XCTAssertTrue(entry.recovered)
        XCTAssertEqual(entry.msToRecover, 500)
    }

    func testTriggerThrottleIsPerKindForTenSeconds() {
        let clock = TestClock()
        var engine = TranscriptLifecycleTriggerEngine(clock: { clock.now })
        let session = "session-123456"

        clock.now = date(0)
        _ = engine.ingest(.transcriptDisappear(sessionID: session))
        clock.now = date(1)
        XCTAssertEqual(engine.ingest(.transcriptAppear(sessionID: session)).count, 1)
        clock.now = date(2)
        _ = engine.ingest(.transcriptDisappear(sessionID: session))
        clock.now = date(3)
        XCTAssertEqual(engine.ingest(.transcriptAppear(sessionID: session)), [])
        clock.now = date(11)
        _ = engine.ingest(.transcriptDisappear(sessionID: session))
        clock.now = date(12)
        XCTAssertEqual(engine.ingest(.transcriptAppear(sessionID: session)).count, 1)
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
        log.record(name: "transcript-appear", sessionID: "session-123456", detail: nil)
        let entry = ScrollDiagnosticEntry(
            timestamp: "1970-01-01T00:00:00.000Z",
            appVersion: "1.0",
            build: "469",
            sessionIDPrefix: "session-",
            kind: .remount,
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
            recentEvents: [],
            lifecycle: log.events,
            corrections: 0,
            recovered: false,
            msToRecover: 0
        )
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        print("SAMPLE_RECORD \(json)")
        XCTAssertTrue(json.contains("\"kind\":\"remount\""))
    }

    private func makeSentinelEligible(
        _ engine: inout TranscriptLifecycleTriggerEngine,
        session: String
    ) {
        _ = engine.ingest(.rowsMounted(sessionID: session, mounted: true))
        _ = engine.ingest(.pinned(sessionID: session, pinned: true))
        _ = engine.ingest(.scrollIdle(sessionID: session, idle: true))
        _ = engine.ingest(.sentinelBuilt(sessionID: session, built: false))
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    private final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
    }
}
