import Foundation
import Security
import XCTest
@testable import CCKit

final class RelayTests: XCTestCase {
    private let expectedP256Pin = "41b9c42ac34d8cd7f63491c59b8405ae5aa7b6a3015c5367e951e836afd65294"

    func testP256CertificateMatchesOpenSSLSPKIVector() throws {
        let certificate = try certificate(named: "relay-p256")
        let pin = try RelayPin.spkiSHA256(of: certificate)
        XCTAssertEqual(pin, expectedP256Pin)
        let relayPin = try RelayPin(pin)
        XCTAssertEqual(relayPin.check, "41B9 C42A")
        XCTAssertEqual(relayPin.grouped, "41b9 c42a c34d 8cd7 f634 91c5 9b84 05ae 5aa7 b6a3 015c 5367 e951 e836 afd6 5294")
    }

    func testRSACertificateIsRejected() throws {
        let certificate = try certificate(named: "relay-rsa")
        XCTAssertThrowsError(try RelayPin.spkiSHA256(of: certificate)) { error in
            guard case .unsupportedKey = error as? RelayPinError else {
                return XCTFail("Expected unsupported key error, got \(error)")
            }
        }
    }

    func testPinnedDelegateAcceptsMatchAndCancelsMismatch() throws {
        let certificate = try certificate(named: "relay-p256")
        let trust = try makeTrust(certificate)
        let pin = try RelayPin.spkiSHA256(of: certificate)
        let endpoint = URL(string: "https://192.0.2.1:47833")!

        let matching = PinnedTrustDelegate(endpoints: [endpoint], mode: .pinned(try RelayPin(pin)))
        let accepted = challenge(trust: trust, host: "192.0.2.1")
        let acceptedDisposition = disposition(delegate: matching, challenge: accepted)
        XCTAssertEqual(acceptedDisposition, .useCredential)

        let mismatch = PinnedTrustDelegate(endpoints: [endpoint], mode: .pinned(try RelayPin(String(repeating: "0", count: 64))))
        let rejected = challenge(trust: trust, host: "192.0.2.1")
        let rejectedDisposition = disposition(delegate: mismatch, challenge: rejected)
        XCTAssertEqual(rejectedDisposition, .cancelAuthenticationChallenge)
        guard case .pinMismatch(let observed) = mismatch.lastFailure else { return XCTFail("Expected pin mismatch") }
        XCTAssertEqual(observed, pin)
    }

    func testTrustOnFirstUseRecordsPin() throws {
        let certificate = try certificate(named: "relay-p256")
        let trust = try makeTrust(certificate)
        let delegate = PinnedTrustDelegate(endpoints: [URL(string: "https://192.0.2.1:47833")!], mode: .trustOnFirstUse)
        XCTAssertEqual(disposition(delegate: delegate, challenge: challenge(trust: trust, host: "192.0.2.1")), .useCredential)
        XCTAssertEqual(delegate.observedPin, try RelayPin.spkiSHA256(of: certificate))
    }

    func testSelectorPrefersEarlierEndpointWithinWindowAndCaches() async throws {
        let endpoints = [URL(string: "https://192.0.2.1:47833")!, URL(string: "https://192.0.2.2:47833")!]
        let clock = RelayTestClock()
        let selector = RelayEndpointSelector(endpoints: endpoints, prober: { endpoint, _ in
            if endpoint == endpoints[0] {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return .reachable
        }, clock: clock)
        let selectedResult = await selector.select()
        let selected = try XCTUnwrap(selectedResult)
        XCTAssertEqual(selected.endpoint, endpoints[0])
        let cached = await selector.select()
        XCTAssertEqual(cached?.endpoint, endpoints[0])
        await selector.invalidate()
        let invalidatedResult = await selector.select()
        let invalidated = try XCTUnwrap(invalidatedResult)
        XCTAssertEqual(invalidated.endpoint, endpoints[0])
        XCTAssertTrue(clock.sleeps.contains(.milliseconds(300)))
    }

    func testSelectorChoosesLaterEndpointAfterPreferenceWindow() async throws {
        let endpoints = [URL(string: "https://192.0.2.1:47833")!, URL(string: "https://192.0.2.2:47833")!]
        let clock = RelayTestClock()
        let selector = RelayEndpointSelector(endpoints: endpoints, prober: { endpoint, _ in
            if endpoint == endpoints[0] {
                try? await Task.sleep(for: .seconds(1))
            }
            return .reachable
        }, clock: clock)
        let selectedResult = await selector.select()
        let selected = try XCTUnwrap(selectedResult)
        XCTAssertEqual(selected.endpoint, endpoints[1])
        XCTAssertEqual(selected.outcomes[endpoints[1]], .reachable)
        XCTAssertTrue(clock.sleeps.contains(.milliseconds(300)))
    }

    func testSelectorReportsPerEndpointOutcomes() async throws {
        let endpoints = [URL(string: "https://192.0.2.1:47833")!, URL(string: "https://192.0.2.2:47833")!]
        let selector = RelayEndpointSelector(endpoints: endpoints, prober: { endpoint, _ in
            endpoint == endpoints[0] ? .pinMismatch : .failed(code: -1009)
        })
        let result = await selector.select()
        XCTAssertNil(result)
    }

    func testHealthPathMappingReportsLocalNetworkDenied() {
        XCTAssertEqual(relayHealthProbeError(for: .localNetworkDenied), .localNetworkDenied)
        XCTAssertNil(relayHealthProbeError(for: .notAvailable))
    }

    func testHealthLineParsing() throws {
        XCTAssertEqual(try parseRelayHealthLine("OK host=1 pending=3 streams=2\n"), RelayHealth(macConnected: true, pending: 3, streams: 2))
        XCTAssertEqual(try parseRelayHealthLine("OK host=0 pending=0 streams=0"), RelayHealth(macConnected: false, pending: 0, streams: 0))
        XCTAssertThrowsError(try parseRelayHealthLine("OK host=yes pending=3 streams=2"))
        XCTAssertThrowsError(try parseRelayHealthLine("not health"))
    }

    func testInMemoryCredentialStoreRelayPinRoundTrip() async throws {
        let store = InMemoryCredentialStore()
        let initiallyStored = try await store.loadRelayPin()
        XCTAssertNil(initiallyStored)
        try await store.saveRelayPin(expectedP256Pin)
        let stored = try await store.loadRelayPin()
        XCTAssertEqual(stored, expectedP256Pin)
        try await store.deleteRelayPin()
        let deleted = try await store.loadRelayPin()
        XCTAssertNil(deleted)
    }

    private func certificate(named name: String) throws -> SecCertificate {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pem"))
        let pem = try String(contentsOf: url, encoding: .utf8)
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }

    private func makeTrust(_ certificate: SecCertificate) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(trust)
    }

    private func challenge(trust: SecTrust, host: String) -> URLAuthenticationChallenge {
        let protectionSpace = TrustProtectionSpace(host: host, trust: trust)
        return URLAuthenticationChallenge(protectionSpace: protectionSpace, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
    }

    private func disposition(delegate: PinnedTrustDelegate, challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        var disposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared, didReceive: challenge) { value, _ in disposition = value }
        return disposition!
    }
}

private final class TrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(host: String, trust: SecTrust) {
        self.trust = trust
        super.init(host: host, port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }

    required init?(coder: NSCoder) {
        fatalError("TrustProtectionSpace is not decoded")
    }

    override var serverTrust: SecTrust? { trust }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { }
    func cancel(_ challenge: URLAuthenticationChallenge) { }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { }
}

private final class RelayTestClock: CCKitClock, @unchecked Sendable {
    private let queue = DispatchQueue(label: "relay-test-clock")
    private var recordedSleeps: [Duration] = []

    var now: Date { Date() }

    var sleeps: [Duration] {
        queue.sync { recordedSleeps }
    }

    func sleep(for duration: Duration) async throws {
        queue.sync { recordedSleeps.append(duration) }
        try await Task.sleep(for: duration)
    }
}
