import XCTest
@testable import CCKit

final class NativePresentationTests: XCTestCase {
    func testSessionsSubtitleOrdersActiveStatesAndOmitsZeroes() {
        let sessions = [
            Session(state: .working),
            Session(state: .needsYou),
            Session(state: .working),
        ]

        XCTAssertEqual(sessionsSubtitle(sessions), "1 needs you · 2 working")
    }

    func testSessionsSubtitleReturnsAllIdle() {
        XCTAssertEqual(sessionsSubtitle([Session(state: .idle), Session(state: .idle)]), "All idle")
    }

    func testSessionsSubtitleReturnsNilForEmptySessions() {
        XCTAssertNil(sessionsSubtitle([]))
    }
}
