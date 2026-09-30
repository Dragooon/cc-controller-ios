import CCKit
import SwiftUI

struct LiveActivityFooterView: View {
    let footer: CCKit.ActivityFooter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SpinnerGlyph(active: true, frozen: true)
                    .font(.footnote)
                Text(primaryText)
                    .font(.footnote)
                    .foregroundStyle(.ccLabel)
            }

            Text(footer.detail)
                .font(.footnote.monospaced())
                .foregroundStyle(.ccSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(primaryText), \(footer.detail)")
    }

    private var primaryText: String {
        footer.primary.hasPrefix("✻ ") ? String(footer.primary.dropFirst(2)) : footer.primary
    }
}
