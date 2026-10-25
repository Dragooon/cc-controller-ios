import Foundation

public enum AuthError: Error, Sendable, Equatable, LocalizedError {
    case invalidDeviceName
    case invalidPairingCode
    case pairingExpired
    case loginRequired
    case enrollmentWindowClosed
    case alreadyEnrolled(deviceName: String?)
    case unknownSecret
    case rateLimited
    case network(String)
    case server(status: Int, message: String)
    case decoding(String)
    case locked
    case notEnrolled
    case biometric(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceName: return "Enter a name for this device."
        case .invalidPairingCode: return "Enter the pairing code shown by cc-gateway on the Mac."
        case .pairingExpired: return "The pairing code expired. Start pairing again on the Mac."
        case .loginRequired: return "The device is paired but not logged in. Unlock it to continue."
        case .enrollmentWindowClosed: return "The pairing window expired. Start pairing again on the Mac."
        case .alreadyEnrolled(let deviceName):
            let name = deviceName.map { "\($0)" } ?? "this device"
            return "\(name) is already enrolled. Run cc-gateway revoke \(name) on the Mac and pair again."
        case .unknownSecret: return "This device secret was revoked. Pair this device again on the Mac."
        case .rateLimited: return "Too many unlock attempts. Wait a minute and try again."
        case .network(let message): return "Could not reach the Mac: \(message)"
        case .server(_, let message): return message
        case .decoding(let message): return "The Mac returned an invalid response: \(message)"
        case .locked: return "Unlock this device to continue."
        case .notEnrolled: return "This device is not enrolled. Pair it with the Mac first."
        case .biometric(let message): return message
        }
    }
}

public struct DaemonProbe: Sendable, Equatable {
    public let isReachable: Bool
    public let latency: Duration

    public init(isReachable: Bool, latency: Duration) {
        self.isReachable = isReachable
        self.latency = latency
    }
}

public final class AuthClient: Sendable {
    public var baseURL: URL { connection.configuredBaseURL }
    public let connection: ConnectionRouter

    public init(baseURL: URL, session: URLSession = .shared) {
        connection = ConnectionRouter(baseURL: baseURL, session: session)
    }

    public init(connection: ConnectionRouter) {
        self.connection = connection
    }

    /// Probes whoami because it is the daemon's unauthenticated status route.
    /// HTTP 401 with a JSON whoami response still proves that the daemon is reachable.
    public func probeDaemon(timeout: TimeInterval? = nil) async throws -> DaemonProbe {
        let target = try await connection.target()
        var components = URLComponents(url: target.baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "api/auth/whoami"].filter { !$0.isEmpty }.joined(separator: "/")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let timeout { request.timeoutInterval = timeout }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await target.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AuthError.decoding("Response was not HTTP") }
            guard http.statusCode == 401 || (200..<300).contains(http.statusCode) else {
                throw mapError(status: http.statusCode, data: data)
            }
            return DaemonProbe(isReachable: true, latency: start.duration(to: clock.now))
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
    }

    public func startPairing(deviceName: String) async throws -> PairStartResponse {
        guard !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AuthError.invalidDeviceName }
        return try await post("/api/pair/start", body: PairingStartBody(deviceName: deviceName))
    }

    public func pollPairing(code: String) async throws -> PairPollResponse {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AuthError.invalidPairingCode }
        return try await get("/api/pair/poll", query: [URLQueryItem(name: "code", value: code)])
    }

    public func enroll(deviceToken: String, deviceName: String) async throws -> NativeEnrollResponse {
        guard !deviceToken.isEmpty else { throw AuthError.invalidPairingCode }
        guard !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AuthError.invalidDeviceName }
        return try await post("/api/auth/native/enroll", body: NativeEnrollBody(deviceToken: deviceToken, deviceName: deviceName))
    }

    public func login(secret: String) async throws -> NativeLoginResponse {
        guard !secret.isEmpty else { throw AuthError.unknownSecret }
        return try await post("/api/auth/native/login", body: NativeLoginBody(secret: secret))
    }

    public func logout(bearer: String? = nil) async throws {
        _ = try await request("/api/auth/logout", method: "POST", body: Data("{}".utf8), bearer: bearer, timeoutInterval: 5) as EmptyAuthResponse
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        try await request(path, method: "GET", query: query)
    }

    private func post<T: Encodable, U: Decodable>(_ path: String, body: T) async throws -> U {
        let data: Data
        do { data = try JSONEncoder.ccKit().encode(body) }
        catch { throw AuthError.decoding(error.localizedDescription) }
        return try await request(path, method: "POST", body: data, contentType: "application/json")
    }

    private func request<T: Decodable>(_ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil, contentType: String? = nil, bearer: String? = nil, timeoutInterval: TimeInterval? = nil) async throws -> T {
        let target = try await connection.target()
        var components = URLComponents(url: target.baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        do {
            let (data, response) = try await target.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AuthError.decoding("Response was not HTTP") }
            guard (200..<300).contains(http.statusCode) else { throw mapError(status: http.statusCode, data: data) }
            do { return try JSONDecoder.ccKit().decode(T.self, from: data) }
            catch { throw AuthError.decoding(error.localizedDescription) }
        } catch let error as AuthError { throw error }
        catch let error as URLError {
            if isNetworkRelayError(error) { connection.invalidate() }
            throw AuthError.network(error.localizedDescription)
        }
        catch { throw AuthError.network(error.localizedDescription) }
    }

    private func mapError(status: Int, data: Data) -> AuthError {
        let response = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        let message = response?.error ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch response?.code {
        case "pairing_expired": return .pairingExpired
        case "enrol_window_closed": return .enrollmentWindowClosed
        case "already_enrolled": return .alreadyEnrolled(deviceName: nil)
        case "rate_limited": return .rateLimited
        case "unauthorized":
            return status == 401 && message.localizedCaseInsensitiveContains("unknown device secret") ? .unknownSecret : .loginRequired
        case "invalid": return .server(status: status, message: message)
        default: break
        }
        switch (status, message) {
        case (400, let text) where text.localizedCaseInsensitiveContains("pairing code"): return .invalidPairingCode
        case (404, _): return .pairingExpired
        case (401, let text) where text.localizedCaseInsensitiveContains("unknown device secret"): return .unknownSecret
        case (401, let text) where text.localizedCaseInsensitiveContains("login required"): return .loginRequired
        case (401, _): return .unknownSecret
        case (409, let text) where text.localizedCaseInsensitiveContains("already enrolled"): return .alreadyEnrolled(deviceName: nil)
        case (429, _): return .rateLimited
        default: return .server(status: status, message: message)
        }
    }
}

private struct PairingStartBody: Encodable { let deviceName: String }
private struct NativeEnrollBody: Encodable { let deviceToken: String; let deviceName: String }
private struct NativeLoginBody: Encodable { let secret: String }
private struct EmptyAuthResponse: Decodable {}
