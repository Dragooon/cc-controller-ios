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
    case .network:
        return "Can't reach your Mac. Check that Termius is forwarding localhost:47832 and the Mac is awake."
    case .rateLimited:
        return "Too many unlock attempts. Wait a minute, then try again."
    case .server(let status, _):
        return "Your Mac could not sign this iPhone in (HTTP \(status)). Try again."
    case .decoding:
        return "Your Mac sent an unexpected reply. Try again."
    default:
        return "Unlock did not finish. Try again."
    }
}
