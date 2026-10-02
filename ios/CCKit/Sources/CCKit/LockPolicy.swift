import Foundation

public enum LockInterval: Sendable, Equatable, CaseIterable {
    case immediately
    case fiveMinutes
    case oneHour
    case custom(TimeInterval)

    public static let `default` = LockInterval.fiveMinutes

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

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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
}

public struct LockPolicy: Sendable, Equatable {
    public var interval: LockInterval

    public init(interval: LockInterval = .default) {
        self.interval = interval
    }

    public func shouldLockOnColdLaunch() -> Bool { true }

    public func shouldLockOnForeground(after backgroundDate: Date?, now: Date) -> Bool {
        guard let backgroundDate else { return false }
        return now.timeIntervalSince(backgroundDate) >= interval.duration
    }

    public func shouldLock(lastActiveAt: Date?, now: Date) -> Bool {
        shouldLockOnForeground(after: lastActiveAt, now: now)
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

    public init(policy: LockPolicy = LockPolicy()) {
        self.policy = policy
    }

    public mutating func setInterval(_ interval: LockInterval) {
        policy.interval = interval
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
            return policy.shouldLockOnForeground(after: backgroundDate, now: date)
        }
    }
}
