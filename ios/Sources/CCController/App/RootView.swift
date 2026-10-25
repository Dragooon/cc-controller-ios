import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            #if DEBUG
            if let result = model.keychainSelfTestResult {
                Text(result)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(32)
            } else {
                content
            }
            #else
            content
            #endif

            if model.identityChanged {
                IdentityChangedView(
                    onRetry: model.retryConnection,
                    onPairAgain: { Task { await model.pairAgain() } }
                )
            } else if model.isPrivacyCovered {
                PrivacyCoverView()
            }
        }
        .tint(.ccAccent)
        .onAppear {
            model.scenePhaseDidChange(scenePhase)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                model.startStoreIfNeeded()
            }
        }
        .onChange(of: model.phase) { _, _ in
            model.startStoreIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseDidChange(phase)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .onboarding:
            onboardingView
        case .locked:
            LockView(message: model.faceIDMessage, isAuthenticating: model.isAuthenticating) {
                Task { await model.unlock() }
            }
        case .unlocked:
            MainSplitView(model: model)
        }
    }

    @ViewBuilder
    private var onboardingView: some View {
        switch model.onboardingStep {
        case .welcome:
            OnboardingWelcomeView(onContinue: model.continueFromWelcome)
        case .connect:
            OnboardingConnectView(
                connection: model.connection,
                address: model.connectionAddress,
                message: model.connectionMessage,
                diagnostics: model.relayDiagnostics,
                onBack: model.goBackFromConnect,
                onContinue: model.continueFromConnect,
                onRetry: model.retryConnection
            )
        case .pair:
            OnboardingPairView(
                code: model.pairingCode ?? "",
                expiresAt: model.pairingExpiresAt ?? .now,
                isExpired: model.onboarding.isPairingExpired(at: .now),
                copied: model.copiedPairingCommand,
                relayCheck: model.relayMode ? model.relayPairingCheck : nil,
                relayPin: model.relayMode ? (model.relayPinGrouped ?? "") : nil,
                message: model.connectionMessage,
                onBack: model.goBackToConnect,
                onCopyCode: model.copyPairingCommand,
                onNewCode: model.getNewPairingCode
            )
        case .faceID:
            OnboardingFaceIDView(
                message: model.faceIDMessage,
                onBack: model.goBackToConnect,
                onTryAgain: { Task { await model.enrollAndUnlock() } }
            )
        case .sessions:
            EmptyView()
        }
    }
}
