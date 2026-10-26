import Foundation

/// The sender of a peer prompt, split from the daemon's `from` string, which looks like
/// `Stockade · thread "X" [mustafar:3fa9c1]`.
public struct PeerSender: Equatable, Sendable {
    public let label: String
    public let host: String?

    public init(label: String, host: String?) {
        self.label = label
        self.host = host
    }

    /// "From <label> · <host>", or "From <label>" when the host is unknown.
    public var headerText: String {
        guard let host else { return "From \(label)" }
        return "From \(label) · \(host)"
    }
}

/// Returns the sender of a peer prompt, or nil when the prompt is not from a peer.
public func peerSender(origin: String?, from: String?) -> PeerSender? {
    guard origin == "peer" else { return nil }
    let trimmed = (from ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return PeerSender(label: "another session", host: nil) }
    return peerSender(from: trimmed)
}

/// Splits `<label> [<host>:<ref>]` into its label and host. A string without the bracketed suffix is all label.
public func peerSender(from text: String) -> PeerSender {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let match = trimmed.firstMatch(of: #/^(.*\S)\s*\[([^:\]]+):[^\]]+\]$/#) else {
        return PeerSender(label: trimmed, host: nil)
    }
    let label = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
    let host = String(match.2).trimmingCharacters(in: .whitespacesAndNewlines)
    return PeerSender(label: label, host: host.isEmpty ? nil : host)
}

public extension PromptEntry {
    var peerSender: PeerSender? { CCKit.peerSender(origin: origin, from: from) }
}
