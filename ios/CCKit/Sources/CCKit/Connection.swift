import Foundation

public protocol CCKitClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemCCKitClock: CCKitClock, Sendable {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public enum ConnectionState: Sendable, Equatable {
    case connecting
    case live
    case reconnecting(attempt: Int, since: Date)
    case offline(lastUpdated: Date?, error: String?)
}
