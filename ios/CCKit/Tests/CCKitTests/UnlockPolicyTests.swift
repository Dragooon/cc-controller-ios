import XCTest
@testable import CCKit

final class UnlockPolicyTests: XCTestCase {
    private let mustafar = try! ControllerID("mustafar")

    private func mac(_ error: AuthError?) -> ControllerUnlockResult {
        ControllerUnlockResult(controllerID: .mac, name: "Mac", isPrimary: true, error: error)
    }

    private func mustafarResult(_ error: AuthError?) -> ControllerUnlockResult {
        ControllerUnlockResult(controllerID: mustafar, name: "Mustafar", isPrimary: false, error: error)
    }

    func testAnUnreachableMacNoLongerHoldsMustafarBack() {
        XCTAssertEqual(
            appUnlockOutcome([mac(.network("no-host")), mustafarResult(nil)]),
            .unlocked(signedOut: [.mac: .unreachable])
        )
    }

    func testARelayGatewayErrorCountsAsUnreachable() {
        XCTAssertEqual(
            appUnlockOutcome([mac(.server(status: 502, message: "no-host")), mustafarResult(nil)]),
            .unlocked(signedOut: [.mac: .unreachable])
        )
    }

    func testMustafarFailingLeavesTheMacSignedIn() {
        XCTAssertEqual(
            appUnlockOutcome([mac(nil), mustafarResult(.unknownSecret)]),
            .unlocked(signedOut: [mustafar: .signInNeeded])
        )
    }

    func testEverySignInWorkingSignsNothingOut() {
        XCTAssertEqual(appUnlockOutcome([mac(nil), mustafarResult(nil)]), .unlocked(signedOut: [:]))
    }

    func testNothingReachableStaysLockedAndNamesBoth() {
        XCTAssertEqual(
            appUnlockOutcome([mac(.network("offline")), mustafarResult(.network("offline"))]),
            .locked(message: "Can't reach Mac or Mustafar. Check your connection and that they're online, then try again.")
        )
    }

    func testASingleUnreachableControllerIsNamed() {
        XCTAssertEqual(
            appUnlockOutcome([mac(.network("offline"))]),
            .locked(message: "Can't reach Mac. Check your connection and that it's online, then try again.")
        )
    }

    func testThreeNamesUseCommasAndOr() {
        XCTAssertEqual(
            unreachableMessage(names: ["Mac", "Mustafar", "Kepler"]),
            "Can't reach Mac, Mustafar or Kepler. Check your connection and that they're online, then try again."
        )
    }

    func testAFaceIDProblemComesFirst() {
        XCTAssertEqual(
            appUnlockOutcome([mac(.biometric("Face ID didn't match. Try again.")), mustafarResult(.biometric("Face ID didn't match. Try again."))]),
            .locked(message: "Face ID didn't match. Try again.")
        )
    }

    func testMixedFailuresShowThePrimarysOwnSentence() {
        XCTAssertEqual(
            appUnlockOutcome([mac(.rateLimited), mustafarResult(.network("offline"))]),
            .locked(message: "Too many unlock attempts. Wait a minute, then try again.")
        )
        XCTAssertEqual(
            appUnlockOutcome([mac(.server(status: 401, message: "no")), mustafarResult(.network("offline"))]),
            .locked(message: "Mac could not sign this iPhone in (HTTP 401). Try again.")
        )
    }

    func testThePrimaryNeedingPairingNoLongerHidesMustafar() {
        // 25 Nov: the Mac forgot this iPhone and the pairing screen hid Mustafar, which was signed in.
        XCTAssertEqual(
            appUnlockOutcome([mac(.unknownSecret), mustafarResult(nil)]),
            .unlocked(signedOut: [.mac: .signInNeeded])
        )
    }

    func testThePrimaryRemovingThisIPhoneAsksToPairAgainWhenNothingElseSignedIn() {
        XCTAssertEqual(
            appUnlockOutcome([mac(.unknownSecret), mustafarResult(.network("offline"))]),
            .rePair(message: "This iPhone was removed on the Mac. Pair again to continue.")
        )
        XCTAssertEqual(
            appUnlockOutcome([mac(.unknownSecret)]),
            .rePair(message: "This iPhone was removed on the Mac. Pair again to continue.")
        )
        XCTAssertEqual(
            appUnlockOutcome([mac(.notEnrolled), mustafarResult(.notEnrolled)]),
            .rePair(message: "Face ID changed on this iPhone. Pair again to continue.")
        )
    }

    func testSignOutReasons() {
        XCTAssertEqual(signOutReason(for: .network("offline")), .unreachable)
        XCTAssertEqual(signOutReason(for: .server(status: 503, message: "")), .unreachable)
        XCTAssertEqual(signOutReason(for: .server(status: 401, message: "")), .signInNeeded)
        XCTAssertEqual(signOutReason(for: .unknownSecret), .signInNeeded)
        XCTAssertEqual(signOutReason(for: .locked), .signInNeeded)
    }

    func testASignOutLocksTheAppOnlyWhenNothingElseIsSignedIn() {
        XCTAssertTrue(signOutLocksApp(stillSignedIn: 0))
        XCTAssertFalse(signOutLocksApp(stillSignedIn: 1))
    }

    func testANamedFailureSentence() {
        XCTAssertEqual(
            faceIDFailureMessage(for: .decoding("bad"), controllerName: "Mustafar"),
            "Mustafar sent an unexpected reply. Try again."
        )
    }
}
