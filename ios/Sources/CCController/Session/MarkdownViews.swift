import CCKit
import SwiftUI

struct AssistantReplyView: View {
    let text: String

    var body: some View {
        MarkdownView(markdown: text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownView: View {
    let markdown: String

    private var document: MarkdownDocument {
        MarkdownDocumentCache.shared.document(for: markdown)
    }

    var body: some View {
        #if CC_PERF
        let _ = PerfCounters.shared.hit(.markdownView)
        #endif
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let listDepth: Int

    init(block: MarkdownBlock, listDepth: Int = 0) {
        self.block = block
        self.listDepth = listDepth
    }

    var body: some View {
        switch block {
        case .paragraph(let text):
            InlineMarkdownText(text: text)
        case .heading(_, let text):
            InlineMarkdownText(text: text, heading: true)
        case .list(let ordered, let items):
            MarkdownListView(ordered: ordered, items: items, depth: listDepth)
        case .code(_, let code):
            CodeBlockView(code: code)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(.ccSeparator)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block, listDepth: listDepth)
                    }
                }
            }
        case .rule:
            Rectangle()
                .fill(.ccSeparator)
                .frame(height: 1)
        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)
        }
    }
}

private struct MarkdownListView: View {
    let ordered: Bool
    let items: [MarkdownListItem]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(for: item, index: index))
                        .font(.body)
                        .foregroundStyle(.ccAccent)
                        .frame(minWidth: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        if !item.text.characters.isEmpty {
                            InlineMarkdownText(text: item.text)
                        }
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block, listDepth: depth + 1)
                        }
                    }
                }
                .padding(.leading, CGFloat(depth) * 16)
            }
        }
    }

    private func marker(for item: MarkdownListItem, index: Int) -> String {
        guard ordered else { return "•" }
        return "\(item.ordinal ?? index + 1)."
    }
}

