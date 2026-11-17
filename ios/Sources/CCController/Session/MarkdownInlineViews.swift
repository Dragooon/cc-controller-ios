import SwiftUI
import UIKit

struct InlineMarkdownText: View {
    let text: AttributedString
    /// Nil for running text. 1 is the largest heading; 3 and deeper share the smallest heading size.
    var headingLevel: Int?

    var body: some View {
        Text(styledText)
            .font(textFont)
            .lineSpacing(headingLevel == nil ? CCMetrics.readingLineSpacing : CCMetrics.headingLineSpacing)
            .foregroundStyle(.ccLabel)
            .tint(.ccAccent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, headingLevel == nil ? 0 : CCMetrics.headingTopSpacing)
    }

    /// Headings step up in size so a long reply shows its structure: a heading the size of the text around it
    /// reads as one more bold line.
    private var textFont: Font {
        switch headingLevel {
        case nil: .body
        case 1?: .title2.weight(.semibold)
        case 2?: .title3.weight(.semibold)
        default: .headline
        }
    }

    /// Code inside a sentence. A fixed-width face looks larger than the text around it at the same size, so
    /// in running text it is set one step smaller.
    private var inlineCodeFont: Font {
        headingLevel == nil ? .subheadline.monospaced() : textFont.monospaced()
    }

    private var styledText: AttributedString {
        var styled = text
        for run in styled.runs {
            guard run.inlinePresentationIntent?.contains(.code) == true else { continue }
            styled[run.range].font = inlineCodeFont
            // A tint of the text colour shows on every surface: the page, a bubble, a card.
            styled[run.range].backgroundColor = Color.ccLabel.opacity(0.10)
        }
        return styled
    }
}

struct CodeBlockView: View {
    let code: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { UIPasteboard.general.string = code } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 28, height: 28)
                    .tapOutset(horizontal: 8, vertical: 8)
            }
            .buttonStyle(.ccPressable)
            .accessibilityLabel("Copy code")

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.ccLabel)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.ccCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct MarkdownTableView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(header, isHeader: true)
                Rectangle()
                    .fill(.ccSeparator)
                    .frame(height: 1)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, isHeader: false)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(.ccSeparator)
                            .frame(height: 1)
                    }
                }
            }
            .background(.ccCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private func tableRow(_ cells: [AttributedString], isHeader: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(.footnote.weight(isHeader ? .semibold : .regular))
                    .foregroundStyle(.ccLabel)
                    .frame(minWidth: 100, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
        }
    }
}
