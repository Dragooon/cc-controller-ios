import SwiftUI

struct OnboardingFaceIDView: View {
    let onTurnOn: () -> Void

    init(onTurnOn: @escaping () -> Void = {}) {
        self.onTurnOn = onTurnOn
    }

    var body: some View {
        OnboardingPage(step: "Step 4 of 4", buttonTitle: "Turn on Face ID", action: onTurnOn) {
            VStack(spacing: 18) {
                Image(systemName: "faceid")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.ccAccent)
                    .accessibilityHidden(true)

                Text("Protect with Face ID")
                    .font(.title.bold())
                    .foregroundStyle(.ccLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("cc-controller locks when you leave it, and Face ID unlocks it.")
                    .font(.body)
                    .foregroundStyle(.ccSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("The key stays in this iPhone's Keychain and never leaves it.")
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
