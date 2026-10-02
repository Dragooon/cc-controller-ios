import SwiftUI

struct OnboardingFaceIDView: View {
    let message: String?
    let onBack: () -> Void
    let onTryAgain: () -> Void

    init(
        message: String? = nil,
        onBack: @escaping () -> Void = {},
        onTryAgain: @escaping () -> Void = {}
    ) {
        self.message = message
        self.onBack = onBack
        self.onTryAgain = onTryAgain
    }

    var body: some View {
        OnboardingPage(
            step: "Step 4 of 4",
            buttonTitle: message == nil ? "Turn on Face ID" : "Try again",
            onBack: onBack,
            action: onTryAgain
        ) {
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

                if let message {
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccAccent)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(message)
                }
            }
        }
    }
}
