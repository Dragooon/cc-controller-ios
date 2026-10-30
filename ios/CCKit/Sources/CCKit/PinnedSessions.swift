import Foundation

/// The sessions pinned on this device, in the order they were pinned. Each key is
/// "controller/session", so a session keeps its pin while it sleeps and wakes. The stored form is
/// one key per line, which fits in `@AppStorage`.
public struct PinnedSessions: Equatable, Sendable {
    public private(set) var keys: [String]

    public init(keys: [String] = []) {
        var seen = Set<String>()
        self.keys = keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public init(stored: String) {
        self.init(keys: stored.split(separator: "\n").map(String.init))
    }

    public var stored: String { keys.joined(separator: "\n") }

    public func contains(_ key: String) -> Bool { keys.contains(key) }

    /// Where a pinned key sits, for keeping pinned rows in pin order; nil when it isn't pinned.
    public func position(of key: String) -> Int? { keys.firstIndex(of: key) }

    public mutating func setPinned(_ pinned: Bool, key: String) {
        guard !key.isEmpty else { return }
        keys.removeAll { $0 == key }
        if pinned { keys.append(key) }
    }
}
