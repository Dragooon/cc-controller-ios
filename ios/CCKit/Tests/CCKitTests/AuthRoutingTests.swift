import LocalAuthentication
import XCTest
@testable import CCKit

final class AuthRoutingTests: XCTestCase {
    func testUnknownSecretRequestsRepair() {
        XCTAssertEqual(
            unlockRoute(for: .unknownSecret),
            .rePair(message: "This iPhone was removed on the Mac. Pair again to continue.")
        )
    }

    func testNotEnrolledRequestsRepair() {
        XCTAssertEqual(
            unlockRoute(for: .notEnrolled),
            .rePair(message: "Face ID changed on this iPhone. Pair again to continue.")
        )
    }

    func testBiometricFailureStaysLockedWithMappedMessage() {
        XCTAssertEqual(
            unlockRoute(for: .biometric("Unlock with Face ID to continue.")),
            .locked(message: "Unlock with Face ID to continue.")
        )
    }

    func testNetworkFailureStaysLockedWithMappedMessage() {
        XCTAssertEqual(
            unlockRoute(for: .network("offline")),
            .locked(message: "Can't reach your Mac. Check that Termius is forwarding localhost:47832 and the Mac is awake.")
        )
    }

    func testServerAndRateLimitFailuresNameTheMac() {
        XCTAssertEqual(
            unlockRoute(for: .server(status: 500, message: "boom")),
            .locked(message: "Your Mac could not sign this iPhone in (HTTP 500). Try again.")
        )
        XCTAssertEqual(
            unlockRoute(for: .rateLimited),
            .locked(message: "Too many unlock attempts. Wait a minute, then try again.")
        )
    }
}
