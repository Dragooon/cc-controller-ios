import CCKit
import SwiftUI

struct OnboardingConnectView: View {
    let connection: OnboardingConnection
    let address: String
    let message: String?
    let diagnostics: RelayDiagnostics?
    let onBack: () -> Void
    let onContinue: () -> Void
    let onRetry: () -> Void

    init(
        connection: OnboardingConnection = .checking,
        address: String = "127.0.0.1:47832",
        message: String? = nil,
        diagnostics: RelayDiagnostics? = nil,
        onBack: @escaping () -> Void = {},
        onContinue: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {}
    ) {
        self.connection = connection
        self.address = address
        self.message = message
        self.diagnostics = diagnostics
        self.onBack = onBack
        self.onContinue = onContinue
        self.onRetry = onRetry
    }

    private var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    var body: some View {
        OnboardingPage(
            step: "Step 2 of 4",
            buttonTitle: "Continue",
            isButtonEnabled: isConnected,
            onBack: onBack,
            action: onContinue
        ) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(diagnostics == nil ? "Connect to your Mac" : "Can't reach your Mac")
                        .font(.title.bold())
                        .foregroundStyle(.ccLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    if diagnostics == nil {
                        Text("In Termius, start the forward to \(Text("localhost:47832").font(.body.monospaced())). Code looks for your Mac there.")
                            .font(.body)
                            .foregroundStyle(.ccSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(diagnostics!.summary)
                            .font(.body)
                            .foregroundStyle(.ccSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let diagnostics {
                    diagnosticsCard(diagnostics)
                } else {
                    statusCard
                }

                if case .unreachable = connection, diagnostics == nil {
                    Text("Check that Termius is forwarding localhost:47832 and the Mac is awake.")
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.ccAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func diagnosticsCard(_ diagnostics: RelayDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(diagnostics.endpoints) { endpoint in
                VStack(alignment: .leading, spacing: 4) {
                    Text(endpoint.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                    Text(endpoint.address)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.ccSecondary)
                    HStack {
                        Text(endpoint.statusText)
                            .font(.footnote)
                            .foregroundStyle(endpoint.status == .identityChanged ? .ccAccent : .ccSecondary)
                        Spacer()
                        if endpoint.status == .localNetworkDenied {
                            Button("Open Settings", action: openLocalNetworkSettings)
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("relay-diagnostic-\(endpoint.id)")
                if endpoint.id != diagnostics.endpoints.last?.id { Divider() }
            }
            Button("Retry", action: onRetry)
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("relay-retry")
        }
        .padding(16)
        .background(.ccCard, in: RoundedRectangle(cornerRadius: 16))
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
        case .connected(let latency): return "\(address) · \(latencyText(latency))"
        case .checking: return "Checking \(address)"
        case .unreachable: return address
        }
    }

    private var statusAccessibilityLabel: String {
        switch connection {
        case .connected(let latency): return "\(statusTitle). \(address), \(latencyText(latency)) round trip"
        default: return "\(statusTitle). \(statusDetail)"
        }
    }
}
