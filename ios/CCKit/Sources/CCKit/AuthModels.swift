import Foundation

public struct Device: Codable, Sendable, Equatable {
    public var name: String?
    public var pairedAt: Date?
    public var createdAt: Date?
    public var lastSeenAt: Date?
    public var expiresAt: Date?
    public var hasPasskey: Bool?
    public var hasNativeSecret: Bool?
    public var thisDevice: Bool?
    public init(name: String? = nil, pairedAt: Date? = nil, createdAt: Date? = nil, lastSeenAt: Date? = nil, expiresAt: Date? = nil, hasPasskey: Bool? = nil, hasNativeSecret: Bool? = nil, thisDevice: Bool? = nil) { self.name = name; self.pairedAt = pairedAt; self.createdAt = createdAt; self.lastSeenAt = lastSeenAt; self.expiresAt = expiresAt; self.hasPasskey = hasPasskey; self.hasNativeSecret = hasNativeSecret; self.thisDevice = thisDevice }
}

public struct DeviceList: Codable, Sendable, Equatable { public var devices: [Device]?; public init(devices: [Device]? = nil) { self.devices = devices } }

public struct WhoAmI: Codable, Sendable, Equatable {
    public var device: Device?
    public var hasPasskey: Bool?
    public var passkeys: Bool?
    public var authenticated: Bool?
    public var sessionExpiresAt: Date?
    public var error: String?
    public init(device: Device? = nil, hasPasskey: Bool? = nil, passkeys: Bool? = nil, authenticated: Bool? = nil, sessionExpiresAt: Date? = nil, error: String? = nil) { self.device = device; self.hasPasskey = hasPasskey; self.passkeys = passkeys; self.authenticated = authenticated; self.sessionExpiresAt = sessionExpiresAt; self.error = error }
}

public struct PairStartResponse: Codable, Sendable, Equatable {
    public var code: String?
    public var expiresAt: Date?
    public init(code: String? = nil, expiresAt: Date? = nil) { self.code = code; self.expiresAt = expiresAt }
}
public enum PairPollState: Codable, Sendable, Equatable { case pending, expired, confirmed, unknown(String); public init(from d: Decoder) throws { let s = try d.singleValueContainer().decode(String.self); switch s { case "pending":self = .pending; case "expired":self = .expired; case "confirmed":self = .confirmed; default:self = .unknown(s) } }; public func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(rawValue) }; public var rawValue:String { switch self { case .pending:"pending"; case .expired:"expired"; case .confirmed:"confirmed"; case .unknown(let s):s } } }
public struct PairPollResponse: Codable, Sendable, Equatable { public var state: PairPollState?; public var deviceToken: String?; public init(state: PairPollState? = nil, deviceToken: String? = nil) { self.state = state; self.deviceToken = deviceToken } }
public struct NativeEnrollResponse: Codable, Sendable, Equatable { public var secret: String?; public init(secret: String? = nil) { self.secret = secret } }
public struct NativeLoginResponse: Codable, Sendable, Equatable { public var authenticated: Bool?; public var token: String?; public var expiresAt: Date?; public init(authenticated: Bool? = nil, token: String? = nil, expiresAt: Date? = nil) { self.authenticated = authenticated; self.token = token; self.expiresAt = expiresAt } }
public struct MessageResult: Codable, Sendable, Equatable { public var delivered: Bool?; public var queued: Bool?; public var route: String?; public var output: String?; public init(delivered: Bool? = nil, queued: Bool? = nil, route: String? = nil, output: String? = nil) { self.delivered = delivered; self.queued = queued; self.route = route; self.output = output } }
public struct UploadedFile: Codable, Sendable, Equatable { public var name: String?; public var path: String?; public var size: Int?; public var mime: String?; public var url: String?; public init(name: String? = nil, path: String? = nil, size: Int? = nil, mime: String? = nil, url: String? = nil) { self.name = name; self.path = path; self.size = size; self.mime = mime; self.url = url } }
public struct UploadResponse: Codable, Sendable, Equatable { public var files: [UploadedFile]?; public init(files: [UploadedFile]? = nil) { self.files = files } }
public struct LogoutResponse: Codable, Sendable, Equatable { public var loggedOut: Bool?; public init(loggedOut: Bool? = nil) { self.loggedOut = loggedOut } }
public struct ErrorResponse: Codable, Sendable, Equatable { public var error: String?; public var code: String?; public var limitBytes: Int?; public init(error: String? = nil, code: String? = nil, limitBytes: Int? = nil) { self.error = error; self.code = code; self.limitBytes = limitBytes } }
