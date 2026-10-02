import Foundation
import XCTest
@testable import CCKit

final class LockPolicyTests: XCTestCase {
    func testBackgroundThenInactiveAndActiveAfterDefaultIntervalLocks() {
        var policy = LockTransitionPolicy()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(policy.shouldLock(on: .background, at: start))
        XCTAssertFalse(policy.shouldLock(on: .inactive, at: start.addingTimeInterval(6 * 60)))
        XCTAssertTrue(policy.shouldLock(on: .active, at: start.addingTimeInterval(6 * 60)))
    }

    func testBackgroundThenActiveBeforeDefaultIntervalDoesNotLock() {
        var policy = LockTransitionPolicy()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(policy.shouldLock(on: .background, at: start))
        XCTAssertFalse(policy.shouldLock(on: .inactive, at: start.addingTimeInterval(2 * 60)))
        XCTAssertFalse(policy.shouldLock(on: .active, at: start.addingTimeInterval(2 * 60)))
    }

    func testInactiveAndActiveWithoutBackgroundNeverLocks() {
        var policy = LockTransitionPolicy()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(policy.shouldLock(on: .inactive, at: start))
        XCTAssertFalse(policy.shouldLock(on: .active, at: start.addingTimeInterval(60 * 60)))
    }

    func testActiveConsumesBackgroundDate() {
        var policy = LockTransitionPolicy()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(policy.shouldLock(on: .background, at: start))
        XCTAssertFalse(policy.shouldLock(on: .active, at: start.addingTimeInterval(60)))
        XCTAssertFalse(policy.shouldLock(on: .inactive, at: start.addingTimeInterval(10 * 60)))
        XCTAssertFalse(policy.shouldLock(on: .active, at: start.addingTimeInterval(10 * 60)))
    }

    func testImmediatelyLocksAfterBackgroundButNotAfterInactive() {
        var policy = LockTransitionPolicy(policy: LockPolicy(interval: .immediately))
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(policy.shouldLock(on: .background, at: start))
        XCTAssertTrue(policy.shouldLock(on: .active, at: start))
        XCTAssertFalse(policy.shouldLock(on: .inactive, at: start))
        XCTAssertFalse(policy.shouldLock(on: .active, at: start.addingTimeInterval(60)))
    }
}
