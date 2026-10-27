import Foundation
import XCTest
@testable import CCKit

final class LockPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testColdLaunchWithoutUnlockStampLocks() {
        let policy = LockPolicy()

        XCTAssertTrue(policy.shouldLockOnColdLaunch(lastUnlockAt: nil, lastBackgroundAt: nil, now: start))
    }

    func testColdLaunchBeforeMaximumUnlockAgeDoesNotLockWithoutBackgroundStamp() {
        let policy = LockPolicy()

        XCTAssertFalse(policy.shouldLockOnColdLaunch(
            lastUnlockAt: start,
            lastBackgroundAt: nil,
            now: start.addingTimeInterval(59 * 60)
        ))
    }

    func testColdLaunchAtMaximumUnlockAgeLocks() {
        let policy = LockPolicy()

        XCTAssertTrue(policy.shouldLockOnColdLaunch(
            lastUnlockAt: start,
            lastBackgroundAt: nil,
            now: start.addingTimeInterval(60 * 60)
        ))
    }

    func testImmediatelyWithBackgroundStampLocksOnColdLaunch() {
        let policy = LockPolicy(interval: .immediately)

        XCTAssertTrue(policy.shouldLockOnColdLaunch(
            lastUnlockAt: start,
            lastBackgroundAt: start,
            now: start
        ))
    }

    func testForegroundAfterTwoMinutesWithRecentUnlockDoesNotLock() {
        let policy = LockPolicy(interval: .oneHour)

        XCTAssertFalse(policy.shouldLockOnForeground(
            lastUnlockAt: start.addingTimeInterval(-10 * 60),
            after: start.addingTimeInterval(-2 * 60),
            now: start
        ))
    }

    func testForegroundWithUnlockOlderThanMaximumAgeLocks() {
        let policy = LockPolicy(interval: .oneHour)

        XCTAssertTrue(policy.shouldLockOnForeground(
            lastUnlockAt: start.addingTimeInterval(-60 * 60),
            after: nil,
            now: start
        ))
    }

    func testUnlockExpiryEqualsLastUnlockPlusMaximumAge() {
        let policy = LockPolicy(maxUnlockAge: 17)

        XCTAssertEqual(
            policy.unlockExpiryDate(lastUnlockAt: start),
            start.addingTimeInterval(17)
        )
    }

    func testLockIntervalMigrationMapsFiveMinutesToOneHourExactlyOnce() {
        let suiteName = "LockPolicyTests.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("fiveMinutes", forKey: LockIntervalStore.storageKey)

        let firstStore = LockIntervalStore(userDefaults: defaults)
        XCTAssertEqual(firstStore.interval, .oneHour)
        XCTAssertTrue(defaults.bool(forKey: LockIntervalStore.migrationKey))

        defaults.set("fiveMinutes", forKey: LockIntervalStore.storageKey)
        let secondStore = LockIntervalStore(userDefaults: defaults)
        XCTAssertEqual(secondStore.interval, .fiveMinutes)
        defaults.removePersistentDomain(forName: suiteName)
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

    func testTransitionConsumesBackgroundDateAndTracksUnlockAge() {
        var policy = LockTransitionPolicy(
            policy: LockPolicy(maxUnlockAge: 60 * 60),
            lastUnlockAt: start
        )

        XCTAssertFalse(policy.shouldLock(on: .background, at: start.addingTimeInterval(60)))
        XCTAssertFalse(policy.shouldLock(on: .active, at: start.addingTimeInterval(2 * 60)))
        XCTAssertFalse(policy.shouldLock(on: .active, at: start.addingTimeInterval(3 * 60)))
        XCTAssertTrue(policy.shouldLock(on: .active, at: start.addingTimeInterval(60 * 60)))
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
