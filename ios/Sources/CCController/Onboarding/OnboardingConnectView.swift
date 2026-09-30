import SwiftUI

struct OnboardingConnectView: View {
    let onContinue: () -> Void

    init(onContinue: @escaping () -> Void = {}) {
        self.onContinue = onContinue
    }

    var body: some View {
        OnboardingPage(step: "Step 2 of 4", buttonTitle: "Continue", action: onContinue) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connect to your Mac")
                        .font(.title.bold())
                        .foregroundStyle(.ccLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("In Termius, start the forward to \(Text("localhost:47832").font(.body.monospaced())). cc-controller looks for your Mac there.")
                        .font(.body)
                        .foregroundStyle(.ccSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                OnboardingCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.ccGreen)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connected to cc-controller 0.1.0")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.ccLabel)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("127.0.0.1:47832 · 18 ms")
                                .font(.footnote.monospaced())
                                .foregroundStyle(.ccSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
