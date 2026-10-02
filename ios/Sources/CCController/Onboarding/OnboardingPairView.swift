import SwiftUI

struct OnboardingPairView: View {
    let code: String
    let expiresAt: Date
    let isExpired: Bool
    let copied: Bool
    let message: String?
    let onBack: () -> Void
    let onCopyCode: () -> Void
    let onNewCode: () -> Void

    init(
        code: String = "",
        expiresAt: Date = .now,
        isExpired: Bool = false,
        copied: Bool = false,
        message: String? = nil,
        onBack: @escaping () -> Void = {},
        onCopyCode: @escaping () -> Void = {},
        onNewCode: @escaping () -> Void = {}
    ) {
        self.code = code
        self.expiresAt = expiresAt
        self.isExpired = isExpired
        self.copied = copied
        self.message = message
        self.onBack = onBack
        self.onCopyCode = onCopyCode
        self.onNewCode = onNewCode
    }

    var body: some View {
        OnboardingPage(step: "Step 3 of 5", buttonTitle: nil, onBack: onBack) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pair this iPhone")
                    .font(.title.bold())
                    .foregroundStyle(.ccLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                OnboardingCard {
                    Text(code.spacedDigits)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.ccLabel)
                        .frame(maxWidth: .infinity)
                        .minimumScaleFactor(0.75)
                        .accessibilityIdentifier("pairing-code")
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                }

                Text("On the Mac run")
                    .font(.body)
                    .foregroundStyle(.ccSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                OnboardingCard { stackedCommand }

                if isExpired {
                    Text("This code expired")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccAccent)
                    Button("Get a new code", action: onNewCode)
                        .buttonStyle(.glassProminent)
                        .tint(.ccAccent)
                        .frame(minHeight: CCMetrics.minTap)
                        .accessibilityLabel("Get a new pairing code")
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(expiryText(at: context.date))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.ccSecondary)
                            .accessibilityLabel(expiryText(at: context.date))
                    }

                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.ccAccent)
                        Text("Waiting for the Mac…")
                            .font(.subheadline)
                            .foregroundStyle(.ccSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Waiting for the Mac to approve this code")
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.ccAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sensoryFeedback(.success, trigger: copied)
    }

    private var stackedCommand: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("cc-gateway pair \(code)")
                .font(.body.monospaced())
                .foregroundStyle(.ccLabel)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: onCopyCode) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: CCMetrics.minTap, minHeight: CCMetrics.minTap)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.ccAccent)
                .accessibilityLabel(copied ? "Pairing command copied" : "Copy pairing command")
            }
        }
    }

    private func expiryText(at date: Date) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(date)))
        return String(format: "Expires in %d:%02d", seconds / 60, seconds % 60)
    }
}

private extension String {
    var spacedDigits: String {
        guard count > 3 else { return self }
        let midpoint = index(startIndex, offsetBy: count - 3)
        return "\(self[..<midpoint]) \(self[midpoint...])"
    }
}
