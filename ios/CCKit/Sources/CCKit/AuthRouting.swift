import Foundation

public enum UnlockRoute: Sendable, Equatable {
    case locked(message: String)
    case rePair(message: String)
}

public func unlockRoute(for error: AuthError) -> UnlockRoute {
    switch error {
    case .unknownSecret:
        return .rePair(message: "This iPhone was removed on the Mac. Pair again to continue.")
    case .notEnrolled:
        return .rePair(message: "Face ID changed on this iPhone. Pair again to continue.")
    default:
        return .locked(message: faceIDFailureMessage(for: error))
    }
}

public func faceIDFailureMessage(for error: AuthError) -> String {
    switch error {
    case .biometric(let message):
        return message
    default:
        return "Face ID did not work. Try again."
    }
}
