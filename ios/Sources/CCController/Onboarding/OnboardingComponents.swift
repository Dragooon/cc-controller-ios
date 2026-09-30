import SwiftUI

struct OnboardingPage<Content: View>: View {
    let step: String
    let buttonTitle: String?
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        step: String,
        buttonTitle: String?,
        action: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.step = step
        self.buttonTitle = buttonTitle
        self.action = action
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(step)
                .font(.caption)
                .foregroundStyle(.ccSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            Spacer(minLength: 28)
            content()
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
            Spacer(minLength: 28)

            if let buttonTitle {
                Button(action: action) {
                    Text(buttonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(.ccAccent)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            } else {
                Button("Start over", action: action)
                    .foregroundStyle(.ccSecondary)
                    .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ccBackground)
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(.ccCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
