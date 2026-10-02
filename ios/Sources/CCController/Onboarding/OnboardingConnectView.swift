import CCKit
import SwiftUI

struct OnboardingConnectView: View {
    let connection: OnboardingConnection
    let address: String
    let message: String?
    let onBack: () -> Void
    let onContinue: () -> Void

    init(
        connection: OnboardingConnection = .checking,
        address: String = "127.0.0.1:47832",
        message: String? = nil,
        onBack: @escaping () -> Void = {},
        onContinue: @escaping () -> Void = {}
    ) {
        self.connection = connection
        self.address = address
        self.message = message
        self.onBack = onBack
        self.onContinue = onContinue
    }

    private var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    var body: some View {
        OnboardingPage(
            step: "Step 2 of 5",
            buttonTitle: "Continue",
            isButtonEnabled: isConnected,
            onBack: onBack,
            action: onContinue
        ) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connect to your Mac")
                        .font(.title.bold())
                        .foregroundStyle(.ccLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Start the Termius port forward to localhost:47832 on this iPhone.")
                        .font(.body)
                        .foregroundStyle(.ccSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                statusCard

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.ccAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusCard: some View {
        OnboardingCard {
            HStack(alignment: .top, spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(statusDetail)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.ccSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusAccessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch connection {
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.ccGreen)
        case .checking:
            ProgressView()
                .controlSize(.small)
                .tint(.ccAccent)
        case .unreachable:
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.ccAccent)
        }
    }

    private var statusTitle: String {
        switch connection {
        case .connected: return "Connected to cc-controller"
        case .checking: return "Looking for your Mac…"
        case .unreachable: return "Can't reach the Mac yet"
        }
    }

    private var statusDetail: String {
        switch connection {
        case .connected: return address
        case .checking: return "Checking \(address)"
        case .unreachable: return address
        }
    }

    private var statusAccessibilityLabel: String {
        "\(statusTitle). \(statusDetail)"
    }
}
