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
        XCTAssertEqual(faceIDFailureMessage(for: .biometric(.biometryNotEnrolled)), "Set up Face ID in Settings to use this app.")
    }

    func testBiometryNotAvailableMessage() {
        XCTAssertEqual(faceIDFailureMessage(for: .biometric(.biometryNotAvailable)), "Face ID is off for Code. Turn it on in Settings.")
    }

    func testOtherBiometricErrorMessageIncludesLAErrorCode() {
        XCTAssertEqual(
            faceIDFailureMessage(for: .biometric(LAError.Code(rawValue: 999)!)),
            "Face ID did not work. Try again. (LAError 999)"
        )
    }

    func testKeychainFailureAfterScanIncludesOSStatus() {
        XCTAssertEqual(faceIDFailureMessage(for: .keychain(-25293)), "Secure storage could not be unlocked. (OSStatus -25293)")
    }

    func testDiagnosticCodePreservesUnderlyingDomainCode() {
        XCTAssertEqual(CredentialStoreError.biometric(.authenticationFailed).diagnosticCode, "LAError -1")
        XCTAssertEqual(CredentialStoreError.keychain(-25293).diagnosticCode, "OSStatus -25293")
    }
}
