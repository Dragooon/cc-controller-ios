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
    public struct Resolution: Sendable, Equatable {
        public let config: ControllerConfig
        public let shouldPersist: Bool
        public let shouldRemoveLegacyRelayEndpoints: Bool

        public init(
            config: ControllerConfig,
            shouldPersist: Bool,
            shouldRemoveLegacyRelayEndpoints: Bool
        ) {
            self.config = config
            self.shouldPersist = shouldPersist
            self.shouldRemoveLegacyRelayEndpoints = shouldRemoveLegacyRelayEndpoints
        }
    }

    public let id: ControllerID
    public var displayName: String
    public var directBaseURL: URL?
    public var relayEndpoints: [URL]

    public init(
        id: ControllerID,
        displayName: String,
        directBaseURL: URL? = nil,
        relayEndpoints: [URL] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.directBaseURL = directBaseURL
        self.relayEndpoints = relayEndpoints
    }

    public static func mac(
        directBaseURL: URL = URL(string: "http://127.0.0.1:47832")!,
        relayEndpoints: [URL] = []
    ) -> ControllerConfig {
        ControllerConfig(
            id: .mac,
            displayName: "Mac",
            directBaseURL: relayEndpoints.isEmpty ? directBaseURL : nil,
            relayEndpoints: relayEndpoints
        )
    }

    public static func resolveMac(
        saved: ControllerConfig,
        legacyRelayEndpoints: String?,
        bundleDefaultEndpoints: [URL],
        hasLaunchOverride: Bool
    ) -> Resolution {
        guard !hasLaunchOverride else {
            return Resolution(
                config: saved,
                shouldPersist: false,
                shouldRemoveLegacyRelayEndpoints: false
            )
        }

        if let legacyRelayEndpoints {
            let endpoints = relayEndpoints(from: legacyRelayEndpoints)
            if !endpoints.isEmpty {
                var migrated = saved
                migrated.directBaseURL = nil
                migrated.relayEndpoints = endpoints
                return Resolution(
                    config: migrated,
                    shouldPersist: true,
                    shouldRemoveLegacyRelayEndpoints: true
                )
            }
        }

        let usesLoopback = saved.directBaseURL.map { url in
            switch url.host?.lowercased() {
            case "127.0.0.1", "localhost", "::1": true
            default: false
            }
        } ?? true
        guard saved.relayEndpoints.isEmpty, usesLoopback, !bundleDefaultEndpoints.isEmpty else {
            return Resolution(
                config: saved,
                shouldPersist: false,
                shouldRemoveLegacyRelayEndpoints: legacyRelayEndpoints != nil
            )
        }

        var fallback = saved
        fallback.directBaseURL = nil
        fallback.relayEndpoints = bundleDefaultEndpoints
        return Resolution(
            config: fallback,
            shouldPersist: false,
            shouldRemoveLegacyRelayEndpoints: legacyRelayEndpoints != nil
        )
    }

    public static func relayEndpoints(from value: String) -> [URL] {
        value
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .compactMap { URL(string: String($0)) }
            .filter(isValidRelayAddress)
    }

    public static func isValidRelayAddress(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              url.user == nil,
              url.password == nil,
              url.port != nil,
              url.path.isEmpty || url.path == "/",
              url.query == nil,
              url.fragment == nil else { return false }
        let octets = host.split(separator: ".")
        guard octets.count == 4,
              octets.allSatisfy({ part in part.allSatisfy(\.isNumber) && (0...255).contains(Int(part) ?? -1) }) else { return false }
        return true
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
