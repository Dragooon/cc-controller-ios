import Foundation
import LocalAuthentication

extension LAContext: @retroactive @unchecked Sendable {}

@MainActor
public final class BiometricUnlockSession: Sendable {
    private let context: LAContext
    private let evaluator: @MainActor @Sendable (LAContext, String) async throws -> Void
    private var isAuthorized = false
    private var isInvalidated = false
    private var evaluationTask: Task<Void, Error>?

    public init(
        evaluator: @escaping @MainActor @Sendable (LAContext, String) async throws -> Void = { context, reason in
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        }
    ) {
        context = LAContext()
        context.localizedFallbackTitle = ""
        self.evaluator = evaluator
    }

    public func authorizedContext(reason: String) async throws -> LAContext {
        guard !isInvalidated else { throw CredentialStoreError.biometric(.appCancel) }
        if isAuthorized { return context }

        let task: Task<Void, Error>
        if let evaluationTask {
            task = evaluationTask
        } else {
            let context = self.context
            let evaluator = self.evaluator
            task = Task { @MainActor in
                do {
                    try await evaluator(context, reason)
                } catch let error as LAError {
                    throw CredentialStoreError.biometric(error.code)
                } catch {
                    throw CredentialStoreError.system(error.localizedDescription)
                }
            }
            evaluationTask = task
        }

        do {
            try await task.value
        } catch {
            evaluationTask = nil
            throw error
        }
        guard !isInvalidated else {
            throw CredentialStoreError.biometric(.appCancel)
        }
        isAuthorized = true
        evaluationTask = nil
        return context
    }

    public func invalidate() {
        isInvalidated = true
        isAuthorized = false
        evaluationTask?.cancel()
        evaluationTask = nil
        context.invalidate()
    }
}
