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
        OnboardingPage(step: "Step 4 of 5", buttonTitle: nil, onBack: onBack) {
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

                Text("Use Face ID to protect this iPhone. The key stays in this iPhone's Keychain and never leaves it.")
                    .font(.body)
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

                Button(action: onTryAgain) {
                    Text(message == nil ? "Turn on Face ID" : "Try again")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)
                .tint(.ccAccent)
                .controlSize(.large)
                .accessibilityLabel(message == nil ? "Turn on Face ID" : "Try again")
            }
        }
    }
}
