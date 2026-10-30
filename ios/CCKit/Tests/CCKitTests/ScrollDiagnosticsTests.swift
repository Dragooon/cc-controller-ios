import Foundation
import XCTest
@testable import CCKit

final class ScrollDiagnosticsTests: XCTestCase {
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
                "rowsCount", "notesCount", "isPinnedToBottom", "userHasScrolled", "lifecycle",
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
            kind: .unbuilt,
            geometry: ScrollDiagnosticGeometry(geometry(contentHeight: 404)),
            rowsCount: 10,
            notesCount: 0,
            isPinnedToBottom: true,
            userHasScrolled: false
        )
    }
}
