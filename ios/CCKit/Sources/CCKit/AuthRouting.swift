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

/// The sentence for a failed unlock or sign-in. `controllerName` names the controller that failed, such as
/// "Mac" or "Mustafar"; without it the sentence says "the controller".
public func faceIDFailureMessage(for error: AuthError, controllerName: String? = nil) -> String {
    let name = controllerName ?? "the controller"
    let subject = controllerName ?? "The controller"
    switch error {
    case .biometric(let message):
        return message
    case .network:
        return unreachableMessage(names: [name])
    case .rateLimited:
        return "Too many unlock attempts. Wait a minute, then try again."
    case .server(let status, _):
        return "\(subject) could not sign this iPhone in (HTTP \(status)). Try again."
    case .decoding:
        return "\(subject) sent an unexpected reply. Try again."
    default:
        return "Unlock did not finish. Try again."
    }
}
