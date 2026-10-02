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
            .locked(message: "Face ID did not work. Try again.")
        )
    }
}
