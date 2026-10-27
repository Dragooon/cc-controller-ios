import SwiftUI

struct OnboardingWelcomeView: View {
    let onContinue: () -> Void

    init(onContinue: @escaping () -> Void = {}) {
        self.onContinue = onContinue
    }

    var body: some View {
        OnboardingPage(step: "Step 1 of 4", buttonTitle: "Get started", action: onContinue) {
            VStack(spacing: 18) {
                Text("✻")
                    .font(.system(size: 88, weight: .regular, design: .rounded))
                    .foregroundStyle(.ccAccent)
                    .accessibilityHidden(true)

                Text("Code")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.ccLabel)
                    .multilineTextAlignment(.center)

                Text("Approve, message and follow your Claude Code sessions from this iPhone.")
                    .font(.body)
                    .foregroundStyle(.ccSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Code. Approve, message and follow your Claude Code sessions from this iPhone.")
        }
    }
}
