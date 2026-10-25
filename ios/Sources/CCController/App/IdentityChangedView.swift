import SwiftUI

struct IdentityChangedView: View {
    let onRetry: () -> Void
    let onPairAgain: () -> Void
    @State private var confirmingPairAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.ccAccent)
            Text("Your Mac's identity changed")
                .font(.largeTitle.bold())
                .foregroundStyle(.ccLabel)
            Text("The relay presented a different key from the one this iPhone paired with. Someone may be intercepting the connection, or the Mac's relay key was reset.")
                .font(.body)
                .foregroundStyle(.ccSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Retry", action: onRetry)
                .buttonStyle(.glassProminent)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("identity-retry")
            Button("Pair again") {
                confirmingPairAgain = true
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("identity-pair-again")
        }
        .padding(28)
        .background(.ccBackground)
        .confirmationDialog(
            "Pair this iPhone again?",
            isPresented: $confirmingPairAgain,
            titleVisibility: .visible
        ) {
            Button("Pair again", role: .destructive, action: onPairAgain)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the stored Mac identity and device credentials.")
        }
        .accessibilityIdentifier("identity-changed-screen")
    }
}
