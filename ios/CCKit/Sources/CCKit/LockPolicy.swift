import Foundation

public enum LockInterval: Sendable, Equatable, CaseIterable {
    case immediately
    case fiveMinutes
    case oneHour
    case custom(TimeInterval)

    public static let `default` = LockInterval.oneHour

    public static var allCases: [LockInterval] {
        [.immediately, .fiveMinutes, .oneHour]
    }

    public var duration: TimeInterval {
        switch self {
        case .immediately: 0
        case .fiveMinutes: 5 * 60
        case .oneHour: 60 * 60
        case .custom(let seconds): seconds
        }
    }
}

public struct LockIntervalStore {
    static let storageKey = "cc-controller.lockInterval"
    static let migrationKey = "cc-controller.lockInterval.defaultMigration.v1"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        migrateLegacyDefaultIfNeeded()
    }

    public var interval: LockInterval {
        switch userDefaults.string(forKey: Self.storageKey) {
        case "immediately": .immediately
        case "fiveMinutes": .fiveMinutes
        case "oneHour": .oneHour
        default: .default
        }
    }

    public func set(_ interval: LockInterval) {
        switch interval {
        case .immediately:
            userDefaults.set("immediately", forKey: Self.storageKey)
        case .fiveMinutes:
            userDefaults.set("fiveMinutes", forKey: Self.storageKey)
        case .oneHour:
            userDefaults.set("oneHour", forKey: Self.storageKey)
        case .custom:
            userDefaults.removeObject(forKey: Self.storageKey)
        }
    }

    private func migrateLegacyDefaultIfNeeded() {
        guard !userDefaults.bool(forKey: Self.migrationKey) else { return }
        if userDefaults.string(forKey: Self.storageKey) == "fiveMinutes" {
            userDefaults.set("oneHour", forKey: Self.storageKey)
        }
        userDefaults.set(true, forKey: Self.migrationKey)
    }
}

public struct LockPolicy: Sendable, Equatable {
    public var interval: LockInterval
    public var maxUnlockAge: TimeInterval

    public init(interval: LockInterval = .default, maxUnlockAge: TimeInterval = 60 * 60) {
        self.interval = interval
        self.maxUnlockAge = maxUnlockAge
    }

    public func shouldLockOnColdLaunch(
        lastUnlockAt: Date?,
        lastBackgroundAt: Date?,
        now: Date
    ) -> Bool {
        guard let lastUnlockAt else { return true }
        return shouldLockOnForeground(lastUnlockAt: lastUnlockAt, after: lastBackgroundAt, now: now)
    }

    public func shouldLockOnForeground(
        lastUnlockAt: Date?,
        after backgroundDate: Date?,
        now: Date
    ) -> Bool {
        guard let lastUnlockAt else { return true }
        if now.timeIntervalSince(lastUnlockAt) >= maxUnlockAge { return true }
        guard let backgroundDate else { return false }
        return now.timeIntervalSince(backgroundDate) >= interval.duration
    }

    public func unlockExpiryDate(lastUnlockAt: Date?) -> Date? {
        lastUnlockAt?.addingTimeInterval(maxUnlockAge)
    }

    public func shouldLock(lastActiveAt: Date?, now: Date) -> Bool {
        shouldLockOnForeground(lastUnlockAt: lastActiveAt, after: nil, now: now)
    }

    public func shouldShowPrivacyCover(isActive: Bool, isBackgrounded: Bool, isLocked: Bool) -> Bool {
        guard !isLocked else { return false }
        return !isActive || isBackgrounded
    }
}

public enum LockScenePhase: Sendable, Equatable {
    case active
    case inactive
    case background
}

public struct LockTransitionPolicy: Sendable, Equatable {
    private var policy: LockPolicy
    private var backgroundDate: Date?
    private var lastUnlockAt: Date?

    public init(policy: LockPolicy = LockPolicy(), lastUnlockAt: Date? = nil) {
        self.policy = policy
        self.lastUnlockAt = lastUnlockAt
    }

    public mutating func setInterval(_ interval: LockInterval) {
        policy.interval = interval
    }

    public mutating func setLastUnlock(at date: Date?) {
        lastUnlockAt = date
    }

    public mutating func shouldLock(on phase: LockScenePhase, at date: Date) -> Bool {
        switch phase {
        case .background:
            backgroundDate = date
            return false
        case .inactive:
            return false
        case .active:
            defer { backgroundDate = nil }
            return policy.shouldLockOnForeground(lastUnlockAt: lastUnlockAt, after: backgroundDate, now: date)
        }
    }
}
