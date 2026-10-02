import CCKit
import SwiftUI

struct SubagentCard: View {
    let entry: SubagentEntry
    let onOpen: (SubagentEntry) -> Void

    private var state: SubagentState { entry.state ?? .done }
    private var linked: Bool { !(entry.agentId ?? "").isEmpty }

    var body: some View {
        Button { onOpen(entry) } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        statusDot
                        Text(entry.agent ?? "agent")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.ccLabel)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(stateLabel) ·")
                            .font(.caption)
                            .foregroundStyle(.ccSecondary)
                        LiveElapsedText(
                            startedAt: entry.startedAt,
                            finishedAt: entry.finishedAt,
                            isLive: state == .running,
                            fallback: nil
                        )
                        .font(.caption)
                        .foregroundStyle(.ccSecondary)
                    }
                    Text(firstMeaningfulLine(entry.text))
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                    if state == .done, !firstMeaningfulLine(entry.result).isEmpty {
                        Text(firstMeaningfulLine(entry.result))
                            .font(.footnote)
                            .foregroundStyle(.ccLabel)
                            .lineLimit(1)
                    }
                    if !linked {
                        Text("transcript not linked")
                            .font(.caption)
                            .foregroundStyle(.ccSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 20)
            }
            .padding(13)
            .background(.ccCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("subagent-card-\(entry.agentId ?? "")")
        .accessibilityLabel("\(entry.agent ?? "agent"), \(stateLabel)")
        .disabled(!linked)
        .opacity(linked ? 1 : 0.7)
    }

    @ViewBuilder
    private var statusDot: some View {
        switch state {
        case .running:
            SpinnerGlyph(active: true, frozen: false)
                .font(.caption)
                .accessibilityHidden(true)
        case .done:
            Text("●")
                .foregroundStyle(.ccGreen)
        case .failed:
            Text("●")
                .foregroundStyle(.ccRed)
        case .stopped, .unknown:
            Text("●")
                .foregroundStyle(.ccSecondary)
        }
    }

    private var stateLabel: String {
        switch state {
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .unknown: "Stopped"
        }
    }
}

struct SubagentResultView: View {
    let entry: SubagentResultEntry
    @State private var isExpanded = false

    private var result: String { entry.result ?? entry.text ?? "" }
    private var durationText: String { displayDuration(entry.durationMs ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                    Text("\(entry.agent ?? "agent") replied · \(durationText)")
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ccSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                MarkdownView(markdown: result)
                    .textSelection(.enabled)
            } else {
                Text(firstMeaningfulLine(result))
                    .font(.footnote)
                    .foregroundStyle(.ccLabel)
                    .lineLimit(1)
            }
        }
    }
}

struct SendMessageView: View {
    let entry: ToolEntry
    let subagents: [Subagent]

    init(entry: ToolEntry, subagents: [Subagent] = []) {
        self.entry = entry
        self.subagents = subagents
    }

    private var messageText: String {
        let args = entry.args?.objectValue ?? [:]
        let rawTarget = args["to"]?.stringValue ?? args["recipient"]?.stringValue ?? ""
        let target = resolveSendMessageTarget(rawTarget, subagents: subagents)
        let summary = sendMessageSummary(args: args)
        return [target, summary].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "arrow.right")
                .font(.footnote)
                .foregroundStyle(.ccSecondary)
            Text(messageText)
                .font(.footnote)
                .foregroundStyle(.ccSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 3)
    }
}
