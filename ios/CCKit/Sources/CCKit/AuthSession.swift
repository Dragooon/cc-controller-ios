import Foundation
import Observation
import OSLog

private let authSessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "cc-controller",
    category: "auth"
)

public enum AuthState: Sendable, Equatable {
    case unpaired
    case pairing(code: String, expiresAt: Date)
    case waitingForConfirmation
    case enrolling
    case locked
    case unlocking
    case unlocked(bearerExpiresAt: Date)
    case failed(AuthError)
}

@MainActor @Observable
public final class AuthSession {
    public private(set) var state: AuthState = .locked

    @ObservationIgnored private let client: AuthClient
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let clock: any CCKitClock
    @ObservationIgnored private let cache: DiskCache?
    @ObservationIgnored private let connection: ConnectionRouter
    @ObservationIgnored private var bearerToken: String?
    @ObservationIgnored private var pairingCode: String?
    @ObservationIgnored private var pairedDeviceToken: String?
    @ObservationIgnored private var deviceName: String?

    public private(set) var lastUnlockBiometricErrorCode: Int?
    public private(set) var lastUnlockFailureCode: String?

    public init(
        client: AuthClient,
        credentials: any CredentialStore,
        clock: any CCKitClock = SystemCCKitClock(),
        cacheDirectory: URL? = nil
    ) {
        self.client = client
        self.credentials = credentials
        self.connection = client.connection
        self.clock = clock
        self.cache = cacheDirectory.map { DiskCache(directory: $0, clock: clock) }
    }

    public convenience init(
        serverURL: URL,
        credentials: any CredentialStore,
        session: URLSession = .shared,
        clock: any CCKitClock = SystemCCKitClock(),
        cacheDirectory: URL? = nil
    ) {
        self.init(client: AuthClient(baseURL: serverURL, session: session), credentials: credentials, clock: clock, cacheDirectory: cacheDirectory)
    }

    public convenience init(
        connection: ConnectionRouter,
        credentials: any CredentialStore,
        clock: any CCKitClock = SystemCCKitClock(),
        cacheDirectory: URL? = nil
    ) {
        self.init(client: AuthClient(connection: connection), credentials: credentials, clock: clock, cacheDirectory: cacheDirectory)
    }

    public var bearerProvider: @Sendable () async throws -> String {
        { [weak self] in
            guard let self else { throw AuthError.locked }
            return try await self.bearer()
        }
    }

    public var pairingDetails: (code: String, expiresAt: Date)? {
        guard case .pairing(let code, let expiresAt) = state else { return nil }
        return (code, expiresAt)
    }

    public func probeDaemon(timeout: TimeInterval? = nil) async throws -> DaemonProbe {
        try await client.probeDaemon(timeout: timeout)
    }

    public func bearer() async throws -> String {
        guard let bearerToken, case .unlocked = state else { throw AuthError.locked }
        return bearerToken
    }

    @discardableResult
    public func restore(token: String, expiresAt: Date) -> Bool {
        guard !token.isEmpty, expiresAt > clock.now else { return false }
        bearerToken = token
        state = .unlocked(bearerExpiresAt: expiresAt)
        return true
    }

    public func lock() {
        bearerToken = nil
        state = .locked
        Task { [credentials] in
            try? await credentials.deleteSessionBearer()
        }
    }

    public func startPairing(deviceName: String) async -> Result<Void, AuthError> {
        do {
            let response = try await client.startPairing(deviceName: deviceName)
            guard let code = response.code, !code.isEmpty else { throw AuthError.decoding("Pairing response did not contain a code.") }
            let expiresAt = response.expiresAt ?? clock.now.addingTimeInterval(5 * 60)
            self.deviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            pairingCode = code
            state = .pairing(code: code, expiresAt: expiresAt)
            return .success(())
        } catch {
            return fail(asAuthError(error))
        }
    }

    public func pollPairing() async -> Result<Void, AuthError> {
        guard let code = pairingCode else { return fail(.invalidPairingCode) }
        do {
            let response = try await client.pollPairing(code: code)
            switch response.state {
            case .pending:
                state = .waitingForConfirmation
                return .success(())
            case .confirmed:
                guard let token = response.deviceToken, !token.isEmpty else { throw AuthError.decoding("Pairing response did not contain a device token.") }
                pairedDeviceToken = token
                try await credentials.setDeviceToken(token)
                if connection.mode == .relay, let observed = connection.observedPin {
                    try await credentials.setRelayPin(observed)
                    try await connection.reconfigure(pin: RelayPin(observed))
                }
                state = .enrolling
                return .success(())
            case .expired, .none:
                return fail(.pairingExpired)
            case .unknown:
                return fail(.pairingExpired)
            }
        } catch {
            return fail(asAuthError(error))
        }
    }

    public func enroll() async -> Result<Void, AuthError> {
        let token: String
        do {
            if let pairedDeviceToken { token = pairedDeviceToken }
            else if let stored = try await credentials.getDeviceToken() { token = stored }
            else { return fail(.invalidPairingCode) }
            guard let deviceName, !deviceName.isEmpty else { return fail(.invalidDeviceName) }
            state = .enrolling
            let response = try await client.enroll(deviceToken: token, deviceName: deviceName)
            guard let secret = response.secret, !secret.isEmpty else { throw AuthError.decoding("Enrollment response did not contain a secret.") }
            try await credentials.setNativeSecret(secret)
            state = .locked
            return .success(())
        } catch {
            return fail(asAuthError(error))
        }
    }

    public func pollPairing(code: String) async -> Result<Void, AuthError> {
        pairingCode = code
        return await pollPairing()
    }

    public func enroll(deviceName: String) async -> Result<Void, AuthError> {
        self.deviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return await enroll()
    }

    public func enroll(deviceToken: String, deviceName: String) async -> Result<Void, AuthError> {
        pairedDeviceToken = deviceToken
        self.deviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await credentials.setDeviceToken(deviceToken) }
        catch { return fail(asAuthError(error)) }
        return await enroll()
    }

    public func unlock(session: BiometricUnlockSession? = nil) async -> Result<Void, AuthError> {
        state = .unlocking
        lastUnlockBiometricErrorCode = nil
        lastUnlockFailureCode = nil
        do {
            guard let secret = try await credentials.getNativeSecret(session: session) else { return fail(.notEnrolled) }
            let response = try await client.login(secret: secret)
            guard response.authenticated != false, let token = response.token, !token.isEmpty else { throw AuthError.unknownSecret }
            let expiresAt = response.expiresAt ?? clock.now.addingTimeInterval(12 * 60 * 60)
            do {
                try await credentials.setSessionBearer(SessionBearer(token: token, expiresAt: expiresAt))
            } catch {
                authSessionLogger.error("Could not persist session bearer: \(error.localizedDescription, privacy: .public)")
            }
            TranscriptLifecycleLog.shared.record(name: "native-login")
            bearerToken = token
            state = .unlocked(bearerExpiresAt: expiresAt)
            return .success(())
        } catch {
            let mapped = asAuthError(error)
            if mapped == .unknownSecret {
                await clearCredentials()
                state = .unpaired
            } else {
                state = .failed(mapped)
            }
            return .failure(mapped)
        }
    }

    public func handleUnauthorized(session: BiometricUnlockSession? = nil) async -> Result<Void, AuthError> {
        bearerToken = nil
        state = .locked
        try? await credentials.deleteSessionBearer()
        return await unlock(session: session)
    }

    public func logout() async -> Result<Void, AuthError> {
        guard let bearerToken else {
            try? await credentials.deleteSessionBearer()
            state = .locked
            return .success(())
        }
        do {
            try await client.logout(bearer: bearerToken)
            self.bearerToken = nil
            state = .locked
            try? await credentials.deleteSessionBearer()
            return .success(())
        } catch {
            self.bearerToken = nil
            state = .locked
            try? await credentials.deleteSessionBearer()
            return .failure(asAuthError(error))
        }
    }

    public func unpair() async -> Result<Void, AuthError> {
        let logoutResult = await logout()
        await clearCredentials()
        pairingCode = nil
        pairedDeviceToken = nil
        deviceName = nil
        state = .unpaired
        if case .failure(let error) = logoutResult, !isAlreadyLoggedOut(error) { return .failure(error) }
        return .success(())
    }

    private func clearCredentials() async {
        try? await credentials.deleteDeviceToken()
        try? await credentials.deleteNativeSecret()
        try? await credentials.deleteRelayPin()
        try? await credentials.deleteLastUnlockAt()
        try? await credentials.deleteLastBackgroundAt()
        try? await credentials.deleteSessionBearer()
        try? await cache?.clear()
        bearerToken = nil
    }

    private func fail(_ error: AuthError) -> Result<Void, AuthError> {
        state = .failed(error)
        return .failure(error)
    }

    private func asAuthError(_ error: Error) -> AuthError {
        if let error = error as? AuthError { return error }
        if let error = error as? CredentialStoreError {
            lastUnlockFailureCode = error.diagnosticCode
            if case .biometric(let code) = error {
                lastUnlockBiometricErrorCode = code.rawValue
            }
            return .biometric(faceIDFailureMessage(for: error))
        }
        return .network(error.localizedDescription)
    }

    private func isAlreadyLoggedOut(_ error: AuthError) -> Bool {
        if case .server(let status, _) = error { return status == 401 }
        return false
    }
}
