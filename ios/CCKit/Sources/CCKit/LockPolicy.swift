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

    public func shouldShowPrivacyCover(isActive: Bool, isBackgrounded: Bool) -> Bool {
        !isActive || isBackgrounded
    }
}
