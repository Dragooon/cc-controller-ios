import SwiftUI

struct InlineMarkdownText: View {
    let text: AttributedString
    var heading = false

    var body: some View {
        Text(styledText)
            .font(heading ? .body.weight(.semibold) : .body)
            .foregroundStyle(.ccLabel)
            .tint(.ccAccent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var styledText: AttributedString {
        var styled = text
        for run in styled.runs {
            guard run.inlinePresentationIntent?.contains(.code) == true else { continue }
            styled[run.range].font = heading ? .body.monospaced().weight(.semibold) : .body.monospaced()
            styled[run.range].backgroundColor = .ccCard
        }
        return styled
    }
}

struct CodeBlockView: View {
    let code: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {} label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
