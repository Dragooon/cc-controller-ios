import Foundation

public struct MarkdownDocument: Sendable, Equatable {
    public let blocks: [MarkdownBlock]

    public init(parsing text: String) {
        do {
            let attributed = try AttributedString(
                markdown: text,
                options: .init(
                    allowsExtendedAttributes: false,
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
            blocks = MarkdownParser(attributed: attributed).parse()
        } catch {
            blocks = [.paragraph(AttributedString(text))]
        }
    }
}

public struct MarkdownListItem: Sendable, Equatable, Identifiable {
    public let ordinal: Int?
    public let text: AttributedString
    public let blocks: [MarkdownBlock]

    public init(ordinal: Int? = nil, text: AttributedString, blocks: [MarkdownBlock] = []) {
        self.ordinal = ordinal
        self.text = text
        self.blocks = blocks
    }

    public var id: String {
        let childIDs = blocks.map(\.id).joined(separator: ",")
        return "item|\(ordinal.map(String.init) ?? "nil")|\(text.characters)|[\(childIDs)]"
    }
}

public enum MarkdownBlock: Sendable, Equatable, Identifiable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, items: [MarkdownListItem])
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case rule
    case table(header: [AttributedString], rows: [[AttributedString]])

    public var id: String {
        switch self {
        case .heading(let level, let text):
            return "heading|\(level)|\(text.characters)"
        case .paragraph(let text):
            return "paragraph|\(text.characters)"
        case .list(let ordered, let items):
            return "list|\(ordered)|\(items.map(\.id).joined(separator: ","))"
        case .code(let language, let text):
            return "code|\(language ?? "nil")|\(text)"
        case .quote(let blocks):
            return "quote|\(blocks.map(\.id).joined(separator: ","))"
        case .rule:
            return "rule"
        case .table(let header, let rows):
            let headerText = header.map { String($0.characters) }.joined(separator: "|")
            let rowText = rows.map { $0.map { String($0.characters) }.joined(separator: "|") }.joined(separator: ";")
            return "table|\(headerText)|\(rowText)"
        }
    }
}

private struct MarkdownParser {
    private struct Node {
        let intent: PresentationIntent.IntentType?
        var textRange: Range<AttributedString.Index>?
        var children: [Node] = []
        var childIndices: [PresentationIntent.IntentType: Int] = [:]
    }

    private let attributed: AttributedString

    init(attributed: AttributedString) {
        self.attributed = attributed
    }

    func parse() -> [MarkdownBlock] {
        var roots: [Node] = []
        var rootIndices: [PresentationIntent.IntentType: Int] = [:]
        for run in attributed.runs {
            guard let presentationIntent = run.presentationIntent else {
                appendUnstructured(run.range, to: &roots)
                continue
            }
            insert(
                run.range,
                components: presentationIntent.components,
                depth: 0,
                into: &roots,
                indices: &rootIndices
            )
        }
        return roots.flatMap(makeBlocks)
    }

    private func appendUnstructured(_ range: Range<AttributedString.Index>, to roots: inout [Node]) {
        guard let index = roots.indices.last, roots[index].intent == nil else {
            roots.append(Node(intent: nil, textRange: range))
            return
        }
        roots[index].textRange = extend(roots[index].textRange, through: range)
    }

    private func insert(
        _ range: Range<AttributedString.Index>,
        components: [PresentationIntent.IntentType],
        depth: Int,
        into nodes: inout [Node],
        indices: inout [PresentationIntent.IntentType: Int]
    ) {
        let firstIndex = components.count - depth - 1
        guard firstIndex >= 0 else { return }
        let first = components[firstIndex]
        let index: Int
        if let existing = indices[first] {
            index = existing
        } else {
            nodes.append(Node(intent: first, textRange: nil))
            index = nodes.count - 1
            indices[first] = index
        }
        if depth == components.count - 1 {
            nodes[index].textRange = extend(nodes[index].textRange, through: range)
            return
        }
        var children = nodes[index].children
        var childIndices = nodes[index].childIndices
        insert(range, components: components, depth: depth + 1, into: &children, indices: &childIndices)
        nodes[index].children = children
        nodes[index].childIndices = childIndices
    }

    private func makeBlocks(_ node: Node) -> [MarkdownBlock] {
        let text = text(for: node)
        guard let intent = node.intent else {
            return text.characters.isEmpty ? [] : [.paragraph(text)]
        }
        switch intent.kind {
        case .paragraph:
            return [.paragraph(text)]
        case .header(let level):
            return [.heading(level: level, text: text)]
        case .orderedList, .unorderedList:
            return [makeList(node, ordered: intent.kind == .orderedList)]
        case .listItem:
            return node.children.flatMap(makeBlocks)
        case .codeBlock(let languageHint):
            return [.code(language: languageHint, text: String(text.characters))]
        case .blockQuote:
            return [.quote(node.children.flatMap(makeBlocks))]
        case .thematicBreak:
            return [.rule]
        case .table:
            return [makeTable(node)]
        case .tableHeaderRow, .tableRow, .tableCell:
            return node.children.flatMap(makeBlocks)
        @unknown default:
            return text.characters.isEmpty ? [] : [.paragraph(text)]
        }
    }

    private func makeList(_ node: Node, ordered: Bool) -> MarkdownBlock {
        let items = node.children.compactMap { child -> MarkdownListItem? in
            guard let intent = child.intent, case .listItem(let ordinal) = intent.kind else { return nil }
            return makeListItem(child, ordinal: ordered ? ordinal : nil)
        }
        return .list(ordered: ordered, items: items)
    }

    private func makeListItem(_ node: Node, ordinal: Int?) -> MarkdownListItem {
        var inlineText = AttributedString()
        var blocks: [MarkdownBlock] = []
        var foundInlineText = false
        for child in node.children {
            if !foundInlineText, let intent = child.intent, case .paragraph = intent.kind {
                inlineText = text(for: child)
                foundInlineText = true
                continue
            }
            blocks.append(contentsOf: makeBlocks(child))
        }
        return MarkdownListItem(ordinal: ordinal, text: inlineText, blocks: blocks)
    }

    private func makeTable(_ node: Node) -> MarkdownBlock {
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        for child in node.children {
            guard let intent = child.intent else { continue }
            switch intent.kind {
            case .tableHeaderRow:
                header = makeCells(child)
            case .tableRow:
                rows.append(makeCells(child))
            default:
                continue
            }
        }
        return .table(header: header, rows: rows)
    }

    private func makeCells(_ node: Node) -> [AttributedString] {
        let cells: [(Int, AttributedString)] = node.children.compactMap { child in
            guard let intent = child.intent, case .tableCell(let columnIndex) = intent.kind else { return nil }
            return (columnIndex, text(for: child))
        }
        return cells.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func text(for node: Node) -> AttributedString {
        guard let range = node.textRange else { return AttributedString() }
        return AttributedString(attributed[range])
    }

    private func extend(
        _ existing: Range<AttributedString.Index>?,
        through range: Range<AttributedString.Index>
    ) -> Range<AttributedString.Index> {
        guard let existing else { return range }
        return existing.lowerBound..<range.upperBound
    }
}
