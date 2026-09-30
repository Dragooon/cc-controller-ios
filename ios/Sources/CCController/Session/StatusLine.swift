import SwiftUI

struct StatusLineView: View {
    let segments: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(segments.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.ccSecondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(segments.joined(separator: ", "))
    }
}
