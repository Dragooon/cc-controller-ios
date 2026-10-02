import SwiftUI

private let onboardingPrimaryHeight: CGFloat = 50

struct OnboardingPage<Content: View>: View {
    let step: String
    let buttonTitle: String?
    let isButtonEnabled: Bool
    let onBack: (() -> Void)?
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        step: String,
        buttonTitle: String?,
        isButtonEnabled: Bool = true,
        onBack: (() -> Void)? = nil,
        action: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.step = step
        self.buttonTitle = buttonTitle
        self.isButtonEnabled = isButtonEnabled
        self.onBack = onBack
        self.action = action
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                            .frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
                    }
                    .accessibilityLabel("Back")
                }
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                    .frame(maxWidth: .infinity, alignment: onBack == nil ? .leading : .center)
                if onBack != nil {
                    Color.clear.frame(width: CCMetrics.minTap, height: CCMetrics.minTap)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer(minLength: 28)
            content()
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
            Spacer(minLength: 28)

            if let buttonTitle {
                Button(action: action) {
                    Text(buttonTitle)
                        .foregroundStyle(.white)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: onboardingPrimaryHeight, maxHeight: onboardingPrimaryHeight)
                        .glassEffect(.regular.tint(.ccAccent).interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(!isButtonEnabled)
                .opacity(isButtonEnabled ? 1 : 0.45)
                .frame(maxWidth: .infinity, minHeight: onboardingPrimaryHeight)
                .contentShape(Rectangle())
                .accessibilityLabel(buttonTitle)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            } else if onBack == nil {
                Button("Start over", action: action)
                    .foregroundStyle(.ccSecondary)
                    .buttonStyle(.plain)
                    .frame(minWidth: CCMetrics.minTap, minHeight: CCMetrics.minTap)
                    .contentShape(Rectangle())
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
