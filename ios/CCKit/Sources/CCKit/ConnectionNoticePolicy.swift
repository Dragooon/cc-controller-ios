import Foundation

/// Decides when a controller's transport failure is ready to be shown to the user.
public struct ConnectionNoticePolicy: Sendable {
    public enum Decision: Sendable, Equatable {
        case suppress(until: Date)
        case show
    }

    public static let launchGracePeriod: TimeInterval = 8
    public static let connectedFailureGracePeriod: TimeInterval = 3

    private let clock: any CCKitClock
    private var graceEndsAt: Date?
    private var failureSince: Date?
    private var hasConnected = false
    private var failureIsVisible = false

    public init(clock: any CCKitClock = SystemCCKitClock()) {
        self.clock = clock
    }

    /// Starts a fresh launch, foreground, or network-path grace period.
    public mutating func beginGracePeriod(at date: Date? = nil) {
        let date = date ?? clock.now
        graceEndsAt = date.addingTimeInterval(Self.launchGracePeriod)
        failureSince = nil
        failureIsVisible = false
    }

    public mutating func markSuccess(at date: Date? = nil) {
        _ = date ?? clock.now
        hasConnected = true
        graceEndsAt = nil
        failureSince = nil
        failureIsVisible = false
    }

    public mutating func failureDecision(at date: Date? = nil) -> Decision {
        let date = date ?? clock.now
        if failureIsVisible { return .show }

        if let graceEndsAt {
            guard date < graceEndsAt else {
                self.graceEndsAt = nil
                failureIsVisible = true
                return .show
            }
            return .suppress(until: graceEndsAt)
        }

        guard hasConnected else {
            failureIsVisible = true
            return .show
        }

        failureSince = failureSince ?? date
        let noticeAt = failureSince!.addingTimeInterval(Self.connectedFailureGracePeriod)
        guard date < noticeAt else {
            failureIsVisible = true
            return .show
        }
        return .suppress(until: noticeAt)
    }
}
