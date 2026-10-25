import Foundation

public struct ControllerID: Codable, Hashable, Sendable, Equatable, Identifiable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw ControllerIDError.invalid(rawValue)
        }
        self.rawValue = rawValue
    }

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var id: String { rawValue }
    public var description: String { rawValue }

    public static let mac = try! ControllerID("mac")

    private static func isValid(_ value: String) -> Bool {
        guard (1...32).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122) ||
            (scalar.value >= 48 && scalar.value <= 57) ||
            scalar.value == 45
        }
    }
}

public enum ControllerIDError: Error, Sendable, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let value):
            return "Controller id must be 1–32 characters from [a-z0-9-], got \(value.debugDescription)."
        }
    }
}

public struct ControllerConfig: Codable, Sendable, Equatable, Identifiable {
    public let id: ControllerID
    public var displayName: String
    public var directBaseURL: URL?
    public var relayEndpoints: [URL]
    public var relayHostID: ControllerID?

    public init(
        id: ControllerID,
        displayName: String,
        directBaseURL: URL? = nil,
        relayEndpoints: [URL] = [],
        relayHostID: ControllerID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.directBaseURL = directBaseURL
        self.relayEndpoints = relayEndpoints
        self.relayHostID = relayHostID
    }

    public static func mac(
        directBaseURL: URL = URL(string: "http://127.0.0.1:47832")!,
        relayEndpoints: [URL] = [],
        relayHostID: ControllerID = .mac
    ) -> ControllerConfig {
        ControllerConfig(
            id: .mac,
            displayName: "Mac",
            directBaseURL: relayEndpoints.isEmpty ? directBaseURL : nil,
            relayEndpoints: relayEndpoints,
            relayHostID: relayHostID
        )
    }
}

public struct ControllerNamespace: Sendable, Equatable {
    public let id: ControllerID

    public init(_ id: ControllerID) {
        self.id = id
    }

    public func key(_ legacyKey: String) -> String {
        "CCController.\(id.rawValue).\(legacyKey)"
    }

    public var directoryName: String { id.rawValue }
}
