import SwiftUI

struct OnboardingPairView: View {
    let onStartOver: () -> Void
    let onCopyCode: () -> Void

    init(onStartOver: @escaping () -> Void = {}, onCopyCode: @escaping () -> Void = {}) {
        self.onStartOver = onStartOver
        self.onCopyCode = onCopyCode
    }

    var body: some View {
        OnboardingPage(step: "Step 3 of 4", buttonTitle: nil, action: onStartOver) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pair this iPhone")
                    .font(.title.bold())
                    .foregroundStyle(.ccLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                OnboardingCard {
                    Text("482 913")
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.ccLabel)
                        .frame(maxWidth: .infinity)
                        .minimumScaleFactor(0.75)
                }

                Text("On the Mac, run")
                    .font(.body)
                    .foregroundStyle(.ccSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                OnboardingCard {
                    stackedCommand
                }

                Text("Expires in 4:12")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.ccSecondary)

                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.ccAccent)
                    Text("Waiting for the Mac…")
                        .font(.subheadline)
                        .foregroundStyle(.ccSecondary)
                }
            }
        }
    }

    private var stackedCommand: some View {
        VStack(alignment: .leading, spacing: 10) {
            commandText
            copyCommandButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var commandText: some View {
        Text("cc-gateway pair 482913")
            .font(.body.monospaced())
            .foregroundStyle(.ccLabel)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var copyCommandButton: some View {
        Button(action: onCopyCode) {
            Image(systemName: "doc.on.doc")
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.ccAccent)
        .accessibilityLabel("Copy pairing command")
    }
}
