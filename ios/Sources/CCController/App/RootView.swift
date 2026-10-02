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

            if model.isPrivacyCovered {
                PrivacyCoverView()
            }
        }
        .tint(.ccAccent)
        .onAppear {
            model.scenePhaseDidChange(scenePhase)
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
            OnboardingWelcomeView()
        case .locked:
            LockView {
                Task { await model.unlock() }
            }
        case .unlocked:
            MainSplitView(model: model)
        }
    }
}
