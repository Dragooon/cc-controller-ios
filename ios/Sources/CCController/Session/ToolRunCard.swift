import CCKit
import SwiftUI

struct ToolRunCard: View {
    let run: ToolRun
    let onTool: (ToolEntry) -> Void
    @State private var userExpanded: Bool?

    init(run: ToolRun, onTool: @escaping (ToolEntry) -> Void) {
        self.run = run
        self.onTool = onTool
        _userExpanded = State(initialValue: nil)
    }

    private var isExpanded: Bool { userExpanded ?? !nativeToolRunIsCollapsed(run) }
    private var isCollapsedRun: Bool { nativeToolRunIsCollapsed(run) && !isExpanded }

    private var collapsedEntries: [ToolEntry] {
        guard let current = run.entries.last(where: { $0.state == .running }) else { return [] }
        return [current]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if run.entries.count >= 4 {
                Button { userExpanded = !isExpanded } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(nativeToolRunLabel(run))
                            .font(.subheadline)
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(run.tallyText)
                            .font(.caption)
                            .foregroundStyle(.ccTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.ccTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.snappy, value: isExpanded)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(nativeToolRunLabel(run))
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }

            let entries = isCollapsedRun ? collapsedEntries : run.entries
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                ToolRow(entry: entry, onOpen: onTool)
                    .id(entry.stableToolRowID + "-\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolRow: View {
    let entry: ToolEntry
    let onOpen: (ToolEntry) -> Void

    var body: some View {
        if let questionRow = questionTranscriptRow(for: entry) {
            QuestionRow(entry: entry, row: questionRow, onOpen: onOpen)
        } else {
            toolRow
        }
    }

    private var toolRow: some View {
        Button { onOpen(entry) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ToolSymbol(tool: entry.tool ?? "Tool")
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 20, height: 20)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[.bottom]
                    }

                Text(toolPhrase(entry))
                    .font(.subheadline)
                    .foregroundStyle(.ccSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ToolRowStatus(entry: entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toolPhraseAccessibilityLabel(entry))
    }
}

private struct QuestionRow: View {
    let entry: ToolEntry
    let row: QuestionTranscriptRow
    let onOpen: (ToolEntry) -> Void

    var body: some View {
        Button { onOpen(entry) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.footnote)
                    .foregroundStyle(row.pending ? .ccAccent : .ccSecondary)
                    .frame(width: 20, height: 20)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[.bottom]
                    }

                Text(row.text)
                    .font(.subheadline)
                    .foregroundStyle(.ccSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ToolRowStatus(entry: entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("question-row")
        .accessibilityLabel("Question")
        .accessibilityValue(row.text)
    }
}

private struct ToolRowStatus: View {
    let entry: ToolEntry

    var body: some View {
        if entry.state == .running {
            ProgressView()
                .controlSize(.mini)
                .tint(.ccSecondary)
                .accessibilityHidden(true)
        } else if isFailed {
            Image(systemName: "exclamationmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.ccRed)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.ccTertiary)
                .accessibilityHidden(true)
        }
    }

    private var isFailed: Bool {
        if case .unknown(let value) = entry.state { return value == "failed" }
        return false
    }
}

private extension ToolEntry {
    var stableToolRowID: String {
        id ?? toolUseId ?? "tool"
    }
}
