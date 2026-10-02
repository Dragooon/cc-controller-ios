import Foundation
import Observation

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
    @ObservationIgnored private var bearerToken: String?
    @ObservationIgnored private var pairingCode: String?
    @ObservationIgnored private var pairedDeviceToken: String?
    @ObservationIgnored private var deviceName: String?

    public init(
        client: AuthClient,
        credentials: any CredentialStore,
        clock: any CCKitClock = SystemCCKitClock(),
        cacheDirectory: URL? = nil
    ) {
        self.client = client
        self.credentials = credentials
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

    public func probeDaemon() async throws -> DaemonProbe {
        try await client.probeDaemon()
    }

    public func bearer() async throws -> String {
        guard let bearerToken, case .unlocked = state else { throw AuthError.locked }
        return bearerToken
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

    public func unlock() async -> Result<Void, AuthError> {
        state = .unlocking
        do {
            guard let secret = try await credentials.getNativeSecret() else { return fail(.notEnrolled) }
            let response = try await client.login(secret: secret)
            guard response.authenticated != false, let token = response.token, !token.isEmpty else { throw AuthError.unknownSecret }
            bearerToken = token
            state = .unlocked(bearerExpiresAt: response.expiresAt ?? clock.now.addingTimeInterval(12 * 60 * 60))
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

    public func handleUnauthorized() async -> Result<Void, AuthError> {
        bearerToken = nil
        state = .locked
        return await unlock()
    }

    public func logout() async -> Result<Void, AuthError> {
        guard let bearerToken else {
            state = .locked
            return .success(())
        }
        do {
            try await client.logout(bearer: bearerToken)
            self.bearerToken = nil
            state = .locked
            return .success(())
        } catch {
            self.bearerToken = nil
            state = .locked
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
        try? await cache?.clear()
        bearerToken = nil
    }

    private func fail(_ error: AuthError) -> Result<Void, AuthError> {
        state = .failed(error)
        return .failure(error)
    }

    private func asAuthError(_ error: Error) -> AuthError {
        if let error = error as? AuthError { return error }
        if let error = error as? CredentialStoreError { return .biometric(faceIDFailureMessage(for: error)) }
        return .network(error.localizedDescription)
    }

    private func isAlreadyLoggedOut(_ error: AuthError) -> Bool {
        if case .server(let status, _) = error { return status == 401 }
        return false
    }
}
