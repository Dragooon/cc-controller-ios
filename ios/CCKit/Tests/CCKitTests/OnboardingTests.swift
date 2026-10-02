import Foundation
import XCTest
@testable import CCKit

final class OnboardingTests: XCTestCase {
    func testStepTransitionsFollowOnboardingOrder() {
        var state = OnboardingFlowState()
        XCTAssertEqual(state.step, .welcome)

        state.continueFromWelcome()
        XCTAssertEqual(state.step, .connect)
        state.markConnectionConnected()
        state.beginPairing(code: "482913", expiresAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(state.step, .pair)
        state.markPairingConfirmed(at: Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(state.step, .faceID)
        state.finish()
        XCTAssertEqual(state.step, .sessions)
    }

    func testPairingCodeExpiresAtItsDeadlineAndKeepsExpiredState() {
        var state = OnboardingFlowState()
        let expiry = Date(timeIntervalSince1970: 1_000)
        state.beginPairing(code: "482913", expiresAt: expiry)

        XCTAssertFalse(state.isPairingExpired(at: expiry.addingTimeInterval(-0.1)))
        XCTAssertTrue(state.isPairingExpired(at: expiry))
        state.markPairingExpired()
        XCTAssertTrue(state.pairingExpired)
        XCTAssertEqual(state.pairingCode, "482913")
    }

    func testEnrollmentWindowIsTenMinutesAfterConfirmation() {
        var state = OnboardingFlowState()
        let confirmed = Date(timeIntervalSince1970: 2_000)
        state.beginPairing(code: "482913", expiresAt: confirmed.addingTimeInterval(300))
        state.markPairingConfirmed(at: confirmed)

        XCTAssertTrue(state.enrollmentWindowOpen(at: confirmed))
        XCTAssertTrue(state.enrollmentWindowOpen(at: confirmed.addingTimeInterval(599.999)))
        XCTAssertFalse(state.enrollmentWindowOpen(at: confirmed.addingTimeInterval(600)))
        XCTAssertFalse(state.enrollmentWindowOpen(at: confirmed.addingTimeInterval(-1)))
    }

    func testBackgroundResumeKeepsTheCurrentStepAndExpiry() {
        var state = OnboardingFlowState()
        let expiry = Date(timeIntervalSince1970: 3_000)
        state.continueFromWelcome()
        state.beginPairing(code: "482913", expiresAt: expiry)

        state.resumeAfterBackground()

        XCTAssertEqual(state.step, .pair)
        XCTAssertEqual(state.pairingCode, "482913")
        XCTAssertEqual(state.pairingExpiresAt, expiry)
        XCTAssertFalse(state.pairingExpired)
    }
}
