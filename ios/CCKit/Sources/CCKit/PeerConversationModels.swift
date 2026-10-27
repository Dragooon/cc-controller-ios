import Foundation

public enum PeerConversationState: Codable, Sendable, Equatable {
    case allowed
    case denied
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "allowed": self = .allowed
        case "denied": self = .denied
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .allowed: "allowed"
        case .denied: "denied"
        case .unknown(let value): value
        }
    }
}

public struct PeerConversationPeer: Codable, Sendable, Equatable {
    public let host: String
    public let hostLabel: String
    public let ref: String
    public let label: String

    public init(host: String, hostLabel: String, ref: String, label: String) {
        self.host = host
        self.hostLabel = hostLabel
        self.ref = ref
        self.label = label
    }
}

public struct PeerConversationLocal: Codable, Sendable, Equatable {
    public let ref: String
    public let label: String

    public init(ref: String, label: String) {
        self.ref = ref
        self.label = label
    }
}

public struct PeerConversation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let peer: PeerConversationPeer
    public let local: PeerConversationLocal
    public let state: PeerConversationState
    public let since: Date?
    public let until: Date?
    /// D4 F2 returns the expiry of an allowed pair rather than a separate last-active field.
    /// A daemon that supplies `lastActive` wins; otherwise the one-hour idle window gives the
    /// equivalent timestamp for the Settings row.
    public let lastActive: Date?

    private enum CodingKeys: String, CodingKey { case id, peer, local, state, since, until, lastActive }

    public init(
        id: String,
        peer: PeerConversationPeer,
        local: PeerConversationLocal,
        state: PeerConversationState,
        since: Date? = nil,
        until: Date? = nil,
        lastActive: Date? = nil
    ) {
        self.id = id
        self.peer = peer
        self.local = local
        self.state = state
        self.since = since
        self.until = until
        self.lastActive = lastActive ?? (state == .allowed ? until?.addingTimeInterval(-60 * 60) : since)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decodeIfPresent(PeerConversationState.self, forKey: .state) ?? .unknown("unknown")
        let since = try container.decodeIfPresent(Date.self, forKey: .since)
        let until = try container.decodeIfPresent(Date.self, forKey: .until)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            peer: try container.decode(PeerConversationPeer.self, forKey: .peer),
            local: try container.decode(PeerConversationLocal.self, forKey: .local),
            state: state,
            since: since,
            until: until,
            lastActive: try container.decodeIfPresent(Date.self, forKey: .lastActive)
        )
    }
}

public struct PeerConversationApproval: Sendable, Equatable {
    public let senderHost: String
    public let senderLabel: String
    public let targetLabel: String
    public let messagePreview: String?

    public init(senderHost: String, senderLabel: String, targetLabel: String, messagePreview: String? = nil) {
        self.senderHost = senderHost
        self.senderLabel = senderLabel
        self.targetLabel = targetLabel
        self.messagePreview = messagePreview
    }

    public var sentence: String {
        "\(senderHost) session ‘\(senderLabel)’ wants to message ‘\(targetLabel)’. Allow?"
    }
}
