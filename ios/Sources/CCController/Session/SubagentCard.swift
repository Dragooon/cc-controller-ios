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
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text("\(stateLabel) ·")
                            .font(.caption)
                            .foregroundStyle(.ccSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
        .accessibilityElement(children: .ignore)
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
    let subagent: Subagent?
    let onOpen: () -> Void

    init(entry: SubagentResultEntry, subagent: Subagent? = nil, onOpen: @escaping () -> Void = {}) {
        self.entry = entry
        self.subagent = subagent
        self.onOpen = onOpen
    }

    private var result: String { entry.result ?? entry.text ?? "" }
    private var agent: String { entry.agent ?? subagent?.agent ?? "agent" }
    private var durationText: String { displayDuration(durationMilliseconds) }
    private var summary: String { firstMeaningfulLine(result) }
    private var state: SubagentState { entry.state ?? subagent?.state ?? .done }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.2")
                    .font(.footnote)
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(agent) \(stateVerb)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(stateColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(summary.isEmpty ? "No result" : summary)
                        .font(.caption)
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 4)
                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.ccSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.ccSecondary)
                    .frame(width: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("subagent-result-row-\(entry.agentId ?? entry.toolUseId ?? "unknown")")
        .accessibilityLabel("\(agent) \(stateVerb) after \(durationText). \(summary.isEmpty ? "No result" : summary).")
        .accessibilityHint("Shows the result")
        .accessibilityElement(children: .ignore)
    }

    private var durationMilliseconds: Int {
        if let durationMs = entry.durationMs { return durationMs }
        guard let startedAt = subagent?.startedAt, let finishedAt = subagent?.finishedAt else { return 0 }
        return max(0, Int(startedAt.distance(to: finishedAt) * 1000))
    }

    private var stateVerb: String {
        switch state {
        case .done: "replied"
        case .failed: "failed"
        case .stopped, .unknown: "stopped"
        case .running: "replied"
        }
    }

    private var stateColor: Color {
        switch state {
        case .done: .ccGreen
        case .failed: .ccRed
        case .stopped, .unknown, .running: .ccSecondary
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
