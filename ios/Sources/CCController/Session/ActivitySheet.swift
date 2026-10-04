import CCKit
import SwiftUI

struct ActivitySheet: View {
    let session: Session
    let onSubagent: (Subagent) -> Void
    @State private var selectedDetent: PresentationDetent

    init(session: Session, initialDetent: PresentationDetent = .medium, onSubagent: @escaping (Subagent) -> Void = { _ in }) {
        self.session = session
        self.onSubagent = onSubagent
        _selectedDetent = State(initialValue: initialDetent)
    }

    private var runningAgents: [Subagent] {
        (session.subagents ?? []).filter { $0.state == .running }
    }

    private var runningShells: [Shell] {
        (session.shells ?? []).filter { $0.state == .running }
    }

    private var recent: [ActivityItem] {
        finishedRecently(for: session)
    }

    var body: some View {
        NavigationStack {
            List {
                if !runningAgents.isEmpty || !runningShells.isEmpty {
                    Section("Running") {
                        ForEach(Array(runningAgents.enumerated()), id: \.offset) { _, agent in
                            ActivityAgentRow(agent: agent, onTap: { onSubagent(agent) })
                        }
                        ForEach(Array(runningShells.enumerated()), id: \.offset) { _, shell in
                            ActivityShellRow(shell: shell)
                        }
                    }
                }

                if !recent.isEmpty {
                    Section("Finished recently") {
                        ForEach(Array(recent.enumerated()), id: \.offset) { _, item in
                            switch item {
                            case .agent(let agent):
                                ActivityAgentRow(agent: agent, onTap: { onSubagent(agent) })
                            case .shell(let shell):
                                ActivityShellRow(shell: shell)
                            }
                        }
                    }
                }

                if runningAgents.isEmpty && runningShells.isEmpty && recent.isEmpty {
                    Section {
                        Text("Nothing running")
                            .foregroundStyle(.ccSecondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(.ccBackground)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .tint(.ccAccent)
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
    }
}

private struct ActivityAgentRow: View {
    let agent: Subagent
    let onTap: () -> Void

    private var isTappable: Bool { agent.agentId?.isEmpty == false }
    private var title: String { agent.agent ?? "agent" }
    private var detail: String {
        let value = agent.state == .running ? agent.text : agent.result
        let line = firstMeaningfulLine(value)
        return line.isEmpty ? subagentStateLabel(state: agent.state?.rawValue) : line
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ActivityStateGlyph(state: agent.state)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ccLabel)
                        .lineLimit(1)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if agent.startedAt != nil {
                    LiveElapsedText(
                        startedAt: agent.startedAt,
                        finishedAt: agent.finishedAt,
                        isLive: agent.state == .running,
                        fallback: nil
                    )
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.ccSecondary)
                }
                if isTappable {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.ccSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
        .accessibilityIdentifier("activity-agent-\(agent.agentId ?? "unknown")")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [title, agent.state?.rawValue ?? "unknown", detail]
        if let startedAt = agent.startedAt {
            parts.append(formatDuration(startedAt.distance(to: agent.finishedAt ?? .now) * 1000))
        }
        return parts.joined(separator: ", ")
    }
}

private struct ActivityShellRow: View {
    let shell: Shell

    private var title: String { shell.description ?? "Shell" }
    private var detail: String { shell.command ?? "" }
    private var stateLabel: String { shell.state?.rawValue ?? "unknown" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.ccAccent)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.ccLabel)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.ccSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if shell.state != .running {
                    Text(stateLabel)
                        .font(.caption)
                        .foregroundStyle(shellStateColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if shell.startedAt != nil {
                LiveElapsedText(
                    startedAt: shell.startedAt,
                    finishedAt: shell.finishedAt,
                    isLive: shell.state == .running,
                    fallback: nil
                )
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.ccSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var shellStateColor: Color {
        switch shell.state {
        case .done: .ccGreen
        case .failed: .ccRed
        case .stopped: .ccSecondary
        default: .ccTertiary
        }
    }

    private var accessibilityLabel: String {
        var parts = [title, detail, stateLabel]
        if let startedAt = shell.startedAt {
            parts.append(formatDuration(startedAt.distance(to: shell.finishedAt ?? .now) * 1000))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private struct ActivityStateGlyph: View {
    let state: SubagentState?

    var body: some View {
        if state == .running {
            SpinnerGlyph(active: true, frozen: false)
                .font(.subheadline)
        } else {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }

    private var color: Color {
        switch state {
        case .done: .ccGreen
        case .failed: .ccRed
        case .stopped: .ccSecondary
        default: .ccTertiary
        }
    }
}
