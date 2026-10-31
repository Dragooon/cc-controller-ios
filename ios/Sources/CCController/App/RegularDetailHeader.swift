import SwiftUI

enum RegularHeaderMetrics {
    static let toggleSize: CGFloat = 44
    static let controlSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 16
    static let topPadding: CGFloat = 6
    static let bottomPadding: CGFloat = 6
    static let rowHeight = topPadding + toggleSize + bottomPadding
    /// The inspector's default 320 points plus a usable transcript beside it.
    static let minimumDetailWidthWithInspector: CGFloat = 640
}

extension EnvironmentValues {
    @Entry var regularHeaderLeadingInset: CGFloat = 0
}

/// The top row of a large-mode detail screen. It starts at the safe area, as the sidebar's header does,
/// so the two line up with the fixed sidebar toggle on every device without measuring anything.
struct RegularDetailHeader<Title: View, Trailing: View>: View {
    /// Keeps room for the approvals capsule that floats beside the sidebar toggle.
    var reservedText: String?
    @ViewBuilder let title: () -> Title
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.regularHeaderLeadingInset) private var leadingInset

    var body: some View {
        HStack(spacing: RegularHeaderMetrics.controlSpacing) {
            if let reservedText {
                Text(reservedText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .fixedSize()
                    .hidden()
                    .accessibilityHidden(true)
            }
            title()
            Spacer(minLength: 0)
            trailing()
        }
        .frame(height: RegularHeaderMetrics.toggleSize)
        .padding(.leading, RegularHeaderMetrics.horizontalPadding + leadingInset)
        .padding(.trailing, RegularHeaderMetrics.horizontalPadding)
        .padding(.top, RegularHeaderMetrics.topPadding)
        .padding(.bottom, RegularHeaderMetrics.bottomPadding)
        .background(.ccBackground)
    }
}
