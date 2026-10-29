import Foundation

public enum ResumeNewChatPolicy {
    public static let defaultThreshold: TimeInterval = 10 * 60

    public static func shouldResume(
        backgroundAt: Date?,
        now: Date,
        threshold: TimeInterval = defaultThreshold,
        hasPendingApprovals: Bool,
        isOnNewChat: Bool,
        isPaired: Bool
    ) -> Bool {
        guard isPaired,
              !hasPendingApprovals,
              !isOnNewChat,
              let backgroundAt,
              now.timeIntervalSince(backgroundAt) >= threshold else {
            return false
        }
        return true
    }
}
