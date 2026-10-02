import Foundation

public enum OnboardingStep: String, Sendable, Equatable, Codable {
    case welcome
    case connect
    case pair
    case faceID
    case sessions
}

public enum OnboardingConnection: Sendable, Equatable {
    case checking
    case connected(version: String?)
    case unreachable(since: Date)
}

public struct OnboardingFlowState: Sendable, Equatable {
    public private(set) var step: OnboardingStep = .welcome
    public private(set) var connection: OnboardingConnection = .checking
    public private(set) var pairingCode: String?
    public private(set) var pairingExpiresAt: Date?
    public private(set) var pairingConfirmedAt: Date?
    public private(set) var pairingExpired = false

    public init() {}

    public mutating func continueFromWelcome() {
        guard step == .welcome else { return }
        step = .connect
    }

    public mutating func markConnectionChecking() {
        guard step == .connect else { return }
        connection = .checking
    }

    public mutating func markConnectionConnected(version: String?) {
        guard step == .connect else { return }
        connection = .connected(version: version)
    }

    public mutating func markConnectionUnreachable(since: Date) {
        guard step == .connect else { return }
        connection = .unreachable(since: since)
    }

    public mutating func beginPairing(code: String, expiresAt: Date) {
        pairingCode = code
        pairingExpiresAt = expiresAt
        pairingConfirmedAt = nil
        pairingExpired = false
        step = .pair
    }

    public mutating func markPairingConfirmed(at date: Date) {
        guard step == .pair else { return }
        pairingConfirmedAt = date
        step = .faceID
    }

    public mutating func markPairingExpired() {
        guard step == .pair else { return }
        pairingExpired = true
    }

    public mutating func restartPairing() {
        pairingCode = nil
        pairingExpiresAt = nil
        pairingConfirmedAt = nil
        pairingExpired = false
        step = .connect
    }

    public mutating func finish() {
        step = .sessions
    }

    public func isPairingExpired(at date: Date) -> Bool {
        if pairingExpired { return true }
        guard let pairingExpiresAt else { return false }
        return date >= pairingExpiresAt
    }

    public func enrollmentWindowOpen(at date: Date, duration: TimeInterval = 10 * 60) -> Bool {
        guard let pairingConfirmedAt else { return false }
        return date >= pairingConfirmedAt && date.timeIntervalSince(pairingConfirmedAt) < duration
    }

    public mutating func resumeAfterBackground() {
        // The flow state is deliberately unchanged. Its dates are evaluated on the next render.
    }
}
