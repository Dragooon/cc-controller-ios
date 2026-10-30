import XCTest
@testable import CCKit

final class PinnedSessionsTests: XCTestCase {
    func testPinsKeepPinOrderAndRoundTripThroughStorage() {
        var pins = PinnedSessions()
        pins.setPinned(true, key: "mac/b")
        pins.setPinned(true, key: "mustafar/a")
        pins.setPinned(true, key: "mac/b")
        pins.setPinned(true, key: "")

        XCTAssertEqual(pins.keys, ["mustafar/a", "mac/b"])
        XCTAssertEqual(pins.position(of: "mac/b"), 1)
        XCTAssertNil(pins.position(of: "mac/c"))
        XCTAssertEqual(PinnedSessions(stored: pins.stored), pins)
    }

    func testUnpinAndStoredDuplicates() {
        var pins = PinnedSessions(stored: "mac/a\n\nmac/b\nmac/a\nmac/c")
        XCTAssertEqual(pins.keys, ["mac/a", "mac/b", "mac/c"])

        pins.setPinned(false, key: "mac/b")
        XCTAssertFalse(pins.contains("mac/b"))
        XCTAssertEqual(pins.stored, "mac/a\nmac/c")
    }
}
