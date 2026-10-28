import XCTest
import LocalAuthentication
@testable import CCKit

@MainActor
final class BiometricUnlockSessionTests: XCTestCase {
    func testAuthorizedContextEvaluatesOnceAndReturnsSameContext() async throws {
        let evaluations = EvaluationCounter()
        let session = BiometricUnlockSession { _, _ in
            _ = await evaluations.increment()
        }

        let first = try await session.authorizedContext(reason: "Unlock Code")
        let second = try await session.authorizedContext(reason: "Unlock Code")

        XCTAssertTrue(first === second)
        let count = await evaluations.value
        XCTAssertEqual(count, 1)
    }

    func testFailedEvaluationIsNotCached() async throws {
        let evaluations = EvaluationCounter()
        let session = BiometricUnlockSession { _, _ in
            let attempt = await evaluations.increment()
            if attempt == 1 {
                throw LAError(.authenticationFailed)
            }
        }

        do {
            _ = try await session.authorizedContext(reason: "Unlock Code")
            XCTFail("The first biometric evaluation should fail")
        } catch let error as CredentialStoreError {
            XCTAssertEqual(error, .biometric(.authenticationFailed))
        }
        _ = try await session.authorizedContext(reason: "Unlock Code")

        let count = await evaluations.value
        XCTAssertEqual(count, 2)
    }

    func testInvalidateInvalidatesContextAndRejectsLaterCalls() async throws {
        let session = BiometricUnlockSession { _, _ in }
        _ = try await session.authorizedContext(reason: "Unlock Code")

        session.invalidate()

        do {
            _ = try await session.authorizedContext(reason: "Unlock Code")
            XCTFail("An invalidated biometric session should reject later calls")
        } catch let error as CredentialStoreError {
            XCTAssertEqual(error, .biometric(.appCancel))
        }
    }
}

private actor EvaluationCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    var value: Int { count }
}
