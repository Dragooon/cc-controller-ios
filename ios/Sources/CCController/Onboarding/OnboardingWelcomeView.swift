import SwiftUI

struct OnboardingWelcomeView: View {
    let onGetStarted: () -> Void

    init(onGetStarted: @escaping () -> Void = {}) {
        self.onGetStarted = onGetStarted
    }

    var body: some View {
        OnboardingPage(step: "Step 1 of 4", buttonTitle: "Get started", action: onGetStarted) {
            VStack(spacing: 18) {
                Text("✻")
                    .font(.system(size: 88, weight: .regular, design: .rounded))
                    .foregroundStyle(.ccAccent)
                    .accessibilityHidden(true)

                Text("cc-controller")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.ccLabel)
                    .multilineTextAlignment(.center)

                Text("Approve, message and follow your Claude Code sessions from this iPhone.")
                    .font(.body)
                    .foregroundStyle(.ccSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
