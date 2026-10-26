import Foundation
import XCTest
@testable import CCKit

final class ScrollDiagnosticsTests: XCTestCase {
    func testOvershootConditionIncludesTheOnePointBoundary() {
        let atBoundary = geometry(contentHeight: 404, insetTop: 1, visibleMinY: 402)
        let belowBoundary = geometry(contentHeight: 404, insetTop: 1, visibleMinY: 400.9)

        XCTAssertEqual(
            ScrollBlankCondition.kind(
                geometry: atBoundary,
                builtRowCount: 1,
                displayRowCount: 10,
                queuedNoteCount: 0
            ),
            .overshoot
        )
        XCTAssertNil(
            ScrollBlankCondition.kind(
                geometry: belowBoundary,
                builtRowCount: 1,
                displayRowCount: 10,
                queuedNoteCount: 0
            )
        )
    }

    func testContentSmallerThanViewportWithNegativeOffsetIsNotOvershoot() {
        let geometry = geometry(
            contentOffsetY: -367.67,
            contentHeight: 404,
            insetTop: 367.67,
            visibleMinY: -367.67,
            visibleMaxY: 500
        )

        XCTAssertNil(
            ScrollBlankCondition.kind(
                geometry: geometry,
                builtRowCount: 1,
                displayRowCount: 10,
                queuedNoteCount: 0
            )
        )
    }

    func testBlankConditionIgnoresOffscreenGeometry() {
        for containerHeight in [CGFloat.zero, -1] {
            XCTAssertNil(
                ScrollBlankCondition.kind(
                    geometry: geometry(contentHeight: 36, containerHeight: containerHeight, visibleMinY: 35),
                    builtRowCount: 0,
                    displayRowCount: 10,
                    queuedNoteCount: 0
                ),
                "Offscreen geometry should not start a blank candidate"
            )
        }
    }

    func testUnbuiltConditionRequiresRowsOrNotesAndNoBuiltRows() {
        let geometry = geometry(contentHeight: 0)
        XCTAssertEqual(
            ScrollBlankCondition.kind(
                geometry: geometry,
                builtRowCount: 0,
                displayRowCount: 1,
                queuedNoteCount: 0
            ),
            .unbuilt
        )
        XCTAssertEqual(
            ScrollBlankCondition.kind(
                geometry: geometry,
                builtRowCount: 0,
                displayRowCount: 0,
                queuedNoteCount: 1
            ),
            .unbuilt
        )
        XCTAssertNil(
            ScrollBlankCondition.kind(
                geometry: geometry,
                builtRowCount: 0,
                displayRowCount: 0,
                queuedNoteCount: 0
            )
        )
        XCTAssertNil(
            ScrollBlankCondition.kind(
                geometry: geometry,
                builtRowCount: 1,
                displayRowCount: 1,
                queuedNoteCount: 0
            )
        )
    }

    func testRecentEventRingKeepsTheLastThirtyEvents() {
        var ring = ScrollDiagnosticEventRing(capacity: 30)
        for index in 0..<31 {
            ring.append(ScrollDiagnosticEvent(name: "event", newValue: Double(index)))
        }

        XCTAssertEqual(ring.count, 30)
        XCTAssertEqual(ring.values.first?.newValue, 1)
        XCTAssertEqual(ring.values.last?.newValue, 30)
    }

    func testFileStoreCapsDiagnosticsAtTwoHundredLines() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scroll-diagnostics-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScrollDiagnosticsFileStore(url: url)
        let entry = makeEntry()

        for _ in 0..<205 {
            let appended = await store.append(entry)
            XCTAssertTrue(appended)
        }

        let lines = await store.readLines()
        XCTAssertEqual(lines.count, 200)
        XCTAssertTrue(lines.allSatisfy { !$0.isEmpty })
    }

    func testEncodedEntryContainsOnlyDiagnosticKeys() throws {
        let data = try JSONEncoder().encode(makeEntry())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            [
                "timestamp", "appVersion", "build", "sessionIDPrefix", "kind", "geometry",
                "rowsCount", "notesCount", "isPinnedToBottom", "userHasScrolled", "recentEvents",
                "corrections", "recovered", "msToRecover",
            ]
        )
        let geometry = try XCTUnwrap(object["geometry"] as? [String: Any])
        XCTAssertEqual(
            Set(geometry.keys),
            [
                "contentOffsetY", "contentHeight", "containerHeight", "insetTop", "insetBottom",
                "visibleRectMinY", "visibleRectMaxY",
            ]
        )
    }

    private func geometry(
        contentOffsetY: CGFloat = 0,
        contentHeight: CGFloat,
        containerHeight: CGFloat = 100,
        insetTop: CGFloat = 0,
        insetBottom: CGFloat = 0,
        visibleMinY: CGFloat = 0,
        visibleMaxY: CGFloat = 100
    ) -> ScrollGuardGeometry {
        ScrollGuardGeometry(
            contentOffsetY: contentOffsetY,
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            insetTop: insetTop,
            insetBottom: insetBottom,
            visibleMinY: visibleMinY,
            visibleMaxY: visibleMaxY
        )
    }

    private func makeEntry() -> ScrollDiagnosticEntry {
        ScrollDiagnosticEntry(
            timestamp: "2026-10-20T00:00:00Z",
            appVersion: "0.1.0",
            build: "1",
            sessionIDPrefix: "12345678",
            kind: .overshoot,
            geometry: ScrollDiagnosticGeometry(geometry(contentHeight: 404)),
            rowsCount: 10,
            notesCount: 0,
            isPinnedToBottom: true,
            userHasScrolled: false,
            recentEvents: [ScrollDiagnosticEvent(name: "rows", newValue: 10)],
            corrections: 1,
            recovered: true,
            msToRecover: 500
        )
    }
}
