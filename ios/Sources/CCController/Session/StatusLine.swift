import SwiftUI

struct StatusLineView: View {
    let segments: [String]

    private var fullText: String { segments.joined(separator: " · ") }
    private var reducedText: String { segments.prefix(2).joined(separator: " · ") }
    private var shortestText: String { segments.first ?? "" }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            statusText(fullText)
            statusText(reducedText)
            statusText(shortestText)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.ccSecondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 1)
        .accessibilityLabel(fullText.replacingOccurrences(of: " · ", with: ", "))
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: true, vertical: false)
    }
}
