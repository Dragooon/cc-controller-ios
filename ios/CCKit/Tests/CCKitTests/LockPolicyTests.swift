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

    func testChangingIntervalPreservesRecordedBackgroundDate() {
        var policy = LockTransitionPolicy()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(policy.shouldLock(on: .background, at: start))
        policy.setInterval(.immediately)

        XCTAssertTrue(policy.shouldLock(on: .active, at: start))
    }

    func testLockIntervalStoreRoundTripsNamedCasesAndDefaultsUnknownValues() {
        let suiteName = "LockPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = LockIntervalStore(userDefaults: defaults)

        XCTAssertEqual(store.interval, .default)
        for interval in LockInterval.allCases {
            store.set(interval)
            XCTAssertEqual(store.interval, interval)
        }

        defaults.removeObject(forKey: LockIntervalStore.storageKey)
        XCTAssertEqual(store.interval, .default)
        defaults.set("futureInterval", forKey: LockIntervalStore.storageKey)
        XCTAssertEqual(store.interval, .default)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPrivacyCoverIsSuppressedOnlyForLockedPhase() {
        let policy = LockPolicy()

        for isActive in [false, true] {
            for isBackgrounded in [false, true] {
                let expected = !isActive || isBackgrounded
                XCTAssertEqual(
                    policy.shouldShowPrivacyCover(isActive: isActive, isBackgrounded: isBackgrounded, isLocked: false),
                    expected,
                    "Unexpected cover state for active=\(isActive), backgrounded=\(isBackgrounded)"
                )
                XCTAssertFalse(
                    policy.shouldShowPrivacyCover(isActive: isActive, isBackgrounded: isBackgrounded, isLocked: true),
                    "Locked phase should remain visible for active=\(isActive), backgrounded=\(isBackgrounded)"
                )
            }
        }
    }
}
