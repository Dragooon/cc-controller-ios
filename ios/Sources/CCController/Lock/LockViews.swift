import SwiftUI

struct LockView: View {
    let message: String?
    let onUnlock: () -> Void

    init(message: String? = nil, onUnlock: @escaping () -> Void = {}) {
        self.message = message
        self.onUnlock = onUnlock
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("✻")
                .font(.system(size: 72, weight: .regular, design: .rounded))
                .foregroundStyle(.ccAccent)
                .accessibilityHidden(true)
            Text("cc-controller is locked")
                .font(.headline)
                .foregroundStyle(.ccLabel)
            if let message {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ccAccent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }
            Button(action: onUnlock) {
                Label("Unlock with Face ID", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.ccAccent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ccBackground)
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct PrivacyCoverView: View {
    var body: some View {
        Text("✻")
            .font(.system(size: 72, weight: .regular, design: .rounded))
            .foregroundStyle(.ccAccent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ccBackground)
            .accessibilityLabel("cc-controller")
            .toolbar(.hidden, for: .navigationBar)
    }
}
