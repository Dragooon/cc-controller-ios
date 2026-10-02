import LocalAuthentication
import XCTest
@testable import CCKit

final class BiometricMessageTests: XCTestCase {
    func testAuthenticationFailedMessage() {
        XCTAssertEqual(faceIDFailureMessage(for: .biometric(.authenticationFailed)), "Face ID didn't match. Try again.")
    }

    func testUserCancelMessage() {
        XCTAssertEqual(faceIDFailureMessage(for: .biometric(.userCancel)), "Unlock with Face ID to continue.")
    }

    func testSystemCancelMessage() {
        XCTAssertEqual(faceIDFailureMessage(for: .biometric(.systemCancel)), "Unlock with Face ID to continue.")
    }

    func testAppCancelMessage() {
        XCTAssertEqual(faceIDFailureMessage(for: .biometric(.appCancel)), "Unlock with Face ID to continue.")
    }

    func testBiometryLockoutMessage() {
        XCTAssertEqual(
            faceIDFailureMessage(for: .biometric(.biometryLockout)),
            "Face ID is locked after too many attempts. Unlock your iPhone with your passcode, then try again."
        )
    }

    func testBiometryNotEnrolledMessage() {
        XCTAssertEqual(faceIDFailureMessage(for: .biometric(.biometryNotEnrolled)), "Set up Face ID in Settings to use this app")
    }

    func testBiometryNotAvailableMessage() {
        XCTAssertEqual(faceIDFailureMessage(for: .biometric(.biometryNotAvailable)), "Face ID is off for cc-controller. Turn it on in Settings.")
    }

    func testOtherBiometricErrorMessage() {
        XCTAssertEqual(faceIDFailureMessage(for: .biometric(LAError.Code(rawValue: 999)!)), "Face ID did not work. Try again.")
    }

    func testKeychainFailureAfterScanMessage() {
        XCTAssertEqual(faceIDFailureMessage(for: .accessDenied), "Secure storage could not be unlocked.")
    }
}
