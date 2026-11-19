import Foundation

/// Why a paired controller is signed out while the app is unlocked.
public enum ControllerSignOutReason: Sendable, Equatable {
    /// Its sign-in couldn't reach it: offline, behind a relay without a host, or a gateway error.
    case unreachable
    /// It needs Face ID or pairing again before it can sign in.
    case signInNeeded
}

/// Sorts a failed sign-in into "couldn't reach it" and "needs you".
public func signOutReason(for error: AuthError) -> ControllerSignOutReason {
    switch error {
    case .network:
        return .unreachable
    case .server(let status, _) where status >= 500:
        return .unreachable
    default:
        return .signInNeeded
    }
}

/// One controller's result from the app unlock, which signs in to every paired controller at once.
public struct ControllerUnlockResult: Sendable, Equatable {
    public let controllerID: ControllerID
    public let name: String
    public let isPrimary: Bool
    /// Nil when the controller signed in.
    public let error: AuthError?

    public init(controllerID: ControllerID, name: String, isPrimary: Bool, error: AuthError?) {
        self.controllerID = controllerID
        self.name = name
        self.isPrimary = isPrimary
        self.error = error
    }
}

/// What the app does after Face ID and the sign-ins finish.
public enum AppUnlockOutcome: Sendable, Equatable {
    /// At least one controller signed in. Each one that didn't shows its own state in the list.
    case unlocked(signedOut: [ControllerID: ControllerSignOutReason])
    /// Nothing signed in. The lock screen stays, with this message.
    case locked(message: String)
    /// The primary no longer knows this iPhone, or Face ID changed: pair again.
    case rePair(message: String)
}

/// Decides the unlock from every controller's sign-in. One controller that can't be reached no longer holds
/// the others back; only the primary's re-pair answer, which is a deliberate reply rather than reachability,
/// still sends the app back to pairing.
public func appUnlockOutcome(_ results: [ControllerUnlockResult]) -> AppUnlockOutcome {
    if let primaryError = results.first(where: \.isPrimary)?.error,
       case .rePair(let message) = unlockRoute(for: primaryError) {
        return .rePair(message: message)
    }
    let failures = results.filter { $0.error != nil }
    if failures.count < results.count {
        var signedOut: [ControllerID: ControllerSignOutReason] = [:]
        for failure in failures {
            if let error = failure.error {
                signedOut[failure.controllerID] = signOutReason(for: error)
            }
        }
        return .unlocked(signedOut: signedOut)
    }
    return .locked(message: lockedUnlockMessage(failures))
}

/// The lock-screen sentence when no controller signed in. A Face ID problem comes first, because every
/// controller fails the same way then; otherwise it names the controllers that couldn't be reached.
public func lockedUnlockMessage(_ failures: [ControllerUnlockResult]) -> String {
    let errors = failures.compactMap(\.error)
    if let biometric = errors.first(where: { if case .biometric = $0 { return true } else { return false } }) {
        return faceIDFailureMessage(for: biometric)
    }
    if !failures.isEmpty, errors.allSatisfy({ signOutReason(for: $0) == .unreachable }) {
        return unreachableMessage(names: failures.map(\.name))
    }
    let shown = failures.first(where: \.isPrimary) ?? failures.first
    guard let shown, let error = shown.error else { return "Unlock did not finish. Try again." }
    return faceIDFailureMessage(for: error, controllerName: shown.name)
}

/// "Can't reach Mac." / "Can't reach Mac or Mustafar." / "Can't reach Mac, Mustafar or Kepler.", then what to check.
public func unreachableMessage(names: [String]) -> String {
    let list: String
    switch names.count {
    case 0: list = "your controller"
    case 1: list = names[0]
    default: list = names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
    }
    let pronoun = names.count > 1 ? "they're" : "it's"
    return "Can't reach \(list). Check your connection and that \(pronoun) online, then try again."
}

/// Whether a controller whose sign-in failed takes the whole app back to the lock screen. Only when nothing
/// else is still signed in; otherwise that controller signs out on its own.
public func signOutLocksApp(stillSignedIn: Int) -> Bool {
    stillSignedIn == 0
}
