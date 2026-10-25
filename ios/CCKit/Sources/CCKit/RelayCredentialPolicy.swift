import Foundation

public enum RelayCredentialAction: Sendable, Equatable {
    case allow
    case clearAndPairAgain
}

public func relayCredentialPolicy(hasPin: Bool, hasCredentials: Bool) -> RelayCredentialAction {
    hasCredentials && !hasPin ? .clearAndPairAgain : .allow
}
