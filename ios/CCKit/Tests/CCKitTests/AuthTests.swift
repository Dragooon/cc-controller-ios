import Foundation
import XCTest
@testable import CCKit

@MainActor
final class AuthTests: XCTestCase {
    func testProbeUsesUnauthenticatedWhoamiAndAcceptsPairingRequired401() async throws {
        AuthURLProtocol.handler = { _ in
            AuthURLProtocol.json(401, body: Data("{\"error\":\"Device pairing required\",\"authenticated\":false}".utf8))
        }
        let client = AuthClient(baseURL: URL(string: "http://localhost:47832")!, session: AuthURLProtocol.session)
        let result = try await client.probeDaemon()
        XCTAssertTrue(result.isReachable)
        XCTAssertGreaterThan(result.latency, .zero)
        XCTAssertEqual(AuthURLProtocol.requests.last?.url?.path, "/api/auth/whoami")
    }

    func testAuthClientRunsPairPollEnrollLoginAndLogout() async throws {
        AuthURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/pair/start": return AuthURLProtocol.json(Data("{\"code\":\"123456\",\"expiresAt\":\"2026-09-30T12:05:00Z\"}".utf8))
            case "/api/pair/poll": return AuthURLProtocol.json(Data("{\"state\":\"confirmed\",\"deviceToken\":\"device-token\"}".utf8))
            case "/api/auth/native/enroll": return AuthURLProtocol.json(Data("{\"secret\":\"native-secret\"}".utf8))
            case "/api/auth/native/login": return AuthURLProtocol.json(Data("{\"authenticated\":true,\"token\":\"bearer\",\"expiresAt\":\"2026-09-30T20:00:00Z\"}".utf8))
            case "/api/auth/logout": return AuthURLProtocol.json(Data("{\"loggedOut\":true}".utf8))
            default: return AuthURLProtocol.json(404, body: Data("{\"error\":\"Not found\"}".utf8))
            }
        }
        let client = AuthClient(baseURL: URL(string: "http://localhost:47832")!, session: AuthURLProtocol.session)
        let started = try await client.startPairing(deviceName: "iPhone")
        XCTAssertEqual(started.code, "123456")
        XCTAssertNotNil(started.expiresAt)
        let polled = try await client.pollPairing(code: "123456")
        XCTAssertEqual(polled.deviceToken, "device-token")
        let enrolled = try await client.enroll(deviceToken: "device-token", deviceName: "iPhone")
        XCTAssertEqual(enrolled.secret, "native-secret")
        let loggedIn = try await client.login(secret: "native-secret")
        XCTAssertEqual(loggedIn.token, "bearer")
        try await client.logout(bearer: "bearer")
        let logoutRequest = try XCTUnwrap(AuthURLProtocol.requests.last)
        XCTAssertEqual(logoutRequest.value(forHTTPHeaderField: "Authorization"), "Bearer bearer")
        XCTAssertEqual(logoutRequest.timeoutInterval, 5, accuracy: 0.001)
    }

    func testAuthClientMapsExpiredEnrollmentLoginAndNetworkErrors() async throws {
        AuthURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/pair/poll": return AuthURLProtocol.json(Data("{\"state\":\"expired\"}".utf8))
            case "/api/auth/native/enroll": return AuthURLProtocol.json(409, body: Data("{\"error\":\"legacy enrollment text\",\"code\":\"already_enrolled\"}".utf8))
            case "/api/auth/native/login": return AuthURLProtocol.json(401, body: Data("{\"error\":\"Unknown device secret\"}".utf8))
            default: return AuthURLProtocol.failure(URLError(.notConnectedToInternet))
            }
        }
        let client = AuthClient(baseURL: URL(string: "http://localhost:47832")!, session: AuthURLProtocol.session)
        let expired = try await client.pollPairing(code: "123456")
        XCTAssertEqual(expired.state, .expired)
        do { _ = try await client.enroll(deviceToken: "token", deviceName: "iPhone"); XCTFail("Expected already enrolled") }
        catch let error as AuthError { guard case .alreadyEnrolled = error else { return XCTFail("Expected already enrolled") } }
        AuthURLProtocol.handler = { request in
            if request.url?.path == "/api/auth/native/enroll" { return AuthURLProtocol.json(401, body: Data("{\"error\":\"Login required\"}".utf8)) }
            return AuthURLProtocol.json(401, body: Data("{\"error\":\"Unknown device secret\"}".utf8))
        }
        do { _ = try await client.enroll(deviceToken: "token", deviceName: "iPhone"); XCTFail("Expected login-required enrollment failure") }
        catch let error as AuthError { guard case .loginRequired = error else { return XCTFail("Expected login-required enrollment failure") } }
        do { _ = try await client.login(secret: "secret"); XCTFail("Expected unknown secret") }
        catch let error as AuthError { guard case .unknownSecret = error else { return XCTFail("Expected unknown secret") } }
        AuthURLProtocol.handler = { _ in AuthURLProtocol.json(500, body: Data("{\"error\":\"legacy pairing text\",\"code\":\"pairing_expired\"}".utf8)) }
        do { _ = try await client.startPairing(deviceName: "iPhone"); XCTFail("Expected code-first pairing failure") }
        catch let error as AuthError { guard case .pairingExpired = error else { return XCTFail("Expected code-first pairing failure") } }
        AuthURLProtocol.handler = { _ in AuthURLProtocol.failure(URLError(.notConnectedToInternet)) }
        do { _ = try await client.startPairing(deviceName: "iPhone"); XCTFail("Expected network failure") }
        catch let error as AuthError { guard case .network = error else { return XCTFail("Expected network failure") } }
    }

    func testAuthSessionTransitionsAndBearerProvider() async throws {
        AuthURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/pair/start": return AuthURLProtocol.json(Data("{\"code\":\"123456\"}".utf8))
            case "/api/pair/poll": return AuthURLProtocol.json(Data("{\"state\":\"confirmed\",\"deviceToken\":\"device-token\"}".utf8))
            case "/api/auth/native/enroll": return AuthURLProtocol.json(Data("{\"secret\":\"native-secret\"}".utf8))
            case "/api/auth/native/login": return AuthURLProtocol.json(Data("{\"authenticated\":true,\"token\":\"bearer\"}".utf8))
            case "/api/auth/logout": return AuthURLProtocol.json(Data("{\"loggedOut\":true}".utf8))
            default: return AuthURLProtocol.json(Data("{}".utf8))
            }
        }
        let credentials = InMemoryCredentialStore()
        let clock = TestAuthClock(now: Date(timeIntervalSince1970: 1_000))
        let auth = AuthSession(serverURL: URL(string: "http://localhost:47832")!, credentials: credentials, session: AuthURLProtocol.session, clock: clock)
        XCTAssertEqual(auth.state, .locked)
        do { _ = try await auth.bearerProvider(); XCTFail("Cold launch must be locked") }
        catch let error as AuthError { guard case .locked = error else { return XCTFail("Cold launch must be locked") } }
        guard case .success = await auth.startPairing(deviceName: "iPhone") else { return XCTFail("Pairing did not start") }
        guard case .pairing(let code, _) = auth.state else { return XCTFail("Expected pairing state") }
        XCTAssertEqual(code, "123456")
        guard case .success = await auth.pollPairing() else { return XCTFail("Pairing did not confirm") }
        XCTAssertEqual(auth.state, .enrolling)
        guard case .success = await auth.enroll() else { return XCTFail("Enrollment failed") }
        XCTAssertEqual(auth.state, .locked)
        guard case .success = await auth.unlock() else { return XCTFail("Unlock failed") }
        let bearer = try await auth.bearer()
        XCTAssertEqual(bearer, "bearer")
        XCTAssertEqual(auth.state, .unlocked(bearerExpiresAt: clock.now.addingTimeInterval(12 * 60 * 60)))
        guard case .success = await auth.handleUnauthorized() else { return XCTFail("Re-unlock failed") }
        guard case .success = await auth.unpair() else { return XCTFail("Unpair failed") }
        XCTAssertEqual(auth.state, .unpaired)
        let deviceToken = try await credentials.getDeviceToken()
        let nativeSecret = try await credentials.getNativeSecret()
        XCTAssertNil(deviceToken)
        XCTAssertNil(nativeSecret)
    }

    func testRevokedSecretReturnsToUnpaired() async throws {
        AuthURLProtocol.handler = { request in
            if request.url?.path == "/api/auth/native/login" { return AuthURLProtocol.json(401, body: Data("{\"error\":\"Unknown device secret\"}".utf8)) }
            return AuthURLProtocol.json(Data("{}".utf8))
        }
        let credentials = InMemoryCredentialStore(deviceToken: "device", nativeSecret: "revoked")
        let auth = AuthSession(serverURL: URL(string: "http://localhost:47832")!, credentials: credentials, session: AuthURLProtocol.session)
        guard case .failure(.unknownSecret) = await auth.unlock() else { return XCTFail("Expected revoked-secret failure") }
        XCTAssertEqual(auth.state, .unpaired)
        let deviceToken = try await credentials.getDeviceToken()
        let nativeSecret = try await credentials.getNativeSecret()
        XCTAssertNil(deviceToken)
        XCTAssertNil(nativeSecret)
    }

    func testAuthSessionLockDiscardsBearer() async throws {
        AuthURLProtocol.handler = { request in
            if request.url?.path == "/api/auth/native/login" {
                return AuthURLProtocol.json(Data("{\"authenticated\":true,\"token\":\"bearer\"}".utf8))
            }
            return AuthURLProtocol.json(Data("{}".utf8))
        }
        let credentials = InMemoryCredentialStore(nativeSecret: "native-secret")
        let auth = AuthSession(
            serverURL: URL(string: "http://localhost:47832")!,
            credentials: credentials,
            session: AuthURLProtocol.session
        )

        guard case .success = await auth.unlock() else { return XCTFail("Unlock failed") }
        auth.lock()

        do {
            _ = try await auth.bearer()
            XCTFail("Locked auth must not return a bearer")
        } catch let error as AuthError {
            guard case .locked = error else { return XCTFail("Expected locked error") }
        }
        XCTAssertEqual(auth.state, .locked)
    }

    func testLockPolicyIntervalsAndPrivacyCover() {
        let date = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(LockPolicy().shouldLockOnColdLaunch(lastUnlockAt: nil, lastBackgroundAt: nil, now: date))
        XCTAssertFalse(LockPolicy(interval: .oneHour).shouldLockOnForeground(
            lastUnlockAt: date,
            after: date.addingTimeInterval(-2 * 60),
            now: date.addingTimeInterval(60)
        ))
        XCTAssertTrue(LockPolicy(interval: .immediately).shouldLockOnForeground(
            lastUnlockAt: date,
            after: date,
            now: date
        ))
        XCTAssertFalse(LockPolicy(interval: .oneHour).shouldLockOnForeground(
            lastUnlockAt: date,
            after: date.addingTimeInterval(3500),
            now: date.addingTimeInterval(3599)
        ))
        XCTAssertTrue(LockPolicy(interval: .oneHour).shouldLockOnForeground(
            lastUnlockAt: date,
            after: nil,
            now: date.addingTimeInterval(3600)
        ))
        XCTAssertTrue(LockPolicy().shouldShowPrivacyCover(isActive: false, isBackgrounded: false, isLocked: false))
        XCTAssertTrue(LockPolicy().shouldShowPrivacyCover(isActive: true, isBackgrounded: true, isLocked: false))
        XCTAssertFalse(LockPolicy().shouldShowPrivacyCover(isActive: true, isBackgrounded: false, isLocked: false))
    }
}

private struct TestAuthClock: CCKitClock {
    let now: Date
    func sleep(for duration: Duration) async throws {}
}

private final class AuthURLProtocol: URLProtocol {
    enum Outcome { case response(HTTPURLResponse, Data); case failure(URLError) }
    nonisolated(unsafe) static var handler: ((URLRequest) -> Outcome)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard let outcome = Self.handler?(request) else { fatalError("No auth URLProtocol handler") }
        switch outcome {
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .response(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}

    static func json(_ body: Data) -> Outcome { json(200, body: body) }
    static func json(_ status: Int, body: Data) -> Outcome {
        .response(HTTPURLResponse(url: URL(string: "http://localhost")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, body)
    }
    static func failure(_ error: URLError) -> Outcome { .failure(error) }
}
