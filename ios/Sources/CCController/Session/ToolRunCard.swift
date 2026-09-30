import CCKit
import SwiftUI

struct ToolRunCard: View {
    let run: ToolRun
    let onTool: (ToolEntry) -> Void
    @State private var isExpanded: Bool

    init(run: ToolRun, onTool: @escaping (ToolEntry) -> Void) {
        self.run = run
        self.onTool = onTool
        _isExpanded = State(initialValue: run.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if run.entries.count >= 2 {
                Button { isExpanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.ccLabel)
                            Text(run.tallyText)
                                .font(.footnote)
                                .foregroundStyle(.ccSecondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.ccSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if isExpanded {
                    Divider().overlay(.ccSeparator)
                }
            }

            if isExpanded || run.entries.count == 1 {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(run.entries.enumerated()), id: \.offset) { index, entry in
                        ToolRow(entry: entry, onOpen: onTool)
                        if index < run.entries.count - 1 {
                            Divider().overlay(.ccSeparator)
                                .padding(.leading, 38)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, run.entries.count == 1 ? 10 : 8)
            }
        }
        .background(.ccCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ToolRow: View {
    let entry: ToolEntry
    let onOpen: (ToolEntry) -> Void

    private var state: ToolDisplayState {
        switch entry.state {
        case .running: .running
        case .done, nil: .done
        case .unknown(let value): value == "failed" ? .failed : .done
        }
    }

    var body: some View {
        Button { onOpen(entry) } label: {
            HStack(alignment: .top, spacing: 8) {
                ToolSymbol(tool: entry.tool ?? "Tool")
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.tool ?? "Tool")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.ccLabel)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(toolArgument(entry.tool, args: entry.args))
                            .font(.footnote.monospaced())
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ToolStatusView(state: state)
                    }
                    Text(firstMeaningfulLine(entry.result))
                        .font(.caption.monospaced())
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.tool ?? "Tool") \(toolArgument(entry.tool, args: entry.args))")
    }
}

private enum ToolDisplayState { case running, done, failed }

private struct ToolStatusView: View {
    let state: ToolDisplayState

    var body: some View {
        switch state {
        case .running:
            HStack(spacing: 4) {
                SpinnerGlyph(active: true, frozen: true)
                Text("12s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.ccAccent)
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.ccGreen)
        case .failed:
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.ccRed)
        }
    }
}
